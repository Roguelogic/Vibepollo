/**
 * @file src/platform/macos/input.cpp
 * @brief macOS input backend focusing on native mouse/keyboard, continuous trackpad scroll,
 *        and Wacom-grade Apple Pencil tablet input (client-delegated touch architecture).
 */
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <ctime>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <pthread.h>
#include <pthread/qos.h>

#include "src/config.h"
#include "src/display_device.h"
#include "src/input.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/cf_guard.h"
#include "src/platform/macos/display_policy.h"
#include "src/platform/macos/keymap.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/palm_rejection.h"
#include "src/platform/macos/sc_video.h"
#include "src/platform/macos/virtual_display.h"
#include "src/platform/macos/wheel_scroll.h"
#include "src/utility.h"
#include "src/voidlink_protocol.h"

constexpr std::chrono::milliseconds MULTICLICK_DELAY_MS(500);

namespace platf {
  using namespace std::literals;

  constexpr int WHEEL_DELTA = 120;
  constexpr double DEFAULT_SCROLLWHEEL_SCALING = 0.3125;
  constexpr int DEFAULT_SCROLL_LINES_PER_DETENT = 5;

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
  };

  void cancel_scroll_momentum(macos_input_t *macos_input);
  double current_scroll_momentum_speed(macos_input_t *macos_input);

  CGFloat display_scaling(const CGDirectDisplayID display) {
    const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) {
      return 1;
    }
    const auto pixel_width = CGDisplayModeGetPixelWidth(mode);
    CGDisplayModeRelease(mode);
    return pixel_width ? ((CGFloat) CGDisplayPixelsWide(display)) / ((CGFloat) pixel_width) : 1;
  }

  CGPoint clamp_point_to_bounds(const CGPoint &point, const CGRect &bounds) noexcept {
    const CGFloat max_x = std::max(bounds.origin.x, bounds.origin.x + bounds.size.width - 1.0);
    const CGFloat max_y = std::max(bounds.origin.y, bounds.origin.y + bounds.size.height - 1.0);
    return CGPointMake(
      std::clamp(point.x, bounds.origin.x, max_x),
      std::clamp(point.y, bounds.origin.y, max_y)
    );
  }

  display_geometry_t current_display_geometry(macos_input_t *macos_input) {
    const CGDirectDisplayID display = macos_virtual_display::active_display_id().value_or(macos_input->configured_display);
    const std::uint64_t gen = macos_virtual_display::display_state_generation();
    std::lock_guard lock(macos_input->display_mutex);
    if (display != macos_input->display || gen != macos_input->displayGeneration || macos_input->displayScaling <= 0 || macos_input->displayBoundsWidth <= 0) {
      const CGRect bounds = CGDisplayBounds(display);
      macos_input->display = display;
      macos_input->displayBounds = bounds;
      macos_input->displayBoundsWidth = bounds.size.width;
      macos_input->displayScaling = display_scaling(display);
      macos_input->displayGeneration = gen;
    }
    return {macos_input->display, macos_input->displayBounds, macos_input->displayScaling};
  }

  CGRect target_display_bounds(macos_input_t *macos_input, const CGPoint &point) {
    const auto geom = current_display_geometry(macos_input);
    if (macos_virtual_display::has_remote_displays()) {
      CGDirectDisplayID display_at_point = kCGNullDirectDisplay;
      uint32_t count = 0;
      if (CGGetDisplaysWithPoint(point, 1, &display_at_point, &count) == kCGErrorSuccess && count == 1 &&
          macos_virtual_display::is_remote_display(display_at_point)) {
        return display_at_point == geom.id ? geom.bounds : CGDisplayBounds(display_at_point);
      }
    }
    return geom.bounds;
  }

  display_geometry_t pointer_display_geometry(macos_input_t *macos_input, const touch_port_t &touch_port) {
    static std::atomic<CGDirectDisplayID> last_remote {kCGNullDirectDisplay};
    const auto stream_display = macos_display_policy::parse_display_identity(touch_port.output_name);
    const auto streamed = current_display_geometry(macos_input);
    const auto display = macos_display_policy::pointer_display(stream_display, macos_virtual_display::is_remote_display, streamed.id);
    if (display != streamed.id) {
      if (last_remote.exchange(display) != display) {
        BOOST_LOG(info) << "Remote Monitor pointer: moving on display "sv << display;
      }
      return {display, CGDisplayBounds(display), display_scaling(display)};
    }
    return streamed;
  }

  void toggle_input_source(macos_input_t *macos_input) {
    const CGEventFlags saved_flags = macos_input->kb_flags.load(std::memory_order_relaxed);
    const CGEventFlags ctrl_flags = saved_flags | kCGEventFlagMaskControl | NX_DEVICELCTLKEYMASK;
    const auto post_key = [&](const CGKeyCode vk, const bool down, const CGEventFlags flags) noexcept {
      if (const CGEventRef ev = CGEventCreateKeyboardEvent(macos_input->keyboard_source, vk, down)) {
        CGEventSetFlags(ev, flags);
        CGEventSetTimestamp(ev, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
      }
    };
    post_key(kVK_Control, true, ctrl_flags);
    post_key(kVK_Space, true, ctrl_flags);
    post_key(kVK_Space, false, ctrl_flags);
    post_key(kVK_Control, false, saved_flags);
  }

  namespace {
    void ensure_event_sources(macos_input_t *macos_input) {
      std::lock_guard lock(macos_input->source_mutex);
      if (!macos_input->source) {
        macos_input->source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (macos_input->source) {
          CGEventSourceSetLocalEventsSuppressionInterval(macos_input->source, 0.0);
        }
      }
      if (!macos_input->keyboard_source) {
        macos_input->keyboard_source = CGEventSourceCreate(kCGEventSourceStatePrivate);
        if (macos_input->keyboard_source) {
          CGEventSourceSetLocalEventsSuppressionInterval(macos_input->keyboard_source, 0.0);
        }
      }
      if (!macos_input->mouse_event) {
        macos_input->mouse_event = CGEventCreate(macos_input->source);
      }
    }
  }  // namespace

  void keyboard_update(input_t &input, uint16_t modcode, bool release, uint8_t flags) {
    (void) flags;
    auto *macos_input = static_cast<macos_input_t *>(input.get());
    ensure_event_sources(macos_input);
    std::lock_guard kb_lock(macos_input->keyboard_mutex);
    const bool secure_password_input = is_loginwindow_session() || IsSecureEventInputEnabled();

    if (modcode == 0xFF || modcode == 0x15) {
      if (!release && !secure_password_input) {
        toggle_input_source(macos_input);
      }
      return;
    }

    CGEventFlags current_flags = macos_input->kb_flags.load(std::memory_order_relaxed);
    if (modcode == 0x14 && (current_flags & kCGEventFlagMaskShift) == 0 && !secure_password_input) {
      const auto now = std::chrono::steady_clock::now();
      if (!release) {
        macos_input->capslock_down_time = now;
        toggle_input_source(macos_input);
      } else {
        if (macos_input->capslock_down_time.time_since_epoch().count() != 0 &&
            (now - macos_input->capslock_down_time) > 350ms) {
          toggle_input_source(macos_input);
        }
        macos_input->capslock_down_time = {};
      }
      return;
    }

    const int key = keysym(modcode);
    BOOST_LOG(debug) << "got keycode: 0x"sv << std::hex << modcode << ", translated to: 0x" << std::hex << key << ", release:" << release;
    if (key < 0) {
      return;
    }

    CGEventRef event = nullptr;
    modifier_flags_t modifier_flags;
    const int64_t kbd_type = effective_keyboard_type();

    if (modifier_flags_for_key(key, modifier_flags)) {
      event = CGEventCreateKeyboardEvent(macos_input->keyboard_source, key, !release);
      if (!event) {
        return;
      }

      CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, key);
      CGEventSetIntegerValueField(event, kCGKeyboardEventKeyboardType, kbd_type);

      if (release) {
        current_flags &= ~modifier_flags.device;
        if ((current_flags & modifier_flags.all_devices) == 0) {
          current_flags &= ~modifier_flags.generic;
        }
      } else {
        cancel_scroll_momentum(macos_input);
        current_flags |= modifier_flags.generic | modifier_flags.device;
      }
      macos_input->kb_flags.store(current_flags, std::memory_order_relaxed);

      CGEventSetType(event, kCGEventFlagsChanged);
    } else {
      if (!release) {
        cancel_scroll_momentum(macos_input);
      }
      event = CGEventCreateKeyboardEvent(macos_input->keyboard_source, key, !release);
      if (!event) {
        return;
      }

      CGEventSetIntegerValueField(event, kCGKeyboardEventKeyboardType, kbd_type);
      CGEventSetType(event, release ? kCGEventKeyUp : kCGEventKeyDown);
      if (secure_password_input) {
        stamp_loginwindow_ascii_unicode(event, key, current_flags);
      }
    }

    CGEventSetFlags(event, current_flags);
    CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    CGEventPost(secure_password_input ? kCGHIDEventTap : kCGSessionEventTap, event);
    CFRelease(event);
  }

  void unicode(input_t &input, char *utf8, int size) {
    if (!utf8 || size <= 0) {
      return;
    }
    auto *macos_input = static_cast<macos_input_t *>(input.get());
    ensure_event_sources(macos_input);
    std::lock_guard kb_lock(macos_input->keyboard_mutex);

    const cf_ref_t<CFStringRef> cf_str(CFStringCreateWithBytes(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8 *>(utf8),
      size,
      kCFStringEncodingUTF8,
      false
    ));
    if (!cf_str) {
      return;
    }
    const CFIndex utf16_len = CFStringGetLength(cf_str.get());
    if (utf16_len <= 0) {
      return;
    }

    UniChar stack_buf[64];
    std::vector<UniChar> heap_buf;
    UniChar *out_chars = stack_buf;
    if (utf16_len > static_cast<CFIndex>(std::size(stack_buf))) {
      heap_buf.resize(static_cast<std::size_t>(utf16_len));
      out_chars = heap_buf.data();
    }
    CFStringGetCharacters(cf_str.get(), CFRangeMake(0, utf16_len), out_chars);

    const bool secure_password_input = is_loginwindow_session() || IsSecureEventInputEnabled();
    const CGEventTapLocation tap = secure_password_input ? kCGHIDEventTap : kCGSessionEventTap;
    for (const bool down : {true, false}) {
      if (CGEventRef ev = CGEventCreateKeyboardEvent(macos_input->keyboard_source, 0, down)) {
        CGEventKeyboardSetUnicodeString(ev, static_cast<UniCharCount>(utf16_len), out_chars);
        CGEventSetTimestamp(ev, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        CGEventPost(tap, ev);
        CFRelease(ev);
      }
    }
  }

  int alloc_gamepad(input_t &input, const gamepad_id_t &id, const gamepad_arrival_t &metadata, feedback_queue_t feedback_queue) {
    BOOST_LOG(info) << "alloc_gamepad: Gamepad not yet implemented for MacOS."sv;
    return -1;
  }

  void free_gamepad(input_t &input, int nr) {
    BOOST_LOG(info) << "free_gamepad: Gamepad not yet implemented for MacOS."sv;
  }

  void gamepad_update(input_t &input, int nr, const gamepad_state_t &gamepad_state) {
    BOOST_LOG(info) << "gamepad: Gamepad not yet implemented for MacOS."sv;
  }

  util::point_t get_mouse_loc(input_t &input) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    ensure_event_sources(macos_input);
    const auto now = std::chrono::steady_clock::now();
    util::point_t fallback {};
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      const auto &c = macos_input->cursor;
      fallback = c.last_cursor_loc;
      if (c.has_cursor_loc &&
          c.last_cursor_update.time_since_epoch().count() != 0 &&
          (now - c.last_cursor_update) < 250ms) {
        return c.last_cursor_loc;
      }
    }
    if (const auto snapshot_event = CGEventCreate(macos_input->source)) {
      const auto current = CGEventGetLocation(snapshot_event);
      CFRelease(snapshot_event);
      std::lock_guard lock(macos_input->scroll_mutex);
      macos_input->cursor.last_cursor_loc = {current.x, current.y};
      macos_input->cursor.has_cursor_loc = true;
      macos_input->cursor.last_cursor_update = now;
      return {current.x, current.y};
    }
    return fallback;
  }

  CGPoint raw_system_cursor_point(macos_input_t *macos_input) {
    ensure_event_sources(macos_input);
    if (const auto snapshot_event = CGEventCreate(macos_input->source)) {
      const auto current = CGEventGetLocation(snapshot_event);
      CFRelease(snapshot_event);
      return current;
    }
    std::lock_guard lock(macos_input->scroll_mutex);
    return CGPointMake(macos_input->cursor.last_cursor_loc.x, macos_input->cursor.last_cursor_loc.y);
  }

  // Snapshots `saved_trackpad_cursor` once on transition from visible mouse mode and hides
  // the standard arrow cursor on SCStream while touch or Apple Pencil is active.
  void suppress_cursor_for_touch_or_pen(macos_input_t *macos_input, const bool keep_pen_reticle) {
    bool need_snapshot = false;
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      auto &c = macos_input->cursor;
      c.trackpad_scroll_needs_warp = true;
      need_snapshot = !c.touch_suppressed;
    }
    if (need_snapshot) {
      const CGPoint current_sys = raw_system_cursor_point(macos_input);
      std::lock_guard lock(macos_input->scroll_mutex);
      auto &c = macos_input->cursor;
      if (!c.touch_suppressed) {
        c.saved_trackpad_cursor = current_sys;
        c.has_saved_trackpad_cursor = true;
        c.touch_suppressed = true;
      }
    }
    macos_sc_set_cursor_visible(false);
    if (!keep_pen_reticle) {
      macos_pen_hover_cursor_hide();
    }
  }

  void show_pen_hover_reticle(
    macos_input_t *macos_input,
    const CGPoint &location,
    const float distance_norm,
    const bool eraser
  ) {
    suppress_cursor_for_touch_or_pen(macos_input, true);
    macos_pen_hover_cursor_show(location.x, location.y, distance_norm, eraser);
  }

  util::point_t consume_trackpad_cursor_loc(input_t &input) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      auto &c = macos_input->cursor;
      c.trackpad_scroll_needs_warp = false;
      if (c.touch_suppressed && c.has_saved_trackpad_cursor) {
        return util::point_t {c.saved_trackpad_cursor.x, c.saved_trackpad_cursor.y};
      }
    }
    return get_mouse_loc(input);
  }

  void flush_pending_cursor_restore_for_trackpad(macos_input_t *macos_input) {
    bool do_warp = false;
    CGPoint restore_pt {};
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      auto &c = macos_input->cursor;
      if (c.touch_suppressed && c.trackpad_scroll_needs_warp && c.has_saved_trackpad_cursor) {
        c.trackpad_scroll_needs_warp = false;
        restore_pt = c.saved_trackpad_cursor;
        do_warp = true;
      }
    }
    if (do_warp) {
      CGWarpMouseCursorPosition(restore_pt);
      CGAssociateMouseAndMouseCursorPosition(true);
    }
  }

  void post_mouse(
    input_t &input,
    const CGMouseButton button,
    const CGEventType type,
    const util::point_t raw_location,
    const util::point_t previous_location,
    const int click_count
  ) {
    BOOST_LOG(debug) << "mouse_event: "sv << button << ", type: "sv << type << ", location:"sv << raw_location.x << ":"sv << raw_location.y << " click_count: "sv << click_count;

    const auto macos_input = static_cast<macos_input_t *>(input.get());
    ensure_event_sources(macos_input);

    {
      std::unique_lock lock(macos_input->scroll_mutex);
      auto &s = macos_input->scroll;
      if (s.in_momentum) {
        const auto now_mom = std::chrono::steady_clock::now();
        const auto elapsed_mom = now_mom - s.mom_start_time;
        if (!s.has_momentum_anchor) {
          s.momentum_anchor = CGPointMake(raw_location.x, raw_location.y);
          s.has_momentum_anchor = true;
        }
        const double dist = std::hypot(raw_location.x - s.momentum_anchor.x, raw_location.y - s.momentum_anchor.y);
        const bool should_cancel = s.trackpad_continuous_mode ? (elapsed_mom >= 35ms || dist > 4.0) : (dist >= 3.0);
        if (should_cancel) {
          lock.unlock();
          cancel_scroll_momentum(macos_input);
        }
      }
    }

    const CGRect display_bounds = target_display_bounds(macos_input, CGPointMake(raw_location.x, raw_location.y));
    const CGPoint location = clamp_point_to_bounds(CGPointMake(raw_location.x, raw_location.y), display_bounds);
    const auto now = std::chrono::steady_clock::now();

    bool show_cursor = false;
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      auto &c = macos_input->cursor;
      c.saved_trackpad_cursor = location;
      c.has_saved_trackpad_cursor = true;
      c.trackpad_scroll_needs_warp = false;
      c.last_cursor_loc = {location.x, location.y};
      c.has_cursor_loc = true;
      c.last_cursor_update = now;
      if (c.touch_suppressed) {
        c.touch_suppressed = false;
        show_cursor = true;
      }
    }
    if (show_cursor) {
      CGWarpMouseCursorPosition(location);
      CGAssociateMouseAndMouseCursorPosition(true);
      macos_pen_hover_cursor_hide();
      macos_sc_set_cursor_visible(true);
    }

    bool do_move_warp = false;
    {
      std::lock_guard mouse_lock(macos_input->mouse_mutex);
      const auto event = macos_input->mouse_event;
      if (!event) {
        return;
      }
      CGEventSetType(event, type);
      CGEventSetLocation(event, location);
      CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, button);
      CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_count);

      const double deltaX = raw_location.x - previous_location.x;
      const double deltaY = raw_location.y - previous_location.y;
      CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, deltaX);
      CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, deltaY);

      CGEventSetFlags(event, macos_input->kb_flags.load(std::memory_order_relaxed));
      CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
      CGEventPost(kCGHIDEventTap, event);

      if (!show_cursor && type == kCGEventMouseMoved &&
          (macos_input->last_mouse_warp.time_since_epoch().count() == 0 ||
           (now - macos_input->last_mouse_warp) >= 1500us)) {
        macos_input->last_mouse_warp = now;
        do_move_warp = true;
      }
    }
    if (do_move_warp) {
      CGWarpMouseCursorPosition(location);
      CGAssociateMouseAndMouseCursorPosition(true);
    }
  }

  inline std::pair<CGMouseButton, CGEventType> active_mouse_move_state(input_t &input) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    std::lock_guard mouse_lock(macos_input->mouse_mutex);
    if (macos_input->mouse_down[0]) {
      return {kCGMouseButtonLeft, kCGEventLeftMouseDragged};
    }
    if (macos_input->mouse_down[2]) {
      return {kCGMouseButtonRight, kCGEventRightMouseDragged};
    }
    if (macos_input->mouse_down[1]) {
      return {kCGMouseButtonCenter, kCGEventOtherMouseDragged};
    }
    if (macos_input->mouse_down[3]) {
      return {static_cast<CGMouseButton>(3), kCGEventOtherMouseDragged};
    }
    if (macos_input->mouse_down[4]) {
      return {static_cast<CGMouseButton>(4), kCGEventOtherMouseDragged};
    }
    return {kCGMouseButtonLeft, kCGEventMouseMoved};
  }

  void move_mouse(input_t &input, const int deltaX, const int deltaY) {
    const auto current = consume_trackpad_cursor_loc(input);
    const auto location = util::point_t {current.x + deltaX, current.y + deltaY};
    const auto [btn, ev_type] = active_mouse_move_state(input);
    post_mouse(input, btn, ev_type, location, current, 0);
  }

  CGPoint stream_location(macos_input_t *macos_input, const touch_port_t &touch_port, const float x, const float y) {
    const auto geom = pointer_display_geometry(macos_input, touch_port);
    return CGPointMake(x * geom.scaling + geom.bounds.origin.x, y * geom.scaling + geom.bounds.origin.y);
  }

  void abs_mouse(input_t &input, const touch_port_t &touch_port, const float x, const float y) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    const auto location = stream_location(macos_input, touch_port, x, y);
    const auto prev = consume_trackpad_cursor_loc(input);
    const auto [btn, ev_type] = active_mouse_move_state(input);
    post_mouse(input, btn, ev_type, util::point_t {location.x, location.y}, prev, 0);
  }

  void button_mouse(input_t &input, const int button, const bool release) {
    CGMouseButton mac_button;
    CGEventType event;
    int slot = -1;

    const auto macos_input = static_cast<macos_input_t *>(input.get());
    if (!release) {
      cancel_scroll_momentum(macos_input);
    }

    switch (button) {
      case 1:
        mac_button = kCGMouseButtonLeft;
        event = release ? kCGEventLeftMouseUp : kCGEventLeftMouseDown;
        slot = 0;
        break;
      case 2:
        mac_button = kCGMouseButtonCenter;
        event = release ? kCGEventOtherMouseUp : kCGEventOtherMouseDown;
        slot = 1;
        break;
      case 3:
        mac_button = kCGMouseButtonRight;
        event = release ? kCGEventRightMouseUp : kCGEventRightMouseDown;
        slot = 2;
        break;
      case 4:
        mac_button = static_cast<CGMouseButton>(3);
        event = release ? kCGEventOtherMouseUp : kCGEventOtherMouseDown;
        slot = 3;
        break;
      case 5:
        mac_button = static_cast<CGMouseButton>(4);
        event = release ? kCGEventOtherMouseUp : kCGEventOtherMouseDown;
        slot = 4;
        break;
      default:
        BOOST_LOG(warning) << "Unsupported mouse button for MacOS: "sv << button;
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    const auto mouse_position = consume_trackpad_cursor_loc(input);
    int clicks = 1;
    {
      std::lock_guard mouse_lock(macos_input->mouse_mutex);
      macos_input->mouse_down[slot] = !release;
      if (!release) {
        const bool within_delay = macos_input->last_mouse_down_time[slot].time_since_epoch().count() != 0 &&
                                  (now - macos_input->last_mouse_down_time[slot]) < MULTICLICK_DELAY_MS;
        const bool near = std::hypot(
                            mouse_position.x - macos_input->last_mouse_down_pos[slot].x,
                            mouse_position.y - macos_input->last_mouse_down_pos[slot].y
                          ) <= 8.0;
        macos_input->mouse_click_count[slot] = (within_delay && near) ? (macos_input->mouse_click_count[slot] + 1) : 1;
        macos_input->last_mouse_down_time[slot] = now;
        macos_input->last_mouse_down_pos[slot] = mouse_position;
      }
      clicks = std::max(1, macos_input->mouse_click_count[slot]);
    }
    post_mouse(input, mac_button, event, mouse_position, mouse_position, clicks);
  }

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

  void continuous_scroll_delta(
    macos_input_t *macos_input,
    const double delta_y_px,
    const double delta_x_px,
    const CGPoint *target_loc = nullptr
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
      if (!primed_target && pkt.phase == macos_input_policy::trackpad_gesture_emitter_t::phase_began) {
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
      if (is_down || type == kCGEventMouseMoved) {
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
        const double pressure = tip_pressed ?
                                  (pen->pressureOrDistance > 0.0f ? std::clamp<double>(pen->pressureOrDistance, 0.0, 1.0) : 0.5) :
                                  0.0;
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

    void pen_release() {
      macos_pen_hover_cursor_hide();
      pen_squeeze_primary_down = false;
      pen_draw_saw_air_hover = false;
      if (!pen_in_proximity) {
        return;
      }

      pen_input_t pen {};
      pen.tilt = LI_TILT_UNKNOWN;
      pen.rotation = LI_ROT_UNKNOWN;
      for (int i = PEN_BUTTON_COUNT - 1; i >= 0; --i) {
        if (pen_down[i]) {
          pen_down[i] = false;
          post_mouse_event(button_event(i, false, false), mouse_button(i), last_location, i == PEN_TIP ? pen_click_count : 1, &pen, true);
        }
      }
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
        pen_down[PEN_TIP] = false;
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
        pen_down[PEN_TIP] = true;
        if (!have_location || location.x != last_location.x || location.y != last_location.y) {
          post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
        }
      } else if (pen_scroll_mode_ == contact_mode_e::undecided &&
                 std::hypot(location.x - pen_start.x, location.y - pen_start.y) > PEN_SLOP) {
        const bool drag_intent = (pen.penButtons & LI_PEN_BUTTON_PRIMARY) != 0 || (now - pen_down_time) >= PEN_DRAG_HOLD;
        macos_pen_hover_cursor_hide();
        if (drag_intent) {
          pen_scroll_mode_ = contact_mode_e::dragging;
          pen_down[PEN_TIP] = true;
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
      pen_down[PEN_TIP] = false;
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
    std::chrono::steady_clock::time_point pen_draw_last_up_time {};

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
      pen_eraser_latched = false;
      pen_squeeze_primary_down = false;
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
    note_pen_activity_for_palm_rejection(
      now,
      input::voidlink::should_press_pen_tip(pen.eventType, pen_down[PEN_TIP])
    );
    if (pen.eventType == LI_TOUCH_EVENT_HOVER) {
      if (!pen_down[PEN_TIP] &&
          pen.pressureOrDistance <= 0.0005f &&
          pen_draw_last_up_time.time_since_epoch().count() != 0 &&
          (now - pen_draw_last_up_time) < 25ms) {
        return;
      }
      if (pen.pressureOrDistance > 0.0005f) {
        pen_draw_saw_air_hover = true;
      }
    } else if (pen.eventType == LI_TOUCH_EVENT_UP) {
      pen_draw_last_up_time = now;
    }

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
      pen_down[i] = wanted[i];

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

  void mac_trackpad_gesture(input_t &input, const mac_trackpad_gesture_t &gesture) {
    auto *macos_input = static_cast<macos_input_t *>(input.get());
    if (!macos_input || !config::input.mouse) {
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

  void gamepad_touch(input_t &input, const gamepad_touch_t &touch) {
  }

  void gamepad_motion(input_t &input, const gamepad_motion_t &motion) {
  }

  void gamepad_battery(input_t &input, const gamepad_battery_t &battery) {
  }

  void gamepad_attributes(input_t &input, const steam_controller_attributes_t &attributes) {
  }

  input_t input() {
    input_t result {new macos_input_t()};
    const auto macos_input = static_cast<macos_input_t *>(result.get());

    macos_input->display = CGMainDisplayID();
    auto output_name = config::get_active_output_name();
    if (!output_name.empty()) {
      const int MAX_DISPLAYS = 32;
      uint32_t max_display = MAX_DISPLAYS;
      uint32_t display_count;
      CGDirectDisplayID displays[MAX_DISPLAYS];
      if (CGGetActiveDisplayList(max_display, displays, &display_count) != kCGErrorSuccess) {
        BOOST_LOG(error) << "Unable to get active display list , error: "sv << std::endl;
      } else {
        for (uint32_t i = 0; i < display_count; i++) {
          CGDirectDisplayID display_id = displays[i];
          if (display_id == static_cast<CGDirectDisplayID>(std::atoi(output_name.c_str()))) {
            macos_input->display = display_id;
          }
        }
      }
    }

    macos_input->configured_display = macos_input->display;
    macos_input->displayBounds = CGDisplayBounds(macos_input->display);
    macos_input->displayBoundsWidth = macos_input->displayBounds.size.width;
    macos_input->displayScaling = display_scaling(macos_input->display);
    macos_input->displayGeneration = macos_virtual_display::display_state_generation();

    ensure_event_sources(macos_input);
    ensure_ascii_keyboard_layout_cached();
    macos_input->scroll_lines_per_detent = get_scroll_lines_per_detent(macos_input->scrollwheel_scaling);

    macos_input->kb_flags.store(0, std::memory_order_relaxed);
    std::fill(std::begin(macos_input->mouse_down), std::end(macos_input->mouse_down), false);
    const CGPoint init_cursor = raw_system_cursor_point(macos_input);
    macos_input->cursor.last_cursor_loc = {init_cursor.x, init_cursor.y};
    macos_input->cursor.has_cursor_loc = true;
    macos_input->cursor.saved_trackpad_cursor = init_cursor;
    macos_input->cursor.has_saved_trackpad_cursor = true;

    macos_input->scroll_thread = std::thread(run_scroll_momentum_worker, macos_input);

    BOOST_LOG(debug) << "macOS scroll speed: com.apple.scrollwheel.scaling="sv << macos_input->scrollwheel_scaling << ", lines per detent="sv << macos_input->scroll_lines_per_detent << ", pixels per line="sv << (macos_input->source ? CGEventSourceGetPixelsPerLine(macos_input->source) : 10.0);
    BOOST_LOG(debug) << "Display "sv << macos_input->display << ", pixel dimension: " << CGDisplayPixelsWide(macos_input->display) << "x"sv << CGDisplayPixelsHigh(macos_input->display);

    return result;
  }

  void freeInput(void *p) {
    auto *input = static_cast<macos_input_t *>(p);

    {
      std::lock_guard lock(input->scroll_mutex);
      input->scroll.stopping = true;
      input->scroll_cv.notify_all();
    }
    if (input->scroll_thread.joinable()) {
      input->scroll_thread.join();
    }
    {
      std::vector<macos_input_policy::trackpad_gesture_packet_t> cancel_pkts;
      {
        std::lock_guard lock(input->gesture_emitter_mutex);
        cancel_pkts = input->trackpad_gesture_emitter.cancel_all();
      }
      if (!cancel_pkts.empty()) {
        post_trackpad_gesture_packets(
          input,
          CGPointMake(input->cursor.last_cursor_loc.x, input->cursor.last_cursor_loc.y),
          cancel_pkts
        );
      }
    }
    input->reusable_gesture_event.reset();
    macos_pen_hover_cursor_hide();
    macos_sc_set_cursor_visible(true);

    if (input->source) {
      CFRelease(input->source);
    }
    if (input->keyboard_source) {
      CFRelease(input->keyboard_source);
    }
    if (input->mouse_event) {
      CFRelease(input->mouse_event);
    }

    delete input;
  }

  std::vector<supported_gamepad_t> &supported_gamepads(input_t *input) {
    static std::vector gamepads {
      supported_gamepad_t {"", false, "gamepads.macos_not_implemented"}
    };
    return gamepads;
  }

  platform_caps::caps_t get_capabilities() {
    platform_caps::caps_t caps = 0;
    if (config::input.native_pen_touch) {
      caps |= platform_caps::pen_touch;
    }
    return caps;
  }
}  // namespace platf
