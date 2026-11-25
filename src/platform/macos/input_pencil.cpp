/**
 * @file src/platform/macos/input_pencil.cpp
 * @brief Per-client Apple Pencil (Wacom-grade tablet & scroll modes) and minimal standard touch backend.
 */
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <ctime>
#include <map>
#include <memory>
#include <mutex>
#include <vector>

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>

#include "src/config.h"
#include "src/platform/common.h"
#include "src/platform/macos/cf_guard.h"
#include "src/platform/macos/input_internal.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/palm_rejection.h"
#include "src/platform/macos/sc_video.h"
#include "src/voidlink_protocol.h"

namespace platf {
  using namespace std::literals;

  /**
   * @brief Per-client Apple Pencil and minimal standard touch context.
   *
   * Apple Pencil is injected via macOS public tablet proximity & tablet-point `CGEvent`s.
   * Finger touch is intended to be handled by the client app's native Trackpad/Mouse mode;
   * if raw `SS_TOUCH_MAGIC` packets arrive, a minimal unambiguous standard mapping is used
   * (tap = click, long-press + move = drag, immediate move = scroll, two-finger tap = right-click).
   */
  class macos_client_input_t: public client_input_t {
  public:
    explicit macos_client_input_t(macos_input_t *macos_input):
        macos_input {macos_input} {
    }

    ~macos_client_input_t() override {
      leave_pen_hover();
      pen_scroll_release();
      pen_release();
      touch_release();
      abort_continuous_scroll_gesture_without_momentum(macos_input);
      cancel_scroll_momentum(macos_input);
      std::vector<macos_input_policy::trackpad_gesture_packet_t> cancel_pkts;
      {
        std::lock_guard lock(macos_input->gesture_emitter_mutex);
        cancel_pkts = macos_input->trackpad_gesture_emitter.cancel_all();
      }
      CGPoint cancel_loc {};
      {
        std::lock_guard lock(macos_input->scroll_mutex);
        auto &c = macos_input->cursor;
        cancel_loc = CGPointMake(c.last_cursor_loc.x, c.last_cursor_loc.y);
        c.touch_suppressed = false;
        c.trackpad_scroll_needs_warp = false;
      }
      if (!cancel_pkts.empty()) {
        post_trackpad_gesture_packets(macos_input, cancel_loc, cancel_pkts);
      }
      macos_pen_hover_cursor_hide();
      macos_sc_set_cursor_visible(true);
    }

    void pen_update(const touch_port_t &touch_port, const pen_input_t &pen);
    void pencil_side_button(const touch_port_t &touch_port, const pencil_side_button_input_t &btn);
    void touch_update(const touch_port_t &touch_port, const touch_input_t &touch);

  private:
    enum pen_button_e {
      PEN_TIP,
      PEN_PRIMARY,
      PEN_SECONDARY,
      PEN_TERTIARY,
      PEN_BUTTON_COUNT
    };

    enum class contact_mode_e : std::uint8_t {
      idle,
      undecided,
      scrolling,
      dragging,
    };

    struct touch_point_t {
      CGPoint start;
      CGPoint last;
      std::chrono::steady_clock::time_point down_time;
    };

    static constexpr double TOUCH_SLOP = 6.0;
    static constexpr double PEN_SLOP = 8.0;
    static constexpr std::chrono::milliseconds LONG_PRESS {350};
    static constexpr std::chrono::milliseconds PEN_DRAG_HOLD {300};
    static constexpr double MULTICLICK_DISTANCE = 8.0;
    static constexpr int POINTER_PEN = 1;     // NX_TABLET_POINTER_PEN
    static constexpr int POINTER_ERASER = 3;  // NX_TABLET_POINTER_ERASER
    static constexpr int TABLET_CAPABILITIES = 0x0001 | 0x0040 | 0x0080 | 0x0100 | 0x0400 | 0x2000;

    static CGMouseButton mouse_button(const int pen_button) {
      switch (pen_button) {
        case PEN_TIP:
          return kCGMouseButtonLeft;
        case PEN_PRIMARY:
          return kCGMouseButtonRight;
        case PEN_SECONDARY:
          return kCGMouseButtonCenter;
        default:
          return static_cast<CGMouseButton>(3);
      }
    }

    static CGEventType button_event(const int pen_button, const bool down, const bool dragged) {
      switch (pen_button) {
        case PEN_TIP:
          return dragged ? kCGEventLeftMouseDragged : (down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp);
        case PEN_PRIMARY:
          return dragged ? kCGEventRightMouseDragged : (down ? kCGEventRightMouseDown : kCGEventRightMouseUp);
        default:
          return dragged ? kCGEventOtherMouseDragged : (down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp);
      }
    }

    CGPoint clamp_to_display(const CGPoint &point) const {
      return clamp_point_to_bounds(point, target_display_bounds(macos_input, point));
    }

    void post_event(CGEventRef event) const {
      CGEventSetFlags(event, macos_input->kb_flags.load(std::memory_order_relaxed));
      CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
      CGEventPost(kCGHIDEventTap, event);
      CFRelease(event);
    }

