/**
 * @file src/platform/macos/keymap.cpp
 * @brief O(1) Windows VKEY to macOS virtual keycode translation and LoginWindow ASCII Unicode layout helpers.
 */
#include "src/platform/macos/keymap.h"

#include <Carbon/Carbon.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <array>
#include <atomic>
#include <chrono>
#include <dispatch/dispatch.h>
#include <pthread.h>

namespace platf {
  namespace {
    struct key_code_pair_t {
      std::uint8_t win_keycode;
      std::int16_t mac_keycode;
    };

    // clang-format off
    constexpr key_code_pair_t kKeyCodePairs[] = {
      { 0x08 /* VKEY_BACK */,             kVK_Delete              },
      { 0x09 /* VKEY_TAB */,              kVK_Tab                 },
      { 0x0C /* VKEY_CLEAR */,            kVK_ANSI_KeypadClear    },
      { 0x0D /* VKEY_RETURN */,           kVK_Return              },
      { 0x10 /* VKEY_SHIFT */,            kVK_Shift               },
      { 0x11 /* VKEY_CONTROL */,          kVK_Control             },
      { 0x12 /* VKEY_MENU */,             kVK_Option              },
      { 0x14 /* VKEY_CAPITAL */,          kVK_CapsLock            },
      { 0x15 /* VKEY_KANA */,             kVK_JIS_Kana            },
      { 0x1B /* VKEY_ESCAPE */,           kVK_Escape              },
      { 0x20 /* VKEY_SPACE */,            kVK_Space               },
      { 0x21 /* VKEY_PRIOR */,            kVK_PageUp              },
      { 0x22 /* VKEY_NEXT */,             kVK_PageDown            },
      { 0x23 /* VKEY_END */,              kVK_End                 },
      { 0x24 /* VKEY_HOME */,             kVK_Home                },
      { 0x25 /* VKEY_LEFT */,             kVK_LeftArrow           },
      { 0x26 /* VKEY_UP */,               kVK_UpArrow             },
      { 0x27 /* VKEY_RIGHT */,            kVK_RightArrow          },
      { 0x28 /* VKEY_DOWN */,             kVK_DownArrow           },
      { 0x2D /* VKEY_INSERT */,           kVK_Help                },
      { 0x2E /* VKEY_DELETE */,           kVK_ForwardDelete       },
      { 0x2F /* VKEY_HELP */,             kVK_Help                },
      { 0x30 /* VKEY_0 */,                kVK_ANSI_0              },
      { 0x31 /* VKEY_1 */,                kVK_ANSI_1              },
      { 0x32 /* VKEY_2 */,                kVK_ANSI_2              },
      { 0x33 /* VKEY_3 */,                kVK_ANSI_3              },
      { 0x34 /* VKEY_4 */,                kVK_ANSI_4              },
      { 0x35 /* VKEY_5 */,                kVK_ANSI_5              },
      { 0x36 /* VKEY_6 */,                kVK_ANSI_6              },
      { 0x37 /* VKEY_7 */,                kVK_ANSI_7              },
      { 0x38 /* VKEY_8 */,                kVK_ANSI_8              },
      { 0x39 /* VKEY_9 */,                kVK_ANSI_9              },
      { 0x41 /* VKEY_A */,                kVK_ANSI_A              },
      { 0x42 /* VKEY_B */,                kVK_ANSI_B              },
      { 0x43 /* VKEY_C */,                kVK_ANSI_C              },
      { 0x44 /* VKEY_D */,                kVK_ANSI_D              },
      { 0x45 /* VKEY_E */,                kVK_ANSI_E              },
      { 0x46 /* VKEY_F */,                kVK_ANSI_F              },
      { 0x47 /* VKEY_G */,                kVK_ANSI_G              },
      { 0x48 /* VKEY_H */,                kVK_ANSI_H              },
      { 0x49 /* VKEY_I */,                kVK_ANSI_I              },
      { 0x4A /* VKEY_J */,                kVK_ANSI_J              },
      { 0x4B /* VKEY_K */,                kVK_ANSI_K              },
      { 0x4C /* VKEY_L */,                kVK_ANSI_L              },
      { 0x4D /* VKEY_M */,                kVK_ANSI_M              },
      { 0x4E /* VKEY_N */,                kVK_ANSI_N              },
      { 0x4F /* VKEY_O */,                kVK_ANSI_O              },
      { 0x50 /* VKEY_P */,                kVK_ANSI_P              },
      { 0x51 /* VKEY_Q */,                kVK_ANSI_Q              },
      { 0x52 /* VKEY_R */,                kVK_ANSI_R              },
      { 0x53 /* VKEY_S */,                kVK_ANSI_S              },
      { 0x54 /* VKEY_T */,                kVK_ANSI_T              },
      { 0x55 /* VKEY_U */,                kVK_ANSI_U              },
      { 0x56 /* VKEY_V */,                kVK_ANSI_V              },
      { 0x57 /* VKEY_W */,                kVK_ANSI_W              },
      { 0x58 /* VKEY_X */,                kVK_ANSI_X              },
      { 0x59 /* VKEY_Y */,                kVK_ANSI_Y              },
      { 0x5A /* VKEY_Z */,                kVK_ANSI_Z              },
      { 0x5B /* VKEY_LWIN */,             kVK_Command             },
      { 0x5C /* VKEY_RWIN */,             kVK_RightCommand        },
      { 0x5D /* VKEY_APPS */,             kVK_RightCommand        },
      { 0x60 /* VKEY_NUMPAD0 */,          kVK_ANSI_Keypad0        },
      { 0x61 /* VKEY_NUMPAD1 */,          kVK_ANSI_Keypad1        },
      { 0x62 /* VKEY_NUMPAD2 */,          kVK_ANSI_Keypad2        },
      { 0x63 /* VKEY_NUMPAD3 */,          kVK_ANSI_Keypad3        },
      { 0x64 /* VKEY_NUMPAD4 */,          kVK_ANSI_Keypad4        },
      { 0x65 /* VKEY_NUMPAD5 */,          kVK_ANSI_Keypad5        },
      { 0x66 /* VKEY_NUMPAD6 */,          kVK_ANSI_Keypad6        },
      { 0x67 /* VKEY_NUMPAD7 */,          kVK_ANSI_Keypad7        },
      { 0x68 /* VKEY_NUMPAD8 */,          kVK_ANSI_Keypad8        },
      { 0x69 /* VKEY_NUMPAD9 */,          kVK_ANSI_Keypad9        },
      { 0x6A /* VKEY_MULTIPLY */,         kVK_ANSI_KeypadMultiply },
      { 0x6B /* VKEY_ADD */,              kVK_ANSI_KeypadPlus     },
      { 0x6D /* VKEY_SUBTRACT */,         kVK_ANSI_KeypadMinus    },
      { 0x6E /* VKEY_DECIMAL */,          kVK_ANSI_KeypadDecimal  },
      { 0x6F /* VKEY_DIVIDE */,           kVK_ANSI_KeypadDivide   },
      { 0x70 /* VKEY_F1 */,               kVK_F1                  },
      { 0x71 /* VKEY_F2 */,               kVK_F2                  },
      { 0x72 /* VKEY_F3 */,               kVK_F3                  },
      { 0x73 /* VKEY_F4 */,               kVK_F4                  },
      { 0x74 /* VKEY_F5 */,               kVK_F5                  },
      { 0x75 /* VKEY_F6 */,               kVK_F6                  },
      { 0x76 /* VKEY_F7 */,               kVK_F7                  },
      { 0x77 /* VKEY_F8 */,               kVK_F8                  },
      { 0x78 /* VKEY_F9 */,               kVK_F9                  },
      { 0x79 /* VKEY_F10 */,              kVK_F10                 },
      { 0x7A /* VKEY_F11 */,              kVK_F11                 },
      { 0x7B /* VKEY_F12 */,              kVK_F12                 },
      { 0x7C /* VKEY_F13 */,              kVK_F13                 },
      { 0x7D /* VKEY_F14 */,              kVK_F14                 },
      { 0x7E /* VKEY_F15 */,              kVK_F15                 },
      { 0x7F /* VKEY_F16 */,              kVK_F16                 },
      { 0x80 /* VKEY_F17 */,              kVK_F17                 },
      { 0x81 /* VKEY_F18 */,              kVK_F18                 },
      { 0x82 /* VKEY_F19 */,              kVK_F19                 },
      { 0x83 /* VKEY_F20 */,              kVK_F20                 },
      { 0xA0 /* VKEY_LSHIFT */,           kVK_Shift               },
      { 0xA1 /* VKEY_RSHIFT */,           kVK_RightShift          },
      { 0xA2 /* VKEY_LCONTROL */,         kVK_Control             },
      { 0xA3 /* VKEY_RCONTROL */,         kVK_RightControl        },
      { 0xA4 /* VKEY_LMENU */,            kVK_Option              },
      { 0xA5 /* VKEY_RMENU */,            kVK_RightOption         },
      { 0xBA /* VKEY_OEM_1 */,            kVK_ANSI_Semicolon      },
      { 0xBB /* VKEY_OEM_PLUS */,         kVK_ANSI_Equal          },
      { 0xBC /* VKEY_OEM_COMMA */,        kVK_ANSI_Comma          },
      { 0xBD /* VKEY_OEM_MINUS */,        kVK_ANSI_Minus          },
      { 0xBE /* VKEY_OEM_PERIOD */,       kVK_ANSI_Period         },
      { 0xBF /* VKEY_OEM_2 */,            kVK_ANSI_Slash          },
      { 0xC0 /* VKEY_OEM_3 */,            kVK_ANSI_Grave          },
      { 0xDB /* VKEY_OEM_4 */,            kVK_ANSI_LeftBracket    },
      { 0xDC /* VKEY_OEM_5 */,            kVK_ANSI_Backslash      },
      { 0xDD /* VKEY_OEM_6 */,            kVK_ANSI_RightBracket   },
      { 0xDE /* VKEY_OEM_7 */,            kVK_ANSI_Quote          },
      { 0xE2 /* VKEY_OEM_102 */,          kVK_ISO_Section         },
      { 0xFE /* VKEY_OEM_CLEAR */,        kVK_ANSI_KeypadClear    },
    };
    // clang-format on

