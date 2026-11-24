/**
 * @file src/platform/macos/vt_encoder.mm
 * @brief Definitions for the native VideoToolbox encoder on macOS.
 *
 * Encodes captured CVPixelBuffers directly through a VTCompressionSession using a bounded
 * 3-stage hardware pipeline (`max_in_flight = 3`, matching AppleAVE2's internal stage depth
 * for 120fps Retina YUV 4:4:4 HDR). With `AllowFrameReordering = false`, VideoToolbox invokes
 * the completion callback strictly in FIFO submission order and dispatches packets directly.
 */
// standard includes
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <limits>
#include <mutex>
#include <vector>

// platform includes
#import <Foundation/Foundation.h>
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>

// local includes
#include "src/cbs.h"
#include "src/logging.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/cf_guard.h"
#include "src/platform/macos/vt_encoder.h"
#include "src/utility.h"
#include "src/video.h"

namespace {
  using namespace std::literals;

  /**
   * @brief Blocking one-frame-in-flight wrapper around a VTCompressionSession.
   */
  class vt_compression_session_t {
  public:
    ~vt_compression_session_t() {
      if (session) {
        VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
        // Guarantees no output callbacks after return
        VTCompressionSessionInvalidate(session);
        CFRelease(session);
      }
      std::lock_guard lg {mutex};
      for (auto &slot : slots) {
        slot.clear();
      }
      in_flight = 0;
      in_flight_atomic.store(0, std::memory_order_relaxed);
    }

    /**
     * @brief Create and configure the compression session.
     *
     * @param codec CoreMedia codec type to encode.
     * @param config Client stream configuration negotiated for this session.
     * @param colorspace Colorimetry information used for encoding.
     * @return True when the session is ready to encode.
     */
    bool init(
      CMVideoCodecType codec,
      const video::config_t &config,
      const video::sunshine_colorspace_t &colorspace,
      const SS_HDR_METADATA *hdr_metadata = nullptr
    ) {
      width = config.width;
      height = config.height;
      framerate = config.framerate;
      codec_type = codec;
      requested_full_range = colorspace.full_range;
      const bool yuv444_input = config.chromaSamplingType == 1;
      encoder_pixel_format = platf::vt::capture_pixel_format(yuv444_input, colorspace.bit_depth == 10, requested_full_range);
      if (yuv444_input && !requested_full_range) {
        encoder_pixel_format = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange;
      } else if (!yuv444_input && colorspace.bit_depth == 10 && requested_full_range) {
        encoder_pixel_format = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
      }
      is_hdr_colorspace = video::colorspace_is_hdr(colorspace);
      // AppleAVE2 HEVC is a 3-stage hardware ASIC at 497.7 Mpx/s Turbo: keep 3 stages up to 2752x2064
      // (~120fps) and 2 pipelined stages on 4K (>6.5M px). By contrast, M4 H.264 has no Turbo mode
      // (capped at 248.8 Mpx/s) and gains <8% throughput from 3-stage pipelining while tripling
      // queuing latency (11.7ms -> 32.6ms at 2752x2064, 4.6ms -> 12.5ms at 1080p); keep H.264 at 1
      // in-flight frame so `wait_for_slot()` always feeds the freshest SCStream capture with zero backlog.
      const std::int64_t pixels_per_frame = static_cast<std::int64_t>(width) * height;
      if (codec == kCMVideoCodecType_H264) {
        max_in_flight_limit = 1;
      } else {
        max_in_flight_limit = pixels_per_frame > 6'500'000 && framerate >= 100 ? 2 : 3;
      }

#if defined(__arm64__) || defined(__aarch64__)
      constexpr bool arm64 = true;
#else
      constexpr bool arm64 = false;
#endif
      const bool try_low_latency = platf::vt::try_low_latency(codec, arm64);
      bool low_latency = try_low_latency && create_session(codec, config, true);
      if (!low_latency && !create_session(codec, config, false)) {
        BOOST_LOG(error) << "VideoToolbox could not create a compression session"sv;
        return false;
      }
      if (try_low_latency && !low_latency) {
        BOOST_LOG(info) << "VideoToolbox low-latency rate control is unavailable; using standard rate control"sv;
      }
      is_low_latency = low_latency;
      BOOST_LOG(info) << "VideoToolbox session uses "sv << (low_latency ? "low-latency"sv : "standard"sv) << " rate control"sv;

      set_property(kVTCompressionPropertyKey_RealTime, config::video.vt.vt_realtime ? kCFBooleanTrue : kCFBooleanFalse, "RealTime"sv);
      set_property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering"sv);
      set_property(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue, "PrioritizeEncodingSpeedOverQuality"sv);
      set_property(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse, "MaximizePowerEfficiency"sv);
      set_int_property(CFSTR("SpatialAdaptiveQPLevel"), 0, "SpatialAdaptiveQPLevel"sv);
      if (codec == kCMVideoCodecType_H264) {
        // Low-latency H.264 sessions mark pictures as long-term references by default; some
        // client hardware decoders mishandle that and freeze, so keep to short-term references.
        set_property(kVTCompressionPropertyKey_EnableLTR, kCFBooleanFalse, "EnableLTR"sv);
        if (const auto entropy_mode = platf::vt::h264_entropy_mode(config::video.vt.vt_coder)) {
          set_property(kVTCompressionPropertyKey_H264EntropyMode, entropy_mode, "H264EntropyMode"sv);
        }
      }

      CFStringRef profile;
      const bool yuv444 = (config.chromaSamplingType == 1);
      if (codec == kCMVideoCodecType_HEVC) {
        if (yuv444) {
          profile = colorspace.bit_depth == 10 ? CFSTR("HEVC_Main44410_AutoLevel") : CFSTR("HEVC_Main444_AutoLevel");
        } else {
          profile = colorspace.bit_depth == 10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel;
        }
      } else {
        profile = kVTProfileLevel_H264_High_AutoLevel;
      }
      if (!set_property(kVTCompressionPropertyKey_ProfileLevel, profile, "ProfileLevel"sv) &&
          (colorspace.bit_depth == 10 || yuv444)) {
        // 10-bit or YUV 4:4:4 output without the matching profile would encode the wrong format
        return false;
      }

      // Select AppleAVE2's highest supported hardware pixel clock mode ("turbo" first, e.g. ID=5
      // at 497.7 Mpx/s on M4 HEVC; falling back to "normal", e.g. ID=3 at 248.8 Mpx/s on M4 H.264
      // so H.264 never drops to half-rate 124.4 Mpx/s "full" mode). Must be applied after ProfileLevel.
      int selected_tp_mode_id = 0;
      std::string_view selected_tp_tier;
      CFTypeRef tp_modes_ref = nullptr;
      if (VTSessionCopyProperty(session, CFSTR("SupportedThroughputModes"), kCFAllocatorDefault, &tp_modes_ref) == noErr && tp_modes_ref) {
        if (CFGetTypeID(tp_modes_ref) == CFDictionaryGetTypeID()) {
          auto tp_modes = static_cast<CFDictionaryRef>(tp_modes_ref);
          const auto pick_tier = [&](CFStringRef key, std::string_view tier_name) {
            if (selected_tp_mode_id > 0) {
              return;
            }
            if (auto list = static_cast<CFArrayRef>(CFDictionaryGetValue(tp_modes, key));
                list && CFGetTypeID(list) == CFArrayGetTypeID() && CFArrayGetCount(list) > 0) {
              if (auto first = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(list, 0));
                  first && CFGetTypeID(first) == CFDictionaryGetTypeID()) {
                if (auto id_num = static_cast<CFNumberRef>(CFDictionaryGetValue(first, CFSTR("ThroughputModeID")));
                    id_num && CFGetTypeID(id_num) == CFNumberGetTypeID()) {
                  CFNumberGetValue(id_num, kCFNumberIntType, &selected_tp_mode_id);
                  if (selected_tp_mode_id > 0) {
                    selected_tp_tier = tier_name;
                  }
                }
              }
            }
          };
          pick_tier(CFSTR("turbo"), "turbo"sv);
          pick_tier(CFSTR("normal"), "normal"sv);
        }
        CFRelease(tp_modes_ref);
      }
      if (selected_tp_mode_id > 0 && set_int_property(CFSTR("ThroughputMode"), selected_tp_mode_id, "ThroughputMode"sv)) {
        BOOST_LOG(info) << "VideoToolbox: enabled hardware "sv << selected_tp_tier << " ThroughputMode="sv << selected_tp_mode_id;
      }
      set_property(CFSTR("EnableVUIBitstreamRestriction"), kCFBooleanTrue, "EnableVUIBitstreamRestriction"sv);
      set_property(CFSTR("ThrottleForBackground"), kCFBooleanFalse, "ThrottleForBackground"sv);
      if (codec == kCMVideoCodecType_HEVC) {
        set_property(CFSTR("PerceptualQualityOptimization"), kCFBooleanTrue, "PerceptualQualityOptimization"sv);
        // GFN NVENC-P1 equivalent on AppleAVE2: narrow hardware motion search window (Mode 6 = 96x64
        // vs default Mode 4 = 320x192), boosting M4 2752x2064 4:4:4 10-bit throughput by +37.7%.
        if (set_int_property(CFSTR("MotionEstimationSearchMode"), 6, "MotionEstimationSearchMode"sv)) {
          BOOST_LOG(info) << "VideoToolbox: enabled ultra-low-latency MotionEstimationSearchMode=6 (96x64)"sv;
        }
      } else if (codec == kCMVideoCodecType_H264) {
        // Narrowest supported H.264 motion search window on AppleAVE2 (Mode 1 = 128x64 vs default Mode 0 = 192x96).
        if (set_int_property(CFSTR("MotionEstimationSearchMode"), 1, "MotionEstimationSearchMode"sv)) {
          BOOST_LOG(info) << "VideoToolbox: enabled low-latency H.264 MotionEstimationSearchMode=1 (128x64)"sv;
        }
      }
      // GFN Multi-Slice parallel encoding: enforce >= 4 slices per frame on Retina streams even when
      // the client negotiates slicesPerFrame=1 so encoders and client decoders pipeline slices concurrently.
      const int target_slices = std::max(config.slicesPerFrame, 4);
      if (set_int_property(CFSTR("NumberOfSlices"), target_slices, "NumberOfSlices"sv)) {
        BOOST_LOG(info) << "VideoToolbox: enabled hardware multi-slice encoding ("sv << target_slices << " slices/frame)"sv;
      }

