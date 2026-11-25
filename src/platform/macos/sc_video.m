/**
 * @file src/platform/macos/sc_video.m
 * @brief Definitions for ScreenCaptureKit video capture on macOS.
 */
// platform includes
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// local includes
#import "sc_video.h"

static NSHashTable<SCVideo *> *sActiveSCVideos = nil;
static BOOL sGlobalShowsCursor = YES;

@interface SCVideo ()
- (void)reconfigureActiveCaptures;
- (void)removeFinishedCapture:(id)capture;
@end

void macos_sc_set_cursor_visible(bool visible) {
  @autoreleasepool {
    const BOOL want = visible ? YES : NO;
    NSArray<SCVideo *> *videos = nil;
    @synchronized([SCVideo class]) {
      if (sGlobalShowsCursor == want) {
        return;
      }
      sGlobalShowsCursor = want;
      videos = [sActiveSCVideos allObjects];
    }
    for (SCVideo *video in videos) {
      [video reconfigureActiveCaptures];
    }
  }
}

bool macos_sc_sample_screen_rect(CMSampleBufferRef sample_buffer, double *x, double *y, double *width, double *height) {
  if (sample_buffer == NULL || x == NULL || y == NULL || width == NULL || height == NULL) {
    return false;
  }
  if (@available(macOS 12.3, *)) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample_buffer, false);
    if (attachments == NULL || CFArrayGetCount(attachments) == 0) {
      return false;
    }
    CFDictionaryRef info = (CFDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
    if (info == NULL) {
      return false;
    }
    CFDictionaryRef rect_dict = (CFDictionaryRef) CFDictionaryGetValue(info, (__bridge const void *) SCStreamFrameInfoScreenRect);
    if (rect_dict == NULL || CFGetTypeID(rect_dict) != CFDictionaryGetTypeID()) {
      return false;
    }
    CGRect rect = CGRectZero;
    if (!CGRectMakeWithDictionaryRepresentation(rect_dict, &rect)) {
      return false;
    }
    *x = rect.origin.x;
    *y = rect.origin.y;
    *width = rect.size.width;
    *height = rect.size.height;
    return true;
  }
  return false;
}

/**
 * @brief One capture: a stream feeding a frame callback until the callback returns false.
 * @details ScreenCaptureKit delivers frames on sampleQueue, which stores the latest frame and
 *          merges a dispatch source on deliveryQueue without blocking SCStream's surface pool.
 */
@interface SCVideoCapture: NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, weak) SCVideo *owner;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, copy) FrameCallbackBlock callback;
@property (nonatomic, strong) dispatch_semaphore_t signal;
@property (nonatomic, strong) dispatch_queue_t sampleQueue;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL directDelivery;
- (void)setupFrameSource;
- (void)startKeepaliveEvery:(CMTime)interval;
- (void)finish;
- (void)stopWithError:(NSError *)error;
@end

@implementation SCVideoCapture {
  CMSampleBufferRef _latestFrame;
  CMSampleBufferRef _keepaliveFrame;
  dispatch_source_t _frameSource;
  dispatch_source_t _keepalive;
  uint64_t _keepalivePeriod;
  uint64_t _lastDelivery;
  BOOL _finished;
}

- (void)setupFrameSource {
  _frameSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, self.queue);
  __weak SCVideoCapture *weakSelf = self;
  dispatch_source_set_event_handler(_frameSource, ^{
    [weakSelf drainLatestFrame];
  });
  dispatch_resume(_frameSource);
}

- (void)startKeepaliveEvery:(CMTime)interval {
  _keepalivePeriod = (uint64_t) (CMTimeGetSeconds(interval) * NSEC_PER_SEC);
  _keepalive = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
  dispatch_source_set_timer(_keepalive, dispatch_time(DISPATCH_TIME_NOW, _keepalivePeriod), _keepalivePeriod, _keepalivePeriod / 10);
  __weak SCVideoCapture *weakSelf = self;
  dispatch_source_set_event_handler(_keepalive, ^{
    [weakSelf keepaliveTick];
  });
  dispatch_resume(_keepalive);
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer) || CMSampleBufferGetImageBuffer(sampleBuffer) == NULL) {
    return;
  }
  if (self.directDelivery) {
    @synchronized(self) {
      if (_finished) {
        return;
      }
      if (_keepalive != nil) {
        if (_keepaliveFrame != NULL) {
          CFRelease(_keepaliveFrame);
        }
        _keepaliveFrame = (CMSampleBufferRef) CFRetain(sampleBuffer);
      }
    }
    _lastDelivery = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!self.callback(sampleBuffer)) {
      [self finishOnQueue];
    }
    return;
  }
  @synchronized(self) {
    if (_finished) {
      return;
    }
    if (_latestFrame != NULL) {
      CFRelease(_latestFrame);
    }
    _latestFrame = (CMSampleBufferRef) CFRetain(sampleBuffer);
    if (_keepalive != nil) {
      if (_keepaliveFrame != NULL) {
        CFRelease(_keepaliveFrame);
      }
      _keepaliveFrame = (CMSampleBufferRef) CFRetain(sampleBuffer);
    }
  }
  if (_frameSource != nil) {
    dispatch_source_merge_data(_frameSource, 1);
  }
}

