/**
 * @file src/system_tray.cpp
 * @brief Definitions for the system tray icon and notification system.
 */
// macros
#if defined SUNSHINE_TRAY && SUNSHINE_TRAY >= 1

  #if defined(_WIN32)
    #define WIN32_LEAN_AND_MEAN
    #include "platform/windows/utils.h"

    #include <Windows.h>
    #include <accctrl.h>
    #include <aclapi.h>
    #define TRAY_ICON WEB_DIR "images/apollo.ico"
    #define TRAY_ICON_PLAYING WEB_DIR "images/apollo-playing.ico"
    #define TRAY_ICON_PAUSING WEB_DIR "images/apollo-pausing.ico"
    #define TRAY_ICON_LOCKED WEB_DIR "images/apollo-locked.ico"
  #elif defined(__linux__) || defined(linux) || defined(__linux)
    #define TRAY_ICON SUNSHINE_TRAY_PREFIX "-tray"
    #define TRAY_ICON_PLAYING SUNSHINE_TRAY_PREFIX "-playing"
    #define TRAY_ICON_PAUSING SUNSHINE_TRAY_PREFIX "-pausing"
    #define TRAY_ICON_LOCKED SUNSHINE_TRAY_PREFIX "-locked"
  #elif defined(__APPLE__) || defined(__MACH__)
    // SVGs stay crisp as menu bar template images; the PNGs have a shadow baked in.
    #define TRAY_ICON WEB_DIR "images/logo-apollo.svg"
    #define TRAY_ICON_PLAYING WEB_DIR "images/apollo-playing.svg"
    #define TRAY_ICON_PAUSING WEB_DIR "images/apollo-pausing.svg"
    #define TRAY_ICON_LOCKED WEB_DIR "images/apollo-locked.svg"
    #include "platform/macos/misc.h"

    #include <dispatch/dispatch.h>
  #endif

  #define TRAY_MSG_NO_APP_RUNNING "Reload Apps"

  // standard includes
  #include <atomic>
  #include <condition_variable>
  #include <csignal>
  #include <cstring>
  #include <cwchar>
  #include <functional>
  #include <mutex>
  #include <queue>
  #include <string>
  #include <thread>
  #include <utility>

  // lib includes
  #include <boost/filesystem.hpp>
  #include <tray/src/tray.h>

  // local includes
  #include "config.h"
  #include "confighttp.h"
  #include "file_handler.h"
  #include "logging.h"
  #include "network.h"
  #include "platform/common.h"
  #include "process.h"
  #include "src/entry_handler.h"
  #include "system_tray.h"
  #include "system_tray_lifecycle.h"
  #include "update.h"

using namespace std::literals;

// system_tray namespace
namespace system_tray {
  static std::atomic<bool> tray_initialized = false;
#ifdef _WIN32
  static std::mutex tray_action_mutex;
  static std::condition_variable tray_action_cv;
  static std::queue<std::function<void()>> tray_actions;
  static detail::worker_t tray_worker;
#else
  static std::atomic<bool> tray_thread_running = false;
  static std::atomic<bool> tray_thread_should_exit = false;
  static std::thread tray_thread;
#endif

  static int init_tray();

  static void tray_log_bridge(enum tray_log_level level, const char *message) {
    if (!message) {
      return;
    }
    switch (level) {
      case TRAY_LOG_DEBUG:
        BOOST_LOG(debug) << message;
        break;
      case TRAY_LOG_INFO:
        BOOST_LOG(info) << message;
        break;
      case TRAY_LOG_WARNING:
        BOOST_LOG(warning) << message;
        break;
      case TRAY_LOG_ERROR:
        BOOST_LOG(error) << message;
        break;
    }
  }

  void tray_open_ui_cb([[maybe_unused]] struct tray_menu *item) {
    BOOST_LOG(info) << "Opening UI from system tray"sv;
    launch_ui();
  }

  void
    tray_force_stop_cb(struct tray_menu *item) {
    BOOST_LOG(info) << "Force stop from system tray"sv;
    proc::proc.terminate(true);
  }

  void tray_restart_cb([[maybe_unused]] struct tray_menu *item) {
    BOOST_LOG(info) << "Restarting from system tray"sv;

    proc::proc.terminate();
    platf::restart();
  }

  void tray_quit_cb([[maybe_unused]] struct tray_menu *item) {
    BOOST_LOG(info) << "Quitting from system tray"sv;

    proc::proc.terminate();

  #ifdef _WIN32
    // If we're running in a service, return a special status to
    // tell it to terminate too, otherwise it will just respawn us.
    if (GetEnvironmentVariableW(platf::service_launch::launched_by_service_env_var, nullptr, 0) != 0) {
      lifetime::exit_sunshine(ERROR_SHUTDOWN_IN_PROGRESS, true);
      return;
    }
  #endif

    lifetime::exit_sunshine(0, true);
  }

