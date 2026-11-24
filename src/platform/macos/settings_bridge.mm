/**
 * @file src/platform/macos/settings_bridge.mm
 * @brief Objective-C++ implementation bridging Vibepollo's C++ host core to SwiftUI.
 */
#import "settings_bridge.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include <algorithm>
#include <filesystem>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>

#include <boost/asio/ip/host_name.hpp>
#include <nlohmann/json.hpp>

#include "misc.h"
#include "virtual_display.h"
#include "src/config.h"
#include "src/config_steam.h"
#include "src/confighttp.h"
#include "src/crypto.h"
#include "src/entry_handler.h"
#include "src/file_handler.h"
#include "src/host_stats.h"
#include "src/httpcommon.h"
#include "src/logging.h"
#include "src/managed_app_focus.h"
#include "src/nvhttp.h"
#include "src/platform/common.h"
#include "src/process.h"
#include "src/remote_monitor_profile_policy.h"
#include "src/remote_session.h"
#include "src/rtsp.h"
#include "src/session_history.h"
#include "src/steam_artwork.h"
#include "src/steam_integration.h"
#include "src/steam_sync_policy.h"
#include "src/stream.h"
#include "src/system_tray.h"
#include "src/update.h"
#include "src/uuid.h"

extern "C" void vibepollo_macos_open_native_ui(const char *route);

namespace {

  NSString *to_nsstring(std::string_view sv) {
    if (sv.empty()) {
      return @"";
    }
    NSString *str = [[NSString alloc] initWithBytes:sv.data()
                                             length:sv.size()
                                           encoding:NSUTF8StringEncoding];
    return str ?: @"";
  }

  std::string virtual_display_mode_string(config::video_t::virtual_display_mode_e mode) {
    switch (mode) {
      case config::video_t::virtual_display_mode_e::disabled:
        return "disabled";
      case config::video_t::virtual_display_mode_e::shared:
        return "shared";
      case config::video_t::virtual_display_mode_e::per_client:
      default:
        return "per_client";
    }
  }

  std::string virtual_display_layout_string(config::video_t::virtual_display_layout_e layout) {
    switch (layout) {
      case config::video_t::virtual_display_layout_e::exclusive:
        return "exclusive";
      case config::video_t::virtual_display_layout_e::extended_primary:
        return "extended_primary";
      case config::video_t::virtual_display_layout_e::extended_isolated:
        return "extended_isolated";
      case config::video_t::virtual_display_layout_e::extended_primary_isolated:
        return "extended_primary_isolated";
      case config::video_t::virtual_display_layout_e::extended:
      default:
        return "extended";
    }
  }

  std::string hdr_request_override_string(config::video_t::dd_t::hdr_request_override_e mode) {
    switch (mode) {
      case config::video_t::dd_t::hdr_request_override_e::force_on:
        return "force_on";
      case config::video_t::dd_t::hdr_request_override_e::force_off:
        return "force_off";
      case config::video_t::dd_t::hdr_request_override_e::automatic:
      default:
        return "auto";
    }
  }

  std::string vt_coder_string(int coder) {
    switch (coder) {
      case 1:
        return "cabac";
      case 2:
        return "cavlc";
      default:
        return "auto";
    }
  }

  bool json_bool_or(const nlohmann::json &obj, const char *key, bool fallback) {
    if (!obj.contains(key)) {
      return fallback;
    }
    const auto &v = obj[key];
    if (v.is_boolean()) {
      return v.get<bool>();
    }
    if (v.is_string()) {
      const auto s = v.get<std::string>();
      return s == "true" || s == "1" || s == "enabled" || s == "yes" || s == "on";
    }
    if (v.is_number_integer()) {
      return v.get<int>() != 0;
    }
    return fallback;
  }

  bool is_screen_capture_allowed() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
    if (CGPreflightScreenCaptureAccess != nullptr) {
      return CGPreflightScreenCaptureAccess();
    }
#pragma clang diagnostic pop
    return true;
  }

  bool is_accessibility_allowed() {
    return CGPreflightPostEventAccess();
  }

  bool is_system_app_entry(const nlohmann::json &entry) {
    if (!entry.is_object()) {
      return false;
    }
    const std::string uuid = entry.value("uuid", "");
    if (remote_session::marked_monitor_profile(entry)) {
      return true;
    }
    for (const auto ctrl : {remote_session::control_e::monitor, remote_session::control_e::input}) {
      if (uuid == remote_session::synthetic(ctrl).uuid) {
        return true;
      }
    }
    if (entry.value("name", "") == "Desktop" && entry.value("cmd", "").empty()) {
      return true;
    }
    return false;
  }

}  // namespace

extern "C" void vibepollo_open_macos_native_ui(const char *route) {
  vibepollo_macos_open_native_ui(route);
}

extern "C" void vibepollo_register_macos_native_ui(void) {
  set_native_ui_launcher([](std::string_view route) -> bool {
    if (platf::is_loginwindow_session()) {
      return false;
    }
    const std::string route_copy(route);
    vibepollo_macos_open_native_ui(route_copy.empty() ? nullptr : route_copy.c_str());
    return true;
  });
}

@implementation VibepolloHostBridge

+ (instancetype)shared {
  static VibepolloHostBridge *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[VibepolloHostBridge alloc] init];
  });
  return instance;
}

- (BOOL)isLoginWindowSession {
  return platf::is_loginwindow_session() ? YES : NO;
}

- (NSString *)appVersion {
  return to_nsstring(PROJECT_VERSION);
}

