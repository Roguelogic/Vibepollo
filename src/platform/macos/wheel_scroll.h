// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <algorithm>
#include <chrono>
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

  /**
   * @brief Reconstructs horizontal trackpad travel and velocity corrupted by VoidLink / Moonlight-iOS.
   *
   * Unpatched VoidLink `StreamView.m` (`mouseWheelMovedContinuous:`) checks `translationDeltaY != 0`
   * first and executes `lastScrollTranslation = currentScrollTranslation` BEFORE computing
   * `translationDeltaX`. Consequently:
   *  1) Any 60/120Hz frame with >= 1 wheel unit of vertical finger drift (~0.32-0.43 pt, i.e. a 4-12 deg
   *     natural wrist angle) sends ONLY `scroll(dy)` and destroys 100% of that frame's horizontal delta.
   *  2) When a subsequent `hscroll(dx)` frame arrives after `k` `scroll(dy)` frames, `dx` only contains
   *     the single frame's travel since the last `scroll(dy)` reset `lastScrollTranslation`, NOT travel
   *     since the previous `hscroll(dx)`. Dividing `dx` by `now - last_x_time` collapses horizontal
   *     velocity by `1 / (k + 1)` and starves inertia in paged shelves (e.g. Apple Music).
   */
  class horizontal_reconstructor_t {
  public:
    using clock = std::chrono::steady_clock;

    struct sample_result_t {
      double eff_dx {};
      double eff_dy {};
      double vx {};
      bool has_vx_update {};
      bool horizontal_locked {};
      bool hold_initial_dy {};
      bool cancel_unemitted_dy {};
    };

    sample_result_t observe(clock::time_point now, double dx, double dy) {
      if (dx == 0.0 && dy == 0.0) {
        return {};
      }
      if (first_event_.time_since_epoch().count() == 0) {
        first_event_ = now;
      }
      const double dt_any = last_event_.time_since_epoch().count() ?
                              std::chrono::duration<double>(now - last_event_).count() :
                              0.0;
      if (dt_any >= 0.004 && dt_any <= 0.022) {
        const double alpha = (dt_any > 1.5 * nominal_dt_) ? 0.12 : 0.30;
        nominal_dt_ = (1.0 - alpha) * nominal_dt_ + alpha * dt_any;
      }

      if (dy != 0.0 && dx == 0.0) {
        return observe_vertical(now, dy, dt_any);
      }
      return observe_horizontal(now, dx);
    }

  private:
    sample_result_t observe_vertical(clock::time_point now, double dy, double dt_any) {
      if (real_x_count_ == 0) {
        last_isolated_y_time_ = now;
        last_event_ = now;
        if (std::abs(dy) <= 3.2 && leading_y_frames_ < 5 && (leading_abs_y_ + std::abs(dy)) <= 7.5) {
          ++leading_y_frames_;
          leading_abs_y_ += std::abs(dy);
          max_leading_dy_ = std::max(max_leading_dy_, std::abs(dy));
          raw_abs_y_ += std::abs(dy);
          const bool hold = (leading_y_frames_ <= 2 && leading_abs_y_ <= 1.8);
          return sample_result_t {
            .eff_dx = 0.0,
            .eff_dy = dy,
            .hold_initial_dy = hold,
          };
        }
        leading_y_frames_ = 99;
        raw_abs_y_ += std::abs(dy);
        return sample_result_t {.eff_dx = 0.0, .eff_dy = dy};
      }

      if (gap_accum_dy_ * dy < 0.0) {
        gap_accum_dy_ = dy;
      } else {
        gap_accum_dy_ += dy;
      }
      const bool small_drift = (std::abs(dy) <= 3.6 && std::abs(gap_accum_dy_) <= 9.0);
      if (horiz_locked_ && small_drift && paired_xy_streak_ < 2) {
        ++gap_y_frames_;
        last_isolated_y_time_ = now;
        last_event_ = now;

        double bridge = 0.0;
        bool update_vx = false;
        if (gap_y_frames_ <= 5 && std::abs(vx_) >= 45.0 && (dt_any <= 0.0 || dt_any <= 0.045)) {
          constexpr double kBridgeDecay[5] = {0.75, 0.60, 0.45, 0.30, 0.20};
          const double step_dt = (dt_any >= 0.0035 && dt_any <= 0.030) ? dt_any : nominal_dt_;
          bridge = std::clamp(vx_ * step_dt * kBridgeDecay[gap_y_frames_ - 1], -28.0, 28.0);
          gap_bridged_dx_ += bridge;
          raw_abs_x_ += std::abs(bridge);
          if (gap_y_frames_ <= 3) {
            vx_ *= 0.92;
            update_vx = true;
          } else {
            vx_ *= 0.72;
          }
        } else if (gap_y_frames_ <= 8) {
          vx_ *= 0.65;
        } else {
          // More than 8 vertical-only packets without any X confirmation means the user transitioned vertically.
          horiz_locked_ = false;
          vx_ = 0.0;
          raw_abs_y_ += std::abs(dy);
          return sample_result_t {
            .eff_dx = 0.0,
            .eff_dy = dy,
            .vx = 0.0,
            .has_vx_update = true,
            .horizontal_locked = false,
          };
        }
        return sample_result_t {
          .eff_dx = bridge,
          .eff_dy = 0.0,
          .vx = vx_,
          .has_vx_update = update_vx,
          .horizontal_locked = true,
        };
      }

      horiz_locked_ = false;
      gap_y_frames_ = 0;
      gap_bridged_dx_ = 0.0;
      last_isolated_y_time_ = now;
      last_event_ = now;
      raw_abs_y_ += std::abs(dy);
      return sample_result_t {
        .eff_dx = 0.0,
        .eff_dy = dy,
        .horizontal_locked = false,
      };
    }

    sample_result_t observe_horizontal(clock::time_point now, double dx) {
      const double since_y = last_isolated_y_time_.time_since_epoch().count() ?
                               std::chrono::duration<double>(now - last_isolated_y_time_).count() :
                               -1.0;
      const double since_x = last_real_x_time_.time_since_epoch().count() ?
                               std::chrono::duration<double>(now - last_real_x_time_).count() :
                               -1.0;

      // Detect clients that genuinely emit paired (Y, X) packets on every diagonal frame (< 2ms apart).
      const bool paired_frame =
        ((real_x_count_ == 0 && leading_y_frames_ == 1) ||
         (real_x_count_ > 0 && gap_y_frames_ == 1 && since_x >= 0.004 && since_x <= 0.025)) &&
        since_y >= 0.0 && since_y < 0.002;
      if (paired_frame) {
        if (++paired_xy_streak_ >= 2) {
          horiz_locked_ = false;
        }
      } else if (since_y < 0.0 || since_y >= 0.0035 || gap_y_frames_ > 1) {
        paired_xy_streak_ = 0;
      }

      // Suppress tiny horizontal wobble during an established vertical scroll.
      if (!horiz_locked_ &&
          raw_abs_y_ > 8.0 &&
          raw_abs_y_ > 2.5 * (raw_abs_x_ + std::abs(dx)) &&
          std::abs(dx) <= 3.5) {
        last_event_ = now;
        return sample_result_t {.eff_dx = 0.0, .eff_dy = 0.0};
      }

      const bool reversed = (real_x_count_ > 0 && last_real_dx_ * dx < 0.0);
      if (reversed) {
        gap_y_frames_ = 0;
        gap_bridged_dx_ = 0.0;
        last_real_vx_ = 0.0;
        vx_ = 0.0;
        peel_used_x_ = false;
      }

      const bool had_y_anchor =
        (paired_xy_streak_ < 2) &&
        ((real_x_count_ == 0 && leading_y_frames_ > 0 && leading_y_frames_ <= 5) ||
         (real_x_count_ > 0 && gap_y_frames_ > 0));

      double dt_eff = 0.0;
      if (had_y_anchor) {
        if (since_y >= 0.0035 && since_y <= 0.035) {
          dt_eff = since_y;
        } else if (since_y >= 0.0 && since_y < 0.0035) {
          // Network/VPN bunched a prior frame's Y packet with this frame's X packet.
          dt_eff = nominal_dt_;
        } else if (since_x > 0.0) {
          dt_eff = since_x;
        }
      } else if (since_x > 0.0) {
        dt_eff = since_x;
      }

      double inst_v = 0.0;
      if (dt_eff <= 0.0 || dt_eff > 0.095) {
        vx_ = 0.0;
        peel_used_x_ = false;
      } else {
        inst_v = std::clamp(dx / std::max(dt_eff, 0.0075), -8000.0, 8000.0);
        if (real_x_count_ == 0) {
          vx_ = 0.85 * inst_v;
          peel_used_x_ = false;
        } else if (last_real_vx_ == 0.0 || last_real_vx_ * inst_v < 0.0) {
          vx_ = inst_v;
          peel_used_x_ = false;
        } else {
          const double ref_v = (gap_y_frames_ > 0) ? last_real_vx_ : vx_;
          if (!peel_used_x_ && dt_eff < 0.025 && std::abs(ref_v) > 180.0 &&
              std::abs(inst_v) < 220.0 && std::abs(inst_v) < 0.35 * std::abs(ref_v)) {
            vx_ = 0.82 * ref_v + 0.18 * inst_v;
            peel_used_x_ = true;
          } else if (peel_used_x_ && std::abs(inst_v) < 0.50 * std::abs(ref_v)) {
            vx_ = inst_v;
          } else {
            if (std::abs(inst_v) >= 0.60 * std::abs(ref_v)) {
              peel_used_x_ = false;
            }
            vx_ = 0.55 * inst_v + 0.45 * ref_v;
          }
        }
      }

      double extra_dx = 0.0;
      bool cancel_unemitted_dy = false;
      if (real_x_count_ == 0 &&
          leading_y_frames_ > 0 &&
          leading_y_frames_ <= 4 &&
          paired_xy_streak_ < 2 &&
          std::abs(dx) >= 1.2 &&
          std::abs(dx) >= 2.0 * max_leading_dy_) {
        horiz_locked_ = true;
        raw_abs_y_ = 0.0;
        cancel_unemitted_dy = true;
        extra_dx = 0.5 * static_cast<double>(leading_y_frames_) * dx;
      } else if (real_x_count_ > 0 &&
                 gap_y_frames_ > 0 &&
                 paired_xy_streak_ < 2 &&
                 !reversed &&
                 since_x > 0.0 &&
                 since_x <= 0.110 &&
                 dt_eff > 0.0) {
        const double t_gap = std::max(0.0, since_x - dt_eff);
        const double v_end = inst_v;
        const double v_start = (last_real_vx_ != 0.0 && last_real_vx_ * v_end > 0.0) ? last_real_vx_ : v_end;
        double expected_gap = 0.5 * (v_start + v_end) * t_gap;
        const double cap = static_cast<double>(gap_y_frames_) * std::max(std::abs(last_real_dx_), std::abs(dx));
        expected_gap = std::clamp(expected_gap, -cap, cap);
        const double diff = expected_gap - gap_bridged_dx_;
        if (diff * dx > 0.0) {
          extra_dx = diff;
        }
      }

      const double total_dx = dx + extra_dx;
      raw_abs_x_ += std::abs(dx) + std::abs(extra_dx);
      if (!horiz_locked_ &&
          paired_xy_streak_ < 2 &&
          ((raw_abs_y_ == 0.0 && raw_abs_x_ >= 0.5) ||
           (raw_abs_x_ >= 1.5 && raw_abs_x_ >= 1.8 * raw_abs_y_))) {
        horiz_locked_ = true;
      }

      ++real_x_count_;
      last_real_x_time_ = now;
      last_event_ = now;
      last_real_dx_ = dx;
      last_real_vx_ = vx_;
      gap_y_frames_ = 0;
      gap_bridged_dx_ = 0.0;
      gap_accum_dy_ = 0.0;

      return sample_result_t {
        .eff_dx = total_dx,
        .eff_dy = 0.0,
        .vx = vx_,
        .has_vx_update = true,
        .horizontal_locked = horiz_locked_,
        .hold_initial_dy = false,
        .cancel_unemitted_dy = cancel_unemitted_dy,
      };
    }

    clock::time_point first_event_ {};
    clock::time_point last_event_ {};
    clock::time_point last_real_x_time_ {};
    clock::time_point last_isolated_y_time_ {};
    double nominal_dt_ {0.008333};
    double raw_abs_x_ {};
    double raw_abs_y_ {};
    double leading_abs_y_ {};
    double max_leading_dy_ {};
    int leading_y_frames_ {};
    int real_x_count_ {};
    bool horiz_locked_ {};
    double vx_ {};
    bool peel_used_x_ {};
    double last_real_dx_ {};
    double last_real_vx_ {};
    int gap_y_frames_ {};
    double gap_bridged_dx_ {};
    double gap_accum_dy_ {};
    int paired_xy_streak_ {};
  };
}  // namespace platf::wheel_scroll_policy
