/**
 * @file src/platform/macos/misc.h
 * @brief Miscellaneous declarations for macOS platform.
 */
#pragma once

// standard includes
#include <chrono>
#include <functional>
#include <memory>
#include <string_view>
#include <vector>

// platform includes
#include <CoreGraphics/CoreGraphics.h>

namespace video {
  struct config_t;
}

namespace platf {
  class display_t;

  bool is_screen_capture_allowed();

  /**
   * @brief A display that captures nothing and produces black frames, for Remote Input streams.
   */
  std::shared_ptr<display_t> black_display(const video::config_t &config);

  /**
   * @brief Set up this process's AppKit session once. Call on the main thread.
   * @details Display configuration and display-mode queries only work in an AppKit session.
   */
  void ensure_appkit_session();

  /**
   * @brief Run the AppKit event loop on the main thread until `should_exit` returns true.
   * @details Delivers menu bar events and display reconfiguration notifications. `should_exit`
   *          is checked at least twice a second.
   */
  void run_main_event_loop(const std::function<bool()> &should_exit);

  /**
   * @brief Whether Open at Login is on.
   * @details launchd then runs Vibepollo from login, and restarts it if it crashes. It's listed
   *          under Allow in the Background in System Settings > General > Login Items.
   */
  bool opens_at_login();

  /**
   * @brief Whether launchd started this process for Open at Login.
   */
  bool is_login_agent();

  /**
   * @brief Turn Open at Login on or off.
   * @details Turning it on starts the login agent, which then takes over from this process.
   *          Turning it off stops the login agent, so if this is it, a new copy of Vibepollo
   *          carries on. If the user turned Vibepollo off in System Settings, only they can turn
   *          it back on, so this opens Login Items for them.
   * @return `true` if Open at Login is now `enabled`.
   */
  bool set_opens_at_login(bool enabled);

  /**
   * @brief If Open at Login is on and this isn't the login agent, start the agent instead.
   * @details Keeps Vibepollo under launchd's care however it's opened.
   * @return `true` if this process should exit and leave it to the agent.
   */
  bool defer_to_login_agent();

  /**
   * @brief Make sure no other copy of Vibepollo runs alongside this one.
   * @details Waits for another copy to quit, as it does when handing over to or from the login
   *          agent. The login agent asks the other copy to quit first.
   * @param timeout How long to wait for another copy to quit.
   * @return `false` if another copy is still running.
   */
  bool acquire_instance_lock(std::chrono::milliseconds timeout);

  /**
   * @brief Turn the displays on if they're asleep, as a keypress would, and wait for one to come on.
   * @details A client can connect while the Mac sleeps. Its network traffic only brings the Mac into
   *          a "dark wake" with every display off, where captures get no frames. Returns right
   *          away on a Mac with no display connected.
   * @param timeout How long to wait for a display to come on.
   * @return `true` if a display is on.
   */
  bool wake_displays(std::chrono::milliseconds timeout = std::chrono::seconds {5});

  /**
   * @brief Run `handler` whenever the Mac is about to sleep, before letting it sleep.
   * @details For ending streams properly: otherwise a client just sees its stream freeze. The
   *          handler runs on a background queue. Only the first call registers a handler.
   */
  void on_system_will_sleep(std::function<void()> handler);

  /**
   * @brief Run `closed` whenever a MacBook's lid goes from open to closed, and `opened` when it opens again.
   * @details The handlers run on a background queue. Only the first call registers them.
   */
  void watch_lid(std::function<void()> closed, std::function<void()> opened);

  /**
   * @brief Whether a MacBook's lid is closed right now. Always false on a Mac without one.
   */
  bool lid_closed();

  inline constexpr std::string_view install_loginscreen_agent_arg = "--macos-install-loginscreen-agent";
  inline constexpr std::string_view remove_loginscreen_agent_arg = "--macos-remove-loginscreen-agent";
  inline constexpr std::string_view aqua_handoff_arg = "--macos-aqua-handoff";
  inline constexpr std::string_view install_update_arg = "--macos-install-update";