- (NSString *)defaultHostName {
  boost::system::error_code ec;
  const std::string hn = boost::asio::ip::host_name(ec);
  return to_nsstring(ec ? "Mac" : hn);
}

- (NSString *)webConsoleURL {
  return to_nsstring(confighttp::get_web_ui_url());
}

- (void)openWebConsoleInBrowser {
  platf::open_url(confighttp::get_web_ui_url());
}

- (NSString *)fetchDashboardSnapshotJSON {
  nlohmann::json out;
  out["version"] = PROJECT_VERSION;

  boost::system::error_code ec;
  const std::string fallback_host = boost::asio::ip::host_name(ec);
  {
    auto read_gate = config::acquire_apply_read_gate();
    out["hostName"] = !config::nvhttp.sunshine_name.empty()
                        ? config::nvhttp.sunshine_name
                        : (ec ? std::string("Mac") : fallback_host);
    out["locale"] = config::sunshine.locale;
    out["virtualDisplayMode"] = virtual_display_mode_string(config::video.virtual_display_mode);
  }

  const auto all_clients = nvhttp::get_all_clients();
  out["pairedCount"] = all_clients.is_array() ? static_cast<int>(all_clients.size()) : 0;

  const bool app_running = proc::proc.current_app_id() > 0;
  out["appRunning"] = app_running;
  out["runningAppName"] = app_running ? proc::proc.get_last_run_app_name() : "";

  nlohmann::json sessions_json = nlohmann::json::array();
  for (const auto &s : stream::get_all_session_info()) {
    nlohmann::json item;
    item["uuid"] = s.uuid;
    item["deviceName"] = s.device_name.empty() ? "Client" : s.device_name;
    item["width"] = s.width;
    item["height"] = s.height;
    item["fps"] = s.fps;
    item["bitrateKbps"] = s.encoder_bitrate_kbps;
    item["codec"] = std::string(stream::video_format_name(s.video_format));
    item["hdr"] = s.hdr;
    item["bitDepth"] = s.dynamic_range != 0 ? 10 : 8;
    item["yuv444"] = s.yuv444;
    item["directUsb"] = s.direct_usb;
    item["encodeLatencyMs"] = s.encode_latency_ms;
    item["framesSent"] = s.frames_sent;
    item["losses"] = s.client_reported_losses;
    item["uptimeSeconds"] = s.uptime_seconds;
    sessions_json.push_back(std::move(item));
  }
  out["sessions"] = std::move(sessions_json);

  const auto stats = host_stats::latest_for_consumer();
  const auto &info = host_stats::info();
  nlohmann::json hs;
  hs["cpuPercent"] = stats.cpu_percent;
  hs["gpuPercent"] = stats.gpu_percent;
  hs["ramUsedGB"] = stats.ram_used_bytes > 0
                      ? static_cast<double>(stats.ram_used_bytes) / (1024.0 * 1024.0 * 1024.0)
                      : -1.0;
  hs["ramTotalGB"] = info.ram_total_bytes > 0
                       ? static_cast<double>(info.ram_total_bytes) / (1024.0 * 1024.0 * 1024.0)
                       : -1.0;
  hs["cpuModel"] = info.cpu_model;
  hs["gpuModel"] = info.gpu_model;
  out["hostStats"] = std::move(hs);
  out["screenCaptureAllowed"] = is_screen_capture_allowed();
  out["accessibilityAllowed"] = is_accessibility_allowed();
  out["deferredReloadPending"] = config::has_deferred_reload();

  const auto upd = update::get_status_snapshot();
  const bool upd_available =
    !upd.available_release.version.empty() &&
    (upd.phase == update::phase_e::available ||
     upd.phase == update::phase_e::downloading ||
     upd.phase == update::phase_e::verifying ||
     upd.phase == update::phase_e::downloaded ||
     upd.phase == update::phase_e::installing ||
     upd.phase == update::phase_e::restarting);
  out["updateAvailable"] = upd_available;
  out["availableUpdateVersion"] = upd_available ? upd.available_release.version : "";

  return to_nsstring(out.dump());
}