      // Honor the host-side bitrate ceiling, matching the avcodec path
      const int bitrate_kbps = config::video.max_bitrate > 0 ? std::min(config.bitrate, config::video.max_bitrate) : config.bitrate;
      // No DataRateLimits under low-latency rate control: with a hard byte window it drops frames
      // that would exceed it (e.g. full-screen changes at 4K120). Without it, AverageBitRate still
      // steers the rate and oversized frames cost quality on later frames instead of a drop.
      set_int_property(kVTCompressionPropertyKey_AverageBitRate, bitrate_kbps * 1000, "AverageBitRate"sv);
      if (!low_latency) {
        // Standard rate control treats AverageBitRate as a long-term target, so bound each second
        // to the bitrate and constrain AppleAVE2's internal VBV buffer from 1.0s down to 50ms
        // (GFN tight-VBV tuning: -4.3ms single-frame encode latency on M4 with 0 frame drops).
        set_data_rate_limit(bitrate_kbps * 1000 / 8);
        set_double_property(CFSTR("VBVBufferDuration"), 0.05, "VBVBufferDuration"sv);
        set_int_property(CFSTR("VBVInitialDelayPercentage"), 10, "VBVInitialDelayPercentage"sv);
      }
      const int expected_rate = platf::vt::expected_frame_rate(codec, config.width, config.height, config.framerate);
      if (expected_rate != config.framerate) {
        BOOST_LOG(info) << "VideoToolbox H.264 expected frame rate capped at "sv << expected_rate << " (level 5.2 limit for "sv
                        << config.width << 'x' << config.height << ")"sv;
      }
      set_int_property(kVTCompressionPropertyKey_ExpectedFrameRate, expected_rate, "ExpectedFrameRate"sv);
      // Do NOT set kVTCompressionPropertyKey_MaximumRealTimeFrameRate: VideoToolbox enforces it as a
      // hard wall-clock arrival limiter and drops any VSync frame arriving < 1/fps after the previous
      // one (kVTEncodeInfo_FrameDropped), leaving frameIndex gaps that stall Moonlight's RTP decoder
      // and trigger continuous emergency IDR freezes (0 -> 14 IDRs in 36s at 120Hz).
      set_int_property(kVTCompressionPropertyKey_MaxKeyFrameInterval, std::numeric_limits<int>::max(), "MaxKeyFrameInterval"sv);
      apply_colorspace(colorspace);
      if (hdr_metadata && is_hdr_colorspace) {
        apply_hdr_metadata(*hdr_metadata, false);
      }

      const auto prepare_status = VTCompressionSessionPrepareToEncodeFrames(session);
      if (prepare_status != noErr) {
        BOOST_LOG(warning) << "VTCompressionSessionPrepareToEncodeFrames failed: "sv << prepare_status;
      }
      return true;
    }

    bool set_bitrate(int requested_kbps) {
      if (!session || requested_kbps <= 0) {
        return false;
      }
      const int bitrate_kbps = config::video.max_bitrate > 0 ? std::min(requested_kbps, config::video.max_bitrate) : requested_kbps;
      if (!set_int_property(kVTCompressionPropertyKey_AverageBitRate, bitrate_kbps * 1000, "AverageBitRate"sv)) {
        return false;
      }
      if (!is_low_latency) {
        set_data_rate_limit(bitrate_kbps * 1000 / 8);
      }
      return true;
    }