  #if defined(__APPLE__) || defined(__MACH__)
  static void tray_pair_pin_cb(struct tray_menu *item);
  static void tray_check_update_cb(struct tray_menu *item);
  static void tray_open_at_login_cb(struct tray_menu *item);
  static void tray_allow_login_screen_cb(struct tray_menu *item);
  static void tray_scroll_inertia_macos_cb(struct tray_menu *item);
  static void tray_scroll_inertia_ipados_cb(struct tray_menu *item);
  static void tray_scroll_inertia_disabled_cb(struct tray_menu *item);
  static void tray_pencil_mode_auto_cb(struct tray_menu *item);
  static void tray_pencil_mode_scroll_cb(struct tray_menu *item);
  static void tray_pencil_mode_draw_cb(struct tray_menu *item);
  static void tray_palm_rejection_cb(struct tray_menu *item);
  static void sync_scroll_inertia_tray_checks();
  static void sync_pencil_mode_tray_checks();
  static void sync_macos_tray_localization();

  static bool is_macos_tray_korean() {
    auto read_gate = config::acquire_apply_read_gate();
    const auto &loc = config::sunshine.locale;
    return loc.size() >= 2 &&
           (loc[0] == 'k' || loc[0] == 'K') &&
           (loc[1] == 'o' || loc[1] == 'O');
  }

  static struct tray_menu scroll_inertia_submenu[] = {
    {.text = "MacBook Trackpad", .checked = 1, .checkbox = 1, .cb = tray_scroll_inertia_macos_cb},
    {.text = "iPad Momentum", .checked = 0, .checkbox = 1, .cb = tray_scroll_inertia_ipados_cb},
    {.text = "Disabled", .checked = 0, .checkbox = 1, .cb = tray_scroll_inertia_disabled_cb},
    {.text = nullptr}
  };

  static struct tray_menu pencil_mode_submenu[] = {
    {.text = "Follow Client (VoidLink)", .checked = 1, .checkbox = 1, .cb = tray_pencil_mode_auto_cb},
    {.text = "Scroll & Tap (iPad Style)", .checked = 0, .checkbox = 1, .cb = tray_pencil_mode_scroll_cb},
    {.text = "Drawing Tablet (Pen Input)", .checked = 0, .checkbox = 1, .cb = tray_pencil_mode_draw_cb},
    {.text = "-"},
    {.text = "Reject Touch While Using Pencil", .checked = 1, .checkbox = 1, .cb = tray_palm_rejection_cb},
    {.text = nullptr}
  };
  #endif

  // Tray menu
  static struct tray tray = {
    .icon = TRAY_ICON,
    .tooltip = PROJECT_NAME,
    .menu =
      (struct tray_menu[]) {
        {.text = "Open Vibepollo", .cb = tray_open_ui_cb},
  #if defined(__APPLE__) || defined(__MACH__)
        {.text = "Pair Device (PIN)...", .cb = tray_pair_pin_cb},
  #endif
        {.text = "-"},
        {.text = TRAY_MSG_NO_APP_RUNNING, .cb = tray_force_stop_cb},
  #if defined(__APPLE__) || defined(__MACH__)
        {.text = "Check for Update", .cb = tray_check_update_cb},
        {.text = "-"},
        {.text = "Scroll Inertia", .submenu = scroll_inertia_submenu},
        {.text = "Apple Pencil", .submenu = pencil_mode_submenu},
        {.text = "Open at Login", .checkbox = 1, .cb = tray_open_at_login_cb},
        {.text = "Allow on Login Screen", .checkbox = 1, .cb = tray_allow_login_screen_cb},
        {.text = "-"},
  #else
        {.text = "Check for Update", .cb = [](tray_menu *) {
           BOOST_LOG(info) << "Manual update check requested from tray"sv;
           update::trigger_check(true);
         }},
  #endif
        {.text = "Restart", .cb = tray_restart_cb},
        {.text = "Quit", .cb = tray_quit_cb},
        {.text = nullptr}
      },
    .iconPathCount = 4,
    .allIconPaths = {TRAY_ICON, TRAY_ICON_LOCKED, TRAY_ICON_PLAYING, TRAY_ICON_PAUSING},
  };

  #if defined(__APPLE__) || defined(__MACH__)
  static std::recursive_mutex g_tray_state_mutex;

  static void persist_and_apply_tray_setting(const char *key, const char *value) {
    if (!config::update_config_file({{key, std::string {value}}}, false)) {
      BOOST_LOG(warning) << "Couldn't persist "sv << key << " to config file"sv;
    }
    config::apply_config_now();
    refresh_macos_tray_checks();
  }

  static void sync_scroll_inertia_tray_checks() {
    const auto mode = config::get_macos_scroll_inertia();
    scroll_inertia_submenu[0].checked = (mode == config::macos_scroll_inertia_e::macos) ? 1 : 0;
    scroll_inertia_submenu[1].checked = (mode == config::macos_scroll_inertia_e::ipados) ? 1 : 0;
    scroll_inertia_submenu[2].checked = (mode == config::macos_scroll_inertia_e::disabled) ? 1 : 0;
  }

