/**
 * @file src/platform/macos/virtual_display_remote.mm
 * @brief Remote Monitor per-client virtual display lifecycle and composed topology on macOS.
 */
// standard includes
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

// platform includes
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// local includes
#include "src/config.h"
#include "src/remote_display_topology.h"
#include "src/utility.h"
#include "virtual_display_internal.h"

using namespace std::literals;

namespace platf::macos_virtual_display {
  namespace {
    struct remote_display_t {
      std::unique_ptr<detail::virtual_display_t> display;
      remote_display_topology::mode_t mode;  ///< As requested.
    };

    std::mutex remote_mutex;  ///< Held while displays are created, which takes seconds.
    std::map<std::string, remote_display_t> remote_displays;  ///< By client UUID.

    // The displays' IDs, for lookups from input and capture that mustn't wait on remote_mutex.
    std::mutex remote_ids_mutex;
    std::vector<CGDirectDisplayID> remote_ids;
    std::vector<CGDirectDisplayID> remote_hdr_ids;
    std::atomic<bool> has_remote_displays_flag {false};
    int remote_displays_pending = 0;  ///< Remote Monitor displays being made, not yet in remote_ids.

    // Call with remote_mutex held.
    void publish_remote_ids() {
      std::vector<CGDirectDisplayID> ids;
      std::vector<CGDirectDisplayID> hdr_ids;
      for (const auto &[_, remote] : remote_displays) {
        if (remote.display) {
          ids.push_back(remote.display->id);
          if (remote.display->hdr) {
            hdr_ids.push_back(remote.display->id);
          }
        }
      }
      std::lock_guard lock {remote_ids_mutex};
      has_remote_displays_flag.store(!ids.empty(), std::memory_order_release);
      remote_ids = std::move(ids);
      remote_hdr_ids = std::move(hdr_ids);
    }

    // A serial per client (FNV-1a of its UUID), so macOS remembers each Remote Monitor's settings.
    unsigned int remote_serial(const std::string &client_uuid) {
      std::uint32_t hash = 2166136261u;
      for (const unsigned char c : client_uuid) {
        hash = (hash ^ c) * 16777619u;
      }
      return hash == detail::serial_number ? hash + 1 : hash;
    }

    int current_refresh_hz(const CGDirectDisplayID id) {
      const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id);
      const double refresh = mode ? CGDisplayModeGetRefreshRate(mode) : 0;
      if (mode) {
        CGDisplayModeRelease(mode);
      }
      // Built-in and virtual displays can report 0.
      return refresh > 0 ? static_cast<int>(std::lround(refresh)) : 60;
    }

