/**
 * @file src/platform/macos/virtual_display_internal.h
 * @brief Internal types and cross-translation-unit helpers for macOS virtual displays.
 */
#pragma once

// standard includes
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

// platform includes
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// local includes
#include "display_policy.h"
#include "virtual_display.h"

// Private CoreGraphics interfaces (macOS 11+), instantiated through NSClassFromString().
@interface CGVirtualDisplayDescriptor: NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode: NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
// Newer macOS only; check with instancesRespondToSelector: first.
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate transferFunction:(unsigned int)transferFunction;
@end

@interface CGVirtualDisplaySettings: NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay: NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

namespace platf::macos_virtual_display::detail {
  // A stable identity lets macOS remember the virtual display's arrangement between sessions.
  inline constexpr unsigned int vendor_id = 0x5650;  // "VP"
  inline constexpr unsigned int product_id = 0x0001;
  inline constexpr unsigned int serial_number = 0x0001;

  // A mode's transfer function, on macOS versions that take one. 1 makes the display HDR: macOS
  // then gives it EDR headroom, as it does an HDR monitor. 0, the default, is SDR.
  inline constexpr unsigned int hdr_transfer_function = 1;

  /// The helper that turns displays back on if Vibepollo exits without doing so.
  using watchdog_t = macos_display_policy::restore_helper_t;

  /**
   * @brief The other displays' modes, from before a new display joins them.
   * @details macOS keeps display settings per combination of displays, so a new display gives the
   *          others their default modes and drops the user's scaling, such as More Space. So does
   *          turning a display back on, or removing one. restore() puts back any that changed.
   */
  class saved_modes_t {
  public:
    saved_modes_t();
    saved_modes_t(const saved_modes_t &) = delete;
    saved_modes_t &operator=(const saved_modes_t &) = delete;
    ~saved_modes_t();

    /// Also remember a display that joined later, unless it's already remembered.
    void add(CGDirectDisplayID id);

    /// @param wait How long macOS may take to make the change, which it does just after the displays change.
    void restore(std::chrono::milliseconds wait) const;

  private:
    std::vector<std::pair<CGDirectDisplayID, CGDisplayModeRef>> changed() const;

    std::vector<std::pair<CGDirectDisplayID, CGDisplayModeRef>> modes;
  };

  struct scale_geometry_t {
    bool hidpi = false;
    bool explicit_scale = false;
    unsigned int mode_width = 0;
    unsigned int mode_height = 0;
    unsigned int pixel_width = 0;
    unsigned int pixel_height = 0;
  };

  struct virtual_display_t {
    CGVirtualDisplay *display = nil;
    CGDirectDisplayID id = kCGNullDirectDisplay;
    bool hdr = false;
    int width = 0;  ///< As requested.
    int height = 0;
    double refresh = 0;
    ///< Target Retina mode when explicit scaling is configured, or default 2x fallback.
    bool hidpi = false;
    bool explicit_scale = false;
    unsigned int max_pixels_wide = 0;
    unsigned int max_pixels_high = 0;
    std::size_t default_mode_width = 0;
    std::size_t default_mode_height = 0;
    std::size_t default_pixel_width = 0;
    std::size_t default_pixel_height = 0;
    std::size_t mode_width = 0;  ///< Logical width in points.
    std::size_t mode_height = 0;
    std::size_t pixel_width = 0;  ///< Active backing pixels, which get captured.
    std::size_t pixel_height = 0;
    bool exclusive = false;  ///< The exclusive layout is in effect: only Vibepollo's displays stay on.
    std::vector<CGDirectDisplayID> turned_off;  ///< Physical displays to turn back on.
    std::unique_ptr<saved_modes_t> turned_off_modes;  ///< Their modes from before.
    watchdog_t watchdog;
    /// Bounds how often displays that keep coming back on get turned off again. Opening the lid
    /// can take two: one right away, and one once the changes settle.
    macos_display_policy::attempt_budget_t enforce_budget {6, std::chrono::seconds {60}};
    bool gave_up_enforcing = false;

    virtual_display_t() = default;
    virtual_display_t(const virtual_display_t &) = delete;
    virtual_display_t &operator=(const virtual_display_t &) = delete;
    ~virtual_display_t();
  };

  // --- Watchdog, marker, and display-power helpers (virtual_display_watchdog.mm) ---

  bool has_configure_display_enabled();
  bool wait_until(const std::function<bool()> &condition, std::chrono::milliseconds timeout);
  std::vector<CGDirectDisplayID> display_list(CGError (*list)(uint32_t, CGDirectDisplayID *, uint32_t *));
  bool is_active(CGDirectDisplayID id);
  bool is_gone(CGDirectDisplayID id);
  std::pair<std::size_t, std::size_t> current_pixels(CGDirectDisplayID id);
  bool set_displays_enabled(const std::vector<CGDirectDisplayID> &ids, bool enabled);
  bool turn_on(const std::vector<CGDirectDisplayID> &ids);
  std::string format_ids(const std::vector<CGDirectDisplayID> &ids);
  std::pair<std::vector<CGDirectDisplayID>, std::vector<CGDirectDisplayID>> split_offline(const std::vector<CGDirectDisplayID> &ids);
  void settle_marker(const std::vector<CGDirectDisplayID> &offline);
  void stop_watchdog(watchdog_t &watchdog, bool displays_restored);
  const macos_display_policy::safeguard_ops_t &safeguard_ops();

  // --- Core virtual display helpers (virtual_display.mm) ---

  bool can_make_hdr();
  unsigned int round_even(double value);
  scale_geometry_t compute_scale_geometry(
    int width,
    int height,
    unsigned int max_pixels_wide,
    unsigned int max_pixels_high,
    int configured_scale
  );
  std::unique_ptr<virtual_display_t> make_display(
    NSString *name,
    unsigned int serial,
    int width,
    int height,
    double refresh,
    bool hdr,
    bool skip_other_modes_restore = false
  );
  void ensure_not_mirrored(CGDirectDisplayID id);
  void keep_created_mode(const virtual_display_t &display);
  void sync_recorded_mode(virtual_display_t &display);
  bool reapply_scale_to_display(virtual_display_t &vd, int configured_scale);
  void request_exclusive_enforcement();
  CGDirectDisplayID current_display_id();

  // --- Remote Monitor hooks (virtual_display_remote.mm) ---

  /// Appends active Remote Monitor display IDs to keep_on; returns true if any are still being created.
  bool append_remote_keep_on(std::vector<CGDirectDisplayID> &keep_on);
  bool is_remote_hdr_display(CGDirectDisplayID id);
  void reconcile_remote_displays(bool displays_changed);
  bool reapply_scale_to_remote_displays(int configured_scale);
}  // namespace platf::macos_virtual_display::detail