  static void set_scroll_inertia_from_tray(const char *mode) {
    persist_and_apply_tray_setting("macos_scroll_inertia", mode);
    BOOST_LOG(info) << "macOS scroll inertia mode set to: "sv << mode;
  }

  static void tray_scroll_inertia_macos_cb(struct tray_menu *) {
    set_scroll_inertia_from_tray("macos");
  }

  static void tray_scroll_inertia_ipados_cb(struct tray_menu *) {
    set_scroll_inertia_from_tray("ipados");
  }

  static void tray_scroll_inertia_disabled_cb(struct tray_menu *) {
    set_scroll_inertia_from_tray("disabled");
  }

  static void sync_pencil_mode_tray_checks() {
    const auto mode = config::get_macos_pencil_mode();
    pencil_mode_submenu[0].checked = (mode == config::macos_pencil_mode_e::follow_client) ? 1 : 0;
    pencil_mode_submenu[1].checked = (mode == config::macos_pencil_mode_e::scroll) ? 1 : 0;
    pencil_mode_submenu[2].checked = (mode == config::macos_pencil_mode_e::draw) ? 1 : 0;
    pencil_mode_submenu[4].checked = config::get_macos_palm_rejection() ? 1 : 0;
  }

  static void tray_palm_rejection_cb(struct tray_menu *item) {
    const bool enable = !item->checked;
    persist_and_apply_tray_setting("macos_palm_rejection", enable ? "true" : "false");
    BOOST_LOG(info) << "macOS palm rejection set to: "sv << (enable ? "true"sv : "false"sv);
  }

  static void set_pencil_mode_from_tray(const char *mode) {
    persist_and_apply_tray_setting("macos_pencil_mode", mode);
    BOOST_LOG(info) << "macOS Apple Pencil mode set to: "sv << mode;
  }

  static void tray_pencil_mode_auto_cb(struct tray_menu *) {
    set_pencil_mode_from_tray("auto");
  }

  static void tray_pencil_mode_scroll_cb(struct tray_menu *) {
    set_pencil_mode_from_tray("scroll");
  }

  static void tray_pencil_mode_draw_cb(struct tray_menu *) {
    set_pencil_mode_from_tray("draw");
  }

  static void tray_open_at_login_cb(struct tray_menu *item) {
    bool enable = !item->checked;
    BOOST_LOG(info) << (enable ? "Enabling"sv : "Disabling"sv) << " open at login from system tray"sv;
    platf::set_opens_at_login(enable);
    std::lock_guard lock {g_tray_state_mutex};
    // Show what actually happened: the user may still need to approve it in System Settings.
    item->checked = platf::opens_at_login();
    tray_update(&tray);
  }

  void refresh_macos_tray_checks() {
    std::lock_guard lock {g_tray_state_mutex};
    sync_scroll_inertia_tray_checks();
    sync_pencil_mode_tray_checks();
    sync_macos_tray_localization();
    for (auto *m = tray.menu; m->text != nullptr; ++m) {
      if (m->cb == tray_open_at_login_cb) {
        m->checked = platf::opens_at_login();
      } else if (m->cb == tray_allow_login_screen_cb) {
        m->checked = platf::loginscreen_agent_enabled();
      }
    }
    tray_update(&tray);
  }

  extern "C" void tray_ensure_macos_app_delegate(void);

  void ensure_macos_app_delegate() {
    tray_ensure_macos_app_delegate();
  }
  #endif

#ifdef _WIN32
  static void clear_pending_quit_messages() {
    MSG msg {};
    while (PeekMessageA(&msg, nullptr, WM_QUIT, WM_QUIT, PM_REMOVE)) {}
  }

  static void run_pending_tray_actions() {
    std::queue<std::function<void()>> pending_actions;
    {
      std::lock_guard lock(tray_action_mutex);
      pending_actions.swap(tray_actions);
    }

    while (!pending_actions.empty()) {
      auto action = std::move(pending_actions.front());
      pending_actions.pop();
      action();
    }
  }
#endif

  template<typename Fn>
  static void run_on_tray_thread(Fn &&fn) {
    if (!tray_initialized.load()) {
      return;
    }

#ifdef _WIN32
    {
      std::lock_guard lock(tray_action_mutex);
      if (!tray_initialized.load() || tray_worker.stop_requested()) {
        return;
      }
      tray_actions.emplace(std::forward<Fn>(fn));
    }
    tray_action_cv.notify_one();
#else
  #if defined(__APPLE__) || defined(__MACH__)
    std::lock_guard lock {g_tray_state_mutex};
  #endif
    fn();
#endif
  }

