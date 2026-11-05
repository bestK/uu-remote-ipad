#import "indicator_view.h"
#import <QuartzCore/QuartzCore.h>

// No public API exposes the notch. On iPhone X-class phones it spans about 53% of the width,
// leaving ~88 pt ears on a 375 pt screen: the clock sits at 26-65 pt and the right icons at
// 306-351 pt, so only ~20 pt stays free beside the clock.
static CGFloat NotchWidth(CGFloat width) { return width * 0.53; }

CGRect UUIndicatorAvailableFrame(CGSize viewSize, CGFloat barHeight, BOOL notched) {
    // The clock is centred in the left ear, so the badge starts just past its right edge.
    CGFloat earRight = notched ? (viewSize.width - NotchWidth(viewSize.width)) / 2 : viewSize.width - 12;
    CGFloat timeRight = notched ? earRight * 0.75 : 62;
    CGFloat leading = timeRight + 4;
    CGFloat height = MIN(22, MAX(barHeight - 2, 12));
    CGFloat width = MAX(0, earRight - 2 - leading);
    return CGRectMake(leading, (barHeight - height) / 2, width, height);
}

@implementation UUIndicatorViewController {
    BOOL _chinese;
    UUIndicatorState _state;
    UIView *_badge;
    UILabel *_label;
}

- (instancetype)initWithChinese:(BOOL)chinese {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _chinese = chinese;
        _state = UUIndicatorUnknown;
    }
    return self;
}

- (void)loadView {
    self.view = [[UIView alloc] init];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = NO;

    _badge = [[UIView alloc] init];
    _badge.layer.cornerRadius = 11;
    _badge.layer.masksToBounds = YES;
    _badge.userInteractionEnabled = NO;
    [self.view addSubview:_badge];

    _label = [[UILabel alloc] init];
    _label.textColor = UIColor.whiteColor;
    _label.textAlignment = NSTextAlignmentCenter;
    _label.numberOfLines = 1;
    _label.adjustsFontForContentSizeCategory = NO;
    _label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _label.adjustsFontSizeToFitWidth = YES;
    _label.minimumScaleFactor = 0.7;
    _label.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    [_badge addSubview:_label];
    [self showIndicatorState:_state];
}

// A hosted window has no scene, so statusBarFrame is unreliable; the screen ratio separates
// notch-class phones (44 pt row) from older phones (20 pt) and iPad (24 pt, 4:3).
static BOOL ScreenIsNotched(CGSize size) { return size.height / MAX(size.width, 1) > 1.9; }

- (CGFloat)statusBarHeightForWidth:(CGFloat)width height:(CGFloat)height {
    CGSize size = CGSizeMake(width, height);
    if (ScreenIsNotched(size)) return 44;
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone ? 20 : 24;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    if (size.width < 1) return;
    CGFloat bar = [self statusBarHeightForWidth:size.width height:size.height];
    BOOL notched = ScreenIsNotched(size);
    CGRect available = UUIndicatorAvailableFrame(size, bar, notched);
    // A notched phone leaves ~20 pt beside the clock: a word cannot fit there, so fall back to a dot.
    BOOL compact = available.size.width < 46;
    CGFloat height = compact ? 10 : available.size.height;
    CGFloat width = compact ? 10 : MIN(available.size.width,
        [_label sizeThatFits:CGSizeMake(available.size.width - 12, available.size.height)].width + 12);
    CGFloat x = compact ? available.origin.x + 2 : available.origin.x;
    CGFloat y = available.origin.y + (available.size.height - height) / 2;
    _badge.frame = CGRectMake(x, y, width, height);
    _badge.layer.cornerRadius = height / 2;
    _label.hidden = compact;
    _label.frame = _badge.bounds;
}

// A slow pulse marks a live session without pulling attention; it stops when idle, when the
// state is unknown, and under Reduce Motion.
- (void)updateBreathing {
    BOOL animate = _state == UUIndicatorActive && !UIAccessibilityIsReduceMotionEnabled();
    if (!animate) {
        [_badge.layer removeAnimationForKey:@"breathing"];
        _badge.layer.transform = CATransform3DIdentity;
        _badge.layer.opacity = 1;
        return;
    }
    if ([_badge.layer animationForKey:@"breathing"]) return;
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @1.0;
    scale.toValue = @1.18;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1.0;
    fade.toValue = @0.72;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[scale, fade];
    group.duration = 1.3;
    group.autoreverses = YES;
    group.repeatCount = HUGE_VALF;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_badge.layer addAnimation:group forKey:@"breathing"];
}

- (void)showIndicatorState:(UUIndicatorState)state {
    _state = state;
    if (!self.isViewLoaded) return;
    _badge.hidden = state == UUIndicatorIdle;
    if (state == UUIndicatorActive) {
        _label.text = _chinese ? @"远控中" : @"Remote";
        _badge.backgroundColor = [UIColor colorWithRed:0.93 green:0.20 blue:0.22 alpha:0.95];
    } else {
        _label.text = _chinese ? @"状态未知" : @"Unknown";
        _badge.backgroundColor = [UIColor colorWithRed:0.42 green:0.22 blue:0.06 alpha:0.92];
    }
    [self updateBreathing];
    _label.accessibilityLabel = state == UUIndicatorActive
        ? (_chinese ? @"UU 远控中" : @"UU remote active")
        : (_chinese ? @"UU 状态未知" : @"UU status unknown");
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}
@end
