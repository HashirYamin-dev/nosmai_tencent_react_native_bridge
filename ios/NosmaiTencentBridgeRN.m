#import "NosmaiTencentBridgeRN.h"
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <stdatomic.h>
#import <nosmai/Nosmai.h>
// Tencent's TRTC and Professional distributions can expose different
// framework names. Compile only against the real installed public headers.
#if __has_include(<TXLiteAVSDK_TRTC/TRTCCloud.h>)
#import <TXLiteAVSDK_TRTC/TRTCCloud.h>
#import <TXLiteAVSDK_TRTC/TRTCCloudDef.h>
#import <TXLiteAVSDK_TRTC/TRTCCloudDelegate.h>
#import <TXLiteAVSDK_TRTC/TRTCStatistics.h>
#elif __has_include(<TXLiteAVSDK_Professional/TRTCCloud.h>)
#import <TXLiteAVSDK_Professional/TRTCCloud.h>
#import <TXLiteAVSDK_Professional/TRTCCloudDef.h>
#import <TXLiteAVSDK_Professional/TRTCCloudDelegate.h>
#import <TXLiteAVSDK_Professional/TRTCStatistics.h>
#else
#error Tencent TRTC public headers not found; check the resolved CocoaPod/framework.
#endif

// A single TRTCCloud role per Flutter engine: publisher OR audience. All TRTC
// session operations happen on main; frames are submitted on Nosmai's render
// callback thread without round-tripping pixels through Dart.

static __weak NosmaiTencentBridgeRN *ntbActiveBridge;

@interface NosmaiTencentBridgeRN () <TRTCCloudDelegate>
@property(atomic, strong) TRTCCloud *rtc;
@property(nonatomic, assign) BOOL hasEventListeners;
@property(nonatomic, assign) BOOL hostRequested;
@property(nonatomic, assign) BOOL viewerRequested;
@property(nonatomic, assign) BOOL roomConnected;
@property(nonatomic, assign) BOOL exitPending;
@property(nonatomic, assign) BOOL exitingViewerRole;
@property(nonatomic, assign) BOOL remoteVideoAvailable;
@property(nonatomic, copy) NSString *watchedHost;
@property(nonatomic, weak) UIView *remoteVideoView;
@property(nonatomic, assign) BOOL remoteSubscribed;
@property(nonatomic, assign) NSInteger uplinkFps;
@property(nonatomic, assign) NSInteger uplinkKbps;
@property(nonatomic, assign) NSInteger outputWidth;
@property(nonatomic, assign) NSInteger outputHeight;
@property(nonatomic, assign) NSInteger downlinkFps;
@property(nonatomic, assign) NSInteger downlinkKbps;
@property(nonatomic, assign) NSInteger downlinkWidth;
@property(nonatomic, assign) NSInteger downlinkHeight;
@property(nonatomic, weak) UIView *nosmaiPreviewView;
@property(nonatomic, assign) BOOL nosmaiInitialized;
@property(nonatomic, assign) BOOL nosmaiCapturing;
- (void)stopNosmaiCapture;
- (void)stopHost;
@end

@implementation NosmaiTencentBridgeRN {
  atomic_bool _acceptFrames;
  atomic_bool _frameTapArmed;
  atomic_bool _firstFrameReported;
  atomic_uint _lastSourcePixelFormat;
  atomic_uint _lastSourceWidth;
  atomic_uint _lastSourceHeight;
  atomic_ullong _sourceFrames;
  atomic_ullong _submittedFrames;
  atomic_bool _formatErrorEmitted;
  uint64_t _lastSourceFrames;
  uint64_t _lastSubmittedFrames;
  CFTimeInterval _lastSampleTime;
  NSUInteger _hostGeneration; // invalidates stale delayed recovery checks
}

RCT_EXPORT_MODULE(NosmaiTencentBridge)

