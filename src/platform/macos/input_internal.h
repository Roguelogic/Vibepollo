/**
 * @file src/platform/macos/input_internal.h
 * @brief Internal shared state and cross-translation-unit helpers for macOS input modules.
 */
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

#include <ApplicationServices/ApplicationServices.h>

#include "src/platform/common.h"
#include "src/platform/macos/cf_guard.h"
#include "src/platform/macos/palm_rejection.h"
#include "src/utility.h"

namespace platf {
  inline constexpr std::chrono::milliseconds MULTICLICK_DELAY_MS {500};
  inline constexpr int WHEEL_DELTA = 120;
  inline constexpr double DEFAULT_SCROLLWHEEL_SCALING = 0.3125;
  inline constexpr int DEFAULT_SCROLL_LINES_PER_DETENT = 5;

  struct scroll_engine_state_t {
    bool stopping {};
    bool in_gesture {};
    bool began_posted {};
    bool in_momentum {};
    bool momentum_first_tick {};
    bool cancelled_momentum {};
    bool trackpad_continuous_mode {true};
    int discrete_wheel_streak {};
    int sample_count {};
    bool peel_used_x {};
    bool peel_used_y {};
    double target_x {};
    double target_y {};
    std::int64_t emitted_x {};
    std::int64_t emitted_y {};
    double gesture_abs_x {};
    double gesture_abs_y {};
    double vx {};  ///< Pixels/sec horizontal velocity
    double vy {};  ///< Pixels/sec vertical velocity
    bool mom_ipados_style {};  ///< false = MacBook quartic, true = iPadOS exponential
    double mom_v0_x {};
    double mom_v0_y {};
    double mom_v0_speed {};
    double mom_duration {};
    double mom_total_x {};
    double mom_total_y {};
    double mom_emitted_x {};
    double mom_emitted_y {};
    CGPoint momentum_anchor {};
    bool has_momentum_anchor {};
    bool has_target_loc {};
    CGPoint target_loc {};
    std::chrono::steady_clock::time_point last_event {};
    std::chrono::steady_clock::time_point last_x_event {};
    std::chrono::steady_clock::time_point last_y_event {};
    std::chrono::steady_clock::time_point next_drag_tick {};
    std::chrono::steady_clock::time_point mom_start_time {};
    std::chrono::steady_clock::time_point next_mom_tick {};

    void clear_velocity() noexcept {
      vx = 0.0;
      vy = 0.0;
    }

    void reset_momentum() noexcept {
      in_momentum = false;
      has_momentum_anchor = false;
      clear_velocity();
      mom_v0_x = 0.0;
      mom_v0_y = 0.0;
      mom_v0_speed = 0.0;
      mom_duration = 0.0;
      mom_total_x = 0.0;
      mom_total_y = 0.0;
      mom_emitted_x = 0.0;
      mom_emitted_y = 0.0;
    }

    void begin_gesture(
      const std::chrono::steady_clock::time_point now,
      const bool was_in_momentum,
      const bool same_dir_continuation
    ) noexcept {
      in_gesture = true;
      began_posted = false;
      cancelled_momentum = was_in_momentum && !same_dir_continuation;
      sample_count = 0;
      peel_used_x = false;
      peel_used_y = false;
      target_x = 0.0;
      target_y = 0.0;
      emitted_x = 0;
      emitted_y = 0;
      if (!same_dir_continuation) {
        gesture_abs_x = 0.0;
        gesture_abs_y = 0.0;
      }
      clear_velocity();
      last_x_event = {};
      last_y_event = {};
      next_drag_tick = now;
    }
  };

  struct cursor_visibility_state_t {
    bool touch_suppressed {};
    bool has_saved_trackpad_cursor {};
    CGPoint saved_trackpad_cursor {};
    bool trackpad_scroll_needs_warp {};
    util::point_t last_cursor_loc {};
    bool has_cursor_loc {};
    std::chrono::steady_clock::time_point last_cursor_update {};
  };

