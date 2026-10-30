#import "NosmaiTencentBridgeRN.h"
#import <React/RCTViewManager.h>

@interface NTBManagedRemoteView : UIView
@end
@implementation NTBManagedRemoteView
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = UIColor.blackColor;
    [[NosmaiTencentBridgeRN activeBridge] attachVideoView:self];
  }
  return self;
}
- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (self.window) [[NosmaiTencentBridgeRN activeBridge] attachVideoView:self];
  else [[NosmaiTencentBridgeRN activeBridge] detachVideoView:self];
}
- (void)dealloc { [[NosmaiTencentBridgeRN activeBridge] detachVideoView:self]; }
@end

@interface NTBRemoteVideoViewManager : RCTViewManager
@end
@implementation NTBRemoteVideoViewManager
RCT_EXPORT_MODULE(NTBRemoteVideoView)
+ (BOOL)requiresMainQueueSetup { return YES; }
- (UIView *)view {
  NTBManagedRemoteView *view = [[NTBManagedRemoteView alloc] initWithFrame:CGRectZero];
  // Force RN module creation even when the video view is mounted before Join.
  NosmaiTencentBridgeRN *module = [self.bridge moduleForClass:[NosmaiTencentBridgeRN class]];
  [module attachVideoView:view];
  return view;
}
@end
