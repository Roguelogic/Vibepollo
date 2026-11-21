#include "src/platform/macos/wheel_scroll.h"

#include <cmath>
#include <gtest/gtest.h>
#include <vector>

using namespace std::chrono_literals;
using platf::wheel_scroll_policy::drag_gain;
using platf::wheel_scroll_policy::drag_step;
using platf::wheel_scroll_policy::horizontal_reconstructor_t;

namespace {
  // Exact C++ replica of unpatched VoidLink StreamView.m mouseWheelMovedContinuous:
  struct unpatched_voidlink_sender_t {
    double bounds_w {1376.0};
    double bounds_h {774.0};  // 16:9 1080p stream on iPad Pro 13"
    double last_x {};
    double last_y {};

    struct wire_packet_t {
      bool horizontal {};
      short amount {};
    };

    std::vector<wire_packet_t> step_to(double cur_x, double cur_y) {
      constexpr short mult = 120 * 20;
      std::vector<wire_packet_t> out;
      const short dy = static_cast<short>(((cur_y - last_y) / bounds_h) * mult);
      if (dy != 0) {
        out.push_back({false, dy});
        last_x = cur_x;  // Bug: overwrites X baseline!
        last_y = cur_y;
      }
      const short dx = static_cast<short>(((cur_x - last_x) / bounds_w) * mult);
      if (dx != 0) {
        out.push_back({true, static_cast<short>(-dx)});
        last_x = cur_x;
        last_y = cur_y;
      }
      return out;
    }
  };

  double wheel_units_to_px(short units, double aspect_gain = 1.0) {
    return static_cast<double>(units) * 50.0 / 120.0 * aspect_gain;
  }
}  // namespace

TEST(MacosWheelScroll, ReconstructsAngledHorizontalSwipesSentByUnpatchedVoidLink) {
  // Simulate a realistic 120Hz human wrist-arc horizontal swipe (~90pt over 120ms = 750pt/s)
  // across wrist angles from 0 deg to 12 deg, where unpatched VoidLink drops up to 80% of X frames.
  constexpr int frames = 15;
  constexpr auto dt = 8333us;
  const double aspect_gain = 1376.0 / 774.0;

  auto run_swipe = [&](double angle_deg) {
    unpatched_voidlink_sender_t sender;
    horizontal_reconstructor_t recon;
    auto now = horizontal_reconstructor_t::clock::time_point {} + 1s;
    const double rad = angle_deg * M_PI / 180.0;

    double x = 0.0;
    double y = 0.0;
    double sum_dx = 0.0;
    double sum_dy = 0.0;
    double last_vx = 0.0;

    for (int i = 0; i < frames; ++i) {
      now += dt;
      // Bell-shaped finger velocity with slight natural wrist curvature so >= 2 X packets survive.
      const double u = (static_cast<double>(i) + 0.5) / static_cast<double>(frames);
      const double speed_pt = 9.2 * std::sin(M_PI * u);  // peaks at ~9.2 pt/frame (~1100 pt/s)
      const double wrist_curve = std::cos(M_PI * u);    // slight arc: +angle -> 0 -> -angle
      x -= speed_pt * std::cos(rad);
      y += speed_pt * std::sin(rad) * wrist_curve;

      for (const auto &pkt : sender.step_to(x, y)) {
        const double dx = pkt.horizontal ? wheel_units_to_px(pkt.amount, aspect_gain) : 0.0;
        const double dy = pkt.horizontal ? 0.0 : wheel_units_to_px(pkt.amount, 1.0);
        const auto res = recon.observe(now, dx, dy);
        if (res.cancel_unemitted_dy) {
          sum_dy = 0.0;
        }
        sum_dx += res.eff_dx;
        sum_dy += std::abs(res.eff_dy);
        if (res.has_vx_update) {
          last_vx = res.vx;
        }
      }
    }
    return std::tuple {sum_dx, sum_dy, last_vx};
  };

  const auto [dx_0, dy_0, vx_0] = run_swipe(0.0);
  ASSERT_GT(dx_0, 95.0);
  ASSERT_GT(vx_0, 300.0);

  for (const double angle : {3.0, 6.0, 9.0, 12.0}) {
    const auto [dx_a, dy_a, vx_a] = run_swipe(angle);
    EXPECT_GT(dx_a, dx_0 * 0.72) << "Horizontal travel collapsed at angle=" << angle;
    EXPECT_LT(dx_a, dx_0 * 1.25) << "Horizontal travel overshot at angle=" << angle;
    EXPECT_GT(vx_a, 240.0) << "Horizontal flick velocity collapsed at angle=" << angle;
    EXPECT_LE(dy_a, 1.5) << "Parasitic vertical drift leaked at angle=" << angle;
  }
}

