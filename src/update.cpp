/**
 * @file src/update.cpp
 * @brief Definitions for update checking, downloading, verification, installation, and notification.
 */

#include "update.h"

// standard includes
#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <future>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <thread>
#include <unistd.h>
#include <variant>

// lib includes
#include <nlohmann/json.hpp>
#include <openssl/evp.h>

// local includes
#include "config.h"
#include "httpcommon.h"
#include "logging.h"
#include "nvhttp.h"  // for save_state persistence hooks
#include "platform/common.h"
#include "process.h"
#include "rtsp.h"  // for session_count
#include "system_tray.h"
#include "update_release.h"
#include "utility.h"
#include "version_compare.h"

#ifdef __APPLE__
  #include "platform/macos/misc.h"
#endif

using namespace std::literals;

namespace update {
  state_t state;

  namespace {
    namespace fs = std::filesystem;

    struct runtime_state_t {
      std::mutex mutex;
      std::atomic<int> phase {static_cast<int>(phase_e::idle)};
      std::atomic<std::int64_t> downloaded_bytes {0};
      std::atomic<std::int64_t> total_bytes {0};
      std::atomic<std::int64_t> last_checked_unix {0};
      std::atomic<bool> scheduled_on_idle {false};
      std::atomic<bool> cancel_requested {false};
      std::atomic<bool> operation_in_progress {false};
      release_info_t available_release;
      asset_info_t target_asset;
      std::string downloaded_dmg_path;
      std::string error_code;
      std::string error_detail;
    };

    runtime_state_t g_runtime;

    std::int64_t current_unix_seconds() {
      return std::chrono::duration_cast<std::chrono::seconds>(
               std::chrono::system_clock::now().time_since_epoch()
      )
        .count();
    }

    fs::path updates_cache_dir() {
      return platf::appdata() / "updates";
    }

    std::string sanitize_filename_token(std::string_view input) {
      std::string out;
      out.reserve(input.size());
      for (const char ch : input) {
        if (std::isalnum(static_cast<unsigned char>(ch)) || ch == '.' || ch == '-' || ch == '_') {
          out.push_back(ch);
        } else {
          out.push_back('_');
        }
      }
      return out.empty() ? "latest" : out;
    }

    fs::path cached_dmg_path_for_version(std::string_view version) {
      return updates_cache_dir() / ("Vibepollo-" + sanitize_filename_token(version) + ".dmg");
    }

    void prune_cached_dmgs_except(const fs::path &keep_path) {
      std::error_code ec;
      const fs::path dir = updates_cache_dir();
      if (!fs::is_directory(dir, ec) || ec) {
        return;
      }
      for (const auto &entry : fs::directory_iterator(dir, ec)) {
        if (ec) {
          break;
        }
        if (entry.path() != keep_path) {
          std::error_code rm_ec;
          fs::remove_all(entry.path(), rm_ec);
        }
      }
    }

    std::string bytes_to_hex(const unsigned char *digest, unsigned int len) {
      std::ostringstream oss;
      oss << std::hex << std::setfill('0');
      for (unsigned int i = 0; i < len; ++i) {
        oss << std::setw(2) << static_cast<unsigned int>(digest[i]);
      }
      return oss.str();
    }

    std::string compute_file_sha256(const fs::path &path) {
      std::ifstream file(path, std::ios::binary);
      if (!file.is_open()) {
        return {};
      }
      EVP_MD_CTX *ctx = EVP_MD_CTX_new();
      if (!ctx) {
        return {};
      }
      auto free_ctx = util::fail_guard([ctx]() {
        EVP_MD_CTX_free(ctx);
      });
      if (EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr) != 1) {
        return {};
      }
      char buffer[65536];
      while (file.good()) {
        file.read(buffer, sizeof(buffer));
        const auto count = file.gcount();
        if (count > 0 && EVP_DigestUpdate(ctx, buffer, static_cast<std::size_t>(count)) != 1) {
          return {};
        }
      }
      if (file.bad()) {
        return {};
      }
      unsigned char md[EVP_MAX_MD_SIZE];
      unsigned int md_len = 0;
      if (EVP_DigestFinal_ex(ctx, md, &md_len) != 1) {
        return {};
      }
      return bytes_to_hex(md, md_len);
    }

    bool verify_cached_dmg(const fs::path &dmg_path, const asset_info_t &asset) {
      std::error_code ec;
      if (dmg_path.empty() || !fs::is_regular_file(dmg_path, ec) || ec) {
        return false;
      }
      const auto file_sz = static_cast<std::int64_t>(fs::file_size(dmg_path, ec));
      if (ec || file_sz <= 0 || (asset.size > 0 && file_sz != asset.size)) {
        return false;
      }
      if (!asset.sha256.empty()) {
        return compute_file_sha256(dmg_path) == asset.sha256;
      }
      return true;
    }