    void post_mouse_event(
      const CGEventType type,
      const CGMouseButton button,
      const CGPoint &location,
      const int click_count,
      const pen_input_t *pen = nullptr,
      const bool sync_cursor = false
    ) {
      ensure_event_sources(macos_input);
      const bool is_down = (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown);
      const bool location_changed = !have_location || location.x != last_location.x || location.y != last_location.y;
      if ((is_down || type == kCGEventMouseMoved) && location_changed) {
        CGWarpMouseCursorPosition(location);
      }

      const double delta_x = (!is_down && have_location) ? (location.x - last_location.x) : 0.0;
      const double delta_y = (!is_down && have_location) ? (location.y - last_location.y) : 0.0;

      if (!pen) {
        if (!reusable_mouse_event_) {
          reusable_mouse_event_.reset(CGEventCreate(macos_input->source));
        }
        const CGEventRef reused = reusable_mouse_event_.get();
        if (!reused) {
          return;
        }
        CGEventSetType(reused, type);
        CGEventSetLocation(reused, location);
        CGEventSetIntegerValueField(reused, kCGMouseEventButtonNumber, button);
        CGEventSetIntegerValueField(reused, kCGMouseEventClickState, click_count);
        CGEventSetDoubleValueField(reused, kCGMouseEventDeltaX, delta_x);
        CGEventSetDoubleValueField(reused, kCGMouseEventDeltaY, delta_y);
        CGEventSetIntegerValueField(reused, kCGMouseEventSubtype, kCGEventMouseSubtypeDefault);
        CGEventSetFlags(reused, macos_input->kb_flags.load(std::memory_order_relaxed));
        CGEventSetTimestamp(reused, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        CGEventPost(kCGHIDEventTap, reused);
      } else {
        const auto event = CGEventCreateMouseEvent(macos_input->source, type, location, button);
        if (!event) {
          return;
        }

        CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_count);
        CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, delta_x);
        CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, delta_y);

        double tilt_x = 0.0;
        double tilt_y = 0.0;
        if (pen->tilt != LI_TILT_UNKNOWN && pen->rotation != LI_ROT_UNKNOWN) {
          const auto rotation = pen->rotation * (M_PI / 180.0);
          const auto tilt = pen->tilt * (M_PI / 180.0);
          const auto r = std::sin(tilt);
          const auto z = std::cos(tilt);
          tilt_x = std::atan2(std::sin(-rotation) * r, z) / (M_PI / 2.0);
          tilt_y = std::atan2(std::cos(-rotation) * r, z) / (M_PI / 2.0);
        }

        int buttons = 0;
        for (int i = 0; i < PEN_BUTTON_COUNT; ++i) {
          if (pen_down[i]) {
            buttons |= 1 << i;
          }
        }

        CGEventSetIntegerValueField(event, kCGMouseEventSubtype, kCGEventMouseSubtypeTabletPoint);
        CGEventSetIntegerValueField(event, kCGTabletEventPointButtons, buttons);
        const bool tip_pressed = pen_down[PEN_TIP] &&
                                 type != kCGEventLeftMouseUp &&
                                 pen->eventType != LI_TOUCH_EVENT_UP &&
                                 pen->eventType != LI_TOUCH_EVENT_HOVER;
        double pressure = 0.0;
        if (!tip_pressed) {
          if (!pen_down[PEN_TIP] || type == kCGEventLeftMouseUp || pen->eventType == LI_TOUCH_EVENT_UP) {
            pen_pressure_sanitizer.end_stroke();
          }
          pressure = 0.0;
        } else if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseDragged) {
          pressure = pen_pressure_sanitizer.resolve(
            true,
            pen->pressureOrDistance,
            pen->pressure_invalid,
            pen->eventType == LI_TOUCH_EVENT_BUTTON_ONLY,
            pen->tilt
          );
        } else {
          pressure = pen_pressure_sanitizer.last_pressure();
        }
        CGEventSetDoubleValueField(event, kCGTabletEventPointPressure, pressure);
        CGEventSetDoubleValueField(event, kCGMouseEventPressure, pressure);
        CGEventSetDoubleValueField(event, kCGTabletEventTiltX, tilt_x);
        CGEventSetDoubleValueField(event, kCGTabletEventTiltY, tilt_y);
        const auto effective_rotation = pen_roll_probe.select(pen->barrelRoll, pen->rotation);
        CGEventSetDoubleValueField(event, kCGTabletEventRotation, effective_rotation == LI_ROT_UNKNOWN ? 0.0 : effective_rotation);
        CGEventSetIntegerValueField(event, kCGTabletEventDeviceID, pen_pointer);

