/**
 * @file src/platform/macos/input_scroll.cpp
 * @brief Continuous trackpad scroll, 120Hz inertia/momentum engine, discrete wheel scroll, and pinch/rotate gestures.
 */
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <ctime>
#include <mutex>
#include <vector>

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <pthread/qos.h>

#include "src/config.h"
#include "src/platform/common.h"
#include "src/platform/macos/cf_guard.h"
#include "src/platform/macos/input_internal.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/sc_video.h"
#include "src/platform/macos/wheel_scroll.h"
#include "src/voidlink_protocol.h"

namespace platf {
  using namespace std::literals;

  namespace {
    double scroll_pixels_exact(const macos_input_t *macos_input, const int high_res_distance) {
      const auto source_pixels_per_line = CGEventSourceGetPixelsPerLine(macos_input->source);
      const auto pixels_per_line = source_pixels_per_line > 0 ? static_cast<double>(source_pixels_per_line) : 10.0;
      return static_cast<double>(high_res_distance) * std::max(1.0, pixels_per_line) * std::max(1, macos_input->scroll_lines_per_detent) / static_cast<double>(WHEEL_DELTA);
    }

    void post_scroll_event_raw(
      macos_input_t *macos_input,
      const int wheelY,
      const int wheelX,
      const uint32_t scroll_phase,
      const uint32_t momentum_phase,
      const CGPoint *target_loc = nullptr
    ) {
      const bool is_terminal_phase =
        (scroll_phase == kCGScrollPhaseEnded ||
         scroll_phase == kCGScrollPhaseCancelled ||
         momentum_phase == kCGMomentumScrollPhaseEnd);
      if (wheelY == 0 && wheelX == 0 && !is_terminal_phase) {
        return;
      }

      const cf_ref_t<CGEventRef> event(CGEventCreateScrollWheelEvent(
        macos_input->source,
        kCGScrollEventUnitPixel,
        2,
        wheelY,
        wheelX
      ));
      if (!event) {
        return;
      }

      if (target_loc) {
        CGEventSetLocation(event.get(), *target_loc);
      }
      CGEventSetIntegerValueField(event.get(), kCGScrollWheelEventIsContinuous, 1);
      CGEventSetIntegerValueField(event.get(), kCGScrollWheelEventScrollPhase, scroll_phase);
      CGEventSetIntegerValueField(event.get(), kCGScrollWheelEventMomentumPhase, momentum_phase);
      CGEventSetFlags(event.get(), momentum_phase != 0 ? 0 : macos_input->kb_flags.load(std::memory_order_relaxed));
      CGEventSetTimestamp(event.get(), clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
      CGEventPost(kCGHIDEventTap, event.get());
    }

    void post_gesture_event_locked(macos_input_t *input, int dy, int dx, uint32_t phase, uint32_t momentum) {
      post_scroll_event_raw(
        input,
        dy,
        dx,
        phase,
        momentum,
        input->scroll.has_target_loc ? &input->scroll.target_loc : nullptr
      );
    }

    bool start_scroll_momentum_locked(
      macos_input_t *macos_input,
      const std::chrono::steady_clock::time_point now,
      const bool immediate_first_tick = false
    ) {
      auto &s = macos_input->scroll;
      const auto &c = macos_input->cursor;
      const auto mode = config::get_macos_scroll_inertia();
      if (mode == config::macos_scroll_inertia_e::disabled) {
        s.clear_velocity();
        return false;
      }

      const double total_abs = std::hypot(s.gesture_abs_x, s.gesture_abs_y);
      if (s.sample_count < 2 || total_abs < 10.0) {
        s.clear_velocity();
        return false;
      }
      if (s.cancelled_momentum && (s.sample_count < 4 || total_abs < 28.0)) {
        s.clear_velocity();
        return false;
      }

      if (s.gesture_abs_x > 14.0 && s.gesture_abs_x > 2.5 * s.gesture_abs_y) {
        s.vy = 0.0;
      } else if (s.gesture_abs_y > 14.0 && s.gesture_abs_y > 2.5 * s.gesture_abs_x) {
        s.vx = 0.0;
      }

      const bool ipados_style = (mode == config::macos_scroll_inertia_e::ipados);
      const double speed = std::hypot(s.vx, s.vy);
      const double min_speed = s.cancelled_momentum ? 220.0 : (ipados_style ? 85.0 : 80.0);
      if (speed < min_speed) {
        s.clear_velocity();
        return false;
      }

      s.in_momentum = true;
      s.momentum_first_tick = true;
      s.momentum_anchor =
        (c.touch_suppressed && c.has_saved_trackpad_cursor) ?
          c.saved_trackpad_cursor :
          CGPointMake(c.last_cursor_loc.x, c.last_cursor_loc.y);
      s.has_momentum_anchor = true;
      s.mom_ipados_style = ipados_style;
      s.mom_v0_x = s.vx;
      s.mom_v0_y = s.vy;
      s.mom_v0_speed = speed;
      s.mom_emitted_x = 0.0;
      s.mom_emitted_y = 0.0;
      s.mom_start_time = immediate_first_tick ? (now - 8333us) : now;
      s.next_mom_tick = immediate_first_tick ? now : (now + 8333us);

      if (!ipados_style) {
        const double duration = 0.063 * std::cbrt(speed);
        s.mom_duration = duration;
        s.mom_total_x = s.vx * duration * 0.25;
        s.mom_total_y = s.vy * duration * 0.25;
      }
      return true;
    }

    void update_axis_velocity(
      double &vel,
      bool &peel_used,
      std::chrono::steady_clock::time_point &last_axis_time,
      const std::chrono::steady_clock::time_point now,
      const double delta_px,
      const bool first_in_gesture,
      const int sample_count
    ) {
      if (delta_px == 0.0) {
        return;
      }
      if (first_in_gesture || last_axis_time.time_since_epoch().count() == 0) {
        vel = 0.0;
        peel_used = false;
        last_axis_time = now;
        return;
      }
      const double dt = std::chrono::duration<double>(now - last_axis_time).count();
      last_axis_time = now;
      if (dt > 0.075) {
        vel = 0.0;
        peel_used = false;
        return;
      }
      const double inst_v = std::clamp(delta_px / std::max(dt, 0.0075), -8000.0, 8000.0);
      if (sample_count <= 2 || vel == 0.0 || vel * inst_v < 0.0) {
        vel = inst_v;
        peel_used = false;
      } else if (!peel_used && dt < 0.025 && std::abs(vel) > 180.0 && std::abs(inst_v) < 0.35 * std::abs(vel)) {
        vel = 0.82 * vel + 0.18 * inst_v;
        peel_used = true;
      } else if (peel_used && std::abs(inst_v) < 0.50 * std::abs(vel)) {
        vel = inst_v;
      } else {
        if (std::abs(inst_v) >= 0.60 * std::abs(vel)) {
          peel_used = false;
        }
        vel = 0.55 * inst_v + 0.45 * vel;
      }
    }

    bool post_pending_drag_locked(macos_input_t *input, bool smooth) {
      auto &s = input->scroll;
      const double share = smooth ? wheel_scroll_policy::drag_gain : 1.0;
      int dx = wheel_scroll_policy::drag_step(s.target_x, s.emitted_x, share);
      int dy = wheel_scroll_policy::drag_step(s.target_y, s.emitted_y, share);
      if (!dx && !dy) {
        return false;
      }
      if (!s.began_posted) {
        if (std::abs(dx) >= 2 * std::abs(dy) && std::abs(dy) <= 3) {
          s.target_y -= dy;
          dy = 0;
        } else if (std::abs(dy) >= 2 * std::abs(dx) && std::abs(dx) <= 3) {
          s.target_x -= dx;
          dx = 0;
        }
        if (!dx && !dy) {
          return false;
        }
      }
      const auto phase = !s.began_posted ? kCGScrollPhaseBegan : kCGScrollPhaseChanged;
      post_gesture_event_locked(input, dy, dx, phase, 0);
      s.began_posted = true;
      s.emitted_x += dx;
      s.emitted_y += dy;
      return true;
    }

    std::chrono::milliseconds effective_scroll_idle_timeout(const scroll_engine_state_t &s) noexcept {
      if (s.has_target_loc) {
        return 600ms;
      }
      return std::hypot(s.vx, s.vy) >= 220.0 ? 42ms : 95ms;
    }

    void finish_drag_locked(macos_input_t *input, std::chrono::steady_clock::time_point now, bool immediate_momentum) {
      auto &s = input->scroll;
      s.in_gesture = false;
      post_pending_drag_locked(input, false);
      if (s.began_posted) {
        post_gesture_event_locked(input, 0, 0, kCGScrollPhaseEnded, 0);
      }
      if (s.last_y_event.time_since_epoch().count() == 0 ||
          (s.last_event - s.last_y_event) > 55ms ||
          (now - s.last_y_event) > 105ms) {
        s.vy = 0;
      }
      if (s.last_x_event.time_since_epoch().count() == 0 ||
          (s.last_event - s.last_x_event) > 55ms ||
          (now - s.last_x_event) > 105ms) {
        s.vx = 0;
      }
      if (!s.began_posted || !start_scroll_momentum_locked(input, now, immediate_momentum)) {
        s.clear_velocity();
        if (s.has_target_loc && input->cursor.touch_suppressed) {
          input->cursor.trackpad_scroll_needs_warp = true;
        }
      }
    }

    void post_discrete_wheel_scroll(macos_input_t *macos_input, const int linesY, const int linesX) {
      if (linesY == 0 && linesX == 0) {
        return;
      }
      ensure_event_sources(macos_input);
      const cf_ref_t<CGEventRef> event(CGEventCreateScrollWheelEvent(
        macos_input->source,
        kCGScrollEventUnitLine,
        2,
        linesY,
        linesX
      ));
      if (!event) {
        return;
      }
      CGEventSetIntegerValueField(event.get(), kCGScrollWheelEventIsContinuous, 0);
      CGEventSetFlags(event.get(), macos_input->kb_flags.load(std::memory_order_relaxed));
      CGEventSetTimestamp(event.get(), clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
      CGEventPost(kCGHIDEventTap, event.get());
    }

    bool is_continuous_trackpad_scroll(macos_input_t *macos_input, const int high_res_distance) {
      std::lock_guard lock(macos_input->scroll_mutex);
      auto &s = macos_input->scroll;
      if ((high_res_distance % WHEEL_DELTA) != 0) {
        s.trackpad_continuous_mode = true;
        s.discrete_wheel_streak = 0;
        return true;
      }
      if (s.trackpad_continuous_mode) {
        if (std::abs(high_res_distance) == WHEEL_DELTA) {
          if (++s.discrete_wheel_streak >= 3) {
            s.trackpad_continuous_mode = false;
            return false;
          }
        } else {
          s.discrete_wheel_streak = 0;
        }
        return true;
      }
      return false;
    }

    void wheel_scroll(input_t &input, int high_res_distance, bool horizontal) {
      if (high_res_distance == 0) {
        return;
      }
      auto *macos_input = static_cast<macos_input_t *>(input.get());
      ensure_event_sources(macos_input);
      flush_pending_cursor_restore_for_trackpad(macos_input);
      const double sign = horizontal ? -1.0 : 1.0;
      const double base_pixels = scroll_pixels_exact(macos_input, high_res_distance) * sign;
      if (is_continuous_trackpad_scroll(macos_input, high_res_distance)) {
        const double dx = horizontal ? base_pixels : 0.0;
        const double dy = horizontal ? 0.0 : base_pixels;
        continuous_scroll_delta(macos_input, dy, dx);
      } else {
        abort_continuous_scroll_gesture_without_momentum(macos_input);
        cancel_scroll_momentum(macos_input);
        const int detents = high_res_distance / WHEEL_DELTA;
        const int lines = detents * std::max(1, macos_input->scroll_lines_per_detent) * (horizontal ? -1 : 1);
        post_discrete_wheel_scroll(macos_input, horizontal ? 0 : lines, horizontal ? lines : 0);
      }
    }
  }  // namespace

  int get_scroll_lines_per_detent(double &scrollwheel_scaling) {
    double scale = DEFAULT_SCROLLWHEEL_SCALING;
    if (const cf_ref_t<CFPropertyListRef> value {CFPreferencesCopyValue(
          CFSTR("com.apple.scrollwheel.scaling"),
          kCFPreferencesAnyApplication,
          kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost
        )}) {
      if (CFGetTypeID(value.get()) == CFNumberGetTypeID()) {
        CFNumberGetValue(static_cast<CFNumberRef>(value.get()), kCFNumberDoubleType, &scale);
      } else if (CFGetTypeID(value.get()) == CFStringGetTypeID()) {
        scale = CFStringGetDoubleValue(static_cast<CFStringRef>(value.get()));
      }
    }

    if (!std::isfinite(scale)) {
      scale = DEFAULT_SCROLLWHEEL_SCALING;
    }

    scrollwheel_scaling = scale;
    const auto scroll_scale = std::clamp(scale, 0.0, 1.0);
    constexpr double lines_per_scroll_scale = (DEFAULT_SCROLL_LINES_PER_DETENT - 1.0) / DEFAULT_SCROLLWHEEL_SCALING;
    return std::max(1, static_cast<int>(std::ceil(1.0 + scroll_scale * lines_per_scroll_scale)));
  }

  void cancel_scroll_momentum(macos_input_t *macos_input) {
    std::lock_guard lock(macos_input->scroll_mutex);
    auto &s = macos_input->scroll;
    if (s.in_momentum) {
      const bool had_emitted = !s.momentum_first_tick;
      s.reset_momentum();
      if (had_emitted) {
        post_gesture_event_locked(macos_input, 0, 0, 0, kCGMomentumScrollPhaseEnd);
      }
      if (s.has_target_loc && macos_input->cursor.touch_suppressed) {
        macos_input->cursor.trackpad_scroll_needs_warp = true;
      }
    }
  }

  double current_scroll_momentum_speed(macos_input_t *macos_input) {
    std::lock_guard lock(macos_input->scroll_mutex);
    const auto &s = macos_input->scroll;
    if (!s.in_momentum) {
      return 0.0;
    }
    const auto now = std::chrono::steady_clock::now();
    const double elapsed = std::max(0.0, std::chrono::duration<double>(now - s.mom_start_time).count());
    if (s.mom_ipados_style) {
      return s.mom_v0_speed * std::exp(-2.0 * elapsed);
    }
    const double duration = std::max(0.001, s.mom_duration);
    const double u = std::clamp(1.0 - elapsed / duration, 0.0, 1.0);
    return s.mom_v0_speed * (u * u * u);
  }

  void continuous_scroll_delta(
    macos_input_t *macos_input,
    const double delta_y_px,
    const double delta_x_px,
    const CGPoint *target_loc
  ) {
    if (delta_y_px == 0.0 && delta_x_px == 0.0) {
      return;
    }

    constexpr auto drag_tick_interval = 8333us;
    const auto now = std::chrono::steady_clock::now();
    bool warp_target = false;
    if (target_loc) {
      std::lock_guard lock(macos_input->scroll_mutex);
      warp_target = macos_input->cursor.touch_suppressed &&
                    (!macos_input->scroll.in_gesture || !macos_input->scroll.has_target_loc);
    }
    if (warp_target) {
      CGWarpMouseCursorPosition(*target_loc);
    }
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      auto &s = macos_input->scroll;
      const bool was_in_momentum = s.in_momentum;
      const double mom_age = was_in_momentum ?
                               std::chrono::duration<double>(now - s.mom_start_time).count() :
                               999.0;
      const bool same_dir_continuation =
        was_in_momentum && mom_age <= 0.070 &&
        ((delta_x_px * s.mom_v0_x > 0.0 && std::abs(delta_x_px) >= 1.0) ||
         (delta_y_px * s.mom_v0_y > 0.0 && std::abs(delta_y_px) >= 1.0));

      if (was_in_momentum) {
        const bool had_emitted = !s.momentum_first_tick;
        s.reset_momentum();
        if (had_emitted) {
          post_gesture_event_locked(macos_input, 0, 0, 0, kCGMomentumScrollPhaseEnd);
        }
      }

      if (s.in_gesture && s.has_target_loc != (target_loc != nullptr)) {
        post_pending_drag_locked(macos_input, false);
        if (s.began_posted) {
          post_gesture_event_locked(macos_input, 0, 0, kCGScrollPhaseEnded, 0);
        }
        s.in_gesture = false;
      }
      const bool starting = !s.in_gesture;
      if (starting) {
        s.begin_gesture(now, was_in_momentum, same_dir_continuation);
        if (!target_loc) {
          s.next_drag_tick = now + 2ms;
        }
      }
      s.has_target_loc = (target_loc != nullptr);
      if (target_loc) {
        s.target_loc = *target_loc;
      }

      s.last_event = now;
      ++s.sample_count;

      double raw_dy = delta_y_px;
      double raw_dx = delta_x_px;
      if (starting && s.cancelled_momentum && std::hypot(raw_dx, raw_dy) <= 5.0) {
        raw_dy = 0.0;
        raw_dx = 0.0;
      }

      s.gesture_abs_y += std::abs(raw_dy);
      s.gesture_abs_x += std::abs(raw_dx);
      update_axis_velocity(s.vy, s.peel_used_y, s.last_y_event, now, raw_dy, starting, s.sample_count);
      update_axis_velocity(s.vx, s.peel_used_x, s.last_x_event, now, raw_dx, starting, s.sample_count);

      double eff_dy = raw_dy;
      double eff_dx = raw_dx;
      if (s.gesture_abs_x > 8.0 && s.gesture_abs_x > 2.5 * s.gesture_abs_y && std::abs(eff_dy) <= 3.0) {
        eff_dy = 0.0;
      } else if (s.gesture_abs_y > 8.0 && s.gesture_abs_y > 2.5 * s.gesture_abs_x && std::abs(eff_dx) <= 3.0) {
        eff_dx = 0.0;
      }
      s.target_y += eff_dy;
      s.target_x += eff_dx;

      const bool began = s.began_posted;
      const bool ready_to_emit = target_loc != nullptr ? (!began || now >= s.next_drag_tick) : (now >= s.next_drag_tick);
      if (ready_to_emit && post_pending_drag_locked(macos_input, began)) {
        s.next_drag_tick = now + drag_tick_interval;
      }
      macos_input->scroll_cv.notify_one();
    }
  }

