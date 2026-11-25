/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */
// standard includes
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

// platform includes
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#import <IOSurface/IOSurface.h>
#include <time.h>
#include <vector>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/display_policy.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/nv12_zero_device.h"
#include "src/platform/macos/sc_video.h"
#include "src/platform/macos/virtual_display.h"
#include "src/platform/macos/vt_encoder.h"

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

namespace fs = std::filesystem;

namespace {
  struct cg_stream_api_t {
    using frame_handler_t = void (^)(int32_t status, uint64_t display_time, IOSurfaceRef frame_surface, CFTypeRef update_ref);
    using create_fn_t = CFTypeRef (*)(
      CGDirectDisplayID display,
      size_t output_width,
      size_t output_height,
      int32_t pixel_format,
      CFDictionaryRef properties,
      dispatch_queue_t queue,
      frame_handler_t handler
    );
    using start_fn_t = CGError (*)(CFTypeRef stream);
    using stop_fn_t = CGError (*)(CFTypeRef stream);

    create_fn_t create = nullptr;
    start_fn_t start = nullptr;
    stop_fn_t stop = nullptr;
    CFStringRef k_show_cursor = nullptr;
    CFStringRef k_queue_depth = nullptr;
    CFStringRef k_min_frame_time = nullptr;
    CFStringRef k_ycbcr_matrix = nullptr;
    CFStringRef k_matrix_709 = nullptr;

    static const cg_stream_api_t &get() {
      static const cg_stream_api_t api = [] {
        cg_stream_api_t a;
        a.create = reinterpret_cast<create_fn_t>(dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue"));
        a.start = reinterpret_cast<start_fn_t>(dlsym(RTLD_DEFAULT, "CGDisplayStreamStart"));
        a.stop = reinterpret_cast<stop_fn_t>(dlsym(RTLD_DEFAULT, "CGDisplayStreamStop"));
        const auto sym_cfstr = [](const char *name) -> CFStringRef {
          const auto *p = static_cast<const CFStringRef *>(dlsym(RTLD_DEFAULT, name));
          return p ? *p : nullptr;
        };
        a.k_show_cursor = sym_cfstr("kCGDisplayStreamShowCursor");
        a.k_queue_depth = sym_cfstr("kCGDisplayStreamQueueDepth");
        a.k_min_frame_time = sym_cfstr("kCGDisplayStreamMinimumFrameTime");
        a.k_ycbcr_matrix = sym_cfstr("kCGDisplayStreamYCbCrMatrix");
        a.k_matrix_709 = sym_cfstr("kCGDisplayStreamYCbCrMatrix_ITU_R_709_2");
        return a;
      }();
      return api;
    }

    bool available() const {
      return create != nullptr && start != nullptr && stop != nullptr;
    }
  };

  OSType normalize_cg_stream_pixel_format(OSType fmt) {
    switch (fmt) {
      case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      case kCVPixelFormatType_ARGB2101010LEPacked:
      case kCVPixelFormatType_32BGRA:
        return fmt;
      case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
      case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        return kCVPixelFormatType_ARGB2101010LEPacked;
      default:
        return kCVPixelFormatType_32BGRA;
    }
  }

  CMSampleBufferRef create_sample_from_iosurface(IOSurfaceRef surface, uint64_t display_time) {
    if (!surface) {
      return nullptr;
    }
    CVPixelBufferRef pixel_buffer = nullptr;
    if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nullptr, &pixel_buffer) != kCVReturnSuccess || !pixel_buffer) {
      return nullptr;
    }
    CMVideoFormatDescriptionRef format_desc = nullptr;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, &format_desc) != noErr || !format_desc) {
      CVPixelBufferRelease(pixel_buffer);
      return nullptr;
    }
    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());
    if (display_time != 0) {
      const CMTime host_pts = CMClockMakeHostTimeFromSystemUnits(display_time);
      if (CMTIME_IS_NUMERIC(host_pts)) {
        pts = host_pts;
      }
    }
    const CMSampleTimingInfo timing {kCMTimeInvalid, pts, kCMTimeInvalid};
    CMSampleBufferRef sample = nullptr;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel_buffer, format_desc, &timing, &sample);
    CFRelease(format_desc);
    CVPixelBufferRelease(pixel_buffer);
    return sample;
  }

  CMSampleBufferRef create_dummy_sample(int width, int height, OSType pixel_format) {
    @autoreleasepool {
    const size_t w = width > 0 ? static_cast<size_t>(width) : 1920;
    const size_t h = height > 0 ? static_cast<size_t>(height) : 1080;
    const OSType fmt = pixel_format != 0 ? pixel_format : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    NSDictionary *attrs = @{
      (__bridge NSString *) kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef pixel_buffer = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, (__bridge CFDictionaryRef) attrs, &pixel_buffer) != kCVReturnSuccess || !pixel_buffer) {
      return nullptr;
    }

    // Fill with neutral black (zeroed YCbCr planes decode as bright green!).
    CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    if (CVPixelBufferIsPlanar(pixel_buffer)) {
      const bool ten_bit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                           fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                           fmt == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange ||
                           fmt == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange;
      const bool full_range = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                              fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                              fmt == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange ||
                              fmt == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange;
      for (size_t plane = 0; plane < CVPixelBufferGetPlaneCount(pixel_buffer); ++plane) {
        auto *base = static_cast<std::uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane));
        const size_t size = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane) * CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
        if (!base || size == 0) {
          continue;
        }
        if (ten_bit) {
          const std::uint16_t luma_black = full_range ? 0 : 64;
          const std::uint16_t fill_value = static_cast<std::uint16_t>((plane == 0 ? luma_black : 512) << 6);
          std::fill_n(reinterpret_cast<std::uint16_t *>(base), size / sizeof(std::uint16_t), fill_value);
        } else {
          const std::uint8_t luma_black = full_range ? 0 : 16;
          std::memset(base, plane == 0 ? luma_black : 128, size);
        }
      }
    } else if (void *base = CVPixelBufferGetBaseAddress(pixel_buffer)) {
      std::memset(base, 0, CVPixelBufferGetBytesPerRow(pixel_buffer) * CVPixelBufferGetHeight(pixel_buffer));
    }
    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);

    CMVideoFormatDescriptionRef format_desc = nullptr;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, &format_desc) != noErr || !format_desc) {
      CVPixelBufferRelease(pixel_buffer);
      return nullptr;
    }
    const CMSampleTimingInfo timing {kCMTimeInvalid, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    CMSampleBufferRef sample = nullptr;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel_buffer, format_desc, &timing, &sample);
    CFRelease(format_desc);
    CVPixelBufferRelease(pixel_buffer);
    return sample;
    }
  }

  struct cg_stream_slot_t {
    std::mutex mutex;
    bool stopped = false;
    CFTypeRef stream = nullptr;
    dispatch_queue_t queue = nil;
    dispatch_source_t keepalive_timer = nil;
    CMSampleBufferRef last_sample = nullptr;
    uint64_t keepalive_ns = 0;
    std::atomic<uint64_t> last_delivery_ns {0};
    FrameCallbackBlock callback = nil;
    dispatch_semaphore_t signal = nil;

    ~cg_stream_slot_t() {
      stop(false);
      if (callback) {
        [callback release];
        callback = nil;
      }
      if (queue) {
        [queue release];
        queue = nil;
      }
      if (signal) {
        [signal release];
        signal = nil;
      }
    }

    bool is_stopped() {
      std::lock_guard lock {mutex};
      return stopped;
    }

    void stop(bool async_teardown) {
      CFTypeRef to_stop = nullptr;
      dispatch_source_t timer_to_cancel = nil;
      CMSampleBufferRef sample_to_release = nullptr;
      bool should_signal = false;
      {
        std::lock_guard lock {mutex};
        if (!stopped) {
          stopped = true;
          should_signal = true;
        }
        to_stop = stream;
        stream = nullptr;
        timer_to_cancel = keepalive_timer;
        keepalive_timer = nil;
        sample_to_release = last_sample;
        last_sample = nullptr;
      }
      if (timer_to_cancel) {
        dispatch_source_cancel(timer_to_cancel);
        [timer_to_cancel release];
      }
      if (sample_to_release) {
        CFRelease(sample_to_release);
      }
      if (should_signal && signal) {
        dispatch_semaphore_signal(signal);
      }
      if (to_stop) {
        if (async_teardown) {
          dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            cg_stream_api_t::get().stop(to_stop);
            CFRelease(to_stop);
          });
        } else {
          cg_stream_api_t::get().stop(to_stop);
          CFRelease(to_stop);
        }
      }
    }
  };
}  // namespace