    asset_info_t select_platform_asset(const release_info_t &rel) {
#ifdef __APPLE__
  #if defined(__aarch64__) || defined(__arm64__) || defined(_M_ARM64)
      constexpr std::string_view expected_name = "Vibepollo-macOS-arm64.dmg";
  #else
      constexpr std::string_view expected_name = "Vibepollo-macOS-x86_64.dmg";
  #endif
      for (const auto &asset : rel.assets) {
        if (asset.name == expected_name && !asset.download_url.empty()) {
          return asset;
        }
      }
#endif
      for (const auto &asset : rel.assets) {
        if (!asset.download_url.empty()) {
          return asset;
        }
      }
      return {};
    }

    bool is_host_idle_for_install(bool explicit_user_schedule) {
#ifdef __APPLE__
      if (platf::is_loginwindow_session()) {
        return false;
      }
      std::string bundle_path;
      if (!platf::can_self_update_macos_bundle(&bundle_path, nullptr)) {
        return false;
      }
      if (!explicit_user_schedule) {
        if (platf::is_native_settings_window_visible()) {
          return false;
        }
        const fs::path target_app {bundle_path};
        if (::access(target_app.parent_path().c_str(), W_OK) != 0 || ::access(target_app.c_str(), W_OK) != 0) {
          // Do not pop an unattended administrator password prompt in the background.
          return false;
        }
      }
#endif
      return rtsp_stream::session_count() == 0 && proc::proc.current_app_id() <= 0;
    }
  }  // namespace

  static size_t write_to_string(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t total = size * nmemb;
    auto *out = static_cast<std::string *>(userp);
    out->append(static_cast<char *>(contents), total);
    return total;
  }

  static bool download_json(const std::string &url, std::string &out_json) {
    out_json.clear();
    CURL *curl = curl_easy_init();
    if (!curl) {
      BOOST_LOG(error) << "CURL init failed for GitHub API"sv;
      return false;
    }
    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Accept: application/vnd.github+json");
    headers = curl_slist_append(headers, "X-GitHub-Api-Version: 2022-11-28");
    headers = curl_slist_append(headers, "User-Agent: Sunshine-Updater/1.0");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    bool tls_configured = http::configure_curl_tls(curl);
    if (!tls_configured) {
      BOOST_LOG(warning) << "GitHub release check is using libcurl defaults for TLS";
    }
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
#if LIBCURL_VERSION_NUM >= 0x075500
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "https");
#else
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTPS);
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTPS);
#endif
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 20L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_to_string);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &out_json);
    char errbuf[CURL_ERROR_SIZE] = {0};
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, errbuf);
    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
      BOOST_LOG(error) << "GitHub API request failed: "sv << curl_easy_strerror(res);
      if (errbuf[0] != '\0') {
        BOOST_LOG(error) << "GitHub API error detail: "sv << errbuf;
      }
      long verify_result = 0;
      if (curl_easy_getinfo(curl, CURLINFO_SSL_VERIFYRESULT, &verify_result) == CURLE_OK && verify_result != 0) {
        BOOST_LOG(error) << "TLS verification result code: "sv << verify_result;
      }
#ifdef CURLINFO_OS_ERRNO
      long os_err = 0;
      if (curl_easy_getinfo(curl, CURLINFO_OS_ERRNO, &os_err) == CURLE_OK && os_err != 0) {
        BOOST_LOG(error) << "OS-level error code: "sv << os_err;
      }
