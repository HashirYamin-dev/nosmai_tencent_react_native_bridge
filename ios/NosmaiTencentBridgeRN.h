#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <UIKit/UIKit.h>

@interface NosmaiTencentBridgeRN : RCTEventEmitter <RCTBridgeModule>
+ (instancetype)activeBridge;
- (void)attachVideoView:(UIView *)view;
- (void)detachVideoView:(UIView *)view;
- (void)attachNosmaiPreviewView:(UIView *)view;
- (void)detachNosmaiPreviewView:(UIView *)view;
@end