  static int init_tray() {
  #ifdef _WIN32
    // If we're running as SYSTEM, Explorer.exe will not have permission to open our thread handle
    // to monitor for thread termination. If Explorer fails to open our thread, our tray icon
    // will persist forever if we terminate unexpectedly. To avoid this, we will modify our thread
    // DACL to add an ACE that allows SYNCHRONIZE access to Everyone.
    {
      PACL old_dacl;
      PSECURITY_DESCRIPTOR sd;
      auto error = GetSecurityInfo(GetCurrentThread(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, &old_dacl, nullptr, &sd);
      if (error != ERROR_SUCCESS) {
        BOOST_LOG(warning) << "GetSecurityInfo() failed: "sv << error;
        return 1;
      }

      auto free_sd = util::fail_guard([sd]() {
        LocalFree(sd);
      });

      SID_IDENTIFIER_AUTHORITY sid_authority = SECURITY_WORLD_SID_AUTHORITY;
      PSID world_sid;
      if (!AllocateAndInitializeSid(&sid_authority, 1, SECURITY_WORLD_RID, 0, 0, 0, 0, 0, 0, 0, &world_sid)) {
        error = GetLastError();
        BOOST_LOG(warning) << "AllocateAndInitializeSid() failed: "sv << error;
        return 1;
      }

      auto free_sid = util::fail_guard([world_sid]() {
        FreeSid(world_sid);
      });

      EXPLICIT_ACCESS ea {};
      ea.grfAccessPermissions = SYNCHRONIZE;
      ea.grfAccessMode = GRANT_ACCESS;
      ea.grfInheritance = NO_INHERITANCE;
      ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
      ea.Trustee.ptstrName = (LPSTR) world_sid;

      PACL new_dacl;
      error = SetEntriesInAcl(1, &ea, old_dacl, &new_dacl);
      if (error != ERROR_SUCCESS) {
        BOOST_LOG(warning) << "SetEntriesInAcl() failed: "sv << error;
        return 1;
      }

      auto free_new_dacl = util::fail_guard([new_dacl]() {
        LocalFree(new_dacl);
      });

      error = SetSecurityInfo(GetCurrentThread(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, new_dacl, nullptr);
      if (error != ERROR_SUCCESS) {
        BOOST_LOG(warning) << "SetSecurityInfo() failed: "sv << error;
        return 1;
      }
    }

    // Wait for the shell to be initialized before registering the tray icon.
    // This ensures the tray icon works reliably after a logoff/logon cycle.
    while (!tray_worker.stop_requested() && GetShellWindow() == nullptr) {
      if (tray_worker.wait_for_stop(1s)) {
        return 1;
      }
    }

    auto wait_for_default_desktop = []() {
      constexpr int attempts = 60;
      for (int attempt = 0; attempt < attempts; ++attempt) {
        if (tray_worker.stop_requested()) {
          return false;
        }
        HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS | DESKTOP_ENUMERATE);
        if (desktop != nullptr) {
          auto close_desktop = util::fail_guard([desktop]() {
            CloseDesktop(desktop);
          });

          WCHAR desktop_name[256] = {};
          DWORD required_length = 0;
          if (GetUserObjectInformationW(desktop, UOI_NAME, desktop_name, sizeof(desktop_name), &required_length)) {
            if (_wcsicmp(desktop_name, L"Default") == 0) {
              return true;
            }
          }
        }

        if (tray_worker.wait_for_stop(1s)) {
          return false;
        }
      }

      return false;
    };

    const bool desktop_ready = wait_for_default_desktop();
    if (tray_worker.stop_requested()) {
      return 1;
    }
    if (!desktop_ready) {
      BOOST_LOG(warning) << "Timed out waiting for interactive desktop; system tray may not appear"sv;
    } else {
      BOOST_LOG(debug) << "Interactive desktop ready for tray initialization"sv;
    }
  #endif

    int attempt = 0;
    int tray_init_result = -1;
    while (tray_init_result < 0 && attempt < 30) {
#ifdef _WIN32
      if (tray_worker.stop_requested()) {
        return 1;
      }
#endif
      tray_init_result = tray_init(&tray);
      if (tray_init_result >= 0) {
        break;
      }
#ifdef _WIN32
      clear_pending_quit_messages();
#endif
      BOOST_LOG(warning) << "Failed to create system tray (attempt "sv << attempt + 1 << ')';
#ifdef _WIN32
      if (tray_worker.wait_for_stop(2s)) {
        return 1;
      }
#else
      std::this_thread::sleep_for(2s);
#endif
      ++attempt;
    }

    if (tray_init_result < 0) {
      BOOST_LOG(warning) << "Failed to create system tray after retries"sv;
      return 1;
    }

    BOOST_LOG(info) << "System tray created"sv;
    tray_initialized = true;
    return 0;
  }

  int system_tray() {
    if (init_tray() != 0) {
      return 1;
    }

#ifdef _WIN32
    while (!tray_worker.stop_requested()) {
      run_pending_tray_actions();
      if (tray_loop(0) < 0) {
        break;
      }

      std::unique_lock lock(tray_action_mutex);
      tray_action_cv.wait_for(lock, 50ms, []() {
        return tray_worker.stop_requested() || !tray_actions.empty();
      });
    }

    tray_exit();
    clear_pending_quit_messages();
#else
    while (tray_loop(1) == 0) {
      BOOST_LOG(debug) << "System tray loop"sv;
    }

    tray_exit();
#endif

    tray_initialized = false;
    return 0;
  }

  void run_tray() {
  #if defined(__APPLE__) || defined(__MACH__)
    std::lock_guard lock {g_tray_state_mutex};
    // The user can also change this in System Settings while Vibepollo isn't running.
    for (auto *item = tray.menu; item->text != nullptr; ++item) {
      if (item->cb == tray_open_at_login_cb) {
        item->checked = platf::opens_at_login();
      } else if (item->cb == tray_allow_login_screen_cb) {
        item->checked = platf::loginscreen_agent_enabled();
      }
    }
    sync_scroll_inertia_tray_checks();
    sync_pencil_mode_tray_checks();
    sync_macos_tray_localization();

    // AppKit only runs the menu bar on the main thread, which is where main() calls this from.
    // main() then runs the AppKit event loop there once startup is done.
    // No retries: unlike Windows' shell, a status item that fails once won't recover.
    tray_set_log_callback(&tray_log_bridge);
    if (tray_init(&tray) < 0) {
      BOOST_LOG(warning) << "Failed to create the menu bar icon"sv;
      return;
    }
    BOOST_LOG(info) << "System tray created"sv;
    tray_initialized = true;
  #else  // Windows, Linux
#ifdef _WIN32
    tray_worker.start([]() {
      tray_set_log_callback(&tray_log_bridge);
      system_tray();
    });
#else
    if (tray_thread.joinable()) {
      return;
    }
    tray_set_log_callback(&tray_log_bridge);
    tray_thread = std::thread(system_tray);
#endif
  #endif
  }

  int end_tray() {
    tray_initialized = false;
#ifdef _WIN32
    tray_worker.stop();
    tray_action_cv.notify_all();
#elif defined(__APPLE__) || defined(__MACH__)
    // No tray thread on macOS: this wakes the main thread's event loop, and is safe from any thread.
    tray_exit();
#else
    if (tray_thread.joinable()) {
      tray_exit();
    }
    if (tray_thread.joinable()) {
      // end_tray() can run on the tray thread itself: a tray menu action
      // Keep self-join protection for any tray-thread caller. Joining our own
      // thread throws std::system_error(resource_deadlock_would_occur); detach
      // in that case and let the tray loop unwind after the callback returns.
      // The main-thread shutdown path still joins.
      if (tray_thread.get_id() == std::this_thread::get_id()) {
        tray_thread.detach();
      } else {
        tray_thread.join();
      }
    }
#endif
#ifdef _WIN32
    std::lock_guard lock(tray_action_mutex);
    std::queue<std::function<void()>> empty;
    tray_actions.swap(empty);
#endif
    return 0;
  }

  // Persistent storage for tooltip/notification strings to avoid dangling pointers
  static std::string s_tooltip;
  static std::string s_notification_text;
  static std::string s_last_playing_app;
  static char s_force_close_msg[256] = {};

  static struct tray_menu *find_force_stop_menu_item() {
    for (auto *m = tray.menu; m != nullptr && m->text != nullptr; ++m) {
      if (m->cb == tray_force_stop_cb) {
        return m;
      }
    }
    return nullptr;
  }

  #if defined(__APPLE__) || defined(__MACH__)
  static void tray_pair_pin_cb(struct tray_menu *) {
    BOOST_LOG(info) << "Opening PIN pairing from system tray"sv;
    launch_ui("/pin"s);
  }

  static void tray_check_update_cb(struct tray_menu *) {
    BOOST_LOG(info) << "Manual update check requested from tray"sv;
    update::trigger_check(true);
  }

  static void tray_allow_login_screen_cb(struct tray_menu *item) {
    const bool enable = !item->checked;
    BOOST_LOG(info) << (enable ? "Enabling"sv : "Disabling"sv) << " LoginWindow agent from system tray"sv;
    (void) platf::set_loginscreen_agent_enabled(enable);
    refresh_macos_tray_checks();
  }

  static void sync_macos_tray_localization() {
    const bool ko = is_macos_tray_korean();
    scroll_inertia_submenu[0].text = ko ? "MacBook 트랙패드" : "MacBook Trackpad";
    scroll_inertia_submenu[1].text = ko ? "iPad 모멘텀" : "iPad Momentum";
    scroll_inertia_submenu[2].text = ko ? "사용 안 함" : "Disabled";

    pencil_mode_submenu[0].text = ko ? "클라이언트 설정 따름 (VoidLink)" : "Follow Client (VoidLink)";
    pencil_mode_submenu[1].text = ko ? "스크롤 및 탭 (iPad 스타일)" : "Scroll & Tap (iPad Style)";
    pencil_mode_submenu[2].text = ko ? "드로잉 태블릿 (펜 입력)" : "Drawing Tablet (Pen Input)";
    pencil_mode_submenu[4].text = ko ? "펜 사용 중 터치 차단" : "Reject Touch While Using Pencil";

    for (auto *m = tray.menu; m != nullptr && m->text != nullptr; ++m) {
      if (m->cb == tray_open_ui_cb) {
        m->text = ko ? "설정..." : "Open Vibepollo";
      } else if (m->cb == tray_pair_pin_cb) {
        m->text = ko ? "기기 페어링 (PIN)..." : "Pair Device (PIN)...";
      } else if (m->cb == tray_force_stop_cb) {
        if (!s_last_playing_app.empty()) {
          snprintf(
            s_force_close_msg,
            sizeof(s_force_close_msg),
            ko ? "[%s] 강제 종료" : "Force close [%s]",
            s_last_playing_app.c_str()
          );
          m->text = s_force_close_msg;
        } else {
          m->text = ko ? "실행 중인 앱 강제 종료" : TRAY_MSG_NO_APP_RUNNING;
        }
      } else if (m->cb == tray_check_update_cb) {
        m->text = ko ? "업데이트 확인" : "Check for Update";
      } else if (m->submenu == scroll_inertia_submenu) {
        m->text = ko ? "스크롤 관성" : "Scroll Inertia";
      } else if (m->submenu == pencil_mode_submenu) {
        m->text = "Apple Pencil";
      } else if (m->cb == tray_open_at_login_cb) {
        m->text = ko ? "로그인 시 열기" : "Open at Login";
      } else if (m->cb == tray_allow_login_screen_cb) {
        m->text = ko ? "로그인 화면에서 허용" : "Allow on Login Screen";
      } else if (m->cb == tray_restart_cb) {
        m->text = ko ? "재시작" : "Restart";
      } else if (m->cb == tray_quit_cb) {
        m->text = ko ? "종료" : "Quit";
      }
    }
  }
  #endif

  void update_tray_playing(std::string app_name) {
    run_on_tray_thread([app_name = std::move(app_name)]() mutable {
      if (!app_name.empty() && app_name == s_last_playing_app && tray.icon && std::strcmp(tray.icon, TRAY_ICON_PLAYING) == 0) {
        return;
      }

      tray.notification_title = nullptr;
      tray.notification_text = nullptr;
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;
      tray.icon = TRAY_ICON_PLAYING;

      char msg[256];
      snprintf(msg, std::size(msg), "%s launched.", app_name.c_str());
  #if defined(__APPLE__) || defined(__MACH__)
      snprintf(
        s_force_close_msg,
        std::size(s_force_close_msg),
        is_macos_tray_korean() ? "[%s] 강제 종료" : "Force close [%s]",
        app_name.c_str()
      );
  #else
      snprintf(s_force_close_msg, std::size(s_force_close_msg), "Force close [%s]", app_name.c_str());
  #endif
  #ifdef _WIN32
      auto msg_acp = utf8ToAcp(msg);
      auto force_msg_acp = utf8ToAcp(s_force_close_msg);
      strncpy(msg, msg_acp.c_str(), std::size(msg) - 1);
      msg[std::size(msg) - 1] = '\0';
      strncpy(s_force_close_msg, force_msg_acp.c_str(), std::size(s_force_close_msg) - 1);
      s_force_close_msg[std::size(s_force_close_msg) - 1] = '\0';
  #endif
      s_notification_text = msg;
      s_tooltip = "Streaming started for " + app_name;
      tray.notification_title = "App launched";
      tray.notification_text = s_notification_text.c_str();
      tray.notification_icon = TRAY_ICON_PLAYING;
      tray.tooltip = s_tooltip.c_str();
      if (auto *force_item = find_force_stop_menu_item()) {
        force_item->text = s_force_close_msg;
      }
      s_last_playing_app = std::move(app_name);
      tray_update(&tray);
    });
  }

  void update_tray_pausing(std::string app_name) {
    run_on_tray_thread([app_name = std::move(app_name)]() {
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;
      tray.notification_text = nullptr;
      tray.notification_title = nullptr;
      tray.icon = TRAY_ICON_PAUSING;

      char msg[256];
      snprintf(msg, std::size(msg), "Streaming paused for %s", app_name.c_str());
  #ifdef _WIN32
      auto msg_acp = utf8ToAcp(msg);
      strncpy(msg, msg_acp.c_str(), std::size(msg) - 1);
      msg[std::size(msg) - 1] = '\0';
  #endif
      s_notification_text = msg;
      tray.notification_title = "Stream Paused";
      tray.notification_text = s_notification_text.c_str();
      tray.notification_icon = TRAY_ICON_PAUSING;
      tray.tooltip = s_notification_text.c_str();
      tray_update(&tray);
    });
  }

  void update_tray_stopped(std::string app_name) {
    run_on_tray_thread([app_name = std::move(app_name)]() {
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;
      tray.notification_text = nullptr;
      tray.notification_title = nullptr;
      tray.icon = TRAY_ICON;

      char msg[256];
      snprintf(msg, std::size(msg), "Streaming stopped for %s", app_name.c_str());
  #ifdef _WIN32
      auto msg_acp = utf8ToAcp(msg);
      strncpy(msg, msg_acp.c_str(), std::size(msg) - 1);
      msg[std::size(msg) - 1] = '\0';
  #endif
      s_notification_text = msg;
      tray.notification_icon = TRAY_ICON;
      tray.notification_title = "Application Stopped";
      tray.notification_text = s_notification_text.c_str();
      tray.tooltip = PROJECT_NAME;
      s_last_playing_app.clear();
  #if defined(__APPLE__) || defined(__MACH__)
      sync_macos_tray_localization();
  #else
      if (auto *force_item = find_force_stop_menu_item()) {
        force_item->text = TRAY_MSG_NO_APP_RUNNING;
      }
  #endif
      tray_update(&tray);
    });
  }

  void
    update_tray_launch_error(std::string app_name, int exit_code) {
    run_on_tray_thread([app_name = std::move(app_name), exit_code]() {
      tray.notification_title = nullptr;
      tray.notification_text = nullptr;
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;
      tray.icon = TRAY_ICON;

      char msg[256];
      snprintf(msg, std::size(msg), "Application %s exited too fast with code %d. Click here to terminate the stream.", app_name.c_str(), exit_code);
  #ifdef _WIN32
      auto msg_acp = utf8ToAcp(msg);
      strncpy(msg, msg_acp.c_str(), std::size(msg) - 1);
      msg[std::size(msg) - 1] = '\0';
  #endif
      s_notification_text = msg;
      tray.notification_icon = TRAY_ICON;
      tray.notification_title = "Launch Error";
      tray.notification_text = s_notification_text.c_str();
      tray.notification_cb = []() {
        BOOST_LOG(info) << "Force stop from notification"sv;
        proc::proc.terminate();
      };
      tray.tooltip = PROJECT_NAME;
      s_last_playing_app.clear();
  #if defined(__APPLE__) || defined(__MACH__)
      sync_macos_tray_localization();
  #else
      if (auto *force_item = find_force_stop_menu_item()) {
        force_item->text = TRAY_MSG_NO_APP_RUNNING;
      }
  #endif
      tray_update(&tray);
    });
  }

  void update_tray_require_pin() {
    run_on_tray_thread([]() {
      tray.notification_title = nullptr;
      tray.notification_text = nullptr;
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;
      tray.icon = TRAY_ICON;

      tray.notification_title = "Incoming Pairing Request";
      tray.notification_text = "Click here to complete the pairing process";
      tray.notification_icon = TRAY_ICON_LOCKED;
      tray.tooltip = PROJECT_NAME;
      tray.notification_cb = []() {
        launch_ui("/clients");
      };
      tray_update(&tray);
    });
  }

  void
    update_tray_paired(std::string device_name) {
    run_on_tray_thread([device_name = std::move(device_name)]() {
      tray.notification_title = nullptr;
      tray.notification_text = nullptr;
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;

      char msg[256];
      snprintf(msg, std::size(msg), "Device %s paired Succesfully. Please make sure you have access to the device.", device_name.c_str());
  #ifdef _WIN32
      auto msg_acp = utf8ToAcp(msg);
      strncpy(msg, msg_acp.c_str(), std::size(msg) - 1);
      msg[std::size(msg) - 1] = '\0';
  #endif
      tray.notification_title = "Device Paired Succesfully";
      static std::string s_paired_text;
      s_paired_text = msg;
      tray.notification_text = s_paired_text.c_str();
      tray.notification_icon = TRAY_ICON;
      tray.tooltip = PROJECT_NAME;
      tray_update(&tray);
    });
  }

  void
    update_tray_client_connected(std::string client_name) {
    run_on_tray_thread([client_name = std::move(client_name)]() {
      tray.notification_title = nullptr;
      tray.notification_text = nullptr;
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;
      tray.icon = TRAY_ICON;

      char msg[256];
      snprintf(msg, std::size(msg), "%s has connected to the session.", client_name.c_str());
  #ifdef _WIN32
      auto msg_acp = utf8ToAcp(msg);
      strncpy(msg, msg_acp.c_str(), std::size(msg) - 1);
      msg[std::size(msg) - 1] = '\0';
  #endif
      tray.notification_title = "Client Connected";
      static std::string s_client_text;
      s_client_text = msg;
      tray.notification_text = s_client_text.c_str();
      tray.notification_icon = TRAY_ICON;
      tray.tooltip = PROJECT_NAME;
      tray_update(&tray);
    });
  }

  void update_tray_vigem_missing() {
    run_on_tray_thread([]() {
      tray.notification_title = nullptr;
      tray.notification_text = nullptr;
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;
      tray.icon = TRAY_ICON;

      tray.notification_title = "Gamepad Input Unavailable";
      tray.notification_text = "ViGEm is not installed. Click for setup info";
      tray.notification_icon = TRAY_ICON;
      tray.tooltip = PROJECT_NAME;
      tray.notification_cb = []() {
        launch_ui("/");
      };
      tray_update(&tray);
    });
  }

  // Threading functions available on all platforms
#ifndef _WIN32
  static void tray_thread_worker() {
    BOOST_LOG(info) << "System tray thread started"sv;

    // Initialize the tray in this thread
    if (init_tray() != 0) {
      BOOST_LOG(error) << "Failed to initialize tray in thread"sv;
      tray_thread_running = false;
      return;
    }

    tray_thread_running = true;

    // Run the event loop
    while (!tray_thread_should_exit) {
      tray_loop(1);
    }

    // Cleanup
    tray_exit();
    tray_initialized = false;
    tray_thread_running = false;
    BOOST_LOG(info) << "System tray thread ended"sv;
  }
#endif

  int init_tray_threaded() {
#ifdef _WIN32
    bool started = false;
    try {
      started = tray_worker.start([]() {
        tray_set_log_callback(&tray_log_bridge);
        // Only the worker that owns startup may change the live tray menu.
        static const std::string title = utf8ToAcp("Open Apollo (" + config::nvhttp.sunshine_name + ":" + std::to_string(net::map_port(confighttp::PORT_HTTPS)) + ")");
        tray.menu[0].text = title.c_str();
        if (config::sunshine.hide_tray_controls) {
          tray.menu[1].text = nullptr;
        }
        system_tray();
      });
    } catch (const std::exception &e) {
      BOOST_LOG(error) << "Failed to create tray thread: " << e.what();
      return 1;
    }
    if (!started) {
      return 1;
    }

    const auto deadline = std::chrono::steady_clock::now() + 10s;
    while (!tray_initialized.load() && !tray_worker.stop_requested()) {
      if (std::chrono::steady_clock::now() >= deadline) {
        BOOST_LOG(error) << "Tray thread initialization timeout"sv;
        end_tray();
        return 1;
      }
      tray_worker.wait_for_stop(10ms);
    }
    return tray_initialized.load() ? 0 : 1;
  #else
    if (tray_thread_running) {
      BOOST_LOG(warning) << "Tray thread is already running"sv;
      return 1;
    }

    static const std::string title_str = "Open Apollo (" + config::nvhttp.sunshine_name + ":" + std::to_string(net::map_port(confighttp::PORT_HTTPS)) + ")";
    tray.menu[0].text = title_str.c_str();

    if (config::sunshine.hide_tray_controls) {
      tray.menu[1].text = nullptr;
    }

    tray_thread_should_exit = false;

    try {
      tray_thread = std::thread(tray_thread_worker);

      // Wait for the thread to start and initialize
      const auto start_time = std::chrono::steady_clock::now();
      while (!tray_thread_running && !tray_thread_should_exit) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));

        // Timeout after 10 seconds
        if (std::chrono::steady_clock::now() - start_time > std::chrono::seconds(10)) {
          BOOST_LOG(error) << "Tray thread initialization timeout"sv;
          tray_thread_should_exit = true;
          if (tray_thread.joinable()) {
            tray_thread.join();
          }
          return 1;
        }
      }

