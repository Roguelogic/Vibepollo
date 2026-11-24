/**
 * @file src/update.h
 * @brief Declarations for update checking and notification.
 */
#pragma once

// standard includes
#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace update {
  struct asset_info_t {
    std::string name;  ///< Asset filename
    std::string download_url;  ///< Direct download URL
    std::string sha256;  ///< SHA256 hash of the asset
    std::int64_t size;  ///< Size in bytes
    std::string content_type;  ///< MIME type
  };

  struct release_info_t {
    std::string version;  ///< Version tag (e.g., "v1.2.3")
    std::string url;  ///< Release page URL
    std::string name;  ///< Release name/title
    std::string body;  ///< Release body/changelog
    std::string published_at;  ///< Publish date
    bool is_prerelease {false};  ///< Whether this is a prerelease
    std::vector<asset_info_t> assets;  ///< Available binary assets
  };

  enum class phase_e : int {
    idle = 0,
    checking = 1,
    up_to_date = 2,
    available = 3,
    downloading = 4,
    verifying = 5,
    downloaded = 6,
    installing = 7,
    restarting = 8,
    error = 9
  };

  struct status_snapshot_t {
    phase_e phase {phase_e::idle};
    std::string current_version;
    std::string current_channel;
    std::string current_commit;
    release_info_t available_release;
    asset_info_t target_asset;
    std::int64_t downloaded_bytes {0};
    std::int64_t total_bytes {0};
    std::int64_t last_checked_unix {0};
    bool scheduled_on_idle {false};
    bool check_in_progress {false};
    std::string downloaded_dmg_path;
    std::string error_code;
    std::string error_detail;
  };

  struct state_t {
    std::mutex notification_mutex;
    std::vector<std::string> notified_versions;  ///< Persisted notification identities
    std::string last_notified_version;  ///< Version string last notified to user
    std::string last_notified_url;  ///< Release page URL last notified to user
    bool last_notified_is_prerelease {false};  ///< Whether last notification was for a prerelease
    release_info_t latest_release;  ///< Latest stable release info
    release_info_t latest_prerelease;  ///< Latest prerelease info (if enabled)
    std::chrono::steady_clock::time_point last_check_time;  ///< Last time we checked
    std::atomic<bool> check_in_progress {false};  ///< True while a check is running
  };

  extern state_t state;

  /**
   * @brief Trigger an asynchronous update check.
   * Initiates a check for updates if not already running. If force is true, bypasses interval throttling.
   * @param force If true, forces the check regardless of throttling.
   */
  void trigger_check(bool force);

  /**
   * @brief Retrieve a thread-safe snapshot of the Software Update engine state for native/web UI.
   */
  status_snapshot_t get_status_snapshot();

  /**
   * @brief Start downloading the currently available update package in the background.
   * @param auto_install_when_idle If true, schedules automatic installation once idle after download completes.
   */
  void start_download(bool auto_install_when_idle = false);

  /**
   * @brief Cancel an in-progress update package download.
   */
  void cancel_download();

  /**
   * @brief Download (if needed), verify, install the available update, and restart Vibepollo.
   * @param reopen_settings_ui If true, reopens the native Settings window on the Software Update pane after restart.
   */
  void start_install_now(bool reopen_settings_ui = true);

  /**
   * @brief Schedule or cancel automatic update installation when all streaming sessions end.
   */
  void schedule_install_on_idle(bool enabled);

  /**
   * @brief React to live changes in Automatic Updates or Beta Updates preferences.
   * @param rescan If true, immediately triggers a forced update scan on the updated channel.
   */
  void on_policy_changed(bool rescan);

  /**
   * @brief Handle stream start event for update notification.
   * Called when a stream transitions from 0 to 1 clients to schedule a delayed update notification.
   */
  void on_stream_started();

  /**
   * @brief Periodic tick to evaluate update check timing.
   * Called from a task pool or timer to determine if the next update check is due.
   */
  void periodic();

  // Fetch validated metadata for a strictly shaped immutable nightly tag.
  bool download_nightly_metadata(const std::string &tag, std::string &out_json);

  /**
   * @brief Download GitHub release data for a repository.
   * Fetches release data in JSON format for the specified repository.
   * @param owner The GitHub repository owner.
   * @param repo The GitHub repository name.
   * @param out_json Output parameter for the fetched JSON data.
   * @return true on success, false otherwise.
   */
  bool download_github_release_data(const std::string &owner, const std::string &repo, std::string &out_json);

  /**
   * @brief Open the last-notified release page.
   * Callback used by tray notifications to open the release page last notified to the user.
   */
  void open_last_notified_release_page();
}  // namespace update
