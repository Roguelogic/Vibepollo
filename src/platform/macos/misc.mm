/**
 * @file src/platform/macos/misc.mm
 * @brief Miscellaneous definitions for macOS platform.
 */

// Required for IPV6_PKTINFO with Darwin headers
#ifndef __APPLE_USE_RFC_3542  // NOLINT(bugprone-reserved-identifier)
  #define __APPLE_USE_RFC_3542 1
#endif

// standard includes
#include <array>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <ifaddrs.h>
#include <mutex>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <thread>
#include <vector>

// platform includes
#include <AppKit/AppKit.h>
#include <arpa/inet.h>
#import <Carbon/Carbon.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <Foundation/Foundation.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPM.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <poll.h>
#include <pwd.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>
#include <ServiceManagement/ServiceManagement.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/qos.h>
#include <sys/wait.h>

// lib includes
#include <boost/asio/ip/address.hpp>
#include <boost/asio/ip/host_name.hpp>
#include <boost/asio/system_executor.hpp>
#include <boost/program_options/parsers.hpp>

// local includes
#include "misc.h"
#include "src/platform/common_services.h"
#include "src/boost_process_shim.h"
#include "src/entry_handler.h"
#include "src/logging.h"
#include "src/platform/common.h"

using namespace std::literals;
namespace fs = std::filesystem;
namespace bp = boost_process_shim;
namespace v2 = boost::process::v2;

// Required by macOS SkyLight's `app_permitted_to_connect_or_launch()` (`getsectdata("__CGPreLoginApp", "__cgpreloginapp", ...)`)
// so the LaunchAgent is permitted to connect to WindowServer, create CGEventSources, and capture displays before login.
__attribute__((used, section("__CGPreLoginApp,__cgpreloginapp")))
static unsigned char s_macos_cg_prelogin_app = 0;

namespace platf {

// Even though the following two functions are available starting in macOS 10.15, they weren't
// actually in the Mac SDK until Xcode 12.2, the first to include the SDK for macOS 11
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 110000  // __MAC_11_0
  // If they're not in the SDK then we can use our own function definitions.
  // Need to use weak import so that this will link in macOS 10.14 and earlier
  extern "C" bool CGPreflightScreenCaptureAccess(void) __attribute__((weak_import));
  extern "C" bool CGRequestScreenCaptureAccess(void) __attribute__((weak_import));
#endif

  namespace {
    auto screen_capture_allowed = std::atomic<bool> {false};
  }  // namespace

  // Return whether screen capture is allowed for this process.
  bool is_screen_capture_allowed() {
    return screen_capture_allowed;
  }

  void ensure_appkit_session() {
    static std::once_flag once;
    std::call_once(once, []() {
      if (is_loginwindow_session()) {
        // Wait up to 10s on early cold boot for WindowServer's LoginWindow session to accept connections.
        const auto deadline = std::chrono::steady_clock::now() + 10s;
        while (std::chrono::steady_clock::now() < deadline) {
          if (CFDictionaryRef session = CGSessionCopyCurrentDictionary()) {
            CFRelease(session);
            break;
          }
          std::this_thread::sleep_for(100ms);
        }
      }
      [NSApplication sharedApplication];
      // Never steal keyboard focus from SecurityAgent's password box on the LoginWindow screen
      // or show a Dock icon when running as a background/tray host.
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      [NSApp finishLaunching];
    });
  }

