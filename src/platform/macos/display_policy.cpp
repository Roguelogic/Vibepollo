/**
 * @file src/platform/macos/display_policy.cpp
 * @brief Definitions for the CoreGraphics-independent display decisions.
 */
// standard includes
#include <algorithm>
#include <charconv>
#include <cmath>
#include <system_error>
#include <utility>

// local includes
#include "display_policy.h"

namespace platf::macos_display_policy {
  namespace {
    bool contains(const std::vector<display_id_t> &ids, const display_id_t id) {
      return std::find(ids.begin(), ids.end(), id) != ids.end();
    }
  }  // namespace

  lid_close_plan_t plan_lid_close(const bool end_streams_on_lid_close, const std::vector<stream_role_e> &streams, const bool app_running) {
    lid_close_plan_t plan;
    if (!end_streams_on_lid_close || streams.empty()) {
      return plan;
    }
    // The app's own streams end as when it exits; Remote Monitor and Remote Input streams outlive
    // it, so they're ended directly.
    plan.quit_app = app_running;
    for (std::size_t i = 0; i < streams.size(); ++i) {
      if (!app_running || streams[i] == stream_role_e::remote) {
        plan.end_streams.push_back(i);
      }
    }
    return plan;
  }

  exclusive_plan_t plan_exclusive_layout(const std::vector<display_id_t> &active, const std::vector<display_id_t> &keep_on, const std::vector<display_id_t> &tracked, const bool defer_untracked) {
    exclusive_plan_t plan;
    for (const auto id : active) {
      if (contains(keep_on, id) || contains(plan.turn_off, id)) {
        continue;
      }
      const bool untracked = !contains(tracked, id);
      if (untracked && defer_untracked) {
        continue;
      }
      plan.turn_off.push_back(id);
      if (untracked) {
        plan.newly_tracked.push_back(id);
      }
    }
    return plan;
  }

  cover_result_e cover_and_turn_off(const safeguard_ops_t &ops, restore_helper_t &helper, const std::vector<display_id_t> &previously_covered, const std::vector<display_id_t> &covered, const std::vector<display_id_t> &turn_off) {
    // Put the marker back as it was: it may now be partly written. If that fails too, it lists
    // displays that are already on, which the next launch skips.
    const auto restore_marker = [&]() {
      if (previously_covered.empty()) {
        ops.remove_marker();
      } else {
        (void) ops.write_marker(previously_covered);
      }
    };

    if (!ops.write_marker(covered)) {
      restore_marker();
      return cover_result_e::safeguards_failed;
    }
    auto next = ops.start_helper(covered);
    if (!next.running()) {
      restore_marker();
      return cover_result_e::safeguards_failed;
    }
    if (!ops.turn_off(turn_off)) {
      // Nothing more is off, so the current helper still covers everything.
      ops.stop_helper(next, true);
      restore_marker();
      return cover_result_e::turn_off_failed;
    }
    auto previous = std::exchange(helper, next);
    if (previous.running()) {
      ops.stop_helper(previous, true);
    }
    return cover_result_e::turned_off;
  }

  display_size_t virtual_display_size(const int width, const int height, const bool hidpi) {
    display_size_t size;
    size.width = hidpi ? width / 2 : width;
    size.height = hidpi ? height / 2 : height;
    size.pixel_width = hidpi ? size.width * 2 : size.width;
    size.pixel_height = hidpi ? size.height * 2 : size.height;
    return size;
  }

  bool supports_hidpi_mode(const int pixel_width, const int pixel_height) {
    if (pixel_width <= 0 || pixel_height <= 0) {
      return false;
    }
    const int short_points = std::min(pixel_width / 2, pixel_height / 2);
    return short_points >= minimum_hidpi_short_axis_points;
  }

  physical_size_mm_t virtual_display_physical_size_mm(const int width, const int height, const bool hidpi) {
    const int base_w = std::max(2, width & ~1);
    const int base_h = std::max(2, height & ~1);
    const double ppi = hidpi ? 220.0 : 110.0;
    double w_mm = (static_cast<double>(base_w) / ppi) * 25.4;
    double h_mm = (static_cast<double>(base_h) / ppi) * 25.4;

    const double min_w_mm = (base_w >= base_h) ? 208.0 : 175.0;
    if (w_mm < min_w_mm && w_mm > 0.0) {
      const double scale = min_w_mm / w_mm;
      w_mm *= scale;
      h_mm *= scale;
    }

    // macOS 26.1 refuses virtual displays whose declared area is under ~160 cm^2 (16,000 mm^2)
    // when reserving > 2,000 px per axis. Keep a comfortable 180 cm^2 floor.
    constexpr double min_area_mm2 = 18000.0;
    const double area = w_mm * h_mm;
    if (area < min_area_mm2 && area > 0.0) {
      const double scale = std::sqrt(min_area_mm2 / area);
      w_mm *= scale;
      h_mm *= scale;
    }

    return {w_mm, h_mm};
  }