TEST(MacosWheelScroll, PreservesVelocityAcrossMultiFrameGapsAndTrailingPeelAndVpnBursts) {
  horizontal_reconstructor_t recon;
  auto now = horizontal_reconstructor_t::clock::time_point {} + 1s;

  // Leading tiny Y drift followed by X, then 4 swallowed Y frames, then VPN-bunched Y+X, then 2 trailing Y peels.
  auto r0 = recon.observe(now, 0.0, 0.42);
  EXPECT_TRUE(r0.hold_initial_dy);

  now += 8ms;
  auto r1 = recon.observe(now, 6.0, 0.0);
  EXPECT_TRUE(r1.cancel_unemitted_dy);
  EXPECT_GT(r1.eff_dx, 8.0);  // 6.0 + 0.5 * 6.0 leading ramp
  EXPECT_GT(r1.vx, 500.0);

  double gap_sum = 0.0;
  for (int i = 0; i < 4; ++i) {
    now += 8ms;
    auto rg = recon.observe(now, 0.0, 0.42);
    EXPECT_EQ(rg.eff_dy, 0.0);
    gap_sum += rg.eff_dx;
  }
  EXPECT_GT(gap_sum, 8.0);

  // Simulate VPN burst: 5th Y arrives delayed by 8ms and X arrives 1ms later!
  now += 15ms;
  auto r_burst_y = recon.observe(now, 0.0, 0.42);
  gap_sum += r_burst_y.eff_dx;
  now += 1ms;
  auto r2 = recon.observe(now, 6.0, 0.0);
  EXPECT_GT(r2.vx, 550.0);  // Must NOT collapse to 6.0 / 0.048s = 125 px/s!
  EXPECT_NEAR(gap_sum + r2.eff_dx, 33.0, 4.0);  // 5 missed frames + current frame across 48ms

  // Two trailing finger-peel Y frames at lift-off must preserve flick velocity.
  now += 8ms;
  auto rp1 = recon.observe(now, 0.0, -0.42);
  now += 8ms;
  auto rp2 = recon.observe(now, 0.0, -0.42);
  EXPECT_TRUE(rp1.has_vx_update);
  EXPECT_TRUE(rp2.has_vx_update);
  EXPECT_GT(rp2.vx, 450.0);
}

TEST(MacosWheelScroll, LeavesVerticalDiagonalReversalAndPairedClientsClean) {
  // 1. Pure vertical scroll passes 1:1 with zero horizontal synthesis.
  {
    horizontal_reconstructor_t recon;
    auto now = horizontal_reconstructor_t::clock::time_point {} + 1s;
    double sum_y = 0.0;
    for (int i = 0; i < 10; ++i) {
      now += 8ms;
      const auto r = recon.observe(now, 0.0, -4.5);
      EXPECT_EQ(r.eff_dx, 0.0);
      sum_y += r.eff_dy;
    }
    EXPECT_DOUBLE_EQ(sum_y, -45.0);
  }

  // 2. Direction reversal never adds forward gap distance.
  {
    horizontal_reconstructor_t recon;
    auto now = horizontal_reconstructor_t::clock::time_point {} + 1s;
    recon.observe(now, 8.0, 0.0);
    now += 8ms;
    recon.observe(now, 0.0, 0.5);
    now += 8ms;
    const auto rev = recon.observe(now, -8.0, 0.0);
    EXPECT_DOUBLE_EQ(rev.eff_dx, -8.0);
    EXPECT_LT(rev.vx, 0.0);
  }

  // 3. Paired simultaneous (Y, X) diagonal client (< 2ms apart every frame) passes both axes without gap inflation.
  {
    horizontal_reconstructor_t recon;
    auto now = horizontal_reconstructor_t::clock::time_point {} + 1s;
    for (int i = 0; i < 6; ++i) {
      now += 15ms;
      const auto ry = recon.observe(now, 0.0, 2.5);
      now += 1ms;
      const auto rx = recon.observe(now, 5.0, 0.0);
      if (i >= 2) {
        EXPECT_DOUBLE_EQ(ry.eff_dy, 2.5);
        EXPECT_DOUBLE_EQ(rx.eff_dx, 5.0);
      }
    }
  }

  // 4. Active braking on trackpad (2+ decelerating samples < 80 px/s) kills flick velocity cleanly.
  {
    horizontal_reconstructor_t recon;
    auto now = horizontal_reconstructor_t::clock::time_point {} + 1s;
    for (int i = 0; i < 5; ++i) {
      now += 8ms;
      recon.observe(now, -7.5, 0.0);
    }
    now += 10ms;
    recon.observe(now, -0.9, 0.0);  // 1st decelerating sample (peel candidate)
    now += 12ms;
    const auto brake = recon.observe(now, -0.6, 0.0);  // 2nd decelerating sample -> real brake!
    EXPECT_LT(std::abs(brake.vx), 80.0);
  }

  // 5. Fractional drag_step settles cleanly.
  for (double target : {0.5, -0.5}) {
    const int step = drag_step(target, 0, drag_gain);
    EXPECT_EQ(step, std::lround(target));
    EXPECT_EQ(drag_step(target, step, drag_gain), 0);
  }
}
