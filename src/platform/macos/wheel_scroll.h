// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cmath>
#include <cstdint>

namespace platf::wheel_scroll_policy {
  constexpr double drag_gain = 0.68;

  inline int drag_step(double target, std::int64_t emitted, double share) {
    // Round the cumulative position so a half-pixel remainder settles on one pixel.
    const auto pending = std::llround(target) - emitted;
    const int step = static_cast<int>(std::lround(static_cast<double>(pending) * share));
    // The worker advances its deadline when it emits a pixel.
    if (pending != 0 && step == 0) {
      return pending > 0 ? 1 : -1;
    }
    return step;
  }
}  // namespace platf::wheel_scroll_policy
