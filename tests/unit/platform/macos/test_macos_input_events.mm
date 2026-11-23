#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

#include "src/platform/macos/cf_guard.h"
#include "src/platform/macos/palm_rejection.h"

#include <chrono>
#include <gtest/gtest.h>

using namespace std::chrono_literals;
namespace mip = platf::macos_input_policy;

TEST(MacosInputEvents, PalmRejectionBlocksFingerWhilePencilActiveAndExpiresSafely) {
  mip::palm_rejection_tracker_t tracker;
  const auto t0 = mip::palm_rejection_tracker_t::clock_t::now();

  EXPECT_FALSE(tracker.should_reject_touch(true, 1, t0));

  tracker.note_pen_activity(t0, false);
  EXPECT_TRUE(tracker.should_reject_touch(true, 1, t0 + 20ms));
  EXPECT_FALSE(tracker.should_reject_touch(false, 1, t0 + 20ms));
  EXPECT_FALSE(tracker.should_reject_touch(true, mip::voidlink_pencil_touch_id, t0 + 20ms));

  // Auto-expires after hover silence timeout if UDP HOVER_LEAVE is dropped.
  EXPECT_FALSE(tracker.should_reject_touch(true, 1, t0 + 400ms));

  const auto t1 = t0 + 1000ms;
  tracker.note_pen_activity(t1, true);
  tracker.note_pen_leave(t1 + 50ms);
  // Within 80ms post_leave_cooldown -> still rejected.
  EXPECT_TRUE(tracker.should_reject_touch(true, 2, t1 + 100ms));
  // Past 80ms post_leave_cooldown (e.g. +140ms after t1, which is +90ms after leave) -> must NOT be shadowed by 180ms post_pen_cooldown!
  EXPECT_FALSE(tracker.should_reject_touch(true, 2, t1 + 150ms));

  // cf_ref_t self-reset guard must not release the live CFTypeRef.
  platf::cf_ref_t<CFStringRef> self_guard {
    CFStringCreateWithCString(kCFAllocatorDefault, "vibepollo", kCFStringEncodingUTF8)
  };
  ASSERT_TRUE(static_cast<bool>(self_guard));
  self_guard.reset(self_guard.get());
  EXPECT_EQ(CFStringGetLength(self_guard.get()), 9);

  // Pencil liftoff detection during active Scroll & Tap contact:
  // 1) A single zero-distance hover sample 8ms after contact is ignored (prevents mid-stroke false lift).
  EXPECT_FALSE(mip::should_finish_pen_contact_on_hover(0.0f, 1, 8ms));
  // 2) Elevated hover distance (> 0.002) finishes promptly on 2nd packet or >= 16ms.
  EXPECT_TRUE(mip::should_finish_pen_contact_on_hover(0.02f, 2, 8ms));
  EXPECT_TRUE(mip::should_finish_pen_contact_on_hover(0.02f, 1, 18ms));
  // 3) Zero-distance hover stream still finishes within 3 packets or >= 32ms (never stuck for 600ms).
  EXPECT_TRUE(mip::should_finish_pen_contact_on_hover(0.0f, 3, 16ms));
  EXPECT_TRUE(mip::should_finish_pen_contact_on_hover(0.0f, 1, 35ms));
}

TEST(MacosInputEvents, TrackpadGestureEmitterBalancesPhasesAndForbidsBookends) {
  mip::trackpad_gesture_emitter_t emitter;

  EXPECT_FALSE(mip::trackpad_gesture_emitter_t::is_allowed_packet({61, mip::trackpad_gesture_emitter_t::phase_began, 0.0}));
  EXPECT_FALSE(mip::trackpad_gesture_emitter_t::is_allowed_packet({62, mip::trackpad_gesture_emitter_t::phase_ended, 0.0}));
  EXPECT_FALSE(mip::trackpad_gesture_emitter_t::is_allowed_packet({mip::trackpad_gesture_emitter_t::subtype_magnify, 12, 0.0}));

  EXPECT_TRUE(emitter.end(mip::trackpad_gesture_emitter_t::subtype_magnify).empty());

  auto changed = emitter.change(mip::trackpad_gesture_emitter_t::subtype_magnify, 0.12);
  ASSERT_EQ(changed.size(), 2u);
  EXPECT_EQ(changed[0].phase, mip::trackpad_gesture_emitter_t::phase_began);
  EXPECT_EQ(changed[1].phase, mip::trackpad_gesture_emitter_t::phase_changed);
  EXPECT_DOUBLE_EQ(changed[1].amount, 0.12);

  EXPECT_TRUE(emitter.begin(mip::trackpad_gesture_emitter_t::subtype_magnify).empty());

  auto ended = emitter.end(mip::trackpad_gesture_emitter_t::subtype_magnify, false);
  ASSERT_EQ(ended.size(), 1u);
  EXPECT_EQ(ended[0].phase, mip::trackpad_gesture_emitter_t::phase_ended);
}

