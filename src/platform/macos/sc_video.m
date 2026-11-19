/**
 * @file src/platform/macos/sc_video.m
 * @brief Definitions for ScreenCaptureKit video capture on macOS.
 */
// platform includes
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// local includes
#import "sc_video.h"

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
  @synchronized(self) {
    if (_finished) {
      return;
    }
    if (_latestFrame != NULL) {
      CFRelease(_latestFrame);
    }
    _latestFrame = (CMSampleBufferRef) CFRetain(sampleBuffer);
    if (_keepaliveFrame != NULL) {
      CFRelease(_keepaliveFrame);
    }
    _keepaliveFrame = (CMSampleBufferRef) CFRetain(sampleBuffer);
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
  // Slightly below 1/fps so WindowServer's 120Hz delivery clock doesn't beat and drop frames.
  const int fps = MAX(frameRate, 1);
  self.minFrameDuration = CMTimeMake(9, fps * 10);
  CGDisplayModeRelease(mode);

  dispatch_semaphore_t found = dispatch_semaphore_create(0);
  __block SCDisplay *display = nil;
  [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
    for (SCDisplay *candidate in content.displays) {
      if (candidate.displayID == displayID) {
        display = candidate;
      }
    }
    dispatch_semaphore_signal(found);
  }];
  if (dispatch_semaphore_wait(found, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0 || display == nil) {
    return nil;
  }

  _display = display;
  _captures = [NSMutableArray array];
  return self;
}

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
  SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
  configuration.width = self.frameWidth;
  configuration.height = self.frameHeight;
  configuration.pixelFormat = self.pixelFormat;
  configuration.captureResolution = SCCaptureResolutionBest;
  configuration.preservesAspectRatio = YES;
  if (self.hdr && self.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
    if ([configuration respondsToSelector:NSSelectorFromString(@"setCaptureDynamicRange:")]) {
      [configuration setValue:@1 forKey:@"captureDynamicRange"];
    }
    configuration.colorSpaceName = kCGColorSpaceITUR_2100_PQ;
    configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
  }
  configuration.minimumFrameInterval = self.minFrameDuration;
  configuration.showsCursor = YES;
  configuration.queueDepth = 8;

  SCVideoCapture *capture = [[SCVideoCapture alloc] init];
  capture.owner = self;
  capture.callback = frameCallback;
  capture.signal = dispatch_semaphore_create(0);
  dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  capture.sampleQueue = dispatch_queue_create("videoSampleQueue", qos);
  capture.queue = dispatch_queue_create("videoDeliveryQueue", qos);
  [capture setupFrameSource];

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

- (void)dealloc {
  for (SCVideoCapture *capture in _captures) {
    [capture finish];
  }
}

@end