    constexpr std::array<std::int16_t, 256> kWinToMacKeyTable = []() constexpr {
      std::array<std::int16_t, 256> table {};
      table.fill(-1);
      for (const auto &entry : kKeyCodePairs) {
        table[entry.win_keycode] = entry.mac_keycode;
      }
      return table;
    }();

    std::atomic<CFDataRef> g_ascii_uchr_data {nullptr};
    std::atomic<bool> g_ascii_uchr_requested {false};

    void load_ascii_keyboard_layout_on_main(void *) {
      if (g_ascii_uchr_data.load(std::memory_order_acquire) != nullptr) {
        return;
      }
      TISInputSourceRef ascii_src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
      if (ascii_src) {
        const auto layout_data = static_cast<CFDataRef>(
          TISGetInputSourceProperty(ascii_src, kTISPropertyUnicodeKeyLayoutData)
        );
        if (layout_data) {
          if (CFDataRef copy = CFDataCreateCopy(kCFAllocatorDefault, layout_data)) {
            CFDataRef expected = nullptr;
            if (!g_ascii_uchr_data.compare_exchange_strong(expected, copy, std::memory_order_acq_rel)) {
              CFRelease(copy);
            }
          }
        }
        CFRelease(ascii_src);
      }
      if (g_ascii_uchr_data.load(std::memory_order_acquire) == nullptr) {
        g_ascii_uchr_requested.store(false, std::memory_order_release);
      }
    }
  }  // namespace

