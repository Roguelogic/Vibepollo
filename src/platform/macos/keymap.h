/**
 * @file src/platform/macos/keymap.h
 * @brief Windows VKEY to macOS virtual keycode translation, modifier masks, and LoginWindow ASCII stamping.
 */
#pragma once

#include <ApplicationServices/ApplicationServices.h>
#include <cstdint>

namespace platf {

  struct modifier_flags_t {
    CGEventFlags generic {};
    CGEventFlags device {};
    CGEventFlags all_devices {};
  };

  /**
   * @brief Translates a Windows virtual-key code (0x00..0xFF) to a macOS kVK_* keycode in O(1) time.
   * @return macOS virtual keycode, or -1 if unmapped/unsupported.
   */
  [[nodiscard]] int keysym(int win_keycode) noexcept;

  /**
   * @brief Populates generic and device-specific NX modifier flags if `mac_keycode` is a modifier key.
   */
  [[nodiscard]] bool modifier_flags_for_key(int mac_keycode, modifier_flags_t &flags) noexcept;

  /**
   * @brief Returns true if `mac_keycode` is a non-printable control/navigation/function key.
   */
  [[nodiscard]] bool is_non_character_key(int mac_keycode) noexcept;

  /**
   * @brief US ANSI fallback character for pre-login / SecureEventInput password entry.
   */
  [[nodiscard]] UniChar fallback_us_ansi_ascii(int mac_keycode, bool shifted) noexcept;

  /**
   * @brief Cached physical keyboard type (defaults to US ANSI 40 on headless Macs).
   */
  [[nodiscard]] std::int64_t effective_keyboard_type() noexcept;

  /**
   * @brief Pre-caches the immutable ASCII keyboard layout `uchr` data on the main queue.
   */
  void ensure_ascii_keyboard_layout_cached() noexcept;

  /**
   * @brief Stamps the exact ASCII character onto secure/pre-login keyboard events without calling TIS* off-main.
   */
  void stamp_loginwindow_ascii_unicode(CGEventRef event, int mac_keycode, CGEventFlags kb_flags) noexcept;

}  // namespace platf