#endif
      curl_slist_free_all(headers);
      curl_easy_cleanup(curl);
      return false;
    }
    long code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    if (code < 200 || code >= 300) {
      BOOST_LOG(error) << "GitHub API returned HTTP "sv << code;
      return false;
    }
    return true;
  }

  bool download_github_release_data(const std::string &owner, const std::string &repo, std::string &out_json) {
    // Commit the list only after every page succeeds. A rate-limited partial list
    // must never be used to announce an update or reuse an earlier candidate.
    nlohmann::json releases = nlohmann::json::array();
    for (int page = 1; page <= 10; ++page) {
      std::string data;
      if (!download_json("https://api.github.com/repos/" + owner + "/" + repo + "/releases?per_page=100&page=" + std::to_string(page), data)) return false;
      auto batch = nlohmann::json::parse(data, nullptr, false);
      if (!batch.is_array()) return false;
      for (const auto &release : batch) releases.push_back(release);
      if (batch.size() < 100) {
        out_json = releases.dump();
        return true;
      }
    }
    return false; // Bounded pagination exhausted: retry rather than infer a winner.
  }

  bool download_nightly_metadata(const std::string &tag, std::string &out_json) {
    if (!release_selection::daily_tag(tag) && !release_selection::numeric_tag(tag)) return false;
    // Kept for API compatibility; availability checks never fetch assets.
    std::string data;
    if (!download_json("https://api.github.com/repos/" SUNSHINE_REPO_OWNER "/" SUNSHINE_REPO_NAME "/releases/tags/" + tag, data)) return false;
    const auto release = nlohmann::json::parse(data, nullptr, false);
    if (!release_selection::verified_nightly_release(release, tag)) return false;
    const auto metadata = release_selection::api_metadata(release);
    if (metadata.is_null()) return false;
    out_json = metadata.dump();
    return true;
  }

  static void notify_new_version(const std::string &version, bool prerelease) {
#if defined SUNSHINE_TRAY && SUNSHINE_TRAY >= 1
    if (version.empty() || (prerelease && !config::sunshine.notify_pre_releases)) {
      return;
    }
    // Persist delivered identities: dismissing an OS toast consumes it, including
    // across process restarts and stable/prerelease channel changes.
    std::string url;
    {
      std::lock_guard<std::mutex> lock(state.notification_mutex);
      if (version == state.last_notified_version || std::find(state.notified_versions.begin(), state.notified_versions.end(), version) != state.notified_versions.end()) {
        BOOST_LOG(debug) << "Update notification suppressed: already notified for "sv << version;
        return;
      }
      state.last_notified_version = version;
      state.last_notified_is_prerelease = prerelease;
      state.last_notified_url = prerelease ? state.latest_prerelease.url : state.latest_release.url;
      state.notified_versions.push_back(version);
      url = state.last_notified_url;
    }
    const std::string title = prerelease ? "New update available (Pre-release)" : "New update available (Stable)";
    // The C tray backend has no per-notification context, and Windows routes
    // older toast clicks through its latest global callback. Keep the exact
    // release link in the text; the Web UI provides its clickable counterpart.
    const std::string body = "Version " + version + (url.empty() ? "" : "\n" + url);
    system_tray::tray_notify(title.c_str(), body.c_str());
    // Do not hold the notification lock while acquiring nvhttp's client lock.
    nvhttp::save_state();
#endif
  }

  static void perform_check() {
    auto fg = util::fail_guard([]() {
      state.check_in_progress = false;
    });
    try {
      state.last_check_time = std::chrono::steady_clock::now();
      BOOST_LOG(info) << "Update check: querying GitHub releases from repo "sv
                      << SUNSHINE_REPO_OWNER << '/' << SUNSHINE_REPO_NAME;
      std::string releases_json;
      if (!download_github_release_data(SUNSHINE_REPO_OWNER, SUNSHINE_REPO_NAME, releases_json)) {
        std::lock_guard lock {g_runtime.mutex};
        if (g_runtime.downloaded_dmg_path.empty()) {
          g_runtime.error_code = "scan_failed";
          g_runtime.error_detail = "Unable to contact GitHub Releases API.";
          g_runtime.phase.store(static_cast<int>(phase_e::error), std::memory_order_release);
        } else {
          g_runtime.phase.store(static_cast<int>(phase_e::downloaded), std::memory_order_release);
        }
        return;
      }

      auto j = nlohmann::json::parse(releases_json, nullptr, false);
      if (!j.is_array()) {
        std::lock_guard lock {g_runtime.mutex};
        g_runtime.error_code = "scan_failed";
        g_runtime.error_detail = "Malformed release payload.";
        g_runtime.phase.store(static_cast<int>(phase_e::error), std::memory_order_release);
        return;
      }

      bool allow_prereleases = true;
      bool auto_check = true;
      bool auto_download = false;
      bool auto_install = false;
      {
        auto read_gate = config::acquire_apply_read_gate();
        allow_prereleases = config::sunshine.notify_pre_releases;
        auto_check = config::sunshine.update_check_interval_seconds > 0;
        auto_download = config::sunshine.auto_download_updates;
        auto_install = config::sunshine.auto_install_updates;
      }

      const auto stable = release_selection::select(j, PROJECT_VERSION, false);
      const auto any = release_selection::select(j, PROJECT_VERSION, allow_prereleases);
      auto info = [](const nlohmann::json &rel) {
        release_info_t result {};
        if (rel.is_null()) return result;
        const std::string tag_name = rel.value("tag_name", "");
        const std::string resolved_id = release_selection::identity(rel);
        result.version = resolved_id.empty() ? tag_name : resolved_id;
        result.url = "https://github.com/" SUNSHINE_REPO_OWNER "/" SUNSHINE_REPO_NAME "/releases/tag/" + tag_name;
        auto text = [](const nlohmann::json &object, const char *key) {
          return object.contains(key) && object[key].is_string() ? object[key].get<std::string>() : std::string {};
        };
        result.name = text(rel, "name");
        result.body = text(rel, "body");
        result.published_at = text(rel, "published_at");
        result.is_prerelease = rel.value("prerelease", false);
        if (rel.contains("assets") && rel["assets"].is_array()) {
          for (const auto &asset : rel["assets"]) {
            if (!asset.is_object()) continue;
            asset_info_t item {};
            item.name = text(asset, "name");
            item.download_url = text(asset, "browser_download_url");
            item.size = asset.value("size", 0LL);
            item.content_type = text(asset, "content_type");
            item.sha256 = release_selection::extract_asset_sha256(asset, result.body);
            result.assets.push_back(std::move(item));
          }
        }
        return result;
      };

      const release_info_t stable_info = info(stable);
      const release_info_t selected_info = info(any);
      state.latest_release = stable_info;
      state.latest_prerelease = (!any.is_null() && any.value("prerelease", false)) ? selected_info : release_info_t {};
      state.last_check_time = std::chrono::steady_clock::now();
      g_runtime.last_checked_unix.store(current_unix_seconds(), std::memory_order_release);

      bool should_auto_download = false;
      bool should_auto_install_now = false;

      {
        std::lock_guard lock {g_runtime.mutex};
        g_runtime.error_code.clear();
        g_runtime.error_detail.clear();

        if (any.is_null() || selected_info.version.empty()) {
          g_runtime.available_release = {};
          g_runtime.target_asset = {};
          g_runtime.downloaded_dmg_path.clear();
          g_runtime.downloaded_bytes.store(0, std::memory_order_relaxed);
          g_runtime.total_bytes.store(0, std::memory_order_relaxed);
          g_runtime.scheduled_on_idle.store(false, std::memory_order_relaxed);
          g_runtime.phase.store(static_cast<int>(phase_e::up_to_date), std::memory_order_release);
        } else {
          g_runtime.available_release = selected_info;
          g_runtime.target_asset = select_platform_asset(selected_info);

          const fs::path candidate_cache = cached_dmg_path_for_version(selected_info.version);
          if (verify_cached_dmg(candidate_cache, g_runtime.target_asset)) {
            g_runtime.downloaded_dmg_path = candidate_cache.string();
            g_runtime.downloaded_bytes.store(g_runtime.target_asset.size, std::memory_order_relaxed);
            g_runtime.total_bytes.store(g_runtime.target_asset.size, std::memory_order_relaxed);
            g_runtime.phase.store(static_cast<int>(phase_e::downloaded), std::memory_order_release);
            if (auto_check && auto_download && auto_install) {
              should_auto_install_now = is_host_idle_for_install(false);
            }
          } else {
            g_runtime.downloaded_dmg_path.clear();
            g_runtime.downloaded_bytes.store(0, std::memory_order_relaxed);
            g_runtime.total_bytes.store(g_runtime.target_asset.size, std::memory_order_relaxed);
            g_runtime.phase.store(static_cast<int>(phase_e::available), std::memory_order_release);
            if (auto_check && auto_download && rtsp_stream::session_count() == 0) {
              should_auto_download = true;
            }
          }
        }
      }

      if (!any.is_null()) {
        notify_new_version(any.value("tag_name", ""), any.value("prerelease", false));
      }

      if (should_auto_download) {
        start_download(auto_install);
      } else if (should_auto_install_now) {
        start_install_now(false);
      }
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "Update check failed: "sv << e.what();
      std::lock_guard lock {g_runtime.mutex};
      g_runtime.error_code = "scan_failed";
      g_runtime.error_detail = e.what();
      g_runtime.phase.store(static_cast<int>(phase_e::error), std::memory_order_release);
    }
  }

  namespace {
    struct streaming_download_sink_t {
      std::ofstream file;
      EVP_MD_CTX *sha_ctx {nullptr};
      std::int64_t written {0};
      bool write_failed {false};
    };

    size_t write_to_dmg_stream(void *contents, size_t size, size_t nmemb, void *userp) {
      const size_t total = size * nmemb;
      auto *sink = static_cast<streaming_download_sink_t *>(userp);
      if (!sink || total == 0) {
        return total;
      }
      sink->file.write(static_cast<const char *>(contents), static_cast<std::streamsize>(total));
      if (!sink->file.good()) {
        sink->write_failed = true;
        return 0;
      }
      if (sink->sha_ctx && EVP_DigestUpdate(sink->sha_ctx, contents, total) != 1) {
        sink->write_failed = true;
        return 0;
      }
      sink->written += static_cast<std::int64_t>(total);
      g_runtime.downloaded_bytes.store(sink->written, std::memory_order_relaxed);
      return total;
    }

    int curl_progress_cb(void *, curl_off_t dltotal, curl_off_t dlnow, curl_off_t, curl_off_t) {
      if (g_runtime.cancel_requested.load(std::memory_order_relaxed)) {
        return 1;
      }
      if (dltotal > 0) {
        g_runtime.total_bytes.store(static_cast<std::int64_t>(dltotal), std::memory_order_relaxed);
      }
      if (dlnow >= 0) {
        g_runtime.downloaded_bytes.store(static_cast<std::int64_t>(dlnow), std::memory_order_relaxed);
      }
      return 0;
    }

    void populate_sha256_from_sums_if_missing(asset_info_t &target, const release_info_t &rel) {
      if (!target.sha256.empty() || target.name.empty()) {
        return;
      }
      for (const auto &asset : rel.assets) {
        if (asset.name == "SHA256SUMS" && !asset.download_url.empty()) {
          std::string sums_text;
          if (download_json(asset.download_url, sums_text)) {
            target.sha256 = release_selection::parse_sha256_for_filename(sums_text, target.name);
          }
          break;
        }
      }
    }

    bool perform_download_locked_target(std::string &out_dmg_path, std::string &out_err_code, std::string &out_err_detail) {
      release_info_t rel;
      asset_info_t asset;
      {
        std::lock_guard lock {g_runtime.mutex};
        rel = g_runtime.available_release;
        asset = g_runtime.target_asset;
        if (!g_runtime.downloaded_dmg_path.empty()) {
          const fs::path existing {g_runtime.downloaded_dmg_path};
          if (verify_cached_dmg(existing, asset)) {
            out_dmg_path = existing.string();
            g_runtime.phase.store(static_cast<int>(phase_e::downloaded), std::memory_order_release);
            return true;
          }
          g_runtime.downloaded_dmg_path.clear();
        }
      }

      if (rel.version.empty() || asset.download_url.empty()) {
        out_err_code = "download_failed";
        out_err_detail = "No downloadable update package is available for this Mac.";
        return false;
      }

      const fs::path cache_dir = updates_cache_dir();
      std::error_code ec;
      fs::create_directories(cache_dir, ec);
      const fs::path final_path = cached_dmg_path_for_version(rel.version);
      const fs::path part_path = final_path.string() + ".part";

      if (verify_cached_dmg(final_path, asset)) {
        std::lock_guard lock {g_runtime.mutex};
        g_runtime.downloaded_dmg_path = final_path.string();
        g_runtime.downloaded_bytes.store(asset.size, std::memory_order_relaxed);
        g_runtime.total_bytes.store(asset.size, std::memory_order_relaxed);
        g_runtime.phase.store(static_cast<int>(phase_e::downloaded), std::memory_order_release);
        out_dmg_path = final_path.string();
        return true;
      }

      fs::remove(part_path, ec);
      g_runtime.cancel_requested.store(false, std::memory_order_relaxed);
      g_runtime.downloaded_bytes.store(0, std::memory_order_relaxed);
      g_runtime.total_bytes.store(asset.size, std::memory_order_relaxed);
      g_runtime.phase.store(static_cast<int>(phase_e::downloading), std::memory_order_release);

      populate_sha256_from_sums_if_missing(asset, rel);

      streaming_download_sink_t sink {};
      sink.file.open(part_path, std::ios::binary | std::ios::trunc);
      if (!sink.file.is_open()) {
        out_err_code = "download_failed";
        out_err_detail = "Unable to create temporary update file on disk.";
        return false;
      }
      sink.sha_ctx = EVP_MD_CTX_new();
      auto cleanup_part = util::fail_guard([&]() {
        if (sink.sha_ctx) {
          EVP_MD_CTX_free(sink.sha_ctx);
          sink.sha_ctx = nullptr;
        }
        sink.file.close();
        std::error_code rm_ec;
        fs::remove(part_path, rm_ec);
      });

      if (!sink.sha_ctx || EVP_DigestInit_ex(sink.sha_ctx, EVP_sha256(), nullptr) != 1) {
        out_err_code = "download_failed";
        out_err_detail = "Unable to initialize SHA-256 verifier.";
        return false;
      }

      CURL *curl = curl_easy_init();
      if (!curl) {
        out_err_code = "download_failed";
        out_err_detail = "Unable to initialize network client.";
        return false;
      }

      struct curl_slist *headers = nullptr;
      headers = curl_slist_append(headers, "User-Agent: Vibepollo-Updater/1.0");
      curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
      curl_easy_setopt(curl, CURLOPT_URL, asset.download_url.c_str());
      (void) http::configure_curl_tls(curl);
      curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
#if LIBCURL_VERSION_NUM >= 0x075500
      curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
      curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "https");
#else
      curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTPS);
      curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTPS);