TEST(MacosInputEvents, ReusableGestureCGEventRoundTripsMagnifyAndRotateThroughNSEvent) {
  @autoreleasepool {
    platf::cf_ref_t<CGEventRef> ev {CGEventCreate(nullptr)};
    ASSERT_TRUE(static_cast<bool>(ev));

    constexpr auto kEventTypeGesture = static_cast<CGEventType>(29);
    constexpr auto kSubtypeField = static_cast<CGEventField>(110);
    constexpr auto kMagnifyField = static_cast<CGEventField>(113);
    constexpr auto kRotateField = static_cast<CGEventField>(114);
    constexpr auto kPhaseField = static_cast<CGEventField>(132);

    // 1. Rotate packet on reusable CGEventRef
    const mip::trackpad_gesture_packet_t rot_pkt {
      mip::trackpad_gesture_emitter_t::subtype_rotate,
      mip::trackpad_gesture_emitter_t::phase_changed,
      22.5,
    };
    const auto rot_write = mip::trackpad_gesture_emitter_t::resolve_value_field_write(rot_pkt);
    CGEventSetType(ev.get(), kEventTypeGesture);
    CGEventSetIntegerValueField(ev.get(), kSubtypeField, rot_pkt.subtype);
    CGEventSetIntegerValueField(ev.get(), kPhaseField, rot_pkt.phase);
    CGEventSetDoubleValueField(
      ev.get(),
      rot_write.slot == mip::cg_gesture_value_slot_e::rotate_114 ? kRotateField : kMagnifyField,
      rot_write.value
    );

    NSEvent *ns_rot = [NSEvent eventWithCGEvent:ev.get()];
    ASSERT_NE(ns_rot, nil);
    EXPECT_EQ([ns_rot type], NSEventTypeRotate);
    EXPECT_EQ([ns_rot phase], NSEventPhaseChanged);
    EXPECT_NEAR([ns_rot rotation], 22.5f, 0.01f);

    // 2. Magnify packet on the SAME CGEventRef must preserve non-zero magnification
    const mip::trackpad_gesture_packet_t mag_pkt {
      mip::trackpad_gesture_emitter_t::subtype_magnify,
      mip::trackpad_gesture_emitter_t::phase_changed,
      0.15,
    };
    const auto mag_write = mip::trackpad_gesture_emitter_t::resolve_value_field_write(mag_pkt);
    CGEventSetType(ev.get(), kEventTypeGesture);
    CGEventSetIntegerValueField(ev.get(), kSubtypeField, mag_pkt.subtype);
    CGEventSetIntegerValueField(ev.get(), kPhaseField, mag_pkt.phase);
    CGEventSetDoubleValueField(
      ev.get(),
      mag_write.slot == mip::cg_gesture_value_slot_e::rotate_114 ? kRotateField : kMagnifyField,
      mag_write.value
    );

    NSEvent *ns_mag = [NSEvent eventWithCGEvent:ev.get()];
    ASSERT_NE(ns_mag, nil);
    EXPECT_EQ([ns_mag type], NSEventTypeMagnify);
    EXPECT_EQ([ns_mag phase], NSEventPhaseChanged);
    EXPECT_NEAR([ns_mag magnification], 0.15, 1e-4);
  }
}

TEST(MacosInputEvents, ContinuousScrollAndTabletPointCGEventsRoundTripThroughNSEvent) {
  @autoreleasepool {
    // 1. Continuous pixel scroll wheel event
    platf::cf_ref_t<CGEventRef> scroll_ev {
      CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, -24, 12)
    };
    ASSERT_TRUE(static_cast<bool>(scroll_ev));
    CGEventSetIntegerValueField(scroll_ev.get(), kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(scroll_ev.get(), kCGScrollWheelEventScrollPhase, kCGScrollPhaseBegan);
    CGEventSetIntegerValueField(scroll_ev.get(), kCGScrollWheelEventMomentumPhase, 0);

    NSEvent *ns_scroll = [NSEvent eventWithCGEvent:scroll_ev.get()];
    ASSERT_NE(ns_scroll, nil);
    EXPECT_EQ([ns_scroll type], NSEventTypeScrollWheel);
    EXPECT_TRUE([ns_scroll hasPreciseScrollingDeltas]);
    EXPECT_EQ([ns_scroll phase], NSEventPhaseBegan);
    EXPECT_DOUBLE_EQ([ns_scroll scrollingDeltaY], -24.0);
    EXPECT_DOUBLE_EQ([ns_scroll scrollingDeltaX], 12.0);

    // 2. Apple Pencil tablet point event
    platf::cf_ref_t<CGEventRef> pen_ev {
      CGEventCreateMouseEvent(nullptr, kCGEventLeftMouseDragged, CGPointMake(300.0, 200.0), kCGMouseButtonLeft)
    };
    ASSERT_TRUE(static_cast<bool>(pen_ev));
    CGEventSetIntegerValueField(pen_ev.get(), kCGMouseEventSubtype, kCGEventMouseSubtypeTabletPoint);
    CGEventSetDoubleValueField(pen_ev.get(), kCGTabletEventPointPressure, 0.75);
    CGEventSetDoubleValueField(pen_ev.get(), kCGMouseEventPressure, 0.75);
    CGEventSetDoubleValueField(pen_ev.get(), kCGTabletEventTiltX, 0.25);
    CGEventSetDoubleValueField(pen_ev.get(), kCGTabletEventTiltY, -0.5);
    CGEventSetDoubleValueField(pen_ev.get(), kCGTabletEventRotation, 135.0);

    NSEvent *ns_pen = [NSEvent eventWithCGEvent:pen_ev.get()];
    ASSERT_NE(ns_pen, nil);
    EXPECT_EQ([ns_pen subtype], NSEventSubtypeTabletPoint);
    EXPECT_NEAR([ns_pen pressure], 0.75f, 0.01f);
    EXPECT_NEAR([ns_pen tilt].x, 0.25, 0.01);
    EXPECT_NEAR([ns_pen tilt].y, -0.5, 0.01);
    EXPECT_NEAR([ns_pen rotation], 135.0f, 0.5f);
  }
}
