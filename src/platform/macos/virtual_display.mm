/**
 * @file src/platform/macos/virtual_display.mm
 * @brief Core per-client virtual display lifecycle, scaling, layout, and reconfiguration watcher for macOS.
 *
 * macOS has no public API for virtual displays, so this uses the private CGVirtualDisplay classes
 * (as BetterDisplay, DeskPad, and Chromium's tests do), and the private CGSConfigureDisplayEnabled
 * to turn physical displays off for the exclusive layout. Both are looked up at runtime, so if a
 * macOS release removes them, streams fall back to the physical display instead of failing.
 *
 * Display configuration and display-mode queries only work in a process with an AppKit session,
 * which main() provides by running the AppKit event loop on the main thread.
 *
 * Related modules:
 *  - virtual_display_watchdog.mm: physical display power/mode safeguards, crash-restore helper, marker recovery.
 *  - virtual_display_remote.mm: Remote Monitor per-client displays and composed topology.
 */
// standard includes
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

// platform includes
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// local includes
#include "display_policy.h"
#include "misc.h"
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/video.h"
#include "virtual_display_internal.h"

using namespace std::literals;

namespace platf::macos_virtual_display {
  namespace {
    // If macOS persists a hostile/unusable state for a (vendor, product, serial) identity (for
    // example after system "Stop Extending"), remember the working offset so reconnects skip it.
    std::mutex identity_offsets_mutex;
    std::map<unsigned int, unsigned int> identity_offsets;

    std::mutex state_mutex;
    std::unique_ptr<detail::virtual_display_t> current;
    int current_users = 0;
    std::atomic<CGDirectDisplayID> current_id {kCGNullDirectDisplay};
    std::atomic<bool> current_hdr {false};

    // Changes arrive in bursts (a reopened lid adds a display, then macOS rearranges and picks modes),
    // so wait for them to stop before acting.
    constexpr auto settle_delay = 750ms;

    std::atomic<std::uint64_t> change_generation {0};
    std::atomic<std::uint64_t> settled_generation {0};
    std::atomic<std::uint32_t> pending_flags {0};
    std::atomic<std::uint64_t> scale_reinit_counter {0};

    // Off the main thread: the callback arrives there, and the work below can wait seconds for
    // displays, during which the event loop the display configuration depends on must keep running.
    dispatch_queue_t reconcile_queue() {
      static dispatch_queue_t queue = dispatch_queue_create("dev.vibepollo.display-changes", DISPATCH_QUEUE_SERIAL);
      return queue;
    }

    /**
     * @brief Whether a display is one of Vibepollo's own virtual displays.
     * @details They carry Vibepollo's vendor and product from the moment macOS makes them, so a
     *          Remote Monitor that's still coming online is never taken for a physical display.
     */
    bool is_own_display(const CGDirectDisplayID id) {
      return CGDisplayVendorNumber(id) == detail::vendor_id && CGDisplayModelNumber(id) == detail::product_id;
    }

    std::pair<std::vector<CGDirectDisplayID>, bool> exclusive_keep_on(const CGDirectDisplayID stream_display, const std::vector<CGDirectDisplayID> &candidates) {
      std::vector<CGDirectDisplayID> keep_on {stream_display};
      for (const auto id : candidates) {
        if (is_own_display(id)) {
          keep_on.push_back(id);
        }
      }
      const bool pending = detail::append_remote_keep_on(keep_on);
      return {std::move(keep_on), pending};
    }

    bool turn_off_other_displays(detail::virtual_display_t &display) {
      if (!detail::has_configure_display_enabled()) {
        return false;
      }

      const auto online = detail::display_list(CGGetOnlineDisplayList);
      const auto [keep_on, pending] = exclusive_keep_on(display.id, online);
      auto others = macos_display_policy::plan_exclusive_layout(online, keep_on, {}, pending).turn_off;
      if (others.empty()) {
        // Such as a MacBook with its lid closed, or while a Remote Monitor is still being made:
        // displays that come on later are turned off then.
        display.exclusive = true;
        return true;
      }

      // Safeguards first: macOS won't turn these back on if Vibepollo dies.
      display.turned_off_modes = std::make_unique<detail::saved_modes_t>();
      if (macos_display_policy::cover_and_turn_off(detail::safeguard_ops(), display.watchdog, {}, others, others) != macos_display_policy::cover_result_e::turned_off) {
        return false;
      }
      display.exclusive = true;
      display.turned_off = std::move(others);
      // Let the desktop settle before capture starts: a capture set up while displays are still
      // going away can get no frames at all.
      detail::wait_until([&display]() {
        return CGDisplayIsMain(display.id) && std::none_of(display.turned_off.begin(), display.turned_off.end(), detail::is_active);
      },
                         5s);
      return true;
    }

    void log_if_unit_number_clashes(const CGDirectDisplayID id) {
      if (id == kCGNullDirectDisplay) {
        return;
      }
      const std::uint32_t unit = CGDisplayUnitNumber(id);
      if (unit == UINT32_MAX) {
        return;
      }
      for (const auto other : detail::display_list(CGGetOnlineDisplayList)) {
        if (other != id && CGDisplayUnitNumber(other) == unit) {
          BOOST_LOG(warning) << "Virtual display: display "sv << id << " shares CGDisplayUnitNumber "sv << unit
                             << " with online display "sv << other << "; capture source verification will reattach if macOS cross-binds them"sv;
          return;
        }
      }
    }

    void make_main(const CGDirectDisplayID id) {
      // The display at (0, 0) is the main one; keep the others to its right in their current order.
      const auto others = detail::display_list(CGGetActiveDisplayList);
      double min_x = 0;
      for (const auto other : others) {
        if (other != id) {
          min_x = std::min(min_x, CGDisplayBounds(other).origin.x);
        }
      }
      const double shift = CGDisplayBounds(id).size.width - min_x;

      CGDisplayConfigRef config;
      if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return;
      }
      CGConfigureDisplayOrigin(config, id, 0, 0);
      for (const auto other : others) {
        if (other != id) {
          const CGRect bounds = CGDisplayBounds(other);
          CGConfigureDisplayOrigin(config, other, static_cast<int32_t>(bounds.origin.x + shift), static_cast<int32_t>(bounds.origin.y));
        }
      }
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }

    void apply_layout(detail::virtual_display_t &display) {
      using layout_e = config::video_t::virtual_display_layout_e;
      const auto layout = config::video.virtual_display_layout;

      if (layout == layout_e::exclusive) {
        if (turn_off_other_displays(display)) {
          return;
        }
        BOOST_LOG(warning) << "Virtual display: couldn't turn off the other displays; making it the main display instead"sv;
      }
      // macOS keeps displays adjacent, so the isolated layouts behave like their plain versions.
      if (layout == layout_e::extended || layout == layout_e::extended_isolated) {
        return;
      }
      make_main(display.id);
    }

    // With HiDPI, macOS exposes both 1x and 2x variants at the same backing pixel size, so match
    // both logical point dimensions and backing pixel dimensions first, preferring the requested refresh rate.
    void select_mode(const CGDirectDisplayID id, const size_t mode_width, const size_t mode_height, const size_t pixel_width, const size_t pixel_height, const double target_refresh = 0.0) {
      NSDictionary *options = @{(__bridge NSString *) kCGDisplayShowDuplicateLowResolutionModes: @YES};
      CGDisplayModeRef chosen = nullptr;
      const auto refresh_matches = [target_refresh](const CGDisplayModeRef mode) {
        if (target_refresh <= 0.0) {
          return true;
        }
        const double hz = CGDisplayModeGetRefreshRate(mode);
        return hz > 0.0 && std::abs(hz - target_refresh) < 0.5;
      };
      detail::wait_until([&]() {
        const CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (__bridge CFDictionaryRef) options);
        if (!modes) {
          return false;
        }
        const CFIndex count = CFArrayGetCount(modes);
        if (target_refresh > 0.0) {
          for (CFIndex i = 0; i < count && !chosen; ++i) {
            const auto mode = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);
            if (CGDisplayModeGetWidth(mode) == mode_width && CGDisplayModeGetHeight(mode) == mode_height &&
                CGDisplayModeGetPixelWidth(mode) == pixel_width && CGDisplayModeGetPixelHeight(mode) == pixel_height &&
                refresh_matches(mode)) {
              chosen = CGDisplayModeRetain(mode);
            }
          }
        }
        for (CFIndex i = 0; i < count && !chosen; ++i) {
          const auto mode = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);
          if (CGDisplayModeGetWidth(mode) == mode_width && CGDisplayModeGetHeight(mode) == mode_height &&
              CGDisplayModeGetPixelWidth(mode) == pixel_width && CGDisplayModeGetPixelHeight(mode) == pixel_height) {
            chosen = CGDisplayModeRetain(mode);
          }
        }
        if (target_refresh > 0.0) {
          for (CFIndex i = 0; i < count && !chosen; ++i) {
            const auto mode = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);
            if (CGDisplayModeGetPixelWidth(mode) == pixel_width && CGDisplayModeGetPixelHeight(mode) == pixel_height &&
                refresh_matches(mode)) {
              chosen = CGDisplayModeRetain(mode);
            }
          }
        }
        for (CFIndex i = 0; i < count && !chosen; ++i) {
          const auto mode = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);
          if (CGDisplayModeGetPixelWidth(mode) == pixel_width && CGDisplayModeGetPixelHeight(mode) == pixel_height) {
            chosen = CGDisplayModeRetain(mode);
          }
        }
        CFRelease(modes);
        return chosen != nullptr;
      },
                         3s);

      if (!chosen) {
        BOOST_LOG(warning) << "Virtual display: no "sv << pixel_width << 'x' << pixel_height << " mode; using macOS's default"sv;
        return;
      }
      CGDisplayConfigRef config;
      if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
        CGConfigureDisplayWithDisplayMode(config, id, chosen, nullptr);
        CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
      }
      CGDisplayModeRelease(chosen);
    }

    void ensure_retina_mode(detail::virtual_display_t &display) {
      if (!detail::is_active(display.id)) {
        detail::sync_recorded_mode(display);
        return;
      }
      if (!display.hidpi) {
        if (display.explicit_scale && display.default_mode_width > 0 && display.default_pixel_width > 0) {
          select_mode(display.id, display.default_mode_width, display.default_mode_height, display.default_pixel_width, display.default_pixel_height, display.refresh);
        }
        detail::sync_recorded_mode(display);
        return;
      }
      if (display.explicit_scale) {
        select_mode(display.id, display.default_mode_width, display.default_mode_height, display.default_pixel_width, display.default_pixel_height, display.refresh);
        detail::sync_recorded_mode(display);
        return;
      }
      const CGDisplayModeRef cur = CGDisplayCopyDisplayMode(display.id);
      const double cur_hz = cur ? CGDisplayModeGetRefreshRate(cur) : 0.0;
      const bool refresh_ok = display.refresh <= 0.0 || cur_hz <= 0.0 || std::abs(cur_hz - display.refresh) < 0.5;
      const bool already_retina = cur &&
                                  CGDisplayModeGetWidth(cur) >= 800 &&
                                  CGDisplayModeGetPixelWidth(cur) == CGDisplayModeGetWidth(cur) * 2 &&
                                  CGDisplayModeGetPixelHeight(cur) == CGDisplayModeGetHeight(cur) * 2 &&
                                  refresh_ok;
      if (cur) {
        CGDisplayModeRelease(cur);
      }
      if (!already_retina) {
        select_mode(display.id, display.default_mode_width, display.default_mode_height, display.default_pixel_width, display.default_pixel_height, display.refresh);
      }
      detail::sync_recorded_mode(display);
    }

    bool apply_virtual_display_settings(
      CGVirtualDisplay *display,
      const int width,
      const int height,
      const unsigned int max_pixels_wide,
      const unsigned int max_pixels_high,
      const double refresh,
      const bool make_hdr,
      const detail::scale_geometry_t &geom
    ) {
      const Class settings_class = NSClassFromString(@"CGVirtualDisplaySettings");
      const Class mode_class = NSClassFromString(@"CGVirtualDisplayMode");
      if (!display || !settings_class || !mode_class) {
        return false;
      }

      CGVirtualDisplaySettings *settings = [[settings_class alloc] init];
      settings.hiDPI = geom.hidpi ? 1 : 0;
      NSMutableArray *modes = [NSMutableArray array];
      std::vector<std::pair<unsigned int, unsigned int>> added_dims;
      const auto add_mode = [&](const unsigned int w, const unsigned int h) {
        if (w == 0 || h == 0 || w > max_pixels_wide || h > max_pixels_high) {
          return;
        }
        if (std::find(added_dims.begin(), added_dims.end(), std::pair {w, h}) != added_dims.end()) {
          return;
        }
        added_dims.emplace_back(w, h);
        CGVirtualDisplayMode *m = make_hdr ?
                                    [[mode_class alloc] initWithWidth:w height:h refreshRate:refresh transferFunction:detail::hdr_transfer_function] :
                                    [[mode_class alloc] initWithWidth:w height:h refreshRate:refresh];
        if (m) {
          [modes addObject:m];
        }
      };

      const auto base_size = macos_display_policy::virtual_display_size(width, height, geom.hidpi);
      if (geom.hidpi) {
        add_mode(base_size.pixel_width, base_size.pixel_height);
        add_mode(base_size.width, base_size.height);
        add_mode(geom.pixel_width, geom.pixel_height);
        add_mode(geom.mode_width, geom.mode_height);
        constexpr double scale_factors[] = {1.25, 1.50, 1.75, 2.15, 2.25, 2.3888889, 2.50, 2.6875, 3.00};
        for (const double factor : scale_factors) {
          const unsigned int lw = detail::round_even(base_size.pixel_width / factor);
          const unsigned int lh = detail::round_even(static_cast<double>(lw) * base_size.pixel_height / base_size.pixel_width);
          if (lw >= 640 && lh >= 480 && lw * 2 <= max_pixels_wide && lh * 2 <= max_pixels_high) {
            add_mode(lw * 2, lh * 2);
            add_mode(lw, lh);
          }
        }
      } else {
        add_mode(geom.pixel_width, geom.pixel_height);
      }

      settings.modes = modes;
      return [display applySettings:settings] == YES;
    }

    std::unique_ptr<detail::virtual_display_t> create(const video::config_t &config) {
      const double refresh = config.framerateX100 > 0 ? config.framerateX100 / 100.0 : config.framerate;
      const bool hdr = config.dynamicRange > 0 && !config.prefer_sdr_10bit && !config.force_sdr;
      const bool exclusive_layout = (config::video.virtual_display_layout == config::video_t::virtual_display_layout_e::exclusive);
      auto result = detail::make_display(@PROJECT_NAME, detail::serial_number, config.width, config.height, refresh, hdr, exclusive_layout);
      if (!result) {
        BOOST_LOG(warning) << "Virtual display: streaming the physical display instead"sv;
        return nullptr;
      }
      result->width = config.width;
      result->height = config.height;
      result->refresh = refresh;
      apply_layout(*result);
      detail::ensure_not_mirrored(result->id);
      // Turning off physical displays activates macOS's single-display profile, which may default
      // back to 1x non-Retina; re-verify and enforce Retina HiDPI after layout settles.
      ensure_retina_mode(*result);
      if (!result->turned_off.empty()) {
        BOOST_LOG(info) << "Virtual display: physical displays turned off (active mode: looks like "sv
                        << result->mode_width << 'x' << result->mode_height << ", pixels "sv
                        << result->pixel_width << 'x' << result->pixel_height << ')';
      }
      return result;
    }

    void release() {
      std::lock_guard lock {state_mutex};
      if (--current_users > 0) {
        return;
      }
      current_id = kCGNullDirectDisplay;
      current_hdr = false;
      current.reset();
    }

    dispatch_queue_t hold_timer_queue() {
      static dispatch_queue_t q = dispatch_queue_create("dev.vibepollo.virtual-display.hold", DISPATCH_QUEUE_SERIAL);
      return q;
    }

    void cancel_timer_locked(__strong dispatch_source_t &timer) {
      if (timer != nil) {
        dispatch_source_cancel(timer);
        timer = nil;
      }
    }

    std::mutex pause_hold_mutex;
    std::shared_ptr<void> pause_hold;
    std::uint64_t pause_hold_generation = 0;
    dispatch_source_t pause_hold_timer = nil;

    // A paused game's display can only be reused by a stream that wants the same mode.
    bool pause_hold_is_stale(const video::config_t &config) {
      {
        std::lock_guard lock {pause_hold_mutex};
        if (!pause_hold) {
          return false;
        }
      }
      const double refresh = config.framerateX100 > 0 ? config.framerateX100 / 100.0 : config.framerate;
      const bool hdr = config.dynamicRange > 0 && !config.prefer_sdr_10bit && !config.force_sdr;
      std::lock_guard lock {state_mutex};
      return current && current_users == 1 &&
             (current->width != config.width || current->height != config.height || current->refresh != refresh || current->hdr != hdr);
    }

    std::mutex launch_hold_mutex;
    std::shared_ptr<void> launch_hold;
    std::uint64_t launch_hold_generation = 0;
    dispatch_source_t launch_hold_timer = nil;

    /**
     * @brief Turn off displays that came back on while the exclusive layout is in effect.
     * @details Call with state_mutex held. Safeguards are updated before anything is turned off.
     */
    void enforce_exclusive_layout(detail::virtual_display_t &display, const std::chrono::steady_clock::time_point noticed) {
      const auto active = detail::display_list(CGGetActiveDisplayList);
      const auto [keep_on, pending] = exclusive_keep_on(display.id, active);
      const auto plan = macos_display_policy::plan_exclusive_layout(active, keep_on, display.turned_off, pending);
      if (plan.turn_off.empty() || display.gave_up_enforcing) {
        return;
      }
      if (!display.enforce_budget.try_spend(std::chrono::steady_clock::now())) {
        display.gave_up_enforcing = true;
        BOOST_LOG(error) << "Virtual display: display(s) "sv << detail::format_ids(plan.turn_off)
                         << " keep turning back on, so they'll stay on for the rest of this session. Start a new stream to try the Exclusive layout again"sv;
        return;
      }

      // Safeguards first, and only for displays they don't cover yet. Turning displays back off
      // that are already covered needs a running helper too: one that couldn't start, or the
      // helper's own failure, would leave nothing to turn them back on.
      using macos_display_policy::cover_result_e;
      auto covered = display.turned_off;
      covered.insert(covered.end(), plan.newly_tracked.begin(), plan.newly_tracked.end());
      auto result = cover_result_e::turned_off;
      if (!plan.newly_tracked.empty() || !display.watchdog.running()) {
        if (!display.turned_off_modes) {
          display.turned_off_modes = std::make_unique<detail::saved_modes_t>();
        }
        for (const auto id : plan.newly_tracked) {
          display.turned_off_modes->add(id);
        }
        result = macos_display_policy::cover_and_turn_off(detail::safeguard_ops(), display.watchdog, display.turned_off, covered, plan.turn_off);
      } else if (!detail::set_displays_enabled(plan.turn_off, false)) {
        result = cover_result_e::turn_off_failed;
      }
      if (result == cover_result_e::safeguards_failed) {
        BOOST_LOG(warning) << "Virtual display: couldn't prepare to turn display(s) "sv << detail::format_ids(plan.turn_off) << " back on, so they stay on"sv;
        return;
      }
      if (result != cover_result_e::turned_off) {
        BOOST_LOG(warning) << "Virtual display: couldn't turn off display(s) "sv << detail::format_ids(plan.turn_off);
        return;
      }
      display.turned_off = std::move(covered);
      detail::wait_until([&display, &plan]() {
        return CGDisplayIsMain(display.id) && std::none_of(plan.turn_off.begin(), plan.turn_off.end(), detail::is_active);
      },
                         3s);
      const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - noticed);
      BOOST_LOG(info) << "Virtual display: display(s) "sv << detail::format_ids(plan.turn_off) << " came on during the session; turned them off for the Exclusive layout "sv
                      << elapsed.count() << " ms after macOS reported it"sv;
    }

    /// Call with state_mutex held.
    bool exclusive_in_effect() {
      return current && current->exclusive && config::video.virtual_display_layout == config::video_t::virtual_display_layout_e::exclusive;
    }

    void reconcile_after_display_change(const std::uint32_t flags) {
      // Only a display arriving or leaving makes macOS pick new modes; a mode change on its own may
      // be the user's choice, so leave it alone.
      const bool displays_changed = (flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag | kCGDisplayDisabledFlag)) != 0;
      {
        std::lock_guard lock {state_mutex};
        if (exclusive_in_effect()) {
          enforce_exclusive_layout(*current, std::chrono::steady_clock::now());
        }
        if (current) {
          detail::ensure_not_mirrored(current->id);
          if (displays_changed) {
            detail::keep_created_mode(*current);
          } else if (detail::is_active(current->id)) {
            detail::sync_recorded_mode(*current);
          }
        }
      }
      detail::reconcile_remote_displays(displays_changed);
    }

    void display_reconfigured(CGDirectDisplayID, const CGDisplayChangeSummaryFlags flags, void *) {
      if (flags & kCGDisplayBeginConfigurationFlag) {
        return;
      }
      // A display coming on, as when the lid opens, shows on screen until it's turned off again, so
      // don't wait for the changes to settle for that: macOS has already made it the main display.
      // The settled pass below catches anything this misses while macOS is still rearranging.
      if (flags & (kCGDisplayAddFlag | kCGDisplayEnabledFlag)) {
        detail::request_exclusive_enforcement();
      }
      pending_flags.fetch_or(static_cast<std::uint32_t>(flags));
      const auto generation = ++change_generation;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, std::chrono::nanoseconds {settle_delay}.count()), reconcile_queue(), ^{
        if (change_generation.load() != generation) {
          return;  // a later change restarted the wait
        }
        reconcile_after_display_change(pending_flags.exchange(0));
        // Changes made while reconciling start another wait; until it ends, nothing has settled.
        if (change_generation.load() == generation) {
          settled_generation = generation;
        }
      });
    }
  }  // namespace

  namespace detail {
    /**
     * @brief Whether this macOS can make an HDR virtual display and capture it in HDR.
     * @details Capturing HDR needs ScreenCaptureKit's HDR capture, from macOS 15.
     */
    bool can_make_hdr() {
      if (@available(macOS 15.0, *)) {
        return [NSClassFromString(@"CGVirtualDisplayMode") instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:transferFunction:)];
      }
      return false;
    }

    unsigned int round_even(const double value) {
      return static_cast<unsigned int>(std::max(1L, std::lround(value / 2.0))) * 2u;
    }

    void sync_recorded_mode(virtual_display_t &display) {
      const CGDisplayModeRef cur = CGDisplayCopyDisplayMode(display.id);
      if (!cur) {
        return;
      }
      display.mode_width = CGDisplayModeGetWidth(cur);
      display.mode_height = CGDisplayModeGetHeight(cur);
      display.pixel_width = CGDisplayModeGetPixelWidth(cur);
      display.pixel_height = CGDisplayModeGetPixelHeight(cur);
      CGDisplayModeRelease(cur);
    }

    scale_geometry_t compute_scale_geometry(
      const int width,
      const int height,
      const unsigned int max_pixels_wide,
      const unsigned int max_pixels_high,
      const int configured_scale
    ) {
      const unsigned int base_w = std::max(2u, static_cast<unsigned int>(width) & ~1u);
      const unsigned int base_h = std::max(2u, static_cast<unsigned int>(height) & ~1u);
      const bool auto_hidpi = (width > 1920 || height > 1200);
      const bool hidpi = configured_scale <= 0 ? auto_hidpi : (configured_scale >= 125);
      const bool explicit_scale = configured_scale >= 100;

      scale_geometry_t g;
      g.hidpi = hidpi;
      g.explicit_scale = explicit_scale;

      if (!hidpi) {
        g.mode_width = g.pixel_width = base_w;
        g.mode_height = g.pixel_height = base_h;
        return g;
      }

      if (configured_scale <= 0 || configured_scale == 200) {
        const auto size = macos_display_policy::virtual_display_size(width, height, true);
        if (!macos_display_policy::supports_hidpi_mode(size.pixel_width, size.pixel_height)) {
          g.hidpi = false;
          g.mode_width = g.pixel_width = base_w;
          g.mode_height = g.pixel_height = base_h;
          return g;
        }
        g.mode_width = size.width;
        g.mode_height = size.height;
        g.pixel_width = size.pixel_width;
        g.pixel_height = size.pixel_height;
        return g;
      }

      const double factor = configured_scale / 100.0;
      const unsigned int cap_lw = std::max(640u, max_pixels_wide / 2);
      const unsigned int cap_lh = std::max(480u, max_pixels_high / 2);
      unsigned int lw = std::clamp(round_even(base_w / factor), 640u, cap_lw);
      unsigned int lh = std::clamp(round_even(static_cast<double>(lw) * base_h / base_w), 480u, cap_lh);
      if (lh * 2 > max_pixels_high) {
        lh = (max_pixels_high / 2) & ~1u;
        lw = std::clamp(round_even(static_cast<double>(lh) * base_w / base_h), 640u, cap_lw);
      }
      if (std::min(lw, lh) < static_cast<unsigned int>(macos_display_policy::minimum_hidpi_short_axis_points)) {
        g.hidpi = false;
        g.mode_width = g.pixel_width = base_w;
        g.mode_height = g.pixel_height = base_h;
        return g;
      }
      g.mode_width = lw;
      g.mode_height = lh;
      g.pixel_width = lw * 2;
      g.pixel_height = lh * 2;
      return g;
    }

    void ensure_not_mirrored(const CGDirectDisplayID id) {
      if (id == kCGNullDirectDisplay) {
        return;
      }
      // CGDisplayIsInMirrorSet returns 1 for mirrored, 0 for not mirrored, and -1 for unknown IDs.
      // Compare explicitly against 1 so an unregistered ID is never treated as mirrored.
      if (CGDisplayIsInMirrorSet(id) != 1) {
        return;
      }
      CGDisplayConfigRef config = nullptr;
      if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return;
      }
      CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay);
      for (const auto other : display_list(CGGetActiveDisplayList)) {
        if (other != id && CGDisplayMirrorsDisplay(other) == id) {
          CGConfigureDisplayMirrorOfDisplay(config, other, kCGNullDirectDisplay);
        }
      }
      // Session scope (not permanent): permanent mirror reconfiguration of a private CGVirtualDisplay
      // fails with kCGErrorIllegalArgument, whereas session scope reliably dissolves the mirror set.
      const CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
      BOOST_LOG(info) << "Virtual display: display "sv << id << " was in a mirror set; detached to extend (result "sv << err << ')';
    }

    /// Put a display of Vibepollo's back in the mode it was made with, if macOS picked another.
    void keep_created_mode(const virtual_display_t &display) {
      if (display.pixel_width == 0 || !is_active(display.id)) {
        return;
      }
      const CGDisplayModeRef cur = CGDisplayCopyDisplayMode(display.id);
      const double cur_hz = cur ? CGDisplayModeGetRefreshRate(cur) : 0.0;
      const bool refresh_ok = display.refresh <= 0.0 || cur_hz <= 0.0 || std::abs(cur_hz - display.refresh) < 0.5;
      const bool matches = cur &&
                           CGDisplayModeGetWidth(cur) == display.mode_width &&
                           CGDisplayModeGetHeight(cur) == display.mode_height &&
                           CGDisplayModeGetPixelWidth(cur) == display.pixel_width &&
                           CGDisplayModeGetPixelHeight(cur) == display.pixel_height &&
                           refresh_ok;
      if (cur) {
        CGDisplayModeRelease(cur);
      }
      if (matches) {
        return;
      }
      BOOST_LOG(info) << "Virtual display: macOS changed display "sv << display.id << "'s mode; putting back "sv << display.mode_width << 'x' << display.mode_height << " ("sv << display.pixel_width << 'x' << display.pixel_height << ')';
      select_mode(display.id, display.mode_width, display.mode_height, display.pixel_width, display.pixel_height, display.refresh);
    }

    /**
     * @brief Create a virtual display, bring it online, and pick its mode, without arranging it.
     * @param name Shown in System Settings > Displays.
     * @param serial Distinguishes the display from Vibepollo's others, so macOS remembers each one's settings.
     * @param hdr Make it an HDR display, where this macOS can.
     */
    std::unique_ptr<virtual_display_t> make_display(
      NSString *name,
      const unsigned int serial,
      const int width,
      const int height,
      const double refresh,
      const bool hdr,
      const bool skip_other_modes_restore
    ) {
      @autoreleasepool {
        const Class descriptor_class = NSClassFromString(@"CGVirtualDisplayDescriptor");
        const Class display_class = NSClassFromString(@"CGVirtualDisplay");
        const Class settings_class = NSClassFromString(@"CGVirtualDisplaySettings");
        const Class mode_class = NSClassFromString(@"CGVirtualDisplayMode");
        if (!descriptor_class || !display_class || !settings_class || !mode_class) {
          BOOST_LOG(warning) << "Virtual display: not supported by this macOS"sv;
          return nullptr;
        }

        const bool make_hdr = hdr && can_make_hdr();
        if (hdr && !make_hdr) {
          BOOST_LOG(info) << "Virtual display: this macOS can't make it HDR, so the stream is SDR"sv;
        }

        // During a dark wake no display comes online, virtual ones included.
        platf::wake_displays();
        const saved_modes_t other_modes;

        const unsigned int base_w = std::max(2u, static_cast<unsigned int>(width) & ~1u);
        const unsigned int base_h = std::max(2u, static_cast<unsigned int>(height) & ~1u);
        const double headroom_factor = std::min({1.6, 7680.0 / base_w, 4320.0 / base_h});
        const unsigned int max_pixel_width = std::max(base_w, round_even(base_w * std::max(1.0, headroom_factor)));
        const unsigned int max_pixel_height = std::max(base_h, round_even(base_h * std::max(1.0, headroom_factor)));

        const int configured_scale = config::video.dd.virtual_display_scale_percent;
        const auto geom = compute_scale_geometry(width, height, max_pixel_width, max_pixel_height, configured_scale);
        const auto phys_mm = macos_display_policy::virtual_display_physical_size_mm(width, height, geom.hidpi);
        const auto bootstrap_size = macos_display_policy::virtual_display_bootstrap_size(width, height);

        unsigned int base_offset = 0;
        {
          std::lock_guard lock {identity_offsets_mutex};
          if (const auto it = identity_offsets.find(serial); it != identity_offsets.end()) {
            base_offset = it->second;
          }
        }

        struct create_attempt_t {
          std::unique_ptr<virtual_display_t> display;
          bool poisoned_identity = false;
        };

        const auto try_create_once = [&](const macos_display_policy::display_identity_t ident, const bool use_bootstrap, const std::chrono::milliseconds online_timeout) -> create_attempt_t {
          create_attempt_t attempt;
          CGVirtualDisplayDescriptor *descriptor = [[descriptor_class alloc] init];
          descriptor.queue = dispatch_queue_create("dev.vibepollo.virtual-display", DISPATCH_QUEUE_SERIAL);
          descriptor.name = name;
          descriptor.maxPixelsWide = max_pixel_width;
          descriptor.maxPixelsHigh = max_pixel_height;
          descriptor.sizeInMillimeters = CGSizeMake(phys_mm.width_mm, phys_mm.height_mm);
          descriptor.vendorID = vendor_id;
          descriptor.productID = ident.product_id;
          descriptor.serialNum = ident.serial_number;
          if (make_hdr) {
            // A wide gamut, as on Apple's HDR displays: Display P3 primaries and a D65 white point.
            descriptor.redPrimary = CGPointMake(0.680, 0.320);
            descriptor.greenPrimary = CGPointMake(0.265, 0.690);
            descriptor.bluePrimary = CGPointMake(0.150, 0.060);
            descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
          }
          // VirtualDisplayClient invokes terminationHandler with scalar status arguments when
          // WindowServer exits; __unsafe_unretained prevents ARC from calling objc_retain on them.
          descriptor.terminationHandler = ^(__unsafe_unretained id, __unsafe_unretained id) {
            BOOST_LOG(warning) << "Virtual display: macOS removed the virtual display"sv;
          };

          auto candidate = std::make_unique<virtual_display_t>();
          candidate->display = [[display_class alloc] initWithDescriptor:descriptor];
          if (!candidate->display) {
            BOOST_LOG(error) << "Virtual display: macOS refused to create it (serial "sv << ident.serial_number << ')';
            return attempt;
          }

          if (use_bootstrap && bootstrap_size) {
            const auto boot_geom = compute_scale_geometry(
              bootstrap_size->width,
              bootstrap_size->height,
              max_pixel_width,
              max_pixel_height,
              configured_scale
            );
            if (!apply_virtual_display_settings(
                  candidate->display,
                  bootstrap_size->width,
                  bootstrap_size->height,
                  max_pixel_width,
                  max_pixel_height,
                  refresh,
                  make_hdr,
                  boot_geom
                )) {
              BOOST_LOG(warning) << "Virtual display: bootstrap mode "sv << bootstrap_size->width << 'x' << bootstrap_size->height << " rejected"sv;
              return attempt;
            }
            candidate->id = candidate->display.displayID;
            if (!wait_until([id = candidate->id]() {
                  return is_active(id);
                },
                            online_timeout)) {
              attempt.poisoned_identity = true;
              return attempt;
            }
            if (!apply_virtual_display_settings(candidate->display, width, height, max_pixel_width, max_pixel_height, refresh, make_hdr, geom)) {
              BOOST_LOG(error) << "Virtual display: macOS rejected promoted mode "sv << geom.mode_width << 'x' << geom.mode_height << '@' << refresh << "Hz"sv;
              return attempt;
            }
          } else {
            if (!apply_virtual_display_settings(candidate->display, width, height, max_pixel_width, max_pixel_height, refresh, make_hdr, geom)) {
              BOOST_LOG(error) << "Virtual display: macOS rejected "sv << geom.mode_width << 'x' << geom.mode_height << '@' << refresh << "Hz"sv;
              return attempt;
            }
            candidate->id = candidate->display.displayID;
            if (!wait_until([id = candidate->id]() {
                  return is_active(id);
                },
                            online_timeout)) {
              attempt.poisoned_identity = true;
              return attempt;
            }
          }

          attempt.display = std::move(candidate);
          return attempt;
        };

        std::unique_ptr<virtual_display_t> result;
        constexpr unsigned int max_identity_probes = 3;
        for (unsigned int probe = 0; probe < max_identity_probes; ++probe) {
          const unsigned int total_offset = base_offset + probe;
          const auto ident = macos_display_policy::offset_display_identity(product_id, serial, total_offset);
          const auto timeout = (probe + 1 == max_identity_probes) ? 5000ms : 3000ms;

          auto attempt = try_create_once(ident, false, timeout);
          if (!attempt.display && bootstrap_size) {
            BOOST_LOG(warning) << "Virtual display: direct creation for "sv << width << 'x' << height
                               << " failed; retrying via conservative bootstrap "sv
                               << bootstrap_size->width << 'x' << bootstrap_size->height;
            attempt = try_create_once(ident, true, 3000ms);
          }
          if (attempt.display) {
            result = std::move(attempt.display);
            if (probe > 0) {
              std::lock_guard lock {identity_offsets_mutex};
              identity_offsets[serial] = total_offset;
              BOOST_LOG(warning) << "Virtual display: recovered from poisoned macOS display identity for serial "sv
                                 << serial << " using offset +"sv << total_offset
                                 << " (product "sv << ident.product_id << ", serial "sv << ident.serial_number << ')';
            }
            break;
          }
          if (!attempt.poisoned_identity) {
            break;
          }
          BOOST_LOG(warning) << "Virtual display: identity (product "sv << ident.product_id
                             << ", serial "sv << ident.serial_number
                             << ") never came online; probing fresh identity"sv;
        }

        if (!result) {
          BOOST_LOG(error) << "Virtual display: it never came online"sv;
          return nullptr;
        }

        result->width = width;
        result->height = height;
        result->max_pixels_wide = max_pixel_width;
        result->max_pixels_high = max_pixel_height;
        result->refresh = refresh;
        result->hdr = make_hdr;
        result->hidpi = geom.hidpi;
        result->explicit_scale = geom.explicit_scale;
        result->default_mode_width = geom.mode_width;
        result->default_mode_height = geom.mode_height;
        result->default_pixel_width = geom.pixel_width;
        result->default_pixel_height = geom.pixel_height;

        ensure_not_mirrored(result->id);
        log_if_unit_number_clashes(result->id);
        ensure_retina_mode(*result);
        // In exclusive layout, apply_layout() immediately turns off all other displays right after
        // make_display() returns, so polling other_modes for 1000ms here only stalls connection startup.
        if (!skip_other_modes_restore) {
          other_modes.restore(150ms);
        }
        BOOST_LOG(info) << "Virtual display: "sv << name.UTF8String << ' ' << result->pixel_width << 'x' << result->pixel_height << '@' << refresh << "Hz"sv
                        << (make_hdr ? " HDR"sv : ""sv)
                        << (geom.hidpi ? " (Retina, looks like "s + std::to_string(result->mode_width) + 'x' + std::to_string(result->mode_height) + ')' : ""s)
                        << ", display id "sv << result->id;
        return result;
      }
    }

    virtual_display_t::~virtual_display_t() {
      const saved_modes_t other_modes;
      bool restored = true;
      if (!turned_off.empty()) {
        // A stream can end while the Mac is half-awake, where displays never come back online.
        platf::wake_displays();
        const auto [online, offline] = split_offline(turned_off);
        // The virtual display goes away after this, so a physical display that's active but still
        // asleep isn't back yet: with nothing else on, macOS stops WindowServer for a stuck display.
        const auto all_back = [&online]() {
          return std::all_of(online.begin(), online.end(), [](const CGDirectDisplayID id) {
            return is_gone(id) || (is_active(id) && !CGDisplayIsAsleep(id));
          });
        };
        restored = turn_on(online) && wait_until(all_back, 5s);
        if (restored) {
          settle_marker(offline);
          BOOST_LOG(info) << "Virtual display: physical displays turned back on"sv;
        } else {
          BOOST_LOG(error) << "Virtual display: couldn't turn the physical displays back on; the restore helper will retry"sv;
        }
      }
      stop_watchdog(watchdog, restored);

      display = nil;
      if (id != kCGNullDirectDisplay) {
        wait_until([id = id]() {
          return !is_active(id);
        },
                   3s);
      }
      if (turned_off_modes) {
        turned_off_modes->restore(100ms);
      }
      other_modes.restore(100ms);
    }

    bool reapply_scale_to_display(virtual_display_t &vd, const int configured_scale) {
      if (!vd.display || vd.id == kCGNullDirectDisplay || !is_active(vd.id) || vd.width <= 0 || vd.height <= 0) {
        return false;
      }
      if (configured_scale == 0) {
        sync_recorded_mode(vd);
        return false;
      }

      const unsigned int max_w = vd.max_pixels_wide > 0 ? vd.max_pixels_wide : static_cast<unsigned int>(vd.width);
      const unsigned int max_h = vd.max_pixels_high > 0 ? vd.max_pixels_high : static_cast<unsigned int>(vd.height);
      const auto geom = compute_scale_geometry(vd.width, vd.height, max_w, max_h, configured_scale);

      sync_recorded_mode(vd);
      if (vd.mode_width == geom.mode_width &&
          vd.mode_height == geom.mode_height &&
          vd.pixel_width == geom.pixel_width &&
          vd.pixel_height == geom.pixel_height) {
        vd.hidpi = geom.hidpi;
        vd.explicit_scale = geom.explicit_scale;
        vd.default_mode_width = geom.mode_width;
        vd.default_mode_height = geom.mode_height;
        vd.default_pixel_width = geom.pixel_width;
        vd.default_pixel_height = geom.pixel_height;
        return false;
      }

      const std::size_t prev_pixel_w = vd.pixel_width;
      const std::size_t prev_pixel_h = vd.pixel_height;

      // Record the intended target mode before reconfiguring so concurrent display callbacks keep it.
      vd.hidpi = geom.hidpi;
      vd.explicit_scale = geom.explicit_scale;
      vd.default_mode_width = geom.mode_width;
      vd.default_mode_height = geom.mode_height;
      vd.default_pixel_width = geom.pixel_width;
      vd.default_pixel_height = geom.pixel_height;
      vd.mode_width = geom.mode_width;
      vd.mode_height = geom.mode_height;
      vd.pixel_width = geom.pixel_width;
      vd.pixel_height = geom.pixel_height;

      if (!apply_virtual_display_settings(vd.display, vd.width, vd.height, max_w, max_h, vd.refresh, vd.hdr, geom)) {
        BOOST_LOG(warning) << "Virtual display: couldn't apply live scale "sv << configured_scale << '%' << " on display "sv << vd.id;
        sync_recorded_mode(vd);
        return false;
      }

      select_mode(vd.id, geom.mode_width, geom.mode_height, geom.pixel_width, geom.pixel_height, vd.refresh);
      using layout_e = config::video_t::virtual_display_layout_e;
      const auto layout = config::video.virtual_display_layout;
      if (!vd.exclusive && (layout == layout_e::extended_primary || layout == layout_e::extended_primary_isolated)) {
        make_main(vd.id);
      }
      sync_recorded_mode(vd);

      pending_flags.store(0, std::memory_order_relaxed);
      const auto gen = ++change_generation;
      settled_generation.store(gen, std::memory_order_release);
      BOOST_LOG(info) << "Virtual display: applied live scale ("sv << configured_scale << "%) on display "sv << vd.id
                      << " -> looks like "sv << vd.mode_width << 'x' << vd.mode_height
                      << " (pixels "sv << vd.pixel_width << 'x' << vd.pixel_height << ')';
      return vd.pixel_width != prev_pixel_w || vd.pixel_height != prev_pixel_h;
    }

    /// Enforce the exclusive layout again soon, as once a Remote Monitor it waited for is published.
    void request_exclusive_enforcement() {
      const auto noticed = std::chrono::steady_clock::now();
      dispatch_async(reconcile_queue(), ^{
        std::lock_guard lock {state_mutex};
        if (exclusive_in_effect()) {
          enforce_exclusive_layout(*current, noticed);
        }
      });
    }

    CGDirectDisplayID current_display_id() {
      return current_id.load();
    }
  }  // namespace detail

  void end_pause_hold() {
    std::shared_ptr<void> held;  // released outside the lock: releasing can take seconds
    {
      std::lock_guard lock {pause_hold_mutex};
      held = std::move(pause_hold);
      ++pause_hold_generation;
      cancel_timer_locked(pause_hold_timer);
    }
  }

  std::shared_ptr<void> acquire(const video::config_t &config) {
    if (config::video.virtual_display_mode == config::video_t::virtual_display_mode_e::disabled) {
      return nullptr;
    }

    if (pause_hold_is_stale(config)) {
      end_pause_hold();
    }

    std::lock_guard lock {state_mutex};
    if (!current) {
      current = create(config);
      if (!current) {
        return nullptr;
      }
      current_hdr = current->hdr;
      current_id = current->id;
    }
    ++current_users;

    static int token;
    return std::shared_ptr<void>(&token, [](void *) {
      release();
    });
  }

  void hold_for_launch(const video::config_t &config) {
    auto held = acquire(config);
    if (!held) {
      return;
    }

    std::shared_ptr<void> previous;  // released outside the lock: releasing can take seconds
    std::uint64_t generation;
    {
      std::lock_guard lock {launch_hold_mutex};
      previous = std::exchange(launch_hold, std::move(held));
      generation = ++launch_hold_generation;
      cancel_timer_locked(launch_hold_timer);
      dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, hold_timer_queue());
      dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 500LL * NSEC_PER_MSEC);
      dispatch_source_set_event_handler(timer, ^{
        std::shared_ptr<void> expired;
        {
          std::lock_guard lg {launch_hold_mutex};
          if (launch_hold_generation == generation) {
            expired = std::move(launch_hold);
            cancel_timer_locked(launch_hold_timer);
          }
        }
        if (expired) {
          BOOST_LOG(info) << "Virtual display: no stream started within 30 seconds of the launch; removing it"sv;
        }
      });
      launch_hold_timer = timer;
      dispatch_resume(timer);
    }
  }

  void hold_for_pause(const std::chrono::seconds timeout) {
    std::shared_ptr<void> held;
    {
      std::lock_guard lock {state_mutex};
      if (!current) {
        return;
      }
      ++current_users;
      static int token;
      held = std::shared_ptr<void>(&token, [](void *) {
        release();
      });
    }

    std::shared_ptr<void> previous;  // released outside the lock: releasing can take seconds
    std::uint64_t generation;
    {
      std::lock_guard lock {pause_hold_mutex};
      previous = std::exchange(pause_hold, std::move(held));
      generation = ++pause_hold_generation;
      cancel_timer_locked(pause_hold_timer);
      if (timeout.count() > 0) {
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, hold_timer_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, timeout.count() * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 1LL * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
          std::shared_ptr<void> expired;
          {
            std::lock_guard lg {pause_hold_mutex};
            if (pause_hold_generation == generation) {
              expired = std::move(pause_hold);
              cancel_timer_locked(pause_hold_timer);
            }
          }
          if (expired) {
            BOOST_LOG(info) << "Virtual display: paused session timed out; removing it"sv;
          }
        });
        pause_hold_timer = timer;
        dispatch_resume(timer);
      }
    }
    BOOST_LOG(info) << "Virtual display: keeping it while the session is paused"sv;
  }

  void end_launch_hold() {
    std::shared_ptr<void> held;
    {
      std::lock_guard lock {launch_hold_mutex};
      held = std::move(launch_hold);
      ++launch_hold_generation;
      cancel_timer_locked(launch_hold_timer);
    }
  }

  std::optional<std::uint32_t> active_display_id() {
    const auto id = current_id.load();
    return id == kCGNullDirectDisplay ? std::nullopt : std::optional<std::uint32_t> {id};
  }

  bool is_hdr_display(const std::uint32_t display_id) {
    if (display_id == current_id.load()) {
      return current_hdr.load();
    }
    return detail::is_remote_hdr_display(display_id);
  }

  void watch_display_changes() {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (CGDisplayRegisterReconfigurationCallback(display_reconfigured, nullptr) != kCGErrorSuccess) {
        BOOST_LOG(warning) << "Virtual display: couldn't watch for display changes; displays that come back on during a stream will stay on"sv;
      }
    });
  }

  bool display_changes_settled() {
    return settled_generation.load() == change_generation.load();
  }

  void reapply_scale() {
    dispatch_async(reconcile_queue(), ^{
      @autoreleasepool {
        const int configured_scale = config::video.dd.virtual_display_scale_percent;
        bool backing_pixels_changed = false;
        {
          std::lock_guard lock {state_mutex};
          if (current) {
            backing_pixels_changed |= detail::reapply_scale_to_display(*current, configured_scale);
          }
        }
        backing_pixels_changed |= detail::reapply_scale_to_remote_displays(configured_scale);
        if (backing_pixels_changed) {
          scale_reinit_counter.fetch_add(1, std::memory_order_release);
        }
      }
    });
  }

  std::uint64_t scale_reinit_epoch() {
    return scale_reinit_counter.load(std::memory_order_acquire);
  }

  std::uint64_t display_state_generation() {
    return change_generation.load(std::memory_order_acquire);
  }
}  // namespace platf::macos_virtual_display