    void set_hdr_metadata(const SS_HDR_METADATA &hdr) {
      if (!session || !is_hdr_colorspace) {
        return;
      }
      apply_hdr_metadata(hdr, true);
    }

    /**
     * @brief Submit one frame to the bounded 3-stage hardware pipeline, invoking `on_packet`
     *        directly from VideoToolbox's FIFO completion callback unless `sync_flush` is set.
     */
    int submit(
      CVPixelBufferRef raw_pixel_buffer,
      std::shared_ptr<platf::av_sample_buf_t> sample_owner,
      std::shared_ptr<platf::av_pixel_buf_t> pixel_owner,
      const platf::vt_frame_metadata_t &meta,
      bool force_idr,
      platf::vt_encode_device_t::packet_callback_t on_packet,
      bool sync_flush,
      uint64_t source_generation = 0
    ) {
      if (!session || !raw_pixel_buffer) {
        return -1;
      }

      if (CVPixelBufferGetWidth(raw_pixel_buffer) != (size_t) width || CVPixelBufferGetHeight(raw_pixel_buffer) != (size_t) height) {
        BOOST_LOG(error) << "VideoToolbox captured frame is "sv << CVPixelBufferGetWidth(raw_pixel_buffer) << 'x' << CVPixelBufferGetHeight(raw_pixel_buffer)
                         << " but the session expects "sv << width << 'x' << height;
        return -1;
      }

      // Capture directly into the encoder format when SCK supports it. When the
      // ranges differ, convert once per captured source generation (keyed by monotonic
      // generation rather than CVPixelBufferRef pointer identity so we never retain an
      // SCStream IOSurface across frames or alias recycled pool buffers) and keep the
      // converted buffer owned by the in-flight slot until VideoToolbox finishes encoding.
      const auto input_format = CVPixelBufferGetPixelFormatType(raw_pixel_buffer);
      platf::cf_ref_t<CVPixelBufferRef> slot_converted_buffer;
      if (input_format != encoder_pixel_format) {
        if (source_generation == 0 || source_generation != last_transfer_generation || !last_transfer_result) {
          if (!range_transfer) {
            VTPixelTransferSessionRef transfer = nullptr;
            if (VTPixelTransferSessionCreate(nullptr, &transfer) != noErr) {
              return -1;
            }
            range_transfer.reset(transfer);
            if (color_primaries) {
              (void) VTSessionSetProperty(range_transfer.get(), kVTPixelTransferPropertyKey_DestinationColorPrimaries, color_primaries);
            }
            if (color_transfer) {
              (void) VTSessionSetProperty(range_transfer.get(), kVTPixelTransferPropertyKey_DestinationTransferFunction, color_transfer);
            }
            if (color_matrix) {
              (void) VTSessionSetProperty(range_transfer.get(), kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, color_matrix);
            }
          }
          auto pool = VTCompressionSessionGetPixelBufferPool(session);
          CVPixelBufferRef buffer = nullptr;
          if (!pool || CVPixelBufferPoolCreatePixelBuffer(nullptr, pool, &buffer) != kCVReturnSuccess || !buffer) {
            return -1;
          }
          platf::cf_ref_t<CVPixelBufferRef> converted {buffer};
          if (color_primaries) {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, color_primaries, kCVAttachmentMode_ShouldPropagate);
          }
          if (color_transfer) {
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, color_transfer, kCVAttachmentMode_ShouldPropagate);
          }
          if (color_matrix) {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, color_matrix, kCVAttachmentMode_ShouldPropagate);
          }
          if (CVPixelBufferGetPixelFormatType(buffer) != encoder_pixel_format ||
              VTPixelTransferSessionTransferImage(range_transfer.get(), raw_pixel_buffer, buffer) != noErr) {
            BOOST_LOG(error) << "VideoToolbox could not convert the capture to the negotiated pixel range";
            return -1;
          }
          last_transfer_generation = source_generation;
          last_transfer_result = std::move(converted);
        }
        // Release the SCStream IOSurface immediately since transfer has completed synchronously.
        pixel_owner.reset();
        sample_owner.reset();
        raw_pixel_buffer = last_transfer_result.get();
        slot_converted_buffer.reset(CVPixelBufferRetain(raw_pixel_buffer));
      } else {
        last_transfer_generation = 0;
        last_transfer_result.reset();
      }
      if (!logged_input_format) {
        const auto fourcc = [](OSType f) { return std::string {char(f >> 24), char(f >> 16), char(f >> 8), char(f)}; };
        BOOST_LOG(info) << "VideoToolbox capture=" << fourcc(input_format) << " encoder input=" << fourcc(encoder_pixel_format)
                        << " requested range=" << (requested_full_range ? "full" : "video");
        logged_input_format = true;
      }
      uint64_t seq = 0;
      {
        std::unique_lock lock {mutex};
        if (!cv.wait_for(lock, 1s, [this] {
              return sticky_error || in_flight < max_in_flight_limit;
            })) {
          BOOST_LOG(error) << "VideoToolbox pipeline wait timed out (in_flight="sv << in_flight << ')';
          return -1;
        }
        if (sticky_error) {
          return -1;
        }
        if (need_idr) {
          force_idr = true;
          need_idr = false;
        }

        seq = next_slot_seq++;
        auto &slot = slots[seq & (slot_ring_size - 1)];
        slot.clear();
        slot.active = true;
        slot.seq = seq;
        slot.force_idr = force_idr;
        slot.meta = meta;
        slot.meta.submitted_at = std::chrono::steady_clock::now();
        slot.sample_buffer = std::move(sample_owner);
        slot.pixel_buffer = std::move(pixel_owner);
        slot.converted_buffer = std::move(slot_converted_buffer);
        slot.on_packet = std::move(on_packet);
        ++in_flight;
        in_flight_atomic.store(in_flight, std::memory_order_relaxed);
      }

      CFDictionaryRef frame_options = nullptr;
      if (force_idr) {
        CFMutableDictionaryRef options = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(options, kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
        frame_options = options;
      }
      const CMTime pts = CMTimeMake(meta.frame_index, framerate);
      const auto encode_status = VTCompressionSessionEncodeFrame(
        session,
        raw_pixel_buffer,
        pts,
        kCMTimeInvalid,
        frame_options,
        reinterpret_cast<void *>(static_cast<uintptr_t>(seq)),
        nullptr
      );
      if (frame_options) {
        CFRelease(frame_options);
      }
      if (encode_status != noErr) {
        {
          std::lock_guard lg {mutex};
          auto &slot = slots[seq & (slot_ring_size - 1)];
          if (slot.active && slot.seq == seq) {
            slot.clear();
            if (in_flight > 0) {
              --in_flight;
            }
            in_flight_atomic.store(in_flight, std::memory_order_relaxed);
          }
          sticky_error = true;
          cv.notify_all();
        }
        BOOST_LOG(error) << "VTCompressionSessionEncodeFrame failed: "sv << encode_status;
        return -1;
      }

      if (sync_flush && !flush()) {
        return -1;
      }
      return 0;
    }

    bool flush() {
      if (!session) {
        return false;
      }
      const auto status = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
      std::lock_guard lg {mutex};
      if (status != noErr) {
        BOOST_LOG(error) << "VTCompressionSessionCompleteFrames failed: "sv << status;
        sticky_error = true;
      }
      return !sticky_error;
    }

    bool wait_for_slot() {
      if (!session) {
        return false;
      }
      std::unique_lock lock {mutex};
      // Keep the wait bounded (50ms) so transient GPU stalls never tear down the stream
      // and shutdown/reinit checks stay responsive; only sticky_error is fatal.
      cv.wait_for(lock, 50ms, [this] {
        return sticky_error || in_flight < max_in_flight_limit;
      });
      return !sticky_error;
    }

    std::size_t in_flight_count() const {
      return in_flight_atomic.load(std::memory_order_relaxed);
    }

    /**
     * @brief Encode one frame synchronously, blocking until the encoded output is available.
     */
    platf::vt_encoded_frame encode(CVPixelBufferRef pixel_buffer, uint64_t frame_index, bool force_idr) {
      platf::vt_encoded_frame result;
      platf::vt_frame_metadata_t meta {.frame_index = frame_index};
      const int st = submit(
        pixel_buffer,
        nullptr,
        nullptr,
        meta,
        force_idr,
        [&result](platf::vt_encoded_frame &&frame, const platf::vt_frame_metadata_t &) {
          result = std::move(frame);
        },
        true
      );
      if (st != 0) {
        return {};
      }
      return result;
    }

  private:
    static constexpr std::size_t slot_ring_size = 8;

    struct in_flight_slot_t {
      bool active = false;
      uint64_t seq = 0;
      bool force_idr = false;
      platf::vt_frame_metadata_t meta;
      std::shared_ptr<platf::av_sample_buf_t> sample_buffer;
      std::shared_ptr<platf::av_pixel_buf_t> pixel_buffer;
      platf::cf_ref_t<CVPixelBufferRef> converted_buffer;
      platf::vt_encode_device_t::packet_callback_t on_packet;

      void clear() {
        active = false;
        seq = 0;
        force_idr = false;
        meta = {};
        on_packet = nullptr;
        converted_buffer.reset();
        // Unlock CVPixelBuffer before releasing the owning CMSampleBuffer.
        pixel_buffer.reset();
        sample_buffer.reset();
      }
    };

    static void output_callback(void *refcon, void *source_frame_refcon, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample_buffer) {
      const auto completed_at = std::chrono::steady_clock::now();
      auto self = static_cast<vt_compression_session_t *>(refcon);
      const uint64_t seq = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(source_frame_refcon));

      platf::vt_frame_metadata_t local_meta;
      bool local_force_idr = false;
      platf::vt_encode_device_t::packet_callback_t local_on_packet;
      std::shared_ptr<platf::av_sample_buf_t> local_sample_buf;
      std::shared_ptr<platf::av_pixel_buf_t> local_pixel_buf;
      platf::cf_ref_t<CVPixelBufferRef> local_converted_buf;
      platf::vt_encoded_frame encoded;
      bool ok = false;
      bool sync = true;
      std::vector<uint8_t> sync_parameter_sets;
      std::vector<uint8_t> sync_hdr_sei;

      {
        std::lock_guard lg {self->mutex};
        auto &slot = self->slots[seq & (slot_ring_size - 1)];
        if (slot.active && slot.seq == seq) {
          local_meta = slot.meta;
          local_meta.completed_at = completed_at;
          local_force_idr = slot.force_idr;
          local_on_packet = std::move(slot.on_packet);
          local_sample_buf = std::move(slot.sample_buffer);
          local_pixel_buf = std::move(slot.pixel_buffer);
          local_converted_buf = std::move(slot.converted_buffer);
          slot.active = false;
          slot.seq = 0;
          if (self->in_flight > 0) {
            --self->in_flight;
          }
          self->in_flight_atomic.store(self->in_flight, std::memory_order_relaxed);
        }

        if (status != noErr) {
          BOOST_LOG(error) << "VideoToolbox encode failed: "sv << status;
          self->sticky_error = true;
        } else if ((flags & kVTEncodeInfo_FrameDropped) || !sample_buffer) {
          self->need_idr = true;
          BOOST_LOG(warning) << "VideoToolbox dropped frame "sv << local_meta.frame_index << ", re-arming IDR"sv;
        } else {
          CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample_buffer, false);
          if (attachments && CFArrayGetCount(attachments) > 0) {
            auto dict = (CFDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
            auto not_sync = (CFBooleanRef) CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
            sync = !not_sync || !CFBooleanGetValue(not_sync);
          }

          CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample_buffer);
          if (format && (!self->last_format || !CMFormatDescriptionEqual(format, self->last_format.get()))) {
            if (!sync && self->last_format) {
              BOOST_LOG(warning) << "VideoToolbox format description changed without a keyframe, forcing IDR"sv;
              self->need_idr = true;
            }
            const auto full_range = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_FullRangeVideo);
            const bool encoded_full = full_range && CFEqual(full_range, kCFBooleanTrue);
            BOOST_LOG(info) << "VideoToolbox encoded range=" << (encoded_full ? "full" : "video");
            if (encoded_full != self->requested_full_range) {
              BOOST_LOG(warning) << "VideoToolbox output range differs from the negotiated range";
            }
            CFRetain(format);
            self->last_format.reset(format);
            self->cached_parameter_sets = build_patched_parameter_sets(format);
          }

          if (local_force_idr && !sync) {
            BOOST_LOG(warning) << "VideoToolbox did not honor IDR on frame "sv << local_meta.frame_index << ", re-arming IDR"sv;
            self->need_idr = true;
          }

          if (sync) {
            sync_parameter_sets = self->cached_parameter_sets;
            sync_hdr_sei = self->cached_hdr_sei;
          }
          ok = true;
        }

        self->cv.notify_all();
      }

      // Return SCStream's IOSurface and any converted buffer immediately before Annex-B packing & network enqueue.
      local_converted_buf.reset();
      local_pixel_buf.reset();
      local_sample_buf.reset();

      if (ok) {
        const bool use_cached_ps = sync && !sync_parameter_sets.empty();
        if (use_cached_ps) {
          encoded.data = std::move(sync_parameter_sets);
        }
        const std::span<const uint8_t> prefix_sei = sync ? std::span<const uint8_t> {sync_hdr_sei} : std::span<const uint8_t> {};
        if (!platf::vt::append_annexb(sample_buffer, sync && !use_cached_ps, encoded.data, prefix_sei)) {
          encoded.data.clear();
          ok = false;
          std::lock_guard lg {self->mutex};
          self->sticky_error = true;
          self->cv.notify_all();
        } else {
          encoded.frame_index = local_meta.frame_index;
          encoded.idr = sync;
          std::lock_guard lg {self->mutex};
          self->frame_size_logger.collect_and_log(encoded.data.size() / 1000.);
        }
      }

      if (ok && local_on_packet) {
        local_on_packet(std::move(encoded), local_meta);
      }
    }

    /**
     * @brief Try to create a hardware compression session.
     *
     * @param codec CoreMedia codec type to encode.
     * @param config Client stream configuration negotiated for this session.
     * @param low_latency Whether to request low-latency rate control.
     * @return True when the session was created.
     */
    bool create_session(CMVideoCodecType codec, const video::config_t &config, bool low_latency) {
      CFMutableDictionaryRef specification = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      // VideoToolbox's software encoder is far slower than Sunshine's own software encoder, so
      // fail without hardware and let encoder selection fall back to that instead.
      CFDictionarySetValue(specification, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
      if (low_latency) {
        CFDictionarySetValue(specification, kVTVideoEncoderSpecification_EnableLowLatencyRateControl, kCFBooleanTrue);
      }

      NSDictionary *attributes = @{
        (NSString *) kCVPixelBufferPixelFormatTypeKey: @(encoder_pixel_format),
        (NSString *) kCVPixelBufferIOSurfacePropertiesKey: @{}
      };
      const auto status = VTCompressionSessionCreate(kCFAllocatorDefault, config.width, config.height, codec, specification,
        (__bridge CFDictionaryRef) attributes, nullptr, output_callback, this, &session);
      CFRelease(specification);
      if (status != noErr || !session) {
        BOOST_LOG(warning) << "VTCompressionSessionCreate failed (low latency: "sv << low_latency << "): "sv << status;
        session = nullptr;
        return false;
      }
      return true;
    }

    /**
     * @brief Limit the encoded data to a number of bytes per second.
     *
     * @param bytes_per_second Maximum encoded bytes in any one-second window.
     */
    void set_data_rate_limit(std::int64_t bytes_per_second) {
      constexpr std::int64_t one_second = 1;
      CFNumberRef bytes = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &bytes_per_second);
      CFNumberRef seconds = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &one_second);
      const void *values[] = {bytes, seconds};
      CFArrayRef limits = CFArrayCreate(kCFAllocatorDefault, values, 2, &kCFTypeArrayCallBacks);
      set_property(kVTCompressionPropertyKey_DataRateLimits, limits, "DataRateLimits"sv);
      CFRelease(limits);
      CFRelease(seconds);
      CFRelease(bytes);
    }

    bool set_property(CFStringRef key, CFTypeRef value, std::string_view name) {
      const auto status = VTSessionSetProperty(session, key, value);
      if (status != noErr) {
        BOOST_LOG(warning) << "VideoToolbox rejected "sv << name << ": "sv << status;
        return false;
      }
      return true;
    }

    bool set_int_property(CFStringRef key, int value, std::string_view name) {
      CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
      const auto ok = set_property(key, number, name);
      CFRelease(number);
      return ok;
    }

    bool set_double_property(CFStringRef key, double value, std::string_view name) {
      CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
      const auto ok = set_property(key, number, name);
      CFRelease(number);
      return ok;
    }

    void apply_colorspace(const video::sunshine_colorspace_t &colorspace) {
      CFStringRef primaries;
      CFStringRef transfer;
      CFStringRef matrix;
      switch (colorspace.colorspace) {
        case video::colorspace_e::rec601:
          primaries = kCVImageBufferColorPrimaries_SMPTE_C;
          transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
          matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
          break;
        case video::colorspace_e::rec709:
          primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
          transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
          matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
          break;
        case video::colorspace_e::bt2020sdr:
          primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
          transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
          matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
          break;
        case video::colorspace_e::bt2020:
          primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
          transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
          matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
          break;
      }
      set_property(kVTCompressionPropertyKey_ColorPrimaries, primaries, "ColorPrimaries"sv);
      set_property(kVTCompressionPropertyKey_TransferFunction, transfer, "TransferFunction"sv);
      set_property(kVTCompressionPropertyKey_YCbCrMatrix, matrix, "YCbCrMatrix"sv);
      color_primaries = primaries;
      color_transfer = transfer;
      color_matrix = matrix;
    }

    // Sets VideoToolbox container extensions and caches an in-band Annex-B HEVC `PREFIX_SEI_NUT`
    // (ISO/IEC 23008-2 D.2.28 Mastering Display Colour Volume + CTA-861.3 Content Light Level Info)
    // emitted right after VPS/SPS/PPS on every IDR frame.
    void apply_hdr_metadata(const SS_HDR_METADATA &hdr, bool runtime_update) {
      auto put_u16_be = [](std::uint8_t *dst, std::uint16_t v) {
        dst[0] = static_cast<std::uint8_t>((v >> 8) & 0xFF);
        dst[1] = static_cast<std::uint8_t>(v & 0xFF);
      };
      auto put_u32_be = [](std::uint8_t *dst, std::uint32_t v) {
        dst[0] = static_cast<std::uint8_t>((v >> 24) & 0xFF);
        dst[1] = static_cast<std::uint8_t>((v >> 16) & 0xFF);
        dst[2] = static_cast<std::uint8_t>((v >> 8) & 0xFF);
        dst[3] = static_cast<std::uint8_t>(v & 0xFF);
      };

      if (hdr.maxDisplayLuminance != 0) {
        std::uint8_t mdcv[24] {};
        // SS_HDR_METADATA stores primaries in R[0], G[1], B[2]; HEVC D.2.28 SEI uses G, B, R.
        put_u16_be(&mdcv[0], hdr.displayPrimaries[1].x);
        put_u16_be(&mdcv[2], hdr.displayPrimaries[1].y);
        put_u16_be(&mdcv[4], hdr.displayPrimaries[2].x);
        put_u16_be(&mdcv[6], hdr.displayPrimaries[2].y);
        put_u16_be(&mdcv[8], hdr.displayPrimaries[0].x);
        put_u16_be(&mdcv[10], hdr.displayPrimaries[0].y);
        put_u16_be(&mdcv[12], hdr.whitePoint.x);
        put_u16_be(&mdcv[14], hdr.whitePoint.y);
        put_u32_be(&mdcv[16], static_cast<std::uint32_t>(hdr.maxDisplayLuminance) * 10000u);
        put_u32_be(&mdcv[20], static_cast<std::uint32_t>(hdr.minDisplayLuminance));
        if (CFDataRef mdcv_data = CFDataCreate(kCFAllocatorDefault, mdcv, sizeof(mdcv))) {
          set_property(kVTCompressionPropertyKey_MasteringDisplayColorVolume, mdcv_data, "MasteringDisplayColorVolume"sv);
          CFRelease(mdcv_data);
        }
      }

      if (hdr.maxContentLightLevel != 0 || hdr.maxFrameAverageLightLevel != 0) {
        std::uint8_t clli[4] {};
        put_u16_be(&clli[0], hdr.maxContentLightLevel);
        put_u16_be(&clli[2], hdr.maxFrameAverageLightLevel);
        if (CFDataRef clli_data = CFDataCreate(kCFAllocatorDefault, clli, sizeof(clli))) {
          set_property(kVTCompressionPropertyKey_ContentLightLevelInfo, clli_data, "ContentLightLevelInfo"sv);
          CFRelease(clli_data);
        }
      }
      set_property(CFSTR("PreserveDynamicHDRMetadata"), kCFBooleanTrue, "PreserveDynamicHDRMetadata"sv);

      if (codec_type == kCMVideoCodecType_HEVC && is_hdr_colorspace) {
        auto sei = platf::vt::build_hdr_sei_hevc(hdr);
        bool changed = false;
        {
          std::lock_guard lg {mutex};
          changed = (sei != cached_hdr_sei);
          cached_hdr_sei = std::move(sei);
          if (runtime_update && changed && !cached_hdr_sei.empty()) {
            need_idr = true;
          }
        }
        if (changed && !cached_hdr_sei.empty()) {
          BOOST_LOG(info) << "VideoToolbox: enabled in-band HDR10 PREFIX_SEI_NUT (peak "sv
                          << hdr.maxDisplayLuminance << " nits, MaxCLL "sv << hdr.maxContentLightLevel
                          << ", MaxFALL "sv << hdr.maxFrameAverageLightLevel
                          << ", "sv << cached_hdr_sei.size() << "B on IDR)"sv;
        }
      }
    }

    static std::vector<uint8_t> build_patched_parameter_sets(CMFormatDescriptionRef format) {
      if (!format) {
        return {};
      }
      constexpr uint8_t start_code[] = {0, 0, 0, 1};
      const bool hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC;
      size_t count = 0;
      const uint8_t *ps0 = nullptr;
      size_t ps0_size = 0;
      const auto status = hevc ?
                            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &ps0, &ps0_size, &count, nullptr) :
                            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &ps0, &ps0_size, &count, nullptr);
      if (status != noErr || count == 0) {
        return {};
      }
      std::vector<uint8_t> raw;
      raw.reserve(128);
      for (size_t i = 0; i < count; ++i) {
        const uint8_t *ps = nullptr;
        size_t ps_size = 0;
        const auto st = hevc ?
                          CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &ps, &ps_size, nullptr, nullptr) :
                          CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &ps, &ps_size, nullptr, nullptr);
        if (st != noErr || !ps_size) {
          return {};
        }
        raw.insert(raw.end(), std::begin(start_code), std::end(start_code));
        raw.insert(raw.end(), ps, ps + ps_size);
      }
      auto patched = cbs::patch_parameter_sets_low_latency(
        std::string_view {reinterpret_cast<const char *>(raw.data()), raw.size()},
        hevc
      );
      return patched.empty() ? raw : patched;
    }

    VTCompressionSessionRef session = nullptr;
    CMVideoCodecType codec_type = 0;
    bool requested_full_range = false;
    OSType encoder_pixel_format = 0;
    CFStringRef color_primaries = nullptr;
    CFStringRef color_transfer = nullptr;
    CFStringRef color_matrix = nullptr;
    platf::cf_ref_t<VTPixelTransferSessionRef> range_transfer;
    uint64_t last_transfer_generation = 0;
    platf::cf_ref_t<CVPixelBufferRef> last_transfer_result;
    bool logged_input_format = false;
    int width = 0;
    int height = 0;
    int framerate = 60;
    bool is_low_latency = false;
    bool is_hdr_colorspace = false;

    std::mutex mutex;
    std::condition_variable cv;
    std::size_t in_flight = 0;
    std::size_t max_in_flight_limit = 3;
    std::atomic<std::size_t> in_flight_atomic {0};
    uint64_t next_slot_seq = 0;
    std::array<in_flight_slot_t, slot_ring_size> slots;
    bool sticky_error = false;
    bool need_idr = false;
    logging::min_max_avg_periodic_logger<double> frame_size_logger = {debug, "VideoToolbox: encoded frame sizes in kB", ""};  ///< Periodic encoded frame size statistics.
    // Retained format description to detect mid-stream parameter set changes without ABA pointer reuse.
    platf::cf_ref_t<CMFormatDescriptionRef> last_format {};
    std::vector<uint8_t> cached_parameter_sets;
    std::vector<uint8_t> cached_hdr_sei;
  };

  /**
   * @brief Native VideoToolbox encode device bound to a macOS capture pipeline.
   */
  class vt_encode_device final: public platf::vt_encode_device_t {
  public:
    /**
     * @brief Bind the device to the capture display and select the capture pixel format.
     *
     * @param pix_fmt Sunshine pixel format to capture and encode.
     * @param resolution_fn Callback that resizes the capture output.
     * @param pixel_format_fn Callback that selects the capture pixel format.
     * @return 0 on success.
     */
    int init(platf::pix_fmt_e pix_fmt, bool full_range, platf::vt::resolution_fn_t resolution_fn, const platf::vt::pixel_format_fn_t &pixel_format_fn) {
      this->resolution_fn = std::move(resolution_fn);
      // Must happen before capture starts; the capture backend snapshots it when the stream is created.
      // SCStream natively supports 'xf44' (2-plane 10-bit 4:4:4) for both 8-bit and 10-bit HEVC 4:4:4.
      const bool yuv444 = pix_fmt == platf::pix_fmt_e::ayuv || pix_fmt == platf::pix_fmt_e::yuv444p16;
      pixel_format_fn(platf::vt::capture_pixel_format(yuv444, pix_fmt == platf::pix_fmt_e::p010, full_range));
      return 0;
    }

    bool init_encoder(const video::config_t &client_config, const video::sunshine_colorspace_t &colorspace) override {
      if (client_config.videoFormat == 2) {
        BOOST_LOG(info) << "VideoToolbox encoder doesn't support AV1"sv;
        return false;
      }
      if (client_config.videoFormat == 0 && colorspace.bit_depth == 10) {
        BOOST_LOG(error) << "VideoToolbox encoder doesn't support 10-bit H.264"sv;
        return false;
      }
      if (client_config.videoFormat == 0 && client_config.chromaSamplingType == 1) {
        BOOST_LOG(info) << "VideoToolbox encoder doesn't support H.264 YUV 4:4:4"sv;
        return false;
      }

      resolution_fn(client_config.width, client_config.height);

      session = std::make_unique<vt_compression_session_t>();
      const CMVideoCodecType codec = client_config.videoFormat == 1 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
      if (!session->init(codec, client_config, colorspace, hdr_metadata_valid ? &hdr_metadata : nullptr)) {
        session.reset();
        return false;
      }
      return true;
    }

    int convert(platf::img_t &img) override {
      auto av_img = (platf::av_img_t *) &img;
      if (!av_img->pixel_buffer || !av_img->pixel_buffer->buf) {
        return -1;
      }

      // Keep the frame's backing sample buffer retained while VideoToolbox reads it;
      // the img_t pool recycles the image (and releases its buffers) at any time.
      // Release order matters: the old pixel buffer must unlock (av_pixel_buf_t dtor)
      // before the old sample buffer that owns it is released.
      pixel_buffer = av_img->pixel_buffer;
      sample_buffer = av_img->sample_buffer;
      ++source_generation;
      return 0;
    }

    platf::vt_encoded_frame encode_frame(uint64_t frame_index, bool force_idr) override {
      if (!session || !pixel_buffer) {
        return {};
      }
      return session->encode(pixel_buffer->buf, frame_index, force_idr);
    }

    int submit_frame(const platf::vt_frame_metadata_t &meta, bool force_idr, packet_callback_t on_packet) override {
      if (!session || !pixel_buffer || !pixel_buffer->buf) {
        return -1;
      }
      return session->submit(pixel_buffer->buf, sample_buffer, pixel_buffer, meta, force_idr, std::move(on_packet), false, source_generation);
    }

    bool flush_encoder() override {
      return !session || session->flush();
    }

    bool wait_for_slot() override {
      return !session || session->wait_for_slot();
    }

    std::size_t in_flight_count() const override {
      return session ? session->in_flight_count() : 0;
    }

    bool set_bitrate(int bitrate_kbps) override {
      return session && session->set_bitrate(bitrate_kbps);
    }

    void set_hdr_metadata(const SS_HDR_METADATA &metadata) override {
      if (session) {
        session->set_hdr_metadata(metadata);
      }
    }

  private:
    platf::vt::resolution_fn_t resolution_fn;
    std::unique_ptr<vt_compression_session_t> session;
    std::shared_ptr<platf::av_sample_buf_t> sample_buffer;
    std::shared_ptr<platf::av_pixel_buf_t> pixel_buffer;
    uint64_t source_generation = 0;
  };
}  // namespace