  /**
   * @brief Whether this process is running inside the pre-login macOS LoginWindow session.
   */
  bool is_loginwindow_session();

  /**
   * @brief Whether a non-root LaunchAgent launch occurred for a non-owner macOS account or while
   *        macOS has no active interactive Aqua session for this user.
   */
  bool should_exit_for_inactive_gui_session();

  /**
   * @brief Prepare an isolated root-owned runtime directory seeded from the owner's paired config
   *        when running in the pre-login macOS LoginWindow session.
   */
  void prepare_loginwindow_runtime();

  /**
   * @brief Wait briefly during the LoginWindow -> Aqua transition for the exiting pre-login agent
   *        to finish releasing its lock and listening ports before binding in the user session.
   */
  void wait_for_loginwindow_handoff(std::uint16_t base_port, std::chrono::milliseconds timeout = std::chrono::seconds {5});

  /**
   * @brief Abort any open accepted TCP client sockets with `SO_LINGER {1, 0}` right before
   *        `LoginWindow` exits so root-owned HTTP keep-alive sockets leave zero `TIME_WAIT` PCBs.
   */
  void abort_open_loginwindow_tcp_clients();

  /**
   * @brief Bootstrap a one-shot `system` domain handoff job right before `LoginWindow` exits so
   *        the incoming `Aqua` session launches Vibepollo immediately (~0.5s) instead of waiting
   *        up to 60s for `launchd` `on-demand-only mode` / TAL relaunch completion.
   */
  void spawn_loginwindow_aqua_handoff();

  /**
   * @brief Privileged one-shot helper that wakes the owner's `Aqua` Vibepollo instance as soon as
   *        `gui/<uid>` comes online after login.
   */
  int run_aqua_handoff_helper(int argc, char *argv[]);

  /**
   * @brief Whether the system-wide `/Library/LaunchAgents` agent (`Aqua` + `LoginWindow`) is installed.
   */
  bool loginscreen_agent_enabled();

  /**
   * @brief Install or remove the system-wide `/Library/LaunchAgents` agent (`Aqua` + `LoginWindow`)
   *        via standard macOS administrator authorization.
   */
  bool set_loginscreen_agent_enabled(bool enabled);

  /**
   * @brief Privileged helper entrypoint invoked with administrator rights to install or remove the
   *        `/Library/LaunchAgents` plist cleanly.
   */
  int run_loginscreen_agent_helper(int argc, char *argv[]);

  /**
   * @brief Privileged helper entrypoint invoked with administrator rights to atomically replace a
   *        root-owned `/Applications/Vibepollo.app` bundle from a verified mounted DMG bundle.
   */
  int run_macos_update_helper(int argc, char *argv[]);

  /**
   * @brief Check whether this running process resides inside a writable/updatable `.app` bundle.
   */
  bool can_self_update_macos_bundle(std::string *out_bundle_path = nullptr, std::string *out_reason = nullptr);

  /**
   * @brief Mount a verified `.dmg`, validate code signatures and bundle/team identity, atomically
   *        swap the `.app` bundle in place (prompting for macOS administrator credentials if needed),
   *        and stage the new executable path for `platf::restart()`.
   */
  bool install_macos_update_dmg(const std::string &dmg_path, std::string &out_error_code, std::string &out_error_detail);

  /**
   * @brief Record a one-shot native Settings route to reopen immediately after `platf::restart()`.
   */
  void set_pending_reopen_ui_route(std::string_view route);

  /**
   * @brief Atomically read and remove any pending post-restart native Settings route.
   */
  std::string consume_pending_reopen_ui_route();

  /**
   * @brief Whether the native macOS Settings window is currently open and visible.
   */
  bool is_native_settings_window_visible();
}

namespace dyn {
  typedef void (*apiproc)();

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict = true);
  void *handle(const std::vector<const char *> &libs);

}  // namespace dyn
