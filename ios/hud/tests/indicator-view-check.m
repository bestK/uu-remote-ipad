#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "indicator_view.h"

static NSUInteger checks;
static void Check(BOOL ok, const char *message) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

@interface IndicatorCheckDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation IndicatorCheckDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)app; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *base = [[UIViewController alloc] init];
    self.window.rootViewController = base;
    [self.window makeKeyAndVisible];

    // iPhone X-class: the badge must sit in the status-bar row, right of the clock, left of the notch.
    CGRect phone = UUIndicatorAvailableFrame(CGSizeMake(375, 812), 44, YES);
    CGFloat phoneEar = (375 - 375 * 0.53) / 2;
    Check(phone.origin.x > 66, "phone badge starts after the clock");
    Check(CGRectGetMaxX(phone) <= phoneEar, "phone badge stays out of the notch");
    Check(phone.size.width > 8 && phone.size.width < 46, "phone keeps only a dot of room beside the clock");
    Check(CGRectGetMinY(phone) >= 0 && CGRectGetMaxY(phone) <= 44, "phone badge sits inside the status bar row");
    Check(CGRectGetHeight(phone) <= 22, "phone badge keeps the status bar row height");
    CGRect wide = UUIndicatorAvailableFrame(CGSizeMake(414, 896), 44, YES);
    Check(CGRectGetMaxX(wide) <= (414 - 414 * 0.53) / 2, "wider notched phones also clear the notch");

    // iPad and older phones have no notch: the row is full width.
    CGRect tablet = UUIndicatorAvailableFrame(CGSizeMake(768, 1024), 24, NO);
    Check(CGRectGetMaxX(tablet) <= 768 - 12, "tablet badge stays inside the screen");
    Check(CGRectGetMinY(tablet) >= 0 && CGRectGetMaxY(tablet) <= 24, "tablet badge sits inside the status bar row");

    for (int chinese = 0; chinese < 2; chinese++) {
        for (int tabletDevice = 0; tabletDevice < 2; tabletDevice++) {
            CGSize size = tabletDevice ? CGSizeMake(768, 1024) : CGSizeMake(375, 812);
            for (int active = 0; active < 2; active++) {
                UUIndicatorViewController *indicator = [[UUIndicatorViewController alloc] initWithChinese:chinese];
                [base addChildViewController:indicator];
                indicator.view.frame = (CGRect){CGPointZero, size};
                [base.view addSubview:indicator.view];
                [indicator didMoveToParentViewController:base];
                [indicator showIndicatorState:active ? UUIndicatorActive : UUIndicatorUnknown];
                [indicator.view layoutIfNeeded];
                UIView *badge = indicator.view.subviews.firstObject;
                UILabel *label = (UILabel *)badge.subviews.firstObject;
                Check(!indicator.view.userInteractionEnabled, "indicator does not accept interaction");
                Check([indicator.view hitTest:CGPointMake(10, 10) withEvent:nil] == nil, "indicator hit test passes through");
                Check(!badge.hidden && label.text.length > 0, "active or unknown message is visible");
                Check(CGRectGetMinX(badge.frame) >= 0 && CGRectGetMaxX(badge.frame) <= size.width,
                    "badge remains inside viewport");
                Check(CGRectGetMinY(badge.frame) >= 0 && CGRectGetMaxY(badge.frame) <= 44,
                    "badge stays in the status bar row");
                if (!tabletDevice) {
                    Check(fabs(CGRectGetWidth(badge.frame) - 10) < 0.5 && label.hidden,
                        "notched phone falls back to a dot");
                } else {
                    Check(!label.hidden && label.font.pointSize >= 8.4, "tablet keeps the word");
                }
                NSString *expected = active ? (chinese ? @"远控中" : @"Remote")
                    : (chinese ? @"状态未知" : @"Unknown");
                Check([label.text isEqualToString:expected], "state text is short and bilingual");
                UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
                format.scale = 1;
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
                UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [[UIColor colorWithWhite:active ? 0.95 : 0.18 alpha:1] setFill];
                    UIRectFill((CGRect){CGPointZero, size});
                    // Stand-in for the status bar row so the badge position is readable.
                    [[UIColor colorWithWhite:0.0 alpha:0.12] setFill];
                    UIRectFill((CGRect){CGPointZero, CGSizeMake(size.width, 44)});
                    [indicator.view.layer renderInContext:context.CGContext];
                }];
                NSString *name = [NSString stringWithFormat:@"indicator-%@-%@-%@.png", tabletDevice ? @"tablet" : @"phone",
                    chinese ? @"zh" : @"en", active ? @"active" : @"unknown"];
                NSString *path = [@UU_INDICATOR_REVIEW_DIR stringByAppendingPathComponent:name];
                Check([UIImagePNGRepresentation(image) writeToFile:path atomically:YES], "synthetic snapshot written");
                [indicator showIndicatorState:UUIndicatorIdle];
                Check(badge.hidden, "idle state hides badge");
                [indicator willMoveToParentViewController:nil];
                [indicator.view removeFromSuperview];
                [indicator removeFromParentViewController];
            }
        }
    }
    printf("indicator view: %lu checks passed (UIKit/Mac Catalyst synthetic, not iOS hardware)\n", (unsigned long)checks);
    exit(0);
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(IndicatorCheckDelegate.class)); }
}