- (void)drainLatestFrame {
  CMSampleBufferRef frame = NULL;
  @synchronized(self) {
    if (_finished || _latestFrame == NULL) {
      return;
    }
    frame = _latestFrame;
    _latestFrame = NULL;
  }
  _lastDelivery = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  BOOL ok = self.callback(frame);
  CFRelease(frame);
  if (!ok) {
    [self finishOnQueue];
  }
}

- (void)keepaliveTick {
  const uint64_t idle = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _lastDelivery;
  if (idle < _keepalivePeriod * 9 / 10) {
    return;
  }
  CMSampleBufferRef frame = NULL;
  @synchronized(self) {
    if (_finished || _keepaliveFrame == NULL) {
      return;
    }
    frame = (CMSampleBufferRef) CFRetain(_keepaliveFrame);
  }
  _lastDelivery = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  BOOL ok = self.callback(frame);
  CFRelease(frame);
  if (!ok) {
    [self finishOnQueue];
  }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  [self stopWithError:error];
}

- (void)stopWithError:(NSError *)error {
  self.owner.stopReason = [NSString stringWithFormat:@"%@ (%@ %ld)", error.localizedDescription, error.domain, (long) error.code];
  [self finish];
}

- (void)finish {
  dispatch_async(self.queue, ^{
    [self finishOnQueue];
  });
}

- (void)finishOnQueue {
  @synchronized(self) {
    if (_finished) {
      return;
    }
    _finished = YES;
    if (_latestFrame != NULL) {
      CFRelease(_latestFrame);
      _latestFrame = NULL;
    }
    if (_keepaliveFrame != NULL) {
      CFRelease(_keepaliveFrame);
      _keepaliveFrame = NULL;
    }
  }
  if (_frameSource != nil) {
    dispatch_source_cancel(_frameSource);
  }
  if (_keepalive != nil) {
    dispatch_source_cancel(_keepalive);
  }
  [self.stream stopCaptureWithCompletionHandler:nil];
  [self.owner removeFinishedCapture:self];
  dispatch_semaphore_signal(self.signal);
}

- (void)dealloc {
  if (_frameSource != nil) {
    dispatch_source_cancel(_frameSource);
  }
  if (_keepalive != nil) {
    dispatch_source_cancel(_keepalive);
  }
  if (_latestFrame != NULL) {
    CFRelease(_latestFrame);
  }
  if (_keepaliveFrame != NULL) {
    CFRelease(_keepaliveFrame);
  }
}

@end

@implementation SCVideo {
  SCDisplay *_display;
  NSMutableArray<SCVideoCapture *> *_captures;
}

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  // Skips AVVideo's initializer, which would set up AVCaptureScreenInput.
  self = [super init];
  if (!self) {
    return nil;
  }

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (mode == NULL) {
    return nil;
  }
  self.displayID = displayID;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
  self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
  const int fps = MAX(frameRate, 1);
  const double refresh = CGDisplayModeGetRefreshRate(mode);
  if (refresh > 0.0 && fps >= (int) floor(refresh)) {
    // Per SCStreamConfiguration.minimumFrameInterval docs, kCMTimeZero captures every native
    // display VSync without arming SCStream's interval throttle (which otherwise drops the next
    // frame whenever a slightly delayed GPU composite brings two callbacks < 7.5ms apart).
    self.minFrameDuration = kCMTimeZero;
  } else {
    self.minFrameDuration = CMTimeMake(9, fps * 10);
  }
  CGDisplayModeRelease(mode);

  dispatch_semaphore_t found = dispatch_semaphore_create(0);
  __block SCDisplay *display = nil;
  [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                             onScreenWindowsOnly:YES
                                               completionHandler:^(SCShareableContent *content, NSError *error) {
    for (SCDisplay *candidate in content.displays) {
      if (candidate.displayID == displayID) {
        display = candidate;
      }
    }
    dispatch_semaphore_signal(found);
  }];
  const int64_t wait_ns = (geteuid() == 0) ? (1 * NSEC_PER_SEC) : (5 * NSEC_PER_SEC);
  if (dispatch_semaphore_wait(found, dispatch_time(DISPATCH_TIME_NOW, wait_ns)) != 0 || display == nil) {
    return nil;
  }

  _display = display;
  _captures = [NSMutableArray array];
  @synchronized([SCVideo class]) {
    if (sActiveSCVideos == nil) {
      sActiveSCVideos = [NSHashTable weakObjectsHashTable];
    }
    [sActiveSCVideos addObject:self];
    sGlobalShowsCursor = YES;
  }
  return self;
}

- (void)removeFinishedCapture:(id)capture {
  @synchronized(self) {
    [_captures removeObjectIdenticalTo:capture];
  }
}

