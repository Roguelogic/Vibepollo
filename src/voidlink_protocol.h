/**
 * @file src/voidlink_protocol.h
 * @brief Wire definitions and consistency policies for VoidLink Apple Pencil and macOS input extensions.
 */
#pragma once

#include <bit>
#include <cstddef>
#include <cstdint>
#include <string_view>

extern "C" {
#include <moonlight-common-c/src/Input.h>
#include <moonlight-common-c/src/Limelight.h>
}

namespace input::voidlink {
  // Extended pen packet adding stylus barrel roll (0..359 deg) after SS_PEN_PACKET.
  inline constexpr std::uint32_t pen_barrel_roll_magic = 0x5500000B;
  // Native macOS trackpad pinch-magnify & two-finger rotate packets.
  inline constexpr std::uint32_t mac_magnify_magic = 0x5500000C;
  inline constexpr std::uint32_t mac_rotate_magic = 0x5500000E;
  // Native Apple Pencil double-tap & Pencil Pro squeeze packet when custom shortcut is OFF.
  inline constexpr std::uint32_t apple_pencil_side_button_magic = 0x5500000D;

  inline constexpr std::uint16_t barrel_roll_unknown = 0xFFFF;

  inline constexpr std::uint8_t pencil_double_tap = 0;
  inline constexpr std::uint8_t pencil_squeeze_begin = 1;
  inline constexpr std::uint8_t pencil_squeeze_change = 2;
  inline constexpr std::uint8_t pencil_squeeze_end = 4;
  inline constexpr std::uint8_t pencil_squeeze_cancel = 8;

  inline constexpr std::uint8_t mac_gesture_begin = 1;
  inline constexpr std::uint8_t mac_gesture_change = 2;
  inline constexpr std::uint8_t mac_gesture_end = 4;
  inline constexpr std::uint8_t mac_gesture_cancel = 8;

#pragma pack(push, 1)
  struct pen_barrel_roll_packet_t {
    SS_PEN_PACKET pen;
    std::uint16_t barrelRoll;
    std::uint16_t reserved;
  };

  struct pencil_side_button_packet_t {
    NV_INPUT_HEADER header;
    std::uint8_t eventType;
    netfloat x;
    netfloat y;
  };

  struct mac_trackpad_gesture_packet_t {
    NV_INPUT_HEADER header;
    std::uint8_t phase;
    netfloat amount;
  };
#pragma pack(pop)

  static_assert(sizeof(SS_PEN_PACKET) == 36);
  static_assert(offsetof(pen_barrel_roll_packet_t, barrelRoll) == 36);
  static_assert(sizeof(pen_barrel_roll_packet_t) == 40);
  static_assert(sizeof(pencil_side_button_packet_t) == 17);
  static_assert(sizeof(mac_trackpad_gesture_packet_t) == 13);

  constexpr std::uint16_t decode_roll(std::uint16_t raw_le) noexcept {
    if constexpr (std::endian::native == std::endian::big) {
      raw_le = std::byteswap(raw_le);
    }
    return raw_le == barrel_roll_unknown ? barrel_roll_unknown : static_cast<std::uint16_t>(raw_le % 360);
  }

  constexpr bool valid_side_button_event(const std::uint8_t event_type) noexcept {
    return event_type == pencil_double_tap ||
           event_type == pencil_squeeze_begin ||
           event_type == pencil_squeeze_change ||
           event_type == pencil_squeeze_end ||
           event_type == pencil_squeeze_cancel;
  }

  constexpr bool valid_gesture_phase(const std::uint8_t phase) noexcept {
    return phase == mac_gesture_begin ||
           phase == mac_gesture_change ||
           phase == mac_gesture_end ||
           phase == mac_gesture_cancel;
  }

  // Preserves azimuth rotation on non-Pro Apple Pencils (which report constant 0 roll on iPadOS 17.5+)
  // until real barrel-roll variation is observed in the session.
  class roll_probe_t {
  public:
    constexpr void reset() noexcept {
      first_ = barrel_roll_unknown;
      varied_ = false;
    }

    constexpr std::uint16_t select(const std::uint16_t roll, const std::uint16_t azimuth) noexcept {
      if (roll == barrel_roll_unknown) {
        return azimuth;
      }
      if (first_ == barrel_roll_unknown) {
        first_ = roll;
      } else if (roll != first_) {
        varied_ = true;
      }
      return varied_ ? roll : azimuth;
    }

    constexpr bool has_varied() const noexcept {
      return varied_;
    }

  private:
    std::uint16_t first_ = barrel_roll_unknown;
    bool varied_ = false;
  };

  // Resolves whether incoming pen packets should use Wacom Drawing Tablet mode (`true`) or
  // iPad-style Scroll & Tap (`false`).
  // - "draw"   : always Drawing Tablet
  // - "scroll" : always Scroll & Tap
  // - "auto"   : follow VoidLink's Pencil Mode (`Stylus`/`Hovering Disabled` send VoidLink pen packets ->
  //              Drawing Tablet, while VoidLink `Touch` routes to `touch_update` -> Scroll & Tap and
  //              VoidLink `Mouse` routes to cursor/click); legacy Moonlight clients keep Scroll & Tap.
  constexpr bool resolve_pencil_draw_mode(
    const std::string_view configured_mode,
    const bool client_uses_voidlink_pen
  ) noexcept {
    if (configured_mode == "draw") {
      return true;
    }
    if (configured_mode == "scroll") {
      return false;
    }
    return client_uses_voidlink_pen;
  }

  // VoidLink's `Stroke Type: HD` hook filter (`phase1`) converts initial `LI_TOUCH_EVENT_DOWN` samples
  // into `LI_TOUCH_EVENT_HOVER` and begins surface contact directly with `LI_TOUCH_EVENT_MOVE`.
  // Both `DOWN` and `MOVE` mean the stylus tip is touching the surface.
  constexpr bool should_press_pen_tip(const std::uint8_t event_type, const bool currently_down) noexcept {
    switch (event_type) {
      case LI_TOUCH_EVENT_DOWN:
      case LI_TOUCH_EVENT_MOVE:
        return true;
      case LI_TOUCH_EVENT_BUTTON_ONLY:
        return currently_down;
      default:
        return false;
    }
  }
}  // namespace input::voidlink