  int keysym(const int win_keycode) noexcept {
    if (win_keycode < 0 || win_keycode >= static_cast<int>(kWinToMacKeyTable.size())) {
      return -1;
    }
    return kWinToMacKeyTable[static_cast<std::size_t>(win_keycode)];
  }

  bool modifier_flags_for_key(const int key, modifier_flags_t &flags) noexcept {
    switch (key) {
      case kVK_Shift:
        flags = {kCGEventFlagMaskShift, NX_DEVICELSHIFTKEYMASK, NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK};
        return true;
      case kVK_RightShift:
        flags = {kCGEventFlagMaskShift, NX_DEVICERSHIFTKEYMASK, NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK};
        return true;
      case kVK_Command:
        flags = {kCGEventFlagMaskCommand, NX_DEVICELCMDKEYMASK, NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK};
        return true;
      case kVK_RightCommand:
        flags = {kCGEventFlagMaskCommand, NX_DEVICERCMDKEYMASK, NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK};
        return true;
      case kVK_Option:
        flags = {kCGEventFlagMaskAlternate, NX_DEVICELALTKEYMASK, NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK};
        return true;
      case kVK_RightOption:
        flags = {kCGEventFlagMaskAlternate, NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK};
        return true;
      case kVK_Control:
        flags = {kCGEventFlagMaskControl, NX_DEVICELCTLKEYMASK, NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK};
        return true;
      case kVK_RightControl:
        flags = {kCGEventFlagMaskControl, NX_DEVICERCTLKEYMASK, NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK};
        return true;
      default:
        return false;
    }
  }