+ (BOOL)requiresMainQueueSetup { return YES; }
+ (instancetype)activeBridge { return ntbActiveBridge; }
- (instancetype)init {
  if ((self = [super init])) {
    ntbActiveBridge = self;
    atomic_init(&_acceptFrames, false);
    atomic_init(&_frameTapArmed, false);
    atomic_init(&_firstFrameReported, false);
    atomic_init(&_lastSourcePixelFormat, 0);
    atomic_init(&_lastSourceWidth, 0);
    atomic_init(&_lastSourceHeight, 0);
    atomic_init(&_sourceFrames, 0);
    atomic_init(&_submittedFrames, 0);
    atomic_init(&_formatErrorEmitted, false);
  }
  return self;
}
- (NSArray<NSString *> *)supportedEvents { return @[@"NTBHostEvent", @"NTBViewerEvent"]; }
- (void)startObserving { self.hasEventListeners = YES; }
- (void)stopObserving { self.hasEventListeners = NO; }
- (void)emit:(NSString *)type message:(NSString *)message viewer:(BOOL)viewer extra:(NSDictionary *)extra {
  NSMutableDictionary *payload = [@{ @"type":type, @"message":message ?: @"" } mutableCopy];
  if (extra) [payload addEntriesFromDictionary:extra];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.hasEventListeners) {
      [self sendEventWithName:viewer ? @"NTBViewerEvent" : @"NTBHostEvent" body:payload];
    }
  });
}
- (TRTCCloud *)ensureCloud {
  if (!_rtc) _rtc = [TRTCCloud sharedInstance];
  _rtc.delegate = self;
  return _rtc;
}

// The React Native Fabric preview is not proof that processed frames are
// reaching NosmaiCore's live output. Arm a native tap before RN starts
// processing and measure callback frames independently from TRTC submission.
- (void)armProcessedFrameTap {
  atomic_store(&_frameTapArmed, true);
  atomic_store(&_firstFrameReported, false);
  _lastSampleTime = CACurrentMediaTime();
  _lastSourceFrames = atomic_load(&_sourceFrames);
  _lastSubmittedFrames = atomic_load(&_submittedFrames);
  __weak typeof(self) weakSelf = self;
  [NosmaiCore shared].liveFrameStreamCallback = ^(CVPixelBufferRef buffer, double timestamp) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) [strongSelf publishProcessedFrame:buffer timestamp:timestamp];
  };
  [self emit:@"frameTapArmed" message:@"Nosmai processed output tap installed" viewer:NO extra:nil];
}
- (void)disarmProcessedFrameTap {
  atomic_store(&_acceptFrames, false);
  atomic_store(&_frameTapArmed, false);
  [NosmaiCore shared].liveFrameStreamCallback = nil;
}
// Host-only camera ownership path for React Native iOS.  The official RN
// Fabric view can own an independent capture lifecycle; attaching the stream
// callback on a separate capture ownership path can produce zero buffers.
// We use one NosmaiCore camera for capture + preview + processed output.
- (void)attachNosmaiPreviewView:(UIView *)view {
  if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{[self attachNosmaiPreviewView:view];}); return; }
  self.nosmaiPreviewView = view;
}
- (void)detachNosmaiPreviewView:(UIView *)view {
  if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{[self detachNosmaiPreviewView:view];}); return; }
  if (self.nosmaiPreviewView != view) return;
  // The view can be removed by navigation, not just the Stop button.
  if (self.nosmaiCapturing) [self stopNosmaiCapture];
  self.nosmaiPreviewView = nil;
}
- (BOOL)startNosmaiCapture:(NSString **)failure {
  NSAssert([NSThread isMainThread], @"Nosmai camera setup must run on main");
  if (!self.nosmaiPreviewView || !self.nosmaiPreviewView.window ||
      self.nosmaiPreviewView.bounds.size.width <= 0) {
    *failure = @"Native Nosmai preview not mounted; wait for camera view layout";
    return NO;
  }
  NosmaiCore *core = [NosmaiCore shared];
  if (!core.camera) { *failure = @"NosmaiCore.camera is unavailable"; return NO; }
  [core.camera attachToView:self.nosmaiPreviewView];
  // Arm BEFORE capture starts. Never replace NosmaiSDK's lower-level
  // setCVPixelBufferCallback: slot, which NosmaiCore uses for fan-out.
  [self armProcessedFrameTap];
  BOOL captured = [core.camera startCapture];
  if (!captured) {
    [self disarmProcessedFrameTap];
    *failure = @"NosmaiCore camera.startCapture returned NO; inspect camera permission and ownership";
    return NO;
  }
  [[NosmaiSDK sharedInstance] startProcessing];
  self.nosmaiCapturing = YES;
  [self emit:@"nosmaiCaptureStarted" message:@"NosmaiCore camera capture started; waiting for processed frames" viewer:NO extra:nil];
  return YES;
}
- (void)stopNosmaiCapture {
  NSAssert([NSThread isMainThread], @"Nosmai camera cleanup must run on main");
  [self disarmProcessedFrameTap];
  if (self.nosmaiCapturing) {
    [[NosmaiSDK sharedInstance] stopProcessing];
    [[NosmaiCore shared].camera stopCapture];
    [[NosmaiCore shared].camera detachFromView];
  }
  self.nosmaiCapturing = NO;
}

