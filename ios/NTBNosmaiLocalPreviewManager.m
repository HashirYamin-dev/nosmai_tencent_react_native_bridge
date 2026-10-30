#import <React/RCTViewManager.h>
#import "NosmaiTencentBridgeRN.h"

// The iOS streaming Host is owned by NosmaiCore, just like the verified
// Flutter iOS bridge.  Do not also mount NosmaiCameraView on this screen:
// it would create a second independent Fabric camera owner.
@interface NTBNosmaiLocalView : UIView
@property(nonatomic, weak) NosmaiTencentBridgeRN *bridgeModule;
@end
@implementation NTBNosmaiLocalView
- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (self.window) [self.bridgeModule attachNosmaiPreviewView:self];
  else [self.bridgeModule detachNosmaiPreviewView:self];
}
- (void)layoutSubviews {
  [super layoutSubviews];
  if (self.window && self.bounds.size.width > 0 && self.bounds.size.height > 0)
    [self.bridgeModule attachNosmaiPreviewView:self];
}
@end

@interface NTBNosmaiLocalPreviewManager : RCTViewManager
@end
@implementation NTBNosmaiLocalPreviewManager
RCT_EXPORT_MODULE(NTBNosmaiLocalPreview)
+ (BOOL)requiresMainQueueSetup { return YES; }
- (UIView *)view {
  NTBNosmaiLocalView *v = [[NTBNosmaiLocalView alloc] initWithFrame:CGRectZero];
  v.backgroundColor = UIColor.blackColor;
  v.bridgeModule = [self.bridge moduleForClass:[NosmaiTencentBridgeRN class]];
  return v;
}
@end
