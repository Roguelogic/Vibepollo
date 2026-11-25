/**
 * @file src/platform/macos/input.cpp
 * @brief macOS core input backend: lifecycle, keyboard/unicode, mouse, cursor suppression, and gamepad stubs.
 *
 * Related modules:
 *  - input_scroll.cpp: continuous trackpad scroll, 120Hz momentum engine, wheel scroll, and pinch/rotate gestures.
 *  - input_pencil.cpp: per-client Apple Pencil (Draw/Scroll modes, hover reticle, side button) and standard touch.
 */
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOLLEvent.h>

#include "src/config.h"
#include "src/display_device.h"
#include "src/input.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/cf_guard.h"
#include "src/platform/macos/display_policy.h"
#include "src/platform/macos/input_internal.h"
#include "src/platform/macos/keymap.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/sc_video.h"
#include "src/platform/macos/virtual_display.h"
#include "src/utility.h"

namespace platf {
  using namespace std::literals;

  bool is_pen_tip_guard_active(const macos_input_t *macos_input) noexcept {
    if (!macos_input || !macos_input->pen_tip_active.load(std::memory_order_acquire)) {
      return false;
    }
    const auto now_ns = static_cast<std::int64_t>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    const auto last_ns = macos_input->pen_tip_last_activity_ns.load(std::memory_order_relaxed);
    constexpr std::int64_t max_hold_ns = 2'000'000'000LL;
    return last_ns > 0 && (now_ns - last_ns) <= max_hold_ns;
  }

  namespace {
    CGFloat display_scaling(const CGDirectDisplayID display) {
      const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
      if (!mode) {
        return 1;
      }
      const auto pixel_width = CGDisplayModeGetPixelWidth(mode);
      CGDisplayModeRelease(mode);
      return pixel_width ? ((CGFloat) CGDisplayPixelsWide(display)) / ((CGFloat) pixel_width) : 1;
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
        CGEventSetIntegerValueField(event, kCGMouseEventSubtype, kCGEventMouseSubtypeDefault);

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
  }  // namespace

  CGPoint clamp_point_to_bounds(const CGPoint &point, const CGRect &bounds) noexcept {
    const CGFloat max_x = std::max(bounds.origin.x, bounds.origin.x + bounds.size.width - 1.0);
    const CGFloat max_y = std::max(bounds.origin.y, bounds.origin.y + bounds.size.height - 1.0);
    return CGPointMake(
      std::clamp(point.x, bounds.origin.x, max_x),
      std::clamp(point.y, bounds.origin.y, max_y)
    );
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

  CGPoint stream_location(macos_input_t *macos_input, const touch_port_t &touch_port, const float x, const float y) {
    const auto geom = pointer_display_geometry(macos_input, touch_port);
    return CGPointMake(x * geom.scaling + geom.bounds.origin.x, y * geom.scaling + geom.bounds.origin.y);
  }

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

  void move_mouse(input_t &input, const int deltaX, const int deltaY) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    if (is_pen_tip_guard_active(macos_input)) {
      return;
    }
    const auto current = consume_trackpad_cursor_loc(input);
    const auto location = util::point_t {current.x + deltaX, current.y + deltaY};
    const auto [btn, ev_type] = active_mouse_move_state(input);
    post_mouse(input, btn, ev_type, location, current, 0);
  }

  void abs_mouse(input_t &input, const touch_port_t &touch_port, const float x, const float y) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    if (is_pen_tip_guard_active(macos_input)) {
      return;
    }
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
