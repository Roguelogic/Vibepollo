#include "src/platform/macos/wheel_scroll.h"

#include <cmath>
#include <gtest/gtest.h>

using platf::wheel_scroll_policy::drag_gain;
using platf::wheel_scroll_policy::drag_step;

TEST(MacosWheelScroll, DragStepConvergesExactIntegerAndHalfPixelTargets) {
  for (double target : {0.5, -0.5, 1.0, -1.0, 17.4, -23.6}) {
    std::int64_t emitted = 0;
    for (int i = 0; i < 16; ++i) {
      emitted += drag_step(target, emitted, drag_gain);
    }
    EXPECT_EQ(emitted, std::llround(target));
    EXPECT_EQ(drag_step(target, emitted, drag_gain), 0);
  }
}