// The RN Fabric preview can show a camera image before Nosmai's effects
// engine is actually draining frames. In the native iOS streaming samples,
// capture and SDK processing are two independent steps. RN's JS startProcessing
// request alone is not proof of processed output reaching NosmaiCore.
//
// Call this only after the Nosmai RN SDK initialized and its single Fabric
// preview has started. Do NOT start a second AVCaptureSession or write to the
// lower-level setCVPixelBufferCallback: slot (Core owns that fan-out).
- (BOOL)ensureNativeNosmaiProcessing:(NSString *)reason {
  NSAssert([NSThread isMainThread], @"Nosmai processing must be started on main");
  NosmaiSDK *sdk = [NosmaiSDK sharedInstance];
  if (!sdk) {
    [self emit:@"error" message:@"NosmaiSDK native singleton unavailable; camera initialization is incomplete"
          viewer:NO extra:nil];
    return NO;
  }
  [sdk startProcessing];
  [self emit:@"nativeProcessingRequested"
       message:[NSString stringWithFormat:@"Requested native Nosmai processing (%@)", reason]
       viewer:NO extra:nil];
  return YES;
}

// Only one recovery attempt per Host start. Never simulate video or silently
// send raw camera frames; require the real processed Nosmai callback to fire.
- (void)verifyProcessedVideoForGeneration:(NSUInteger)generation firstCheck:(BOOL)firstCheck {
  if (!_hostRequested || _hostGeneration != generation) return;
  if (atomic_load(&_sourceFrames) != 0) return;
  if (firstCheck) {
    [self emit:@"noProcessedFramesYet"
         message:@"No processed Nosmai frames after Host start; requesting native pipeline recovery"
         viewer:NO extra:nil];
    // Never re-arm/restart the camera behind the native view while live.
    // The owner is startNosmaiCapture. Surface an actionable error instead.
    [self emit:@"noProcessedFrames"
         message:@"NosmaiCore capture active but processed callback is zero; inspect native capture and SDK processing"
         viewer:NO extra:@{ @"sourceFramesTotal":@(atomic_load(&_sourceFrames)) }];
  } else {
    [self emit:@"noProcessedFrames"
         message:@"Nosmai output still 0: verify RN Fabric camera capture and NosmaiSDK processing; Tencent room/audio can connect without video"
         viewer:NO extra:@{ @"sourceFramesTotal":@(atomic_load(&_sourceFrames)) }];
  }
}

- (BOOL)checkCredentials:(NSDictionary *)args viewer:(BOOL)viewer error:(NSString **)error {
  NSNumber *appId = args[@"sdkAppId"];
  NSNumber *room = args[@"roomId"];
  NSString *user = args[@"userId"];
  NSString *sig = args[@"userSig"];
  NSString *host = args[@"hostUserId"];
  if (![appId isKindOfClass:[NSNumber class]] || appId.intValue <= 0 ||
      ![room isKindOfClass:[NSNumber class]] || room.intValue <= 0 ||
      ![user isKindOfClass:[NSString class]] || user.length == 0 ||
      ![sig isKindOfClass:[NSString class]] || sig.length == 0 ||
      (viewer && (![host isKindOfClass:[NSString class]] || host.length == 0 || [host isEqual:user]))) {
    *error = @"Valid SDKAppID, RoomID, distinct UserIDs, and this user's UserSig are required";
    return NO;
  }
  return YES;
}

