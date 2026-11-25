/**
 * @file src/platform/macos/virtual_display_watchdog.mm
 * @brief Physical display power/mode safeguards, crash-restore watchdog, and marker recovery.
 */
// standard includes
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

// platform includes
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

// local includes
#include "misc.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "virtual_display_internal.h"

extern char **environ;

using namespace std::literals;

namespace platf::macos_virtual_display {
  namespace {
    using configure_display_enabled_fn = CGError (*)(CGDisplayConfigRef, CGDirectDisplayID, bool);

    configure_display_enabled_fn configure_display_enabled() {
      static const auto fn = reinterpret_cast<configure_display_enabled_fn>(dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled"));
      return fn;
    }

    // For the restore helper, which has no event loop of its own.
    void pump_events(const std::chrono::milliseconds duration) {
      NSDate *until = [NSDate dateWithTimeIntervalSinceNow:duration.count() / 1000.0];
      while (until.timeIntervalSinceNow > 0) {
        @autoreleasepool {
          NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
          if (event) {
            [NSApp sendEvent:event];
          }
        }
      }
    }

    std::filesystem::path marker_path() {
      return platf::appdata() / "macos_displays_turned_off";
    }

    /// Replaces the marker whole, so a failed write never leaves a partial list behind.
    bool write_marker(const std::vector<CGDirectDisplayID> &ids) {
      const auto path = marker_path();
      auto temporary = path;
      temporary += ".tmp";
      {
        std::ofstream file {temporary};
        for (const auto id : ids) {
          file << id << '\n';
        }
        file.flush();
        if (!file) {
          BOOST_LOG(warning) << "Virtual display: couldn't write "sv << temporary.string();
          return false;
        }
      }
      std::error_code ec;
      std::filesystem::rename(temporary, path, ec);
      if (ec) {
        BOOST_LOG(warning) << "Virtual display: couldn't write "sv << path.string() << ": "sv << ec.message();
        std::filesystem::remove(temporary, ec);
        return false;
      }
      return true;
    }

    std::vector<CGDirectDisplayID> read_marker() {
      std::vector<CGDirectDisplayID> ids;
      std::ifstream file {marker_path()};
      for (CGDirectDisplayID id; file >> id;) {
        ids.push_back(id);
      }
      return ids;
    }

    void remove_marker() {
      std::error_code ec;
      std::filesystem::remove(marker_path(), ec);
    }

    bool same_mode(const CGDisplayModeRef a, const CGDisplayModeRef b) {
      return CGDisplayModeGetPixelWidth(a) == CGDisplayModeGetPixelWidth(b) && CGDisplayModeGetPixelHeight(a) == CGDisplayModeGetPixelHeight(b) &&
             CGDisplayModeGetWidth(a) == CGDisplayModeGetWidth(b) && CGDisplayModeGetHeight(a) == CGDisplayModeGetHeight(b);
    }

    detail::watchdog_t start_watchdog(const std::vector<CGDirectDisplayID> &ids) {
      int fds[2];
      if (pipe(fds) != 0) {
        BOOST_LOG(warning) << "Virtual display: couldn't start the restore helper: "sv << std::strerror(errno);
        return {};
      }
      fcntl(fds[0], F_SETFD, FD_CLOEXEC);
      fcntl(fds[1], F_SETFD, FD_CLOEXEC);
      // If the helper died first, writing "done" must fail rather than raise SIGPIPE here.
      fcntl(fds[1], F_SETNOSIGPIPE, 1);

      char executable[PATH_MAX];
      uint32_t size = sizeof(executable);
      if (_NSGetExecutablePath(executable, &size) != 0) {
        close(fds[0]);
        close(fds[1]);
        BOOST_LOG(warning) << "Virtual display: couldn't start the restore helper: no executable path"sv;
        return {};
      }

      std::vector<std::string> args {executable, std::string {restore_watchdog_arg}};
      for (const auto id : ids) {
        args.push_back(std::to_string(id));
      }
      std::vector<char *> argv;
      for (auto &arg : args) {
        argv.push_back(arg.data());
      }
      argv.push_back(nullptr);

      // Inherit only the pipe (as stdin): an inherited listening socket would keep Vibepollo's
      // ports busy after a crash.
      posix_spawnattr_t attributes;
      posix_spawnattr_init(&attributes);
      posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
      posix_spawn_file_actions_t actions;
      posix_spawn_file_actions_init(&actions);
      posix_spawn_file_actions_adddup2(&actions, fds[0], STDIN_FILENO);

      pid_t pid = -1;
      const int result = posix_spawn(&pid, executable, &actions, &attributes, argv.data(), environ);
      posix_spawn_file_actions_destroy(&actions);
      posix_spawnattr_destroy(&attributes);
      close(fds[0]);

      if (result != 0) {
        close(fds[1]);
        BOOST_LOG(warning) << "Virtual display: couldn't start the restore helper: "sv << std::strerror(result);
        return {};
      }
      return {pid, fds[1]};
    }
  }  // namespace