  void run_main_event_loop(const std::function<bool()> &should_exit) {
    ensure_appkit_session();
    while (!should_exit()) {
      @autoreleasepool {
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.5];
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event != nil) {
          [NSApp sendEvent:event];
          [NSApp updateWindows];
        }
      }
    }
  }

  namespace {
    SMAppService *login_agent() API_AVAILABLE(macos(13.0)) {
      // Contents/Library/LaunchAgents/<this>, whose Label is also PROJECT_FQDN.
      return [SMAppService agentServiceWithPlistName:@PROJECT_FQDN ".plist"];
    }

    // launchd stops the login agent when it's unregistered, so carry on in a copy of our own.
    void launch_replacement() {
      NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
      configuration.createsNewApplicationInstance = YES;
      configuration.activates = NO;
      [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL
                                          configuration:configuration
                                      completionHandler:^(NSRunningApplication *, NSError *launch_error) {
                                        if (launch_error != nil) {
                                          BOOST_LOG(error) << "Couldn't start Vibepollo again without Open at Login: "sv << launch_error.localizedDescription.UTF8String;
                                        }
                                      }];
    }

    int run(const std::vector<std::string> &args) {
      std::vector<char *> argv;
      for (const auto &arg : args) {
        argv.push_back(const_cast<char *>(arg.c_str()));
      }
      argv.push_back(nullptr);

      pid_t pid;
      if (posix_spawn(&pid, argv[0], nullptr, nullptr, argv.data(), *_NSGetEnviron()) != 0) {
        return -1;
      }
      int status = 0;
      while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
      return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
  }  // namespace

  namespace {
    constexpr std::string_view loginscreen_label = PROJECT_FQDN ".loginscreen";
    constexpr std::string_view loginscreen_plist_path = "/Library/LaunchAgents/" PROJECT_FQDN ".loginscreen.plist";
    constexpr std::string_view loginwindow_runtime_root = "/Library/Application Support/Vibepollo/loginwindow-runtime";

    bool detect_loginwindow_session() {
      if (const char *forced = std::getenv("VIBEPOLLO_FORCE_LOGINWINDOW");
          forced != nullptr && forced[0] == '1' && forced[1] == '\0') {
        return true;
      }
      if (geteuid() != 0) {
        return false;
      }
      if (const char *lw_env = std::getenv("VIBEPOLLO_LOGINWINDOW");
          lw_env != nullptr && lw_env[0] == '1') {
        return true;
      }
      bool is_prelogin = false;
      if (CFDictionaryRef session = CGSessionCopyCurrentDictionary()) {
        const auto login_done = static_cast<CFBooleanRef>(CFDictionaryGetValue(session, kCGSessionLoginDoneKey));
        const auto username = static_cast<CFStringRef>(CFDictionaryGetValue(session, kCGSessionUserNameKey));
        if (login_done == kCFBooleanFalse || username == nullptr) {
          is_prelogin = true;
        }
        CFRelease(session);
      }
      return is_prelogin;
    }

    bool copy_file_mode_0600(const fs::path &src, const fs::path &dst) {
      std::error_code ec;
      if (!fs::is_regular_file(src, ec) || ec) {
        return false;
      }
      std::ifstream in(src, std::ios::binary);
      if (!in) {
        return false;
      }
      std::string bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
      fs::create_directories(dst.parent_path(), ec);
      ::unlink(dst.c_str());
      const int fd = ::open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
      if (fd < 0) {
        return false;
      }
      std::size_t off = 0;
      bool ok = true;
      while (off < bytes.size()) {
        const ssize_t n = ::write(fd, bytes.data() + off, bytes.size() - off);
        if (n < 0) {
          if (errno == EINTR) {
            continue;
          }
          ok = false;
          break;
        }
        off += static_cast<std::size_t>(n);
      }
      ::fchmod(fd, 0600);
      ::close(fd);
      return ok;
    }

    std::string xml_escape(std::string_view s) {
      std::string out;
      out.reserve(s.size());
      for (const char c : s) {
        switch (c) {
          case '&':
            out += "&amp;";
            break;
          case '<':
            out += "&lt;";
            break;
          case '>':
            out += "&gt;";
            break;
          case '"':
            out += "&quot;";
            break;
          case '\'':
            out += "&apos;";
            break;
          default:
            out.push_back(c);
            break;
        }
      }
      return out;
    }
  }  // namespace

  bool is_loginwindow_session() {
    static const bool cached = detect_loginwindow_session();
    return cached;
  }

  void prepare_loginwindow_runtime() {
    if (!is_loginwindow_session()) {
      return;
    }

    const fs::path runtime_home {loginwindow_runtime_root};
    const fs::path runtime_cfg = runtime_home / ".config" / "vibepollo";
    std::error_code ec;
    fs::create_directories(runtime_cfg / "credentials", ec);
    ::chmod(runtime_home.parent_path().c_str(), 0755);
    ::chmod(runtime_home.c_str(), 0700);
    ::chmod((runtime_home / ".config").c_str(), 0700);
    ::chmod(runtime_cfg.c_str(), 0700);
    ::chmod((runtime_cfg / "credentials").c_str(), 0700);

    const char *owner_cfg_env = std::getenv("VIBEPOLLO_OWNER_CONFIG_DIR");
    if (owner_cfg_env != nullptr && owner_cfg_env[0] != '\0') {
      const fs::path src_cfg {owner_cfg_env};
      for (const char *fname : {"sunshine.conf", "sunshine_state.json", "vibeshine_state.json"}) {
        copy_file_mode_0600(src_cfg / fname, runtime_cfg / fname);
      }
      const fs::path src_creds = src_cfg / "credentials";
      if (fs::is_directory(src_creds, ec) && !ec) {
        for (const auto &entry : fs::directory_iterator(src_creds, ec)) {
          if (!ec && entry.is_regular_file()) {
            copy_file_mode_0600(entry.path(), runtime_cfg / "credentials" / entry.path().filename());
          }
        }
      }
    }

    // Lock pre-login apps.json strictly to Desktop only so no shell commands can be launched as root
    // before authenticating through macOS SecurityAgent.
    {
      const fs::path apps_path = runtime_cfg / "apps.json";
      constexpr std::string_view desktop_only_apps = R"({
  "env": {},
  "apps": [
    {
      "name": "Desktop",
      "image-path": "desktop.png"
    }
  ]
}
)";
      ::unlink(apps_path.c_str());
      const int fd = ::open(apps_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
      if (fd >= 0) {
        (void) ::write(fd, desktop_only_apps.data(), desktop_only_apps.size());
        ::fchmod(fd, 0600);
        ::close(fd);
      }
    }

    ::setenv("HOME", runtime_home.c_str(), 1);
    ::unsetenv("XDG_CONFIG_HOME");
  }

  bool is_login_agent() {
    // launchd names the job it started in XPC_SERVICE_NAME. Restarting from the menu bar
    // re-executes in place, so it survives that too.
    const char *service = getenv("XPC_SERVICE_NAME");
    if (service == nullptr) {
      return false;
    }
    const std::string_view sv {service};
    return sv == PROJECT_FQDN || sv == loginscreen_label;
  }

  bool loginscreen_agent_enabled() {
    std::error_code ec;
    return fs::is_regular_file(fs::path {loginscreen_plist_path}, ec) && !ec;
  }

  bool opens_at_login() {
    if (@available(macOS 13.0, *)) {
      return login_agent().status == SMAppServiceStatusEnabled;
    }
    return false;
  }

  int run_loginscreen_agent_helper(int argc, char *argv[]) {
    if (argc >= 2 && std::string_view {argv[1]} == remove_loginscreen_agent_arg) {
      if (geteuid() != 0) {
        std::fprintf(stderr, "Vibepollo: removing the login-screen agent requires root.\n");
        return 1;
      }
      ::unlink(std::string {loginscreen_plist_path}.c_str());
      std::error_code ec;
      fs::remove_all(fs::path {loginwindow_runtime_root}, ec);
      return 0;
    }

    if (argc < 4 || std::string_view {argv[1]} != install_loginscreen_agent_arg) {
      return 2;
    }
    if (geteuid() != 0) {
      std::fprintf(stderr, "Vibepollo: installing the login-screen agent requires root.\n");
      return 1;
    }

    const std::string owner_cfg_dir = argv[2];
    const std::string executable_path = argv[3];
    if (owner_cfg_dir.empty() || executable_path.empty() || executable_path.front() != '/') {
      return 2;
    }

    const std::string plist_xml =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
      "<plist version=\"1.0\">\n"
      "<dict>\n"
      "  <key>Label</key>\n"
      "  <string>" + xml_escape(loginscreen_label) + "</string>\n"
      "  <key>ProgramArguments</key>\n"
      "  <array>\n"
      "    <string>" + xml_escape(executable_path) + "</string>\n"
      "  </array>\n"
      "  <key>EnvironmentVariables</key>\n"
      "  <dict>\n"
      "    <key>VIBEPOLLO_LOGINWINDOW</key>\n"
      "    <string>1</string>\n"
      "    <key>VIBEPOLLO_OWNER_CONFIG_DIR</key>\n"
      "    <string>" + xml_escape(owner_cfg_dir) + "</string>\n"
      "  </dict>\n"
      "  <key>LimitLoadToSessionType</key>\n"
      "  <array>\n"
      "    <string>LoginWindow</string>\n"
      "  </array>\n"
      "  <key>RunAtLoad</key>\n"
      "  <true/>\n"
      "  <key>KeepAlive</key>\n"
      "  <dict>\n"
      "    <key>SuccessfulExit</key>\n"
      "    <false/>\n"
      "  </dict>\n"
      "  <key>ProcessType</key>\n"
      "  <string>Interactive</string>\n"
      "  <key>ThrottleInterval</key>\n"
      "  <integer>2</integer>\n"
      "</dict>\n"
      "</plist>\n";

    const fs::path dst {loginscreen_plist_path};
    const fs::path tmp = dst.string() + ".tmp";
    ::unlink(tmp.c_str());
    const int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (fd < 0) {
      return 1;
    }
    const ssize_t n = ::write(fd, plist_xml.data(), plist_xml.size());
    ::fchmod(fd, 0644);
    ::fchown(fd, 0, 0);
    ::fsync(fd);
    ::close(fd);
    if (n != static_cast<ssize_t>(plist_xml.size())) {
      ::unlink(tmp.c_str());
      return 1;
    }
    std::error_code ec;
    fs::rename(tmp, dst, ec);
    if (ec) {
      ::unlink(tmp.c_str());
      return 1;
    }
    return 0;
  }

  bool set_loginscreen_agent_enabled(bool enabled) {
    char executable[2048];
    uint32_t exec_size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &exec_size) != 0) {
      return loginscreen_agent_enabled();
    }
    std::error_code ec;
    const std::string canon_exec = fs::weakly_canonical(fs::path {executable}, ec).string();
    const std::string &exe = (!ec && !canon_exec.empty()) ? canon_exec : std::string {executable};
    const std::string cfg_dir = appdata().string();

    using AuthRef = struct AuthorizationOpaqueRef *;
    struct AuthItem {
      const char *name;
      std::size_t valueLength;
      void *value;
      std::uint32_t flags;
    };
    struct AuthRights {
      std::uint32_t count;
      AuthItem *items;
    };
    using CreateFn = OSStatus (*)(const AuthRights *, const AuthRights *, std::uint32_t, AuthRef *);
    using FreeFn = OSStatus (*)(AuthRef, std::uint32_t);
    using ExecFn = OSStatus (*)(AuthRef, const char *, std::uint32_t, char *const *, FILE **);

    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    if (!sec) {
      BOOST_LOG(warning) << "Unable to load Security.framework for administrator prompt"sv;
      return loginscreen_agent_enabled();
    }
    const auto auth_create = reinterpret_cast<CreateFn>(dlsym(sec, "AuthorizationCreate"));
    const auto auth_free = reinterpret_cast<FreeFn>(dlsym(sec, "AuthorizationFree"));
    const auto auth_exec = reinterpret_cast<ExecFn>(dlsym(sec, "AuthorizationExecuteWithPrivileges"));
    if (!auth_create || !auth_free || !auth_exec) {
      dlclose(sec);
      return loginscreen_agent_enabled();
    }

    AuthItem right {"system.privilege.admin", 0, nullptr, 0};
    AuthRights rights {1, &right};
    constexpr std::uint32_t kAuthFlags = (1u << 0) | (1u << 1) | (1u << 4);  // InteractionAllowed | ExtendRights | PreAuthorize
    AuthRef auth = nullptr;
    if (auth_create(&rights, nullptr, kAuthFlags, &auth) != errSecSuccess || !auth) {
      dlclose(sec);
      return loginscreen_agent_enabled();
    }

    std::string arg_install {install_loginscreen_agent_arg};
    std::string arg_remove {remove_loginscreen_agent_arg};
    std::vector<char *> helper_args;
    if (enabled) {
      helper_args = {
        const_cast<char *>(arg_install.c_str()),
        const_cast<char *>(cfg_dir.c_str()),
        const_cast<char *>(exe.c_str()),
        nullptr
      };
    } else {
      helper_args = {
        const_cast<char *>(arg_remove.c_str()),
        nullptr
      };
    }

    FILE *pipe_fp = nullptr;
    const OSStatus exec_status = auth_exec(auth, exe.c_str(), 0, helper_args.data(), &pipe_fp);
    if (pipe_fp) {
      char buf[128];
      while (std::fgets(buf, sizeof(buf), pipe_fp) != nullptr) {}
      std::fclose(pipe_fp);
    }
    if (exec_status == errSecSuccess) {
      for (int i = 0; i < 40 && loginscreen_agent_enabled() != enabled; ++i) {
        std::this_thread::sleep_for(25ms);
      }
    }
    auth_free(auth, 0);
    dlclose(sec);

    return loginscreen_agent_enabled();
  }

  bool set_opens_at_login(bool enabled) {
    if (@available(macOS 13.0, *)) {
      SMAppService *agent = login_agent();
      NSError *error = nil;
      if (enabled) {
        // launchd starts the agent right away, and it takes over from this copy.
        if (![agent registerAndReturnError:&error]) {
          BOOST_LOG(warning) << "Couldn't turn on Open at Login: "sv << error.localizedDescription.UTF8String;
        }

        // If the user turned Vibepollo off in System Settings, only they can turn it back on.
        if (agent.status == SMAppServiceStatusRequiresApproval) {
          BOOST_LOG(info) << "Opening Login Items so the user can allow Vibepollo in the background"sv;
          [SMAppService openSystemSettingsLoginItems];
        }
        return opens_at_login();
      }

      bool replace = is_login_agent();
      if (agent.status == SMAppServiceStatusEnabled && ![agent unregisterAndReturnError:&error]) {
        BOOST_LOG(warning) << "Couldn't turn off Open at Login: "sv << error.localizedDescription.UTF8String;
        return false;
      }
      if (replace) {
        launch_replacement();
      }
      return !opens_at_login();
    }

    BOOST_LOG(warning) << "Open at Login requires macOS 13 or later"sv;
    return false;
  }

  namespace {
    fs::path instance_lock_path() {
      return appdata() / "vibepollo.lock";
    }

    // Whether another process holds the instance lock, as the login agent does once it runs.
    bool instance_lock_held_elsewhere() {
      int fd = open(instance_lock_path().c_str(), O_RDONLY | O_CLOEXEC);
      if (fd < 0) {
        return false;
      }
      const bool held = flock(fd, LOCK_EX | LOCK_NB) != 0;
      close(fd);
      return held;
    }

    // Starts the agent unless it's already running, and waits for it to take over.
    bool start_login_agent(const std::string &service) {
      if (run({"/bin/launchctl", "kickstart", service}) != 0) {
        return false;
      }
      // kickstart succeeds even when launchd then fails to spawn the agent.
      const auto deadline = std::chrono::steady_clock::now() + 5s;
      while (!instance_lock_held_elsewhere()) {
        if (std::chrono::steady_clock::now() >= deadline) {
          return false;
        }
        std::this_thread::sleep_for(100ms);
      }
      return true;
    }
  }  // namespace

  bool defer_to_login_agent() {
    if (is_loginwindow_session() || is_login_agent() || !opens_at_login()) {
      return false;
    }

    auto service = "gui/"s + std::to_string(getuid()) + "/" + std::string {PROJECT_FQDN};
    if (!start_login_agent(service)) {
      // launchd only starts the agent for the build that registered it, so an update can leave it
      // unable to. Turning Open at Login off and on again registers it for this build.
      BOOST_LOG(warning) << "Couldn't start "sv << service << ", so running without it"sv;
      BOOST_LOG(warning) << "If Vibepollo was just updated, turn Open at Login off and on again"sv;
      return false;
    }
    BOOST_LOG(info) << "Open at Login is on, so leaving it to "sv << service << " to run Vibepollo"sv;
    return true;
  }

  bool acquire_instance_lock(std::chrono::milliseconds timeout) {
    std::error_code ec;
    fs::create_directories(appdata(), ec);
    auto path = instance_lock_path();

    // Held until the process exits. O_CLOEXEC keeps launched apps from holding it after that, and
    // restarting from the menu bar closes it before re-executing.
    int fd = open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) {
      BOOST_LOG(warning) << "Couldn't open "sv << path << ", so not checking for other copies of Vibepollo: "sv << strerror(errno);
      return true;
    }

    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
      // The login agent takes over from other copies, like the one that just turned Open at Login on.
      char pid[16] = {};
      if (is_login_agent() && pread(fd, pid, sizeof(pid) - 1, 0) > 0 && std::atoi(pid) > 0) {
        BOOST_LOG(info) << "Asking the copy of Vibepollo with PID "sv << pid << " to quit"sv;
        kill(std::atoi(pid), SIGTERM);
      }

      BOOST_LOG(info) << "Waiting for another copy of Vibepollo to quit"sv;
      auto deadline = std::chrono::steady_clock::now() + timeout;
      while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (std::chrono::steady_clock::now() >= deadline) {
          close(fd);
          return false;
        }
        std::this_thread::sleep_for(100ms);
      }
    }

    auto pid = std::to_string(getpid());
    if (ftruncate(fd, 0) != 0 || pwrite(fd, pid.data(), pid.size(), 0) < 0) {
      BOOST_LOG(warning) << "Couldn't record this process in "sv << path;
    }
    return true;
  }

  namespace {
    // A sleeping display drops out of the active list, and during a dark wake every display does.
    bool displays_awake() {
      uint32_t count = 0;
      return CGGetActiveDisplayList(0, nullptr, &count) == kCGErrorSuccess && count > 0 && !CGDisplayIsAsleep(CGMainDisplayID());
    }
  }  // namespace

  bool wake_displays(const std::chrono::milliseconds timeout) {
    if (displays_awake()) {
      return true;
    }

    // Declaring user activity finishes a dark wake and turns the displays on. The assertion
    // expires on its own after the display sleep delay.
    IOPMAssertionID activity = kIOPMNullAssertionID;
    if (IOPMAssertionDeclareUserActivity(CFSTR("Vibepollo is waking the displays for a stream"), kIOPMUserActiveLocal, &activity) != kIOReturnSuccess) {
      BOOST_LOG(warning) << "Couldn't wake the displays for capture"sv;
      return false;
    }

    // A Mac without a screen of its own (a headless Mac mini, a closed MacBook) has none to wait for.
    uint32_t online = 0;
    if (CGGetOnlineDisplayList(0, nullptr, &online) != kCGErrorSuccess || online == 0) {
      return false;
    }

    const auto start = std::chrono::steady_clock::now();
    while (!displays_awake()) {
      if (std::chrono::steady_clock::now() - start >= timeout) {
        BOOST_LOG(warning) << "Displays are still asleep after "sv << timeout.count() << " ms; capture may fail"sv;
        return false;
      }
      std::this_thread::sleep_for(50ms);
    }
    BOOST_LOG(info) << "Woke the displays for capture in "sv << std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count() << " ms"sv;
    return true;
  }

  namespace {
    struct sleep_watch_t {
      io_connect_t root_port = MACH_PORT_NULL;
      IONotificationPortRef port = nullptr;
      io_object_t notifier = IO_OBJECT_NULL;
      std::function<void()> handler;
    } sleep_watch;

    void system_power_changed(void *, io_service_t, natural_t message, void *argument) {
      switch (message) {
        case kIOMessageCanSystemSleep:
          // Idle sleep: streaming holds its own assertions against it, so just answer.
          IOAllowPowerChange(sleep_watch.root_port, reinterpret_cast<intptr_t>(argument));
          break;
        case kIOMessageSystemWillSleep:
          sleep_watch.handler();
          IOAllowPowerChange(sleep_watch.root_port, reinterpret_cast<intptr_t>(argument));
          break;
        default:
          break;
      }
    }
  }  // namespace

  void on_system_will_sleep(std::function<void()> handler) {
    static std::once_flag once;
    std::call_once(once, [&handler]() {
      sleep_watch.handler = std::move(handler);
      sleep_watch.root_port = IORegisterForSystemPower(nullptr, &sleep_watch.port, system_power_changed, &sleep_watch.notifier);
      if (sleep_watch.root_port == MACH_PORT_NULL) {
        BOOST_LOG(warning) << "Couldn't watch for sleep; streams will just stop when the Mac sleeps"sv;
        return;
      }
      IONotificationPortSetDispatchQueue(sleep_watch.port, dispatch_queue_create("dev.vibepollo.sleep", DISPATCH_QUEUE_SERIAL));
    });
  }

  namespace {
    struct lid_watch_t {
      IONotificationPortRef port = nullptr;
      io_object_t notifier = IO_OBJECT_NULL;
      bool closed = false;
      std::function<void()> closed_handler;
      std::function<void()> opened_handler;
    } lid_watch;

    void root_domain_message(void *, io_service_t, natural_t message, void *argument) {
      if (message != kIOPMMessageClamshellStateChange) {
        return;
      }
      // Also sent while the lid stays closed, when power or displays change: act on closing only.
      const bool closed = (reinterpret_cast<uintptr_t>(argument) & kClamshellStateBit) != 0;
      const bool just_closed = closed && !lid_watch.closed;
      const bool just_opened = !closed && lid_watch.closed;
      lid_watch.closed = closed;
      if (just_closed) {
        lid_watch.closed_handler();
      } else if (just_opened) {
        BOOST_LOG(info) << "The lid was opened"sv;
        lid_watch.opened_handler();
      }
    }
  }  // namespace

  bool lid_closed() {
    const io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (root == IO_OBJECT_NULL) {
      return false;
    }
    const CFTypeRef state = IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    const bool closed = state == kCFBooleanTrue;
    if (state != nullptr) {
      CFRelease(state);
    }
    return closed;
  }

  void watch_lid(std::function<void()> closed, std::function<void()> opened) {
    static std::once_flag once;
    std::call_once(once, [&closed, &opened]() {
      const io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
      if (root == IO_OBJECT_NULL) {
        return;
      }
      lid_watch.closed = lid_closed();
      lid_watch.closed_handler = std::move(closed);
      lid_watch.opened_handler = std::move(opened);
      lid_watch.port = IONotificationPortCreate(kIOMainPortDefault);
      IONotificationPortSetDispatchQueue(lid_watch.port, dispatch_queue_create("dev.vibepollo.lid", DISPATCH_QUEUE_SERIAL));
      if (IOServiceAddInterestNotification(lid_watch.port, root, kIOGeneralInterest, root_domain_message, nullptr, &lid_watch.notifier) != KERN_SUCCESS) {
        BOOST_LOG(warning) << "Couldn't watch the lid; closing it won't end streams"sv;
      }
      IOObjectRelease(root);
    });
  }

  std::unique_ptr<deinit_t> init() {
    if (is_loginwindow_session()) {
      ensure_appkit_session();
      dispatch_async(dispatch_get_main_queue(), ^{
        if (TISInputSourceRef ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()) {
          TISSelectInputSource(ascii);
          CFRelease(ascii);
        }
      });
      // Pre-login LoginWindow sessions have no interactive TCC approval dialogs; rely on the
      // system-level TCC entries already granted to the signed app bundle.
      screen_capture_allowed = true;
      return std::make_unique<deinit_t>();
    }

    // Remote mouse and keyboard input is posted as synthetic events, which macOS only delivers
    // for apps allowed under Privacy & Security > Accessibility. Streaming works without it.
    const bool can_post_events = CGPreflightPostEventAccess();
    if (!can_post_events) {
      BOOST_LOG(warning) << "No accessibility permission; remote mouse and keyboard input will be ignored"sv;
      BOOST_LOG(warning) << "Please allow it in 'System Settings' -> 'Privacy & Security'"sv;
    }

    // This will generate a warning about CGPreflightScreenCaptureAccess and
    // CGRequestScreenCaptureAccess being unavailable before macOS 10.15, but
    // we have a guard to prevent it from being called on those earlier systems.
    // Unfortunately the supported way to silence this warning, using @available,
    // produces linker errors for __isPlatformVersionAtLeast, so we have to use
    // a different method.
    // We also ignore "tautological-pointer-compare" because when compiling with
    // Xcode 12.2 and later, these functions are not weakly linked and will never
    // be null, and therefore generate this warning. Since we are weakly linking
    // when compiling with earlier Xcode versions, the check for null is
    // necessary, and so we ignore the warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {10, 15, 0})] &&
        // Double check that these weakly-linked symbols have been loaded:
        CGPreflightScreenCaptureAccess != nullptr && CGRequestScreenCaptureAccess != nullptr &&
        !CGPreflightScreenCaptureAccess()) {
      BOOST_LOG(error) << "No screen capture permission!"sv;
      BOOST_LOG(error) << "Please allow it in 'System Settings' -> 'Privacy & Security', then restart Vibepollo"sv;
      // Asking ScreenCaptureKit shows the system prompt and lists the app under Privacy & Security.
      // CGRequestScreenCaptureAccess() no longer does either on current macOS.
      // macOS shows one privacy prompt at a time, so Accessibility waits for the next launch,
      // which allowing screen recording needs anyway (macOS offers to quit and reopen).
      [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *, NSError *) {
      }];
      return nullptr;
    }