#endif
      curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
      curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1024L);
      curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 30L);
      curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_to_dmg_stream);
      curl_easy_setopt(curl, CURLOPT_WRITEDATA, &sink);
      curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
      curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, curl_progress_cb);
      curl_easy_setopt(curl, CURLOPT_XFERINFODATA, nullptr);

      const CURLcode res = curl_easy_perform(curl);
      long http_code = 0;
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
      curl_slist_free_all(headers);
      curl_easy_cleanup(curl);

      sink.file.flush();
      sink.file.close();

      if (res == CURLE_ABORTED_BY_CALLBACK || g_runtime.cancel_requested.load(std::memory_order_relaxed)) {
        out_err_code = "cancelled";
        return false;
      }

      if (res != CURLE_OK || sink.write_failed || http_code < 200 || http_code >= 300) {
        out_err_code = "download_failed";
        out_err_detail = res != CURLE_OK ? curl_easy_strerror(res) : ("HTTP " + std::to_string(http_code));
        return false;
      }

      g_runtime.phase.store(static_cast<int>(phase_e::verifying), std::memory_order_release);

      if (asset.size > 0 && sink.written != asset.size) {
        out_err_code = "checksum_mismatch";
        out_err_detail = "Downloaded package size did not match release metadata.";
        return false;
      }

      unsigned char md[EVP_MAX_MD_SIZE];
      unsigned int md_len = 0;
      if (EVP_DigestFinal_ex(sink.sha_ctx, md, &md_len) != 1) {
        out_err_code = "checksum_mismatch";
        out_err_detail = "Failed to finalize SHA-256 digest.";
        return false;
      }
      EVP_MD_CTX_free(sink.sha_ctx);
      sink.sha_ctx = nullptr;

      const std::string computed_sha256 = bytes_to_hex(md, md_len);
      if (!asset.sha256.empty() && computed_sha256 != asset.sha256) {
        BOOST_LOG(error) << "Update SHA-256 mismatch: expected "sv << asset.sha256 << ", got "sv << computed_sha256;
        out_err_code = "checksum_mismatch";
        out_err_detail = "SHA-256 digest verification failed.";
        return false;
      }

      fs::rename(part_path, final_path, ec);
      if (ec) {
        out_err_code = "download_failed";
        out_err_detail = "Unable to finalize downloaded disk image: " + ec.message();
        return false;
      }

      cleanup_part.disable();
      prune_cached_dmgs_except(final_path);

      {
        std::lock_guard lock {g_runtime.mutex};
        g_runtime.target_asset.sha256 = asset.sha256.empty() ? computed_sha256 : asset.sha256;
        g_runtime.downloaded_dmg_path = final_path.string();
        g_runtime.downloaded_bytes.store(sink.written, std::memory_order_relaxed);
        g_runtime.total_bytes.store(sink.written, std::memory_order_relaxed);
        g_runtime.error_code.clear();
        g_runtime.error_detail.clear();
        g_runtime.phase.store(static_cast<int>(phase_e::downloaded), std::memory_order_release);
      }

      out_dmg_path = final_path.string();
      return true;
    }

    void run_install_pipeline(bool reopen_settings_ui) {
      auto op_guard = util::fail_guard([]() {
        g_runtime.operation_in_progress.store(false, std::memory_order_release);
      });

      std::string dmg_path;
      std::string err_code;
      std::string err_detail;
      if (!perform_download_locked_target(dmg_path, err_code, err_detail)) {
        std::lock_guard lock {g_runtime.mutex};
        if (err_code == "cancelled") {
          g_runtime.downloaded_bytes.store(0, std::memory_order_relaxed);
          g_runtime.error_code.clear();
          g_runtime.error_detail.clear();
          g_runtime.phase.store(static_cast<int>(phase_e::available), std::memory_order_release);
        } else {
          g_runtime.error_code = err_code;
          g_runtime.error_detail = err_detail;
          g_runtime.scheduled_on_idle.store(false, std::memory_order_relaxed);
          g_runtime.phase.store(static_cast<int>(phase_e::error), std::memory_order_release);
        }
        return;
      }

#ifdef __APPLE__
      g_runtime.phase.store(static_cast<int>(phase_e::installing), std::memory_order_release);
      if (!platf::install_macos_update_dmg(dmg_path, err_code, err_detail)) {
        std::lock_guard lock {g_runtime.mutex};
        if (err_code == "auth_cancelled") {
          // User dismissed the macOS administrator password / Touch ID prompt: keep package ready.
          g_runtime.error_code.clear();
          g_runtime.error_detail.clear();
          g_runtime.phase.store(static_cast<int>(phase_e::downloaded), std::memory_order_release);
        } else {
          g_runtime.error_code = err_code;
          g_runtime.error_detail = err_detail;
          g_runtime.scheduled_on_idle.store(false, std::memory_order_relaxed);
          g_runtime.phase.store(static_cast<int>(phase_e::error), std::memory_order_release);
        }
        return;
      }

      g_runtime.scheduled_on_idle.store(false, std::memory_order_relaxed);
      g_runtime.phase.store(static_cast<int>(phase_e::restarting), std::memory_order_release);

      std::error_code rm_ec;
      fs::remove(fs::path {dmg_path}, rm_ec);

      if (reopen_settings_ui) {
        platf::set_pending_reopen_ui_route("software_update");
      }

      // Brief pause so SwiftUI renders "Restarting Vibepollo…" cleanly before teardown.
      std::this_thread::sleep_for(350ms);
      proc::proc.terminate();
      platf::restart();
#else
      (void) reopen_settings_ui;
      open_last_notified_release_page();
#endif
    }
  }  // namespace

  status_snapshot_t get_status_snapshot() {
    status_snapshot_t snap {};
    snap.current_version = PROJECT_VERSION;
    snap.current_channel = PROJECT_BUILD_CHANNEL;
    snap.current_commit = PROJECT_VERSION_COMMIT;
    snap.phase = static_cast<phase_e>(g_runtime.phase.load(std::memory_order_acquire));
    snap.downloaded_bytes = g_runtime.downloaded_bytes.load(std::memory_order_relaxed);
    snap.total_bytes = g_runtime.total_bytes.load(std::memory_order_relaxed);
    snap.last_checked_unix = g_runtime.last_checked_unix.load(std::memory_order_acquire);
    snap.scheduled_on_idle = g_runtime.scheduled_on_idle.load(std::memory_order_relaxed);
    snap.check_in_progress = state.check_in_progress.load(std::memory_order_acquire);

    std::lock_guard lock {g_runtime.mutex};
    snap.available_release = g_runtime.available_release;
    snap.target_asset = g_runtime.target_asset;
    snap.downloaded_dmg_path = g_runtime.downloaded_dmg_path;
    snap.error_code = g_runtime.error_code;
    snap.error_detail = g_runtime.error_detail;
    return snap;
  }

  void start_download(bool auto_install_when_idle) {
#ifdef __APPLE__
    if (platf::is_loginwindow_session()) {
      return;
    }
#endif
    bool expected = false;
    if (!g_runtime.operation_in_progress.compare_exchange_strong(expected, true)) {
      if (auto_install_when_idle) {
        g_runtime.scheduled_on_idle.store(true, std::memory_order_relaxed);
      }
      return;
    }

    if (auto_install_when_idle) {
      g_runtime.scheduled_on_idle.store(true, std::memory_order_relaxed);
    }

    std::thread([auto_install_when_idle]() {
      auto op_guard = util::fail_guard([]() {
        g_runtime.operation_in_progress.store(false, std::memory_order_release);
      });

      std::string dmg_path;
      std::string err_code;
      std::string err_detail;
      if (!perform_download_locked_target(dmg_path, err_code, err_detail)) {
        std::lock_guard lock {g_runtime.mutex};
        if (err_code == "cancelled") {
          g_runtime.downloaded_bytes.store(0, std::memory_order_relaxed);
          g_runtime.error_code.clear();
          g_runtime.error_detail.clear();
          g_runtime.phase.store(static_cast<int>(phase_e::available), std::memory_order_release);
        } else {
          g_runtime.error_code = err_code;
          g_runtime.error_detail = err_detail;
          g_runtime.scheduled_on_idle.store(false, std::memory_order_relaxed);
          g_runtime.phase.store(static_cast<int>(phase_e::error), std::memory_order_release);
        }
        return;
      }

      op_guard.disable();
      g_runtime.operation_in_progress.store(false, std::memory_order_release);

      const bool scheduled = g_runtime.scheduled_on_idle.load(std::memory_order_relaxed);
      if ((auto_install_when_idle || scheduled) && is_host_idle_for_install(scheduled && !auto_install_when_idle)) {
        start_install_now(false);
      }
    }).detach();
  }

  void cancel_download() {
    g_runtime.cancel_requested.store(true, std::memory_order_relaxed);
    g_runtime.scheduled_on_idle.store(false, std::memory_order_relaxed);
  }

  void start_install_now(bool reopen_settings_ui) {
#ifdef __APPLE__
    if (platf::is_loginwindow_session()) {
      return;
    }
#endif
    bool expected = false;
    if (!g_runtime.operation_in_progress.compare_exchange_strong(expected, true)) {
      return;
    }
    std::thread([reopen_settings_ui]() {
      run_install_pipeline(reopen_settings_ui);
    }).detach();
  }

  void schedule_install_on_idle(bool enabled) {
    g_runtime.scheduled_on_idle.store(enabled, std::memory_order_relaxed);
    if (!enabled) {
      return;
    }
    const auto cur_phase = static_cast<phase_e>(g_runtime.phase.load(std::memory_order_acquire));
    if (cur_phase == phase_e::available || cur_phase == phase_e::error) {
      start_download(false);
    } else if (cur_phase == phase_e::downloaded && is_host_idle_for_install(true)) {
      start_install_now(false);
    }
  }

  void on_policy_changed(bool rescan) {
    if (rescan) {
      trigger_check(true);
      return;
    }
    bool auto_check = false;
    bool auto_download = false;
    bool auto_install = false;
    {
      auto read_gate = config::acquire_apply_read_gate();
      auto_check = config::sunshine.update_check_interval_seconds > 0;
      auto_download = config::sunshine.auto_download_updates;
      auto_install = config::sunshine.auto_install_updates;
    }
    const auto cur_phase = static_cast<phase_e>(g_runtime.phase.load(std::memory_order_acquire));
    if (auto_check && auto_download && cur_phase == phase_e::available && rtsp_stream::session_count() == 0) {
      start_download(auto_install);
    }
  }

  void trigger_check(bool force) {
    if (g_runtime.operation_in_progress.load(std::memory_order_acquire)) {
      BOOST_LOG(info) << "Update check trigger skipped: download or installation is in progress"sv;
      return;
    }
    bool expected = false;
    if (!state.check_in_progress.compare_exchange_strong(expected, true)) {
      BOOST_LOG(info) << "Update check trigger skipped: another check is in progress (force="sv << (force ? "true"sv : "false"sv) << ')';
      return;
    }
    auto trigger_guard = util::fail_guard([]() { state.check_in_progress = false; });
    int interval_secs = 0;
    {
      auto read_gate = config::acquire_apply_read_gate();
      interval_secs = config::sunshine.update_check_interval_seconds;
    }
    if (!force && interval_secs == 0) {
      return;
    }
    if (!force) {
      auto now = std::chrono::steady_clock::now();
      auto since_last = std::chrono::duration_cast<std::chrono::seconds>(now - state.last_check_time);
      if (state.last_check_time.time_since_epoch().count() != 0 && since_last < std::chrono::seconds(interval_secs)) {
        return;
      }
    }
    g_runtime.phase.store(static_cast<int>(phase_e::checking), std::memory_order_release);
    BOOST_LOG(info) << "Update check trigger accepted (force="sv << (force ? "true"sv : "false"sv) << ')';
    std::thread([]() {
      perform_check();
    }).detach();
    trigger_guard.disable();
  }

  void on_stream_started() {
    // Kick a metadata refresh after a small delay if automatic checks are enabled,
    // without auto-downloading or auto-installing during an active stream.
    int interval_secs = 0;
    {
      auto read_gate = config::acquire_apply_read_gate();
      interval_secs = config::sunshine.update_check_interval_seconds;
    }
    if (interval_secs <= 0) {
      return;
    }
    std::thread([]() {
      std::this_thread::sleep_for(3s);
      trigger_check(true);
    }).detach();
  }

  void periodic() {
    const auto cur_phase = static_cast<phase_e>(g_runtime.phase.load(std::memory_order_acquire));
    const bool user_scheduled = g_runtime.scheduled_on_idle.load(std::memory_order_relaxed);
    bool auto_check = false;
    bool auto_download = false;
    bool auto_install = false;
    {
      auto read_gate = config::acquire_apply_read_gate();
      auto_check = config::sunshine.update_check_interval_seconds > 0;
      auto_download = config::sunshine.auto_download_updates;
      auto_install = config::sunshine.auto_install_updates;
    }

    if (cur_phase == phase_e::downloaded) {
      if (user_scheduled && is_host_idle_for_install(true)) {
        start_install_now(false);
        return;
      }
      if (auto_check && auto_download && auto_install && is_host_idle_for_install(false)) {
        start_install_now(false);
        return;
      }
    } else if (cur_phase == phase_e::available && rtsp_stream::session_count() == 0) {
      if (user_scheduled || (auto_check && auto_download)) {
        start_download(auto_install && !user_scheduled);
        return;
      }
    }

    // Only trigger periodic checks if no streaming sessions are active
    if (rtsp_stream::session_count() == 0) {
      trigger_check(false);
    }
  }

  void open_last_notified_release_page() {
    try {
      std::string url;
      {
        std::lock_guard<std::mutex> lock(state.notification_mutex);
        url = state.last_notified_url;
      }
      if (url.empty()) {
        std::lock_guard lock {g_runtime.mutex};
        url = g_runtime.available_release.url;
      }
      if (!url.empty()) {
        platf::open_url(url);
      }
    } catch (...) {
      // swallow errors; opening the URL is best-effort
    }
  }
}  // namespace update