        post_event(event);
      }

      if (sync_cursor) {
        const auto now_sync = std::chrono::steady_clock::now();
        bool show_cursor = false;
        {
          std::lock_guard lock(macos_input->scroll_mutex);
          auto &c = macos_input->cursor;
          c.last_cursor_loc = {location.x, location.y};
          c.has_cursor_loc = true;
          c.last_cursor_update = now_sync;
          c.saved_trackpad_cursor = location;
          c.has_saved_trackpad_cursor = true;
          if (c.touch_suppressed) {
            c.touch_suppressed = false;
            show_cursor = true;
          }
        }
        if (show_cursor) {
          macos_sc_set_cursor_visible(true);
        }
      }
      last_location = location;
      have_location = true;
    }

    void post_proximity(const bool enter) const {
      const auto event = CGEventCreate(macos_input->source);
      if (!event) {
        return;
      }
      CGEventSetType(event, kCGEventTabletProximity);
      CGEventSetIntegerValueField(event, kCGTabletProximityEventEnterProximity, enter);
      CGEventSetIntegerValueField(event, kCGTabletProximityEventPointerType, pen_pointer);
      CGEventSetIntegerValueField(event, kCGTabletProximityEventDeviceID, pen_pointer);
      CGEventSetIntegerValueField(event, kCGTabletProximityEventPointerID, pen_pointer);
      CGEventSetIntegerValueField(event, kCGTabletProximityEventSystemTabletID, 1);
      CGEventSetIntegerValueField(event, kCGTabletProximityEventTabletID, 1);
      CGEventSetIntegerValueField(event, kCGTabletProximityEventCapabilityMask, TABLET_CAPABILITIES);
      post_event(event);
    }

    void set_pen_tip_down(const bool down) noexcept {
      pen_down[PEN_TIP] = down;
      if (macos_input) {
        if (down) {
          macos_input->pen_tip_last_activity_ns.store(
            static_cast<std::int64_t>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)),
            std::memory_order_relaxed
          );
          macos_input->pen_tip_active.store(true, std::memory_order_release);
        } else {
          macos_input->pen_tip_active.store(false, std::memory_order_release);
        }
      }
    }

    void touch_pen_tip_activity() const noexcept {
      if (macos_input && pen_down[PEN_TIP]) {
        macos_input->pen_tip_last_activity_ns.store(
          static_cast<std::int64_t>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)),
          std::memory_order_relaxed
        );
      }
    }

    void pen_release() {
      macos_pen_hover_cursor_hide();
      pen_squeeze_primary_down = false;
      pen_draw_saw_air_hover = false;
      pen_draw_air_hover_during_contact = 0;
      pen_pressure_sanitizer.end_stroke();
      if (!pen_in_proximity) {
        set_pen_tip_down(false);
        return;
      }

      pen_input_t pen {};
      pen.tilt = LI_TILT_UNKNOWN;
      pen.rotation = LI_ROT_UNKNOWN;
      for (int i = PEN_BUTTON_COUNT - 1; i >= 0; --i) {
        if (pen_down[i]) {
          if (i == PEN_TIP) {
            set_pen_tip_down(false);
          } else {
            pen_down[i] = false;
          }
          post_mouse_event(button_event(i, false, false), mouse_button(i), last_location, i == PEN_TIP ? pen_click_count : 1, &pen, true);
        }
      }
      set_pen_tip_down(false);
      post_proximity(false);
      pen_in_proximity = false;
    }

    void ensure_pen_proximity(const std::uint8_t tool_type) {
      const int pointer = tool_type == LI_TOOL_TYPE_ERASER ? POINTER_ERASER : POINTER_PEN;
      if (pen_in_proximity && pointer != pen_pointer) {
        post_proximity(false);
        pen_in_proximity = false;
      }
      if (!pen_in_proximity) {
        pen_pointer = pointer;
        pen_in_proximity = true;
        post_proximity(true);
      }
    }

    void leave_pen_hover() {
      pen_hover_active = false;
      pen_hover_primary_down = false;
      macos_pen_hover_cursor_hide();
      if (pen_in_proximity &&
          !pen_down[PEN_TIP] && !pen_down[PEN_PRIMARY] && !pen_down[PEN_SECONDARY] && !pen_down[PEN_TERTIARY]) {
        post_proximity(false);
        pen_in_proximity = false;
      }
    }

    void pen_scroll_release() {
      leave_pen_hover();
      if (pen_scroll_mode_ == contact_mode_e::idle) {
        return;
      }
      if (pen_scroll_mode_ == contact_mode_e::dragging) {
        set_pen_tip_down(false);
        post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, last_location, 1);
      } else if (pen_scroll_mode_ == contact_mode_e::scrolling) {
        finish_continuous_scroll_gesture(macos_input);
      }
      pen_scroll_mode_ = contact_mode_e::idle;
      pen_caught_momentum = false;
      pen_air_hover_during_contact = 0;
    }

    void begin_pen_scroll_contact(const CGPoint &location, const std::chrono::steady_clock::time_point now) {
      suppress_cursor_for_touch_or_pen(macos_input, false);
      pen_caught_momentum = (current_scroll_momentum_speed(macos_input) >= 90.0);
      cancel_scroll_momentum(macos_input);
      pen_scroll_mode_ = contact_mode_e::undecided;
      pen_air_hover_during_contact = 0;
      pen_last_contact_time = now;
      pen_start = location;
      pen_last = location;
      pen_down_time = now;
      touch_scroll_origin = location;
      scroll_remainder_x = 0;
      scroll_remainder_y = 0;
    }

    void move_pen_scroll_contact(
      const CGPoint &location,
      const std::chrono::steady_clock::time_point now,
      const pen_input_t &pen
    ) {
      const double delta_x = location.x - pen_last.x;
      const double delta_y = location.y - pen_last.y;
      pen_last = location;

      if (pen_scroll_mode_ == contact_mode_e::scrolling) {
        scroll_remainder_x += delta_x;
        scroll_remainder_y += delta_y;
        scroll_by_remainder();
      } else if (pen_scroll_mode_ == contact_mode_e::dragging) {
        set_pen_tip_down(true);
        if (!have_location || location.x != last_location.x || location.y != last_location.y) {
          post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
        }
      } else if (pen_scroll_mode_ == contact_mode_e::undecided &&
                 std::hypot(location.x - pen_start.x, location.y - pen_start.y) > PEN_SLOP) {
        const bool drag_intent = (pen.penButtons & LI_PEN_BUTTON_PRIMARY) != 0 || (now - pen_down_time) >= PEN_DRAG_HOLD;
        macos_pen_hover_cursor_hide();
        if (drag_intent) {
          pen_scroll_mode_ = contact_mode_e::dragging;
          set_pen_tip_down(true);
          post_mouse_event(kCGEventLeftMouseDown, kCGMouseButtonLeft, pen_start, 1);
          post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
        } else {
          pen_scroll_mode_ = contact_mode_e::scrolling;
          scroll_remainder_x += location.x - pen_start.x;
          scroll_remainder_y += location.y - pen_start.y;
          scroll_by_remainder();
        }
      }
    }

    void finish_pen_scroll_contact(const CGPoint &location, const pen_input_t &pen) {
      const contact_mode_e prev_mode = pen_scroll_mode_;
      const bool was_catching_momentum = pen_caught_momentum;
      const bool held = (std::chrono::steady_clock::now() - pen_down_time) >= LONG_PRESS;
      const CGPoint start = pen_start;

      pen_scroll_mode_ = contact_mode_e::idle;
      pen_caught_momentum = false;
      pen_air_hover_during_contact = 0;
      set_pen_tip_down(false);
      macos_pen_hover_cursor_hide();

      if (prev_mode == contact_mode_e::dragging) {
        if (!have_location || location.x != last_location.x || location.y != last_location.y) {
          post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
        }
        post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, location, 1);
      } else if (prev_mode == contact_mode_e::scrolling) {
        finish_continuous_scroll_gesture(macos_input);
      } else if (prev_mode == contact_mode_e::undecided) {
        if ((pen.penButtons & LI_PEN_BUTTON_PRIMARY) != 0 || held) {
          touch_right_click(start, false);
        } else if (!was_catching_momentum) {
          touch_click(start, false);
        }
      }
    }

    void pen_scroll_mode_update(const touch_port_t &touch_port, const pen_input_t &pen);

    void touch_right_click(const CGPoint &location, const bool keep_pen_reticle = false) {
      suppress_cursor_for_touch_or_pen(macos_input, keep_pen_reticle);
      if (keep_pen_reticle) {
        macos_pen_hover_cursor_show(location.x, location.y, 0.0f, false);
      }
      post_mouse_event(kCGEventRightMouseDown, kCGMouseButtonRight, location, 1);
      post_mouse_event(kCGEventRightMouseUp, kCGMouseButtonRight, location, 1);
    }

    void touch_click(const CGPoint &location, const bool keep_pen_reticle = false) {
      const auto now = std::chrono::steady_clock::now();
      const bool near = std::hypot(location.x - last_tap.x, location.y - last_tap.y) <= MULTICLICK_DISTANCE;
      tap_count = (now - last_tap_time < MULTICLICK_DELAY_MS && near) ? tap_count + 1 : 1;
      last_tap = location;
      last_tap_time = now;

      suppress_cursor_for_touch_or_pen(macos_input, keep_pen_reticle);
      if (keep_pen_reticle) {
        macos_pen_hover_cursor_show(location.x, location.y, 0.0f, false);
      }
      post_mouse_event(kCGEventLeftMouseDown, kCGMouseButtonLeft, location, tap_count);
      post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, location, tap_count);
    }

    void scroll_by_remainder() {
      const double dx = scroll_remainder_x;
      const double dy = scroll_remainder_y;
      scroll_remainder_x = 0;
      scroll_remainder_y = 0;
      continuous_scroll_delta(macos_input, dy, dx, &touch_scroll_origin);
    }

    void touch_release() {
      if (touch_mode_ == contact_mode_e::dragging) {
        post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, last_location, 1);
      } else if (touch_mode_ == contact_mode_e::scrolling) {
        abort_continuous_scroll_gesture_without_momentum(macos_input);
      }
      touch_mode_ = contact_mode_e::idle;
      touch_caught_momentum = false;
      two_finger_tap_candidate = false;
      touch_points.clear();
    }

    void note_pen_activity_for_palm_rejection(
      const std::chrono::steady_clock::time_point now,
      const bool tip_down
    ) {
      palm_rejection.note_pen_activity(now, tip_down);
      if (config::get_macos_palm_rejection() && !touch_points.empty()) {
        touch_release();
      }
    }

    void note_pen_leave_for_palm_rejection(const std::chrono::steady_clock::time_point now) {
      palm_rejection.note_pen_leave(now);
    }

    bool use_pen_draw_mode() const noexcept {
      switch (config::get_macos_pencil_mode()) {
        case config::macos_pencil_mode_e::draw:
          return true;
        case config::macos_pencil_mode_e::scroll:
          return false;
        case config::macos_pencil_mode_e::follow_client:
          return client_voidlink_pen;
      }
      return client_voidlink_pen;
    }

    macos_input_t *macos_input;
    CGPoint last_location {};
    bool have_location {};
    CGPoint touch_scroll_origin {};
    cf_ref_t<CGEventRef> reusable_mouse_event_ {};

    // Apple Pencil state
    bool pen_in_proximity {};
    int pen_pointer {POINTER_PEN};
    bool pen_down[PEN_BUTTON_COUNT] {};
    int pen_click_count {1};
    CGPoint last_pen_down {};
    std::chrono::steady_clock::time_point last_pen_down_time {};

    contact_mode_e pen_scroll_mode_ {contact_mode_e::idle};
    bool pen_caught_momentum {};
    int pen_air_hover_during_contact {};
    bool pen_hover_active {};
    bool pen_hover_primary_down {};
    CGPoint last_hover_location {};
    std::uint8_t last_hover_tilt {LI_TILT_UNKNOWN};
    std::uint16_t last_hover_rotation {LI_ROT_UNKNOWN};
    CGPoint pen_start {};
    CGPoint pen_last {};
    std::chrono::steady_clock::time_point pen_down_time {};
    std::chrono::steady_clock::time_point pen_last_contact_time {};
    std::chrono::steady_clock::time_point pen_last_up_time {};
    std::chrono::steady_clock::time_point last_hover_post_time {};

    input::voidlink::roll_probe_t pen_roll_probe {};
    bool client_voidlink_pen {};
    bool pen_eraser_latched {};
    bool pen_squeeze_primary_down {};
    bool pen_draw_saw_air_hover {};
    int pen_draw_air_hover_during_contact {};
    std::chrono::steady_clock::time_point pen_draw_last_contact_time {};
    std::chrono::steady_clock::time_point pen_draw_last_up_time {};
    macos_input_policy::pen_pressure_sanitizer_t pen_pressure_sanitizer {};

    // Minimal standard touch state
    std::map<std::uint32_t, touch_point_t> touch_points;
    contact_mode_e touch_mode_ {contact_mode_e::idle};
    bool touch_caught_momentum {};
    bool two_finger_tap_candidate {};
    std::chrono::steady_clock::time_point two_finger_down_time {};
    macos_input_policy::palm_rejection_tracker_t palm_rejection {};
    double scroll_remainder_x {};
    double scroll_remainder_y {};
    int tap_count {1};
    CGPoint last_tap {};
    std::chrono::steady_clock::time_point last_tap_time {};
  };

  void macos_client_input_t::pen_scroll_mode_update(const touch_port_t &touch_port, const pen_input_t &pen) {
    const auto now = std::chrono::steady_clock::now();
    const auto location = clamp_to_display(stream_location(macos_input, touch_port, pen.x * touch_port.width, pen.y * touch_port.height));

    switch (pen.eventType) {
      case LI_TOUCH_EVENT_CANCEL:
      case LI_TOUCH_EVENT_CANCEL_ALL:
        note_pen_leave_for_palm_rejection(now);
        pen_scroll_release();
        return;

      case LI_TOUCH_EVENT_HOVER_LEAVE:
        note_pen_leave_for_palm_rejection(now);
        if (pen_scroll_mode_ != contact_mode_e::idle) {
          finish_pen_scroll_contact(pen_last, pen);
        }
        leave_pen_hover();
        return;

      case LI_TOUCH_EVENT_HOVER: {
        note_pen_activity_for_palm_rejection(now, false);
        if (pen_scroll_mode_ != contact_mode_e::idle) {
          ++pen_air_hover_during_contact;
          const auto since_contact = std::chrono::duration_cast<std::chrono::milliseconds>(now - pen_last_contact_time);
          if (macos_input_policy::should_finish_pen_contact_on_hover(
                pen.pressureOrDistance,
                pen_air_hover_during_contact,
                since_contact
              )) {
            finish_pen_scroll_contact(pen_last, pen);
          }
          if (pen_scroll_mode_ != contact_mode_e::idle) {
            return;
          }
        }

        if (pen.pressureOrDistance <= 0.0005f &&
            pen_last_up_time.time_since_epoch().count() != 0 &&
            (now - pen_last_up_time) < 25ms) {
          return;
        }

        show_pen_hover_reticle(
          macos_input,
          location,
          std::max(0.0f, pen.pressureOrDistance),
          pen.toolType == LI_TOOL_TYPE_ERASER
        );
        ensure_pen_proximity(pen.toolType);
        const bool first_hover = !pen_hover_active;
        const bool changed = first_hover ||
                             std::hypot(location.x - last_hover_location.x, location.y - last_hover_location.y) >= 0.05 ||
                             pen.tilt != last_hover_tilt ||
                             pen.rotation != last_hover_rotation;
        if (changed &&
            (first_hover || last_hover_post_time.time_since_epoch().count() == 0 ||
             (now - last_hover_post_time) >= std::chrono::microseconds(7000))) {
          pen_hover_active = true;
          last_hover_location = location;
          last_hover_tilt = pen.tilt;
          last_hover_rotation = pen.rotation;
          last_hover_post_time = now;
          post_mouse_event(kCGEventMouseMoved, kCGMouseButtonLeft, location, 0, &pen, false);
        }
        return;
      }

      case LI_TOUCH_EVENT_BUTTON_ONLY: {
        note_pen_activity_for_palm_rejection(now, pen_scroll_mode_ != contact_mode_e::idle);
        const bool primary_now = (pen.penButtons & LI_PEN_BUTTON_PRIMARY) != 0;
        if (pen_hover_active && pen_scroll_mode_ == contact_mode_e::idle && primary_now && !pen_hover_primary_down) {
          touch_right_click(last_hover_location, true);
        }
        pen_hover_primary_down = primary_now;
        return;
      }

      case LI_TOUCH_EVENT_DOWN: {
        note_pen_activity_for_palm_rejection(now, true);
        leave_pen_hover();
        if (pen_scroll_mode_ != contact_mode_e::idle) {
          pen_scroll_release();
        }
        begin_pen_scroll_contact(location, now);
        return;
      }

      case LI_TOUCH_EVENT_MOVE: {
        note_pen_activity_for_palm_rejection(now, true);
        leave_pen_hover();
        pen_air_hover_during_contact = 0;
        pen_last_contact_time = now;
        if (pen_scroll_mode_ == contact_mode_e::idle) {
          begin_pen_scroll_contact(location, now);
        } else {
          move_pen_scroll_contact(location, now, pen);
        }
        return;
      }

      case LI_TOUCH_EVENT_UP:
        note_pen_activity_for_palm_rejection(now, false);
        pen_air_hover_during_contact = 0;
        pen_last_up_time = now;
        if (pen_scroll_mode_ == contact_mode_e::idle) {
          return;
        }
        finish_pen_scroll_contact(location, pen);
        return;

      default:
        return;
    }
  }

  void macos_client_input_t::pen_update(const touch_port_t &touch_port, const pen_input_t &pen) {
    if (pen.voidlink_extended) {
      client_voidlink_pen = true;
    }
    if (pen.eventType == LI_TOUCH_EVENT_CANCEL_ALL) {
      pen_roll_probe.reset();
      pen_pressure_sanitizer.reset();
      pen_eraser_latched = false;
      pen_squeeze_primary_down = false;
      pen_draw_air_hover_during_contact = 0;
    }

    if (!use_pen_draw_mode()) {
      if (pen_in_proximity && !pen_hover_active) {
        pen_release();
      }
      pen_scroll_mode_update(touch_port, pen);
      return;
    }

    leave_pen_hover();
    if (pen_scroll_mode_ != contact_mode_e::idle) {
      pen_scroll_release();
    }

    switch (pen.eventType) {
      case LI_TOUCH_EVENT_CANCEL:
      case LI_TOUCH_EVENT_CANCEL_ALL:
      case LI_TOUCH_EVENT_HOVER_LEAVE:
        note_pen_leave_for_palm_rejection(std::chrono::steady_clock::now());
        pen_release();
        return;
      case LI_TOUCH_EVENT_HOVER:
      case LI_TOUCH_EVENT_DOWN:
      case LI_TOUCH_EVENT_UP:
      case LI_TOUCH_EVENT_MOVE:
      case LI_TOUCH_EVENT_BUTTON_ONLY:
        break;
      default:
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    if (pen.eventType == LI_TOUCH_EVENT_HOVER) {
      if (pen_down[PEN_TIP]) {
        ++pen_draw_air_hover_during_contact;
        const auto since_contact = pen_draw_last_contact_time.time_since_epoch().count() != 0
                                     ? std::chrono::duration_cast<std::chrono::milliseconds>(now - pen_draw_last_contact_time)
                                     : std::chrono::milliseconds(100);
        if (!macos_input_policy::should_finish_pen_contact_on_hover(
              pen.pressureOrDistance,
              pen_draw_air_hover_during_contact,
              since_contact
            )) {
          note_pen_activity_for_palm_rejection(now, true);
          touch_pen_tip_activity();
          return;
        }
      }
      if (!pen_down[PEN_TIP] &&
          pen.pressureOrDistance <= 0.0005f &&
          pen_draw_last_up_time.time_since_epoch().count() != 0 &&
          (now - pen_draw_last_up_time) < 25ms) {
        return;
      }
      if (pen.pressureOrDistance > 0.0005f) {
        pen_draw_saw_air_hover = true;
      }
    } else if (pen.eventType == LI_TOUCH_EVENT_DOWN || pen.eventType == LI_TOUCH_EVENT_MOVE) {
      pen_draw_air_hover_during_contact = 0;
      pen_draw_last_contact_time = now;
      touch_pen_tip_activity();
    } else if (pen.eventType == LI_TOUCH_EVENT_UP) {
      pen_draw_air_hover_during_contact = 0;
      pen_draw_last_up_time = now;
    }

    note_pen_activity_for_palm_rejection(
      now,
      input::voidlink::should_press_pen_tip(pen.eventType, pen_down[PEN_TIP])
    );

    const auto location = clamp_to_display(stream_location(macos_input, touch_port, pen.x * touch_port.width, pen.y * touch_port.height));
    const std::uint8_t effective_tool =
      (pen.toolType == LI_TOOL_TYPE_ERASER || pen_eraser_latched) ? LI_TOOL_TYPE_ERASER : pen.toolType;

    const int pointer = effective_tool == LI_TOOL_TYPE_ERASER ? POINTER_ERASER : POINTER_PEN;
    if (pen_in_proximity && pointer != pen_pointer) {
      pen_release();
    }
    if (!pen_in_proximity) {
      pen_pointer = pointer;
      pen_in_proximity = true;
      post_proximity(true);
    }

    bool wanted[PEN_BUTTON_COUNT] {};
    wanted[PEN_TIP] = input::voidlink::should_press_pen_tip(pen.eventType, pen_down[PEN_TIP]);
    wanted[PEN_PRIMARY] = (pen.penButtons & LI_PEN_BUTTON_PRIMARY) != 0 || pen_squeeze_primary_down;
    wanted[PEN_SECONDARY] = (pen.penButtons & LI_PEN_BUTTON_SECONDARY) != 0;
    wanted[PEN_TERTIARY] = (pen.penButtons & LI_PEN_BUTTON_TERTIARY) != 0;

    int held = -1;
    for (int i = 0; i < PEN_BUTTON_COUNT && held < 0; ++i) {
      if (pen_down[i]) {
        held = i;
      }
    }

    if (pen.eventType == LI_TOUCH_EVENT_UP && !pen_draw_saw_air_hover) {
      suppress_cursor_for_touch_or_pen(macos_input, false);
    } else {
      show_pen_hover_reticle(
        macos_input,
        location,
        pen.eventType == LI_TOUCH_EVENT_HOVER ? pen.pressureOrDistance : 0.0f,
        effective_tool == LI_TOOL_TYPE_ERASER
      );
    }

    if (pen.eventType == LI_TOUCH_EVENT_HOVER) {
      last_hover_location = location;
      last_hover_tilt = pen.tilt;
      last_hover_rotation = pen.rotation;
    }

    const bool moved = !have_location || location.x != last_location.x || location.y != last_location.y;
    if (pen.eventType == LI_TOUCH_EVENT_MOVE ||
        pen.eventType == LI_TOUCH_EVENT_HOVER ||
        (pen.eventType != LI_TOUCH_EVENT_BUTTON_ONLY && pen.eventType != LI_TOUCH_EVENT_UP && moved)) {
      post_mouse_event(held < 0 ? kCGEventMouseMoved : button_event(held, true, true), held < 0 ? kCGMouseButtonLeft : mouse_button(held), location, 0, &pen, false);
    }

    for (int i = 0; i < PEN_BUTTON_COUNT; ++i) {
      if (wanted[i] == pen_down[i]) {
        continue;
      }
      if (i == PEN_TIP) {
        set_pen_tip_down(wanted[i]);
      } else {
        pen_down[i] = wanted[i];
      }

      int clicks = 1;
      if (i == PEN_TIP && wanted[i]) {
        const bool near = std::hypot(location.x - last_pen_down.x, location.y - last_pen_down.y) <= MULTICLICK_DISTANCE;
        pen_click_count = (now - last_pen_down_time < MULTICLICK_DELAY_MS && near) ? pen_click_count + 1 : 1;
        last_pen_down = location;
        last_pen_down_time = now;
      }
      if (i == PEN_TIP) {
        clicks = pen_click_count;
      }
      post_mouse_event(button_event(i, wanted[i], false), mouse_button(i), location, clicks, &pen, false);
    }
  }

  void macos_client_input_t::pencil_side_button(const touch_port_t &touch_port, const pencil_side_button_input_t &btn) {
    client_voidlink_pen = true;
    note_pen_activity_for_palm_rejection(std::chrono::steady_clock::now(), pen_down[PEN_TIP]);
    const auto location = clamp_to_display(stream_location(macos_input, touch_port, btn.x * touch_port.width, btn.y * touch_port.height));

    if (!use_pen_draw_mode()) {
      if (btn.eventType == input::voidlink::pencil_double_tap ||
          btn.eventType == input::voidlink::pencil_squeeze_begin) {
        touch_right_click(location, pen_hover_active);
      }
      return;
    }

    if (btn.eventType == input::voidlink::pencil_double_tap) {
      pen_eraser_latched = !pen_eraser_latched;
      if (!pen_down[PEN_TIP]) {
        ensure_pen_proximity(pen_eraser_latched ? LI_TOOL_TYPE_ERASER : LI_TOOL_TYPE_PEN);
        if (pen_in_proximity && (pen_hover_active || pen_draw_saw_air_hover)) {
          show_pen_hover_reticle(macos_input, location, 0.05f, pen_eraser_latched);
        }
      }
      return;
    }

    pen_input_t synthetic_pen {};
    synthetic_pen.eventType = LI_TOUCH_EVENT_BUTTON_ONLY;
    synthetic_pen.toolType = pen_eraser_latched ? LI_TOOL_TYPE_ERASER : LI_TOOL_TYPE_PEN;
    synthetic_pen.tilt = last_hover_tilt;
    synthetic_pen.rotation = last_hover_rotation;
    synthetic_pen.x = btn.x;
    synthetic_pen.y = btn.y;
    synthetic_pen.voidlink_extended = true;

    switch (btn.eventType) {
      case input::voidlink::pencil_squeeze_begin:
        if (!pen_down[PEN_TIP] && !pen_squeeze_primary_down) {
          pen_squeeze_primary_down = true;
          ensure_pen_proximity(synthetic_pen.toolType);
          pen_down[PEN_PRIMARY] = true;
          post_mouse_event(kCGEventRightMouseDown, kCGMouseButtonRight, location, 1, &synthetic_pen, false);
        }
        break;
      case input::voidlink::pencil_squeeze_change:
        if (pen_squeeze_primary_down && pen_down[PEN_PRIMARY] &&
            (!have_location || std::hypot(location.x - last_location.x, location.y - last_location.y) >= 0.5)) {
          post_mouse_event(kCGEventRightMouseDragged, kCGMouseButtonRight, location, 0, &synthetic_pen, false);
        }
        break;
      case input::voidlink::pencil_squeeze_end:
      case input::voidlink::pencil_squeeze_cancel:
        if (pen_squeeze_primary_down) {
          pen_squeeze_primary_down = false;
          if (pen_down[PEN_PRIMARY]) {
            pen_down[PEN_PRIMARY] = false;
            post_mouse_event(kCGEventRightMouseUp, kCGMouseButtonRight, location, 1, &synthetic_pen, false);
          }
        }
        break;
      default:
        break;
    }
  }

  void macos_client_input_t::touch_update(const touch_port_t &touch_port, const touch_input_t &touch) {
    switch (touch.eventType) {
      case LI_TOUCH_EVENT_CANCEL:
        touch_points.erase(touch.pointerId);
        if (touch_points.empty()) {
          touch_release();
        }
        return;
      case LI_TOUCH_EVENT_CANCEL_ALL:
        touch_release();
        palm_rejection.reset();
        return;
      case LI_TOUCH_EVENT_DOWN:
      case LI_TOUCH_EVENT_UP:
      case LI_TOUCH_EVENT_MOVE:
        break;
      default:
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    if (palm_rejection.should_reject_touch(config::get_macos_palm_rejection(), touch.pointerId, now)) {
      if (touch.eventType == LI_TOUCH_EVENT_UP) {
        touch_points.erase(touch.pointerId);
      }
      return;
    }

    const auto location = clamp_to_display(stream_location(macos_input, touch_port, touch.x * touch_port.width, touch.y * touch_port.height));

    switch (touch.eventType) {
      case LI_TOUCH_EVENT_DOWN: {
        suppress_cursor_for_touch_or_pen(macos_input, false);
        const bool was_fast_mom = (current_scroll_momentum_speed(macos_input) >= 90.0);
        cancel_scroll_momentum(macos_input);
        const bool was_empty = touch_points.empty();
        touch_points[touch.pointerId] = {location, location, now};

        if (was_empty) {
          touch_caught_momentum = was_fast_mom;
          touch_mode_ = contact_mode_e::undecided;
          touch_scroll_origin = location;
          scroll_remainder_x = 0;
          scroll_remainder_y = 0;
          two_finger_tap_candidate = false;
        } else if (touch_points.size() >= 2) {
          if (touch_mode_ == contact_mode_e::dragging) {
            post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, last_location, 1);
          }
          touch_mode_ = contact_mode_e::scrolling;
          two_finger_tap_candidate = (touch_points.size() == 2 && !touch_caught_momentum);
          two_finger_down_time = now;
        }
        break;
      }

      case LI_TOUCH_EVENT_MOVE: {
        const auto point = touch_points.find(touch.pointerId);
        if (point == touch_points.end()) {
          return;
        }

        const double delta_x = location.x - point->second.last.x;
        const double delta_y = location.y - point->second.last.y;
        point->second.last = location;

        if (two_finger_tap_candidate) {
          if (std::hypot(location.x - point->second.start.x, location.y - point->second.start.y) <= TOUCH_SLOP) {
            return;
          }
          two_finger_tap_candidate = false;
        }

        if (touch_mode_ == contact_mode_e::scrolling) {
          const auto fingers = static_cast<double>(std::max<std::size_t>(touch_points.size(), 1));
          scroll_remainder_x += delta_x / fingers;
          scroll_remainder_y += delta_y / fingers;
          scroll_by_remainder();
        } else if (touch_mode_ == contact_mode_e::dragging) {
          if (!have_location || location.x != last_location.x || location.y != last_location.y) {
            post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
          }
        } else if (touch_mode_ == contact_mode_e::undecided &&
                   touch_points.size() == 1 &&
                   std::hypot(location.x - point->second.start.x, location.y - point->second.start.y) > TOUCH_SLOP) {
          if (now - point->second.down_time >= LONG_PRESS) {
            touch_mode_ = contact_mode_e::dragging;
            post_mouse_event(kCGEventLeftMouseDown, kCGMouseButtonLeft, point->second.start, 1);
            post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
          } else {
            touch_mode_ = contact_mode_e::scrolling;
            scroll_remainder_x += location.x - point->second.start.x;
            scroll_remainder_y += location.y - point->second.start.y;
            scroll_by_remainder();
          }
        }
        break;
      }

      case LI_TOUCH_EVENT_UP: {
        const auto point = touch_points.find(touch.pointerId);
        if (point == touch_points.end()) {
          return;
        }

        const bool single_undecided = (touch_points.size() == 1 && touch_mode_ == contact_mode_e::undecided);
        const bool held = (now - point->second.down_time >= LONG_PRESS);
        const auto start = point->second.start;

        if (two_finger_tap_candidate) {
          two_finger_tap_candidate = false;
          if (now - two_finger_down_time < LONG_PRESS) {
            touch_right_click(start, false);
            touch_mode_ = contact_mode_e::idle;
          }
        }

        touch_points.erase(point);

        if (touch_mode_ == contact_mode_e::dragging) {
          if (!have_location || location.x != last_location.x || location.y != last_location.y) {
            post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
          }
          post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, location, 1);
          touch_mode_ = contact_mode_e::idle;
        } else if (single_undecided) {
          if (held) {
            touch_right_click(start, false);
          } else if (!touch_caught_momentum) {
            touch_click(start, false);
          }
          touch_mode_ = contact_mode_e::idle;
        }

        if (touch_points.empty()) {
          if (touch_mode_ == contact_mode_e::scrolling) {
            finish_continuous_scroll_gesture(macos_input);
          }
          touch_mode_ = contact_mode_e::idle;
          touch_caught_momentum = false;
          two_finger_tap_candidate = false;
        }
        break;
      }
    }
  }

  std::unique_ptr<client_input_t> allocate_client_input_context(input_t &input) {
    return std::make_unique<macos_client_input_t>(static_cast<macos_input_t *>(input.get()));
  }

  void touch_update(client_input_t *input, const touch_port_t &touch_port, const touch_input_t &touch) {
    if (const auto client = static_cast<macos_client_input_t *>(input)) {
      client->touch_update(touch_port, touch);
    }
  }

  void pen_update(client_input_t *input, const touch_port_t &touch_port, const pen_input_t &pen) {
    if (const auto client = static_cast<macos_client_input_t *>(input)) {
      client->pen_update(touch_port, pen);
    }
  }

  void pencil_side_button(client_input_t *input, const touch_port_t &touch_port, const pencil_side_button_input_t &btn) {
    if (const auto client = static_cast<macos_client_input_t *>(input)) {
      client->pencil_side_button(touch_port, btn);
    }
  }
}  // namespace platf
