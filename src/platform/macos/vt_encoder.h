/**
 * @file src/platform/macos/vt_encoder.h
 * @brief Declarations for the native VideoToolbox encoder on macOS.
 */
#pragma once

// standard includes
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <vector>

// platform includes
#include <CoreMedia/CoreMedia.h>

// local includes
#include "src/platform/common.h"

namespace platf::vt {
  /**
   * @brief Callback that resizes the capture output to the encoder resolution.
   */
  using resolution_fn_t = std::function<void(int width, int height)>;

  /**
   * @brief Callback that selects the capture pixel format.
   */
  using pixel_format_fn_t = std::function<void(int pixel_format)>;

  /**
   * @brief Decide whether to request low-latency rate control before standard rate control.
   *
   * On Apple Silicon (AVE), `EnableLowLatencyRateControl` throttles HEVC encode throughput at
   * high Retina resolutions (e.g. ~17-23.5ms/frame at 2752x2064 on M4), whereas standard rate
   * control with `RealTime=true`, `AllowFrameReordering=false`, and a 1s `DataRateLimits` window
   * sustains 120fps (~7.0ms/frame) with zero dropped frames. Low-latency rate control is
   * therefore requested only for H.264.
   *
   * @param codec CoreMedia codec type of the session.
   * @param arm64 Whether the host is Apple silicon.
   * @return True when low-latency rate control should be tried first.
   */
  bool try_low_latency(CMVideoCodecType codec, bool arm64);

  /**
   * @brief Map the `vt_coder` setting to an H.264 entropy mode.
   *
   * @param coder Value of `config::video.vt.vt_coder` (1 = CABAC, 2 = CAVLC, anything else = auto).
   * @return Entropy mode to set, or null to leave the encoder default.
   */
  CFStringRef h264_entropy_mode(int coder);

  /**
   * @brief Build an Annex-B HEVC `PREFIX_SEI_NUT` (NAL type 39) containing ISO/IEC 23008-2 D.2.28
   *        `mastering_display_colour_volume` (payload 137) and CTA-861.3 / D.2.35
   *        `content_light_level_info` (payload 144) with RBSP `0x03` emulation prevention.
   *
   * Apple's hardware HEVC encoder (`AppleAVE2`) records MDCV/CLLI on `CMFormatDescription`
   * container extensions but omits payloads 137 and 144 from the `CMBlockBuffer` bitstream.
   * Injecting this NAL unit right after VPS/SPS/PPS on IDR frames ensures raw Annex-B RTP
   * clients and decoders receive authoritative in-band HDR10 mastering metadata from frame 0.
   *
   * @param hdr Authoritative stream HDR10 metadata.
   * @return Complete Annex-B `PREFIX_SEI_NUT` bytes (including `00 00 00 01`), or empty when unset.
   */
  std::vector<uint8_t> build_hdr_sei_hevc(const SS_HDR_METADATA &hdr);

  /**
   * @brief Convert one encoded sample buffer from AVCC framing to an Annex-B elementary stream.
   *
   * On IDR frames the parameter sets held out-of-band in the format description are emitted
   * first (H.264: SPS, PPS; HEVC: VPS, SPS, PPS), because Moonlight identifies IDR frames by
   * the leading parameter-set NAL and decodes each packet as a self-contained frame.
   *
   * @param sample_buffer Encoded sample buffer delivered by the compression session.
   * @param idr Whether the sample buffer holds a sync (IDR) frame whose parameter sets must be emitted.
   * @param out Vector that receives the Annex-B bytes; left unchanged when conversion fails.
   * @param prefix_sei Optional Annex-B `PREFIX_SEI_NUT` bytes emitted after parameter sets and before VCL slices.
   * @return True when the complete frame was converted.
   */
  bool append_annexb(
    CMSampleBufferRef sample_buffer,
    bool idr,
    std::vector<uint8_t> &out,
    std::span<const uint8_t> prefix_sei = {}
  );

  /**
   * @brief Compute the frame rate to declare to a VideoToolbox compression session.
   *
   * Low-latency H.264 sessions drop every frame when the declared rate exceeds what H.264
   * level 5.2 (the highest level the hardware encoder offers) allows at the session's
   * resolution, so H.264 rates are capped at that limit. Frames are still submitted at the
   * negotiated rate; only the rate-control hint changes. Other codecs are not capped.
   *
   * @param codec CoreMedia codec type of the session.
   * @param width Encoded width in pixels.
   * @param height Encoded height in pixels.
   * @param framerate Negotiated stream frame rate.
   * @return Frame rate to set as `kVTCompressionPropertyKey_ExpectedFrameRate`.
   */
  int expected_frame_rate(CMVideoCodecType codec, int width, int height, int framerate);

  /**
   * @brief Create a native VideoToolbox encode device bound to the capture display.
   *
   * @param pix_fmt Sunshine pixel format to capture and encode.
   * @param resolution_fn Callback that resizes the capture output.
   * @param pixel_format_fn Callback that selects the capture pixel format; invoked before capture starts.
   * @return Constructed encode device object, or null on failure.
   */
  std::unique_ptr<vt_encode_device_t> make_encode_device(pix_fmt_e pix_fmt, resolution_fn_t resolution_fn, const pixel_format_fn_t &pixel_format_fn);
}  // namespace platf::vt