#pragma clang diagnostic pop
    if (!can_post_events) {
      CGRequestPostEventAccess();
    }
    // Record that we determined that we have the screen capture permission.
    screen_capture_allowed = true;
    return std::make_unique<deinit_t>();
  }

  fs::path appdata() {
    const char *homedir;
    if ((homedir = getenv("HOME")) == nullptr) {
      homedir = getpwuid(geteuid())->pw_dir;
    }

    return services::home_config_root(std::optional<fs::path> {fs::path {homedir}}, fs::path {homedir});
  }

  using ifaddr_t = util::safe_ptr<ifaddrs, freeifaddrs>;

  ifaddr_t get_ifaddrs() {
    ifaddrs *p {nullptr};

    getifaddrs(&p);

    return ifaddr_t {p};
  }

  std::string from_sockaddr(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
    }

    return std::string {data};
  }

  std::pair<std::uint16_t, std::string> from_sockaddr_ex(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    std::uint16_t port = 0;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
      port = ((sockaddr_in6 *) ip_addr)->sin6_port;
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
      port = ((sockaddr_in *) ip_addr)->sin_port;
    }

    return {port, std::string {data}};
  }

  std::string get_mac_address(const std::string_view &address) {
    auto ifaddrs = get_ifaddrs();

    for (auto pos = ifaddrs.get(); pos != nullptr; pos = pos->ifa_next) {
      if (pos->ifa_addr && address == from_sockaddr(pos->ifa_addr)) {
        BOOST_LOG(verbose) << "Looking for MAC of "sv << pos->ifa_name;

        struct ifaddrs *ifap, *ifaptr;
        unsigned char *ptr;
        std::string mac_address;

        if (getifaddrs(&ifap) == 0) {
          for (ifaptr = ifap; ifaptr != nullptr; ifaptr = (ifaptr)->ifa_next) {
            if (!strcmp((ifaptr)->ifa_name, pos->ifa_name) && (((ifaptr)->ifa_addr)->sa_family == AF_LINK)) {
              ptr = (unsigned char *) LLADDR((struct sockaddr_dl *) (ifaptr)->ifa_addr);
              char buff[100];

              snprintf(buff, sizeof(buff), "%02x:%02x:%02x:%02x:%02x:%02x", *ptr, *(ptr + 1), *(ptr + 2), *(ptr + 3), *(ptr + 4), *(ptr + 5));
              mac_address = buff;
              break;
            }
          }

          freeifaddrs(ifap);

          if (ifaptr != nullptr) {
            BOOST_LOG(verbose) << "Found MAC of "sv << pos->ifa_name << ": "sv << mac_address;
            return mac_address;
          }
        }
      }
    }

    BOOST_LOG(warning) << "Unable to find MAC address for "sv << address;
    return "00:00:00:00:00:00"s;
  }

  // TODO: return actual IP
  std::string get_local_ip_for_gateway() {
    return "";
  }

  bp::child run_command(bool elevated, bool interactive, const std::string &cmd, boost::filesystem::path &working_dir, const bp::environment &env, FILE *file, std::error_code &ec, bp::group *group) {
    (void) elevated;
    (void) interactive;
    ec.clear();

    std::vector<std::string> parts;
    try {
      parts = boost::program_options::split_unix(cmd);
    } catch (...) {
    }

    if (parts.empty()) {
      ec = std::make_error_code(std::errc::invalid_argument);
      return bp::child();
    }

    auto exe_path = v2::filesystem::path(parts.front());
    // Only PATH-search when there's no directory component (e.g., "foo" not "./foo" or "../foo")
    if (!exe_path.is_absolute() && exe_path.parent_path().empty()) {
      exe_path = v2::environment::find_executable(exe_path);
    }

    if (exe_path.empty()) {
      ec = std::make_error_code(std::errc::no_such_file_or_directory);
      return bp::child();
    }

    std::vector<std::string> args;
    if (parts.size() > 1) {
      args.assign(parts.begin() + 1, parts.end());
    }

    v2::process_stdio stdio {};
    stdio.in = nullptr;
    if (file) {
      stdio.out = file;
      stdio.err = file;
    } else {
      stdio.out = nullptr;
      stdio.err = nullptr;
    }

    auto env_init = env.to_process_environment();
    boost::asio::system_executor exec;

    try {
      if (group) {
        if (!working_dir.empty()) {
          auto start = v2::process_start_dir(v2::filesystem::path(working_dir.string()));
          auto proc = v2::process(exec, exe_path, args, start, stdio, env_init, bp::detail::posix_group_initer {group});
          return bp::child(std::move(proc));
        }
        auto proc = v2::process(exec, exe_path, args, stdio, env_init, bp::detail::posix_group_initer {group});
        return bp::child(std::move(proc));
      }

      if (!working_dir.empty()) {
        auto start = v2::process_start_dir(v2::filesystem::path(working_dir.string()));
        auto proc = v2::process(exec, exe_path, args, start, stdio, env_init);
        return bp::child(std::move(proc));
      }
      auto proc = v2::process(exec, exe_path, args, stdio, env_init);
      return bp::child(std::move(proc));
    } catch (const std::system_error &e) {
      ec = e.code();
      return bp::child();
    } catch (...) {
      ec = std::make_error_code(std::errc::invalid_argument);
      return bp::child();
    }
  }

  /**
   * @brief Open a url in the default web browser.
   * @param url The url to open.
   */
  void open_url(const std::string &url) {
    boost::filesystem::path working_dir;
    std::string cmd = R"(open ")" + url + R"(")";

    bp::environment _env = bp::this_process::env();
    std::error_code ec;
    auto child = run_command(false, false, cmd, working_dir, _env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Couldn't open url ["sv << url << "]: System: "sv << ec.message();
    } else {
      BOOST_LOG(info) << "Opened url ["sv << url << "]"sv;
      child.detach();
    }
  }

  void adjust_thread_priority(thread_priority_e priority) {
    qos_class_t mac_priority;

    switch (priority) {
      case thread_priority_e::low:
        mac_priority = QOS_CLASS_UTILITY;
        break;
      case thread_priority_e::normal:
        mac_priority = QOS_CLASS_DEFAULT;
        break;
      case thread_priority_e::high:
        mac_priority = QOS_CLASS_USER_INITIATED;
        break;
      case thread_priority_e::critical:
        mac_priority = QOS_CLASS_USER_INTERACTIVE;
        break;
      default:
        BOOST_LOG(error) << "Unknown thread priority: "sv << (int) priority;
        return;
    }

    // https://github.com/apple/darwin-libpthread/blob/main/include/sys/qos.h
    pthread_set_qos_class_self_np(mac_priority, 0);

    if (priority == thread_priority_e::critical) {
      mach_timebase_info_data_t tb {};
      if (mach_timebase_info(&tb) == KERN_SUCCESS && tb.numer > 0) {
        const auto ns_to_abs = [&](std::uint64_t ns) -> std::uint32_t {
          return static_cast<std::uint32_t>((ns * tb.denom) / tb.numer);
        };
        thread_time_constraint_policy_data_t policy {};
        policy.period = ns_to_abs(8'333'333);       // 120 Hz cadence (8.33 ms)
        policy.computation = ns_to_abs(5'000'000);  // 5.0 ms RT compute budget (prevents mid-frame demotion)
        policy.constraint = ns_to_abs(8'000'000);   // 8.0 ms deadline within one 120 Hz VSync
        policy.preemptible = TRUE;
        thread_policy_set(
          mach_thread_self(),
          THREAD_TIME_CONSTRAINT_POLICY,
          reinterpret_cast<thread_policy_t>(&policy),
          THREAD_TIME_CONSTRAINT_POLICY_COUNT
        );
      }
    }
  }

  void set_thread_name(std::string_view name) {
    std::string thread_name {name};
    pthread_setname_np(thread_name.c_str());
  }

  void enable_mouse_keys() {
    // Unimplemented
  }

  void streaming_will_start() {
    // Nothing to do
  }

  void streaming_will_stop() {
    // Nothing to do
  }

  void restart_on_exit() {
    char executable[2048];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) < 0) {
      BOOST_LOG(fatal) << "NSGetExecutablePath() failed: "sv << errno;
      return;
    }

    // ASIO doesn't use O_CLOEXEC, so we have to close all fds ourselves
    int openmax = (int) sysconf(_SC_OPEN_MAX);
    for (int fd = STDERR_FILENO + 1; fd < openmax; fd++) {
      close(fd);
    }

    // Re-exec ourselves with the same arguments
    if (execv(executable, lifetime::get_argv()) < 0) {
      BOOST_LOG(fatal) << "execv() failed: "sv << errno;
      return;
    }
  }

  void restart() {
    // Gracefully clean up and restart ourselves instead of exiting
    atexit(restart_on_exit);
    lifetime::exit_sunshine(0, true);
  }

  int set_env(const std::string &name, const std::string &value) {
    return services::process_environment().set(name, value);
  }

  int unset_env(const std::string &name) {
    return services::process_environment().unset(name);
  }

  bool request_process_group_exit(std::uintptr_t native_handle) {
    if (killpg((pid_t) native_handle, SIGTERM) == 0 || errno == ESRCH) {
      BOOST_LOG(debug) << "Successfully sent SIGTERM to process group: "sv << native_handle;
      return true;
    } else {
      BOOST_LOG(warning) << "Unable to send SIGTERM to process group ["sv << native_handle << "]: "sv << errno;
      return false;
    }
  }

  bool process_group_running(std::uintptr_t native_handle) {
    return waitpid(-((pid_t) native_handle), nullptr, WNOHANG) >= 0;
  }

  struct sockaddr_in to_sockaddr(boost::asio::ip::address_v4 address, uint16_t port) {
    struct sockaddr_in saddr_v4 = {};

    saddr_v4.sin_family = AF_INET;
    saddr_v4.sin_port = htons(port);

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v4.sin_addr, addr_bytes.data(), sizeof(saddr_v4.sin_addr));

    return saddr_v4;
  }

  struct sockaddr_in6 to_sockaddr(boost::asio::ip::address_v6 address, uint16_t port) {
    struct sockaddr_in6 saddr_v6 = {};

    saddr_v6.sin6_family = AF_INET6;
    saddr_v6.sin6_port = htons(port);
    saddr_v6.sin6_scope_id = address.scope_id();

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v6.sin6_addr, addr_bytes.data(), sizeof(saddr_v6.sin6_addr));

    return saddr_v6;
  }

  extern "C" {
    struct msghdr_x {
      void *msg_name;
      socklen_t msg_namelen;
      struct iovec *msg_iov;
      int msg_iovlen;
      void *msg_control;
      socklen_t msg_controllen;
      int msg_flags;
      size_t msg_datalen;
    };

    ssize_t sendmsg_x(int s, const struct msghdr_x *msgp, u_int cnt, int flags);
  }

  // On multi-homed Macs where wired `en0` (e.g. 192.168.1.209) and Wi-Fi `en1` (e.g. 192.168.1.214)
  // share the same IPv4 subnet on a wildcard `0.0.0.0` UDP socket, passing `ipi_ifindex = 0` in
  // `IP_PKTINFO` lets XNU's unscoped route lookup pick `en1` (when `en1` has a lower link index
  // than `en0`), transmitting 100% of 120fps RTP packets out of the Mac's Wi-Fi radio instead of
  // wired Ethernet! Resolve and pin the exact outbound `ifindex` matching `src_addr` (preferring `en0`).
  unsigned int resolve_ipv4_outbound_ifindex(in_addr_t src_addr) {
    if (src_addr == 0) {
      return 0;
    }
    struct cache_entry_t {
      in_addr_t addr {};
      unsigned int ifindex {};
    };
    static std::mutex cache_mutex;
    static std::chrono::steady_clock::time_point last_refresh {};
    static std::vector<cache_entry_t> entries;

    const auto now = std::chrono::steady_clock::now();
    std::lock_guard lock {cache_mutex};
    if (entries.empty() || (now - last_refresh) >= std::chrono::seconds(5)) {
      entries.clear();
      last_refresh = now;
      ifaddrs *ifaddr = nullptr;
      if (getifaddrs(&ifaddr) == 0 && ifaddr) {
        // Insert `en0` first if multiple interfaces ever alias.
        for (int pass = 0; pass < 2; ++pass) {
          for (auto *ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || !ifa->ifa_name || !(ifa->ifa_flags & IFF_UP) || ifa->ifa_addr->sa_family != AF_INET) {
              continue;
            }
            const bool is_en0 = (std::strcmp(ifa->ifa_name, "en0") == 0);
            if ((pass == 0) != is_en0) {
              continue;
            }
            const in_addr_t a = reinterpret_cast<const sockaddr_in *>(ifa->ifa_addr)->sin_addr.s_addr;
            const unsigned int idx = if_nametoindex(ifa->ifa_name);
            if (a != 0 && idx != 0) {
              entries.push_back({a, idx});
            }
          }
        }
        freeifaddrs(ifaddr);
      }
    }
    for (const auto &e : entries) {
      if (e.addr == src_addr) {
        return e.ifindex;
      }
    }
    return 0;
  }

  bool send_batch(batched_send_info_t &send_info) {
    if (send_info.block_count == 0) {
      return true;
    }

    auto sockfd = (int) send_info.native_socket;

    struct sockaddr_in taddr_v4 = {};
    struct sockaddr_in6 taddr_v6 = {};
    void *msg_name = nullptr;
    socklen_t msg_namelen = 0;
    if (send_info.target_address.is_v6()) {
      taddr_v6 = to_sockaddr(send_info.target_address.to_v6(), send_info.target_port);
      msg_name = &taddr_v6;
      msg_namelen = sizeof(taddr_v6);
    } else {
      taddr_v4 = to_sockaddr(send_info.target_address.to_v4(), send_info.target_port);
      msg_name = &taddr_v4;
      msg_namelen = sizeof(taddr_v4);
    }

    union {
      char buf[std::max(CMSG_SPACE(sizeof(struct in_pktinfo)), CMSG_SPACE(sizeof(struct in6_pktinfo)))];
      struct cmsghdr alignment;
    } cmbuf {};

    socklen_t cmbuflen = 0;
    {
      struct msghdr cmsg_template = {};
      cmsg_template.msg_control = cmbuf.buf;
      cmsg_template.msg_controllen = sizeof(cmbuf.buf);
      auto pktinfo_cm = CMSG_FIRSTHDR(&cmsg_template);
      if (send_info.source_address.is_v6()) {
        struct in6_pktinfo pktInfo {};
        struct sockaddr_in6 saddr_v6 = to_sockaddr(send_info.source_address.to_v6(), 0);
        pktInfo.ipi6_addr = saddr_v6.sin6_addr;
        pktInfo.ipi6_ifindex = 0;

        cmbuflen += CMSG_SPACE(sizeof(pktInfo));
        pktinfo_cm->cmsg_level = IPPROTO_IPV6;
        pktinfo_cm->cmsg_type = IPV6_PKTINFO;
        pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
        memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
      } else {
        struct in_pktinfo pktInfo {};
        struct sockaddr_in saddr_v4 = to_sockaddr(send_info.source_address.to_v4(), 0);
        pktInfo.ipi_spec_dst = saddr_v4.sin_addr;
        pktInfo.ipi_ifindex = resolve_ipv4_outbound_ifindex(saddr_v4.sin_addr.s_addr);

        cmbuflen += CMSG_SPACE(sizeof(pktInfo));
        pktinfo_cm->cmsg_level = IPPROTO_IP;
        pktinfo_cm->cmsg_type = IP_PKTINFO;
        pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
        memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
      }
    }

    constexpr size_t MAX_CHUNK = 64;
    std::array<struct msghdr_x, MAX_CHUNK> msgs {};
    std::array<struct iovec, MAX_CHUNK * 2> iovs {};

    size_t blocks_sent = 0;
    while (blocks_sent < send_info.block_count) {
      if (send_info.send_cancelled && send_info.send_cancelled()) {
        send_info.allow_fallback = (blocks_sent == 0);
        return false;
      }

      const size_t chunk = std::min(send_info.block_count - blocks_sent, MAX_CHUNK);
      size_t iov_idx = 0;
      for (size_t i = 0; i < chunk; ++i) {
        const size_t block_idx = send_info.block_offset + blocks_sent + i;
        auto &m = msgs[i];
        m = {};
        m.msg_name = msg_name;
        m.msg_namelen = msg_namelen;
        m.msg_iov = &iovs[iov_idx];
        m.msg_iovlen = send_info.headers ? 2 : 1;
        m.msg_control = cmbuf.buf;
        m.msg_controllen = cmbuflen;

        if (send_info.headers) {
          iovs[iov_idx].iov_base = (void *) &send_info.headers[block_idx * send_info.header_size];
          iovs[iov_idx].iov_len = send_info.header_size;
          ++iov_idx;
        }
        auto payload_desc = send_info.buffer_for_payload_offset(static_cast<ptrdiff_t>(block_idx * send_info.payload_size));
        iovs[iov_idx].iov_base = (void *) payload_desc.buffer;
        iovs[iov_idx].iov_len = send_info.payload_size;
        ++iov_idx;
      }

      const ssize_t sent = sendmsg_x(sockfd, msgs.data(), static_cast<u_int>(chunk), 0);
      if (sent < 0) {
        if (errno == EINTR) {
          continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
          if (send_info.send_cancelled && send_info.send_cancelled()) {
            send_info.allow_fallback = false;
            return false;
          }
          struct pollfd pfd {};
          pfd.fd = sockfd;
          pfd.events = POLLOUT;
          const int pr = poll(&pfd, 1, 10);
          if (pr < 0 && errno != EINTR) {
            BOOST_LOG(warning) << "poll() failed: "sv << errno;
            send_info.allow_fallback = false;
            return false;
          }
          continue;
        }
        if (blocks_sent == 0 && (errno == ENOSYS || errno == EINVAL || errno == EOPNOTSUPP)) {
          send_info.allow_fallback = true;
          return false;
        }
        BOOST_LOG(warning) << "sendmsg_x() failed: "sv << errno;
        send_info.allow_fallback = false;
        return false;
      }
      if (sent == 0) {
        send_info.allow_fallback = (blocks_sent == 0);
        return false;
      }

      blocks_sent += static_cast<size_t>(sent);
    }

    return true;
  }

  bool send(send_info_t &send_info) {
    auto sockfd = (int) send_info.native_socket;
    struct msghdr msg = {};

    // Convert the target address into a sockaddr
    struct sockaddr_in taddr_v4 = {};
    struct sockaddr_in6 taddr_v6 = {};
    if (send_info.target_address.is_v6()) {
      taddr_v6 = to_sockaddr(send_info.target_address.to_v6(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v6;
      msg.msg_namelen = sizeof(taddr_v6);
    } else {
      taddr_v4 = to_sockaddr(send_info.target_address.to_v4(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v4;
      msg.msg_namelen = sizeof(taddr_v4);
    }

    union {
      char buf[std::max(CMSG_SPACE(sizeof(struct in_pktinfo)), CMSG_SPACE(sizeof(struct in6_pktinfo)))];
      struct cmsghdr alignment;
    } cmbuf {};

    socklen_t cmbuflen = 0;

    msg.msg_control = cmbuf.buf;
    msg.msg_controllen = sizeof(cmbuf.buf);

    auto pktinfo_cm = CMSG_FIRSTHDR(&msg);
    if (send_info.source_address.is_v6()) {
      struct in6_pktinfo pktInfo {};

      struct sockaddr_in6 saddr_v6 = to_sockaddr(send_info.source_address.to_v6(), 0);
      pktInfo.ipi6_addr = saddr_v6.sin6_addr;
      pktInfo.ipi6_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IPV6;
      pktinfo_cm->cmsg_type = IPV6_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    } else {
      struct in_pktinfo pktInfo {};

      struct sockaddr_in saddr_v4 = to_sockaddr(send_info.source_address.to_v4(), 0);
      pktInfo.ipi_spec_dst = saddr_v4.sin_addr;
      pktInfo.ipi_ifindex = resolve_ipv4_outbound_ifindex(saddr_v4.sin_addr.s_addr);

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IP;
      pktinfo_cm->cmsg_type = IP_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    }

    struct iovec iovs[2] = {};
    int iovlen = 0;
    if (send_info.header) {
      iovs[iovlen].iov_base = (void *) send_info.header;
      iovs[iovlen].iov_len = send_info.header_size;
      iovlen++;
    }
    iovs[iovlen].iov_base = (void *) send_info.payload;
    iovs[iovlen].iov_len = send_info.payload_size;
    iovlen++;

    msg.msg_iov = iovs;
    msg.msg_iovlen = iovlen;

    msg.msg_controllen = cmbuflen;

    auto bytes_sent = sendmsg(sockfd, &msg, 0);

    // If there's no send buffer space, wait for some to be available
    while (bytes_sent < 0 && errno == EAGAIN) {
      struct pollfd pfd;

      pfd.fd = sockfd;
      pfd.events = POLLOUT;

      if (poll(&pfd, 1, -1) != 1) {
        BOOST_LOG(warning) << "poll() failed: "sv << errno;
        break;
      }

      // Try to send again
      bytes_sent = sendmsg(sockfd, &msg, 0);
    }

    if (bytes_sent < 0) {
      BOOST_LOG(warning) << "sendmsg() failed: "sv << errno;
      return false;
    }

    return true;
  }

  // We can't track QoS state separately for each destination on this OS,
  // so we keep a ref count to only disable QoS options when all clients
  // are disconnected.
  static std::atomic<int> qos_ref_count = 0;

  class qos_t: public deinit_t {
  public:
    qos_t(int sockfd, std::vector<std::tuple<int, int, int>> options):
        sockfd(sockfd),
        options(options) {
      qos_ref_count++;
    }

    virtual ~qos_t() {
      if (--qos_ref_count == 0) {
        for (const auto &tuple : options) {
          auto reset_val = std::get<2>(tuple);
          if (setsockopt(sockfd, std::get<0>(tuple), std::get<1>(tuple), &reset_val, sizeof(reset_val)) < 0) {
            BOOST_LOG(warning) << "Failed to reset option: "sv << errno;
          }
        }
      }
    }

  private:
    int sockfd;
    std::vector<std::tuple<int, int, int>> options;
  };

  /**
   * @brief Enables QoS on the given socket for traffic to the specified destination.
   * @param native_socket The native socket handle.
   * @param address The destination address for traffic sent on this socket.
   * @param port The destination port for traffic sent on this socket.
   * @param data_type The type of traffic sent on this socket.
   * @param dscp_tagging Specifies whether to enable DSCP tagging on outgoing traffic.
   */
  std::unique_ptr<deinit_t> enable_socket_qos(uintptr_t native_socket, boost::asio::ip::address &address, uint16_t port, qos_data_type_e data_type, bool dscp_tagging) {
    int sockfd = (int) native_socket;
    std::vector<std::tuple<int, int, int>> reset_options;

    // We can use SO_NET_SERVICE_TYPE to set link-layer prioritization without DSCP tagging
    int service_type = 0;
    switch (data_type) {
      case qos_data_type_e::video:
        service_type = NET_SERVICE_TYPE_VI;
        break;
      case qos_data_type_e::audio:
        service_type = NET_SERVICE_TYPE_VO;
        break;
      default:
        BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
        break;
    }

    if (service_type) {
      if (setsockopt(sockfd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service_type, sizeof(service_type)) == 0) {
        // Reset SO_NET_SERVICE_TYPE to best-effort when QoS is disabled
        reset_options.emplace_back(std::make_tuple(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_BE));
      } else {
        BOOST_LOG(error) << "Failed to set SO_NET_SERVICE_TYPE: "sv << errno;
      }
    }

    // Set DSCP (when requested) and L4S ECN `ECT(1)` (0x01, RFC 9331) on outgoing video UDP
    // packets so Apple/L4S-capable Wi-Fi APs and clients apply low-latency AQM without drops.
    const int ecn_bits = (data_type == qos_data_type_e::video) ? 0x01 : 0x00;
    int dscp = 0;
    if (dscp_tagging) {
      // The specific DSCP values here are chosen to be consistent with Windows,
      // except that we use CS6 instead of CS7 for audio traffic.
      switch (data_type) {
        case qos_data_type_e::video:
          dscp = 40;
          break;
        case qos_data_type_e::audio:
          dscp = 48;
          break;
        default:
          BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
          break;
      }
    }

    const int tos = (dscp << 2) | ecn_bits;
    if (tos != 0) {
      const int level = address.is_v6() ? IPPROTO_IPV6 : IPPROTO_IP;
      const int option = address.is_v6() ? IPV6_TCLASS : IP_TOS;
      if (setsockopt(sockfd, level, option, &tos, sizeof(tos)) == 0) {
        reset_options.emplace_back(std::make_tuple(level, option, 0));
      } else {
        BOOST_LOG(error) << "Failed to set TOS/TCLASS: "sv << errno;
      }
    }

    return std::make_unique<qos_t>(sockfd, reset_options);
  }

  std::string get_host_name() {
    services::function_host_name_provider_t provider {[]() -> std::optional<std::string> {
      try {
        return boost::asio::ip::host_name();
      } catch (boost::system::system_error &err) {
        BOOST_LOG(error) << "Failed to get hostname: "sv << err.what();
        return std::nullopt;
      }
    }};
    return services::host_name_or(provider);
  }

  class macos_high_precision_timer: public high_precision_timer {
  public:
    macos_high_precision_timer() {
      mach_timebase_info(&tb_);
    }

    void sleep_for(const std::chrono::nanoseconds &duration) override {
      if (duration <= 0ns) {
        return;
      }
      if (tb_.numer == 0) {
        std::this_thread::sleep_for(duration);
        return;
      }
      const auto due = std::chrono::steady_clock::now() + duration;
      constexpr auto spin_margin = 25us;
      if (duration > spin_margin) {
        const auto sleep_ns = static_cast<std::uint64_t>((duration - spin_margin).count());
        const std::uint64_t deadline = mach_absolute_time() + (sleep_ns * tb_.denom) / tb_.numer;
        mach_wait_until(deadline);
      }
      while (std::chrono::steady_clock::now() < due) {
#if defined(__aarch64__) || defined(__arm64__)
        asm volatile("yield");
#else
        std::this_thread::yield();
#endif
      }
    }

    operator bool() override {
      return true;
    }

  private:
    mach_timebase_info_data_t tb_ {};
  };

  std::unique_ptr<high_precision_timer> create_high_precision_timer() {
    return std::make_unique<macos_high_precision_timer>();
  }

  std::string
    get_clipboard() {
    // Placeholder
    return "";
  }

  bool
    set_clipboard(const std::string &content) {
    // Placeholder
    return false;
  }

  std::string resolve_render_device() {
    return {};
  }
}  // namespace platf

@interface VibepolloPenHoverView: NSView
@property (nonatomic, assign) int distanceStep;
@property (nonatomic, assign) BOOL eraserMode;
@end

@implementation VibepolloPenHoverView
- (BOOL)isOpaque {
  return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
  (void) dirtyRect;
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (!ctx) {
    return;
  }
  CGContextClearRect(ctx, self.bounds);
  const CGFloat cx = NSMidX(self.bounds);
  const CGFloat cy = NSMidY(self.bounds);

  if (self.eraserMode) {
    // Windows-style hollow circular eraser tip with high-contrast dual ring.
    const CGFloat r = 5.8;
    CGContextSetRGBStrokeColor(ctx, 0.08, 0.08, 0.10, 0.88);
    CGContextSetLineWidth(ctx, 2.6);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2.0, r * 2.0));

    CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 0.96);
    CGContextSetLineWidth(ctx, 1.4);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2.0, r * 2.0));
    return;
  }

  // Subtle distance-reactive outer hover ring (tightens toward the tip as Pencil approaches glass).
  const CGFloat norm = std::clamp<CGFloat>(self.distanceStep / 8.0, 0.0, 1.0);
  if (self.distanceStep > 0) {
    const CGFloat haloR = 4.6 + norm * 3.6;
    const CGFloat haloAlpha = 0.58 - norm * 0.22;
    CGContextSetRGBStrokeColor(ctx, 0.06, 0.06, 0.08, haloAlpha * 0.55);
    CGContextSetLineWidth(ctx, 1.8);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - haloR, cy - haloR, haloR * 2.0, haloR * 2.0));

    CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, haloAlpha);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - haloR, cy - haloR, haloR * 2.0, haloR * 2.0));
  }

  // Windows 11-style crisp precision stylus dot: high-contrast dark border + bright white core,
  // clearly distinct from the macOS mouse arrow and readable on both dark and light surfaces.
  const CGFloat outerR = 3.1;
  CGContextSetRGBFillColor(ctx, 0.07, 0.07, 0.09, 0.94);
  CGContextFillEllipseInRect(ctx, CGRectMake(cx - outerR, cy - outerR, outerR * 2.0, outerR * 2.0));

  const CGFloat innerR = 1.95;
  CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.99);
  CGContextFillEllipseInRect(ctx, CGRectMake(cx - innerR, cy - innerR, innerR * 2.0, innerR * 2.0));
}
@end

