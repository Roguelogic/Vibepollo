/**
 * @file src/video_pacing_policy.h
 * @brief Shared packet pacing math for video transports.
 */
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>

namespace stream::pacing {
  /// Data plus parity packets for one FEC block, matching the video send path.
  inline std::size_t fec_expanded_packets(std::size_t data_packets, int fec_percentage, std::size_t min_parity_packets) {
    auto parity_packets = (data_packets * std::size_t(std::max(fec_percentage, 0)) + 99) / 100;
    if (fec_percentage > 0 && parity_packets < min_parity_packets) {
      parity_packets = min_parity_packets;
    }
    return data_packets + parity_packets;
  }

  /// Proactive Adaptive FEC percentage for ordinary (non-PyroWave) UDP frames.
  /// Preserves full configured parity on IDR frames, during warmup (<2s), for 8s
  /// after any reported FEC recovery/loss hazard, and proactively on multi-batch
  /// burst frames (>40 data shards) so sudden scene changes never hit Wi-Fi
  /// queues with 5% parity. Static/small frames step down to save airtime.
  inline int adaptive_fec_percentage(
    int configured_fec,
    bool is_idr,
    std::size_t data_shards,
    std::int64_t elapsed_since_start_ns,
    std::optional<std::int64_t> clean_since_hazard_ns
  ) {
    if (configured_fec <= 5 || is_idr) {
      return configured_fec;
    }
    if (elapsed_since_start_ns < 2'000'000'000LL) {
      return configured_fec;
    }
    // Multi-batch motion/scene-change frames (>40 data shards, ~56 KiB) keep full
    // configured FEC proactively: on encoders without LTR/RFI (e.g. VideoToolbox
    // HEVC 4:4:4), a single unrecoverable motion frame forces a full IDR keyframe.
    if (data_shards > 40) {
      return configured_fec;
    }
    const auto clean_ns = clean_since_hazard_ns.value_or(elapsed_since_start_ns);
    if (clean_ns < 8'000'000'000LL) {
      return configured_fec;
    }
    // Moderate frames (21..40 data shards) never step below 10% parity so 3-4
    // packet Wi-Fi blips remain recoverable; small/static frames (<=20 shards,
    // which still enforce >=2 parity shards = >=10% effective parity) step to 5%.
    if (clean_ns >= 15'000'000'000LL && data_shards <= 20) {
      return std::min(configured_fec, 5);
    }
    return std::min(configured_fec, 10);
  }

  /// Sub-frame burst pacing quantum (packets/ms) for oversized or IDR frames when
  /// explicit pacing options are off. Returns nullopt for ordinary small/medium
  /// frames so steady-state latency stays at zero sleep.
  inline std::optional<std::size_t> burst_guard_packets_per_ms(
    bool is_idr,
    std::size_t frame_wire_packets,
    int bitrate_kbps,
    std::size_t payload_bytes,
    std::size_t wire_bytes
  ) {
    constexpr std::size_t idr_threshold_packets = 48;
    constexpr std::size_t large_frame_threshold_packets = 80;
    const bool needs_guard = (is_idr && frame_wire_packets >= idr_threshold_packets) ||
                             frame_wire_packets >= large_frame_threshold_packets;
    if (!needs_guard || payload_bytes == 0 || wire_bytes == 0) {
      return std::nullopt;
    }
    // At least ~230 Mbps wire pace (20 packets/ms at ~1450 wire bytes) so a 200-packet
    // IDR finishes in ~10 ms while sending ~28 KiB sub-batches instead of 800 Mbps 64 KiB
    // blasts; scale up to >=1.5x nominal wire demand (including ~20% FEC + headers) for
    // ultra-high-bitrate streams.
    constexpr std::size_t min_burst_packets_per_ms = 20;
    const auto demand_1_5x_kbps = std::uint64_t(std::max(bitrate_kbps, 0)) * 18 / 10;
    const auto demand_packets_per_ms = (demand_1_5x_kbps + 8 * payload_bytes - 1) / (8 * payload_bytes);
    return std::max<std::size_t>(min_burst_packets_per_ms, std::size_t(demand_packets_per_ms));
  }

  /// Packets in one millisecond of pacing time, based on stream and frame demand.
  /// `frame_packets` includes any transport parity packets for the frame.
  inline std::size_t packets_per_ms(
    std::uint64_t link_bps,
    int bitrate_kbps,
    std::size_t payload_bytes,
    std::size_t wire_bytes,
    std::size_t frame_packets,
    int framerate,
    std::uint64_t calibrated_pace_bps
  ) {
    if (payload_bytes == 0 || wire_bytes == 0) {
      return 1;
    }
    const auto frame_allowance = (frame_packets * std::uint64_t(std::max(framerate, 0)) + 999) / 1000;
    const auto bitrate_allowance = (std::uint64_t(std::max(bitrate_kbps, 0)) + 8 * payload_bytes - 1) / (8 * payload_bytes);
    const auto demand = std::max(frame_allowance, bitrate_allowance);
    const auto calibrated_packets = calibrated_pace_bps / 8 / 1000 / wire_bytes;
    if (link_bps == 0) {
      return std::max<std::size_t>(1, std::max(calibrated_packets, demand));
    }
    const auto link_packets = link_bps / 8 / 1000 / wire_bytes;
    const auto target_packets = calibrated_pace_bps ? calibrated_packets : link_bps * 80 / 100 / 8 / 1000 / wire_bytes;
    return std::max<std::size_t>(1, std::min(link_packets, std::max(target_packets, demand)));
  }

  /// Bound a send batch by both its configured maximum and one pacing quantum.
  inline std::size_t max_batch_bytes(std::size_t configured_max, std::size_t packets_per_quantum, std::size_t datagram_bytes) {
    const auto quantum_bytes = datagram_bytes && packets_per_quantum > std::numeric_limits<std::size_t>::max() / datagram_bytes ?
                                 std::numeric_limits<std::size_t>::max() :
                                 packets_per_quantum * datagram_bytes;
    return std::min(configured_max, quantum_bytes);
  }
}  // namespace stream::pacing