- (TRTCParams *)params:(NSDictionary *)args viewer:(BOOL)viewer {
  TRTCParams *p = [[TRTCParams alloc] init];
  p.sdkAppId = [args[@"sdkAppId"] intValue];
  p.roomId = [args[@"roomId"] intValue];
  p.userId = args[@"userId"];
  p.userSig = args[@"userSig"];
  p.role = viewer ? TRTCRoleAudience : TRTCRoleAnchor;
  return p;
}

- (void)invoke:(NSString *)name args:(NSDictionary *)args resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self invoke:name args:args resolver:resolve rejecter:reject]; });
    return;
  }
  if ([name isEqualToString:@"initialize"]) {
    [self ensureCloud]; resolve(nil); return;
  }
  if ([name isEqualToString:@"armFrameTap"]) {
    if (_viewerRequested || _exitPending) {
      reject(@"ROLE_BUSY", @"Cannot arm Host output during Viewer/room exit", nil); return;
    }
    [self armProcessedFrameTap];
    resolve(@YES); return;
  }
  if ([name isEqualToString:@"getHostState"]) {
    resolve(@{ @"active":@(_hostRequested), @"connected":@(_hostRequested && _roomConnected) }); return;
  }
  if ([name isEqualToString:@"getHostFps"]) {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = MAX(now - _lastSampleTime, 0.001);
    uint64_t source = atomic_load(&_sourceFrames);
    uint64_t submitted = atomic_load(&_submittedFrames);
    NSInteger sourceFps = atomic_load(&_frameTapArmed)
      ? (NSInteger)llround((source >= _lastSourceFrames ? source - _lastSourceFrames : 0) / elapsed) : 0;
    NSInteger submittedFps = _hostRequested
      ? (NSInteger)llround((submitted >= _lastSubmittedFrames ? submitted - _lastSubmittedFrames : 0) / elapsed) : 0;
    _lastSourceFrames = source; _lastSubmittedFrames = submitted; _lastSampleTime = now;
    resolve(@{ @"active":@(_hostRequested),
              @"frameTapArmed":@(atomic_load(&_frameTapArmed)),
              @"sourceFramesTotal":@(source),
              @"sourceWidth":@(atomic_load(&_lastSourceWidth)),
              @"sourceHeight":@(atomic_load(&_lastSourceHeight)),
              @"sourcePixelFormat":@(atomic_load(&_lastSourcePixelFormat)),
              @"sourceFps":@(sourceFps),
              @"submittedFps":@(submittedFps), @"uplinkFps":@(_hostRequested ? _uplinkFps : 0),
              @"uplinkKbps":@(_hostRequested ? _uplinkKbps : 0),
              @"width":@(_outputWidth), @"height":@(_outputHeight) });
    return;
  }
  if ([name isEqualToString:@"start"]) {
    if (_hostRequested || _viewerRequested || _exitPending) {
      reject(@"ROLE_BUSY", @"Stop/leave current TRTC role first", nil); return;
    }
    NSString *error = nil;
    if (![self checkCredentials:args viewer:NO error:&error]) {
      reject(@"INVALID_ARGUMENT", error, nil); return;
    }
    // React Native iOS Host uses the same NosmaiCore-owned camera as Flutter.
    // Refuse empty video sessions rather than showing an apparently joined
    // TRTC room with a black Viewer.
    if (!self.nosmaiCapturing || atomic_load(&_sourceFrames) == 0) {
      reject(@"VIDEO_NOT_READY", @"No processed Nosmai frames. Wait for native firstSourceFrame before going live", nil);
      return;
    }
    TRTCCloud *rtc = [self ensureCloud];
    TRTCVideoEncParam *enc = [[TRTCVideoEncParam alloc] init];
    enc.videoResolution = TRTCVideoResolution_1280_720;
    enc.resMode = TRTCVideoResolutionModePortrait;
    enc.videoFps = 30;
    enc.videoBitrate = 1800;
    [rtc setVideoEncoderParam:enc];
    _roomConnected = NO; _hostRequested = YES;
    _uplinkFps = 0; _uplinkKbps = 0; _outputWidth = 0; _outputHeight = 0;
    _lastSampleTime = CACurrentMediaTime(); _lastSourceFrames = 0; _lastSubmittedFrames = 0;
    atomic_store(&_sourceFrames, 0); atomic_store(&_submittedFrames, 0);
    atomic_store(&_formatErrorEmitted, false);
    atomic_store(&_acceptFrames, true);
    NSUInteger generation = ++_hostGeneration;
    // Capture is already running in the bridge-owned NosmaiCore.  Do not
    // replace the callback or start a competing Fabric camera here.
    [rtc enableCustomVideoCapture:TRTCVideoStreamTypeBig enable:YES];
    if (![args[@"publishAudio"] isKindOfClass:[NSNumber class]] || [args[@"publishAudio"] boolValue]) {
      [rtc startLocalAudio:TRTCAudioQualityDefault];
    }
    [self emit:@"joining" message:@"Host room entry requested" viewer:NO extra:nil];
    [rtc enterRoom:[self params:args viewer:NO] appScene:TRTCAppSceneLIVE];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [self verifyProcessedVideoForGeneration:generation firstCheck:YES];
    });
    resolve(@YES); return;
  }
  if ([name isEqualToString:@"stop"]) {
    [self stopHost]; resolve(nil); return;
  }
  if ([name isEqualToString:@"viewerJoin"]) {
    if (_hostRequested || _viewerRequested || _exitPending) {
      reject(@"ROLE_BUSY", @"Stop/leave current TRTC role first", nil); return;
    }
    NSString *error = nil;
    if (![self checkCredentials:args viewer:YES error:&error]) {
      reject(@"INVALID_ARGUMENT", error, nil); return;
    }
    _viewerRequested = YES; _roomConnected = NO; _remoteVideoAvailable = NO;
    _remoteSubscribed = NO; _watchedHost = [args[@"hostUserId"] copy];
    TRTCCloud *rtc = [self ensureCloud];
    [self emit:@"joining" message:@"Joining room as audience" viewer:YES extra:nil];
    [rtc enterRoom:[self params:args viewer:YES] appScene:TRTCAppSceneLIVE];
    resolve(@YES); return;
  }
  if ([name isEqualToString:@"viewerLeave"]) {
    [self leaveViewer]; resolve(nil); return;
  }
  if ([name isEqualToString:@"dispose"]) {
    [self stopHost]; [self leaveViewer];
    [self stopNosmaiCapture];
    self.rtc.delegate = nil;
    self.rtc = nil;
    self.exitPending = NO;
    // Do not destroy the shared SDK synchronously while a render callback
    // may still be exiting; the process/SDK manages the singleton lifetime.
    resolve(nil); return;
  }
  reject(@"UNSUPPORTED_METHOD", @"Unknown bridge method", nil);
}