  namespace detail {
    bool has_configure_display_enabled() {
      return configure_display_enabled() != nullptr;
    }

    bool wait_until(const std::function<bool()> &condition, const std::chrono::milliseconds timeout) {
      const auto deadline = std::chrono::steady_clock::now() + timeout;
      while (!condition()) {
        if (std::chrono::steady_clock::now() >= deadline) {
          return false;
        }
        std::this_thread::sleep_for(5ms);
      }
      return true;
    }

    std::vector<CGDirectDisplayID> display_list(CGError (*list)(uint32_t, CGDirectDisplayID *, uint32_t *)) {
      std::vector<CGDirectDisplayID> ids(32);
      uint32_t count = 0;
      if (list(static_cast<uint32_t>(ids.size()), ids.data(), &count) != kCGErrorSuccess) {
        return {};
      }
      ids.resize(count);
      return ids;
    }

    bool is_active(const CGDirectDisplayID id) {
      const auto active = display_list(CGGetActiveDisplayList);
      return std::find(active.begin(), active.end(), id) != active.end();
    }

    // A display that no longer exists, such as another app's virtual display removed while it was
    // turned off, reports this vendor. A display that's only turned off keeps its real one.
    bool is_gone(const CGDirectDisplayID id) {
      return CGDisplayVendorNumber(id) == 0xFFFFFFFF;
    }

    std::pair<std::size_t, std::size_t> current_pixels(const CGDirectDisplayID id) {
      const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id);
      if (!mode) {
        return {0, 0};
      }
      const std::pair<std::size_t, std::size_t> pixels {CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode)};
      CGDisplayModeRelease(mode);
      return pixels;
    }

    // Session scope, so the change doesn't depend on this process staying alive.
    bool set_displays_enabled(const std::vector<CGDirectDisplayID> &ids, const bool enabled) {
      const auto configure = configure_display_enabled();
      CGDisplayConfigRef config;
      if (!configure || CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return false;
      }
      for (const auto id : ids) {
        configure(config, id, enabled);
      }
      return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
    }

    // One configuration per display: a single display that fails, like one that's since been
    // removed, would otherwise fail them all and leave every screen off. Enabling a display that's
    // already on fails too, so skip those. Every display is attempted; only a removed one may fail.
    bool turn_on(const std::vector<CGDirectDisplayID> &ids) {
      bool restored = true;
      for (const auto id : ids) {
        if (!is_active(id) && !set_displays_enabled({id}, true) && !is_gone(id)) {
          restored = false;
        }
      }
      return restored;
    }

    std::string format_ids(const std::vector<CGDirectDisplayID> &ids) {
      std::string result;
      for (const auto id : ids) {
        result += (result.empty() ? ""s : ", "s) + std::to_string(id);
      }
      return result;
    }

    /**
     * @brief Split off a closed MacBook's built-in display, which can't be turned on until the lid opens.
     * @details Once turned off, it comes back on by itself when the lid opens (seen on macOS 27), but it
     *          stays in the marker in case it doesn't. CGDisplayIsOnline() can't tell: macOS reports a
     *          display that's only turned off as offline too.
     */
    std::pair<std::vector<CGDirectDisplayID>, std::vector<CGDirectDisplayID>> split_offline(const std::vector<CGDirectDisplayID> &ids) {
      std::pair<std::vector<CGDirectDisplayID>, std::vector<CGDirectDisplayID>> result;
      const bool lid_closed = platf::lid_closed();
      for (const auto id : ids) {
        (lid_closed && CGDisplayIsBuiltin(id) && !is_gone(id) ? result.second : result.first).push_back(id);
      }
      return result;
    }

    /// After turning displays back on: forget the marker, or keep just the offline ones in it.
    void settle_marker(const std::vector<CGDirectDisplayID> &offline) {
      if (offline.empty()) {
        remove_marker();
        return;
      }
      write_marker(offline);
      BOOST_LOG(info) << "Virtual display: the lid is closed, so the built-in display "sv << format_ids(offline) << " comes back on when it opens"sv;
    }