- (SCStreamConfiguration *)makeStreamConfiguration {
  SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
  configuration.width = self.frameWidth;
  configuration.height = self.frameHeight;
  configuration.pixelFormat = self.pixelFormat;
  configuration.captureResolution = SCCaptureResolutionBest;
  configuration.preservesAspectRatio = YES;
  const BOOL tenBitHdrFormat = (self.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                                self.pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange);
  if (self.hdr && tenBitHdrFormat) {
    if ([configuration respondsToSelector:NSSelectorFromString(@"setCaptureDynamicRange:")]) {
      // Keep SCCaptureDynamicRangeHDRLocalDisplay (1) so WindowServer stays on the direct
      // display composite tap. HDRCanonicalDisplay (2) triggers a second FP16 per-window/backdrop
      // re-composition pass (+25~30%p M4 GPU load at 2752x2064@120Hz), saturating the GPU to
      // 85~98% and causing 120Hz VSync misses under Liquid Glass and Apple Music windows.
      [configuration setValue:@1 forKey:@"captureDynamicRange"];
    }
    configuration.colorSpaceName = kCGColorSpaceITUR_2100_PQ;
    configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
  }
  configuration.minimumFrameInterval = self.minFrameDuration;
  BOOL showCursor = YES;
  @synchronized([SCVideo class]) {
    showCursor = sGlobalShowsCursor;
  }
  configuration.showsCursor = showCursor;
  // Leave shouldBeOpaque and ignoreShadowsDisplay at their defaults (NO): setting either on a
  // full-display stream forces WindowServer off the direct display composite tap into a second
  // per-window RGBA16Float re-composition pass (+35~45% GPU load on M4 at 2752x2064@120Hz HDR).
  // Keep 8 surfaces in SCStream's pool so 120~144Hz ProMotion HDR ('xf44') never starves
  // WindowServer's swapchain while AppleAVE2's 3-stage hardware DMA pipeline is active.
  configuration.queueDepth = 8;
  return configuration;
}

- (void)reconfigureActiveCaptures {
  NSArray<SCVideoCapture *> *active = nil;
  @synchronized(self) {
    if (_captures.count > 0) {
      active = [_captures copy];
    }
  }
  if (active.count == 0) {
    return;
  }
  SCStreamConfiguration *configuration = [self makeStreamConfiguration];
  for (SCVideoCapture *capture in active) {
    [capture.stream updateConfiguration:configuration completionHandler:nil];
  }
}

- (void)setPixelFormat:(OSType)pixelFormat {
  if (self.pixelFormat == pixelFormat) {
    return;
  }
  [super setPixelFormat:pixelFormat];
  [self reconfigureActiveCaptures];
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  if (self.frameWidth == frameWidth && self.frameHeight == frameHeight) {
    return;
  }
  [super setFrameWidth:frameWidth frameHeight:frameHeight];
  [self reconfigureActiveCaptures];
}

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
  SCStreamConfiguration *configuration = [self makeStreamConfiguration];

  SCVideoCapture *capture = [[SCVideoCapture alloc] init];
  capture.owner = self;
  capture.callback = frameCallback;
  capture.signal = dispatch_semaphore_create(0);
  capture.directDelivery = self.directDelivery;
  dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  capture.sampleQueue = dispatch_queue_create("videoSampleQueue", qos);
  if (self.directDelivery) {
    capture.queue = capture.sampleQueue;
  } else {
    capture.queue = dispatch_queue_create("videoDeliveryQueue", qos);
    [capture setupFrameSource];
  }

  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:_display excludingWindows:@[]];
  capture.stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:capture];

  NSError *error = nil;
  if (![capture.stream addStreamOutput:capture type:SCStreamOutputTypeScreen sampleHandlerQueue:capture.sampleQueue error:&error]) {
    return nil;
  }
  [capture.stream startCaptureWithCompletionHandler:^(NSError *startError) {
    if (startError != nil) {
      [capture stopWithError:startError];
    }
  }];
  if (CMTIME_IS_VALID(self.keepaliveInterval)) {
    [capture startKeepaliveEvery:self.keepaliveInterval];
  }

  @synchronized(self) {
    [_captures addObject:capture];
  }
  return capture.signal;
}

- (void)stopCaptureForSignal:(dispatch_semaphore_t)signal {
  if (signal == nil) {
    return;
  }
  SCVideoCapture *matched = nil;
  @synchronized(self) {
    for (SCVideoCapture *capture in _captures) {
      if (capture.signal == signal) {
        matched = capture;
        break;
      }
    }
  }
  if (matched != nil) {
    [matched finish];
  }
}

- (void)stopAllCaptures {
  NSArray<SCVideoCapture *> *active = nil;
  @synchronized(self) {
    if (_captures.count > 0) {
      active = [_captures copy];
    }
  }
  for (SCVideoCapture *capture in active) {
    [capture finish];
  }
}

- (void)dealloc {
  [self stopAllCaptures];
}

@end