/**
 * @brief Zero-copy CoreGraphics/SkyLight `CGDisplayStream` capture backend.
 * @details Used in pre-login `LoginWindow` sessions (where ScreenCaptureKit's Aqua `replayd` agent
 *          is not running) and as a fallback on virtual or physical displays when `SCVideo` fails.
 */
@interface CGStreamVideo: AVVideo
@property (nonatomic, assign) CMTime keepaliveInterval;
@end

@implementation CGStreamVideo {
  std::mutex _slots_mutex;
  std::vector<std::shared_ptr<cg_stream_slot_t>> _slots;
}

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  if (!cg_stream_api_t::get().available()) {
    [self release];
    return nil;
  }
  self = [super init];
  if (!self) {
    return nil;
  }
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (mode == NULL) {
    [self release];
    return nil;
  }
  self.displayID = displayID;
  super.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
  self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
  const int fps = std::max(frameRate, 1);
  self.minFrameDuration = CMTimeMake(1, fps);
  self.keepaliveInterval = kCMTimeInvalid;
  CGDisplayModeRelease(mode);
  return self;
}

- (void)setPixelFormat:(OSType)pixelFormat {
  [super setPixelFormat:normalize_cg_stream_pixel_format(pixelFormat)];
}

- (void)stopCaptureForSignal:(dispatch_semaphore_t)signal {
  if (signal == nil) {
    return;
  }
  std::shared_ptr<cg_stream_slot_t> matched;
  {
    std::lock_guard lock {_slots_mutex};
    for (auto it = _slots.begin(); it != _slots.end(); ++it) {
      if (*it && (*it)->signal == signal) {
        matched = *it;
        _slots.erase(it);
        break;
      }
    }
  }
  if (matched) {
    matched->stop(false);
  }
}

- (void)stopAllCaptures {
  std::vector<std::shared_ptr<cg_stream_slot_t>> slots;
  {
    std::lock_guard lock {_slots_mutex};
    slots.swap(_slots);
  }
  for (auto &slot : slots) {
    if (slot) {
      slot->stop(false);
    }
  }
}