      if (!tray_thread_running) {
        BOOST_LOG(error) << "Tray thread failed to start"sv;
        if (tray_thread.joinable()) {
          tray_thread.join();
        }
        return 1;
      }

      BOOST_LOG(info) << "System tray thread initialized successfully"sv;
      return 0;
    } catch (const std::exception &e) {
      BOOST_LOG(error) << "Failed to create tray thread: " << e.what();
      return 1;
    }
  #endif
  }

  int end_tray_threaded() {
#ifdef _WIN32
    return end_tray();
#else
    if (!tray_thread_running) {
      return 0;
    }

    BOOST_LOG(info) << "Stopping system tray thread"sv;
    tray_thread_should_exit = true;

    if (tray_thread.joinable()) {
      tray_thread.join();
    }

    return 0;
#endif
  }

  void tray_notify(const char *title, const char *text, void (*cb)()) {
    std::string title_copy = title ? std::string {title} : std::string {};
    std::string text_copy = text ? std::string {text} : std::string {};

    run_on_tray_thread([title_copy = std::move(title_copy), text_copy = std::move(text_copy), cb]() {
      tray.notification_title = nullptr;
      tray.notification_text = nullptr;
      tray.notification_cb = nullptr;
      tray.notification_icon = nullptr;
      tray.icon = TRAY_ICON;
      tray_update(&tray);

      static std::string s_notify_title;
      s_notify_title = title_copy;
      s_notification_text = text_copy;

      tray.icon = TRAY_ICON;
      tray.notification_title = s_notify_title.empty() ? nullptr : s_notify_title.c_str();
      tray.notification_text = s_notification_text.c_str();
      tray.notification_icon = TRAY_ICON;
      tray.tooltip = PROJECT_NAME;
      tray.notification_cb = cb;
      tray_update(&tray);
    });
  }

}  // namespace system_tray

#endif
