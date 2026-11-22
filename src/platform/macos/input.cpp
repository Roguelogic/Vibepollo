/**
 * @file src/platform/macos/input.cpp
 * @brief Definitions for macOS input handling.
 */
// standard includes
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <thread>

// platform includes
#include <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <pthread.h>
#include <pthread/qos.h>

// local includes
#include "src/config.h"
#include "src/display_device.h"
#include "src/input.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/display_policy.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/sc_video.h"
#include "src/platform/macos/virtual_display.h"
#include "src/platform/macos/wheel_scroll.h"
#include "src/platform/macos/window_drag_prefetch.h"
#include "src/utility.h"
#include "src/voidlink_protocol.h"

/**
 * @brief Delay for a double click, in milliseconds.
 * @todo Make this configurable.
 */
constexpr std::chrono::milliseconds MULTICLICK_DELAY_MS(500);

namespace platf {
  using namespace std::literals;

  constexpr int WHEEL_DELTA = 120;
  constexpr double DEFAULT_SCROLLWHEEL_SCALING = 0.3125;
  constexpr int DEFAULT_SCROLL_LINES_PER_DETENT = 5;

  struct macos_input_t {
  public:
    CGDirectDisplayID configured_display {};  ///< Chosen at startup from output_name.
    CGDirectDisplayID display {};  ///< Display input currently targets; see current_display().
    CGRect displayBounds {};
    CGFloat displayScaling {};
    CGFloat displayBoundsWidth {};
    std::uint64_t displayGeneration {UINT64_MAX};
    CGEventSourceRef source {};

    // keyboard related stuff
    CGEventSourceRef keyboard_source {};
    CGEventFlags kb_flags {};
    std::chrono::steady_clock::time_point capslock_down_time {};

    // mouse related stuff
    CGEventRef mouse_event {};  // mouse event source
    util::point_t last_cursor_loc {};
    bool has_cursor_loc {};
    std::chrono::steady_clock::time_point last_cursor_update {};
    std::chrono::steady_clock::time_point last_mouse_warp {};
    double scrollwheel_scaling {DEFAULT_SCROLLWHEEL_SCALING};
    int scroll_lines_per_detent {DEFAULT_SCROLL_LINES_PER_DETENT};
    bool mouse_down[3] {};  // mouse button status
    std::chrono::steady_clock::steady_clock::time_point last_mouse_event[3][2];  // timestamp of last mouse events

    // continuous trackpad scroll & 120Hz momentum inertia state
    std::mutex scroll_mutex;
    std::condition_variable scroll_cv;
    std::thread scroll_thread;
    bool scroll_stopping {};
    bool scroll_in_gesture {};
    bool scroll_began_posted {};
    bool scroll_in_momentum {};
    bool scroll_momentum_first_tick {};
    bool scroll_cancelled_momentum {};
    bool trackpad_continuous_mode {true};
    int discrete_wheel_streak {};
    int scroll_sample_count {};
    bool scroll_peel_used_x {};
    bool scroll_peel_used_y {};
    double scroll_target_x {};
    double scroll_target_y {};
    std::int64_t scroll_emitted_x {};
    std::int64_t scroll_emitted_y {};
    double scroll_gesture_abs_x {};
    double scroll_gesture_abs_y {};
    double scroll_vx {};  ///< Pixels/sec horizontal velocity
    double scroll_vy {};  ///< Pixels/sec vertical velocity
    bool scroll_mom_ipados_style {};  ///< false = MacBook quartic, true = iPadOS exponential
    double scroll_mom_v0_x {};
    double scroll_mom_v0_y {};
    double scroll_mom_v0_speed {};
    double scroll_mom_duration {};
    double scroll_mom_total_x {};
    double scroll_mom_total_y {};
    double scroll_mom_emitted_x {};
    double scroll_mom_emitted_y {};
    CGPoint scroll_momentum_anchor {};
    bool scroll_has_momentum_anchor {};
    bool scroll_has_target_loc {};
    CGPoint scroll_target_loc {};
    bool touch_cursor_suppressed {};
    bool pen_hovering {};
    bool has_saved_trackpad_cursor {};
    CGPoint saved_trackpad_cursor {};
    bool trackpad_scroll_needs_warp {};
    bool cursor_restore_pending {};
    bool cursor_restore_post_move {};
    std::chrono::steady_clock::time_point cursor_restore_deadline {};
    std::chrono::steady_clock::time_point scroll_last_event {};
    std::chrono::steady_clock::time_point scroll_last_x_event {};
    std::chrono::steady_clock::time_point scroll_last_y_event {};
    std::chrono::steady_clock::time_point scroll_next_drag_tick {};
    std::chrono::steady_clock::time_point scroll_mom_start_time {};
    std::chrono::steady_clock::time_point scroll_next_mom_tick {};
    std::atomic<std::uint64_t> window_layout_mutation_epoch {0};
    window_drag_prefetch::coordinator_t drag_region_prefetch;
  };

  void cancel_scroll_momentum(macos_input_t *macos_input);
  double current_scroll_momentum_speed(macos_input_t *macos_input);
  void begin_touch_interaction(macos_input_t *macos_input);
  void schedule_touch_cursor_restore(macos_input_t *macos_input, std::chrono::milliseconds delay = 35ms, bool post_move = false);

  // Input coordinates are based on the display's points, not its pixels (Retina is 2 pixels per point).
  CGFloat display_scaling(const CGDirectDisplayID display) {
    const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) {
      return 1;
    }
    const auto pixel_width = CGDisplayModeGetPixelWidth(mode);
    CGDisplayModeRelease(mode);
    return pixel_width ? ((CGFloat) CGDisplayPixelsWide(display)) / ((CGFloat) pixel_width) : 1;
  }

  // The streamed display can change while input is running (the per-client virtual display comes
  // and goes with streams), so resolve it per event and refresh the scaling when it changes.
  CGDirectDisplayID current_display(macos_input_t *macos_input) {
    const CGDirectDisplayID display = macos_virtual_display::active_display_id().value_or(macos_input->configured_display);
    const std::uint64_t gen = macos_virtual_display::display_state_generation();
    if (display != macos_input->display || gen != macos_input->displayGeneration || macos_input->displayScaling <= 0 || macos_input->displayBoundsWidth <= 0) {
      const CGRect bounds = CGDisplayBounds(display);
      macos_input->display = display;
      macos_input->displayBounds = bounds;
      macos_input->displayBoundsWidth = bounds.size.width;
      macos_input->displayScaling = display_scaling(display);
      macos_input->displayGeneration = gen;
    }
    return display;
  }

  inline void note_window_layout_mutation(macos_input_t *macos_input) {
    macos_input->window_layout_mutation_epoch.fetch_add(1, std::memory_order_relaxed);
  }

  std::uint64_t current_window_layout_epoch(macos_input_t *macos_input) {
    const CGDirectDisplayID display = current_display(macos_input);
    std::uint64_t h = macos_input->displayGeneration;
    h ^= static_cast<std::uint64_t>(display) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
    const auto mutation = macos_input->window_layout_mutation_epoch.load(std::memory_order_relaxed);
    h ^= mutation + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
    return h;
  }

  CGRect target_display_bounds(macos_input_t *macos_input, const CGPoint &point) {
    const CGDirectDisplayID display = current_display(macos_input);
    if (macos_virtual_display::has_remote_displays()) {
      CGDirectDisplayID display_at_point = kCGNullDirectDisplay;
      uint32_t count = 0;
      if (CGGetDisplaysWithPoint(point, 1, &display_at_point, &count) == kCGErrorSuccess && count == 1 &&
          macos_virtual_display::is_remote_display(display_at_point)) {
        return display_at_point == display ? macos_input->displayBounds : CGDisplayBounds(display_at_point);
      }
    }
    return macos_input->displayBounds;
  }

  // A Remote Monitor stream's pointer belongs to its own display, which display() names in the
  // stream's touch port. Every other stream's goes to the streamed display.
  CGDirectDisplayID pointer_display(macos_input_t *macos_input, const touch_port_t &touch_port) {
    static std::atomic<CGDirectDisplayID> last_remote {kCGNullDirectDisplay};
    const auto stream_display = macos_display_policy::parse_display_identity(touch_port.output_name);
    const auto streamed = current_display(macos_input);
    const auto display = macos_display_policy::pointer_display(stream_display, macos_virtual_display::is_remote_display, streamed);
    if (display != streamed && last_remote.exchange(display) != display) {
      BOOST_LOG(info) << "Remote Monitor pointer: moving on display "sv << display;
    }
    return display;
  }

  // A struct to hold a Windows keycode to Mac virtual keycode mapping.
  struct KeyCodeMap {
    int win_keycode;
    int mac_keycode;
  };

  // Customized less operator for using std::lower_bound() on a KeyCodeMap array.
  bool operator<(const KeyCodeMap &a, const KeyCodeMap &b) {
    return a.win_keycode < b.win_keycode;
  }

  // clang-format off