  bool is_non_character_key(const int key) noexcept {
    switch (key) {
      case kVK_Return:
      case kVK_ANSI_KeypadEnter:
      case kVK_Tab:
      case kVK_Delete:
      case kVK_ForwardDelete:
      case kVK_Escape:
      case kVK_Home:
      case kVK_End:
      case kVK_PageUp:
      case kVK_PageDown:
      case kVK_LeftArrow:
      case kVK_RightArrow:
      case kVK_DownArrow:
      case kVK_UpArrow:
      case kVK_Help:
      case kVK_ANSI_KeypadClear:
      case kVK_CapsLock:
      case kVK_JIS_Kana:
      case kVK_F1:
      case kVK_F2:
      case kVK_F3:
      case kVK_F4:
      case kVK_F5:
      case kVK_F6:
      case kVK_F7:
      case kVK_F8:
      case kVK_F9:
      case kVK_F10:
      case kVK_F11:
      case kVK_F12:
      case kVK_F13:
      case kVK_F14:
      case kVK_F15:
      case kVK_F16:
      case kVK_F17:
      case kVK_F18:
      case kVK_F19:
      case kVK_F20:
        return true;
      default:
        return false;
    }
  }

  UniChar fallback_us_ansi_ascii(const int key, const bool shifted) noexcept {
    switch (key) {
      case kVK_ANSI_A: return shifted ? 'A' : 'a';
      case kVK_ANSI_B: return shifted ? 'B' : 'b';
      case kVK_ANSI_C: return shifted ? 'C' : 'c';
      case kVK_ANSI_D: return shifted ? 'D' : 'd';
      case kVK_ANSI_E: return shifted ? 'E' : 'e';
      case kVK_ANSI_F: return shifted ? 'F' : 'f';
      case kVK_ANSI_G: return shifted ? 'G' : 'g';
      case kVK_ANSI_H: return shifted ? 'H' : 'h';
      case kVK_ANSI_I: return shifted ? 'I' : 'i';
      case kVK_ANSI_J: return shifted ? 'J' : 'j';
      case kVK_ANSI_K: return shifted ? 'K' : 'k';
      case kVK_ANSI_L: return shifted ? 'L' : 'l';
      case kVK_ANSI_M: return shifted ? 'M' : 'm';
      case kVK_ANSI_N: return shifted ? 'N' : 'n';
      case kVK_ANSI_O: return shifted ? 'O' : 'o';
      case kVK_ANSI_P: return shifted ? 'P' : 'p';
      case kVK_ANSI_Q: return shifted ? 'Q' : 'q';
      case kVK_ANSI_R: return shifted ? 'R' : 'r';
      case kVK_ANSI_S: return shifted ? 'S' : 's';
      case kVK_ANSI_T: return shifted ? 'T' : 't';
      case kVK_ANSI_U: return shifted ? 'U' : 'u';
      case kVK_ANSI_V: return shifted ? 'V' : 'v';
      case kVK_ANSI_W: return shifted ? 'W' : 'w';
      case kVK_ANSI_X: return shifted ? 'X' : 'x';
      case kVK_ANSI_Y: return shifted ? 'Y' : 'y';
      case kVK_ANSI_Z: return shifted ? 'Z' : 'z';
      case kVK_ANSI_1: return shifted ? '!' : '1';
      case kVK_ANSI_2: return shifted ? '@' : '2';
      case kVK_ANSI_3: return shifted ? '#' : '3';
      case kVK_ANSI_4: return shifted ? '$' : '4';
      case kVK_ANSI_5: return shifted ? '%' : '5';
      case kVK_ANSI_6: return shifted ? '^' : '6';
      case kVK_ANSI_7: return shifted ? '&' : '7';
      case kVK_ANSI_8: return shifted ? '*' : '8';
      case kVK_ANSI_9: return shifted ? '(' : '9';
      case kVK_ANSI_0: return shifted ? ')' : '0';
      case kVK_ANSI_Minus: return shifted ? '_' : '-';
      case kVK_ANSI_Equal: return shifted ? '+' : '=';
      case kVK_ANSI_LeftBracket: return shifted ? '{' : '[';
      case kVK_ANSI_RightBracket: return shifted ? '}' : ']';
      case kVK_ANSI_Backslash: return shifted ? '|' : '\\';
      case kVK_ANSI_Semicolon: return shifted ? ':' : ';';
      case kVK_ANSI_Quote: return shifted ? '"' : '\'';
      case kVK_ANSI_Grave: return shifted ? '~' : '`';
      case kVK_ANSI_Comma: return shifted ? '<' : ',';
      case kVK_ANSI_Period: return shifted ? '>' : '.';
      case kVK_ANSI_Slash: return shifted ? '?' : '/';
      case kVK_ANSI_Keypad0: return '0';
      case kVK_ANSI_Keypad1: return '1';
      case kVK_ANSI_Keypad2: return '2';
      case kVK_ANSI_Keypad3: return '3';
      case kVK_ANSI_Keypad4: return '4';
      case kVK_ANSI_Keypad5: return '5';
      case kVK_ANSI_Keypad6: return '6';
      case kVK_ANSI_Keypad7: return '7';
      case kVK_ANSI_Keypad8: return '8';
      case kVK_ANSI_Keypad9: return '9';
      case kVK_ANSI_KeypadDecimal: return '.';
      case kVK_ANSI_KeypadMultiply: return '*';
      case kVK_ANSI_KeypadPlus: return '+';
      case kVK_ANSI_KeypadMinus: return '-';
      case kVK_ANSI_KeypadDivide: return '/';
      case kVK_ANSI_KeypadEquals: return '=';
      case kVK_Space: return ' ';
      default: return 0;
    }
  }

