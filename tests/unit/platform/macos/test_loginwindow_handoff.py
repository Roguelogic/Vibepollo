"""Compile and verify macOS LoginWindow <-> Aqua LaunchAgent & port handoff helpers."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", default="clang++")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[4]
    misc_source = (root / "src/platform/macos/misc.mm").read_text()

    start_marker = '    constexpr std::string_view loginscreen_label = PROJECT_FQDN ".loginscreen";'
    end_marker = "  bool is_loginwindow_session() {"
    start_idx = misc_source.find(start_marker)
    end_idx = misc_source.find(end_marker, start_idx)
    assert start_idx != -1 and end_idx != -1, "Could not locate LoginWindow helpers in misc.mm"

    extracted = misc_source[start_idx:end_idx]
    ns_close = extracted.rfind("  }  // namespace")
    assert ns_close != -1, "Could not locate anonymous namespace end in misc.mm"
    extracted = extracted[:ns_close]

    harness = f"""
#include <arpa/inet.h>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <netinet/in.h>
#include <poll.h>
#include <string>
#include <string_view>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define PROJECT_FQDN "io.github.Nonary.vibepollo"
namespace fs = std::filesystem;

namespace test_macos_handoff {{
{extracted}
}}  // namespace test_macos_handoff

int main(int argc, char *argv[]) {{
  using namespace test_macos_handoff;

  static_assert(loginscreen_plist_path == "/Library/LaunchAgents/io.github.Nonary.vibepollo.loginscreen.plist");
  static_assert(loginwindow_runtime_root == "/Library/Application Support/Vibepollo/loginwindow-runtime");
  static_assert(loginwindow_handoff_lock_path == "/Library/Application Support/Vibepollo/loginwindow.lock");
  (void) &write_root_plist_atomic;

  if (argc > 1 && std::string_view {{argv[1]}} == "--dump-plist") {{
    std::cout << build_loginscreen_agent_plist_xml("/Users/alice & bob/.config/vibepollo", "/Applications/Vibepollo.app/Contents/MacOS/Vibepollo");
    return 0;
  }}

  // 1. In Aqua (non-root), VIBEPOLLO_LOGINWINDOW=1 must NOT mark the process as LoginWindow.
  if (geteuid() != 0) {{
    ::setenv("VIBEPOLLO_LOGINWINDOW", "1", 1);
    ::unsetenv("VIBEPOLLO_FORCE_LOGINWINDOW");
    assert(!detect_loginwindow_session());

    ::setenv("VIBEPOLLO_FORCE_LOGINWINDOW", "1", 1);
    assert(detect_loginwindow_session());
    ::unsetenv("VIBEPOLLO_FORCE_LOGINWINDOW");
  }}

  // 2. Multi-user owner check + 0600 credential file copy helper.
  if (geteuid() != 0) {{
    const fs::path temp_dir = fs::temp_directory_path() / ("vibepollo-owner-test-" + std::to_string(::getpid()));
    fs::create_directories(temp_dir);
    const fs::path src_file = temp_dir / "sunshine_state.json";
    const fs::path dst_file = temp_dir / "copied" / "sunshine_state.json";
    {{
      std::ofstream out(src_file);
      out << "{{\\"root\\":{{}}}}";
    }}
    assert(copy_file_mode_0600(src_file, dst_file));
    struct stat dst_st {{}};
    assert(::stat(dst_file.c_str(), &dst_st) == 0);
    assert((dst_st.st_mode & 0777) == 0600);

    ::setenv("XPC_SERVICE_NAME", "io.github.Nonary.vibepollo.loginscreen", 1);
    ::setenv("VIBEPOLLO_OWNER_CONFIG_DIR", temp_dir.c_str(), 1);
    assert(is_loginscreen_launch_agent());
    assert(!is_smappservice_launch_agent());
    assert(!is_non_owner_loginscreen_user());
    fs::remove_all(temp_dir);

    ::setenv("XPC_SERVICE_NAME", "io.github.Nonary.vibepollo", 1);
    assert(is_smappservice_launch_agent());
    assert(!is_loginscreen_launch_agent());
  }}

  // 3. Loopback TCP listener probe detects active listener and clears immediately upon close().
  const int srv = ::socket(AF_INET, SOCK_STREAM, 0);
  assert(srv >= 0);
  int one = 1;
  (void) ::setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in bind_addr {{}};
  bind_addr.sin_family = AF_INET;
  bind_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  bind_addr.sin_port = 0;
  assert(::bind(srv, reinterpret_cast<const sockaddr *>(&bind_addr), sizeof(bind_addr)) == 0);
  assert(::listen(srv, 4) == 0);

  socklen_t addr_len = sizeof(bind_addr);
  assert(::getsockname(srv, reinterpret_cast<sockaddr *>(&bind_addr), &addr_len) == 0);
  const std::uint16_t bound_port = ntohs(bind_addr.sin_port);
  assert(bound_port != 0);
  assert(tcp_loopback_listener_active(bound_port));

  ::close(srv);
  assert(!tcp_loopback_listener_active(bound_port));
  return 0;
}}
"""

    with tempfile.TemporaryDirectory(prefix="macos-loginwindow-handoff-") as tmp:
        src = Path(tmp) / "handoff_test.cpp"
        bin_path = Path(tmp) / "handoff_test"
        src.write_text(harness)
        subprocess.run(
            [args.compiler, "-std=c++23", "-Wall", "-Wextra", "-Werror", str(src), "-o", str(bin_path)],
            check=True,
        )
        subprocess.run([str(bin_path)], check=True)
        plist_bytes = subprocess.check_output([str(bin_path), "--dump-plist"])
        parsed = plistlib.loads(plist_bytes)
        assert parsed["Label"] == "io.github.Nonary.vibepollo.loginscreen"
        assert parsed["AssociatedBundleIdentifiers"] == "io.github.Nonary.vibepollo"
        assert parsed["LimitLoadToSessionType"] == ["LoginWindow", "Aqua"]
        assert parsed["RunAtLoad"] is True
        assert parsed["KeepAlive"] == {"SuccessfulExit": False}
        assert parsed["ProcessType"] == "Interactive"
        assert parsed["EnvironmentVariables"]["VIBEPOLLO_LOGINWINDOW"] == "1"
        assert parsed["EnvironmentVariables"]["VIBEPOLLO_OWNER_CONFIG_DIR"] == "/Users/alice & bob/.config/vibepollo"
        print("PASS: unified LoginWindow+Aqua plist, multi-user guard, and TCP port handoff verified")


if __name__ == "__main__":
    main()