namespace {
  struct pen_hover_overlay_state_t {
    std::mutex mutex;
    bool visible = false;
    double cg_x = 0.0;
    double cg_y = 0.0;
    int distance_step = 0;
    bool eraser = false;
    bool dispatch_pending = false;
  };

  pen_hover_overlay_state_t &pen_hover_state() {
    static pen_hover_overlay_state_t s;
    return s;
  }

  void apply_pen_hover_on_main() {
    static NSWindow *sWindow = nil;
    static VibepolloPenHoverView *sView = nil;
    constexpr CGFloat kWinSize = 28.0;

    bool visible = false;
    double cg_x = 0.0;
    double cg_y = 0.0;
    int distance_step = 0;
    bool eraser = false;
    {
      auto &st = pen_hover_state();
      std::lock_guard lock(st.mutex);
      st.dispatch_pending = false;
      visible = st.visible;
      cg_x = st.cg_x;
      cg_y = st.cg_y;
      distance_step = st.distance_step;
      eraser = st.eraser;
    }

    if (!visible) {
      if (sWindow != nil && sWindow.alphaValue > 0.0) {
        [sWindow setAlphaValue:0.0];
      }
      return;
    }

    platf::ensure_appkit_session();
    if (sWindow == nil) {
      NSRect rect = NSMakeRect(0, 0, kWinSize, kWinSize);
      sWindow = [[NSWindow alloc] initWithContentRect:rect
                                            styleMask:NSWindowStyleMaskBorderless
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
      [sWindow setReleasedWhenClosed:NO];
      [sWindow setOpaque:NO];
      [sWindow setBackgroundColor:NSColor.clearColor];
      [sWindow setHasShadow:NO];
      [sWindow setIgnoresMouseEvents:YES];
      [sWindow setHidesOnDeactivate:NO];
      [sWindow setCanHide:NO];
      [sWindow setExcludedFromWindowsMenu:YES];
      [sWindow setRestorable:NO];
      [sWindow setTabbingMode:NSWindowTabbingModeDisallowed];
      [sWindow setSharingType:NSWindowSharingReadOnly];
      [sWindow setAnimationBehavior:NSWindowAnimationBehaviorNone];
      [sWindow setLevel:NSScreenSaverWindowLevel];
      [sWindow setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                      NSWindowCollectionBehaviorFullScreenAuxiliary |
                                      NSWindowCollectionBehaviorStationary |
                                      NSWindowCollectionBehaviorIgnoresCycle)];
      sView = [[VibepolloPenHoverView alloc] initWithFrame:rect];
      sView.distanceStep = -1;
      [sWindow setContentView:sView];
      [sWindow setAlphaValue:1.0];
      [sWindow orderFrontRegardless];
    }

    const CGFloat primaryH = CGDisplayBounds(CGMainDisplayID()).size.height;
    const NSPoint origin = NSMakePoint(cg_x - kWinSize * 0.5, (primaryH - cg_y) - kWinSize * 0.5);
    if (!NSEqualPoints(sWindow.frame.origin, origin)) {
      [sWindow setFrameOrigin:origin];
    }

    const BOOL wantEraser = eraser ? YES : NO;
    if (sView.distanceStep != distance_step || sView.eraserMode != wantEraser) {
      sView.distanceStep = distance_step;
      sView.eraserMode = wantEraser;
      [sView setNeedsDisplay:YES];
    }
    if (sWindow.alphaValue < 1.0) {
      [sWindow setAlphaValue:1.0];
    }
    if (!sWindow.visible) {
      [sWindow orderFrontRegardless];
    }
  }