const KeyCodeMap kKeyCodesMap[] = {
  { 0x08 /* VKEY_BACK */,                      kVK_Delete              },
  { 0x09 /* VKEY_TAB */,                       kVK_Tab                 },
  { 0x0A /* VKEY_BACKTAB */,                   0x21E4                  },
  { 0x0C /* VKEY_CLEAR */,                     kVK_ANSI_KeypadClear    },
  { 0x0D /* VKEY_RETURN */,                    kVK_Return              },
  { 0x10 /* VKEY_SHIFT */,                     kVK_Shift               },
  { 0x11 /* VKEY_CONTROL */,                   kVK_Control             },
  { 0x12 /* VKEY_MENU */,                      kVK_Option              },
  { 0x13 /* VKEY_PAUSE */,                     -1                      },
  { 0x14 /* VKEY_CAPITAL */,                   kVK_CapsLock            },
  { 0x15 /* VKEY_KANA */,                      kVK_JIS_Kana            },
  { 0x15 /* VKEY_HANGUL */,                    -1                      },
  { 0x17 /* VKEY_JUNJA */,                     -1                      },
  { 0x18 /* VKEY_FINAL */,                     -1                      },
  { 0x19 /* VKEY_HANJA */,                     -1                      },
  { 0x19 /* VKEY_KANJI */,                     -1                      },
  { 0x1B /* VKEY_ESCAPE */,                    kVK_Escape              },
  { 0x1C /* VKEY_CONVERT */,                   -1                      },
  { 0x1D /* VKEY_NONCONVERT */,                -1                      },
  { 0x1E /* VKEY_ACCEPT */,                    -1                      },
  { 0x1F /* VKEY_MODECHANGE */,                -1                      },
  { 0x20 /* VKEY_SPACE */,                     kVK_Space               },
  { 0x21 /* VKEY_PRIOR */,                     kVK_PageUp              },
  { 0x22 /* VKEY_NEXT */,                      kVK_PageDown            },
  { 0x23 /* VKEY_END */,                       kVK_End                 },
  { 0x24 /* VKEY_HOME */,                      kVK_Home                },
  { 0x25 /* VKEY_LEFT */,                      kVK_LeftArrow           },
  { 0x26 /* VKEY_UP */,                        kVK_UpArrow             },
  { 0x27 /* VKEY_RIGHT */,                     kVK_RightArrow          },
  { 0x28 /* VKEY_DOWN */,                      kVK_DownArrow           },
  { 0x29 /* VKEY_SELECT */,                    -1                      },
  { 0x2A /* VKEY_PRINT */,                     -1                      },
  { 0x2B /* VKEY_EXECUTE */,                   -1                      },
  { 0x2C /* VKEY_SNAPSHOT */,                  -1                      },
  { 0x2D /* VKEY_INSERT */,                    kVK_Help                },
  { 0x2E /* VKEY_DELETE */,                    kVK_ForwardDelete       },
  { 0x2F /* VKEY_HELP */,                      kVK_Help                },
  { 0x30 /* VKEY_0 */,                         kVK_ANSI_0              },
  { 0x31 /* VKEY_1 */,                         kVK_ANSI_1              },
  { 0x32 /* VKEY_2 */,                         kVK_ANSI_2              },
  { 0x33 /* VKEY_3 */,                         kVK_ANSI_3              },
  { 0x34 /* VKEY_4 */,                         kVK_ANSI_4              },
  { 0x35 /* VKEY_5 */,                         kVK_ANSI_5              },
  { 0x36 /* VKEY_6 */,                         kVK_ANSI_6              },
  { 0x37 /* VKEY_7 */,                         kVK_ANSI_7              },
  { 0x38 /* VKEY_8 */,                         kVK_ANSI_8              },
  { 0x39 /* VKEY_9 */,                         kVK_ANSI_9              },
  { 0x41 /* VKEY_A */,                         kVK_ANSI_A              },
  { 0x42 /* VKEY_B */,                         kVK_ANSI_B              },
  { 0x43 /* VKEY_C */,                         kVK_ANSI_C              },
  { 0x44 /* VKEY_D */,                         kVK_ANSI_D              },
  { 0x45 /* VKEY_E */,                         kVK_ANSI_E              },
  { 0x46 /* VKEY_F */,                         kVK_ANSI_F              },
  { 0x47 /* VKEY_G */,                         kVK_ANSI_G              },
  { 0x48 /* VKEY_H */,                         kVK_ANSI_H              },
  { 0x49 /* VKEY_I */,                         kVK_ANSI_I              },
  { 0x4A /* VKEY_J */,                         kVK_ANSI_J              },
  { 0x4B /* VKEY_K */,                         kVK_ANSI_K              },
  { 0x4C /* VKEY_L */,                         kVK_ANSI_L              },
  { 0x4D /* VKEY_M */,                         kVK_ANSI_M              },
  { 0x4E /* VKEY_N */,                         kVK_ANSI_N              },
  { 0x4F /* VKEY_O */,                         kVK_ANSI_O              },
  { 0x50 /* VKEY_P */,                         kVK_ANSI_P              },
  { 0x51 /* VKEY_Q */,                         kVK_ANSI_Q              },
  { 0x52 /* VKEY_R */,                         kVK_ANSI_R              },
  { 0x53 /* VKEY_S */,                         kVK_ANSI_S              },
  { 0x54 /* VKEY_T */,                         kVK_ANSI_T              },
  { 0x55 /* VKEY_U */,                         kVK_ANSI_U              },
  { 0x56 /* VKEY_V */,                         kVK_ANSI_V              },
  { 0x57 /* VKEY_W */,                         kVK_ANSI_W              },
  { 0x58 /* VKEY_X */,                         kVK_ANSI_X              },
  { 0x59 /* VKEY_Y */,                         kVK_ANSI_Y              },
  { 0x5A /* VKEY_Z */,                         kVK_ANSI_Z              },
  { 0x5B /* VKEY_LWIN */,                      kVK_Command             },
  { 0x5C /* VKEY_RWIN */,                      kVK_RightCommand        },
  { 0x5D /* VKEY_APPS */,                      kVK_RightCommand        },
  { 0x5F /* VKEY_SLEEP */,                     -1                      },
  { 0x60 /* VKEY_NUMPAD0 */,                   kVK_ANSI_Keypad0        },
  { 0x61 /* VKEY_NUMPAD1 */,                   kVK_ANSI_Keypad1        },
  { 0x62 /* VKEY_NUMPAD2 */,                   kVK_ANSI_Keypad2        },
  { 0x63 /* VKEY_NUMPAD3 */,                   kVK_ANSI_Keypad3        },
  { 0x64 /* VKEY_NUMPAD4 */,                   kVK_ANSI_Keypad4        },
  { 0x65 /* VKEY_NUMPAD5 */,                   kVK_ANSI_Keypad5        },
  { 0x66 /* VKEY_NUMPAD6 */,                   kVK_ANSI_Keypad6        },
  { 0x67 /* VKEY_NUMPAD7 */,                   kVK_ANSI_Keypad7        },
  { 0x68 /* VKEY_NUMPAD8 */,                   kVK_ANSI_Keypad8        },
  { 0x69 /* VKEY_NUMPAD9 */,                   kVK_ANSI_Keypad9        },
  { 0x6A /* VKEY_MULTIPLY */,                  kVK_ANSI_KeypadMultiply },
  { 0x6B /* VKEY_ADD */,                       kVK_ANSI_KeypadPlus     },
  { 0x6C /* VKEY_SEPARATOR */,                 -1                      },
  { 0x6D /* VKEY_SUBTRACT */,                  kVK_ANSI_KeypadMinus    },
  { 0x6E /* VKEY_DECIMAL */,                   kVK_ANSI_KeypadDecimal  },
  { 0x6F /* VKEY_DIVIDE */,                    kVK_ANSI_KeypadDivide   },
  { 0x70 /* VKEY_F1 */,                        kVK_F1                  },
  { 0x71 /* VKEY_F2 */,                        kVK_F2                  },
  { 0x72 /* VKEY_F3 */,                        kVK_F3                  },
  { 0x73 /* VKEY_F4 */,                        kVK_F4                  },
  { 0x74 /* VKEY_F5 */,                        kVK_F5                  },
  { 0x75 /* VKEY_F6 */,                        kVK_F6                  },
  { 0x76 /* VKEY_F7 */,                        kVK_F7                  },
  { 0x77 /* VKEY_F8 */,                        kVK_F8                  },
  { 0x78 /* VKEY_F9 */,                        kVK_F9                  },
  { 0x79 /* VKEY_F10 */,                       kVK_F10                 },
  { 0x7A /* VKEY_F11 */,                       kVK_F11                 },
  { 0x7B /* VKEY_F12 */,                       kVK_F12                 },
  { 0x7C /* VKEY_F13 */,                       kVK_F13                 },
  { 0x7D /* VKEY_F14 */,                       kVK_F14                 },
  { 0x7E /* VKEY_F15 */,                       kVK_F15                 },
  { 0x7F /* VKEY_F16 */,                       kVK_F16                 },
  { 0x80 /* VKEY_F17 */,                       kVK_F17                 },
  { 0x81 /* VKEY_F18 */,                       kVK_F18                 },
  { 0x82 /* VKEY_F19 */,                       kVK_F19                 },
  { 0x83 /* VKEY_F20 */,                       kVK_F20                 },
  { 0x84 /* VKEY_F21 */,                       -1                      },
  { 0x85 /* VKEY_F22 */,                       -1                      },
  { 0x86 /* VKEY_F23 */,                       -1                      },
  { 0x87 /* VKEY_F24 */,                       -1                      },
  { 0x90 /* VKEY_NUMLOCK */,                   -1                      },
  { 0x91 /* VKEY_SCROLL */,                    -1                      },
  { 0xA0 /* VKEY_LSHIFT */,                    kVK_Shift               },
  { 0xA1 /* VKEY_RSHIFT */,                    kVK_RightShift          },
  { 0xA2 /* VKEY_LCONTROL */,                  kVK_Control             },
  { 0xA3 /* VKEY_RCONTROL */,                  kVK_RightControl        },
  { 0xA4 /* VKEY_LMENU */,                     kVK_Option              },
  { 0xA5 /* VKEY_RMENU */,                     kVK_RightOption         },
  { 0xA6 /* VKEY_BROWSER_BACK */,              -1                      },
  { 0xA7 /* VKEY_BROWSER_FORWARD */,           -1                      },
  { 0xA8 /* VKEY_BROWSER_REFRESH */,           -1                      },
  { 0xA9 /* VKEY_BROWSER_STOP */,              -1                      },
  { 0xAA /* VKEY_BROWSER_SEARCH */,            -1                      },
  { 0xAB /* VKEY_BROWSER_FAVORITES */,         -1                      },
  { 0xAC /* VKEY_BROWSER_HOME */,              -1                      },
  { 0xAD /* VKEY_VOLUME_MUTE */,               -1                      },
  { 0xAE /* VKEY_VOLUME_DOWN */,               -1                      },
  { 0xAF /* VKEY_VOLUME_UP */,                 -1                      },
  { 0xB0 /* VKEY_MEDIA_NEXT_TRACK */,          -1                      },
  { 0xB1 /* VKEY_MEDIA_PREV_TRACK */,          -1                      },
  { 0xB2 /* VKEY_MEDIA_STOP */,                -1                      },
  { 0xB3 /* VKEY_MEDIA_PLAY_PAUSE */,          -1                      },
  { 0xB4 /* VKEY_MEDIA_LAUNCH_MAIL */,         -1                      },
  { 0xB5 /* VKEY_MEDIA_LAUNCH_MEDIA_SELECT */, -1                      },
  { 0xB6 /* VKEY_MEDIA_LAUNCH_APP1 */,         -1                      },
  { 0xB7 /* VKEY_MEDIA_LAUNCH_APP2 */,         -1                      },
  { 0xBA /* VKEY_OEM_1 */,                     kVK_ANSI_Semicolon      },
  { 0xBB /* VKEY_OEM_PLUS */,                  kVK_ANSI_Equal          },
  { 0xBC /* VKEY_OEM_COMMA */,                 kVK_ANSI_Comma          },
  { 0xBD /* VKEY_OEM_MINUS */,                 kVK_ANSI_Minus          },
  { 0xBE /* VKEY_OEM_PERIOD */,                kVK_ANSI_Period         },
  { 0xBF /* VKEY_OEM_2 */,                     kVK_ANSI_Slash          },
  { 0xC0 /* VKEY_OEM_3 */,                     kVK_ANSI_Grave          },
  { 0xDB /* VKEY_OEM_4 */,                     kVK_ANSI_LeftBracket    },
  { 0xDC /* VKEY_OEM_5 */,                     kVK_ANSI_Backslash      },
  { 0xDD /* VKEY_OEM_6 */,                     kVK_ANSI_RightBracket   },
  { 0xDE /* VKEY_OEM_7 */,                     kVK_ANSI_Quote          },
  { 0xDF /* VKEY_OEM_8 */,                     -1                      },
  { 0xE2 /* VKEY_OEM_102 */,                   -1                      },
  { 0xE5 /* VKEY_PROCESSKEY */,                -1                      },
  { 0xE7 /* VKEY_PACKET */,                    -1                      },
  { 0xF6 /* VKEY_ATTN */,                      -1                      },
  { 0xF7 /* VKEY_CRSEL */,                     -1                      },
  { 0xF8 /* VKEY_EXSEL */,                     -1                      },
  { 0xF9 /* VKEY_EREOF */,                     -1                      },
  { 0xFA /* VKEY_PLAY */,                      -1                      },
  { 0xFB /* VKEY_ZOOM */,                      -1                      },
  { 0xFC /* VKEY_NONAME */,                    -1                      },
  { 0xFD /* VKEY_PA1 */,                       -1                      },
  { 0xFE /* VKEY_OEM_CLEAR */,                 kVK_ANSI_KeypadClear    }
};
  // clang-format on

  int keysym(int keycode) {
    KeyCodeMap key_map {};

    key_map.win_keycode = keycode;
    const KeyCodeMap *temp_map = std::lower_bound(
      kKeyCodesMap,
      kKeyCodesMap + sizeof(kKeyCodesMap) / sizeof(kKeyCodesMap[0]),
      key_map
    );

    if (temp_map >= kKeyCodesMap + sizeof(kKeyCodesMap) / sizeof(kKeyCodesMap[0]) ||
        temp_map->win_keycode != keycode || temp_map->mac_keycode == -1) {
      return -1;
    }

    return temp_map->mac_keycode;
  }

  struct modifier_flags_t {
    CGEventFlags generic {};
    CGEventFlags device {};
    CGEventFlags all_devices {};
  };

  bool modifier_flags_for_key(int key, modifier_flags_t &flags) {
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

  // Triggers macOS's global input source switch (Control+Space, Symbolic Hotkey 60) at the HID tap
  // so iPad Magic Keyboard's 한/영 (Caps Lock) and Globe (0xFF) keys reliably toggle ABC <-> Korean.
  void toggle_input_source(macos_input_t *macos_input) {
    const CGEventFlags saved_flags = macos_input->kb_flags;
    const CGEventFlags ctrl_flags = saved_flags | kCGEventFlagMaskControl | NX_DEVICELCTLKEYMASK;

    if (CGEventRef ctrl_down = CGEventCreateKeyboardEvent(macos_input->keyboard_source, kVK_Control, true)) {
      CGEventSetFlags(ctrl_down, ctrl_flags);
      CGEventPost(kCGHIDEventTap, ctrl_down);
      CFRelease(ctrl_down);
    }
    if (CGEventRef space_down = CGEventCreateKeyboardEvent(macos_input->keyboard_source, kVK_Space, true)) {
      CGEventSetFlags(space_down, ctrl_flags);
      CGEventPost(kCGHIDEventTap, space_down);
      CFRelease(space_down);
    }
    if (CGEventRef space_up = CGEventCreateKeyboardEvent(macos_input->keyboard_source, kVK_Space, false)) {
      CGEventSetFlags(space_up, ctrl_flags);
      CGEventPost(kCGHIDEventTap, space_up);
      CFRelease(space_up);
    }
    if (CGEventRef ctrl_up = CGEventCreateKeyboardEvent(macos_input->keyboard_source, kVK_Control, false)) {
      CGEventSetFlags(ctrl_up, saved_flags);
      CGEventPost(kCGHIDEventTap, ctrl_up);
      CFRelease(ctrl_up);
    }
  }

  namespace {
    void ensure_event_sources(macos_input_t *macos_input) {
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

    int64_t effective_keyboard_type() {
      const UInt8 lm_type = LMGetKbdType();
      // Headless Macs with zero physical keyboards attached report LMGetKbdType() == 0 (or default
      // CGEvent field 3); default to US ANSI (40) so shifted symbols match standard ANSI keyboards.
      return lm_type != 0 ? static_cast<int64_t>(lm_type) : 40;
    }

    bool is_non_character_key(int key) {
      switch (key) {
        case kVK_Return:
        case kVK_ANSI_KeypadEnter:
        case kVK_Tab:
        case 0x21E4:
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

    std::atomic<CFDataRef> g_ascii_uchr_data {nullptr};
    std::atomic<bool> g_ascii_uchr_requested {false};

    void load_ascii_keyboard_layout_on_main(void *) {
      if (g_ascii_uchr_data.load(std::memory_order_acquire) != nullptr) {
        return;
      }
      TISInputSourceRef ascii_src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
      if (!ascii_src) {
        return;
      }
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

    // HIToolbox's TIS* APIs assert dispatch_get_main_queue() on macOS Tahoe whenever the input
    // source list refreshes (such as entering a SecureEventInput password field). Cache an
    // immutable CFData copy of the ASCII keyboard layout on the main thread and never call TIS*
    // from worker threads.
    void ensure_ascii_keyboard_layout_cached() {
      if (g_ascii_uchr_data.load(std::memory_order_acquire) != nullptr) {
        return;
      }
      if (pthread_main_np() != 0) {
        load_ascii_keyboard_layout_on_main(nullptr);
      } else if (!g_ascii_uchr_requested.exchange(true, std::memory_order_acq_rel)) {
        dispatch_async_f(dispatch_get_main_queue(), nullptr, &load_ascii_keyboard_layout_on_main);
      }
    }

    UniChar fallback_us_ansi_ascii(int key, bool shifted) {
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
        case kVK_Space: return ' ';
        default: return 0;
      }
    }

    // CGEventCreateKeyboardEvent populates the event's internal Unicode string BEFORE CGEventSetFlags
    // runs (leaving Shift+A as 'a' and Shift+2 as '2' inside the CGEvent), and LoginWindow on a
    // Korean Mac may also have 2SetKorean selected in /Library/Preferences/com.apple.HIToolbox.plist
    // with zero physical HID keyboards attached. Stamp the exact ASCII character from the cached
    // ASCII-capable layout onto secure/pre-login key events without touching TIS* off the main queue.
    void stamp_loginwindow_ascii_unicode(CGEventRef event, int key, CGEventFlags kb_flags) {
      if (is_non_character_key(key) ||
          (kb_flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) != 0) {
        return;
      }
      ensure_ascii_keyboard_layout_cached();
      const CFDataRef layout_data = g_ascii_uchr_data.load(std::memory_order_acquire);
      if (layout_data) {
        const auto *uchr = reinterpret_cast<const UCKeyboardLayout *>(CFDataGetBytePtr(layout_data));
        if (uchr) {
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
  }  // namespace

  void keyboard_update(input_t &input, uint16_t modcode, bool release, uint8_t flags) {
    (void) flags;
    auto macos_input = ((macos_input_t *) input.get());
    ensure_event_sources(macos_input);
    const bool secure_password_input = is_loginwindow_session() || IsSecureEventInputEnabled();

    // Globe / Language key (0xFF in VoidLink/Moonlight-iOS) or VK_HANGUL (0x15)
    if (modcode == 0xFF || modcode == 0x15) {
      if (!release && !secure_password_input) {
        toggle_input_source(macos_input);
      }
      return;
    }

    // Caps Lock / 한영 key (0x14) without Shift: toggle input source (Shift+CapsLock keeps real CapsLock)
    if (modcode == 0x14 && (macos_input->kb_flags & kCGEventFlagMaskShift) == 0 && !secure_password_input) {
      const auto now = std::chrono::steady_clock::now();
      if (!release) {
        macos_input->capslock_down_time = now;
        toggle_input_source(macos_input);
      } else {
        // Also handle hardware-latched CapsLock on iPadOS where alternate presses emit only key-up
        if (macos_input->capslock_down_time.time_since_epoch().count() != 0 &&
            (now - macos_input->capslock_down_time) > 350ms) {
          toggle_input_source(macos_input);
        }
        macos_input->capslock_down_time = {};
      }
      return;
    }

    auto key = keysym(modcode);

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
        macos_input->kb_flags &= ~modifier_flags.device;
        if ((macos_input->kb_flags & modifier_flags.all_devices) == 0) {
          macos_input->kb_flags &= ~modifier_flags.generic;
        }
      } else {
        cancel_scroll_momentum(macos_input);
        macos_input->kb_flags |= modifier_flags.generic | modifier_flags.device;
      }

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
        stamp_loginwindow_ascii_unicode(event, key, macos_input->kb_flags);
      }
    }

    CGEventSetFlags(event, macos_input->kb_flags);
    CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    CGEventPost(secure_password_input ? kCGHIDEventTap : kCGSessionEventTap, event);
    CFRelease(event);
    note_window_layout_mutation(macos_input);
  }

  void unicode(input_t &input, char *utf8, int size) {
    if (!utf8 || size <= 0) {
      return;
    }
    auto *macos_input = static_cast<macos_input_t *>(input.get());
    ensure_event_sources(macos_input);

    CFStringRef cf_str = CFStringCreateWithBytes(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8 *>(utf8),
      size,
      kCFStringEncodingUTF8,
      false
    );
    if (!cf_str) {
      return;
    }
    const CFIndex utf16_len = CFStringGetLength(cf_str);
    if (utf16_len > 0) {
      std::vector<UniChar> buf(static_cast<std::size_t>(utf16_len));
      CFStringGetCharacters(cf_str, CFRangeMake(0, utf16_len), buf.data());
      const CGEventTapLocation tap = is_loginwindow_session() ? kCGHIDEventTap : kCGSessionEventTap;
      for (const bool down : {true, false}) {
        if (CGEventRef ev = CGEventCreateKeyboardEvent(macos_input->keyboard_source, 0, down)) {
          CGEventKeyboardSetUnicodeString(ev, static_cast<UniCharCount>(buf.size()), buf.data());
          CGEventSetTimestamp(ev, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
          CGEventPost(tap, ev);
          CFRelease(ev);
        }
      }
    }
    CFRelease(cf_str);
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

  // returns current mouse location without a synchronous WindowServer Mach IPC trap during active input:
  util::point_t get_mouse_loc(input_t &input) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    const auto now = std::chrono::steady_clock::now();
    if (macos_input->has_cursor_loc &&
        macos_input->last_cursor_update.time_since_epoch().count() != 0 &&
        (now - macos_input->last_cursor_update) < 250ms) {
      return macos_input->last_cursor_loc;
    }
    if (const auto snapshot_event = CGEventCreate(macos_input->source)) {
      const auto current = CGEventGetLocation(snapshot_event);
      CFRelease(snapshot_event);
      macos_input->last_cursor_loc = {current.x, current.y};
      macos_input->has_cursor_loc = true;
      macos_input->last_cursor_update = now;
      return macos_input->last_cursor_loc;
    }
    return macos_input->last_cursor_loc;
  }

  CGPoint raw_system_cursor_point(macos_input_t *macos_input) {
    if (const auto snapshot_event = CGEventCreate(macos_input->source)) {
      const auto current = CGEventGetLocation(snapshot_event);
      CFRelease(snapshot_event);
      return current;
    }
    return CGPointMake(macos_input->last_cursor_loc.x, macos_input->last_cursor_loc.y);
  }

  // Updates touch/pencil cursor suppression state and snapshots `saved_trackpad_cursor` ONLY on
  // the initial transition from visible mouse/trackpad mode (`!touch_cursor_suppressed`), avoiding
  // redundant WindowServer `CGEventCreate` IPC traps on every 120-240Hz Apple Pencil hover sample.
  void suppress_cursor_for_touch_or_pen(macos_input_t *macos_input, const std::optional<bool> pen_hovering = std::nullopt) {
    bool need_snapshot = false;
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      macos_input->cursor_restore_pending = false;
      macos_input->cursor_restore_post_move = false;
      macos_input->trackpad_scroll_needs_warp = true;
      if (pen_hovering.has_value()) {
        macos_input->pen_hovering = *pen_hovering;
      }
      need_snapshot = !macos_input->touch_cursor_suppressed;
    }
    if (!need_snapshot) {
      return;
    }
    const CGPoint current_sys = raw_system_cursor_point(macos_input);
    std::lock_guard lock(macos_input->scroll_mutex);
    if (!macos_input->touch_cursor_suppressed) {
      macos_input->saved_trackpad_cursor = current_sys;
      macos_input->has_saved_trackpad_cursor = true;
      macos_input->touch_cursor_suppressed = true;
    }
  }

  // Snapshots `saved_trackpad_cursor` once on entry to touch/pencil interaction and hides the
  // standard macOS arrow cursor on SCStream.
  void begin_touch_interaction(macos_input_t *macos_input) {
    suppress_cursor_for_touch_or_pen(macos_input);
    macos_pen_hover_cursor_hide();
    macos_sc_set_cursor_visible(false);
  }

  // Enters Apple Pencil air hover: hides the standard macOS mouse arrow (`showsCursor = NO`) while
  // preserving `saved_trackpad_cursor`, and renders a crisp Windows-Ink-style stylus reticle right
  // at `location` so pen hover looks distinct from trackpad mouse movement.
  void begin_pen_hover_interaction(macos_input_t *macos_input, const CGPoint &location, const float distance_norm, const bool eraser) {
    suppress_cursor_for_touch_or_pen(macos_input, true);
    macos_sc_set_cursor_visible(false);
    macos_pen_hover_cursor_show(location.x, location.y, distance_norm, eraser);
  }

  void preserve_trackpad_cursor_for_pen_contact(macos_input_t *macos_input, const bool keep_pen_reticle, const CGPoint &location) {
    suppress_cursor_for_touch_or_pen(macos_input);
    macos_sc_set_cursor_visible(false);
    if (keep_pen_reticle) {
      macos_pen_hover_cursor_show(location.x, location.y, 0.0f, false);
    } else {
      macos_pen_hover_cursor_hide();
    }
  }

  // Marks touch/pencil interaction complete. Crucially, we NEVER warp WindowServer's cursor back
  // to `saved_trackpad_cursor` until the user actually uses the trackpad/mouse — warping back to
  // `saved_trackpad_cursor` on pencil/finger lift would re-enter whatever UI control the mouse was
  // previously parked over (e.g. Safari's green zoom button tiling menu, Dock magnification, or
  // YouTube hover previews). When `post_move` is true (Apple Pencil HOVER_LEAVE), we instead park
  // the hidden cursor on an inert neutral spot to clear the Pencil's last `:hover` target cleanly.
  void schedule_touch_cursor_restore(macos_input_t *macos_input, const std::chrono::milliseconds delay, const bool post_move) {
    std::lock_guard lock(macos_input->scroll_mutex);
    macos_input->trackpad_scroll_needs_warp = true;
    if (!post_move || macos_input->pen_hovering) {
      return;
    }
    if (macos_input->touch_cursor_suppressed) {
      macos_input->cursor_restore_pending = true;
      macos_input->cursor_restore_post_move = true;
      macos_input->cursor_restore_deadline = std::chrono::steady_clock::now() + delay;
      macos_input->scroll_cv.notify_one();
    }
  }

  // Finds a 100% inert point on the streamed display to park the hidden cursor after Apple Pencil
  // leaves hover (`LI_TOUCH_EVENT_HOVER_LEAVE`) so the hovered element clears without triggering
  // window traffic-light popups, Dock magnification, Stage Manager, Full-Screen menu bar, or Hot Corners.
  CGPoint neutral_hover_park_point(macos_input_t *macos_input) {
    current_display(macos_input);
    const CGRect b = macos_input->displayBounds;
    bool menu_bar_visible = false;
    if (const CFArrayRef window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)) {
      const CFIndex count = CFArrayGetCount(window_list);
      for (CFIndex i = 0; i < count; ++i) {
        const auto dict = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(window_list, i));
        if (!dict) {
          continue;
        }
        int layer = -1;
        if (const auto layer_num = static_cast<CFNumberRef>(CFDictionaryGetValue(dict, kCGWindowLayer))) {
          CFNumberGetValue(layer_num, kCFNumberIntType, &layer);
        }
        if (layer != 24) {
          continue;
        }
        CGRect wb {};
        const auto bounds_dict = static_cast<CFDictionaryRef>(CFDictionaryGetValue(dict, kCGWindowBounds));
        if (bounds_dict && CGRectMakeWithDictionaryRepresentation(bounds_dict, &wb) &&
            wb.size.height >= 18.0 && wb.size.height <= 48.0 &&
            wb.origin.y >= b.origin.y - 2.0 && wb.origin.y <= b.origin.y + 4.0 &&
            wb.origin.x <= b.origin.x + 16.0) {
          menu_bar_visible = true;
          break;
        }
      }
      CFRelease(window_list);
    }
    if (menu_bar_visible && b.size.width > 100.0 && b.size.height > 100.0) {
      // Empty middle region of the visible WindowServer Menu Bar (layer 24): sits above all app
      // windows so apps receive MouseExited/:hover-off, while having zero hover popups/tooltips.
      return CGPointMake(std::round(b.origin.x + b.size.width * 0.45), std::round(b.origin.y + 14.0));
    }
    // Native Full Screen fallback: 2pt inside the vertical midpoint of the right edge (avoids top
    // y=0 menu-bar reveal, bottom Dock reveal, left Stage Manager strip, and all 4 Hot Corners).
    return CGPointMake(
      std::clamp(b.origin.x + b.size.width - 2.0, b.origin.x, b.origin.x + std::max(1.0, b.size.width - 1.0)),
      std::round(b.origin.y + b.size.height * 0.5)
    );
  }

  void park_hidden_hover_cursor(macos_input_t *macos_input) {
    const CGPoint pt = neutral_hover_park_point(macos_input);
    CGWarpMouseCursorPosition(pt);
    CGAssociateMouseAndMouseCursorPosition(true);
    if (CGEventRef ev = CGEventCreateMouseEvent(macos_input->source, kCGEventMouseMoved, pt, kCGMouseButtonLeft)) {
      CGEventSetIntegerValueField(ev, kCGMouseEventClickState, 0);
      CGEventSetFlags(ev, macos_input->kb_flags);
      CGEventPost(kCGHIDEventTap, ev);
      CFRelease(ev);
    }
  }

  // Returns the authoritative trackpad/mouse cursor position, ignoring intermediate touch locations.
  util::point_t consume_trackpad_cursor_loc(input_t &input) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      macos_input->cursor_restore_pending = false;
      macos_input->cursor_restore_post_move = false;
      macos_input->trackpad_scroll_needs_warp = false;
      if (macos_input->touch_cursor_suppressed && macos_input->has_saved_trackpad_cursor) {
        return util::point_t {macos_input->saved_trackpad_cursor.x, macos_input->saved_trackpad_cursor.y};
      }
    }
    return get_mouse_loc(input);
  }

  // Ensures WindowServer's cursor is warped back to saved_trackpad_cursor ONLY when an actual
  // Magic Keyboard trackpad scroll arrives while `touch_cursor_suppressed` is still active.
  void flush_pending_cursor_restore_for_trackpad(macos_input_t *macos_input) {
    bool do_warp = false;
    CGPoint restore_pt {};
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      macos_input->cursor_restore_pending = false;
      macos_input->cursor_restore_post_move = false;
      if (macos_input->touch_cursor_suppressed &&
          macos_input->trackpad_scroll_needs_warp &&
          macos_input->has_saved_trackpad_cursor) {
        macos_input->trackpad_scroll_needs_warp = false;
        restore_pt = macos_input->saved_trackpad_cursor;
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
    const auto event = macos_input->mouse_event;

    {
      std::unique_lock lock(macos_input->scroll_mutex);
      if (macos_input->scroll_in_momentum) {
        const auto now_mom = std::chrono::steady_clock::now();
        const auto elapsed_mom = now_mom - macos_input->scroll_mom_start_time;
        if (!macos_input->scroll_has_momentum_anchor) {
          macos_input->scroll_momentum_anchor = CGPointMake(raw_location.x, raw_location.y);
          macos_input->scroll_has_momentum_anchor = true;
        }
        const double dist = std::hypot(
          raw_location.x - macos_input->scroll_momentum_anchor.x,
          raw_location.y - macos_input->scroll_momentum_anchor.y
        );
        // On a continuous trackpad (e.g. iPad Magic Keyboard), once fingers have lifted past the
        // 35ms peel window, ANY pointer contact/movement stops momentum immediately just like
        // resting a finger on a native MacBook/iPad trackpad. On a discrete desktop mouse wheel,
        // keep a 3pt deadband against desk sensor jitter.
        const bool should_cancel = macos_input->trackpad_continuous_mode ?
                                     (elapsed_mom >= 35ms || dist > 4.0) :
                                     (dist >= 3.0);
        if (should_cancel) {
          lock.unlock();
          cancel_scroll_momentum(macos_input);
        }
      }
    }

    // Keep the pointer on the streamed display, or on a Remote Monitor display, which someone is
    // also watching.
    const CGRect display_bounds = target_display_bounds(macos_input, CGPointMake(raw_location.x, raw_location.y));
    const auto location = CGPoint {
      std::clamp(raw_location.x, display_bounds.origin.x, display_bounds.origin.x + display_bounds.size.width - 1),
      std::clamp(raw_location.y, display_bounds.origin.y, display_bounds.origin.y + display_bounds.size.height - 1)
    };

    CGEventSetType(event, type);
    CGEventSetLocation(event, location);
    CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, button);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_count);

    // Include deltas so some 3D applications can consume changes (game cameras, etc)
    const double deltaX = raw_location.x - previous_location.x;
    const double deltaY = raw_location.y - previous_location.y;
    CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, deltaX);
    CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, deltaY);

    // Inject modifier flags and authoritative monotonic uptime timestamp so WindowServer, AppKit,
    // WebKit, and Metal receive real event cadence rather than the startup CGEvent's frozen t=0.
    CGEventSetFlags(event, macos_input->kb_flags);
    CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    CGEventPost(kCGHIDEventTap, event);
    const auto now = std::chrono::steady_clock::now();
    if (type == kCGEventMouseMoved &&
        (macos_input->last_mouse_warp.time_since_epoch().count() == 0 ||
         (now - macos_input->last_mouse_warp) >= 1500us)) {
      // Sync SCStream's cursor sprite at up to ~666Hz (1.5ms) with immediate cursor association
      // (matching Parsec) while still preventing >1000Hz SkyLight IPC buffer overflow.
      macos_input->last_mouse_warp = now;
      CGWarpMouseCursorPosition(location);
      CGAssociateMouseAndMouseCursorPosition(true);
    }
    macos_input->last_cursor_loc = {location.x, location.y};
    macos_input->has_cursor_loc = true;
    macos_input->last_cursor_update = now;

    bool show_cursor = false;
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      macos_input->saved_trackpad_cursor = location;
      macos_input->has_saved_trackpad_cursor = true;
      macos_input->cursor_restore_pending = false;
      macos_input->cursor_restore_post_move = false;
      macos_input->trackpad_scroll_needs_warp = false;
      macos_input->pen_hovering = false;
      if (macos_input->touch_cursor_suppressed) {
        macos_input->touch_cursor_suppressed = false;
        show_cursor = true;
      }
    }
    if (show_cursor) {
      macos_pen_hover_cursor_hide();
      macos_sc_set_cursor_visible(true);
    }
  }

  inline CGEventType event_type_mouse(input_t &input) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());

    if (macos_input->mouse_down[0]) {
      return kCGEventLeftMouseDragged;
    }
    if (macos_input->mouse_down[1]) {
      return kCGEventOtherMouseDragged;
    }
    if (macos_input->mouse_down[2]) {
      return kCGEventRightMouseDragged;
    }
    return kCGEventMouseMoved;
  }

  void move_mouse(
    input_t &input,
    const int deltaX,
    const int deltaY
  ) {
    const auto current = consume_trackpad_cursor_loc(input);

    const auto location = util::point_t {current.x + deltaX, current.y + deltaY};
    post_mouse(input, kCGMouseButtonLeft, event_type_mouse(input), location, current, 0);
  }

  // Maps a point in the stream's touch port to a global screen point on the display it belongs to.
  CGPoint stream_location(macos_input_t *macos_input, const touch_port_t &touch_port, const float x, const float y) {
    const auto display = pointer_display(macos_input, touch_port);
    const bool is_cached_display = (display == macos_input->display && macos_input->displayScaling > 0 && macos_input->displayBoundsWidth > 0);
    const auto scaling = is_cached_display ? macos_input->displayScaling : display_scaling(display);
    const CGRect display_bounds = is_cached_display ? macos_input->displayBounds : CGDisplayBounds(display);
    return CGPointMake(x * scaling + display_bounds.origin.x, y * scaling + display_bounds.origin.y);
  }

  void abs_mouse(
    input_t &input,
    const touch_port_t &touch_port,
    const float x,
    const float y
  ) {
    const auto macos_input = static_cast<macos_input_t *>(input.get());
    const auto location = stream_location(macos_input, touch_port, x, y);
    const auto prev = consume_trackpad_cursor_loc(input);

    post_mouse(input, kCGMouseButtonLeft, event_type_mouse(input), util::point_t {location.x, location.y}, prev, 0);
  }

  void button_mouse(input_t &input, const int button, const bool release) {
    CGMouseButton mac_button;
    CGEventType event;

    const auto macos_input = static_cast<macos_input_t *>(input.get());
    if (!release) {
      cancel_scroll_momentum(macos_input);
    }

    switch (button) {
      case 1:
        mac_button = kCGMouseButtonLeft;
        event = release ? kCGEventLeftMouseUp : kCGEventLeftMouseDown;
        break;
      case 2:
        mac_button = kCGMouseButtonCenter;
        event = release ? kCGEventOtherMouseUp : kCGEventOtherMouseDown;
        break;
      case 3:
        mac_button = kCGMouseButtonRight;
        event = release ? kCGEventRightMouseUp : kCGEventRightMouseDown;
        break;
      default:
        BOOST_LOG(warning) << "Unsupported mouse button for MacOS: "sv << button;
        return;
    }

    macos_input->mouse_down[mac_button] = !release;

    // if the last mouse down was less than MULTICLICK_DELAY_MS, we send a double click event
    const auto now = std::chrono::steady_clock::now();
    const auto mouse_position = consume_trackpad_cursor_loc(input);

    if (now < macos_input->last_mouse_event[mac_button][release] + MULTICLICK_DELAY_MS) {
      post_mouse(input, mac_button, event, mouse_position, mouse_position, 2);
    } else {
      post_mouse(input, mac_button, event, mouse_position, mouse_position, 1);
    }

    macos_input->last_mouse_event[mac_button][release] = now;
    note_window_layout_mutation(macos_input);
  }

  int get_scroll_lines_per_detent(double &scrollwheel_scaling) {
    double scale = DEFAULT_SCROLLWHEEL_SCALING;
    const auto value = CFPreferencesCopyValue(CFSTR("com.apple.scrollwheel.scaling"), kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (value) {
      if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType, &scale);
      } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
        scale = CFStringGetDoubleValue(static_cast<CFStringRef>(value));
      }
      CFRelease(value);
    }

    if (!std::isfinite(scale)) {
      scale = DEFAULT_SCROLLWHEEL_SCALING;
    }

    scrollwheel_scaling = scale;

    // com.apple.scrollwheel.scaling stores the Mouse scroll speed slider position, not
    // the scroll multiplier itself. The slider is 0..1 and Apple's default is 0.3125,
    // so anchor 0 at one line per wheel detent and 0.3125 at five lines.
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
    (void) scroll_phase;
    // Synthetic CGEvents have `[NSEvent _hidEvent] == NULL`. Setting `kCGScrollWheelEventScrollPhase`
    // or `kCGScrollWheelEventMomentumPhase` causes AppKit/SwiftUI `.paging` and `.viewAligned`
    // scroll views (e.g. Apple Music shelves) to see zero HID velocity on `PhaseEnded`, snap back
    // to page 0, and ignore synthetic momentum events. Pure `IsContinuous = 1` pixel events
    // (`ScrollPhase = 0`, `MomentumPhase = 0`) execute synchronously from Tick 0 across AppKit,
    // SwiftUI, and WebKit (`WKWebView` CSS `scroll-snap-type: x mandatory`).
    if (wheelY == 0 && wheelX == 0) {
      return;
    }

    CGEventRef event = CGEventCreateScrollWheelEvent(macos_input->source, kCGScrollEventUnitPixel, 2, wheelY, wheelX);
    if (!event) {
      return;
    }

    if (target_loc) {
      CGEventSetLocation(event, *target_loc);
    }
    CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);
    // Momentum coasting events carry empty modifier flags so pressing Cmd after a flick
    // never triggers accidental Cmd+Scroll zoom in browsers/editors.
    CGEventSetFlags(event, momentum_phase != 0 ? 0 : macos_input->kb_flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
  }

  void post_gesture_event_locked(macos_input_t *input, int dy, int dx, uint32_t phase, uint32_t momentum) {
    post_scroll_event_raw(
      input,
      dy,
      dx,
      phase,
      momentum,
      input->scroll_has_target_loc ? &input->scroll_target_loc : nullptr
    );
  }

  void cancel_scroll_momentum(macos_input_t *macos_input) {
    std::lock_guard lock(macos_input->scroll_mutex);
    if (macos_input->scroll_in_momentum) {
      macos_input->scroll_in_momentum = false;
      macos_input->scroll_has_momentum_anchor = false;
      macos_input->scroll_vx = 0;
      macos_input->scroll_vy = 0;
      macos_input->scroll_mom_v0_x = 0;
      macos_input->scroll_mom_v0_y = 0;
      macos_input->scroll_mom_v0_speed = 0;
      macos_input->scroll_mom_duration = 0;
      macos_input->scroll_mom_total_x = 0;
      macos_input->scroll_mom_total_y = 0;
      macos_input->scroll_mom_emitted_x = 0;
      macos_input->scroll_mom_emitted_y = 0;
      if (!macos_input->scroll_momentum_first_tick) {
        post_gesture_event_locked(macos_input, 0, 0, 0, kCGMomentumScrollPhaseEnd);
      }
      if (macos_input->scroll_has_target_loc && macos_input->touch_cursor_suppressed) {
        macos_input->trackpad_scroll_needs_warp = true;
      }
    }
  }

  double current_scroll_momentum_speed(macos_input_t *macos_input) {
    std::lock_guard lock(macos_input->scroll_mutex);
    if (!macos_input->scroll_in_momentum) {
      return 0.0;
    }
    const auto now = std::chrono::steady_clock::now();
    const double elapsed = std::max(0.0, std::chrono::duration<double>(now - macos_input->scroll_mom_start_time).count());
    if (macos_input->scroll_mom_ipados_style) {
      return macos_input->scroll_mom_v0_speed * std::exp(-2.0 * elapsed);
    }
    const double duration = std::max(0.001, macos_input->scroll_mom_duration);
    const double u = std::clamp(1.0 - elapsed / duration, 0.0, 1.0);
    return macos_input->scroll_mom_v0_speed * (u * u * u);
  }

  // Starts either MacBook trackpad momentum (AppKit _NSScrollingMomentumCalculator quartic curve)
  // or iPadOS momentum (UIKit UIScrollViewDecelerationRateNormal 0.998/ms exponential curve),
  // according to config::input.macos_scroll_inertia ("macos", "ipados", "disabled").
  bool start_scroll_momentum_locked(
    macos_input_t *macos_input,
    const std::chrono::steady_clock::time_point now,
    const bool immediate_first_tick = false
  ) {
    const auto &mode = config::input.macos_scroll_inertia;
    if (mode == "disabled") {
      macos_input->scroll_vx = 0;
      macos_input->scroll_vy = 0;
      return false;
    }

    const double total_abs = std::hypot(macos_input->scroll_gesture_abs_x, macos_input->scroll_gesture_abs_y);
    if (macos_input->scroll_sample_count < 2 || total_abs < 10.0) {
      macos_input->scroll_vx = 0;
      macos_input->scroll_vy = 0;
      return false;
    }
    // When two fingers touch the trackpad to catch/stop an active momentum scroll, fingertips
    // naturally shift a few pixels on contact before resting still. Suppress re-launching momentum
    // unless the user performs a deliberate follow-through swipe (>= 4 samples & >= 28px & >= 220px/s).
    if (macos_input->scroll_cancelled_momentum &&
        (macos_input->scroll_sample_count < 4 || total_abs < 28.0)) {
      macos_input->scroll_vx = 0;
      macos_input->scroll_vy = 0;
      return false;
    }

    // Lock momentum to the predominant axis when the swipe was strongly 1D (> 2.5:1), preventing
    // accidental cross-axis finger-lift twitch from making horizontal/vertical coasting drift diagonally.
    if (macos_input->scroll_gesture_abs_x > 14.0 &&
        macos_input->scroll_gesture_abs_x > 2.5 * macos_input->scroll_gesture_abs_y) {
      macos_input->scroll_vy = 0.0;
    } else if (macos_input->scroll_gesture_abs_y > 14.0 &&
               macos_input->scroll_gesture_abs_y > 2.5 * macos_input->scroll_gesture_abs_x) {
      macos_input->scroll_vx = 0.0;
    }

    const bool ipados_style = (mode == "ipados");
    const double speed = std::hypot(macos_input->scroll_vx, macos_input->scroll_vy);
    const double min_speed = macos_input->scroll_cancelled_momentum ? 220.0 : (ipados_style ? 85.0 : 80.0);
    if (speed < min_speed) {
      macos_input->scroll_vx = 0;
      macos_input->scroll_vy = 0;
      return false;
    }

    macos_input->scroll_in_momentum = true;
    macos_input->scroll_momentum_first_tick = true;
    macos_input->scroll_momentum_anchor =
      (macos_input->touch_cursor_suppressed && macos_input->has_saved_trackpad_cursor) ?
        macos_input->saved_trackpad_cursor :
        CGPointMake(macos_input->last_cursor_loc.x, macos_input->last_cursor_loc.y);
    macos_input->scroll_has_momentum_anchor = true;
    macos_input->scroll_mom_ipados_style = ipados_style;
    macos_input->scroll_mom_v0_x = macos_input->scroll_vx;
    macos_input->scroll_mom_v0_y = macos_input->scroll_vy;
    macos_input->scroll_mom_v0_speed = speed;
    macos_input->scroll_mom_emitted_x = 0.0;
    macos_input->scroll_mom_emitted_y = 0.0;
    macos_input->scroll_mom_start_time = immediate_first_tick ? (now - 8333us) : now;
    macos_input->scroll_next_mom_tick = immediate_first_tick ? now : (now + 8333us);

    if (!ipados_style) {
      const double duration = 0.063 * std::cbrt(speed);
      macos_input->scroll_mom_duration = duration;
      macos_input->scroll_mom_total_x = macos_input->scroll_vx * duration * 0.25;
      macos_input->scroll_mom_total_y = macos_input->scroll_vy * duration * 0.25;
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
      // Never synthesize flick velocity from a single contact sample; real velocity requires >= 2 samples.
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
      // Preserve flick speed across at most ONE trailing finger-peel sample as two fingers lift off Magic Keyboard.
      // Consecutive decelerating samples mean the user is actively braking on the trackpad to stop.
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
    const double share = smooth ? wheel_scroll_policy::drag_gain : 1.0;
    const int dx = wheel_scroll_policy::drag_step(input->scroll_target_x, input->scroll_emitted_x, share);
    const int dy = wheel_scroll_policy::drag_step(input->scroll_target_y, input->scroll_emitted_y, share);
    if (!dx && !dy) {
      return false;
    }
    const auto phase = !input->scroll_began_posted ? kCGScrollPhaseBegan : kCGScrollPhaseChanged;
    post_gesture_event_locked(input, dy, dx, phase, 0);
    input->scroll_began_posted = true;
    input->scroll_emitted_x += dx;
    input->scroll_emitted_y += dy;
    return true;
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

    constexpr auto drag_tick_interval = 8333us;  // 120Hz VSync-aligned de-jitter cadence

    const auto now = std::chrono::steady_clock::now();
    {
      std::lock_guard lock(macos_input->scroll_mutex);
      const bool was_in_momentum = macos_input->scroll_in_momentum;
      const double mom_age = was_in_momentum ?
                               std::chrono::duration<double>(now - macos_input->scroll_mom_start_time).count() :
                               999.0;
      // If a Wi-Fi/VPN gap briefly exceeded gesture_idle_timeout (< 70ms ago) and packets continue
      // arriving in the same scroll direction, treat them as a continuation of the active swipe
      // rather than a stationary finger-down momentum catch.
      const bool same_dir_continuation =
        was_in_momentum && mom_age <= 0.070 &&
        ((delta_x_px * macos_input->scroll_mom_v0_x > 0.0 && std::abs(delta_x_px) >= 1.0) ||
         (delta_y_px * macos_input->scroll_mom_v0_y > 0.0 && std::abs(delta_y_px) >= 1.0));

      if (was_in_momentum) {
        macos_input->scroll_in_momentum = false;
        macos_input->scroll_has_momentum_anchor = false;
        macos_input->scroll_vx = 0;
        macos_input->scroll_vy = 0;
        if (!macos_input->scroll_momentum_first_tick) {
          post_gesture_event_locked(macos_input, 0, 0, 0, kCGMomentumScrollPhaseEnd);
        }
      }

      if (macos_input->scroll_in_gesture && macos_input->scroll_has_target_loc != (target_loc != nullptr)) {
        post_pending_drag_locked(macos_input, false);
        if (macos_input->scroll_began_posted) {
          post_gesture_event_locked(macos_input, 0, 0, kCGScrollPhaseEnded, 0);
        }
        macos_input->scroll_in_gesture = false;
      }
      const bool starting = !macos_input->scroll_in_gesture;
      if (starting) {
        macos_input->scroll_in_gesture = true;
        macos_input->scroll_began_posted = false;
        macos_input->scroll_cancelled_momentum = was_in_momentum && !same_dir_continuation;
        macos_input->scroll_sample_count = 0;
        macos_input->scroll_peel_used_x = false;
        macos_input->scroll_peel_used_y = false;
        macos_input->scroll_target_x = 0;
        macos_input->scroll_target_y = 0;
        macos_input->scroll_emitted_x = 0;
        macos_input->scroll_emitted_y = 0;
        if (!same_dir_continuation) {
          macos_input->scroll_gesture_abs_x = 0;
          macos_input->scroll_gesture_abs_y = 0;
        }
        macos_input->scroll_vx = 0;
        macos_input->scroll_vy = 0;
        macos_input->scroll_last_x_event = {};
        macos_input->scroll_last_y_event = {};
        macos_input->scroll_next_drag_tick = now;
        if (target_loc && macos_input->touch_cursor_suppressed) {
          CGWarpMouseCursorPosition(*target_loc);
        }
      }
      macos_input->scroll_has_target_loc = (target_loc != nullptr);
      if (target_loc) {
        macos_input->scroll_target_loc = *target_loc;
      }

      macos_input->scroll_last_event = now;
      ++macos_input->scroll_sample_count;

      double raw_dy = delta_y_px;
      double raw_dx = delta_x_px;
      // When two fingers land on the trackpad to catch/brake a coasting scroll, absorb the initial
      // sub-5px fingertip compression roll so the page halts cleanly on the exact current pixel.
      if (starting && macos_input->scroll_cancelled_momentum && std::hypot(raw_dx, raw_dy) <= 5.0) {
        raw_dy = 0.0;
        raw_dx = 0.0;
      }

      macos_input->scroll_gesture_abs_y += std::abs(raw_dy);
      macos_input->scroll_gesture_abs_x += std::abs(raw_dx);
      update_axis_velocity(
        macos_input->scroll_vy,
        macos_input->scroll_peel_used_y,
        macos_input->scroll_last_y_event,
        now,
        raw_dy,
        starting,
        macos_input->scroll_sample_count
      );
      update_axis_velocity(
        macos_input->scroll_vx,
        macos_input->scroll_peel_used_x,
        macos_input->scroll_last_x_event,
        now,
        raw_dx,
        starting,
        macos_input->scroll_sample_count
      );
      double eff_dy = raw_dy;
      double eff_dx = raw_dx;
      if (macos_input->scroll_gesture_abs_x > 8.0 &&
          macos_input->scroll_gesture_abs_x > 2.5 * macos_input->scroll_gesture_abs_y &&
          std::abs(eff_dy) <= 3.0) {
        eff_dy = 0.0;
      } else if (macos_input->scroll_gesture_abs_y > 8.0 &&
                 macos_input->scroll_gesture_abs_y > 2.5 * macos_input->scroll_gesture_abs_x &&
                 std::abs(eff_dx) <= 3.0) {
        eff_dx = 0.0;
      }
      macos_input->scroll_target_y += eff_dy;
      macos_input->scroll_target_x += eff_dx;

      const bool began = macos_input->scroll_began_posted;
      if ((!began || now >= macos_input->scroll_next_drag_tick) && post_pending_drag_locked(macos_input, began)) {
        macos_input->scroll_next_drag_tick = now + drag_tick_interval;
      }
      macos_input->scroll_cv.notify_one();
    }
  }

  void finish_drag_locked(macos_input_t *input, std::chrono::steady_clock::time_point now, bool immediate_momentum) {
    input->scroll_in_gesture = false;
    post_pending_drag_locked(input, false);
    if (input->scroll_began_posted) {
      post_gesture_event_locked(input, 0, 0, kCGScrollPhaseEnded, 0);
    }
    if (input->scroll_last_y_event.time_since_epoch().count() == 0 ||
        (input->scroll_last_event - input->scroll_last_y_event) > 55ms ||
        (now - input->scroll_last_y_event) > 105ms) {
      input->scroll_vy = 0;
    }
    if (input->scroll_last_x_event.time_since_epoch().count() == 0 ||
        (input->scroll_last_event - input->scroll_last_x_event) > 55ms ||
        (now - input->scroll_last_x_event) > 105ms) {
      input->scroll_vx = 0;
    }
    if (!input->scroll_began_posted || !start_scroll_momentum_locked(input, now, immediate_momentum)) {
      input->scroll_vx = 0;
      input->scroll_vy = 0;
      if (input->scroll_has_target_loc && input->touch_cursor_suppressed) {
        input->trackpad_scroll_needs_warp = true;
      }
    }
  }

  void finish_continuous_scroll_gesture(macos_input_t *input) {
    std::lock_guard lock(input->scroll_mutex);
    if (input->scroll_in_gesture) {
      finish_drag_locked(input, std::chrono::steady_clock::now(), false);
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
      bool do_hover_park = false;
      bool has_loc = false;
      uint32_t mom_phase = 0;
      int step_y = 0;
      int step_x = 0;

      {
        std::unique_lock lock(macos_input->scroll_mutex);
        macos_input->scroll_cv.wait(lock, [&]() {
          return macos_input->scroll_stopping ||
                 macos_input->scroll_in_gesture ||
                 macos_input->scroll_in_momentum ||
                 macos_input->cursor_restore_pending;
        });
        if (macos_input->scroll_stopping) {
          return;
        }
        has_loc = macos_input->scroll_has_target_loc;

        if (macos_input->scroll_in_gesture) {
          // Trackpad wheel gestures have no explicit finger-up packet and stream over Wi-Fi/VPN,
          // whereas direct touch/pen call finish_continuous_scroll_gesture() immediately on UP.
          const auto gesture_idle_timeout = macos_input->scroll_has_target_loc ? 28ms : 42ms;
          const auto idle_deadline = macos_input->scroll_last_event + gesture_idle_timeout;
          const bool has_pending_drag = (std::llround(macos_input->scroll_target_y) != macos_input->scroll_emitted_y ||
                                         std::llround(macos_input->scroll_target_x) != macos_input->scroll_emitted_x);
          const auto wake_deadline = (has_pending_drag && macos_input->scroll_next_drag_tick < idle_deadline) ?
                                       macos_input->scroll_next_drag_tick :
                                       idle_deadline;

          macos_input->scroll_cv.wait_until(lock, wake_deadline);
          if (macos_input->scroll_stopping) {
            return;
          }
          const auto now = std::chrono::steady_clock::now();
          if (!macos_input->scroll_in_gesture) {
            continue;
          }
          const auto idle = macos_input->scroll_has_target_loc ? 28ms : 42ms;
          if (now >= macos_input->scroll_last_event + idle) {
            finish_drag_locked(macos_input, now, true);
          } else if (now >= macos_input->scroll_next_drag_tick &&
                     post_pending_drag_locked(macos_input, macos_input->scroll_began_posted)) {
            macos_input->scroll_next_drag_tick += momentum_tick_interval;
            if (macos_input->scroll_next_drag_tick <= now) {
              macos_input->scroll_next_drag_tick = now + momentum_tick_interval;
            }
          }
        } else if (macos_input->scroll_in_momentum) {
          macos_input->scroll_cv.wait_until(lock, macos_input->scroll_next_mom_tick);
          if (macos_input->scroll_stopping) {
            return;
          }
          if (macos_input->scroll_in_momentum) {
            const auto now = std::chrono::steady_clock::now();
            macos_input->scroll_next_mom_tick += momentum_tick_interval;
            if (macos_input->scroll_next_mom_tick <= now) {
              macos_input->scroll_next_mom_tick = now + momentum_tick_interval;
            }
            const double elapsed = std::max(0.0, std::chrono::duration<double>(now - macos_input->scroll_mom_start_time).count());

            if (macos_input->scroll_mom_ipados_style) {
              // Exact analytical integral of iPadOS UIScrollViewDecelerationRateNormal (0.998/ms, k = 2.0/s):
              // x(t) = (v0 / k) * (1 - exp(-k * t)), immune to timer wakeup jitter.
              constexpr double k = 2.0;
              const double exp_kt = std::exp(-k * elapsed);
              const double factor = (1.0 - exp_kt) / k;
              const double target_x = macos_input->scroll_mom_v0_x * factor;
              const double target_y = macos_input->scroll_mom_v0_y * factor;
              step_x = static_cast<int>(std::lround(target_x - macos_input->scroll_mom_emitted_x));
              step_y = static_cast<int>(std::lround(target_y - macos_input->scroll_mom_emitted_y));
              macos_input->scroll_mom_emitted_x += step_x;
              macos_input->scroll_mom_emitted_y += step_y;

              if (step_x != 0 || step_y != 0) {
                mom_phase = macos_input->scroll_momentum_first_tick ? kCGMomentumScrollPhaseBegin : kCGMomentumScrollPhaseContinue;
                macos_input->scroll_momentum_first_tick = false;
                do_mom_tick = true;
              }

              if (macos_input->scroll_mom_v0_speed * exp_kt < 42.0) {
                macos_input->scroll_in_momentum = false;
                macos_input->scroll_has_momentum_anchor = false;
                macos_input->scroll_vx = 0;
                macos_input->scroll_vy = 0;
                do_mom_end = !macos_input->scroll_momentum_first_tick;
                if (has_loc && macos_input->touch_cursor_suppressed) {
                  macos_input->trackpad_scroll_needs_warp = true;
                }
              }
            } else {
              // MacBook Force Touch trackpad AppKit _NSScrollingMomentumCalculator: 1 - (1 - t/T)^4
              const double duration = std::max(0.001, macos_input->scroll_mom_duration);
              const double t_norm = std::clamp(elapsed / duration, 0.0, 1.0);
              const double u = 1.0 - t_norm;
              const double progress = 1.0 - (u * u * u * u);

              const double target_x = macos_input->scroll_mom_total_x * progress;
              const double target_y = macos_input->scroll_mom_total_y * progress;
              step_x = static_cast<int>(std::lround(target_x - macos_input->scroll_mom_emitted_x));
              step_y = static_cast<int>(std::lround(target_y - macos_input->scroll_mom_emitted_y));
              macos_input->scroll_mom_emitted_x += step_x;
              macos_input->scroll_mom_emitted_y += step_y;

              if (step_x != 0 || step_y != 0) {
                mom_phase = macos_input->scroll_momentum_first_tick ? kCGMomentumScrollPhaseBegin : kCGMomentumScrollPhaseContinue;
                macos_input->scroll_momentum_first_tick = false;
                do_mom_tick = true;
              }

              if (t_norm >= 1.0) {
                macos_input->scroll_in_momentum = false;
                macos_input->scroll_has_momentum_anchor = false;
                macos_input->scroll_vx = 0;
                macos_input->scroll_vy = 0;
                do_mom_end = !macos_input->scroll_momentum_first_tick;
                if (has_loc && macos_input->touch_cursor_suppressed) {
                  macos_input->trackpad_scroll_needs_warp = true;
                }
              }
            }
          }
          if (do_mom_tick) {
            post_gesture_event_locked(macos_input, step_y, step_x, 0, mom_phase);
          }
          if (do_mom_end) {
            post_gesture_event_locked(macos_input, 0, 0, 0, kCGMomentumScrollPhaseEnd);
          }
        } else if (macos_input->cursor_restore_pending) {
          const auto deadline = macos_input->cursor_restore_deadline;
          macos_input->scroll_cv.wait_until(lock, deadline);
          if (macos_input->scroll_stopping) {
            return;
          }
          const auto now = std::chrono::steady_clock::now();
          if (macos_input->cursor_restore_pending &&
              !macos_input->pen_hovering &&
              !macos_input->scroll_in_gesture &&
              !macos_input->scroll_in_momentum &&
              now >= macos_input->cursor_restore_deadline) {
            macos_input->cursor_restore_pending = false;
            if (macos_input->cursor_restore_post_move && macos_input->touch_cursor_suppressed) {
              do_hover_park = true;
            }
            macos_input->cursor_restore_post_move = false;
          }
        }
      }

      if (do_hover_park) {
        park_hidden_hover_cursor(macos_input);
      }
    }
  }

  void post_scroll(macos_input_t *macos_input, const int wheelY, const int wheelX) {
    post_scroll_event_raw(macos_input, wheelY, wheelX, 0, 0);
  }

  void post_scroll(input_t &input, const int wheelY, const int wheelX) {
    post_scroll(static_cast<macos_input_t *>(input.get()), wheelY, wheelX);
  }

  bool is_continuous_trackpad_scroll(macos_input_t *macos_input, const int high_res_distance) {
    if ((high_res_distance % WHEEL_DELTA) != 0) {
      std::lock_guard lock(macos_input->scroll_mutex);
      macos_input->trackpad_continuous_mode = true;
      macos_input->discrete_wheel_streak = 0;
      return true;
    }
    std::lock_guard lock(macos_input->scroll_mutex);
    if (macos_input->scroll_in_gesture || macos_input->scroll_in_momentum) {
      return true;
    }
    if (macos_input->trackpad_continuous_mode) {
      if (std::abs(high_res_distance) == WHEEL_DELTA) {
        if (++macos_input->discrete_wheel_streak >= 3) {
          macos_input->trackpad_continuous_mode = false;
          return false;
        }
      } else {
        macos_input->discrete_wheel_streak = 0;
      }
      return true;
    }
    return false;
  }

  // Convert wheel packets to macOS pixels.
  // Synthetic CGEvents (`[NSEvent _hidEvent] == NULL`) are NOT inverted by macOS's
  // `com.apple.swipescrolldirection` preference: negative wheel1 always scrolls down (matching
  // Windows WM_MOUSEWHEEL / Moonlight vertical scroll), while negative wheel2 scrolls right
  // (opposite to Windows WM_MOUSEHWHEEL / Moonlight horizontal scroll).
  void wheel_scroll(input_t &input, int high_res_distance, bool horizontal) {
    auto *macos_input = static_cast<macos_input_t *>(input.get());
    flush_pending_cursor_restore_for_trackpad(macos_input);
    const double sign = horizontal ? -1.0 : 1.0;
    const double base_pixels = scroll_pixels_exact(macos_input, high_res_distance) * sign;
    if (is_continuous_trackpad_scroll(macos_input, high_res_distance)) {
      const double dx = horizontal ? base_pixels : 0.0;
      const double dy = horizontal ? 0.0 : base_pixels;
      continuous_scroll_delta(macos_input, dy, dx);
    } else {
      cancel_scroll_momentum(macos_input);
      const int px = static_cast<int>(std::lround(base_pixels));
      post_scroll(macos_input, horizontal ? 0 : px, horizontal ? px : 0);
    }
    note_window_layout_mutation(macos_input);
  }

  void scroll(input_t &input, const int high_res_distance) {
    wheel_scroll(input, high_res_distance, false);
  }

  void hscroll(input_t &input, int high_res_distance) {
    wheel_scroll(input, high_res_distance, true);
  }

  // Checks whether `pt` should start a mouse drag immediately (without waiting for LONG_PRESS):
  // 1) Any point NOT inside a foreground application window (0 <= layer < 20) — i.e. the macOS
  //    Desktop (rubber-band marquee selection & Desktop icon dragging), Desktop Widgets, Menu Bar,
  //    and Dock — none of which are scrollable.
  // 2) The top titlebar/toolbar strip (54pt) or outer resize frame (8pt) of the frontmost visible
  //    application window.
  bool is_window_drag_region(const CGPoint &pt) {
    const CFArrayRef window_list = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID
    );
    if (!window_list) {
      return false;
    }
    bool hit_app_window = false;
    bool on_window_chrome = false;
    const CFIndex count = CFArrayGetCount(window_list);
    for (CFIndex i = 0; i < count; ++i) {
      const auto dict = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(window_list, i));
      if (!dict) {
        continue;
      }
      int layer = -1;
      if (const auto layer_num = static_cast<CFNumberRef>(CFDictionaryGetValue(dict, kCGWindowLayer))) {
        CFNumberGetValue(layer_num, kCFNumberIntType, &layer);
      }
      // Foreground app windows/panels/popovers use layers 0..19; Dock (20), Menu Bar (24),
      // Widgets (< 0), and Finder Desktop (< 0) lie outside 0..19.
      if (layer < 0 || layer >= 20) {
        continue;
      }
      double alpha = 1.0;
      if (const auto alpha_num = static_cast<CFNumberRef>(CFDictionaryGetValue(dict, kCGWindowAlpha))) {
        CFNumberGetValue(alpha_num, kCFNumberDoubleType, &alpha);
      }
      if (alpha <= 0.01) {
        continue;
      }
      CGRect bounds {};
      const auto bounds_dict = static_cast<CFDictionaryRef>(CFDictionaryGetValue(dict, kCGWindowBounds));
      if (!bounds_dict || !CGRectMakeWithDictionaryRepresentation(bounds_dict, &bounds)) {
        continue;
      }
      if (bounds.size.width < 40.0 || bounds.size.height < 40.0) {
        continue;
      }
      constexpr CGFloat edge_slop = 8.0;
      const CGRect expanded = CGRectInset(bounds, -edge_slop, -edge_slop);
      if (!CGRectContainsPoint(expanded, pt)) {
        continue;
      }
      hit_app_window = true;
      constexpr CGFloat titlebar_height = 54.0;
      const bool on_titlebar = (pt.y >= bounds.origin.y - edge_slop) && (pt.y <= bounds.origin.y + titlebar_height);
      const bool on_resize_edge =
        (pt.x <= bounds.origin.x + edge_slop) ||
        (pt.x >= bounds.origin.x + bounds.size.width - edge_slop) ||
        (pt.y >= bounds.origin.y + bounds.size.height - edge_slop);
      on_window_chrome = on_titlebar || on_resize_edge;
      break;
    }
    CFRelease(window_list);
    return !hit_app_window || on_window_chrome;
  }

  /**
   * @brief Per-client pen and touch state.
   *
   * The pen is posted as a tablet device: proximity events as it enters, leaves, or changes tool,
   * and mouse events carrying the tablet fields (pressure, tilt, rotation, buttons) while it is
   * in range. Touch has no public injection API on macOS, so one finger scrolls (hold, then
   * move, to drag), a tap clicks, and two fingers scroll.
   */
  class macos_client_input_t: public client_input_t {
  public:
    explicit macos_client_input_t(macos_input_t *macos_input):
        macos_input {macos_input} {
    }

    ~macos_client_input_t() override {
      leave_pen_hover(false);
      pen_scroll_release();
      pen_release();
      touch_release();
    }

    void pen_update(const touch_port_t &touch_port, const pen_input_t &pen);
    void pencil_side_button(const touch_port_t &touch_port, const pencil_side_button_input_t &btn);
    void touch_update(const touch_port_t &touch_port, const touch_input_t &touch);

  private:
    // Pen buttons, in the order used for the pressed state: tip, then the barrel buttons.
    enum pen_button_e {
      PEN_TIP,
      PEN_PRIMARY,
      PEN_SECONDARY,
      PEN_TERTIARY,
      PEN_BUTTON_COUNT
    };

    struct touch_point_t {
      CGPoint start;
      CGPoint last;
      std::chrono::steady_clock::time_point down_time;
    };

    // A tap (down and up with little movement) clicks; moving past this many points scrolls/drags.
    static constexpr double TOUCH_SLOP = 6;
    static constexpr double PEN_SLOP = 8;
    // Holding still this long makes the next movement drag instead of scroll.
    static constexpr std::chrono::milliseconds LONG_PRESS {350};
    static constexpr std::chrono::milliseconds PEN_DRAG_HOLD {300};
    static constexpr double MULTICLICK_DISTANCE = 8;
    static constexpr int POINTER_PEN = 1;  // NX_TABLET_POINTER_PEN
    static constexpr int POINTER_ERASER = 3;  // NX_TABLET_POINTER_ERASER
    // NX_TABLET_CAPABILITY_ DEVICEID, BUTTONS, TILTX, TILTY, PRESSURE, and ROTATION.
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
      const CGRect bounds = target_display_bounds(macos_input, point);
      return CGPointMake(
        std::clamp(point.x, bounds.origin.x, bounds.origin.x + bounds.size.width - 1),
        std::clamp(point.y, bounds.origin.y, bounds.origin.y + bounds.size.height - 1)
      );
    }

    void post_event(CGEventRef event) const {
      CGEventSetFlags(event, macos_input->kb_flags);
      CGEventPost(kCGHIDEventTap, event);
      CFRelease(event);
    }

    // Posts a mouse event at location; pressure and tilt are set for pen events only.
    // sync_cursor is true ONLY in Drawing Tablet mode so touch & iPad-style Pencil never teleport the cursor.
    void post_mouse_event(
      const CGEventType type,
      const CGMouseButton button,
      const CGPoint &location,
      const int click_count,
      const pen_input_t *pen = nullptr,
      const bool sync_cursor = false
    ) {
      const bool is_down = (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown);
      if (is_down || type == kCGEventMouseMoved) {
        // Ensure WindowServer's hardware cursor is already at `location` before MouseDown/MouseMoved
        // arrives so AppKit [NSEvent mouseLocation] / NSTrackingArea / WKWebView :hover / Dock magnify
        // hit-test `location` immediately on frame 0.
        CGWarpMouseCursorPosition(location);
      }

      const auto event = CGEventCreateMouseEvent(macos_input->source, type, location, button);
      if (!event) {
        return;
      }

      CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_count);
      const double delta_x = (!is_down && have_location) ? (location.x - last_location.x) : 0.0;
      const double delta_y = (!is_down && have_location) ? (location.y - last_location.y) : 0.0;
      CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, delta_x);
      CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, delta_y);

      if (pen) {
        double tilt_x = 0;
        double tilt_y = 0;
        // Convert the tilt from vertical and the direction it leans into X and Y tilt, from -1 to 1.
        if (pen->tilt != LI_TILT_UNKNOWN && pen->rotation != LI_ROT_UNKNOWN) {
          const auto rotation = pen->rotation * (M_PI / 180);
          const auto tilt = pen->tilt * (M_PI / 180);
          const auto r = std::sin(tilt);
          const auto z = std::cos(tilt);
          tilt_x = std::atan2(std::sin(-rotation) * r, z) / (M_PI / 2);
          tilt_y = std::atan2(std::cos(-rotation) * r, z) / (M_PI / 2);
        }

        int buttons = 0;
        for (int i = 0; i < PEN_BUTTON_COUNT; ++i) {
          if (pen_down[i]) {
            buttons |= 1 << i;
          }
        }

        // The subtype has to be set before the other tablet fields.
        CGEventSetIntegerValueField(event, kCGMouseEventSubtype, kCGEventMouseSubtypeTabletPoint);
        CGEventSetIntegerValueField(event, kCGTabletEventPointButtons, buttons);
        const double pressure = pen_down[PEN_TIP] ? (pen->pressureOrDistance > 0.0f ? pen->pressureOrDistance : 0.5) : 0.0;
        CGEventSetDoubleValueField(event, kCGTabletEventPointPressure, pressure);
        // NSEvent.pressure on mouse events reads this field instead of the tablet one.
        CGEventSetDoubleValueField(event, kCGMouseEventPressure, pressure);
        CGEventSetDoubleValueField(event, kCGTabletEventTiltX, tilt_x);
        CGEventSetDoubleValueField(event, kCGTabletEventTiltY, tilt_y);
        const auto effective_rotation = pen_roll_probe.select(pen->barrelRoll, pen->rotation);
        CGEventSetDoubleValueField(event, kCGTabletEventRotation, effective_rotation == LI_ROT_UNKNOWN ? 0.0 : effective_rotation);
        CGEventSetIntegerValueField(event, kCGTabletEventDeviceID, pen_pointer);
      }

      post_event(event);
      // Do NOT call CGWarpMouseCursorPosition(location) after post_event: posting to kCGHIDEventTap
      // already updates WindowServer's cursor and PKGCore drag position, whereas a trailing warp
      // emits a duplicate moveDrag/proposeDragMovement ~60us later (doubling WindowServer IPC and
      // overflowing the 16KB SkyLight datagram buffer during 240Hz Apple Pencil window drags).
      if (sync_cursor) {
        macos_input->last_cursor_loc = {location.x, location.y};
        macos_input->has_cursor_loc = true;
        macos_input->last_cursor_update = std::chrono::steady_clock::now();
        bool show_cursor = false;
        {
          std::lock_guard lock(macos_input->scroll_mutex);
          macos_input->saved_trackpad_cursor = location;
          macos_input->has_saved_trackpad_cursor = true;
          macos_input->cursor_restore_pending = false;
          if (macos_input->touch_cursor_suppressed) {
            macos_input->touch_cursor_suppressed = false;
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

    // Lifts every pen button and leaves proximity, so nothing stays pressed.
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

    void set_pen_hovering_flag(const bool active) {
      std::lock_guard lock(macos_input->scroll_mutex);
      macos_input->pen_hovering = active;
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

    // Exits Apple Pencil air hover: hides the Pencil hover cursor immediately on lift-away and
    // parks the invisible cursor on a neutral spot to clear `:hover` without touching `saved_trackpad_cursor`.
    void leave_pen_hover(const bool park_and_hide) {
      const bool was_hovering = pen_hover_active;
      pen_hover_active = false;
      pen_hover_primary_down = false;
      set_pen_hovering_flag(false);
      if (pen_in_proximity &&
          !pen_down[PEN_TIP] && !pen_down[PEN_PRIMARY] && !pen_down[PEN_SECONDARY] && !pen_down[PEN_TERTIARY]) {
        post_proximity(false);
        pen_in_proximity = false;
      }
      if (park_and_hide && was_hovering) {
        macos_pen_hover_cursor_hide();
        macos_sc_set_cursor_visible(false);
        schedule_touch_cursor_restore(macos_input, 35ms, true);
      }
    }

    void start_drag_prefetch(
      window_drag_prefetch::ticket_t &ticket,
      const CGPoint &pt,
      const std::chrono::steady_clock::time_point now
    ) {
      ticket = macos_input->drag_region_prefetch.begin(
        {pt.x, pt.y},
        current_window_layout_epoch(macos_input),
        now
      );
    }

    bool resolve_drag_prefetch(
      window_drag_prefetch::ticket_t &ticket,
      const CGPoint &pt,
      const std::chrono::steady_clock::time_point now,
      const std::chrono::steady_clock::duration max_age
    ) {
      return macos_input->drag_region_prefetch.resolve(
        ticket,
        {pt.x, pt.y},
        current_window_layout_epoch(macos_input),
        now,
        max_age
      ).is_drag_region;
    }

    void pen_scroll_release() {
      macos_input->drag_region_prefetch.cancel(pen_drag_prefetch_ticket);
      const bool was_hovering = pen_hover_active;
      leave_pen_hover(false);
      macos_pen_hover_cursor_hide();
      macos_sc_set_cursor_visible(false);
      if (!pen_contact_active) {
        if (was_hovering) {
          schedule_touch_cursor_restore(macos_input, 35ms, true);
        }
        return;
      }
      if (pen_dragging) {
        pen_down[PEN_TIP] = false;
        post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, last_location, 1);
        note_window_layout_mutation(macos_input);
      }
      if (pen_scrolling) {
        finish_continuous_scroll_gesture(macos_input);
      }
      pen_contact_active = false;
      pen_contact_from_hover = false;
      pen_caught_momentum = false;
      pen_air_hover_during_contact = 0;
      pen_scrolling = false;
      pen_dragging = false;
      schedule_touch_cursor_restore(macos_input, 35ms, true);
    }

    void begin_pen_scroll_contact(
      const CGPoint &location,
      const std::chrono::steady_clock::time_point now,
      const bool from_visible_hover = false,
      const bool prefetch_drag_region = true
    ) {
      preserve_trackpad_cursor_for_pen_contact(macos_input, from_visible_hover, location);
      pen_caught_momentum = (current_scroll_momentum_speed(macos_input) >= 90.0);
      cancel_scroll_momentum(macos_input);
      if (prefetch_drag_region) {
        start_drag_prefetch(pen_drag_prefetch_ticket, location, now);
      } else {
        macos_input->drag_region_prefetch.cancel(pen_drag_prefetch_ticket);
      }
      pen_contact_active = true;
      pen_contact_from_hover = from_visible_hover;
      pen_air_hover_during_contact = 0;
      pen_last_contact_time = now;
      pen_scrolling = false;
      pen_dragging = false;
      pen_start = location;
      pen_last = location;
      pen_down_time = now;
      touch_scroll_origin = location;
      scroll_remainder_x = 0;
      scroll_remainder_y = 0;
    }

    void move_pen_scroll_contact(const CGPoint &location, const std::chrono::steady_clock::time_point now, const pen_input_t &pen) {
      const double delta_x = location.x - pen_last.x;
      const double delta_y = location.y - pen_last.y;
      pen_last = location;

      if (pen_scrolling) {
        scroll_remainder_x += delta_x;
        scroll_remainder_y += delta_y;
        scroll_by_remainder();
      } else if (pen_dragging) {
        pen_down[PEN_TIP] = true;
        // Pace LeftMouseDragged to 120Hz display refresh (>= 7.5ms) so 240Hz Apple Pencil samples
        // and Wi-Fi burst packets never flood macOS PKGCore proposeDragMovement IPC on heavy windows.
        if (last_drag_post_time.time_since_epoch().count() == 0 ||
            (now - last_drag_post_time) >= std::chrono::microseconds(7500)) {
          last_drag_post_time = now;
          post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
        }
      } else if (std::hypot(location.x - pen_start.x, location.y - pen_start.y) > PEN_SLOP) {
        const bool immediate_drag = (pen.penButtons & LI_PEN_BUTTON_PRIMARY) != 0 || (now - pen_down_time) >= PEN_DRAG_HOLD;
        if (immediate_drag) {
          macos_input->drag_region_prefetch.cancel(pen_drag_prefetch_ticket);
        }
        if (immediate_drag || resolve_drag_prefetch(pen_drag_prefetch_ticket, pen_start, now, PEN_DRAG_HOLD)) {
          pen_dragging = true;
          pen_down[PEN_TIP] = true;
          macos_pen_hover_cursor_hide();
          // Anchor MouseDown cleanly at pen_start (ClickState=1) and immediately advance the drag
          // to `location` (ClickState=0) so PKGCore window drags begin smoothly on frame 0.
          post_mouse_event(kCGEventLeftMouseDown, kCGMouseButtonLeft, pen_start, 1);
          post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
          last_drag_post_time = now;
        } else {
          pen_scrolling = true;
          // Hide the stylus hover reticle while scrolling so it never sits stationary at pen_start;
          // lifting the Pencil back into air hover immediately shows it under the tip again.
          macos_pen_hover_cursor_hide();
          scroll_remainder_x += location.x - pen_start.x;
          scroll_remainder_y += location.y - pen_start.y;
          scroll_by_remainder();
        }
      }
    }

    void finish_pen_scroll_contact(const CGPoint &location, const pen_input_t &pen) {
      macos_input->drag_region_prefetch.cancel(pen_drag_prefetch_ticket);
      const bool was_dragging = pen_dragging;
      const bool was_scrolling = pen_scrolling;
      const bool was_catching_momentum = pen_caught_momentum;
      const bool held = (std::chrono::steady_clock::now() - pen_down_time) >= LONG_PRESS;
      const CGPoint start = pen_start;

      pen_contact_active = false;
      pen_contact_from_hover = false;
      pen_caught_momentum = false;
      pen_air_hover_during_contact = 0;
      pen_scrolling = false;
      pen_dragging = false;
      pen_down[PEN_TIP] = false;
      // Hide on contact lift; if the Pencil remains in hover range above the glass, the very next
      // 120/240Hz HOVER packet (~4ms) displays it at the live hover altitude.
      macos_pen_hover_cursor_hide();

      if (was_dragging) {
        if (!have_location || location.x != last_location.x || location.y != last_location.y) {
          post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
        }
        post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, location, 1);
        note_window_layout_mutation(macos_input);
        schedule_touch_cursor_restore(macos_input, 65ms);
      } else if (was_scrolling) {
        finish_continuous_scroll_gesture(macos_input);
      } else {
        if ((pen.penButtons & LI_PEN_BUTTON_PRIMARY) != 0 || held) {
          touch_right_click(start, false);
        } else if (!was_catching_momentum) {
          touch_click(start, false);
        }
      }
    }

    void pen_scroll_mode_update(const touch_port_t &touch_port, const pen_input_t &pen);

    void touch_right_click(const CGPoint &location, const bool keep_pen_reticle = false) {
      preserve_trackpad_cursor_for_pen_contact(macos_input, keep_pen_reticle, location);
      post_mouse_event(kCGEventRightMouseDown, kCGMouseButtonRight, location, 1);
      post_mouse_event(kCGEventRightMouseUp, kCGMouseButtonRight, location, 1);
      note_window_layout_mutation(macos_input);
      schedule_touch_cursor_restore(macos_input);
    }

    void touch_click(const CGPoint &location, const bool keep_pen_reticle = false) {
      // Taps close together in time and place are a double or triple click.
      const auto now = std::chrono::steady_clock::now();
      const bool near = std::hypot(location.x - last_tap.x, location.y - last_tap.y) <= MULTICLICK_DISTANCE;
      tap_count = (now - last_tap_time < MULTICLICK_DELAY_MS && near) ? tap_count + 1 : 1;
      last_tap = location;
      last_tap_time = now;

      preserve_trackpad_cursor_for_pen_contact(macos_input, keep_pen_reticle, location);
      post_mouse_event(kCGEventLeftMouseDown, kCGMouseButtonLeft, location, tap_count);
      post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, location, tap_count);
      note_window_layout_mutation(macos_input);
      schedule_touch_cursor_restore(macos_input);
    }

    // Scrolls by the accumulated touch delta and feeds the continuous momentum tracker
    // targeted at touch_scroll_origin without moving the system mouse cursor.
    void scroll_by_remainder() {
      const double dx = scroll_remainder_x;
      const double dy = scroll_remainder_y;
      scroll_remainder_x = 0;
      scroll_remainder_y = 0;
      continuous_scroll_delta(macos_input, dy, dx, &touch_scroll_origin);
      note_window_layout_mutation(macos_input);
    }

    void touch_release() {
      macos_input->drag_region_prefetch.cancel(touch_drag_prefetch_ticket);
      if (touch_dragging) {
        post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, last_location, 1);
        note_window_layout_mutation(macos_input);
      }
      touch_dragging = false;
      touch_caught_momentum = false;
      touch_points.clear();
      two_finger_tap = false;
      schedule_touch_cursor_restore(macos_input);
    }

    macos_input_t *macos_input;
    CGPoint last_location {};
    bool have_location {};
    CGPoint touch_scroll_origin {};

    bool pen_in_proximity {};
    int pen_pointer {POINTER_PEN};
    bool pen_down[PEN_BUTTON_COUNT] {};
    int pen_click_count {1};
    CGPoint last_pen_down {};
    std::chrono::steady_clock::time_point last_pen_down_time {};

    bool pen_contact_active {};
    bool pen_contact_from_hover {};
    bool pen_caught_momentum {};
    int pen_air_hover_during_contact {};
    bool pen_scrolling {};
    bool pen_dragging {};
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
    std::chrono::steady_clock::time_point last_drag_post_time {};
    std::chrono::steady_clock::time_point last_hover_post_time {};

    std::map<std::uint32_t, touch_point_t> touch_points;
    bool touch_dragging {};  ///< The left button is held for a one-finger drag.
    bool touch_scrolling {};  ///< Two fingers have been down since the last finger lifted.
    bool touch_caught_momentum {};  ///< Touch began by catching a fast coasting scroll; suppress accidental tap-click.
    bool two_finger_tap {};  ///< Two fingers are down and neither has moved yet, so lifting them right-clicks.
    std::chrono::steady_clock::time_point two_finger_down_time {};
    double scroll_remainder_x {};  ///< Movement too small to scroll a whole pixel yet.
    double scroll_remainder_y {};
    int tap_count {1};
    CGPoint last_tap {};
    std::chrono::steady_clock::time_point last_tap_time {};
    window_drag_prefetch::ticket_t pen_drag_prefetch_ticket {};
    window_drag_prefetch::ticket_t touch_drag_prefetch_ticket {};

    input::voidlink::roll_probe_t pen_roll_probe {};
    bool client_voidlink_pen {};
    bool pen_eraser_latched {};
    bool pen_squeeze_primary_down {};
    bool pen_draw_saw_air_hover {};
    std::chrono::steady_clock::time_point pen_draw_last_up_time {};

    bool use_pen_draw_mode() const noexcept {
      return input::voidlink::resolve_pencil_draw_mode(config::input.macos_pencil_mode, client_voidlink_pen);
    }
  };

  void macos_client_input_t::pen_scroll_mode_update(const touch_port_t &touch_port, const pen_input_t &pen) {
    const auto now = std::chrono::steady_clock::now();
    const auto location = clamp_to_display(stream_location(macos_input, touch_port, pen.x * touch_port.width, pen.y * touch_port.height));

    switch (pen.eventType) {
      case LI_TOUCH_EVENT_CANCEL:
      case LI_TOUCH_EVENT_CANCEL_ALL:
        pen_scroll_release();
        return;

      case LI_TOUCH_EVENT_HOVER_LEAVE:
        // Always release any active contact/drag on HOVER_LEAVE so a missed UP packet (e.g. near
        // iPadOS screen-edge system gestures) can never leave LeftMouseDown wedged on a window.
        if (pen_contact_active) {
          finish_pen_scroll_contact(pen_last, pen);
        }
        leave_pen_hover(true);
        return;

      case LI_TOUCH_EVENT_HOVER: {
        if (pen_contact_active) {
          // Hover packets use unreliable ENet delivery while UP/DOWN are reliable, and on iPadOS
          // UIHoverGestureRecognizer also fires zOffset == 0.0f while UITouch is on the glass.
          // Ignore zero-altitude hover during contact, and if >= 3 consecutive real air-hover
          // samples (zOffset > 0.002f) arrive without UP, release the contact cleanly so window
          // drags can never stay stuck in PKGCore/AppKit modal tracking.
          if (pen.pressureOrDistance > 0.002f) {
            if (++pen_air_hover_during_contact >= 3 || (now - pen_last_contact_time) > 45ms) {
              finish_pen_scroll_contact(pen_last, pen);
            }
          } else {
            pen_air_hover_during_contact = 0;
          }
          if (pen_contact_active) {
            return;
          }
        }

        // Skip a single trailing zOffset == 0 sample immediately after UP when lifting straight away.
        if (pen.pressureOrDistance <= 0.0005f &&
            pen_last_up_time.time_since_epoch().count() != 0 &&
            (now - pen_last_up_time) < 25ms) {
          return;
        }

        // Render a crisp Windows-Ink-style stylus reticle right under the Apple Pencil tip while
        // keeping the standard macOS mouse arrow hidden (`showsCursor = NO`). Never synthesize
        // fake touch-downs from UIHoverGestureRecognizer.
        begin_pen_hover_interaction(
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
        const bool primary_now = (pen.penButtons & LI_PEN_BUTTON_PRIMARY) != 0;
        if (pen_hover_active && !pen_contact_active && primary_now && !pen_hover_primary_down) {
          touch_right_click(last_hover_location, true);
          set_pen_hovering_flag(true);
        }
        pen_hover_primary_down = primary_now;
        return;
      }

      case LI_TOUCH_EVENT_DOWN: {
        const bool was_hover = pen_hover_active;
        leave_pen_hover(false);
        if (pen_contact_active) {
          pen_scroll_release();
        }
        begin_pen_scroll_contact(location, now, was_hover, (pen.penButtons & LI_PEN_BUTTON_PRIMARY) == 0);
        return;
      }

      case LI_TOUCH_EVENT_MOVE: {
        const bool was_hover = pen_hover_active;
        leave_pen_hover(false);
        pen_air_hover_during_contact = 0;
        pen_last_contact_time = now;
        if (!pen_contact_active) {
          begin_pen_scroll_contact(location, now, was_hover, (pen.penButtons & LI_PEN_BUTTON_PRIMARY) == 0);
        } else {
          move_pen_scroll_contact(location, now, pen);
        }
        return;
      }

      case LI_TOUCH_EVENT_UP:
        pen_air_hover_during_contact = 0;
        pen_last_up_time = now;
        if (!pen_contact_active) {
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

    leave_pen_hover(false);
    if (pen_contact_active) {
      pen_scroll_release();
    }

    switch (pen.eventType) {
      case LI_TOUCH_EVENT_CANCEL:
      case LI_TOUCH_EVENT_CANCEL_ALL:
      case LI_TOUCH_EVENT_HOVER_LEAVE:
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
      // In VoidLink's `Hovering Disabled` mode, lifting the Pencil emits `UP` followed immediately
      // by a synthetic `HOVER` (distance = 0) and `HOVER_LEAVE` 8.6ms later. Suppress the zero-height
      // post-lift packet so the reticle never flashes when hovering is disabled.
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

    // Pen and touch coordinates are 0..1 across the stream; touch_port gives its size.
    const auto location = clamp_to_display(stream_location(macos_input, touch_port, pen.x * touch_port.width, pen.y * touch_port.height));
    const std::uint8_t effective_tool =
      (pen.toolType == LI_TOOL_TYPE_ERASER || pen_eraser_latched) ? LI_TOOL_TYPE_ERASER : pen.toolType;

    // A tool change (pen to eraser) is a new device coming into range.
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

    // Move first, so a press lands where the pen is.
    int held = -1;
    for (int i = 0; i < PEN_BUTTON_COUNT && held < 0; ++i) {
      if (pen_down[i]) {
        held = i;
      }
    }
    // In Drawing Tablet mode (`draw`), replace the giant mouse arrow with the stylus reticle,
    // hiding cleanly on contact lift when the client has `Hovering Disabled`.
    if (pen.eventType == LI_TOUCH_EVENT_UP && !pen_draw_saw_air_hover) {
      suppress_cursor_for_touch_or_pen(macos_input, false);
      macos_pen_hover_cursor_hide();
    } else {
      begin_pen_hover_interaction(
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

    // A move is posted even when the pen holds still, since pressure and tilt can change.
    const bool moved = !have_location || location.x != last_location.x || location.y != last_location.y;
    if (pen.eventType == LI_TOUCH_EVENT_MOVE || pen.eventType == LI_TOUCH_EVENT_HOVER || (pen.eventType != LI_TOUCH_EVENT_BUTTON_ONLY && moved)) {
      post_mouse_event(held < 0 ? kCGEventMouseMoved : button_event(held, true, true), held < 0 ? kCGMouseButtonLeft : mouse_button(held), location, 0, &pen, false);
    }

    for (int i = 0; i < PEN_BUTTON_COUNT; ++i) {
      if (wanted[i] == pen_down[i]) {
        continue;
      }
      pen_down[i] = wanted[i];

      int clicks = 1;
      if (i == PEN_TIP && wanted[i]) {
        // Taps close together in time and place are a double or triple click.
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
    const auto location = clamp_to_display(stream_location(macos_input, touch_port, btn.x * touch_port.width, btn.y * touch_port.height));

    if (!use_pen_draw_mode()) {
      if (btn.eventType == input::voidlink::pencil_double_tap ||
          btn.eventType == input::voidlink::pencil_squeeze_begin) {
        touch_right_click(location, pen_hover_active);
        if (pen_hover_active) {
          set_pen_hovering_flag(true);
        }
      }
      return;
    }

    if (btn.eventType == input::voidlink::pencil_double_tap) {
      // Match macOS/iPadOS system default when VoidLink's custom double-tap shortcut is OFF:
      // toggle between Brush (`POINTER_PEN`) and Eraser (`POINTER_ERASER`).
      pen_eraser_latched = !pen_eraser_latched;
      if (!pen_down[PEN_TIP]) {
        ensure_pen_proximity(pen_eraser_latched ? LI_TOOL_TYPE_ERASER : LI_TOOL_TYPE_PEN);
        if (pen_in_proximity) {
          begin_pen_hover_interaction(macos_input, location, 0.05f, pen_eraser_latched);
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
          touch_scrolling = false;
        }
        return;
      case LI_TOUCH_EVENT_CANCEL_ALL:
        touch_release();
        touch_scrolling = false;
        return;
      case LI_TOUCH_EVENT_DOWN:
      case LI_TOUCH_EVENT_UP:
      case LI_TOUCH_EVENT_MOVE:
        break;
      default:
        return;  // Hover and button-only events have no touch equivalent.
    }

    const auto location = clamp_to_display(stream_location(macos_input, touch_port, touch.x * touch_port.width, touch.y * touch_port.height));

    switch (touch.eventType) {
      case LI_TOUCH_EVENT_DOWN: {
        begin_touch_interaction(macos_input);
        const bool was_fast_mom = (current_scroll_momentum_speed(macos_input) >= 90.0);
        cancel_scroll_momentum(macos_input);
        const bool was_empty = touch_points.empty();
        const auto down_now = std::chrono::steady_clock::now();
        touch_points[touch.pointerId] = {location, location, down_now};
        if (was_empty) {
          touch_caught_momentum = was_fast_mom;
        }
        if (touch_points.size() >= 2) {
          macos_input->drag_region_prefetch.cancel(touch_drag_prefetch_ticket);
          // The first finger was waiting to become a click or drag; it is a scroll now.
          if (touch_dragging) {
            post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, last_location, 1);
            note_window_layout_mutation(macos_input);
            touch_dragging = false;
          }
          touch_scrolling = true;
          two_finger_tap = touch_points.size() == 2 && !touch_caught_momentum;
          two_finger_down_time = down_now;
        } else {
          start_drag_prefetch(touch_drag_prefetch_ticket, location, down_now);
          touch_scroll_origin = location;
          touch_scrolling = false;
          two_finger_tap = false;
        }
        break;
      }
      case LI_TOUCH_EVENT_MOVE: {
        const auto point = touch_points.find(touch.pointerId);
        if (point == touch_points.end()) {
          return;
        }

        const auto delta_x = location.x - point->second.last.x;
        const auto delta_y = location.y - point->second.last.y;
        point->second.last = location;

        if (two_finger_tap) {
          // Small movement still counts as a tap; moving past the slop turns it into a scroll.
          if (std::hypot(location.x - point->second.start.x, location.y - point->second.start.y) <= TOUCH_SLOP) {
            return;
          }
          two_finger_tap = false;
        }

        if (touch_scrolling) {
          // Two fingers moving together scroll by their average movement; each finger reports
          // its own move, so take half of each.
          const auto fingers = static_cast<double>(std::max<std::size_t>(touch_points.size(), 1));
          scroll_remainder_x += delta_x / fingers;
          scroll_remainder_y += delta_y / fingers;
          scroll_by_remainder();
        } else if (touch_dragging) {
          const auto now = std::chrono::steady_clock::now();
          if (last_drag_post_time.time_since_epoch().count() == 0 ||
              (now - last_drag_post_time) >= std::chrono::microseconds(7500)) {
            last_drag_post_time = now;
            post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
          }
        } else if (touch_points.size() == 1 && std::hypot(location.x - point->second.start.x, location.y - point->second.start.y) > TOUCH_SLOP) {
          const auto now = std::chrono::steady_clock::now();
          const bool held_long = (now - point->second.down_time >= LONG_PRESS);
          if (held_long) {
            macos_input->drag_region_prefetch.cancel(touch_drag_prefetch_ticket);
          }
          if (held_long || resolve_drag_prefetch(touch_drag_prefetch_ticket, point->second.start, now, LONG_PRESS)) {
            // Anchor MouseDown cleanly at start (ClickState=1) and advance drag to location (ClickState=0).
            post_mouse_event(kCGEventLeftMouseDown, kCGMouseButtonLeft, point->second.start, 1);
            post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
            last_drag_post_time = now;
            touch_dragging = true;
          } else {
            // Moved right away: scroll, counting from where the finger landed.
            touch_scrolling = true;
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

        const bool single = touch_points.size() == 1 && !touch_dragging && !touch_scrolling;
        const bool held = std::chrono::steady_clock::now() - point->second.down_time >= LONG_PRESS;
        const auto start = point->second.start;
        if (two_finger_tap) {
          // Two fingers tapped together: right-click where the first one landed.
          two_finger_tap = false;
          if (std::chrono::steady_clock::now() - two_finger_down_time < LONG_PRESS) {
            touch_right_click(start);
          }
        }
        touch_points.erase(point);
        if (touch_dragging) {
          if (!have_location || location.x != last_location.x || location.y != last_location.y) {
            post_mouse_event(kCGEventLeftMouseDragged, kCGMouseButtonLeft, location, 0);
          }
          post_mouse_event(kCGEventLeftMouseUp, kCGMouseButtonLeft, location, 1);
          note_window_layout_mutation(macos_input);
          schedule_touch_cursor_restore(macos_input, 65ms);
          touch_dragging = false;
        } else if (single) {
          // A finger held still and lifted is a right-click, like a long press on an iPad.
          // If this touch caught an actively coasting momentum scroll, stop the scroll without
          // clicking links underneath (matching native iPadOS UIScrollView).
          if (held) {
            touch_right_click(start);
          } else if (!touch_caught_momentum) {
            touch_click(start);
          }
        }
        if (touch_points.empty()) {
          macos_input->drag_region_prefetch.cancel(touch_drag_prefetch_ticket);
          if (touch_scrolling) {
            finish_continuous_scroll_gesture(macos_input);
          }
          touch_scrolling = false;
          touch_caught_momentum = false;
        }
        break;
      }
    }
  }

  /**
   * @brief Allocates a context to store per-client input data.
   * @param input The global input context.
   * @return A unique pointer to a per-client input data context.
   */
  std::unique_ptr<client_input_t> allocate_client_input_context(input_t &input) {
    return std::make_unique<macos_client_input_t>(static_cast<macos_input_t *>(input.get()));
  }

  /**
   * @brief Sends a touch event to the OS.
   * @param input The client-specific input context.
   * @param touch_port The current viewport for translating to screen coordinates.
   * @param touch The touch event.
   */
  void touch_update(client_input_t *input, const touch_port_t &touch_port, const touch_input_t &touch) {
    if (const auto client = static_cast<macos_client_input_t *>(input)) {
      client->touch_update(touch_port, touch);
    }
  }

  /**
   * @brief Sends a pen event to the OS.
   * @param input The client-specific input context.
   * @param touch_port The current viewport for translating to screen coordinates.
   * @param pen The pen event.
   */
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
    if (!macos_input) {
      return;
    }
    ensure_event_sources(macos_input);
    const auto pt = get_mouse_loc(input);
    const CGPoint loc = CGPointMake(pt.x, pt.y);

    constexpr auto kCGEventGestureType = static_cast<CGEventType>(29);
    constexpr auto kGestureSubtypeField = static_cast<CGEventField>(110);
    constexpr auto kGestureMagnifyField = static_cast<CGEventField>(113);
    constexpr auto kGestureRotateField = static_cast<CGEventField>(114);
    constexpr auto kGesturePhaseField = static_cast<CGEventField>(132);
    constexpr int64_t kSubtypeRotate = 5;
    constexpr int64_t kSubtypeMagnify = 8;
    constexpr int64_t kSubtypeBeginGesture = 61;
    constexpr int64_t kSubtypeEndGesture = 62;

    auto post_gesture_subevent = [&](const int64_t subtype, const int64_t phase, const double amount) {
      const auto ev = CGEventCreate(macos_input->source);
      if (!ev) {
        return;
      }
      CGEventSetType(ev, kCGEventGestureType);
      CGEventSetLocation(ev, loc);
      CGEventSetFlags(ev, macos_input->kb_flags);
      CGEventSetIntegerValueField(ev, kGestureSubtypeField, subtype);
      CGEventSetIntegerValueField(ev, kGesturePhaseField, phase);
      if (subtype == kSubtypeMagnify) {
        CGEventSetDoubleValueField(ev, kGestureMagnifyField, amount);
      } else if (subtype == kSubtypeRotate) {
        CGEventSetDoubleValueField(ev, kGestureRotateField, amount);
      }
      CGEventPost(kCGHIDEventTap, ev);
      CFRelease(ev);
    };

    if (gesture.phase == input::voidlink::mac_gesture_begin) {
      post_gesture_subevent(kSubtypeBeginGesture, gesture.phase, 0.0);
    }
    post_gesture_subevent(gesture.is_rotate ? kSubtypeRotate : kSubtypeMagnify, gesture.phase, gesture.amount);
    if (gesture.phase == input::voidlink::mac_gesture_end ||
        gesture.phase == input::voidlink::mac_gesture_cancel) {
      post_gesture_subevent(kSubtypeEndGesture, gesture.phase, 0.0);
    }
  }

  /**
   * @brief Sends a gamepad touch event to the OS.
   * @param input The global input context.
   * @param touch The touch event.
   */
  void gamepad_touch(input_t &input, const gamepad_touch_t &touch) {
    // Unimplemented feature - platform_caps::controller_touch
  }

  /**
   * @brief Sends a gamepad motion event to the OS.
   * @param input The global input context.
   * @param motion The motion event.
   */
  void gamepad_motion(input_t &input, const gamepad_motion_t &motion) {
    // Unimplemented
  }

  /**
   * @brief Sends a gamepad battery event to the OS.
   * @param input The global input context.
   * @param battery The battery event.
   */
  void gamepad_battery(input_t &input, const gamepad_battery_t &battery) {
    // Unimplemented
  }

  /**
   * @brief Hands the real Steam Controller's firmware attributes to the virtual controller.
   * @param input The global input context.
   * @param attributes The attributes.
   */
  void gamepad_attributes(input_t &input, const steam_controller_attributes_t &attributes) {
    // Unimplemented: no virtual gamepad on this platform
  }

  input_t input() {
    input_t result {new macos_input_t()};

    const auto macos_input = static_cast<macos_input_t *>(result.get());

    // Default to main display
    macos_input->display = CGMainDisplayID();

    auto output_name = config::get_active_output_name();
    // If output_name is set, try to find the display with that display id
    if (!output_name.empty()) {
      const int MAX_DISPLAYS = 32;
      uint32_t max_display = MAX_DISPLAYS;
      uint32_t display_count;
      CGDirectDisplayID displays[MAX_DISPLAYS];
      if (CGGetActiveDisplayList(max_display, displays, &display_count) != kCGErrorSuccess) {
        BOOST_LOG(error) << "Unable to get active display list , error: "sv << std::endl;
      } else {
        for (int i = 0; i < display_count; i++) {
          CGDirectDisplayID display_id = displays[i];
          if (display_id == std::atoi(output_name.c_str())) {
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

    macos_input->kb_flags = 0;
    macos_input->mouse_down[0] = false;
    macos_input->mouse_down[1] = false;
    macos_input->mouse_down[2] = false;
    const CGPoint init_cursor = raw_system_cursor_point(macos_input);
    macos_input->last_cursor_loc = {init_cursor.x, init_cursor.y};
    macos_input->has_cursor_loc = true;
    macos_input->saved_trackpad_cursor = init_cursor;
    macos_input->has_saved_trackpad_cursor = true;

    macos_input->scroll_thread = std::thread(run_scroll_momentum_worker, macos_input);
    macos_input->drag_region_prefetch.start_worker(
      [](const window_drag_prefetch::point_t pt) {
        return is_window_drag_region(CGPointMake(pt.x, pt.y));
      },
      []() {
        platf::set_thread_name("input::dragPrefetch");
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        platf::adjust_thread_priority(platf::thread_priority_e::critical);
      }
    );

    BOOST_LOG(debug) << "macOS scroll speed: com.apple.scrollwheel.scaling="sv << macos_input->scrollwheel_scaling << ", lines per detent="sv << macos_input->scroll_lines_per_detent << ", pixels per line="sv << (macos_input->source ? CGEventSourceGetPixelsPerLine(macos_input->source) : 10.0);
    BOOST_LOG(debug) << "Display "sv << macos_input->display << ", pixel dimension: " << CGDisplayPixelsWide(macos_input->display) << "x"sv << CGDisplayPixelsHigh(macos_input->display);

    return result;
  }

  void freeInput(void *p) {
    auto *input = static_cast<macos_input_t *>(p);

    input->drag_region_prefetch.stop_worker();
    {
      std::lock_guard lock(input->scroll_mutex);
      input->scroll_stopping = true;
      input->scroll_cv.notify_all();
    }
    if (input->scroll_thread.joinable()) {
      input->scroll_thread.join();
    }
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

  /**
   * @brief Returns the supported platform capabilities to advertise to the client.
   * @return Capability flags.
   */
  platform_caps::caps_t get_capabilities() {
    platform_caps::caps_t caps = 0;

    // Pen and touch are posted as ordinary input events, so they need only the permission that
    // mouse and keyboard input already do.
    if (config::input.native_pen_touch) {
      caps |= platform_caps::pen_touch;
    }

    return caps;
  }
}  // namespace platf