namespace platf::vt {
  std::vector<uint8_t> build_hdr_sei_hevc(const SS_HDR_METADATA &hdr) {
    const bool has_mdcv = hdr.maxDisplayLuminance != 0;
    const bool has_clli = hdr.maxContentLightLevel != 0 || hdr.maxFrameAverageLightLevel != 0;
    if (!has_mdcv && !has_clli) {
      return {};
    }

    std::vector<uint8_t> rbsp;
    rbsp.reserve(36);
    auto push_u16_be = [&rbsp](std::uint16_t v) {
      rbsp.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
      rbsp.push_back(static_cast<uint8_t>(v & 0xFF));
    };
    auto push_u32_be = [&rbsp](std::uint32_t v) {
      rbsp.push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
      rbsp.push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
      rbsp.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
      rbsp.push_back(static_cast<uint8_t>(v & 0xFF));
    };

    if (has_mdcv) {
      // ISO/IEC 23008-2 D.2.28 mastering_display_colour_volume (payloadType = 137, payloadSize = 24):
      // primaries are encoded in G (c=0), B (c=1), R (c=2) order; SS_HDR_METADATA stores R[0], G[1], B[2].
      rbsp.push_back(137);
      rbsp.push_back(24);
      push_u16_be(hdr.displayPrimaries[1].x);
      push_u16_be(hdr.displayPrimaries[1].y);
      push_u16_be(hdr.displayPrimaries[2].x);
      push_u16_be(hdr.displayPrimaries[2].y);
      push_u16_be(hdr.displayPrimaries[0].x);
      push_u16_be(hdr.displayPrimaries[0].y);
      push_u16_be(hdr.whitePoint.x);
      push_u16_be(hdr.whitePoint.y);
      push_u32_be(static_cast<std::uint32_t>(hdr.maxDisplayLuminance) * 10000u);
      push_u32_be(static_cast<std::uint32_t>(hdr.minDisplayLuminance));
    }

    if (has_clli) {
      // CTA-861.3 / ISO/IEC 23008-2 D.2.35 content_light_level_info (payloadType = 144, payloadSize = 4).
      rbsp.push_back(144);
      rbsp.push_back(4);
      push_u16_be(hdr.maxContentLightLevel);
      push_u16_be(hdr.maxFrameAverageLightLevel);
    }

    // rbsp_trailing_bits(): byte-aligned SEI payloads terminate with 1 stop bit + 7 zero alignment bits.
    rbsp.push_back(0x80);

    // Annex-B start code + HEVC NAL unit header for PREFIX_SEI_NUT (nal_unit_type = 39, layer = 0, tid_plus1 = 1 -> 0x4E01)
    std::vector<uint8_t> out = {0x00, 0x00, 0x00, 0x01, 0x4E, 0x01};
    out.reserve(6 + rbsp.size() + 4);

    // Convert RBSP to EBSP (ITU-T H.265 §7.4.2.2 emulation_prevention_three_byte = 0x03).
    int zero_count = 0;
    for (const uint8_t b : rbsp) {
      if (zero_count == 2 && b <= 0x03) {
        out.push_back(0x03);
        zero_count = 0;
      }
      out.push_back(b);
      zero_count = (b == 0) ? (zero_count + 1) : 0;
    }
    return out;
  }