  struct display_geometry_t {
    CGDirectDisplayID id {kCGNullDirectDisplay};
    CGRect bounds {};
    CGFloat scaling {1.0};
  };

  struct macos_input_t {
    CGDirectDisplayID configured_display {};
    std::mutex display_mutex;
    CGDirectDisplayID display {};
    CGRect displayBounds {};
    CGFloat displayScaling {};
    CGFloat displayBoundsWidth {};
    std::uint64_t displayGeneration {UINT64_MAX};

    std::mutex source_mutex;
    CGEventSourceRef source {};

    // Keyboard state
    std::mutex keyboard_mutex;
    CGEventSourceRef keyboard_source {};
    std::atomic<CGEventFlags> kb_flags {0};
    std::chrono::steady_clock::time_point capslock_down_time {};

    // Mouse state
    std::mutex mouse_mutex;
    CGEventRef mouse_event {};
    std::chrono::steady_clock::time_point last_mouse_warp {};
    double scrollwheel_scaling {DEFAULT_SCROLLWHEEL_SCALING};
    int scroll_lines_per_detent {DEFAULT_SCROLL_LINES_PER_DETENT};
    bool mouse_down[5] {};
    int mouse_click_count[5] {};
    std::chrono::steady_clock::time_point last_mouse_down_time[5] {};
    util::point_t last_mouse_down_pos[5] {};

    // Continuous trackpad scroll, 120Hz momentum & cursor visibility state
    std::mutex scroll_mutex;
    std::condition_variable scroll_cv;
    std::thread scroll_thread;
    scroll_engine_state_t scroll {};
    cursor_visibility_state_t cursor {};

    // Client-recognized hardware trackpad pinch/rotate state
    std::mutex gesture_emitter_mutex;
    macos_input_policy::trackpad_gesture_emitter_t trackpad_gesture_emitter {};
    std::mutex gesture_dispatch_mutex;
    cf_ref_t<CGEventRef> reusable_gesture_event {};

    // Active Apple Pencil tip contact guard: prevents stray mouse/trackpad moves
    // from injecting default-subtype (pressure=1.0) drags mid-stroke.
    std::atomic<bool> pen_tip_active {false};
    std::atomic<std::int64_t> pen_tip_last_activity_ns {0};
  };

  // --- Core input helpers (input.cpp) ---

  bool is_pen_tip_guard_active(const macos_input_t *macos_input) noexcept;
  void ensure_event_sources(macos_input_t *macos_input);
  CGPoint clamp_point_to_bounds(const CGPoint &point, const CGRect &bounds) noexcept;
  CGRect target_display_bounds(macos_input_t *macos_input, const CGPoint &point);
  CGPoint stream_location(macos_input_t *macos_input, const touch_port_t &touch_port, float x, float y);
  void suppress_cursor_for_touch_or_pen(macos_input_t *macos_input, bool keep_pen_reticle);
  void show_pen_hover_reticle(macos_input_t *macos_input, const CGPoint &location, float distance_norm, bool eraser);
  util::point_t consume_trackpad_cursor_loc(input_t &input);
  void flush_pending_cursor_restore_for_trackpad(macos_input_t *macos_input);

  // --- Scroll momentum & trackpad gesture helpers (input_scroll.cpp) ---

  int get_scroll_lines_per_detent(double &scrollwheel_scaling);
  void cancel_scroll_momentum(macos_input_t *macos_input);
  double current_scroll_momentum_speed(macos_input_t *macos_input);
  void continuous_scroll_delta(macos_input_t *macos_input, double delta_y_px, double delta_x_px, const CGPoint *target_loc = nullptr);
  void finish_continuous_scroll_gesture(macos_input_t *input);
  void abort_continuous_scroll_gesture_without_momentum(macos_input_t *input);
  void run_scroll_momentum_worker(macos_input_t *macos_input);
  void post_trackpad_gesture_packets(
    macos_input_t *macos_input,
    const CGPoint &loc,
    const std::vector<macos_input_policy::trackpad_gesture_packet_t> &packets
  ) noexcept;
}  // namespace platf