  void finish_continuous_scroll_gesture(macos_input_t *input) {
    std::lock_guard lock(input->scroll_mutex);
    if (input->scroll.in_gesture) {
      finish_drag_locked(input, std::chrono::steady_clock::now(), false);
      input->scroll_cv.notify_one();
    }
  }

  void abort_continuous_scroll_gesture_without_momentum(macos_input_t *input) {
    std::lock_guard lock(input->scroll_mutex);
    auto &s = input->scroll;
    if (s.in_gesture) {
      s.in_gesture = false;
      post_pending_drag_locked(input, false);
      if (s.began_posted) {
        post_gesture_event_locked(input, 0, 0, kCGScrollPhaseCancelled, 0);
      }
      s.clear_velocity();
      if (s.has_target_loc && input->cursor.touch_suppressed) {
        input->cursor.trackpad_scroll_needs_warp = true;
      }
      input->scroll_cv.notify_one();
    }
  }

  void run_scroll_momentum_worker(macos_input_t *macos_input) {
    platf::set_thread_name("input::scrollMomentum");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    platf::adjust_thread_priority(platf::thread_priority_e::critical);

    constexpr auto momentum_tick_interval = 8333us;  // 120Hz

    for (;;) {
      bool do_mom_tick = false;
      bool do_mom_end = false;
      uint32_t mom_phase = 0;
      int step_y = 0;
      int step_x = 0;

      {
        std::unique_lock lock(macos_input->scroll_mutex);
        auto &s = macos_input->scroll;
        macos_input->scroll_cv.wait(lock, [&]() {
          return s.stopping || s.in_gesture || s.in_momentum;
        });
        if (s.stopping) {
          return;
        }

        if (s.in_gesture) {
          const auto gesture_idle_timeout = effective_scroll_idle_timeout(s);
          const auto idle_deadline = s.last_event + gesture_idle_timeout;
          const bool has_pending_drag = (std::llround(s.target_y) != s.emitted_y ||
                                         std::llround(s.target_x) != s.emitted_x);
          const auto wake_deadline = (has_pending_drag && s.next_drag_tick < idle_deadline) ? s.next_drag_tick : idle_deadline;

          macos_input->scroll_cv.wait_until(lock, wake_deadline);
          if (s.stopping) {
            return;
          }
          const auto now = std::chrono::steady_clock::now();
          if (s.in_gesture) {
            const auto idle = effective_scroll_idle_timeout(s);
            if (now >= s.last_event + idle) {
              finish_drag_locked(macos_input, now, true);
            } else if (now >= s.next_drag_tick && post_pending_drag_locked(macos_input, s.began_posted)) {
              s.next_drag_tick += momentum_tick_interval;
              if (s.next_drag_tick <= now) {
                s.next_drag_tick = now + momentum_tick_interval;
              }
            }
          }
        } else if (s.in_momentum) {
          macos_input->scroll_cv.wait_until(lock, s.next_mom_tick);
          if (s.stopping) {
            return;
          }
          const auto now = std::chrono::steady_clock::now();
          if (s.in_momentum && now >= s.next_mom_tick) {
            s.next_mom_tick += momentum_tick_interval;
            if (s.next_mom_tick <= now) {
              s.next_mom_tick = now + momentum_tick_interval;
            }
            const double elapsed = std::max(0.0, std::chrono::duration<double>(now - s.mom_start_time).count());

            double target_x = 0.0;
            double target_y = 0.0;
            bool finished = false;
            if (s.mom_ipados_style) {
              constexpr double k = 2.0;
              const double exp_kt = std::exp(-k * elapsed);
              const double factor = (1.0 - exp_kt) / k;
              target_x = s.mom_v0_x * factor;
              target_y = s.mom_v0_y * factor;
              finished = (s.mom_v0_speed * exp_kt < 42.0);
            } else {
              const double duration = std::max(0.001, s.mom_duration);
              const double t_norm = std::clamp(elapsed / duration, 0.0, 1.0);
              const double u = 1.0 - t_norm;
              const double progress = 1.0 - (u * u * u * u);
              target_x = s.mom_total_x * progress;
              target_y = s.mom_total_y * progress;
              finished = (t_norm >= 1.0);
            }

            step_x = static_cast<int>(std::lround(target_x - s.mom_emitted_x));
            step_y = static_cast<int>(std::lround(target_y - s.mom_emitted_y));
            s.mom_emitted_x += step_x;
            s.mom_emitted_y += step_y;

            if (step_x != 0 || step_y != 0) {
              mom_phase = s.momentum_first_tick ? kCGMomentumScrollPhaseBegin : kCGMomentumScrollPhaseContinue;
              s.momentum_first_tick = false;
              do_mom_tick = true;
            }
            if (finished) {
              do_mom_end = !s.momentum_first_tick;
              s.reset_momentum();
              if (s.has_target_loc && macos_input->cursor.touch_suppressed) {
                macos_input->cursor.trackpad_scroll_needs_warp = true;
              }
            }
          }
          if (do_mom_tick) {
            post_gesture_event_locked(macos_input, step_y, step_x, 0, mom_phase);
          }
          if (do_mom_end) {
            post_gesture_event_locked(macos_input, 0, 0, 0, kCGMomentumScrollPhaseEnd);
          }
        }
      }
    }
  }