  std::optional<bootstrap_size_t> virtual_display_bootstrap_size(const int width, const int height) {
    if (width <= 0 || height <= 0) {
      return std::nullopt;
    }
    constexpr int max_long_edge = 3200;
    constexpr int max_short_edge = 1800;
    const bool landscape = width >= height;
    const int limit_w = landscape ? max_long_edge : max_short_edge;
    const int limit_h = landscape ? max_short_edge : max_long_edge;
    if (width <= limit_w && height <= limit_h) {
      return std::nullopt;
    }
    const double scale = std::min(
      static_cast<double>(limit_w) / static_cast<double>(width),
      static_cast<double>(limit_h) / static_cast<double>(height)
    );
    const int boot_w = std::max(2, static_cast<int>(std::floor(width * scale)) & ~1);
    const int boot_h = std::max(2, static_cast<int>(std::floor(height * scale)) & ~1);
    return bootstrap_size_t {boot_w, boot_h};
  }

  display_identity_t offset_display_identity(const std::uint32_t base_product_id, const std::uint32_t base_serial, const std::uint32_t offset) {
    const std::uint32_t next_product = base_product_id + offset;
    std::uint32_t next_serial = base_serial + offset;
    if (next_serial == 0) {
      next_serial = 1;
    }
    return {next_product, next_serial};
  }

  bool display_rect_t::approximately_equal(const display_rect_t &other, const double tolerance) const {
    return std::abs(x - other.x) <= tolerance &&
           std::abs(y - other.y) <= tolerance &&
           std::abs(width - other.width) <= tolerance &&
           std::abs(height - other.height) <= tolerance;
  }

  capture_source_check_t::capture_source_check_t(const clock::duration tolerance):
      tolerance {tolerance} {
  }

  bool capture_source_check_t::mismatched(const display_rect_t &screen_rect, const display_rect_t &expected, const clock::time_point now) {
    if (screen_rect.empty() || expected.empty() || screen_rect.approximately_equal(expected)) {
      mismatch_since.reset();
      return false;
    }
    if (!mismatch_since) {
      mismatch_since = now;
      return false;
    }
    if (now - *mismatch_since < tolerance) {
      return false;
    }
    mismatch_since.reset();
    return true;
  }

  void capture_source_check_t::reset() {
    mismatch_since.reset();
  }

  std::optional<display_id_t> parse_display_identity(const std::string_view output_name) {
    display_id_t id = 0;
    const auto end = output_name.data() + output_name.size();
    const auto [last, error] = std::from_chars(output_name.data(), end, id);
    if (output_name.empty() || error != std::errc {} || last != end || id == 0) {
      return std::nullopt;
    }
    return id;
  }

  display_id_t pointer_display(const std::optional<display_id_t> stream_display, const std::function<bool(display_id_t)> &is_remote_display, const display_id_t streamed_display) {
    if (stream_display && is_remote_display(*stream_display)) {
      return *stream_display;
    }
    return streamed_display;
  }

  attempt_budget_t::attempt_budget_t(const std::size_t limit, const clock::duration window):
      limit {limit},
      window {window} {
  }

  bool attempt_budget_t::try_spend(const clock::time_point now) {
    while (!attempts.empty() && now - attempts.front() >= window) {
      attempts.pop_front();
    }
    if (attempts.size() >= limit) {
      return false;
    }
    attempts.push_back(now);
    return true;
  }

  void attempt_budget_t::reset() {
    attempts.clear();
  }

  display_presence_t::display_presence_t(const clock::duration grace):
      grace {grace} {
  }

  bool display_presence_t::lost(const bool online, const clock::time_point now) {
    if (online) {
      offline_since.reset();
      return false;
    }
    if (!offline_since) {
      offline_since = now;
    }
    return now - *offline_since >= grace;
  }
}  // namespace platf::macos_display_policy