RCT_EXPORT_METHOD(initialize:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"initialize" args:@{} resolver:resolve rejecter:reject];
}
RCT_EXPORT_METHOD(armFrameTap:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"armFrameTap" args:@{} resolver:resolve rejecter:reject];
}
// Called only on iOS by the Host test app.  Do NOT initialize the Nosmai
// React Native Fabric camera on the same Host screen; this bridge owns capture.
RCT_EXPORT_METHOD(initializeNosmaiCamera:(NSString *)license resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![license isKindOfClass:[NSString class]] || license.length == 0) {
      reject(@"NOSMAI_LICENSE_REQUIRED", @"Missing iOS Nosmai license", nil); return;
    }
    if (self.nosmaiCapturing) { resolve(@YES); return; }
    AVAuthorizationStatus cameraAuth = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (cameraAuth == AVAuthorizationStatusNotDetermined) {
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (granted) [self initializeNosmaiCamera:license resolver:resolve rejecter:reject];
          else reject(@"NOSMAI_CAMERA_PERMISSION", @"Camera permission denied", nil);
        });
      }];
      return;
    }
    if (cameraAuth != AVAuthorizationStatusAuthorized) {
      reject(@"NOSMAI_CAMERA_PERMISSION", @"Enable Camera permission in iPhone Settings", nil); return;
    }
    if (self.nosmaiInitialized) {
      NSString *reason = nil;
      BOOL ok = [self startNosmaiCapture:&reason];
      if (ok) resolve(@YES); else reject(@"NOSMAI_CAPTURE_FAILED", reason, nil);
      return;
    }
    [[NosmaiCore shared] initializeWithAPIKey:license completion:^(BOOL success, NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!success) {
          reject(@"NOSMAI_INIT_FAILED", error.localizedDescription ?: @"NosmaiCore initialization failed", error);
          return;
        }
        self.nosmaiInitialized = YES;
        NSString *reason = nil;
        BOOL ok = [self startNosmaiCapture:&reason];
        if (ok) resolve(@YES); else reject(@"NOSMAI_CAPTURE_FAILED", reason, nil);
      });
    }];
  });
}
RCT_EXPORT_METHOD(stopNosmaiCamera:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.hostRequested) [self stopHost];
    [self stopNosmaiCapture];
    resolve(nil);
  });
}
RCT_EXPORT_METHOD(setNosmaiSmoothing:(nonnull NSNumber *)amount resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.nosmaiCapturing) { reject(@"NOSMAI_NOT_CAPTURING", @"NosmaiCore camera not started", nil); return; }
    [[NosmaiCore shared].effects applySkinSmoothing:MAX(0.0, MIN(1.0, amount.floatValue))];
    resolve(nil);
  });
}
RCT_EXPORT_METHOD(switchNosmaiCamera:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.nosmaiCapturing) { reject(@"NOSMAI_NOT_CAPTURING", @"NosmaiCore camera not started", nil); return; }
    BOOL ok = [[NosmaiCore shared].camera switchCamera];
    if (ok) resolve(@YES); else reject(@"NOSMAI_SWITCH_FAILED", @"NosmaiCore camera switch returned NO", nil);
  });
}
RCT_EXPORT_METHOD(getHostState:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"getHostState" args:@{} resolver:resolve rejecter:reject];
}
RCT_EXPORT_METHOD(getHostFps:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"getHostFps" args:@{} resolver:resolve rejecter:reject];
}
RCT_EXPORT_METHOD(start:(NSDictionary *)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"start" args:options resolver:resolve rejecter:reject];
}
RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"stop" args:@{} resolver:resolve rejecter:reject];
}
RCT_EXPORT_METHOD(viewerJoin:(NSDictionary *)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"viewerJoin" args:options resolver:resolve rejecter:reject];
}
RCT_EXPORT_METHOD(viewerLeave:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"viewerLeave" args:@{} resolver:resolve rejecter:reject];
}
RCT_EXPORT_METHOD(dispose:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self invoke:@"dispose" args:@{} resolver:resolve rejecter:reject];
}
- (void)publishProcessedFrame:(CVPixelBufferRef)buffer timestamp:(double)timestamp {
  if (!buffer || !atomic_load(&_frameTapArmed)) return;
  atomic_fetch_add(&_sourceFrames, 1);
  OSType format = CVPixelBufferGetPixelFormatType(buffer);
  uint32_t width = (uint32_t)CVPixelBufferGetWidth(buffer);
  uint32_t height = (uint32_t)CVPixelBufferGetHeight(buffer);
  atomic_store(&_lastSourcePixelFormat, (unsigned int)format);
  atomic_store(&_lastSourceWidth, width);
  atomic_store(&_lastSourceHeight, height);
  if (!atomic_exchange(&_firstFrameReported, true)) {
    [self emit:@"firstSourceFrame" message:@"First Nosmai processed frame reached native bridge"
        viewer:NO extra:@{@"width":@(width), @"height":@(height), @"pixelFormat":@(format)}];
  }
  if (!atomic_load(&_acceptFrames)) return;
  TRTCVideoPixelFormat trtcFormat;
  if (format == kCVPixelFormatType_32BGRA) {
    trtcFormat = TRTCVideoPixelFormat_32BGRA;
  } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
             format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    trtcFormat = TRTCVideoPixelFormat_NV12;
  } else {
    if (!atomic_exchange(&_formatErrorEmitted, true)) {
      [self emit:@"error" message:@"Unsupported Nosmai CVPixelBuffer pixel format for TRTC custom capture" viewer:NO extra:@{@"pixelFormat":@(format)}];
    }
    return;
  }
  // TRTC accepts BGRA or NV12 CVPixelBuffer. Frame ownership and smooth
  // submission rates must still be checked with a physical iOS device.
  TRTCVideoFrame *frame = [[TRTCVideoFrame alloc] init];
  frame.pixelFormat = trtcFormat;
  frame.bufferType = TRTCVideoBufferType_PixelBuffer;
  frame.pixelBuffer = buffer;
  frame.width = (uint32_t)CVPixelBufferGetWidth(buffer);
  frame.height = (uint32_t)CVPixelBufferGetHeight(buffer);
  // Nosmai's timestamp is seconds, but can have a clock origin unlike TRTC.
  // Let TRTC stamp receipt on its own monotonic clock for this first version.
  frame.timestamp = 0;
  TRTCCloud *rtc = self.rtc;
  if (!rtc || !atomic_load(&_acceptFrames)) return;
  [rtc sendCustomVideoData:TRTCVideoStreamTypeBig frame:frame];
  atomic_fetch_add(&_submittedFrames, 1);
}

