/**
 * @file src/platform/macos/sc_video.h
 * @brief Declarations for ScreenCaptureKit video capture on macOS.
 */
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif
/// Dynamically shows or hides the composited macOS cursor across active ScreenCaptureKit streams.
void macos_sc_set_cursor_visible(bool visible);

/// Updates and shows the Windows-Ink-style stylus hover reticle at Quartz global coordinates (x, y).
void macos_pen_hover_cursor_show(double cg_x, double cg_y, float distance_norm, bool eraser);

/// Hides the stylus hover reticle immediately.
void macos_pen_hover_cursor_hide(void);
#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
// local includes
#import "av_video.h"
/**
 * @brief AVVideo backed by ScreenCaptureKit instead of AVCaptureScreenInput.
 * @details AVCaptureScreenInput delivers no frames from virtual displays (CGVirtualDisplay), so
 *          the per-client virtual display is captured with ScreenCaptureKit. It keeps AVVideo's
 *          interface, so the rest of the capture and encode pipeline is unchanged.
 */
@interface SCVideo: AVVideo

/// Longest time without a delivered frame before the last one is re-sent (the minimum frame rate).
@property (nonatomic, assign) CMTime keepaliveInterval;

/// Capture HDR, in BT.2020 with the PQ transfer function, when the pixel format is 10-bit. Needs macOS 15.
@property (nonatomic, assign) BOOL hdr;

/// Deliver frames directly on SCStream's sampleQueue without bouncing through a second GCD queue.
@property (nonatomic, assign) BOOL directDelivery;

/// Why ScreenCaptureKit last stopped a capture by itself, such as its display going away; nil if it hasn't.
@property (atomic, copy) NSString *stopReason;

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback;

@end
#endif
