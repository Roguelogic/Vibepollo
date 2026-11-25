/**
 * @file tests/unit/platform/macos/test_keymap.cpp
 * @brief Unit tests for O(1) Windows VKEY -> macOS virtual keycode translation and modifier helpers.
 */
#include <Carbon/Carbon.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <gtest/gtest.h>

#include "src/platform/macos/keymap.h"

namespace {

  TEST(MacosKeymap, TranslatesLettersDigitsFunctionAndNavigationKeysInConstantTime) {
    EXPECT_EQ(platf::keysym(0x41), kVK_ANSI_A);
    EXPECT_EQ(platf::keysym(0x5A), kVK_ANSI_Z);
    EXPECT_EQ(platf::keysym(0x30), kVK_ANSI_0);
    EXPECT_EQ(platf::keysym(0x39), kVK_ANSI_9);
    EXPECT_EQ(platf::keysym(0x0D), kVK_Return);
    EXPECT_EQ(platf::keysym(0x1B), kVK_Escape);
    EXPECT_EQ(platf::keysym(0x20), kVK_Space);
    EXPECT_EQ(platf::keysym(0x25), kVK_LeftArrow);
    EXPECT_EQ(platf::keysym(0x26), kVK_UpArrow);
    EXPECT_EQ(platf::keysym(0x27), kVK_RightArrow);
    EXPECT_EQ(platf::keysym(0x28), kVK_DownArrow);
    EXPECT_EQ(platf::keysym(0x70), kVK_F1);
    EXPECT_EQ(platf::keysym(0x83), kVK_F20);
    EXPECT_EQ(platf::keysym(0x5B), kVK_Command);
    EXPECT_EQ(platf::keysym(0x5C), kVK_RightCommand);
    EXPECT_EQ(platf::keysym(0xA0), kVK_Shift);
    EXPECT_EQ(platf::keysym(0xA1), kVK_RightShift);
  }

  TEST(MacosKeymap, RejectsUnmappedAndOutOfBoundsKeycodes) {
    EXPECT_EQ(platf::keysym(-1), -1);
    EXPECT_EQ(platf::keysym(0x00), -1);
    EXPECT_EQ(platf::keysym(0x0A /* VKEY_BACKTAB */), -1);
    EXPECT_EQ(platf::keysym(0x13 /* VKEY_PAUSE */), -1);
    EXPECT_EQ(platf::keysym(0x84 /* VKEY_F21 */), -1);
    EXPECT_EQ(platf::keysym(0xE2 /* VKEY_OEM_102 */), kVK_ISO_Section);
    EXPECT_EQ(platf::keysym(256), -1);
    EXPECT_EQ(platf::keysym(65535), -1);
    for (int vk = 0; vk < 256; ++vk) {
      const int mac_vk = platf::keysym(vk);
      if (mac_vk >= 0) {
        EXPECT_LE(mac_vk, 0x7F) << "VKEY 0x" << std::hex << vk << " mapped outside valid CGKeyCode range";
      }
    }
  }

  TEST(MacosKeymap, ResolvesLeftAndRightModifierDeviceFlags) {
    platf::modifier_flags_t flags {};
    ASSERT_TRUE(platf::modifier_flags_for_key(kVK_Command, flags));
    EXPECT_EQ(flags.generic, kCGEventFlagMaskCommand);
    EXPECT_EQ(flags.device, static_cast<CGEventFlags>(NX_DEVICELCMDKEYMASK));
    EXPECT_EQ(flags.all_devices, static_cast<CGEventFlags>(NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK));

    ASSERT_TRUE(platf::modifier_flags_for_key(kVK_RightOption, flags));
    EXPECT_EQ(flags.generic, kCGEventFlagMaskAlternate);
    EXPECT_EQ(flags.device, static_cast<CGEventFlags>(NX_DEVICERALTKEYMASK));

    EXPECT_FALSE(platf::modifier_flags_for_key(kVK_ANSI_A, flags));
  }