- (void)stopHost {
  ++_hostGeneration;
  if (!_hostRequested) { [self disarmProcessedFrameTap]; return; }
  _hostRequested = NO; _roomConnected = NO;
  _exitPending = YES; _exitingViewerRole = NO;
  atomic_store(&_acceptFrames, false);
  // Do not replace NosmaiCore's internal SDK callback or stop its preview.
  [self disarmProcessedFrameTap];
  if (self.nosmaiCapturing) [self armProcessedFrameTap]; // keep detecting video for next Start
  [self emit:@"stopping" message:@"Host stop requested" viewer:NO extra:nil];
  [_rtc stopLocalAudio];
  [_rtc enableCustomVideoCapture:TRTCVideoStreamTypeBig enable:NO];
  [_rtc exitRoom];
  _uplinkFps = 0; _uplinkKbps = 0;
}

- (void)leaveViewer {
  if (!_viewerRequested) return;
  [self unsubscribeRemote];
  _viewerRequested = NO; _roomConnected = NO; _remoteVideoAvailable = NO;
  _exitPending = YES; _exitingViewerRole = YES;
  _watchedHost = nil;
  [_rtc exitRoom];
  [self emit:@"left" message:@"Viewer leave requested" viewer:YES extra:nil];
}

- (void)trySubscribeRemote {
  if (!_viewerRequested || !_roomConnected || !_remoteVideoView || !_watchedHost || !_remoteVideoAvailable || _remoteSubscribed) return;
  [_rtc startRemoteView:_watchedHost streamType:TRTCVideoStreamTypeBig view:_remoteVideoView];
  _remoteSubscribed = YES;
  [self emit:@"subscribing" message:@"Subscribing to host video" viewer:YES extra:nil];
}