- (void)openScreenCapturePrivacySettings {
  NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"];
  if (url != nil) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

- (void)openAccessibilityPrivacySettings {
  CGRequestPostEventAccess();
  NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
  if (url != nil) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

- (BOOL)pairWithPIN:(NSString *)pin deviceName:(NSString *)deviceName {
  return nvhttp::pin(pin.UTF8String ?: "", deviceName.UTF8String ?: "") ? YES : NO;
}

- (NSString *)fetchClientsJSON {
  const auto clients = nvhttp::get_all_clients();
  return to_nsstring(clients.is_array() ? clients.dump() : "[]");
}

- (BOOL)setClientEnabled:(NSString *)uuid enabled:(BOOL)enabled {
  return nvhttp::set_client_enabled(uuid.UTF8String ?: "", enabled == YES) ? YES : NO;
}

- (BOOL)disconnectClient:(NSString *)uuid {
  return nvhttp::disconnect_client(uuid.UTF8String ?: "") ? YES : NO;
}

- (BOOL)unpairClient:(NSString *)uuid {
  return nvhttp::unpair_client(uuid.UTF8String ?: "") ? YES : NO;
}

- (BOOL)updateClientWithJSON:(NSString *)payloadJSON {
  try {
    const auto input = nlohmann::json::parse(payloadJSON.UTF8String ?: "{}");
    const std::string uuid = input.value("uuid", "");
    if (uuid.empty()) {
      return NO;
    }

    const std::string name = input.value("name", "Client");
    const std::string display_mode = input.value("display_mode", "");
    const std::string output_name_override = input.value("output_name_override", "");
    const bool enable_legacy_ordering = input.value("enable_legacy_ordering", true);
    const bool allow_client_commands = input.value("allow_client_commands", true);
    const bool always_use_virtual_display = input.value("always_use_virtual_display", false);
    const bool prefer_10bit_sdr = input.value("prefer_10bit_sdr", false);
    const std::string virtual_display_mode = input.value("virtual_display_mode", "");
    const std::string virtual_display_layout = input.value("virtual_display_layout", "");

    const auto do_cmds = nvhttp::extract_command_entries(input, "do");
    const auto undo_cmds = nvhttp::extract_command_entries(input, "undo");
    const auto perm = static_cast<crypto::PERM>(
      input.value("perm", static_cast<uint32_t>(crypto::PERM::_default)) &
      static_cast<uint32_t>(crypto::PERM::_all)
    );

    std::unordered_map<std::string, std::string> overrides;
    const bool has_overrides = input.contains("config_overrides") && input["config_overrides"].is_object();
    if (has_overrides) {
      for (const auto &it : input["config_overrides"].items()) {
        if (!it.key().empty() && !it.value().is_null()) {
          overrides[it.key()] = it.value().is_string() ? it.value().get<std::string>() : it.value().dump();
        }
      }
    }

    bool ok = nvhttp::update_device_info(
      uuid,
      name,
      display_mode,
      output_name_override,
      do_cmds,
      undo_cmds,
      perm,
      enable_legacy_ordering,
      allow_client_commands,
      always_use_virtual_display,
      virtual_display_mode,
      virtual_display_layout,
      prefer_10bit_sdr,
      has_overrides ? std::make_optional(std::move(overrides)) : std::nullopt
    );

    if (input.contains("allow_sleep") && input["allow_sleep"].is_boolean()) {
      ok = nvhttp::set_client_sleep_allowed(uuid, input["allow_sleep"].get<bool>()) && ok;
    }
    if (input.contains("enabled") && input["enabled"].is_boolean()) {
      ok = nvhttp::set_client_enabled(uuid, input["enabled"].get<bool>()) && ok;
    }

    return ok ? YES : NO;
  } catch (const std::exception &e) {
    BOOST_LOG(warning) << "Native updateClientWithJSON failed: " << e.what();
    return NO;
  }
}

- (NSString *)fetchAppsJSON {
  try {
    std::lock_guard apps_lock {confighttp::apps_file_mutex()};
    const std::string content = file_handler::read_file(config::stream.file_apps.c_str());
    nlohmann::json file_tree = content.empty() ? nlohmann::json::object() : nlohmann::json::parse(content);
    nlohmann::json out = nlohmann::json::array();

    if (file_tree.contains("apps") && file_tree["apps"].is_array()) {
      for (const auto &entry : file_tree["apps"]) {
        if (!entry.is_object()) {
          continue;
        }
        nlohmann::json item;
        item["uuid"] = entry.value("uuid", "");
        item["name"] = entry.value("name", "");
        item["cmd"] = entry.value("cmd", "");
        item["workingDir"] = entry.value("working-dir", "");
        item["autoDetach"] = json_bool_or(entry, "auto-detach", true);
        item["waitAll"] = json_bool_or(entry, "wait-all", true);
        item["terminateOnPause"] = json_bool_or(entry, "terminate-on-pause", false);
        item["virtualScreen"] = json_bool_or(entry, "virtual-screen", false);
        item["prefer10BitSdr"] = json_bool_or(entry, "prefer-10bit-sdr", false);
        item["excludeGlobalPrepCmd"] = json_bool_or(entry, "exclude-global-prep-cmd", false);
        item["exitTimeout"] = entry.contains("exit-timeout") && entry["exit-timeout"].is_number_integer()
                                ? entry["exit-timeout"].get<int>()
                                : 5;
        item["isSystem"] = is_system_app_entry(entry);

        nlohmann::json detached = nlohmann::json::array();
        if (entry.contains("detached") && entry["detached"].is_array()) {
          for (const auto &d : entry["detached"]) {
            if (d.is_string()) {
              detached.push_back(d.get<std::string>());
            }
          }
        }
        item["detached"] = std::move(detached);

        nlohmann::json overrides = nlohmann::json::object();
        if (entry.contains("config-overrides") && entry["config-overrides"].is_object()) {
          for (const auto &kv : entry["config-overrides"].items()) {
            if (!kv.key().empty() && !kv.value().is_null()) {
              overrides[kv.key()] = kv.value().is_string() ? kv.value().get<std::string>() : kv.value().dump();
            }
          }
        }
        item["configOverrides"] = std::move(overrides);

        nlohmann::json preps = nlohmann::json::array();
        if (entry.contains("prep-cmd") && entry["prep-cmd"].is_array()) {
          for (const auto &p : entry["prep-cmd"]) {
            if (p.is_object()) {
              preps.push_back({
                {"do", p.value("do", "")},
                {"undo", p.value("undo", "")},
              });
            }
          }
        }
        item["prepCmds"] = std::move(preps);
        out.push_back(std::move(item));
      }
    }
    return to_nsstring(out.dump());
  } catch (const std::exception &e) {
    BOOST_LOG(warning) << "Native fetchAppsJSON failed: " << e.what();
    return @"[]";
  }
}

- (BOOL)saveAppWithJSON:(NSString *)payloadJSON
           errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
  try {
    const auto input = nlohmann::json::parse(payloadJSON.UTF8String ?: "{}");
    const std::string name = input.value("name", "");
    if (name.empty()) {
      if (errorMessage) *errorMessage = @"Application name is required.";
      return NO;
    }

    std::lock_guard apps_lock {confighttp::apps_file_mutex()};
    const std::string content = file_handler::read_file(config::stream.file_apps.c_str());
    nlohmann::json file_tree = content.empty() ? nlohmann::json {{"apps", nlohmann::json::array()}}
                                               : nlohmann::json::parse(content);
    if (!file_tree.contains("apps") || !file_tree["apps"].is_array()) {
      file_tree["apps"] = nlohmann::json::array();
    }

    std::string target_uuid = input.value("uuid", "");
    auto &apps_node = file_tree["apps"];
    int found_index = -1;
    if (!target_uuid.empty()) {
      for (std::size_t i = 0; i < apps_node.size(); ++i) {
        if (apps_node[i].is_object() && apps_node[i].value("uuid", "") == target_uuid) {
          found_index = static_cast<int>(i);
          break;
        }
      }
    }

    nlohmann::json entry = (found_index >= 0) ? apps_node[found_index] : nlohmann::json::object();
    if (target_uuid.empty()) {
      target_uuid = uuid_util::uuid_t::generate().string();
    }
    entry["uuid"] = target_uuid;
    entry["name"] = name;
    entry["cmd"] = input.value("cmd", "");
    entry["working-dir"] = input.value("workingDir", "");
    entry["auto-detach"] = input.value("autoDetach", true);
    entry["wait-all"] = input.value("waitAll", true);
    entry["terminate-on-pause"] = input.value("terminateOnPause", false);
    entry["virtual-screen"] = input.value("virtualScreen", false);
    entry["prefer-10bit-sdr"] = input.value("prefer10BitSdr", false);
    entry["exclude-global-prep-cmd"] = input.value("excludeGlobalPrepCmd", false);
    entry["exit-timeout"] = input.value("exitTimeout", 5);

    if (input.contains("detached") && input["detached"].is_array()) {
      nlohmann::json det = nlohmann::json::array();
      for (const auto &d : input["detached"]) {
        if (d.is_string() && !d.get<std::string>().empty()) {
          det.push_back(d.get<std::string>());
        }
      }
      entry["detached"] = std::move(det);
    }

    if (input.contains("configOverrides") && input["configOverrides"].is_object()) {
      nlohmann::json ov = nlohmann::json::object();
      for (const auto &kv : input["configOverrides"].items()) {
        if (!kv.key().empty() && !kv.value().is_null()) {
          const std::string s = kv.value().is_string() ? kv.value().get<std::string>() : kv.value().dump();
          if (!s.empty()) {
            ov[kv.key()] = s;
          }
        }
      }
      if (ov.empty()) {
        entry.erase("config-overrides");
      } else {
        entry["config-overrides"] = std::move(ov);
      }
    }

    if (input.contains("prepCmds") && input["prepCmds"].is_array()) {
      nlohmann::json prep_arr = nlohmann::json::array();
      const auto existing_preps = (entry.contains("prep-cmd") && entry["prep-cmd"].is_array())
                                    ? entry["prep-cmd"]
                                    : nlohmann::json::array();
      std::size_t idx = 0;
      for (const auto &p : input["prepCmds"]) {
        if (p.is_object()) {
          const std::string do_c = p.value("do", "");
          const std::string undo_c = p.value("undo", "");
          if (!do_c.empty() || !undo_c.empty()) {
            nlohmann::json item = (idx < existing_preps.size() && existing_preps[idx].is_object())
                                    ? existing_preps[idx]
                                    : nlohmann::json::object();
            item["do"] = do_c;
            item["undo"] = undo_c;
            prep_arr.push_back(std::move(item));
          }
        }
        ++idx;
      }
      entry["prep-cmd"] = std::move(prep_arr);
    }

    if (found_index >= 0) {
      apps_node[found_index] = std::move(entry);
    } else {
      apps_node.push_back(std::move(entry));
    }

    confighttp::refresh_client_apps_cache(file_tree);
    return YES;
  } catch (const std::exception &e) {
    if (errorMessage) *errorMessage = to_nsstring(e.what());
    return NO;
  }
}

- (BOOL)deleteAppWithUUID:(NSString *)uuid {
  const std::string target = uuid.UTF8String ?: "";
  if (target.empty()) {
    return NO;
  }
  try {
    std::lock_guard apps_lock {confighttp::apps_file_mutex()};
    const std::string content = file_handler::read_file(config::stream.file_apps.c_str());
    nlohmann::json file_tree = nlohmann::json::parse(content);
    if (!file_tree.contains("apps") || !file_tree["apps"].is_array()) {
      return NO;
    }

    nlohmann::json next_apps = nlohmann::json::array();
    bool removed = false;
    for (const auto &entry : file_tree["apps"]) {
      if (entry.is_object() && entry.value("uuid", "") == target && !is_system_app_entry(entry)) {
        removed = true;
        continue;
      }
      next_apps.push_back(entry);
    }
    if (!removed) {
      return NO;
    }
    file_tree["apps"] = std::move(next_apps);
    confighttp::refresh_client_apps_cache(file_tree);
    return YES;
  } catch (const std::exception &e) {
    BOOST_LOG(warning) << "Native deleteAppWithUUID failed: " << e.what();
    return NO;
  }
}

- (void)terminateRunningApp {
  proc::proc.terminate(true);
}

- (NSString *)fetchSettingsJSON {
  nlohmann::json out;
  std::unordered_map<std::string, std::string> file_vars;
  {
    std::lock_guard file_lock {config::config_file_mutex()};
    file_vars = config::parse_config(file_handler::read_file(config::sunshine.config_file.c_str()));
  }
  const bool opens_login = platf::opens_at_login();
  const bool allow_login_screen = platf::loginscreen_agent_enabled();
  auto read_gate = config::acquire_apply_read_gate();

  // General, Identity, Lifecycle & Files
  out["locale"] = config::sunshine.locale;
  out["sunshineName"] = config::nvhttp.sunshine_name;
  out["minLogLevel"] = config::sunshine.min_log_level;
  out["opensAtLogin"] = opens_login;
  out["allowOnLoginScreen"] = allow_login_screen;
  out["lidCloseEndsStreams"] = config::sunshine.lid_close_ends_streams;
  out["updateCheckInterval"] = config::sunshine.update_check_interval_seconds;
  out["notifyPreReleases"] = config::sunshine.notify_pre_releases;
  out["autoDownloadUpdates"] = config::sunshine.auto_download_updates;
  out["autoInstallUpdates"] = config::sunshine.auto_install_updates;
  out["hideTrayControls"] = config::sunshine.hide_tray_controls;
  out["envvarCompatibilityMode"] = config::sunshine.envvar_compatibility_mode;
  out["legacyOrdering"] = config::sunshine.legacy_ordering;

  out["appFocusAttempts"] = managed_app_focus::settings.attempts;
  out["appFocusTimeoutSecs"] = managed_app_focus::settings.timeout_secs;
  out["appFocusExitOnFirst"] = managed_app_focus::settings.exit_on_first;

  nlohmann::json prep_arr = nlohmann::json::array();
  for (const auto &p : config::sunshine.prep_cmds) {
    prep_arr.push_back({{"do", p.do_cmd}, {"undo", p.undo_cmd}});
  }
  out["globalPrepCmds"] = std::move(prep_arr);

  nlohmann::json state_arr = nlohmann::json::array();
  for (const auto &p : config::sunshine.state_cmds) {
    state_arr.push_back({{"do", p.do_cmd}, {"undo", p.undo_cmd}});
  }
  out["globalStateCmds"] = std::move(state_arr);

  nlohmann::json srv_arr = nlohmann::json::array();
  for (const auto &s : config::sunshine.server_cmds) {
    srv_arr.push_back({{"name", s.cmd_name}, {"cmd", s.cmd_val}});
  }
  out["serverCmds"] = std::move(srv_arr);

  out["credentialsFile"] = file_vars.contains("credentials_file") ? file_vars["credentials_file"] : "";
  out["fileState"] = file_vars.contains("file_state") ? file_vars["file_state"] : "";
  out["vibeshineFileState"] = file_vars.contains("vibeshine_file_state") ? file_vars["vibeshine_file_state"] : "";
  out["fileApps"] = file_vars.contains("file_apps") ? file_vars["file_apps"] : "";
  out["logPath"] = file_vars.contains("log_path") ? file_vars["log_path"] : "";
  out["pkey"] = file_vars.contains("pkey") ? file_vars["pkey"] : "";
  out["cert"] = file_vars.contains("cert") ? file_vars["cert"] : "";

  // Display & Remote Monitor
  out["virtualDisplayMode"] = virtual_display_mode_string(config::video.virtual_display_mode);
  out["virtualDisplayLayout"] = virtual_display_layout_string(config::video.virtual_display_layout);
  out["virtualDisplayScale"] = config::video.dd.virtual_display_scale_percent;
  out["keepDisplayWhilePaused"] = config::video.virtual_display_keep_while_paused;
  out["pausedDisplayTimeoutSecs"] = config::video.dd.paused_virtual_display_timeout_secs;
  out["hdrRequestOverride"] = hdr_request_override_string(config::video.dd.hdr_request_override);
  out["virtualDisplayMaxClients"] = config::video.virtual_display_max_clients;
  out["outputName"] = config::video.output_name;
  out["fallbackMode"] = config::video.fallback_mode;
  out["remoteMonitorConfirmAppReplacement"] = config::video.remote_monitor_confirm_app_replacement;
  out["remoteMonitorMuteAudio"] = config::video.remote_monitor_mute_audio;
  out["remoteMonitorDisconnectOnStreamEnd"] = config::video.remote_monitor_disconnect_on_stream_end;

  // Video & Encoder
  out["encoder"] = config::video.encoder;
  out["maxBitrateKbps"] = config::video.max_bitrate;
  out["minimumFpsTarget"] = config::video.minimum_fps_target;
  out["hevcMode"] = config::video.hevc_mode;
  out["av1Mode"] = config::video.av1_mode;
  out["fecPercentage"] = config::stream.fec_percentage;
  out["videoMaxBatchSizeKb"] = config::stream.video_max_batch_size_kb;
  out["pyrowave"] = config::video.pyrowave;
  out["hostAdaptivePacing"] = config::stream.host_adaptive_pacing;
  out["ignoreEncoderProbeFailure"] = config::video.ignore_encoder_probe_failure;

  out["vtRealtime"] = config::video.vt.vt_realtime != 0;
  out["vtCoder"] = vt_coder_string(config::video.vt.vt_coder);
  if (file_vars.contains("vt_software") && !file_vars["vt_software"].empty()) {
    out["vtSoftware"] = file_vars["vt_software"];
  } else if (config::video.vt.vt_require_sw != 0) {
    out["vtSoftware"] = "forced";
  } else if (config::video.vt.vt_allow_sw != 0) {
    out["vtSoftware"] = "allowed";
  } else {
    out["vtSoftware"] = "auto";
  }

  out["swPreset"] = config::video.sw.sw_preset.empty() ? "superfast" : config::video.sw.sw_preset;
  out["swTune"] = config::video.sw.sw_tune.empty() ? "zerolatency" : config::video.sw.sw_tune;
  out["qp"] = config::video.qp;
  out["minThreads"] = config::video.min_threads;

  // Input & Audio
  out["keyboard"] = config::input.keyboard;
  out["mouse"] = config::input.mouse;
  out["controller"] = config::input.controller;
  out["enableInputOnlyMode"] = config::input.enable_input_only_mode;
  out["forwardRumble"] = config::input.forward_rumble;
  out["motionAsDs4"] = config::input.motion_as_ds4;
  out["touchpadAsDs4"] = config::input.touchpad_as_ds4;
  out["ds4BackAsTouchpadClick"] = config::input.ds4_back_as_touchpad_click;
  out["alwaysSendScancodes"] = config::input.always_send_scancodes;
  out["keyRightAltToKeyWin"] = file_vars.contains("key_rightalt_to_key_win") &&
                               (file_vars["key_rightalt_to_key_win"] == "true" ||
                                file_vars["key_rightalt_to_key_win"] == "enabled" ||
                                file_vars["key_rightalt_to_key_win"] == "1");
  out["backButtonTimeout"] = static_cast<int>(config::input.back_button_timeout.count());
  out["guideButtonKey"] = config::input.guide_button_key;
  out["guideButtonController"] = config::input.guide_button_controller;
  out["keyRepeatDelay"] = static_cast<int>(config::input.key_repeat_delay.count());
  out["keyRepeatFrequency"] = config::input.key_repeat_period.count() > 0.0
                                ? (1.0 / config::input.key_repeat_period.count())
                                : 24.9;
  out["keybindings"] = file_vars.contains("keybindings") ? file_vars["keybindings"] : "";

  out["scrollInertia"] = config::input.macos_scroll_inertia.empty() ? "macos" : config::input.macos_scroll_inertia;
  out["pencilMode"] = config::input.macos_pencil_mode.empty() ? "auto" : config::input.macos_pencil_mode;
  out["palmRejection"] = config::input.macos_palm_rejection;
  out["highResScrolling"] = config::input.high_resolution_scrolling;
  out["nativePenTouch"] = config::input.native_pen_touch;

  out["streamAudio"] = config::audio.stream;
  out["audioFormat"] = config::audio.format.empty() ? "opus" : config::audio.format;
  out["highQualityAudio"] = config::audio.high_quality_audio;
  out["keepSinkDefault"] = config::audio.keep_default;
  out["autoCaptureSink"] = config::audio.auto_capture;
  out["audioSink"] = config::audio.sink;
  out["virtualSink"] = config::audio.virtual_sink;

  // Network, Security & Session History
  out["port"] = static_cast<int>(config::sunshine.port);
  out["addressFamily"] = config::sunshine.address_family.empty() ? "ipv4" : config::sunshine.address_family;
  out["upnp"] = file_vars.contains("upnp") &&
                (file_vars["upnp"] == "true" || file_vars["upnp"] == "enabled" || file_vars["upnp"] == "1");
  out["enableDiscovery"] = config::sunshine.enable_discovery;
  out["enablePairing"] = config::sunshine.enable_pairing;
  out["webUsername"] = config::sunshine.username;
  out["originWebUiAllowed"] = config::nvhttp.origin_web_ui_allowed.empty() ? "lan" : config::nvhttp.origin_web_ui_allowed;
  out["bindAddress"] = config::sunshine.bind_address;
  out["externalIp"] = config::nvhttp.external_ip;
  out["pingTimeout"] = static_cast<int>(config::stream.ping_timeout.count());
  out["controlPeerTimeout"] = static_cast<int>(config::get_control_peer_timeout().count());
  out["pacingMaxBitrateKbps"] = config::stream.pacing_max_bitrate_kbps;
  out["packetsize"] = config::stream.packetsize;
  out["lanEncryptionMode"] = config::stream.lan_encryption_mode;
  out["wanEncryptionMode"] = config::stream.wan_encryption_mode;
  out["sessionTokenTtlSeconds"] = static_cast<int>(config::sunshine.session_token_ttl.count());
  out["rememberMeRefreshTokenTtlSeconds"] = static_cast<int>(config::sunshine.remember_me_refresh_token_ttl.count());
  out["csrfAllowedOrigins"] = file_vars.contains("csrf_allowed_origins") ? file_vars["csrf_allowed_origins"] : "";

  out["sessionHistoryEnabled"] = config::sunshine.session_history_enabled;
  out["sessionHistoryTtlDays"] = config::sunshine.session_history_ttl_days;
  out["sessionHistoryDbSizeLimitMb"] = config::sunshine.session_history_db_size_limit_mb;
  out["hardwareMetrics"] = config::sunshine.hardware_metrics;
  out["hardwareMetricsInterval"] = config::sunshine.hardware_metrics_interval;
  out["realtimeStatsEnabled"] = config::sunshine.realtime_stats_enabled;
  out["realtimeStatsPollIntervalMs"] = config::sunshine.realtime_stats_poll_interval_ms;

  // Steam Integration
  out["steamEnabled"] = config::steam.enabled;
  out["steamAutoSync"] = config::steam.auto_sync;
  out["steamSyncAllInstalled"] = config::steam.sync_all_installed;
  out["steamRecentGames"] = config::steam.recent_games;
  out["steamRecentMaxAgeDays"] = config::steam.recent_max_age_days;
  out["steamAutosyncRemoveUninstalled"] = config::steam.autosync_remove_uninstalled;
  out["steamIncludeTools"] = config::steam.include_tools;

  return to_nsstring(out.dump());
}

- (NSDictionary<NSString *, id> *)saveSettingsWithJSON:(NSString *)patchJSON {
  try {
    const auto patch = nlohmann::json::parse(patchJSON.UTF8String ?: "{}");
    if (!patch.is_object()) {
      return @{@"status": @NO};
    }

    std::set<std::string> changed_keys;
    std::set<std::string> non_restart_keys;
    std::map<std::string, std::optional<std::string>> updates;

    for (auto it = patch.begin(); it != patch.end(); ++it) {
      const std::string key = it.key();
      const auto &val = it.value();
      changed_keys.insert(key);
      if (!config::is_restart_required_key(key)) {
        non_restart_keys.insert(key);
      }

      if (val.is_null() ||
          (val.is_string() && val.get<std::string>().empty()) ||
          (val.is_array() && val.empty())) {
        updates[key] = std::nullopt;
        continue;
      }
      if (val.is_string()) {
        updates[key] = val.get<std::string>();
      } else if (val.is_boolean()) {
        updates[key] = val.get<bool>() ? "true" : "false";
      } else {
        updates[key] = val.dump();
      }
    }

    if (!config::update_config_file(updates, false)) {
      return @{@"status": @NO};
    }

    bool restart_required = false;
    for (const auto &k : changed_keys) {
      if (config::is_restart_required_key(k)) {
        restart_required = true;
        break;
      }
    }

    const bool has_sessions = config::has_active_or_pending_stream_session();
    bool applied_now = false;
    bool deferred = false;

    if (!non_restart_keys.empty()) {
      if (config::can_hot_apply_during_session(non_restart_keys) || !has_sessions) {
        config::apply_config_now();
        if (non_restart_keys.count("dd_virtual_display_scale")) {
          platf::macos_virtual_display::reapply_scale();
        }
        applied_now = !restart_required;
      } else {
        config::mark_deferred_reload();
        deferred = true;
      }
    }

    system_tray::refresh_macos_tray_checks();

    if (changed_keys.count("notify_pre_releases")) {
      update::on_policy_changed(true);
    } else if (changed_keys.count("update_check_interval") ||
               changed_keys.count("auto_download_updates") ||
               changed_keys.count("auto_install_updates")) {
      update::on_policy_changed(false);
    }

    return @{
      @"status": @YES,
      @"appliedNow": @(applied_now),
      @"deferred": @(deferred),
      @"restartRequired": @(restart_required),
    };
  } catch (const std::exception &e) {
    BOOST_LOG(warning) << "Native saveSettingsWithJSON failed: " << e.what();
    return @{@"status": @NO};
  }
}

- (BOOL)updateWebCredentialsWithUsername:(NSString *)username
                                password:(NSString *)password {
  const std::string user = username.UTF8String ?: "";
  const std::string pass = password.UTF8String ?: "";
  if (user.empty() || pass.empty() || config::sunshine.credentials_file.empty()) {
    return NO;
  }
  if (http::save_user_creds(config::sunshine.credentials_file, user, pass) != 0) {
    return NO;
  }
  return http::reload_user_creds(config::sunshine.credentials_file) == 0 ? YES : NO;
}

- (BOOL)isOpenAtLoginEnabled {
  return platf::opens_at_login() ? YES : NO;
}

- (BOOL)isAllowOnLoginScreenEnabled {
  return platf::loginscreen_agent_enabled() ? YES : NO;
}

- (BOOL)setOpenAtLogin:(BOOL)enabled {
  (void) platf::set_opens_at_login(enabled == YES);
  system_tray::refresh_macos_tray_checks();
  return platf::opens_at_login() ? YES : NO;
}

- (BOOL)setAllowOnLoginScreen:(BOOL)enabled {
  (void) platf::set_loginscreen_agent_enabled(enabled == YES);
  system_tray::refresh_macos_tray_checks();
  return platf::loginscreen_agent_enabled() ? YES : NO;
}

- (NSString *)fetchLogsTail:(NSInteger)maxLines {
  const auto log_path = logging::current_log_file();
  if (log_path.empty()) {
    return @"";
  }
  std::string content = file_handler::read_file(log_path.string().c_str());
  if (content.empty() || maxLines <= 0) {
    return to_nsstring(content);
  }

  const std::size_t limit = static_cast<std::size_t>(std::min<NSInteger>(maxLines, 5000));
  std::size_t cursor = content.size();
  if (content.back() == '\n' && cursor > 0) {
    --cursor;
  }
  std::size_t tail_start = 0;
  for (std::size_t line = 0; line < limit && cursor > 0; ++line) {
    const auto sep = content.rfind('\n', cursor - 1);
    if (sep == std::string::npos) {
      tail_start = 0;
      break;
    }
    tail_start = sep + 1;
    cursor = sep;
  }
  if (tail_start > 0) {
    content.erase(0, tail_start);
  }
  return to_nsstring(content);
}

- (NSString *)currentLogFilePath {
  return to_nsstring(logging::current_log_file().string());
}

- (void)revealLogFileInFinder {
  const auto log_path = logging::current_log_file();
  if (log_path.empty()) {
    return;
  }
  NSURL *fileURL = [NSURL fileURLWithPath:to_nsstring(log_path.string())];
  if (fileURL != nil) {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[fileURL]];
  }
}