  void scroll(input_t &input, const int high_res_distance) {
    wheel_scroll(input, high_res_distance, false);
  }

  void hscroll(input_t &input, int high_res_distance) {
    wheel_scroll(input, high_res_distance, true);
  }

  void post_trackpad_gesture_packets(
    macos_input_t *macos_input,
    const CGPoint &loc,
    const std::vector<macos_input_policy::trackpad_gesture_packet_t> &packets
  ) noexcept {
    if (!macos_input || packets.empty()) {
      return;
    }
    ensure_event_sources(macos_input);
    constexpr auto kEventTypeGesture = static_cast<CGEventType>(29);
    constexpr auto kSubtypeField = static_cast<CGEventField>(110);
    constexpr auto kMagnifyField = static_cast<CGEventField>(113);
    constexpr auto kRotateField = static_cast<CGEventField>(114);
    constexpr auto kPhaseField = static_cast<CGEventField>(132);

    std::lock_guard lock(macos_input->gesture_dispatch_mutex);
    if (!macos_input->reusable_gesture_event) {
      macos_input->reusable_gesture_event.reset(CGEventCreate(macos_input->source));
    }
    const CGEventRef ev = macos_input->reusable_gesture_event.get();
    if (!ev) {
      return;
    }

    bool primed_target = false;
    for (const auto &pkt : packets) {
      if (!macos_input_policy::trackpad_gesture_emitter_t::is_allowed_packet(pkt)) {
        continue;
      }
      if (!primed_target &&
          pkt.phase == macos_input_policy::trackpad_gesture_emitter_t::phase_began &&
          !is_pen_tip_guard_active(macos_input)) {
        primed_target = true;
        CGWarpMouseCursorPosition(loc);
        CGAssociateMouseAndMouseCursorPosition(true);
        if (const cf_ref_t<CGEventRef> mv {
              CGEventCreateMouseEvent(macos_input->source, kCGEventMouseMoved, loc, kCGMouseButtonLeft)
            }) {
          CGEventSetIntegerValueField(mv.get(), kCGMouseEventClickState, 0);
          CGEventSetFlags(mv.get(), macos_input->kb_flags.load(std::memory_order_relaxed));
          CGEventSetTimestamp(mv.get(), clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
          CGEventPost(kCGHIDEventTap, mv.get());
        }
      }
      CGEventSetType(ev, kEventTypeGesture);
      CGEventSetLocation(ev, loc);
      CGEventSetFlags(ev, macos_input->kb_flags.load(std::memory_order_relaxed));
      CGEventSetIntegerValueField(ev, kSubtypeField, pkt.subtype);
      CGEventSetIntegerValueField(ev, kPhaseField, pkt.phase);
      const auto field_write = macos_input_policy::trackpad_gesture_emitter_t::resolve_value_field_write(pkt);
      CGEventSetDoubleValueField(
        ev,
        field_write.slot == macos_input_policy::cg_gesture_value_slot_e::rotate_114 ? kRotateField : kMagnifyField,
        field_write.value
      );
      CGEventSetTimestamp(ev, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
      CGEventPost(kCGHIDEventTap, ev);
    }
  }

  void mac_trackpad_gesture(input_t &input, const mac_trackpad_gesture_t &gesture) {
    auto *macos_input = static_cast<macos_input_t *>(input.get());
    if (!macos_input || !config::input.mouse) {
      return;
    }
    if (is_pen_tip_guard_active(macos_input) &&
        gesture.phase != input::voidlink::mac_gesture_end &&
        gesture.phase != input::voidlink::mac_gesture_cancel) {
      return;
    }
    using emitter_t = macos_input_policy::trackpad_gesture_emitter_t;
    const std::int64_t subtype = gesture.is_rotate ? emitter_t::subtype_rotate : emitter_t::subtype_magnify;

    ensure_event_sources(macos_input);
    flush_pending_cursor_restore_for_trackpad(macos_input);
    const auto pt = consume_trackpad_cursor_loc(input);
    const CGPoint loc = CGPointMake(pt.x, pt.y);

    if (gesture.phase == input::voidlink::mac_gesture_begin) {
      abort_continuous_scroll_gesture_without_momentum(macos_input);
      cancel_scroll_momentum(macos_input);
      bool show_cursor = false;
      {
        std::lock_guard lock(macos_input->scroll_mutex);
        auto &c = macos_input->cursor;
        if (c.touch_suppressed) {
          c.touch_suppressed = false;
          show_cursor = true;
        }
      }
      if (show_cursor) {
        macos_pen_hover_cursor_hide();
        macos_sc_set_cursor_visible(true);
      }
    }

    std::vector<macos_input_policy::trackpad_gesture_packet_t> pkts;
    {
      std::lock_guard lock(macos_input->gesture_emitter_mutex);
      if (gesture.phase == input::voidlink::mac_gesture_begin) {
        pkts = macos_input->trackpad_gesture_emitter.begin(subtype);
      } else if (gesture.phase == input::voidlink::mac_gesture_change) {
        pkts = macos_input->trackpad_gesture_emitter.change(subtype, gesture.amount);
      } else if (gesture.phase == input::voidlink::mac_gesture_end) {
        pkts = macos_input->trackpad_gesture_emitter.end(subtype, false);
      } else if (gesture.phase == input::voidlink::mac_gesture_cancel) {
        pkts = macos_input->trackpad_gesture_emitter.end(subtype, true);
      }
    }
    if (!pkts.empty()) {
      post_trackpad_gesture_packets(macos_input, loc, pkts);
    }
  }
}  // namespace platf