  TEST(MacosKeymap, DistinguishesPrintableAsciiFallbackFromControlKeys) {
    EXPECT_TRUE(platf::is_non_character_key(kVK_Return));
    EXPECT_TRUE(platf::is_non_character_key(kVK_F12));
    EXPECT_FALSE(platf::is_non_character_key(kVK_ANSI_A));

    EXPECT_EQ(platf::fallback_us_ansi_ascii(kVK_ANSI_A, false), 'a');
    EXPECT_EQ(platf::fallback_us_ansi_ascii(kVK_ANSI_A, true), 'A');
    EXPECT_EQ(platf::fallback_us_ansi_ascii(kVK_ANSI_2, false), '2');
    EXPECT_EQ(platf::fallback_us_ansi_ascii(kVK_ANSI_2, true), '@');
    EXPECT_EQ(platf::fallback_us_ansi_ascii(kVK_ANSI_Keypad7, false), '7');
    EXPECT_EQ(platf::fallback_us_ansi_ascii(kVK_ANSI_Keypad7, true), '7');
    EXPECT_EQ(platf::fallback_us_ansi_ascii(kVK_ANSI_KeypadDecimal, false), '.');
    EXPECT_EQ(platf::fallback_us_ansi_ascii(kVK_Return, false), 0);
  }

  TEST(MacosKeymap, ClassifiesSystemAuthProcessesForSecurePasswordInputMode) {
    EXPECT_TRUE(platf::is_system_auth_executable_path(
      "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent"
    ));
    EXPECT_TRUE(platf::is_system_auth_executable_path(
      "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha"
    ));
    EXPECT_TRUE(platf::is_system_auth_executable_path(
      "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
    ));
    EXPECT_TRUE(platf::is_system_auth_executable_path(
      "/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine"
    ));
    EXPECT_TRUE(platf::is_system_auth_executable_path(
      "/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/MacOS/CoreServicesUIAgent"
    ));

    // Normal Aqua apps (including Chromium/Electron apps that frequently keep Secure Event Input
    // enabled in the background) must NOT trigger LoginWindow-style IME blocking or ASCII stamping.
    EXPECT_FALSE(platf::is_system_auth_executable_path(
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    ));
    EXPECT_FALSE(platf::is_system_auth_executable_path(
      "/Applications/Discord.app/Contents/MacOS/Discord"
    ));
    EXPECT_FALSE(platf::is_system_auth_executable_path(
      "/System/Applications/App Store.app/Contents/MacOS/App Store"
    ));
    EXPECT_FALSE(platf::is_system_auth_executable_path(
      "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    ));
    EXPECT_FALSE(platf::is_system_auth_executable_path(
      "/Applications/SecurityAgent.app/Contents/MacOS/SecurityAgent"
    ));
    EXPECT_FALSE(platf::is_system_auth_executable_path(
      "/System/Library/../../Applications/SecurityAgent"
    ));
    EXPECT_FALSE(platf::is_system_auth_executable_path(""));

    // LoginWindow and Lock Screen always enable system password input mode.
    EXPECT_TRUE(platf::should_use_system_password_input(true, false, false, ""));
    EXPECT_TRUE(platf::should_use_system_password_input(false, false, true, ""));
    EXPECT_TRUE(platf::should_use_system_password_input(false, true, true, "/Applications/Discord.app/Contents/MacOS/Discord"));

    // Unlocked Aqua session: only system auth agents enable system password input mode.
    EXPECT_FALSE(platf::should_use_system_password_input(false, false, false, ""));
    EXPECT_FALSE(platf::should_use_system_password_input(false, true, false, ""));
    EXPECT_FALSE(platf::should_use_system_password_input(
      false, true, false, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    ));
    EXPECT_FALSE(platf::should_use_system_password_input(
      false, true, false, "/Applications/Discord.app/Contents/MacOS/Discord"
    ));
    EXPECT_TRUE(platf::should_use_system_password_input(
      false,
      true,
      false,
      "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent"
    ));
    EXPECT_TRUE(platf::should_use_system_password_input(
      false,
      true,
      false,
      "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha"
    ));
  }

}  // namespace