  std::int64_t effective_keyboard_type() noexcept {
    static std::atomic<std::uint64_t> last_refresh_ns {0};
    static std::atomic<std::int64_t> cached_type {40};

    const std::uint64_t now_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const std::uint64_t prev_ns = last_refresh_ns.load(std::memory_order_relaxed);
    if (prev_ns != 0 && (now_ns - prev_ns) < 5'000'000'000ULL) {
      return cached_type.load(std::memory_order_relaxed);
    }
    const UInt8 lm_type = LMGetKbdType();
    // Headless Macs with zero physical keyboards attached report LMGetKbdType() == 0;
    // default to US ANSI (40) so shifted symbols match standard ANSI keyboards.
    const std::int64_t resolved = lm_type != 0 ? static_cast<std::int64_t>(lm_type) : 40;
    cached_type.store(resolved, std::memory_order_relaxed);
    last_refresh_ns.store(now_ns, std::memory_order_relaxed);
    return resolved;
  }

  void ensure_ascii_keyboard_layout_cached() noexcept {
    if (g_ascii_uchr_data.load(std::memory_order_acquire) != nullptr) {
      return;
    }
    if (pthread_main_np() != 0) {
      load_ascii_keyboard_layout_on_main(nullptr);
    } else if (!g_ascii_uchr_requested.exchange(true, std::memory_order_acq_rel)) {
      dispatch_async_f(dispatch_get_main_queue(), nullptr, &load_ascii_keyboard_layout_on_main);
    }
  }