  void schedule_pen_hover_apply() {
    if (NSThread.isMainThread) {
      apply_pen_hover_on_main();
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      @autoreleasepool {
        apply_pen_hover_on_main();
      }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
  }
}  // namespace

extern "C" void macos_pen_hover_cursor_show(double cg_x, double cg_y, float distance_norm, bool eraser) {
  const int step = distance_norm <= 0.0005f ? 0 : std::clamp<int>(static_cast<int>(std::lround(distance_norm * 8.0f)), 1, 8);
  bool need_schedule = false;
  {
    auto &st = pen_hover_state();
    std::lock_guard lock(st.mutex);
    st.visible = true;
    st.cg_x = cg_x;
    st.cg_y = cg_y;
    st.distance_step = step;
    st.eraser = eraser;
    if (!st.dispatch_pending) {
      st.dispatch_pending = true;
      need_schedule = true;
    }
  }
  if (need_schedule) {
    schedule_pen_hover_apply();
  }
}

extern "C" void macos_pen_hover_cursor_hide(void) {
  bool need_schedule = false;
  {
    auto &st = pen_hover_state();
    std::lock_guard lock(st.mutex);
    if (!st.visible && !st.dispatch_pending) {
      return;
    }
    st.visible = false;
    if (!st.dispatch_pending) {
      st.dispatch_pending = true;
      need_schedule = true;
    }
  }
  if (need_schedule) {
    schedule_pen_hover_apply();
  }
}

namespace dyn {
  void *handle(const std::vector<const char *> &libs) {
    void *handle;

    for (auto lib : libs) {
      handle = dlopen(lib, RTLD_LAZY | RTLD_LOCAL);
      if (handle) {
        return handle;
      }
    }

    std::stringstream ss;
    ss << "Couldn't find any of the following libraries: ["sv << libs.front();
    std::for_each(std::begin(libs) + 1, std::end(libs), [&](auto lib) {
      ss << ", "sv << lib;
    });

    ss << ']';

    BOOST_LOG(error) << ss.str();

    return nullptr;
  }

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict) {
    int err = 0;
    for (auto &func : funcs) {
      TUPLE_2D_REF(fn, name, func);

      *fn = (void (*)()) dlsym(handle, name);

      if (!*fn && strict) {
        BOOST_LOG(error) << "Couldn't find function: "sv << name;

        err = -1;
      }
    }

    return err;
  }
}  // namespace dyn
