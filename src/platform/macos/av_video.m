/**
 * @file src/platform/macos/av_video.m
 * @brief Definitions for video capture on macOS.
 */
// local includes
#import "av_video.h"

@implementation AVVideo

// XXX: Currently, this function only returns the screen IDs as names,
// which is not very helpful to the user. The API to retrieve names
// was deprecated with 10.9+.
// However, there is a solution with little external code that can be used:
// https://stackoverflow.com/questions/20025868/cgdisplayioserviceport-is-deprecated-in-os-x-10-9-how-to-replace
+ (NSArray<NSDictionary *> *)displayNames {
  CGDirectDisplayID displays[kMaxDisplays];
  uint32_t count;
  if (CGGetActiveDisplayList(kMaxDisplays, displays, &count) != kCGErrorSuccess) {
    return [NSArray array];
  }

  NSMutableArray *result = [NSMutableArray array];

  for (uint32_t i = 0; i < count; i++) {
    NSString *displayName = [self getDisplayName:displays[i]] ?: [NSString stringWithFormat:@"Display %u", displays[i]];
    [result addObject:@{
      @"id": [NSNumber numberWithUnsignedInt:displays[i]],
      @"name": [NSString stringWithFormat:@"%u", displays[i]],
      @"displayName": displayName,
    }];
  }

  return [NSArray arrayWithArray:result];
}

+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID {
  for (NSScreen *screen in [NSScreen screens]) {
    if ([screen.deviceDescription[@"NSScreenNumber"] isEqualToNumber:[NSNumber numberWithUnsignedInt:displayID]]) {
      return screen.localizedName;
    }
  }
  return nil;
}

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];
  if (!self) {
    return nil;
  }

  // No mode means no such display, as on a Mac without a screen of its own.
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (mode == NULL) {
    return nil;
  }

  self.displayID = displayID;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
  self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
  self.minFrameDuration = CMTimeMake(1, MAX(frameRate, 1));
  self.session = [[AVCaptureSession alloc] init];
  self.videoOutputs = [NSMapTable strongToStrongObjectsMapTable];
  self.captureCallbacks = [NSMapTable strongToStrongObjectsMapTable];
  self.captureSignals = [NSMapTable strongToStrongObjectsMapTable];

  CFRelease(mode);

  AVCaptureScreenInput *screenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:self.displayID];
  [screenInput setMinFrameDuration:self.minFrameDuration];

  if ([self.session canAddInput:screenInput]) {
    [self.session addInput:screenInput];
  } else {
    return nil;
  }

  return self;
}

- (void)stopCaptureForSignal:(dispatch_semaphore_t)signal {
  if (signal == nil) {
    return;
  }
  @synchronized(self) {
    AVCaptureConnection *matchedConnection = nil;
    for (AVCaptureConnection *conn in self.captureSignals.keyEnumerator) {
      if ([self.captureSignals objectForKey:conn] == signal) {
        matchedConnection = conn;
        break;
      }
    }
    if (matchedConnection == nil) {
      return;
    }
    [self.session stopRunning];
    [self.captureCallbacks removeObjectForKey:matchedConnection];
    AVCaptureVideoDataOutput *output = [self.videoOutputs objectForKey:matchedConnection];
    if (output != nil) {
      [output setSampleBufferDelegate:nil queue:nil];
      [self.session removeOutput:output];
      [self.videoOutputs removeObjectForKey:matchedConnection];
    }
    [self.captureSignals removeObjectForKey:matchedConnection];
    dispatch_semaphore_signal(signal);
    if (self.videoOutputs.count > 0) {
      [self.session startRunning];
    }
  }
}

- (void)stopAllCaptures {
  @synchronized(self) {
    [self.session stopRunning];
    for (AVCaptureVideoDataOutput *output in self.videoOutputs.objectEnumerator) {
      [output setSampleBufferDelegate:nil queue:nil];
      [self.session removeOutput:output];
    }
    for (dispatch_semaphore_t signal in self.captureSignals.objectEnumerator) {
      dispatch_semaphore_signal(signal);
    }
    [self.videoOutputs removeAllObjects];
    [self.captureCallbacks removeAllObjects];
    [self.captureSignals removeAllObjects];
  }
}

- (void)dealloc {
  // Stop the frames before releasing the tables they're looked up in. A capture that timed out
  // can still have an output attached.
  [self.session stopRunning];
  for (AVCaptureVideoDataOutput *output in self.videoOutputs.objectEnumerator) {
    [output setSampleBufferDelegate:nil queue:nil];
  }
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  self.frameWidth = frameWidth;
  self.frameHeight = frameHeight;
}

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
  @synchronized(self) {
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];

    [videoOutput setVideoSettings:@{
      (NSString *) kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:self.pixelFormat],
      (NSString *) kCVPixelBufferWidthKey: [NSNumber numberWithInt:self.frameWidth],
      (NSString *) kCVPixelBufferHeightKey: [NSNumber numberWithInt:self.frameHeight],
      (NSString *) AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    }];

    dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    dispatch_queue_t recordingQueue = dispatch_queue_create("videoCaptureQueue", qos);
    [videoOutput setSampleBufferDelegate:self queue:recordingQueue];

    [self.session stopRunning];

    if ([self.session canAddOutput:videoOutput]) {
      [self.session addOutput:videoOutput];
    } else {
      [videoOutput setSampleBufferDelegate:nil queue:nil];
      if (self.videoOutputs.count > 0) {
        [self.session startRunning];
      }
      return nil;
    }

    AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (videoConnection == nil) {
      [videoOutput setSampleBufferDelegate:nil queue:nil];
      [self.session removeOutput:videoOutput];
      if (self.videoOutputs.count > 0) {
        [self.session startRunning];
      }
      return nil;
    }
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);

    [self.videoOutputs setObject:videoOutput forKey:videoConnection];
    [self.captureCallbacks setObject:[frameCallback copy] forKey:videoConnection];
    [self.captureSignals setObject:signal forKey:videoConnection];

    [self.session startRunning];

    return signal;
  }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  FrameCallbackBlock callback = nil;
  @synchronized(self) {
    callback = [self.captureCallbacks objectForKey:connection];
  }

  if (callback != nil) {
    if (!callback(sampleBuffer)) {
      dispatch_semaphore_t signalToStop = nil;
      @synchronized(self) {
        [self.captureCallbacks removeObjectForKey:connection];
        signalToStop = [self.captureSignals objectForKey:connection];
      }
      // Perform stopRunning off the sample callback queue to avoid AB-BA deadlock with stopCaptureForSignal:.
      if (signalToStop != nil) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          [self stopCaptureForSignal:signalToStop];
        });
      }
    }
  }
}

@end