  void stamp_loginwindow_ascii_unicode(
    const CGEventRef event,
    const int key,
    const CGEventFlags kb_flags
  ) noexcept {
    if (!event ||
        is_non_character_key(key) ||
        (kb_flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) != 0) {
      return;
    }
    ensure_ascii_keyboard_layout_cached();
    if (const CFDataRef layout_data = g_ascii_uchr_data.load(std::memory_order_acquire)) {
      if (const auto *uchr = reinterpret_cast<const UCKeyboardLayout *>(CFDataGetBytePtr(layout_data))) {
        UInt32 mod_state = 0;
        if ((kb_flags & kCGEventFlagMaskShift) != 0) {
          mod_state |= (shiftKey >> 8);
        }
        if ((kb_flags & kCGEventFlagMaskAlternate) != 0) {
          mod_state |= (optionKey >> 8);
        }
        if ((kb_flags & kCGEventFlagMaskAlphaShift) != 0) {
          mod_state |= (alphaLock >> 8);
        }
        UInt32 dead_key_state = 0;
        UniChar chars[4] {};
        UniCharCount actual_len = 0;
        const OSStatus st = UCKeyTranslate(
          uchr,
          static_cast<UInt16>(key),
          kUCKeyActionDown,
          mod_state,
          static_cast<UInt32>(effective_keyboard_type()),
          kUCKeyTranslateNoDeadKeysMask,
          &dead_key_state,
          4,
          &actual_len,
          chars
        );
        if (st == noErr && actual_len > 0) {
          CGEventKeyboardSetUnicodeString(event, actual_len, chars);
          return;
        }
      }
    }

    const bool shifted = ((kb_flags & kCGEventFlagMaskShift) != 0) ^
                         ((kb_flags & kCGEventFlagMaskAlphaShift) != 0);
    if (const UniChar ch = fallback_us_ansi_ascii(key, shifted); ch != 0) {
      CGEventKeyboardSetUnicodeString(event, 1, &ch);
    }
  }

  bool is_system_auth_executable_path(const std::string_view executable_path) noexcept {
    constexpr std::string_view kSystemLibraryPrefix = "/System/Library/";
    if (!executable_path.starts_with(kSystemLibraryPrefix) ||
        executable_path.find("/../") != std::string_view::npos) {
      return false;
    }
    const std::size_t slash = executable_path.rfind('/');
    if (slash == std::string_view::npos || slash + 1 >= executable_path.size()) {
      return false;
    }
    const std::string_view name = executable_path.substr(slash + 1);
    return name == "SecurityAgent" ||
           name == "coreautha" ||
           name == "loginwindow" ||
           name == "ScreenSaverEngine" ||
           name == "LockScreen" ||
           name == "CoreServicesUIAgent" ||
           name == "LocalAuthenticationUIAgent";
  }

  bool should_use_system_password_input(
    const bool loginwindow_session,
    const bool secure_event_input_enabled,
    const bool screen_locked,
    const std::string_view secure_input_owner_path
  ) noexcept {
    if (loginwindow_session || screen_locked) {
      return true;
    }
    if (!secure_event_input_enabled) {
      return false;
    }
    return is_system_auth_executable_path(secure_input_owner_path);
  }

}  // namespace platf