    std::string display_label(const CGDirectDisplayID id) {
      for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number.unsignedIntValue == id) {
          if (NSString *loc = screen.localizedName; loc && loc.UTF8String) {
            return loc.UTF8String;
          }
        }
      }
      return "Display "s + std::to_string(id);
    }
  }  // namespace

  namespace detail {
    bool append_remote_keep_on(std::vector<CGDirectDisplayID> &keep_on) {
      std::lock_guard lock {remote_ids_mutex};
      keep_on.insert(keep_on.end(), remote_ids.begin(), remote_ids.end());
      return remote_displays_pending > 0;
    }

    bool is_remote_hdr_display(const CGDirectDisplayID id) {
      std::lock_guard lock {remote_ids_mutex};
      return std::find(remote_hdr_ids.begin(), remote_hdr_ids.end(), id) != remote_hdr_ids.end();
    }

    void reconcile_remote_displays(const bool displays_changed) {
      std::lock_guard lock {remote_mutex};
      for (auto &[_, remote] : remote_displays) {
        if (remote.display) {
          ensure_not_mirrored(remote.display->id);
          if (displays_changed) {
            keep_created_mode(*remote.display);
          } else if (is_active(remote.display->id)) {
            sync_recorded_mode(*remote.display);
          }
        }
      }
    }

    bool reapply_scale_to_remote_displays(const int configured_scale) {
      bool backing_pixels_changed = false;
      std::lock_guard lock {remote_mutex};
      for (auto &[_, remote] : remote_displays) {
        if (remote.display) {
          backing_pixels_changed |= reapply_scale_to_display(*remote.display, configured_scale);
        }
      }
      return backing_pixels_changed;
    }
  }  // namespace detail

  bool remote_create_or_reclaim(const std::string &client_uuid, const std::string &client_label, const remote_display_topology::mode_t &mode) {
    std::lock_guard lock {remote_mutex};
    auto &remote = remote_displays[client_uuid];
    if (remote.display && detail::is_active(remote.display->id) && remote.mode.width == mode.width && remote.mode.height == mode.height && remote.mode.refresh_hz == mode.refresh_hz && remote.mode.hdr == mode.hdr) {
      return true;
    }

    // Until it's published, the exclusive layout leaves displays it hasn't seen before alone: the
    // new display could be taken for a physical one. Once it is, the layout is enforced again.
    {
      std::lock_guard ids_lock {remote_ids_mutex};
      ++remote_displays_pending;
    }
    const auto published = util::fail_guard([]() {
      {
        std::lock_guard ids_lock {remote_ids_mutex};
        --remote_displays_pending;
      }
      detail::request_exclusive_enforcement();
    });

    // A new mode gets a new display: two at once with the same serial would confuse macOS.
    remote.display.reset();
    publish_remote_ids();
    NSString *name = client_label.empty() ? @PROJECT_NAME " Remote Monitor" : @(client_label.c_str());
    remote.display = detail::make_display(name, remote_serial(client_uuid), mode.width, mode.height, mode.refresh_hz, mode.hdr);
    if (!remote.display) {
      remote_displays.erase(client_uuid);
      return false;
    }
    remote.mode = mode;
    publish_remote_ids();
    return true;
  }

  std::optional<std::pair<int, int>> remote_layout_size(const std::string &, const remote_display_topology::mode_t &mode) {
    // Desktop coordinates are in points; match the exact scale geometry make_display() applies.
    const unsigned int base_w = std::max(2u, static_cast<unsigned int>(std::max(2, mode.width)) & ~1u);
    const unsigned int base_h = std::max(2u, static_cast<unsigned int>(std::max(2, mode.height)) & ~1u);
    const double headroom_factor = std::min({1.6, 7680.0 / base_w, 4320.0 / base_h});
    const unsigned int max_pixel_width = std::max(base_w, detail::round_even(base_w * std::max(1.0, headroom_factor)));
    const unsigned int max_pixel_height = std::max(base_h, detail::round_even(base_h * std::max(1.0, headroom_factor)));
    const auto geom = detail::compute_scale_geometry(
      mode.width,
      mode.height,
      max_pixel_width,
      max_pixel_height,
      config::video.dd.virtual_display_scale_percent
    );
    return std::pair {static_cast<int>(geom.mode_width), static_cast<int>(geom.mode_height)};
  }

  void remote_resolve_mode(const std::string &, remote_display_topology::mode_t &mode) {
    mode.hdr = mode.hdr && detail::can_make_hdr();
  }

  bool remote_apply_composed_topology(const std::vector<remote_display_topology::node_t> &composed) {
    std::lock_guard lock {remote_mutex};
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
      return false;
    }
    for (const auto &node : composed) {
      CGDirectDisplayID id = kCGNullDirectDisplay;
      if (node.preexisting) {
        id = static_cast<CGDirectDisplayID>(std::strtoul(node.device_id.c_str(), nullptr, 10));
      } else if (const auto remote = remote_displays.find(node.id); remote != remote_displays.end() && remote->second.display) {
        id = remote->second.display->id;
      }
      if (node.active && id != kCGNullDirectDisplay && detail::is_active(id)) {
        CGConfigureDisplayOrigin(config, id, node.x, node.y);
      }
    }
    // Like the game's virtual display, the arrangement lasts only while Vibepollo runs.
    return CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) == kCGErrorSuccess;
  }

  std::optional<std::string> remote_exact_capture_output(const std::string &client_uuid, const remote_display_topology::mode_t &) {
    std::lock_guard lock {remote_mutex};
    const auto remote = remote_displays.find(client_uuid);
    if (remote == remote_displays.end() || !remote->second.display || !detail::is_active(remote->second.display->id)) {
      return std::nullopt;
    }
    // Ready once the display is online in the mode it was created with; macOS offers no other.
    const auto id = remote->second.display->id;
    if (detail::current_pixels(id) != std::pair {remote->second.display->pixel_width, remote->second.display->pixel_height}) {
      return std::nullopt;
    }
    // platf::display_names() names displays by their ID.
    return std::to_string(id);
  }

  bool remote_remove_owned_display(const std::string &client_uuid) {
    std::lock_guard lock {remote_mutex};
    remote_displays.erase(client_uuid);
    publish_remote_ids();
    return true;
  }

  std::vector<remote_display_topology::node_t> remote_baseline() {
    std::vector<remote_display_topology::node_t> baseline;
    const CGDirectDisplayID stream_id = detail::current_display_id();
    for (const auto id : detail::display_list(CGGetActiveDisplayList)) {
      if (is_remote_display(id)) {
        continue;
      }
      const CGRect bounds = CGDisplayBounds(id);
      const auto [pixel_width, pixel_height] = detail::current_pixels(id);
      remote_display_topology::node_t node;
      node.id = node.device_id = std::to_string(id);
      node.label = display_label(id);
      node.preexisting = true;
      node.physical = id != stream_id;
      node.active = true;
      node.primary = CGDisplayIsMain(id);
      // Desktop coordinates are in points, while modes are in pixels.
      node.x = static_cast<int>(bounds.origin.x);
      node.y = static_cast<int>(bounds.origin.y);
      node.configured_mode = {
        .width = static_cast<int>(pixel_width),
        .height = static_cast<int>(pixel_height),
        .refresh_hz = current_refresh_hz(id),
      };
      node.layout_width = static_cast<int>(bounds.size.width);
      node.layout_height = static_cast<int>(bounds.size.height);
      baseline.push_back(std::move(node));
    }
    return baseline;
  }

  bool is_remote_display(const std::uint32_t display_id) {
    if (!has_remote_displays_flag.load(std::memory_order_acquire)) {
      return false;
    }
    std::lock_guard lock {remote_ids_mutex};
    return std::find(remote_ids.begin(), remote_ids.end(), display_id) != remote_ids.end();
  }

  bool has_remote_displays() {
    return has_remote_displays_flag.load(std::memory_order_acquire);
  }
}  // namespace platf::macos_virtual_display
