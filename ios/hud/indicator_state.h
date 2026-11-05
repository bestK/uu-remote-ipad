#import <Foundation/Foundation.h>

// A missing or stale heartbeat is not evidence that remote control has ended.
typedef NS_ENUM(NSInteger, UUIndicatorState) {
    UUIndicatorUnknown,
    UUIndicatorIdle,
    UUIndicatorActive,
};

@interface UUIndicatorStatus : NSObject
// `direct` and `rootfs` are independent views of the host status. JSON is never logged.
- (UUIndicatorState)updateDirect:(NSData *)direct rootfs:(NSData *)rootfs now:(NSTimeInterval)now;
@end