- (void)dealloc {
  [self stopAllCaptures];
  [super dealloc];
}

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
  const auto &api = cg_stream_api_t::get();
  if (!api.available() || !frameCallback) {
    return nil;
  }

  {
    std::lock_guard lock {_slots_mutex};
    std::erase_if(_slots, [](const std::shared_ptr<cg_stream_slot_t> &s) {
      return !s || s->is_stopped();
    });
  }

  auto slot = std::make_shared<cg_stream_slot_t>();
  dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  slot->queue = dispatch_queue_create("dev.vibepollo.cgstream", qos);
  slot->signal = dispatch_semaphore_create(0);
  slot->callback = [frameCallback copy];
  if (CMTIME_IS_VALID(self.keepaliveInterval) && CMTimeGetSeconds(self.keepaliveInterval) > 0.0) {
    slot->keepalive_ns = static_cast<uint64_t>(CMTimeGetSeconds(self.keepaliveInterval) * NSEC_PER_SEC);
  }

  CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  if (api.k_show_cursor) {
    CFDictionarySetValue(props, api.k_show_cursor, kCFBooleanTrue);
  }
  if (api.k_queue_depth) {
    const int depth = 3;
    CFNumberRef depth_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &depth);
    CFDictionarySetValue(props, api.k_queue_depth, depth_num);
    CFRelease(depth_num);
  }
  if (api.k_min_frame_time && CMTIME_IS_NUMERIC(self.minFrameDuration)) {
    const double min_dt = std::max(0.0, CMTimeGetSeconds(self.minFrameDuration) * 0.9);
    CFNumberRef dt_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &min_dt);
    CFDictionarySetValue(props, api.k_min_frame_time, dt_num);
    CFRelease(dt_num);
  }
  if (api.k_ycbcr_matrix && api.k_matrix_709) {
    CFDictionarySetValue(props, api.k_ycbcr_matrix, api.k_matrix_709);
  }

  std::weak_ptr<cg_stream_slot_t> weak_slot = slot;
  cg_stream_api_t::frame_handler_t handler = ^(int32_t status, uint64_t display_time, IOSurfaceRef frame_surface, CFTypeRef) {
    auto s = weak_slot.lock();
    if (!s) {
      return;
    }
    if (status == 3 /* kCGDisplayStreamFrameStatusStopped */) {
      s->stop(true);
      return;
    }
    if (status != 0 /* kCGDisplayStreamFrameStatusFrameComplete */ || frame_surface == nullptr) {
      return;
    }
    if (s->is_stopped()) {
      return;
    }
    CMSampleBufferRef sample = create_sample_from_iosurface(frame_surface, display_time);
    if (!sample) {
      return;
    }
    if (s->keepalive_ns > 0) {
      std::lock_guard lock {s->mutex};
      if (!s->stopped) {
        if (s->last_sample) {
          CFRelease(s->last_sample);
        }
        s->last_sample = (CMSampleBufferRef) CFRetain(sample);
      }
    }
    s->last_delivery_ns.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), std::memory_order_relaxed);
    const bool keep_going = s->callback(sample);
    CFRelease(sample);
    if (!keep_going) {
      s->stop(true);
    }
  };

  const size_t out_w = static_cast<size_t>(std::max(1, self.frameWidth));
  const size_t out_h = static_cast<size_t>(std::max(1, self.frameHeight));
  OSType chosen_fmt = normalize_cg_stream_pixel_format(self.pixelFormat);
  CFTypeRef stream = api.create(self.displayID, out_w, out_h, static_cast<int32_t>(chosen_fmt), props, slot->queue, handler);
  if (!stream && chosen_fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    chosen_fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    stream = api.create(self.displayID, out_w, out_h, static_cast<int32_t>(chosen_fmt), props, slot->queue, handler);
  }
  if (!stream && chosen_fmt != kCVPixelFormatType_32BGRA) {
    chosen_fmt = kCVPixelFormatType_32BGRA;
    stream = api.create(self.displayID, out_w, out_h, static_cast<int32_t>(chosen_fmt), props, slot->queue, handler);
  }
  CFRelease(props);

  if (!stream) {
    return nil;
  }
  super.pixelFormat = chosen_fmt;
  slot->stream = stream;

  if (slot->keepalive_ns > 0) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, slot->queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, slot->keepalive_ns), slot->keepalive_ns, slot->keepalive_ns / 10);
    dispatch_source_set_event_handler(timer, ^{
      auto s = weak_slot.lock();
      if (!s) {
        return;
      }
      const uint64_t last = s->last_delivery_ns.load(std::memory_order_relaxed);
      if (last != 0 && (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last) < (s->keepalive_ns * 9 / 10)) {
        return;
      }
      CMSampleBufferRef sample = nullptr;
      {
        std::lock_guard lock {s->mutex};
        if (s->stopped || !s->last_sample) {
          return;
        }
        sample = (CMSampleBufferRef) CFRetain(s->last_sample);
      }
      s->last_delivery_ns.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), std::memory_order_relaxed);
      const bool keep_going = s->callback(sample);
      CFRelease(sample);
      if (!keep_going) {
        s->stop(true);
      }
    });
    slot->keepalive_timer = timer;
    dispatch_resume(timer);
  }

  if (api.start(stream) != kCGErrorSuccess) {
    slot->stop(false);
    return nil;
  }

  {
    std::lock_guard lock {_slots_mutex};
    _slots.push_back(slot);
  }
  return slot->signal;
}

@end

namespace platf {
  using namespace std::literals;

  namespace {
    /**
     * @brief State shared by a capture call and its frame callback.
     * @details The callback runs on the capture queue and can fire after the call has timed out and
     *          returned, so it checks `stopped` under the lock before touching anything the call owns.
     */
    struct capture_state_t {
      std::mutex mutex;
      bool stopped = false;
      bool delivered = false;
      bool scale_reinit = false;
      bool source_mismatch = false;
      macos_display_policy::display_rect_t mismatched_rect {};
      macos_display_policy::display_rect_t expected_rect {};
      macos_display_policy::capture_source_check_t source_check {1500ms};
      std::chrono::steady_clock::time_point last_source_check {};
      std::chrono::steady_clock::time_point last_frame = std::chrono::steady_clock::now();
    };

    // SDR white in ScreenCaptureKit's HDRLocalDisplay (1) frames, measured from an HDR virtual
    // display on macOS 27 (~140 nits SDR white, ~700 nits peak at 5x headroom).
    constexpr double sdr_white_nits = 140.0;
    // macOS 27 gives an HDR virtual display this much EDR headroom.
    constexpr double virtual_display_headroom = 5.0;
    // The brightest Apple displays peak at 1600 nits.
    constexpr double max_peak_nits = 1600.0;

    // A display can drop offline for a moment while macOS rearranges displays.
    constexpr auto offline_grace = 2s;

    /**
     * @brief Bounds capture restarts, across every stream and the displays they go through.
     * @details A capture that keeps stopping right after it starts would otherwise restart forever
     *          while the client watches a frozen picture. Past the limit the stream ends with an error.
     */
    bool may_restart_capture() {
      static std::mutex mutex;
      static macos_display_policy::attempt_budget_t budget {10, 60s};
      std::lock_guard lock {mutex};
      return budget.try_spend(std::chrono::steady_clock::now());
    }

