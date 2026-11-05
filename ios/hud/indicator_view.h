#import <UIKit/UIKit.h>
#import "indicator_state.h"

// Where the badge may sit: same row as the status bar, right of the clock, clear of the notch.
CGRect UUIndicatorAvailableFrame(CGSize viewSize, CGFloat barHeight, BOOL notched);

@interface UUIndicatorViewController : UIViewController
- (instancetype)initWithChinese:(BOOL)chinese;
- (void)showIndicatorState:(UUIndicatorState)state;
@end