  bool append_annexb(
    CMSampleBufferRef sample_buffer,
    bool idr,
    std::vector<uint8_t> &out,
    std::span<const uint8_t> prefix_sei
  ) {
    constexpr uint8_t start_code[] = {0, 0, 0, 1};
    const auto start_size = out.size();
    auto restore_out = util::fail_guard([&]() {
      out.resize(start_size);
    });

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample_buffer);
    if (!format) {
      BOOST_LOG(error) << "VideoToolbox sample buffer has no format description"sv;
      return false;
    }
    const bool hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC;

    size_t parameter_set_count = 0;
    int nal_length_size = 4;
    {
      const uint8_t *ps = nullptr;
      size_t ps_size = 0;
      const auto status = hevc ?
                            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &ps, &ps_size, &parameter_set_count, &nal_length_size) :
                            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &ps, &ps_size, &parameter_set_count, &nal_length_size);
      if (status != noErr) {
        BOOST_LOG(error) << "VideoToolbox parameter set query failed: "sv << status;
        return false;
      }
    }

    struct ps_span_t {
      const uint8_t *ptr;
      size_t size;
    };
    std::array<ps_span_t, 8> ps_spans {};
    size_t ps_count = 0;
    size_t ps_total_bytes = 0;

    if (idr) {
      for (size_t i = 0; i < parameter_set_count; ++i) {
        const uint8_t *ps = nullptr;
        size_t ps_size = 0;
        const auto status = hevc ?
                              CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &ps, &ps_size, nullptr, nullptr) :
                              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &ps, &ps_size, nullptr, nullptr);
        if (status != noErr || !ps_size) {
          BOOST_LOG(error) << "VideoToolbox parameter set "sv << i << " query failed: "sv << status;
          return false;
        }
        if (i == 0) {
          const int nal_type = hevc ? ((ps[0] >> 1) & 0x3f) : (ps[0] & 0x1f);
          const int expected = hevc ? 32 : 7;  // Moonlight requires VPS-first (HEVC) / SPS-first (H.264) IDR frames
          if (nal_type != expected) {
            BOOST_LOG(error) << "VideoToolbox emitted unexpected leading parameter set NAL type "sv << nal_type;
          }
        }
        if (ps_count < ps_spans.size()) {
          ps_spans[ps_count++] = {ps, ps_size};
          ps_total_bytes += sizeof(start_code) + ps_size;
        } else {
          out.insert(out.end(), std::begin(start_code), std::end(start_code));
          out.insert(out.end(), ps, ps + ps_size);
        }
      }
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_buffer);
    if (!block) {
      BOOST_LOG(error) << "VideoToolbox sample buffer has no data buffer"sv;
      return false;
    }

    char *data = nullptr;
    size_t contiguous_length = 0;
    size_t total_length = 0;
    CMBlockBufferRef contiguous = nullptr;
    auto status = CMBlockBufferGetDataPointer(block, 0, &contiguous_length, &total_length, &data);
    if (status != kCMBlockBufferNoErr || contiguous_length < total_length) {
      if (CMBlockBufferCreateContiguous(kCFAllocatorDefault, block, nullptr, nullptr, 0, 0, 0, &contiguous) != kCMBlockBufferNoErr) {
        BOOST_LOG(error) << "VideoToolbox block buffer could not be made contiguous"sv;
        return false;
      }
      status = CMBlockBufferGetDataPointer(contiguous, 0, &contiguous_length, &total_length, &data);
      if (status != kCMBlockBufferNoErr || contiguous_length < total_length) {
        CFRelease(contiguous);
        BOOST_LOG(error) << "VideoToolbox contiguous block buffer access failed: "sv << status;
        return false;
      }
    }

    // Validate NAL headers in one tiny stride walk (typically 4 slices + 1 SEI = 5 hops) so we can
    // allocate the exact output size once (staying inside macOS nano/small malloc magazines instead
    // of 256KB+ VM allocations) and emit Annex-B via direct pointer memcpy with zero reallocations.
    bool ok = (nal_length_size >= 1 && nal_length_size <= 8);
    size_t offset = 0;
    size_t annexb_body_bytes = 0;
    while (ok && offset + (size_t) nal_length_size <= total_length) {
      uint64_t nal_length = 0;
      for (int i = 0; i < nal_length_size; ++i) {
        nal_length = (nal_length << 8) | (uint8_t) data[offset + i];
      }
      offset += nal_length_size;
      if (!nal_length || nal_length > total_length - offset) {
        ok = false;
        break;
      }
      annexb_body_bytes += sizeof(start_code) + (size_t) nal_length;
      offset += (size_t) nal_length;
    }
    if (offset != total_length) {
      ok = false;
    }

    if (ok) {
      const size_t sei_bytes = (hevc && !prefix_sei.empty()) ? prefix_sei.size() : 0;
      const size_t write_offset = out.size();
      out.resize(write_offset + ps_total_bytes + sei_bytes + annexb_body_bytes);
      uint8_t *dst = out.data() + write_offset;

      for (size_t i = 0; i < ps_count; ++i) {
        std::memcpy(dst, start_code, sizeof(start_code));
        dst += sizeof(start_code);
        std::memcpy(dst, ps_spans[i].ptr, ps_spans[i].size);
        dst += ps_spans[i].size;
      }
      if (sei_bytes > 0) {
        std::memcpy(dst, prefix_sei.data(), sei_bytes);
        dst += sei_bytes;
      }

      size_t src_off = 0;
      while (src_off + (size_t) nal_length_size <= total_length) {
        uint64_t nal_length = 0;
        for (int i = 0; i < nal_length_size; ++i) {
          nal_length = (nal_length << 8) | (uint8_t) data[src_off + i];
        }
        src_off += nal_length_size;
        std::memcpy(dst, start_code, sizeof(start_code));
        dst += sizeof(start_code);
        std::memcpy(dst, data + src_off, (size_t) nal_length);
        dst += (size_t) nal_length;
        src_off += (size_t) nal_length;
      }
    } else {
      BOOST_LOG(error) << "VideoToolbox produced a malformed AVCC bitstream"sv;
    }
    if (contiguous) {
      CFRelease(contiguous);
    }
    if (ok) {
      restore_out.disable();
    }
    return ok;
  }

  OSType capture_pixel_format(bool yuv444, bool ten_bit, bool full_range) {
    // ScreenCaptureKit supports a single range for each 10-bit chroma format.
    if (yuv444) return kCVPixelFormatType_444YpCbCr10BiPlanarFullRange;
    if (ten_bit) return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    return full_range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  }

  bool try_low_latency(CMVideoCodecType codec, bool arm64) {
    if (arm64) {
      return false;
    }
    return codec == kCMVideoCodecType_H264;
  }

  CFStringRef h264_entropy_mode(int coder) {
    switch (coder) {
      case 1:
        return kVTH264EntropyMode_CABAC;
      case 2:
        return kVTH264EntropyMode_CAVLC;
      default:
        return nullptr;
    }
  }

  int expected_frame_rate(CMVideoCodecType codec, int width, int height, int framerate) {
    if (codec != kCMVideoCodecType_H264 || width <= 0 || height <= 0) {
      return framerate;
    }

    // H.264 level 5.2 MaxMBPS (macroblocks per second), Table A-1
    constexpr std::int64_t max_macroblocks_per_second = 2073600;
    const std::int64_t macroblocks_per_frame = static_cast<std::int64_t>((width + 15) / 16) * ((height + 15) / 16);
    const auto level_limit = static_cast<int>(std::max<std::int64_t>(1, max_macroblocks_per_second / macroblocks_per_frame));
    return std::min(framerate, level_limit);
  }

  std::unique_ptr<vt_encode_device_t> make_encode_device(pix_fmt_e pix_fmt, bool full_range, resolution_fn_t resolution_fn, const pixel_format_fn_t &pixel_format_fn) {
    if (pix_fmt != pix_fmt_e::nv12 &&
        pix_fmt != pix_fmt_e::p010 &&
        pix_fmt != pix_fmt_e::ayuv &&
        pix_fmt != pix_fmt_e::yuv444p16) {
      BOOST_LOG(error) << "Unsupported pixel format for the VideoToolbox encoder"sv;
      return nullptr;
    }

    auto device = std::make_unique<::vt_encode_device>();
    if (device->init(pix_fmt, full_range, std::move(resolution_fn), pixel_format_fn)) {
      return nullptr;
    }
    return device;
  }
}  // namespace platf::vt