    std::pair<std::size_t, std::size_t> mode_pixels(const CGDirectDisplayID display_id) {
      const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display_id);
      if (!mode) {
        return {0, 0};
      }
      const std::pair<std::size_t, std::size_t> pixels {CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode)};
      CGDisplayModeRelease(mode);
      return pixels;
    }

    /**
     * @brief How far above SDR white a display can go: more than 1 for an HDR display.
     */
    double edr_headroom(const CGDirectDisplayID display_id) {
      @autoreleasepool {
        for (NSScreen *screen in NSScreen.screens) {
          if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display_id) {
            return screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
          }
        }
      }
      return 1.0;
    }
  }  // namespace

  struct av_display_t: public display_t {
    AVVideo *av_capture {};
    CGDirectDisplayID display_id {};
    bool hdr = false;
    double headroom = 1.0;  ///< The display's EDR headroom, while hdr.
    std::pair<std::size_t, std::size_t> captured_pixels;  ///< The display's mode when capture was set up.
    std::atomic<bool> lock_cpu_pixels {false};
    std::atomic<bool> need_bootstrap_sample {true};
    std::atomic<int> wrong_source_reattaches {0};
    std::mutex latest_sample_mutex;
    CMSampleBufferRef latest_sample = nullptr;

    ~av_display_t() override {
      if (latest_sample) {
        CFRelease(latest_sample);
      }
      [av_capture release];
    }

    static void populate_captured_img(av_img_t *av_img, CMSampleBufferRef sampleBuffer, bool lock_cpu) {
      const auto host_processing_timestamp = std::chrono::steady_clock::now();
      auto frame_timestamp = host_processing_timestamp;
      const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
      if (CMTIME_IS_NUMERIC(pts)) {
        const CMTime now_cm = CMClockGetTime(CMClockGetHostTimeClock());
        const double age_sec = CMTimeGetSeconds(CMTimeSubtract(now_cm, pts));
        if (age_sec >= 0.0 && age_sec < 1.0) {
          frame_timestamp = host_processing_timestamp - std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(age_sec));
        }
      }

      auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
      auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf, lock_cpu);

      // Keep previous pixel/sample buffer alive on the stack until the replacement pointers are installed.
      temp_retain_av_img_t old_data_retainer(
        av_img->sample_buffer,
        av_img->pixel_buffer,
        av_img->data
      );

      av_img->sample_buffer = std::move(new_sample_buffer);
      av_img->pixel_buffer = std::move(new_pixel_buffer);
      av_img->data = av_img->pixel_buffer->data();

      auto *pb = av_img->pixel_buffer->buf;
      av_img->width = (int) CVPixelBufferGetWidth(pb);
      av_img->height = (int) CVPixelBufferGetHeight(pb);
      const size_t bpr = CVPixelBufferIsPlanar(pb) ?
                           CVPixelBufferGetBytesPerRowOfPlane(pb, 0) :
                           CVPixelBufferGetBytesPerRow(pb);
      av_img->row_pitch = (int) bpr;
      av_img->pixel_pitch = av_img->width > 0 ? av_img->row_pitch / av_img->width : 0;
      av_img->frame_timestamp = frame_timestamp;
      av_img->host_processing_timestamp = host_processing_timestamp;
    }

    bool is_hdr() override {
      return hdr;
    }

    bool get_hdr_metadata(SS_HDR_METADATA &metadata) override {
      std::memset(&metadata, 0, sizeof(metadata));
      if (!hdr) {
        return false;
      }
      // Display P3 primaries (red, green, blue) and a D65 white point, normalized to 50,000: the
      // gamut of Apple's HDR displays and of Vibepollo's HDR virtual display.
      metadata.displayPrimaries[0] = {34000, 16000};
      metadata.displayPrimaries[1] = {13250, 34500};
      metadata.displayPrimaries[2] = {7500, 3000};
      metadata.whitePoint = {15635, 16450};
      metadata.maxDisplayLuminance = peak_nits();
      metadata.minDisplayLuminance = 50;  // 0.005 nits
      metadata.maxContentLightLevel = metadata.maxDisplayLuminance;
      metadata.maxFrameAverageLightLevel = static_cast<std::uint16_t>(sdr_white_nits);
      return true;
    }

    /// The display's peak brightness in the captured frames: its EDR headroom over SDR white.
    std::uint16_t peak_nits() const {
      return static_cast<std::uint16_t>(std::lround(std::min(headroom * sdr_white_nits, max_peak_nits)));
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      // Keep the display awake while capturing, as the Windows capture does: a sleeping display
      // sends no frames.
      IOPMAssertionID keep_awake = kIOPMNullAssertionID;
      const IOReturn awake_status = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("Vibepollo is streaming the display"),
        &keep_awake
      );
      auto release_keep_awake = util::fail_guard([awake_status, keep_awake]() {
        if (awake_status == kIOReturnSuccess && keep_awake != kIOPMNullAssertionID) {
          IOPMAssertionRelease(keep_awake);
        }
      });

      const std::uint64_t initial_scale_epoch = macos_virtual_display::scale_reinit_epoch();
      auto state = std::make_shared<capture_state_t>();
      // Copied to the heap: the capture can hold on to it after this function returns.
      FrameCallbackBlock on_frame = [^bool(CMSampleBufferRef sampleBuffer) {
        std::lock_guard lock {state->mutex};
        if (state->stopped) {
          return false;
        }
        if (macos_virtual_display::scale_reinit_epoch() != initial_scale_epoch) {
          const auto pixels = mode_pixels(display_id);
          if (pixels.first != 0 && captured_pixels.first != 0 && pixels != captured_pixels) {
            state->stopped = true;
            state->scale_reinit = true;
            return false;
          }
        }

        // Verify at ~4 Hz that ScreenCaptureKit is still delivering this display's bounds rather
        // than silently delivering another display after sleep or virtual display recreation.
        constexpr int max_wrong_source_reattaches = 3;
        const auto now = std::chrono::steady_clock::now();
        if (wrong_source_reattaches.load(std::memory_order_relaxed) < max_wrong_source_reattaches &&
            (state->last_source_check == std::chrono::steady_clock::time_point {} ||
             now - state->last_source_check >= 250ms)) {
          state->last_source_check = now;
          if (!macos_virtual_display::display_changes_settled()) {
            state->source_check.reset();
          } else {
            double rx = 0.0, ry = 0.0, rw = 0.0, rh = 0.0;
            if (macos_sc_sample_screen_rect(sampleBuffer, &rx, &ry, &rw, &rh)) {
              const CGRect bounds = CGDisplayBounds(display_id);
              const macos_display_policy::display_rect_t frame_rect {rx, ry, rw, rh};
              const macos_display_policy::display_rect_t expected_rect {
                bounds.origin.x,
                bounds.origin.y,
                bounds.size.width,
                bounds.size.height
              };
              if (state->source_check.mismatched(frame_rect, expected_rect, now)) {
                state->stopped = true;
                state->source_mismatch = true;
                state->mismatched_rect = frame_rect;
                state->expected_rect = expected_rect;
                return false;
              }
            }
          }
        }

        if (need_bootstrap_sample.load(std::memory_order_relaxed) &&
            need_bootstrap_sample.exchange(false, std::memory_order_relaxed)) {
          std::lock_guard sample_lock {latest_sample_mutex};
          if (latest_sample) {
            CFRelease(latest_sample);
          }
          latest_sample = (CMSampleBufferRef) CFRetain(sampleBuffer);
        }

        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          // got interrupt signal
          // returning false here stops capture backend
          state->stopped = true;
          return false;
        }
        auto av_img = std::static_pointer_cast<av_img_t>(img_out);
        populate_captured_img(av_img.get(), sampleBuffer, lock_cpu_pixels.load(std::memory_order_relaxed));

        if (!push_captured_image_cb(std::move(img_out), true)) {
          // got interrupt signal
          // returning false here stops capture backend
          state->stopped = true;
          return false;
        }

        state->last_frame = std::chrono::steady_clock::now();
        return true;
      } copy];
      dispatch_semaphore_t signal = nil;
      @autoreleasepool {
        signal = [av_capture capture:on_frame];
        if (signal != nil) {
          dispatch_retain(signal);
        }
      }
      [on_frame release];  // the capture keeps its own reference
      if (signal == nil) {
        return capture_e::error;
      }
      auto stop_capture_guard = util::fail_guard([this, signal]() {
        @autoreleasepool {
          [av_capture stopCaptureForSignal:signal];
        }
        dispatch_release(signal);
      });

      // Frames stop while the display sleeps. After a second without one, re-send the last image
      // every second, as the Linux captures do on a timeout: the stream stays up, and a stop
      // request is still seen. This also checks on the display at least once a second.
      macos_display_policy::display_presence_t presence {offline_grace};
      for (;;) {
        std::chrono::nanoseconds until_resend;
        {
          std::lock_guard lock {state->mutex};
          until_resend = state->last_frame + 1s - std::chrono::steady_clock::now();
        }
        if (until_resend > 0ns && dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, until_resend.count())) == 0) {
          break;
        }

        // Displays come and go as a MacBook's lid closes and opens. Set the capture up again, within
        // the same stream, when its display goes away or macOS gives it another size: that picks a
        // display that's there, and the encoder and input start over with the new size.
        const auto change = display_change(presence);

        std::lock_guard lock {state->mutex};
        if (state->stopped) {
          return capture_e::ok;
        }
        if (change) {
          state->stopped = true;
          BOOST_LOG(info) << "Display "sv << display_id << ' ' << *change << "; setting up capture again"sv;
          return macos_virtual_display::scale_reinit_epoch() != initial_scale_epoch ? capture_e::reinit : restart_status();
        }
        if (std::chrono::steady_clock::now() - state->last_frame < 1s) {
          continue;  // a frame arrived while waiting
        }
        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out) || !push_captured_image_cb(std::move(img_out), false)) {
          state->stopped = true;
          return capture_e::ok;
        }
        state->last_frame = std::chrono::steady_clock::now();
      }

      // The capture signals when a callback stops it, or when it stops by itself: ScreenCaptureKit
      // ends a stream on errors, such as its display going away. Start over in that case.
      std::lock_guard lock {state->mutex};
      if (state->scale_reinit) {
        BOOST_LOG(info) << "Display "sv << display_id << " backing scale changed; setting up capture again"sv;
        return capture_e::reinit;
      }
      if (state->source_mismatch) {
        const int count = wrong_source_reattaches.fetch_add(1, std::memory_order_relaxed) + 1;
        BOOST_LOG(warning) << "Capture of display "sv << display_id << " delivered frames from ("sv
                           << state->mismatched_rect.x << ',' << state->mismatched_rect.y << ' '
                           << state->mismatched_rect.width << 'x' << state->mismatched_rect.height
                           << ") instead of expected ("sv
                           << state->expected_rect.x << ',' << state->expected_rect.y << ' '
                           << state->expected_rect.width << 'x' << state->expected_rect.height
                           << "); reattaching capture ("sv << count << "/3)"sv;
        return restart_status();
      }
      if (!state->stopped) {
        state->stopped = true;
        BOOST_LOG(warning) << "Capture of display "sv << display_id << " stopped by itself ("sv << stop_reason() << "); restarting it"sv;
        return restart_status();
      }
      return capture_e::ok;
    }

    /// Why the captured display needs a new capture, if it does.
    std::optional<std::string_view> display_change(macos_display_policy::display_presence_t &presence) const {
      if (presence.lost(CGDisplayIsOnline(display_id), std::chrono::steady_clock::now())) {
        return "went offline"sv;
      }
      // While displays are still changing, the virtual display's mode may yet be put back.
      if (!macos_virtual_display::display_changes_settled()) {
        return std::nullopt;
      }
      const auto pixels = mode_pixels(display_id);
      if (pixels.first != 0 && captured_pixels.first != 0 && pixels != captured_pixels) {
        return "changed size"sv;
      }
      return std::nullopt;
    }

    capture_e restart_status() const {
      if (may_restart_capture()) {
        return capture_e::reinit;
      }
      BOOST_LOG(error) << "Capture had to restart more than 10 times in a minute; ending the stream. "sv
                       << "Check that a display is on and that Vibepollo still has Screen Recording permission"sv;
      return capture_e::error;
    }

    std::string stop_reason() const {
      @autoreleasepool {
        if ([av_capture isKindOfClass:[SCVideo class]]) {
          if (NSString *reason = static_cast<SCVideo *>(av_capture).stopReason) {
            if (const char *utf8 = reason.UTF8String) {
              return utf8;
            }
          }
        }
      }
      return "no reason given";
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        lock_cpu_pixels.store(true, std::memory_order_relaxed);
        av_capture.pixelFormat = kCVPixelFormatType_32BGRA;

        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        lock_cpu_pixels.store(false, std::memory_order_relaxed);
        auto device = std::make_unique<nv12_zero_device>();

        device->init(static_cast<void *>(av_capture), pix_fmt, setResolution, setPixelFormat);

        return device;
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    std::unique_ptr<vt_encode_device_t> make_vt_encode_device(pix_fmt_e pix_fmt, bool full_range) override {
      lock_cpu_pixels.store(false, std::memory_order_relaxed);
      auto *capture = av_capture;
      return vt::make_encode_device(
        pix_fmt, full_range,
        [capture](int width, int height) {
          @autoreleasepool {
            [capture setFrameWidth:width frameHeight:height];
          }
        },
        [capture](int pixel_format) {
          @autoreleasepool {
            capture.pixelFormat = pixel_format;
          }
        }
      );
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        // If we don't have the screen capture permission, this function will hang
        // indefinitely without doing anything useful. Exit instead to avoid this.
        // A non-zero return value indicates failure to the calling function.
        return 1;
      }

      const bool lock_cpu = lock_cpu_pixels.load(std::memory_order_relaxed);
      if (CMSampleBufferRef synthetic = create_dummy_sample(av_capture.frameWidth, av_capture.frameHeight, av_capture.pixelFormat)) {
        populate_captured_img(static_cast<av_img_t *>(img), synthetic, lock_cpu);
        CFRelease(synthetic);
        return 0;
      }
      {
        CMSampleBufferRef cached = nullptr;
        {
          std::lock_guard sample_lock {latest_sample_mutex};
          if (latest_sample) {
            CVImageBufferRef pb = CMSampleBufferGetImageBuffer(latest_sample);
            if (pb &&
                CVPixelBufferGetPixelFormatType(pb) == av_capture.pixelFormat &&
                (int) CVPixelBufferGetWidth(pb) == av_capture.frameWidth &&
                (int) CVPixelBufferGetHeight(pb) == av_capture.frameHeight) {
              cached = latest_sample;
              latest_sample = nullptr;
            } else {
              CFRelease(latest_sample);
              latest_sample = nullptr;
            }
          }
        }
        if (cached) {
          populate_captured_img(static_cast<av_img_t *>(img), cached, lock_cpu);
          CFRelease(cached);
          return 0;
        }
        need_bootstrap_sample.store(true, std::memory_order_relaxed);
      }

      auto state = std::make_shared<capture_state_t>();
      FrameCallbackBlock on_frame = [^bool(CMSampleBufferRef sampleBuffer) {
        std::lock_guard lock {state->mutex};
        if (state->stopped) {
          return false;
        }

        populate_captured_img(static_cast<av_img_t *>(img), sampleBuffer, lock_cpu);

        state->delivered = true;
        // returning false here stops capture backend
        return false;
      } copy];
      auto signal = [av_capture capture:on_frame];
      [on_frame release];  // the capture keeps its own reference
      if (signal == nil) {
        return 1;
      }
      auto stop_capture_guard = util::fail_guard([this, signal]() {
        [av_capture stopCaptureForSignal:signal];
      });

      // A display that's asleep sends nothing: fail, so the client gets an error instead of a
      // connection that hangs forever. The capture can also end by itself without an image.
      const int64_t wait_ns = platf::is_loginwindow_session() ? (600LL * NSEC_PER_MSEC) : (3LL * NSEC_PER_SEC);
      dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, wait_ns));
      std::lock_guard lock {state->mutex};
      state->stopped = true;
      if (!state->delivered) {
        if (platf::is_loginwindow_session()) {
          // Immediately after WindowServer boots into LoginWindow, an idle headless display may not
          // have emitted its first SCStream surface yet; synthesize one IOSurface-backed frame so
          // startup encoder probing completes in < 1s instead of delaying port binding by ~20s.
          video::config_t synth_cfg {};
          synth_cfg.width = std::max(1, av_capture.frameWidth);
          synth_cfg.height = std::max(1, av_capture.frameHeight);
          synth_cfg.framerate = 60;
          auto fallback = platf::black_display(synth_cfg);
          if (fallback) {
            if (lock_cpu) {
              (void) fallback->make_avcodec_encode_device(pix_fmt_e::yuv420p);
            } else {
              const pix_fmt_e fmt = (av_capture.pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange) ?
                                      pix_fmt_e::yuv444p16 :
                                      (av_capture.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ?
                                         pix_fmt_e::p010 :
                                         pix_fmt_e::nv12);
              (void) fallback->make_vt_encode_device(fmt, av_capture.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                                                        av_capture.pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange);
            }
            if (fallback->dummy_img(img) == 0) {
              return 0;
            }
          }
        }
        BOOST_LOG(error) << "Display "sv << display_id << " sent no image within 3 seconds"sv;
        return 1;
      }

      return 0;
    }

    /**
     * A bridge from the pure C++ code of the hwdevice_t class to the pure Objective C code.
     *
     * display --> an opaque pointer to an object of this class
     * width --> the intended capture width
     * height --> the intended capture height
     */
    static void setResolution(void *display, int width, int height) {
      [static_cast<AVVideo *>(display) setFrameWidth:width frameHeight:height];
    }

    static void setPixelFormat(void *display, OSType pixelFormat) {
      static_cast<AVVideo *>(display).pixelFormat = pixelFormat;
    }
  };

  /**
   * @brief Black frames for Remote Input, which needs a video stream but shows no display.
   * @details One black image in the format and size the encoder asks for, paced by
   *          capture_synthetic_black() like the other platforms' synthetic sources.
   */
  struct black_display_t: public display_t {
    explicit black_display_t(const video::config_t &config):
        frame_rate {std::max(1, config.framerate)} {
      width = logical_width = env_width = env_logical_width = std::max(1, config.width);
      height = logical_height = env_height = env_logical_height = std::max(1, config.height);
    }

    ~black_display_t() override {
      if (black) {
        CFRelease(black);
      }
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *) override {
      return capture_synthetic_black(push_captured_image_cb, pull_free_image_cb, frame_rate);
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    int dummy_img(img_t *img) override {
      std::lock_guard lock {mutex};
      if (!black) {
        black = create_dummy_sample(width, height, pixel_format);
        if (!black) {
          return 1;
        }
      }

      auto av_img = static_cast<av_img_t *>(img);
      av_img->sample_buffer = std::make_shared<av_sample_buf_t>(black);
      av_img->pixel_buffer = std::make_shared<av_pixel_buf_t>(av_img->sample_buffer->buf, lock_cpu_pixels);
      img->data = av_img->pixel_buffer->data();
      auto *pb = av_img->pixel_buffer->buf;
      img->width = (int) CVPixelBufferGetWidth(pb);
      img->height = (int) CVPixelBufferGetHeight(pb);
      const size_t bpr = CVPixelBufferIsPlanar(pb) ?
                           CVPixelBufferGetBytesPerRowOfPlane(pb, 0) :
                           CVPixelBufferGetBytesPerRow(pb);
      img->row_pitch = (int) bpr;
      img->pixel_pitch = img->width > 0 ? img->row_pitch / img->width : 0;
      return 0;
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        lock_cpu_pixels = true;
        set_format(kCVPixelFormatType_32BGRA, width, height);
        return std::make_unique<avcodec_encode_device_t>();
      }
      if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        lock_cpu_pixels = false;
        auto device = std::make_unique<nv12_zero_device>();
        device->init(
          this,
          pix_fmt,
          [](void *display, int frame_width, int frame_height) {
            auto self = static_cast<black_display_t *>(display);
            self->set_format(self->pixel_format, frame_width, frame_height);
          },
          [](void *display, int format) {
            auto self = static_cast<black_display_t *>(display);
            self->set_format(static_cast<OSType>(format), self->width, self->height);
          }
        );
        return device;
      }
      BOOST_LOG(error) << "Unsupported Pixel Format."sv;
      return nullptr;
    }

    std::unique_ptr<vt_encode_device_t> make_vt_encode_device(pix_fmt_e pix_fmt, bool full_range) override {
      lock_cpu_pixels = false;
      return vt::make_encode_device(
        pix_fmt, full_range,
        [this](int frame_width, int frame_height) {
          this->set_format(this->pixel_format, frame_width, frame_height);
        },
        [this](int format) {
          this->set_format(static_cast<OSType>(format), this->width, this->height);
        }
      );
    }

  private:
    void set_format(const OSType format, const int frame_width, const int frame_height) {
      std::lock_guard lock {mutex};
      if (format == pixel_format && frame_width == width && frame_height == height) {
        return;
      }
      pixel_format = format;
      width = frame_width;
      height = frame_height;
      if (black) {
        CFRelease(black);
        black = nullptr;
      }
    }

    std::mutex mutex;
    OSType pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CMSampleBufferRef black = nullptr;
    bool lock_cpu_pixels = false;
    int frame_rate;
  };

  std::shared_ptr<display_t> black_display(const video::config_t &config) {
    return std::make_shared<black_display_t>(config);
  }

  std::shared_ptr<display_t> display(
    platf::mem_type_e hwdevice_type,
    const std::string &display_name,
    const video::config_t &config,
    const std::optional<adapter_id_t> &required_adapter
  ) {
    @autoreleasepool {
    (void) required_adapter;
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
      return nullptr;
    }

    // Like the Windows capture, power the displays on if they're asleep: a client connecting to a
    // sleeping Mac only half-wakes it, and a sleeping display sends no frames.
    wake_displays();

    auto display = std::make_shared<av_display_t>();
    display->lock_cpu_pixels.store(hwdevice_type == platf::mem_type_e::system, std::memory_order_relaxed);
    // create_dummy_sample() handles synthetic black bootstrap frames for both hardware and
    // software paths; never pin the first captured SCStream IOSurface in latest_sample.
    display->need_bootstrap_sample.store(false, std::memory_order_relaxed);

    // Default to main display
    display->display_id = CGMainDisplayID();

    // Print all displays available with it's name and id
    auto display_array = [AVVideo displayNames];
    BOOST_LOG(info) << "Detecting displays"sv;
    for (NSDictionary *item in display_array) {
      NSNumber *display_id = item[@"id"];
      // We need show display's product name and corresponding display number given by user
      NSString *name = item[@"displayName"];
      const char *name_utf8 = (name && name.UTF8String) ? name.UTF8String : "Unknown";
      const unsigned int item_id = display_id ? [display_id unsignedIntValue] : 0;
      // We are using CGGetActiveDisplayList that only returns active displays so hardcoded connected value in log to true
      BOOST_LOG(info) << "Detected display: "sv << name_utf8 << " (id: "sv << item_id << ") connected: true"sv;
      if (!display_name.empty() && display_id && static_cast<unsigned int>(std::atoi(display_name.c_str())) == item_id) {
        display->display_id = item_id;
      }
    }
    // A Remote Monitor stream captures its own display. For any other stream, the stream's virtual
    // display, while there is one, takes precedence over output_name.
    const bool remote_monitor = macos_virtual_display::is_remote_display(display->display_id);
    if (const auto virtual_id = macos_virtual_display::active_display_id(); virtual_id && !remote_monitor) {
      display->display_id = *virtual_id;
    }
    BOOST_LOG(info) << "Configuring selected display ("sv << display->display_id << ") to stream"sv;

    // HDR needs ScreenCaptureKit's HDR capture, from macOS 15, and an HDR display: Vibepollo's HDR
    // virtual display, or a physical one with EDR headroom, such as a MacBook Pro's.
    if (config.dynamicRange > 0 && !config.prefer_sdr_10bit && !config.force_sdr) {
      if (@available(macOS 15.0, *)) {
        display->headroom = edr_headroom(display->display_id);
        if (macos_virtual_display::is_hdr_display(display->display_id)) {
          // AppKit can lag behind a display that was just created.
          display->headroom = std::max(display->headroom, virtual_display_headroom);
        }
        display->hdr = display->headroom > 1.0;
      }
      if (display->hdr) {
        BOOST_LOG(info) << "Capturing HDR, up to "sv << display->peak_nits() << " nits"sv;
      } else {
        BOOST_LOG(info) << "Display "sv << display->display_id << " can't be captured in HDR, so the stream is SDR"sv;
      }
    }

    // AVCaptureScreenInput delivers no frames from virtual displays, nor HDR; ScreenCaptureKit does.
    if (remote_monitor || macos_virtual_display::active_display_id() == display->display_id || display->hdr || hwdevice_type == platf::mem_type_e::videotoolbox) {
      SCVideo *capture = [[SCVideo alloc] initWithDisplay:display->display_id frameRate:config.framerate];
      if (capture) {
        capture.hdr = display->hdr;
        if (hwdevice_type == platf::mem_type_e::videotoolbox) {
          // Async PARALLEL_ENCODING enforces minimum_fps_target in encode_run() and only wraps
          // IOSurface handles in the callback, so deliver directly on sampleQueue without a
          // duplicate keepalive timer.
          capture.directDelivery = YES;
        } else {
          // The sync encode path only encodes delivered frames, so enforce the minimum frame rate here
          // (the same default as video.cpp: a fifth of the stream's rate, at least 10 fps).
          const double minimum_fps = config::video.minimum_fps_target > 0 ? config::video.minimum_fps_target : std::max(config.framerate / 5.0, 10.0);
          capture.keepaliveInterval = CMTimeMakeWithSeconds(1.0 / minimum_fps, 1000000);
        }
        display->av_capture = capture;
      } else if (cg_stream_api_t::get().available()) {
        BOOST_LOG(info) << "ScreenCaptureKit unavailable for display "sv << display->display_id
                        << "; falling back to CGDisplayStream capture"sv;
        display->hdr = false;
        display->headroom = 1.0;
        CGStreamVideo *cg_capture = [[CGStreamVideo alloc] initWithDisplay:display->display_id frameRate:config.framerate];
        if (cg_capture && hwdevice_type != platf::mem_type_e::videotoolbox) {
          const double minimum_fps = config::video.minimum_fps_target > 0 ? config::video.minimum_fps_target : std::max(config.framerate / 5.0, 10.0);
          cg_capture.keepaliveInterval = CMTimeMakeWithSeconds(1.0 / minimum_fps, 1000000);
        }
        display->av_capture = cg_capture;
      }
    } else {
      display->av_capture = [[AVVideo alloc] initWithDisplay:display->display_id frameRate:config.framerate];
      if (!display->av_capture && cg_stream_api_t::get().available()) {
        display->av_capture = [[CGStreamVideo alloc] initWithDisplay:display->display_id frameRate:config.framerate];
      }
    }

    if (!display->av_capture) {
      BOOST_LOG(error) << "Video setup failed."sv;
      return nullptr;
    }

    display->width = display->av_capture.frameWidth;
    display->height = display->av_capture.frameHeight;
    display->captured_pixels = mode_pixels(display->display_id);
    // We also need set env_width and env_height for absolute mouse coordinates
    display->env_width = display->width;
    display->env_height = display->height;

    if (hwdevice_type == platf::mem_type_e::videotoolbox) {
      // Pre-configure capture pixel format and output dimensions before captureThread starts SCStream;
      // otherwise async PARALLEL_ENCODING starts SCStream in 32BGRA SDR before make_vt_encode_device runs.
      const auto colorspace = video::colorspace_from_client_config(config, display->hdr);
      display->av_capture.pixelFormat = vt::capture_pixel_format(config.chromaSamplingType == 1, colorspace.bit_depth == 10, colorspace.full_range);
      if (config.width > 0 && config.height > 0) {
        [display->av_capture setFrameWidth:config.width frameHeight:config.height];
      }
    }
    // Where the display sits on the desktop, in points.
    const CGRect bounds = CGDisplayBounds(display->display_id);
    display->offset_x = static_cast<int>(bounds.origin.x);
    display->offset_y = static_cast<int>(bounds.origin.y);
    // The stream's input carries the display's ID, so a Remote Monitor client's pointer stays on
    // its own display wherever that display moves, and wherever other displays take its old place.
    display->input_output_name = std::to_string(display->display_id);

    return display;
    }
  }

  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    (void) hwdevice_type;
    @autoreleasepool {
      __block std::vector<std::string> display_names;

      auto display_array = [AVVideo displayNames];

      display_names.reserve([display_array count]);
      [display_array enumerateObjectsUsingBlock:^(NSDictionary *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
        (void) idx;
        (void) stop;
        NSString *name = obj[@"name"];
        if (name && name.UTF8String) {
          display_names.emplace_back(name.UTF8String);
        }
      }];

      return display_names;
    }
  }

  /**
   * @brief Returns if GPUs/drivers have changed since the last call to this function.
   * @return `true` if a change has occurred or if it is unknown whether a change occurred.
   */
  bool needs_encoder_reenumeration() {
    // We don't track GPU state, so we will always reenumerate. Fortunately, it is fast on macOS.
    return true;
  }
}  // namespace platf
