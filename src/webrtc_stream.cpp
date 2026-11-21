/**
 * @file src/webrtc_stream.cpp
 * @brief Minimal no-op WebRTC stub for the standalone macOS Moonlight/RTSP host.
 */
#include "webrtc_stream.h"

namespace webrtc_stream {
  bool has_active_sessions() {
    return false;
  }

  unsigned int active_session_count() {
    return 0;
  }

  bool has_active_or_pending_sessions() {
    return false;
  }

  bool has_capture_active() {
    return false;
  }

  bool has_teardown_in_progress() {
    return false;
  }

  unsigned int teardown_session_count() {
    return 0;
  }

  std::optional<SessionState> create_session(const SessionOptions &) {
    return std::nullopt;
  }

  std::optional<std::string> ensure_capture_started(const SessionOptions &) {
    return "WebRTC browser streaming is disabled in the standalone macOS host";
  }

  bool close_session(std::string_view) {
    return false;
  }

  std::optional<SessionState> get_session(std::string_view) {
    return std::nullopt;
  }

  std::vector<SessionState> list_sessions() {
    return {};
  }

  void shutdown_all_sessions() {}

  void submit_video_packet(video::packet_raw_t &) {}

  void submit_audio_packet(const audio::buffer_t &) {}

  void submit_video_frame(const std::shared_ptr<platf::img_t> &) {}

  void submit_audio_frame(const std::vector<float> &, int, int, int) {}

  void set_rtsp_sessions_active(bool) {}

  void set_rtsp_capture_config(const video::config_t &, const audio::config_t &) {}

  bool set_remote_offer(std::string_view, const std::string &, const std::string &) {
    return false;
  }

  bool add_ice_candidate(std::string_view, std::string, int, std::string) {
    return false;
  }

  bool set_local_answer(std::string_view, const std::string &, const std::string &) {
    return false;
  }

  bool get_local_answer(std::string_view, std::string &, std::string &) {
    return false;
  }

  bool wait_for_local_answer(std::string_view, std::string &, std::string &, std::chrono::milliseconds) {
    return false;
  }

  std::string get_negotiation_error(std::string_view) {
    return "WebRTC browser streaming is disabled on macOS";
  }

  bool add_local_candidate(std::string_view, std::string, int, std::string) {
    return false;
  }

  std::vector<IceCandidateInfo> get_local_candidates(std::string_view, std::size_t) {
    return {};
  }

  std::string get_server_cert_fingerprint() {
    return {};
  }

  std::string get_server_cert_pem() {
    return {};
  }
}  // namespace webrtc_stream