- (NSString *)fetchSessionHistoryJSON:(NSInteger)limit {
  try {
    const int capped = static_cast<int>(std::clamp<NSInteger>(limit, 1, 100));
    const auto rows = session_history::list_sessions(capped, 0);
    nlohmann::json out = nlohmann::json::array();
    for (const auto &r : rows) {
      out.push_back({
        {"uuid", r.uuid},
        {"protocol", r.protocol},
        {"clientName", r.client_name},
        {"deviceName", r.device_name},
        {"appName", r.app_name},
        {"width", r.width},
        {"height", r.height},
        {"targetFps", r.target_fps},
        {"bitrateKbps", r.encoder_bitrate_kbps},
        {"codec", r.codec},
        {"hdr", r.hdr},
        {"yuv444", r.yuv444},
        {"startTimeUnix", r.start_time_unix},
        {"endTimeUnix", r.end_time_unix},
        {"durationSeconds", r.duration_seconds},
        {"verdict", r.verdict},
      });
    }
    return to_nsstring(out.dump());
  } catch (const std::exception &e) {
    BOOST_LOG(warning) << "Native fetchSessionHistoryJSON failed: " << e.what();
    return @"[]";
  }
}

- (BOOL)deleteSessionHistoryWithUUID:(NSString *)uuid {
  const std::string target = uuid.UTF8String ?: "";
  if (target.empty()) {
    return NO;
  }
  return session_history::delete_session(target) == session_history::delete_result_e::deleted ? YES : NO;
}