    saved_modes_t::saved_modes_t() {
      for (const auto id : display_list(CGGetActiveDisplayList)) {
        if (const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id)) {
          modes.emplace_back(id, mode);
        }
      }
    }

    void saved_modes_t::add(const CGDirectDisplayID id) {
      if (std::any_of(modes.begin(), modes.end(), [id](const auto &entry) {
            return entry.first == id;
          })) {
        return;
      }
      if (const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id)) {
        modes.emplace_back(id, mode);
      }
    }

    saved_modes_t::~saved_modes_t() {
      for (const auto &[_, mode] : modes) {
        CGDisplayModeRelease(mode);
      }
    }

    void saved_modes_t::restore(const std::chrono::milliseconds wait) const {
      wait_until([this]() {
        return !changed().empty();
      },
                 wait);
      const auto displays = changed();
      CGDisplayConfigRef config;
      if (displays.empty() || CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return;
      }
      for (const auto &[id, mode] : displays) {
        BOOST_LOG(info) << "Virtual display: putting back the mode macOS changed on display "sv << id;
        CGConfigureDisplayWithDisplayMode(config, id, mode, nullptr);
      }
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }

    std::vector<std::pair<CGDirectDisplayID, CGDisplayModeRef>> saved_modes_t::changed() const {
      std::vector<std::pair<CGDirectDisplayID, CGDisplayModeRef>> result;
      for (const auto &[id, mode] : modes) {
        const CGDisplayModeRef current = CGDisplayCopyDisplayMode(id);
        if (current && is_active(id) && !same_mode(current, mode)) {
          result.emplace_back(id, mode);
        }
        if (current) {
          CGDisplayModeRelease(current);
        }
      }
      return result;
    }

    void stop_watchdog(watchdog_t &watchdog, const bool displays_restored) {
      if (watchdog.fd < 0) {
        watchdog.pid = -1;
        return;
      }
      if (displays_restored) {
        constexpr char done = 'd';
        (void) write(watchdog.fd, &done, 1);
      }
      // Without "done", the helper turns the displays back on itself.
      close(watchdog.fd);
      watchdog.fd = -1;
      wait_until([&watchdog]() {
        const pid_t r = waitpid(watchdog.pid, nullptr, WNOHANG);
        return r > 0 || (r < 0 && errno != EINTR);
      },
                 3s);
      watchdog.pid = -1;
    }

    /// The safeguards and display changes macos_display_policy::cover_and_turn_off() makes.
    const macos_display_policy::safeguard_ops_t &safeguard_ops() {
      static const macos_display_policy::safeguard_ops_t ops {
        .write_marker = write_marker,
        .remove_marker = remove_marker,
        .start_helper = start_watchdog,
        .stop_helper = stop_watchdog,
        .turn_off = [](const std::vector<CGDirectDisplayID> &ids) {
          return set_displays_enabled(ids, false);
        },
      };
      return ops;
    }
  }  // namespace detail

  void recover_disabled_displays() {
    dispatch_async(dispatch_get_main_queue(), ^{
      // Not under state_mutex, which removing a display holds for seconds.
      if (detail::current_display_id() != kCGNullDirectDisplay) {
        return;
      }
      const auto ids = read_marker();
      if (ids.empty()) {
        return;
      }
      const auto [online, offline] = detail::split_offline(ids);
      if (online.empty()) {
        return;  // still offline; checked again when the lid opens or at the next launch
      }
      BOOST_LOG(warning) << "Virtual display: turning back on displays that were left off"sv;
      if (detail::turn_on(online)) {
        detail::settle_marker(offline);
      } else {
        BOOST_LOG(error) << "Virtual display: couldn't turn them back on; logging out and back in will"sv;
      }
    });
  }

  int run_restore_watchdog(int argc, char *argv[]) {
    // Survive "killall Vibepollo" and hangups: the main process's exit is what this waits for.
    std::signal(SIGINT, SIG_IGN);
    std::signal(SIGTERM, SIG_IGN);
    std::signal(SIGHUP, SIG_IGN);

    std::vector<CGDirectDisplayID> ids;
    for (int i = 2; i < argc; ++i) {
      ids.push_back(static_cast<CGDirectDisplayID>(std::strtoul(argv[i], nullptr, 10)));
    }

    char message = 0;
    ssize_t count;
    do {
      count = read(STDIN_FILENO, &message, 1);
    } while (count < 0 && errno == EINTR);
    if (count == 1 && message == 'd') {
      return 0;  // Vibepollo turned them back on itself
    }

    // Vibepollo exited without restoring them. Display configuration needs an AppKit session.
    ensure_appkit_session();
    pump_events(500ms);
    const bool restored = detail::turn_on(ids);
    pump_events(1s);
    if (restored) {
      remove_marker();
    }
    return restored ? 0 : 1;
  }
}  // namespace platf::macos_virtual_display
