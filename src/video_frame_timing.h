#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <optional>

namespace video {
  struct frame_timing_sample_t {
    // Counts cover one history sampling interval. -1 means unavailable (e.g. old history).
    std::int64_t captured_frames = -1;
    std::int64_t repeated_frames = -1;
    double capture_to_submit_p95_ms = -1;
    double encode_p95_ms = -1;
    double complete_to_send_p95_ms = -1;
    double send_interval_jitter_ms = -1;
  };

  class frame_timing_t {
    using clock = std::chrono::steady_clock;
    using time_point = clock::time_point;

  public:
    void record(std::optional<time_point> capture, time_point submit, time_point complete, time_point sent) {
      std::lock_guard lock {mutex};
      if (previous_send) {
        const double interval = milliseconds(sent - *previous_send);
        const double delta = interval - mean;
        mean += delta / ++intervals;
        m2 += delta * (interval - mean);
      }
      previous_send = sent;
      if (!capture) {
        ++repeats;
        return;
      }
      ++captures;
      if (submit == time_point {} || submit < *capture || complete < submit || sent < complete) return;
      durations[measured++ % durations.size()] = {
        milliseconds(submit - *capture), milliseconds(complete - submit), milliseconds(sent - complete)
      };
    }

    frame_timing_sample_t snapshot(bool finish_interval) {
      if (!finish_interval) {
        std::lock_guard lock {mutex};
        return latest;
      }

      // Only the history sampler closes intervals. Copy the populated prefix under
      // the sender lock, then compute order statistics without blocking frame sends.
      decltype(durations) samples;
      std::size_t count;
      frame_timing_sample_t result;
      {
        std::lock_guard lock {mutex};
        result.captured_frames = captures;
        result.repeated_frames = repeats;
        if (intervals > 1) result.send_interval_jitter_ms = std::sqrt(std::max(0.0, m2) / (intervals - 1));
        count = std::min(measured, durations.size());
        std::copy_n(durations.begin(), count, samples.begin());
        captures = repeats = intervals = 0;
        measured = 0;
        mean = m2 = 0;
      }
      // Bound memory even if sampling stops. Keep the newest 2048 measured frames.
      if (count) {
        std::array<double, capacity> sorted;
        auto percentile = [&](std::size_t stage) {
          for (std::size_t i = 0; i < count; ++i) sorted[i] = samples[i][stage];
          auto rank = sorted.begin() + (count * 95 - 1) / 100;
          std::nth_element(sorted.begin(), rank, sorted.begin() + count);
          return *rank;
        };
        result.capture_to_submit_p95_ms = percentile(0);
        result.encode_p95_ms = percentile(1);
        result.complete_to_send_p95_ms = percentile(2);
      }
      std::lock_guard lock {mutex};
      latest = result;
      return result;
    }

  private:
    static double milliseconds(clock::duration duration) {
      return std::chrono::duration<double, std::milli>(duration).count();
    }

    std::mutex mutex;
    std::optional<time_point> previous_send;
    std::int64_t captures = 0, repeats = 0, intervals = 0;
    double mean = 0, m2 = 0;
    static constexpr std::size_t capacity = 2048;
    std::array<std::array<double, 3>, capacity> durations;
    std::size_t measured = 0;
    frame_timing_sample_t latest;
  };
}