- (BOOL)isSteamAvailable {
  return platf::steam::available() ? YES : NO;
}

- (BOOL)syncSteamCatalogNow {
  try {
    if (!platf::steam::available()) {
      return NO;
    }
    const auto path = config::stream.file_apps;
    std::lock_guard apps_lock {confighttp::apps_file_mutex()};
    const auto text = file_handler::read_file(path.c_str());
    nlohmann::json root = text.empty() ? nlohmann::json {{"apps", nlohmann::json::array()}}
                                       : nlohmann::json::parse(text);
    auto catalog = platf::steam::discover_catalog();
    auto games = platf::steam::sync::policy::select_games(
      catalog,
      config::steam.sync_all_installed,
      config::steam.recent_games,
      config::steam.recent_max_age_days,
      config::steam.exclude_games_meta,
      config::steam.include_tools
    );
    platf::steam::artwork::prepare(games, platf::appdata());
    const bool remove_missing = !config::steam.sync_all_installed || config::steam.autosync_remove_uninstalled;
    if (platf::steam::sync::policy::reconcile(
          root,
          games,
          remove_missing,
          config::steam.exclude_games_meta,
          config::steam.include_tools,
          config::steam.sync_all_installed ? "installed" : "recent"
        )) {
      confighttp::refresh_client_apps_cache(root);
    }
    return YES;
  } catch (const std::exception &e) {
    BOOST_LOG(warning) << "Native syncSteamCatalogNow failed: " << e.what();
    return NO;
  }
}