- (void)unsubscribeRemote {
  if (_remoteSubscribed && _watchedHost) [_rtc stopRemoteView:_watchedHost streamType:TRTCVideoStreamTypeBig];
  _remoteSubscribed = NO;
}

- (void)attachVideoView:(UIView *)view {
  [self unsubscribeRemote];
  self.remoteVideoView = view;
  [self trySubscribeRemote];
}

- (void)detachVideoView:(UIView *)view {
  if (_remoteVideoView == view) {
    [self unsubscribeRemote];
    self.remoteVideoView = nil;
  }
}

#pragma mark - TRTCCloudDelegate
- (void)onEnterRoom:(NSInteger)result {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.hostRequested && !self.viewerRequested) return;
    BOOL viewer = self.viewerRequested;
    if (result > 0) {
      self.roomConnected = YES;
      [self emit:@"joined" message:@"TRTC room joined" viewer:viewer extra:@{@"elapsedMs":@(result)}];
      if (viewer) [self trySubscribeRemote];
    } else {
      self.roomConnected = NO;
      [self emit:viewer ? @"error" : @"joinFailed" message:[NSString stringWithFormat:@"TRTC join error %ld",(long)result] viewer:viewer extra:@{@"code":@(result)}];
      if (viewer) [self leaveViewer]; else [self stopHost];
      self.exitPending = NO; // failed room entry may not produce onExitRoom
    }
  });
}
- (void)onExitRoom:(NSInteger)reason {
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL viewer = self.exitPending ? self.exitingViewerRole : self.viewerRequested;
    self.exitPending = NO;
    [self emit:@"left" message:@"TRTC room exited" viewer:viewer extra:@{@"reason":@(reason)}];
  });
}
- (void)onError:(TXLiteAVError)errCode errMsg:(NSString *)errMsg extInfo:(NSDictionary *)extInfo {
  [self emit:@"error" message:[NSString stringWithFormat:@"TRTC %ld: %@",(long)errCode,errMsg ?: @""] viewer:_viewerRequested extra:@{@"code":@(errCode)}];
}
- (void)onConnectionLost { [self emit:@"connectionLost" message:@"TRTC connection lost" viewer:_viewerRequested extra:nil]; }
- (void)onConnectionRecovery { [self emit:@"connectionRecovered" message:@"TRTC connection recovered" viewer:_viewerRequested extra:nil]; }
- (void)onRemoteUserEnterRoom:(NSString *)userId {
  if (_viewerRequested) [self emit:@"remoteUser" message:@"Remote user entered" viewer:YES extra:@{@"userId":userId ?: @""}];
}
- (void)onRemoteUserLeaveRoom:(NSString *)userId reason:(NSInteger)reason {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.viewerRequested || ![userId isEqualToString:self.watchedHost]) return;
    [self unsubscribeRemote]; self.remoteVideoAvailable = NO;
    [self emit:@"hostLeft" message:@"Host left room" viewer:YES extra:nil];
  });
}
- (void)onUserVideoAvailable:(NSString *)userId available:(BOOL)available {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.viewerRequested || ![userId isEqualToString:self.watchedHost]) return;
    self.remoteVideoAvailable = available;
    [self emit:available ? @"videoAvailable" : @"videoUnavailable" message:available ? @"Host video available" : @"Host video unavailable" viewer:YES extra:nil];
    if (available) [self trySubscribeRemote]; else [self unsubscribeRemote];
  });
}
- (void)onUserAudioAvailable:(NSString *)userId available:(BOOL)available {
  if (_viewerRequested && [userId isEqualToString:_watchedHost]) {
    [self emit:@"audioAvailable" message:available ? @"Host audio available" : @"Host audio unavailable" viewer:YES extra:nil];
  }
}
- (void)onFirstVideoFrame:(NSString *)userId streamType:(TRTCVideoStreamType)streamType width:(int)width height:(int)height {
  if (_viewerRequested && [userId isEqualToString:_watchedHost]) {
    [self emit:@"firstVideoFrame" message:[NSString stringWithFormat:@"First remote frame %dx%d",width,height] viewer:YES extra:@{@"width":@(width),@"height":@(height)}];
  }
}
- (void)onFirstAudioFrame:(NSString *)userId {
  if (_viewerRequested && [userId isEqualToString:_watchedHost]) [self emit:@"firstAudioFrame" message:@"First remote audio frame" viewer:YES extra:nil];
}
- (void)onStatistics:(TRTCStatistics *)statistics {
  // iOS statistics property names are localStatistics / remoteStatistics.
  if (_hostRequested) {
    TRTCLocalStatistics *item = statistics.localStatistics.firstObject;
    if (!item) return;
    _uplinkFps = item.frameRate; _uplinkKbps = item.videoBitrate;
    _outputWidth = item.width; _outputHeight = item.height;
  } else if (_viewerRequested) {
    for (TRTCRemoteStatistics *item in statistics.remoteStatistics) {
      if (![item.userId isEqualToString:_watchedHost]) continue;
      _downlinkFps = item.frameRate; _downlinkKbps = item.videoBitrate;
      _downlinkWidth = item.width; _downlinkHeight = item.height;
      [self emit:@"fpsStats" message:@"TRTC remote receive statistics" viewer:YES
           extra:@{@"fps":@(_downlinkFps),@"kbps":@(_downlinkKbps),@"width":@(_downlinkWidth),@"height":@(_downlinkHeight)}];
      break;
    }
  }
}


- (void)invalidate {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self stopHost]; [self leaveViewer];
    [self stopNosmaiCapture];
    self.rtc.delegate = nil;
    self.rtc = nil;
    if (ntbActiveBridge == self) ntbActiveBridge = nil;
  });
  [super invalidate];
}
@end