- (NSString *)fetchSoftwareUpdateStatusJSON {
  const auto snap = update::get_status_snapshot();
  auto phase_str = [](update::phase_e p) -> const char * {
    switch (p) {
      case update::phase_e::checking:
        return "checking";
      case update::phase_e::up_to_date:
        return "up_to_date";
      case update::phase_e::available:
        return "available";
      case update::phase_e::downloading:
        return "downloading";
      case update::phase_e::verifying:
        return "verifying";
      case update::phase_e::downloaded:
        return "downloaded";
      case update::phase_e::installing:
        return "installing";
      case update::phase_e::restarting:
        return "restarting";
      case update::phase_e::error:
        return "error";
      case update::phase_e::idle:
      default:
        return "idle";
    }
  };

  std::string bundle_path;
  std::string bundle_reason;
  const bool can_self_update = platf::can_self_update_macos_bundle(&bundle_path, &bundle_reason);

  nlohmann::json out;
  out["phase"] = phase_str(snap.phase);
  out["currentVersion"] = snap.current_version;
  out["currentChannel"] = snap.current_channel;
  out["currentCommit"] = snap.current_commit;
  out["availableVersion"] = snap.available_release.version;
  out["availableName"] = snap.available_release.name;
  out["availableUrl"] = snap.available_release.url;
  out["availableBody"] = snap.available_release.body;
  out["availablePublishedAt"] = snap.available_release.published_at;
  out["isPrerelease"] = snap.available_release.is_prerelease;
  out["assetName"] = snap.target_asset.name;
  out["assetSize"] = snap.target_asset.size;
  out["downloadedBytes"] = snap.downloaded_bytes;
  out["totalBytes"] = snap.total_bytes;
  out["lastCheckedUnix"] = snap.last_checked_unix;
  out["scheduledOnIdle"] = snap.scheduled_on_idle;
  out["checkInProgress"] = snap.check_in_progress;
  out["canSelfUpdate"] = can_self_update;
  out["bundlePath"] = bundle_path;
  out["bundleReason"] = bundle_reason;
  out["errorCode"] = snap.error_code;
  out["errorDetail"] = snap.error_detail;
  return to_nsstring(out.dump());
}

- (void)checkForUpdates {
  update::trigger_check(true);
}

- (void)startSoftwareUpdateNow {
  update::start_install_now(true);
}

- (void)downloadSoftwareUpdateOnly {
  update::start_download(false);
}

- (void)cancelSoftwareUpdateDownload {
  update::cancel_download();
}

- (void)setSoftwareUpdateScheduledOnIdle:(BOOL)scheduled {
  update::schedule_install_on_idle(scheduled == YES);
}

- (void)openExternalURL:(NSString *)urlString {
  const std::string raw = urlString.UTF8String ?: "";
  if (raw.starts_with("https://")) {
    platf::open_url(raw);
  }
}

- (void)restartHost {
  proc::proc.terminate();
  platf::restart();
}

@end
