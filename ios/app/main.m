// Home-screen panel for the iPad UU host: shows the login QR the daemon writes and keeps the
// lock-screen passcode the host uses to unlock the iPad when a viewer connects.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static NSString *const kStatusPath = @"/private/var/tmp/uu-status.txt";
static NSString *const kQRPath = @"/private/var/tmp/uu-qr.png";
static NSString *const kStatusJSONPath = @"/private/var/tmp/uu-status.json";
static NSString *const kHistoryPath = @"/private/var/tmp/uu-history.jsonl";
// Read by the host (root) only to unlock; never leaves the device.
static NSString *const kPasscodeDir = @"/var/mobile/Library/UURemote";
static NSString *const kPasscodePath = @"/var/mobile/Library/UURemote/unlock.key";
static NSString *const kSettingsPath = @"/var/mobile/Library/UURemote/settings.json";
static NSString *const kUnlockStatusPath = @"/private/var/tmp/uu-unlock.txt";
// The host (root) polls this every 2 s and executes the command it finds.
static NSString *const kCommandPath = @"/var/mobile/Library/UURemote/command";
static const NSTimeInterval kServiceTimeout = 60;

static const NSTimeInterval kStaleAfter = 10; // the host rewrites uu-status.json every 3 s

static NSString *T(NSString *zh, NSString *en) {
    static BOOL chinese;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ chinese = [[NSLocale preferredLanguages].firstObject hasPrefix:@"zh"]; });
    return chinese ? zh : en;
}

// Bold variant that still follows Dynamic Type.
static UIFont *FontForTraitsWeight(UIFontTextStyle style, UIFontWeight weight, UITraitCollection *traits) {
    UITraitCollection *base = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
    UIFontDescriptor *d = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style compatibleWithTraitCollection:base];
    UIFont *font = [UIFont systemFontOfSize:d.pointSize weight:weight];
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:font compatibleWithTraitCollection:traits];
}

static UIFont *FontForTraits(UIFontTextStyle style, BOOL bold, UITraitCollection *traits) {
    return FontForTraitsWeight(style, bold ? UIFontWeightBold : UIFontWeightRegular, traits);
}

static UIFont *Font(UIFontTextStyle style, BOOL bold) { return FontForTraits(style, bold, nil); }

// 显式跟随所属窗口的字号，兼顾分屏、环境覆盖和辅助功能超大字号。
@interface PanelLabel : UILabel
@property(nonatomic) UIFontTextStyle panelStyle;
@property(nonatomic) UIFontWeight panelWeight;
@property(nonatomic) BOOL panelMonospaced;
@end
@implementation PanelLabel
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (self.panelStyle) {
        if (self.panelMonospaced) {
            UITraitCollection *base = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
            UIFontDescriptor *d = [UIFontDescriptor preferredFontDescriptorWithTextStyle:self.panelStyle compatibleWithTraitCollection:base];
            UIFont *mono = [UIFont monospacedSystemFontOfSize:d.pointSize weight:self.panelWeight];
            self.font = [[UIFontMetrics metricsForTextStyle:self.panelStyle] scaledFontForFont:mono compatibleWithTraitCollection:self.traitCollection];
        } else {
            self.font = FontForTraitsWeight(self.panelStyle, self.panelWeight, self.traitCollection);
        }
    }
}
@end

static UILabel *LabelWeight(UIFontTextStyle style, UIFontWeight weight, UIColor *color) {
    PanelLabel *l = [[PanelLabel alloc] init];
    l.panelStyle = style;
    l.panelWeight = weight;
    l.font = FontForTraitsWeight(style, weight, nil);
    l.adjustsFontForContentSizeCategory = YES;
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

static UILabel *Label(UIFontTextStyle style, BOOL bold, UIColor *color) {
    return LabelWeight(style, bold ? UIFontWeightBold : UIFontWeightRegular, color);
}

static UILabel *MonoLabel(UIFontTextStyle style, UIColor *color) {
    PanelLabel *l = [[PanelLabel alloc] init];
    l.panelStyle = style;
    l.panelWeight = UIFontWeightMedium;
    l.panelMonospaced = YES;
    UITraitCollection *base = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
    UIFontDescriptor *d = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style compatibleWithTraitCollection:base];
    UIFont *mono = [UIFont monospacedSystemFontOfSize:d.pointSize weight:UIFontWeightMedium];
    l.font = [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:mono];
    l.adjustsFontForContentSizeCategory = YES;
    l.textColor = color;
    l.numberOfLines = 1;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

// Capsule text field with comfortable horizontal padding and no legacy border.
@interface PaddedTextField : UITextField
@end
@implementation PaddedTextField
- (CGRect)textRectForBounds:(CGRect)bounds {
    return CGRectMake(bounds.origin.x + 18, bounds.origin.y, MAX(0, bounds.size.width - 36), bounds.size.height);
}
- (CGRect)editingRectForBounds:(CGRect)bounds { return [self textRectForBounds:bounds]; }
- (CGRect)placeholderRectForBounds:(CGRect)bounds { return [self textRectForBounds:bounds]; }
@end

// Geometric 8-spoke asterisk ornament for the status hero card (prominent in dark mode, whisper-subtle in light).
@interface HeroAsteriskView : UIView
@property(nonatomic) CAShapeLayer *spokeLayer;
@end
@implementation HeroAsteriskView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.spokeLayer = [CAShapeLayer layer];
        self.spokeLayer.fillColor = nil;
        self.spokeLayer.lineWidth = 11;
        [self.layer addSublayer:self.spokeLayer];
        [self updateAppearance];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.spokeLayer.frame = self.bounds;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat cx = w * 0.5, cy = h * 0.5, r = MIN(w, h) * 0.46;
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (int i = 0; i < 4; i++) {
        double angle = (double)i * (M_PI / 4.0);
        CGFloat dx = (CGFloat)cos(angle) * r, dy = (CGFloat)sin(angle) * r;
        [path moveToPoint:CGPointMake(cx - dx, cy - dy)];
        [path addLineToPoint:CGPointMake(cx + dx, cy + dy)];
    }
    self.spokeLayer.path = path.CGPath;
}
- (void)updateAppearance {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    self.hidden = !dark;
    self.spokeLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateAppearance];
}
@end

// Avoids flicker from the 1 s refresh.
static void SetText(UILabel *l, NSString *s) { if (![l.text isEqualToString:s]) l.text = s; }
static void SetColor(UILabel *l, UIColor *c) { if (![l.textColor isEqual:c]) l.textColor = c; }
static void SetHidden(UIView *v, BOOL hidden) { if (v.hidden != hidden) v.hidden = hidden; }

static NSString *Trimmed(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSDictionary *ReadJSONDict(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static double Number(id v) { return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }

// "今天 15:02" / "Yesterday 15:02" / "3月2日 15:02".
static NSString *WhenText(NSDate *date) {
    static NSDateFormatter *time, *day;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        time = [[NSDateFormatter alloc] init];
        time.dateFormat = @"HH:mm";
        day = [[NSDateFormatter alloc] init];
        day.locale = [NSLocale localeWithLocaleIdentifier:T(@"zh_CN", @"en_US")];
        day.dateFormat = T(@"M月d日", @"MMM d");
    });
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSString *d = [cal isDateInToday:date] ? T(@"今天", @"Today")
        : [cal isDateInYesterday:date] ? T(@"昨天", @"Yesterday") : [day stringFromDate:date];
    return [NSString stringWithFormat:@"%@ %@", d, [time stringFromDate:date]];
}

static NSString *DurationText(double seconds) {
    if (seconds < 60) return T(@"不到 1 分钟", @"Under 1 min");
    long minutes = (long)(seconds / 60);
    if (minutes <= 60) return [NSString stringWithFormat:T(@"%ld 分钟", @"%ld min"), minutes];
    long h = minutes / 60, m = minutes % 60;
    if (m == 0) return [NSString stringWithFormat:T(@"%ld 小时", @"%ld h"), h];
    return [NSString stringWithFormat:T(@"%ld 小时 %ld 分钟", @"%ld h %ld min"), h, m];
}

// Valid history entries, oldest first.
static NSArray<NSDictionary *> *ReadHistory(void) {
    NSString *text = [NSString stringWithContentsOfFile:kHistoryPath encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSData *data = [Trimmed(line) dataUsingEncoding:NSUTF8StringEncoding];
        id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([obj isKindOfClass:[NSDictionary class]] && Number(obj[@"at"]) > 0) [out addObject:obj];
    }
    return out;
}

static BOOL EnsureDir(void) {
    return [[NSFileManager defaultManager] createDirectoryAtPath:kPasscodeDir withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
}

// Create 0600 before writing, so the contents are never readable by others even briefly.
static BOOL WritePrivate(NSString *path, NSData *data) {
    if (!EnsureDir()) return NO;
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    BOOL ok = fd >= 0 && fchmod(fd, 0600) == 0 && write(fd, data.bytes, data.length) == (ssize_t)data.length;
    if (fd >= 0) close(fd);
    return ok;
}

static NSString *ShellQuote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

// Runs a bundled service script through sudo; the password goes through stdin, never argv or a file.
// Returns the last lines of output (password lines removed).
static NSString *RunServiceScript(NSString *scriptName, NSString *password, BOOL *success, BOOL *timedOut) {
    *success = NO;
    *timedOut = NO;
    NSString *script = [[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"service"]
        stringByAppendingPathComponent:scriptName];
    // The password goes through stdin, never argv: another process could read it from `ps`.
    NSString *command = [NSString stringWithFormat:@"exec sudo -S sh %@ 2>&1", ShellQuote(script)];
    NSString *shell = [[NSFileManager defaultManager] isExecutableFileAtPath:@"/var/jb/bin/sh"] ? @"/var/jb/bin/sh" : @"/bin/sh";

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"] = @"/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin";
    NSMutableArray<NSString *> *envStrings = [NSMutableArray array];
    for (NSString *k in env) [envStrings addObject:[NSString stringWithFormat:@"%@=%@", k, env[k]]];
    char **envp = calloc(envStrings.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < envStrings.count; i++) envp[i] = strdup(envStrings[i].UTF8String);

    int fds[2], stdinPipe[2];
    if (pipe(fds) != 0) { free(envp); return T(@"无法启动服务管理进程", @"Couldn't start service management"); }
    if (pipe(stdinPipe) != 0) { close(fds[0]); close(fds[1]); free(envp); return T(@"无法启动服务管理进程", @"Couldn't start service management"); }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0);
    posix_spawn_file_actions_addclose(&actions, stdinPipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdinPipe[1]);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 2);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP); // own group, so a timeout can kill sudo and the script too
    posix_spawnattr_setpgroup(&attr, 0);
    char *argv[] = {(char *)shell.UTF8String, "-c", (char *)command.UTF8String, NULL};
    pid_t pid = 0;
    int rc = posix_spawn(&pid, shell.fileSystemRepresentation, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    for (NSUInteger i = 0; i < envStrings.count; i++) free(envp[i]);
    free(envp);
    close(fds[1]);
    close(stdinPipe[0]);
    if (rc != 0) { close(fds[0]); close(stdinPipe[1]); return T(@"无法启动服务管理进程", @"Couldn't start service management"); }
    {
        NSString *line = [password stringByAppendingString:@"\n"];
        const char *bytes = line.UTF8String;
        size_t length = strlen(bytes), written = 0;
        while (written < length) {
            ssize_t n = write(stdinPipe[1], bytes + written, length - written);
            if (n <= 0) break;
            written += (size_t)n;
        }
    }
    close(stdinPipe[1]);

    NSMutableData *out = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kServiceTimeout];
    for (;;) {
        double left = [deadline timeIntervalSinceNow];
        if (left <= 0) { *timedOut = YES; break; }
        struct pollfd pfd = {fds[0], POLLIN, 0};
        int n = poll(&pfd, 1, (int)MIN(left * 1000, 500));
        if (n > 0) {
            char buf[1024];
            ssize_t r = read(fds[0], buf, sizeof buf);
            if (r > 0) [out appendBytes:buf length:r];
            else if (r == 0 || errno != EINTR) break;
        }
    }
    close(fds[0]);
    int st = 0;
    if (*timedOut) {
        kill(-pid, SIGKILL);
        waitpid(pid, &st, 0);
    } else {
        waitpid(pid, &st, 0);
        *success = WIFEXITED(st) && WEXITSTATUS(st) == 0;
    }

    NSString *text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = Trimmed(raw);
        if (!line.length) continue;
        if ([line rangeOfString:@"password" options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
        if ([line rangeOfString:@"[sudo]"].location != NSNotFound) continue;
        if (password.length && [line rangeOfString:password].location != NSNotFound) continue;
        [lines addObject:line];
    }
    if (lines.count > 5) [lines removeObjectsInRange:NSMakeRange(0, lines.count - 5)];
    return [lines componentsJoinedByString:@"\n"];
}

typedef NS_ENUM(NSInteger, HostState) { HostDown, HostActive, HostWaiting, HostOnline };

#pragma mark - Theme Palette

// Light: warm stone #ECECE7; Dark: deep carbon #0A0A0D.
static UIColor *PageSurfaceColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.039 green:0.039 blue:0.051 alpha:1]
            : [UIColor colorWithRed:0.925 green:0.925 blue:0.906 alpha:1];
    }];
}

// Light: crisp white #FFFFFF; Dark: dark graphite #18181C.
static UIColor *CardSurfaceColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.094 green:0.094 blue:0.110 alpha:1]
            : [UIColor colorWithWhite:1.0 alpha:1];
    }];
}

// Status Hero surface: white card in Light mode; vibrant electric blue #1D74F5 (or state surface) in Dark mode.
static UIColor *HeroSurfaceColor(HostState state) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle != UIUserInterfaceStyleDark) return [UIColor whiteColor];
        switch (state) {
            case HostActive:
            case HostOnline: return [UIColor colorWithRed:0.114 green:0.455 blue:0.961 alpha:1];
            case HostWaiting: return [UIColor colorWithRed:0.114 green:0.380 blue:0.820 alpha:1];
            case HostDown: return [UIColor colorWithRed:0.125 green:0.129 blue:0.153 alpha:1];
        }
    }];
}

static UIColor *HeroPrimaryTextColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor whiteColor]
            : [UIColor colorWithRed:0.047 green:0.047 blue:0.055 alpha:1];
    }];
}

static UIColor *HeroSecondaryTextColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.78]
            : [UIColor colorWithRed:0.467 green:0.482 blue:0.514 alpha:1];
    }];
}

// Electric lime #D6FF00 in Light mode (active/online), amber for waiting, stone for offline;
// translucent white badge on the electric-blue hero card in Dark mode.
static UIColor *StatusBadgeFillColor(HostState state) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.18];
        }
        switch (state) {
            case HostActive:
            case HostOnline:
                return [UIColor colorWithRed:0.839 green:1.000 blue:0.000 alpha:1];
            case HostWaiting:
                return [UIColor colorWithRed:1.000 green:0.882 blue:0.302 alpha:1];
            case HostDown:
                return [UIColor colorWithRed:0.898 green:0.902 blue:0.882 alpha:1];
        }
    }];
}

static UIColor *StatusBadgeTextColor(HostState state) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor whiteColor];
        }
        if (state == HostDown) {
            return [UIColor colorWithRed:0.320 green:0.333 blue:0.365 alpha:1];
        }
        return [UIColor colorWithRed:0.047 green:0.047 blue:0.055 alpha:1];
    }];
}

static UIColor *FieldFillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.141 green:0.141 blue:0.165 alpha:1]
            : [UIColor colorWithRed:0.953 green:0.953 blue:0.941 alpha:1];
    }];
}

static UIColor *PrimaryActionFillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.114 green:0.455 blue:0.961 alpha:1]
            : [UIColor colorWithRed:0.047 green:0.047 blue:0.055 alpha:1];
    }];
}

static UIColor *SecondaryPillFillColor(BOOL destructive) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return destructive
                ? [UIColor colorWithRed:0.224 green:0.114 blue:0.122 alpha:1]
                : [UIColor colorWithRed:0.149 green:0.149 blue:0.176 alpha:1];
        }
        return [UIColor colorWithRed:0.953 green:0.953 blue:0.941 alpha:1];
    }];
}

static UIColor *SecondaryPillTextColor(BOOL destructive, BOOL enabled) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        if (!enabled) {
            return dark ? [UIColor colorWithWhite:1.0 alpha:0.28] : [UIColor colorWithWhite:0.0 alpha:0.28];
        }
        if (dark && destructive) {
            return [UIColor colorWithRed:1.000 green:0.353 blue:0.310 alpha:1];
        }
        return dark ? [UIColor whiteColor] : [UIColor colorWithRed:0.047 green:0.047 blue:0.055 alpha:1];
    }];
}

static UIColor *SubtleDividerColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.08]
            : [UIColor colorWithWhite:0.0 alpha:0.06];
    }];
}

@interface PanelController : UITabBarController <UITextFieldDelegate, UITabBarControllerDelegate>
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSMutableArray<UIScrollView *> *scrollViews;
// Floating pill bar
@property(nonatomic) UIView *floatingBar;
@property(nonatomic) NSArray<UIButton *> *floatingTabButtons;
// Status hero card
@property(nonatomic) UIView *statusPlate;
@property(nonatomic) HeroAsteriskView *heroWatermark;
@property(nonatomic) UILabel *heroDeviceLabel;
@property(nonatomic) UIView *statusBadgePill;
@property(nonatomic) UILabel *statusBadgeLabel;
@property(nonatomic) UIView *statusSymbolCircle;
@property(nonatomic) UIImageView *statusSymbol;
@property(nonatomic) UILabel *stateDetail;
@property(nonatomic) HostState displayedState;
@property(nonatomic) BOOL hasDisplayedState;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UILabel *lastSessionTitleLabel;
@property(nonatomic) UILabel *lastSessionLabel;
@property(nonatomic) UIStackView *qrGroup;
@property(nonatomic) UIImageView *qrView;
@property(nonatomic) NSDate *qrModified;
@property(nonatomic) NSDictionary *qrBeforeRequest;
@property(nonatomic) NSDate *loginDeadline;
@property(nonatomic) UIButton *refreshLoginButton;
@property(nonatomic) BOOL requestingLogin;
// Account
@property(nonatomic) UIView *accountCard;
@property(nonatomic) UIView *accountAvatar;
@property(nonatomic) UIImageView *accountSymbol;
@property(nonatomic) UILabel *accountCaptionLabel;
@property(nonatomic) UILabel *accountLabel;
@property(nonatomic) UIButton *logoutButton;
@property(nonatomic) BOOL loggingOut;
@property(nonatomic) NSDate *logoutDeadline;
@property(nonatomic) BOOL signedIn;
@property(nonatomic) BOOL hostAvailable;
@property(nonatomic) UILabel *accountResult;
// Service install
@property(nonatomic) UIView *installCard;
@property(nonatomic) UIView *installSection;
@property(nonatomic) UIView *installForm;
@property(nonatomic) UITextField *installField;
@property(nonatomic) NSMutableString *installPassword;
@property(nonatomic) UIButton *installButton;
@property(nonatomic) UILabel *installResult;
@property(nonatomic) UILabel *installOutput;
@property(nonatomic) BOOL installing;
@property(nonatomic) BOOL installFinished;
// Service uninstall
@property(nonatomic) UIButton *uninstallButton;
@property(nonatomic) UILabel *versionLabel;
@property(nonatomic) UILabel *uninstallResult;
@property(nonatomic) UILabel *uninstallOutput;
@property(nonatomic) BOOL uninstalling;
// Auto-unlock
@property(nonatomic) UIView *unlockCard;
@property(nonatomic) UIView *unlockStatusPill;
@property(nonatomic) UIImageView *unlockSymbol;
@property(nonatomic) UITextField *passcodeField;
@property(nonatomic) NSMutableString *passcode;
@property(nonatomic) UIButton *saveButton;
@property(nonatomic) UIButton *clearButton;
@property(nonatomic) UILabel *unlockLabel;
@property(nonatomic) NSString *unlockNotice;
@property(nonatomic) NSDate *unlockNoticeUntil;
// Lock after session
@property(nonatomic) UISwitch *lockSwitch;
// History
@property(nonatomic) UIStackView *historyRows;
@property(nonatomic) NSArray *historyShown;
// Shortcuts
@property(nonatomic) UISegmentedControl *shortcutPlatform;
@property(nonatomic) UIStackView *shortcutRows;
@property(nonatomic) NSArray<NSDictionary *> *shortcutValues;
@property(nonatomic) NSArray<NSString *> *shortcutKeyTexts;
@end

@implementation PanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PageSurfaceColor();
    self.view.tintColor = PrimaryActionFillColor();
    self.delegate = self;
    self.scrollViews = [NSMutableArray array];

    UIView *status = [self statusPlateView];
    self.installCard = [self installCardView];
    self.installSection = [self insetSection:self.installCard];
    self.unlockCard = [self unlockCardView];
    self.accountCard = [self accountCardView];
    self.viewControllers = @[
        [self pageWithTitle:T(@"连接", @"Connect") tab:T(@"连接", @"Connect") symbol:@"ipad"
            sections:@[[self insetSection:status], self.installSection, [self insetSection:self.accountCard],
                [self insetSection:[self historyCard]]]],
        [self pageWithTitle:T(@"安全", @"Security") tab:T(@"安全", @"Security") symbol:@"lock.shield"
            sections:@[[self insetSection:self.unlockCard], [self insetSection:[self lockCard]],
                [self insetSection:[self serviceCard]]]],
        [self pageWithTitle:T(@"快捷键", @"Shortcuts") tab:T(@"快捷键", @"Shortcuts") symbol:@"keyboard"
            sections:@[[self insetSection:[self shortcutsCard]]]],
    ];
    self.tabBar.hidden = YES;
    [self setupFloatingTabBar];

    NSNotificationCenter *notes = [NSNotificationCenter defaultCenter];
    [notes addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [notes addObserver:self selector:@selector(resumeRefresh) name:UIApplicationDidBecomeActiveNotification object:nil];
    [notes addObserver:self selector:@selector(pauseRefresh) name:UIApplicationWillResignActiveNotification object:nil];
    [self resumeRefresh];
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    [super setSelectedIndex:selectedIndex];
    [self updateFloatingTabBar];
}

- (void)setupFloatingTabBar {
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = CardSurfaceColor();
    bar.layer.cornerRadius = 30;
    bar.layer.cornerCurve = kCACornerCurveContinuous;
    bar.layer.shadowColor = [UIColor blackColor].CGColor;
    bar.layer.shadowOpacity = 0.08f;
    bar.layer.shadowRadius = 20;
    bar.layer.shadowOffset = CGSizeMake(0, 6);
    bar.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    bar.layer.borderColor = SubtleDividerColor().CGColor;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];
    self.floatingBar = bar;

    NSArray<NSString *> *titles = @[
        T(@"连接", @"Connect"),
        T(@"安全", @"Security"),
        T(@"快捷键", @"Shortcuts"),
    ];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 6;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:row];

    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = (NSInteger)i;
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = FontWeight(UIFontTextStyleSubheadline, UIFontWeightBold);
        btn.titleLabel.adjustsFontForContentSizeCategory = YES;
        btn.layer.cornerRadius = 24;
        btn.layer.cornerCurve = kCACornerCurveContinuous;
        [btn.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
        [btn addTarget:self action:@selector(floatingTabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:btn];
        [row addArrangedSubview:btn];
    }
    self.floatingTabButtons = buttons;

    NSLayoutConstraint *wide = [bar.widthAnchor constraintEqualToConstant:420];
    wide.priority = 750;
    [NSLayoutConstraint activateConstraints:@[
        [bar.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [bar.widthAnchor constraintLessThanOrEqualToConstant:420],
        [bar.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-32],
        wide,
        [row.topAnchor constraintEqualToAnchor:bar.topAnchor constant:6],
        [row.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-6],
        [row.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:6],
        [row.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-6],
    ]];
    [self updateFloatingTabBar];
}

static UIFont *FontWeight(UIFontTextStyle style, UIFontWeight weight) {
    return FontForTraitsWeight(style, weight, nil);
}

- (void)floatingTabTapped:(UIButton *)sender {
    [self dismissKeyboard];
    self.selectedIndex = (NSUInteger)sender.tag;
}

- (void)updateFloatingTabBar {
    if (!self.floatingTabButtons.count) return;
    self.floatingBar.layer.borderColor = SubtleDividerColor().CGColor;
    for (NSUInteger i = 0; i < self.floatingTabButtons.count; i++) {
        UIButton *btn = self.floatingTabButtons[i];
        BOOL active = (i == self.selectedIndex);
        btn.backgroundColor = active ? PrimaryActionFillColor() : [UIColor clearColor];
        UIColor *titleColor = active ? [UIColor whiteColor] : [UIColor secondaryLabelColor];
        [btn setTitleColor:titleColor forState:UIControlStateNormal];
        btn.accessibilityTraits = active ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateFloatingTabBar];
}

// 页面内容通栏滚动，所有卡片统一 28pt 大圆角并居中限制在 680pt。
- (UIViewController *)pageWithTitle:(NSString *)title tab:(NSString *)tab symbol:(NSString *)symbol
    sections:(NSArray<UIView *> *)sections {
    UIViewController *controller = [[UIViewController alloc] init];
    controller.title = title;
    controller.view.backgroundColor = PageSurfaceColor();
    controller.tabBarItem = [[UITabBarItem alloc] initWithTitle:tab image:[UIImage systemImageNamed:symbol] tag:self.scrollViews.count];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.alwaysBounceVertical = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:scroll];
    [self.scrollViews addObject:scroll];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [scroll addGestureRecognizer:tap];

    UIStackView *page = [[UIStackView alloc] initWithArrangedSubviews:sections];
    page.axis = UILayoutConstraintAxisVertical;
    page.spacing = 18;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:page];
    UILayoutGuide *content = scroll.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:controller.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:controller.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor],
        [page.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [page.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-104],
        [page.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.navigationBarHidden = YES;
    return navigation;
}

// 卡片在通栏页面里居中，宽度上限 680pt，两侧至少 20pt。
- (UIView *)insetSection:(UIView *)card {
    UIView *holder = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [holder addSubview:card];
    NSLayoutConstraint *fill = [card.widthAnchor constraintEqualToAnchor:holder.widthAnchor constant:-40];
    fill.priority = 750;
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:holder.topAnchor],
        [card.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor],
        [card.centerXAnchor constraintEqualToAnchor:holder.centerXAnchor],
        [card.widthAnchor constraintLessThanOrEqualToConstant:680],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:holder.widthAnchor constant:-40],
        fill,
    ]];
    return holder;
}

- (void)dismissKeyboard { [self.view endEditing:YES]; }

- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectViewController:(UIViewController *)viewController {
    [self dismissKeyboard];
    return YES;
}

- (void)resumeRefresh {
    [self refresh];
    if (!self.timer) self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)pauseRefresh { [self.timer invalidate]; self.timer = nil; }

#pragma mark - Cards

// Returns a 28pt continuous-corner card; its content stack comes back through `stack`.
- (UIView *)cardWithStack:(UIStackView **)stack {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = CardSurfaceColor();
    card.layer.cornerRadius = 28;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    UIStackView *s = [[UIStackView alloc] init];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 16;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:24],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-24],
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
    ]];
    *stack = s;
    return card;
}

- (UILabel *)cardTitle:(NSString *)text {
    UILabel *l = LabelWeight(UIFontTextStyleTitle3, UIFontWeightBold, [UIColor labelColor]);
    l.text = text;
    l.accessibilityTraits = UIAccessibilityTraitHeader;
    return l;
}

- (UIView *)hairlineInk:(BOOL)onHero {
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = onHero ? [UIColor colorWithWhite:1.0 alpha:0.16] : SubtleDividerColor();
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return line;
}

#pragma mark - Status Hero Card

- (UIView *)statusPlateView {
    UIView *plate = [[UIView alloc] init];
    plate.backgroundColor = HeroSurfaceColor(HostOnline);
    plate.layer.cornerRadius = 28;
    plate.layer.cornerCurve = kCACornerCurveContinuous;
    plate.clipsToBounds = YES;
    self.statusPlate = plate;

    HeroAsteriskView *watermark = [[HeroAsteriskView alloc] init];
    watermark.translatesAutoresizingMaskIntoConstraints = NO;
    [plate addSubview:watermark];
    self.heroWatermark = watermark;
    [NSLayoutConstraint activateConstraints:@[
        [watermark.widthAnchor constraintEqualToConstant:180],
        [watermark.heightAnchor constraintEqualToConstant:180],
        [watermark.trailingAnchor constraintEqualToAnchor:plate.trailingAnchor constant:24],
        [watermark.centerYAnchor constraintEqualToAnchor:plate.centerYAnchor constant:-8],
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [plate addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:plate.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:plate.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:plate.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:plate.trailingAnchor constant:-24],
    ]];

    self.heroDeviceLabel = LabelWeight(UIFontTextStyleFootnote, UIFontWeightBold, HeroSecondaryTextColor());
    self.heroDeviceLabel.text = [[UIDevice currentDevice].name uppercaseString];

    self.statusBadgePill = [[UIView alloc] init];
    self.statusBadgePill.backgroundColor = StatusBadgeFillColor(HostOnline);
    self.statusBadgePill.layer.cornerRadius = 16;
    self.statusBadgePill.layer.cornerCurve = kCACornerCurveContinuous;
    [self.statusBadgePill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.statusBadgePill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    self.statusBadgeLabel = LabelWeight(UIFontTextStyleCaption1, UIFontWeightHeavy, StatusBadgeTextColor(HostOnline));
    self.statusBadgeLabel.numberOfLines = 1;
    self.statusBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusBadgePill addSubview:self.statusBadgeLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusBadgeLabel.topAnchor constraintEqualToAnchor:self.statusBadgePill.topAnchor constant:7],
        [self.statusBadgeLabel.bottomAnchor constraintEqualToAnchor:self.statusBadgePill.bottomAnchor constant:-7],
        [self.statusBadgeLabel.leadingAnchor constraintEqualToAnchor:self.statusBadgePill.leadingAnchor constant:14],
        [self.statusBadgeLabel.trailingAnchor constraintEqualToAnchor:self.statusBadgePill.trailingAnchor constant:-14],
    ]];

    UIView *headSpacer = [[UIView alloc] init];
    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.heroDeviceLabel, headSpacer, self.statusBadgePill]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.spacing = 12;
    [stack addArrangedSubview:topRow];
    [stack setCustomSpacing:6 afterView:topRow];

    self.statusLabel = LabelWeight(UIFontTextStyleLargeTitle, UIFontWeightHeavy, HeroPrimaryTextColor());
    self.statusLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    [stack addArrangedSubview:self.statusLabel];
    [stack setCustomSpacing:4 afterView:self.statusLabel];

    self.stateDetail = Label(UIFontTextStyleBody, NO, HeroSecondaryTextColor());
    [stack addArrangedSubview:self.stateDetail];
    [stack setCustomSpacing:22 afterView:self.stateDetail];

    self.qrView = [[UIImageView alloc] init];
    self.qrView.contentMode = UIViewContentModeScaleAspectFit;
    self.qrView.backgroundColor = [UIColor whiteColor]; // the QR needs a light quiet zone in dark mode too
    self.qrView.layer.cornerRadius = 18;
    self.qrView.layer.cornerCurve = kCACornerCurveContinuous;
    self.qrView.clipsToBounds = YES;
    self.qrView.layer.magnificationFilter = kCAFilterNearest;
    self.qrView.layer.minificationFilter = kCAFilterNearest;
    self.qrView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.qrView.widthAnchor constraintEqualToConstant:200],
        [self.qrView.heightAnchor constraintEqualToConstant:200],
    ]];
    self.refreshLoginButton = [self buttonWithTitle:T(@"刷新二维码", @"Refresh QR Code") bold:NO action:@selector(refreshLogin)];
    self.refreshLoginButton.tintColor = HeroPrimaryTextColor();
    self.qrGroup = [[UIStackView alloc] initWithArrangedSubviews:@[self.qrView, self.refreshLoginButton]];
    self.qrGroup.axis = UILayoutConstraintAxisVertical;
    self.qrGroup.alignment = UIStackViewAlignmentCenter;
    self.qrGroup.spacing = 8;
    self.qrGroup.hidden = YES;
    [stack addArrangedSubview:self.qrGroup];
    [stack setCustomSpacing:22 afterView:self.qrGroup];

    self.statusSymbolCircle = [[UIView alloc] init];
    self.statusSymbolCircle.backgroundColor = StatusBadgeFillColor(HostOnline);
    self.statusSymbolCircle.layer.cornerRadius = 22;
    self.statusSymbolCircle.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusSymbolCircle.widthAnchor constraintEqualToConstant:44],
        [self.statusSymbolCircle.heightAnchor constraintEqualToConstant:44],
    ]];
    self.statusSymbol = [[UIImageView alloc] init];
    self.statusSymbol.contentMode = UIViewContentModeScaleAspectFit;
    self.statusSymbol.tintColor = StatusBadgeTextColor(HostOnline);
    self.statusSymbol.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusSymbolCircle addSubview:self.statusSymbol];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusSymbol.centerXAnchor constraintEqualToAnchor:self.statusSymbolCircle.centerXAnchor],
        [self.statusSymbol.centerYAnchor constraintEqualToAnchor:self.statusSymbolCircle.centerYAnchor],
    ]];

    self.lastSessionTitleLabel = Label(UIFontTextStyleSubheadline, YES, HeroPrimaryTextColor());
    self.lastSessionTitleLabel.text = T(@"最近连接", @"Last Session");
    self.lastSessionLabel = Label(UIFontTextStyleFootnote, NO, HeroSecondaryTextColor());
    UIStackView *sessionTextStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.lastSessionTitleLabel, self.lastSessionLabel]];
    sessionTextStack.axis = UILayoutConstraintAxisVertical;
    sessionTextStack.spacing = 2;

    UIStackView *sessionRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusSymbolCircle, sessionTextStack]];
    sessionRow.axis = UILayoutConstraintAxisHorizontal;
    sessionRow.spacing = 14;
    sessionRow.alignment = UIStackViewAlignmentCenter;
    [stack addArrangedSubview:sessionRow];
    return plate;
}

#pragma mark - Account

- (UIView *)accountCardView {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];

    self.accountAvatar = [[UIView alloc] init];
    self.accountAvatar.backgroundColor = PrimaryActionFillColor();
    self.accountAvatar.layer.cornerRadius = 24;
    self.accountAvatar.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.accountAvatar.widthAnchor constraintEqualToConstant:48],
        [self.accountAvatar.heightAnchor constraintEqualToConstant:48],
    ]];

    self.accountSymbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"person.fill"
        withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleHeadline]]];
    self.accountSymbol.tintColor = [UIColor whiteColor];
    self.accountSymbol.contentMode = UIViewContentModeScaleAspectFit;
    self.accountSymbol.translatesAutoresizingMaskIntoConstraints = NO;
    [self.accountAvatar addSubview:self.accountSymbol];
    [NSLayoutConstraint activateConstraints:@[
        [self.accountSymbol.centerXAnchor constraintEqualToAnchor:self.accountAvatar.centerXAnchor],
        [self.accountSymbol.centerYAnchor constraintEqualToAnchor:self.accountAvatar.centerYAnchor],
    ]];

    self.accountCaptionLabel = LabelWeight(UIFontTextStyleCaption1, UIFontWeightBold, [UIColor secondaryLabelColor]);
    self.accountCaptionLabel.text = T(@"账号", @"ACCOUNT");
    self.accountCaptionLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    self.accountLabel = LabelWeight(UIFontTextStyleHeadline, UIFontWeightBold, [UIColor labelColor]);
    UIStackView *metaStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.accountCaptionLabel, self.accountLabel]];
    metaStack.axis = UILayoutConstraintAxisVertical;
    metaStack.spacing = 2;

    self.logoutButton = [self pillSecondaryButtonWithTitle:T(@"退出登录", @"Sign Out") destructive:YES action:@selector(accountAction)];
    __weak PanelController *weakSelf = self;
    self.logoutButton.configurationUpdateHandler = ^(UIButton *button) {
        UIButtonConfiguration *cfg = button.configuration;
        cfg.baseBackgroundColor = SecondaryPillFillColor(weakSelf.signedIn);
        cfg.baseForegroundColor = SecondaryPillTextColor(weakSelf.signedIn, button.enabled);
        button.configuration = cfg;
    };
    UIView *spacer = [[UIView alloc] init];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.accountAvatar, metaStack, spacer, self.logoutButton]];
    row.spacing = 14;
    row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [stack addArrangedSubview:row];
    self.accountResult = Label(UIFontTextStyleFootnote, NO, [UIColor systemRedColor]);
    self.accountResult.hidden = YES;
    [stack addArrangedSubview:self.accountResult];
    return card;
}

#pragma mark - Install

- (UIView *)installCardView {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    [stack addArrangedSubview:[self cardTitle:T(@"安装服务", @"Install Daemon Service")]];

    self.installPassword = [NSMutableString string];
    self.installField = [self maskedFieldWithPlaceholder:T(@"Root / Sudo 密码（默认 123）", @"Root / Sudo Password (default 123)")];
    self.installButton = [self buttonWithTitle:T(@"安装", @"Install Service") bold:YES action:@selector(installService)];
    [self.installButton setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.installField, self.installButton]];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentFill;
    self.installForm = row;
    [stack addArrangedSubview:row];

    self.installResult = MonoLabel(UIFontTextStyleFootnote, [UIColor secondaryLabelColor]);
    self.installResult.hidden = YES;
    [stack addArrangedSubview:self.installResult];
    self.installOutput = MonoLabel(UIFontTextStyleFootnote, [UIColor secondaryLabelColor]);
    self.installOutput.hidden = YES;
    [stack addArrangedSubview:self.installOutput];
    return card;
}

- (UIButton *)buttonWithTitle:(NSString *)title bold:(BOOL)bold action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = Font(UIFontTextStyleBody, bold);
    b.titleLabel.adjustsFontForContentSizeCategory = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [b setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:50].active = YES;
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    if (bold) {
        UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
        configuration.baseBackgroundColor = PrimaryActionFillColor();
        configuration.baseForegroundColor = [UIColor whiteColor];
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(13, 24, 13, 24);
        b.configuration = configuration;
    }
    return b;
}

- (UIButton *)pillSecondaryButtonWithTitle:(NSString *)title destructive:(BOOL)destructive action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 18, 10, 18);
    cfg.baseBackgroundColor = SecondaryPillFillColor(destructive);
    cfg.baseForegroundColor = SecondaryPillTextColor(destructive, YES);
    b.configuration = cfg;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = Font(UIFontTextStyleSubheadline, YES);
    b.titleLabel.adjustsFontForContentSizeCategory = YES;
    b.configurationUpdateHandler = ^(UIButton *button) {
        UIButtonConfiguration *updated = button.configuration;
        updated.baseBackgroundColor = SecondaryPillFillColor(destructive);
        updated.baseForegroundColor = SecondaryPillTextColor(destructive, button.enabled);
        button.configuration = updated;
    };
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [b setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return b;
}

#pragma mark - Security

- (UIView *)serviceCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    [stack addArrangedSubview:[self cardTitle:T(@"宿主服务", @"Host Service")]];
    self.uninstallButton = [self pillSecondaryButtonWithTitle:T(@"卸载宿主服务", @"Uninstall Host Service")
        destructive:YES action:@selector(confirmUninstall)];
    [self.uninstallButton setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [stack addArrangedSubview:self.uninstallButton];
    self.uninstallResult = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
    self.uninstallResult.hidden = YES;
    [stack addArrangedSubview:self.uninstallResult];
    self.uninstallOutput = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
    self.uninstallOutput.hidden = YES;
    [stack addArrangedSubview:self.uninstallOutput];
    // Panel and host can come from different builds (the host is installed separately).
    self.versionLabel = MonoLabel(UIFontTextStyleCaption1, [UIColor secondaryLabelColor]);
    self.versionLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.versionLabel];
    return card;
}

static NSString *PanelVersion(void) {
    NSString *v = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    return v.length ? v : @"dev";
}

- (void)refreshVersion:(NSDictionary *)status {
    NSString *host = [status[@"version"] isKindOfClass:[NSString class]] ? status[@"version"] : nil;
    NSString *panel = PanelVersion();
    NSString *text = [NSString stringWithFormat:@"%@ %@ · %@ %@", T(@"面板", @"Panel"), panel,
        T(@"宿主", @"Host"), host ?: T(@"未运行", @"not running")];
    // A host without the field predates versioning: it is older than any versioned panel.
    BOOL mismatch = self.hostAvailable && ![host isEqualToString:panel];
    if (mismatch) text = [text stringByAppendingFormat:@"\n%@",
        T(@"版本不一致，请重新安装宿主服务", @"Versions differ; reinstall the host service")];
    SetText(self.versionLabel, text);
    UIColor *color = mismatch ? [UIColor systemOrangeColor] : [UIColor secondaryLabelColor];
    if (![self.versionLabel.textColor isEqual:color]) self.versionLabel.textColor = color;
}

- (UIView *)unlockCardView {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];

    UILabel *title = [self cardTitle:T(@"自动解锁", @"Auto-unlock")];
    self.unlockSymbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle"]];
    self.unlockSymbol.contentMode = UIViewContentModeScaleAspectFit;
    [self.unlockSymbol setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.unlockLabel = LabelWeight(UIFontTextStyleFootnote, UIFontWeightBold, [UIColor secondaryLabelColor]);

    self.unlockStatusPill = [[UIView alloc] init];
    self.unlockStatusPill.backgroundColor = FieldFillColor();
    self.unlockStatusPill.layer.cornerRadius = 15;
    self.unlockStatusPill.layer.cornerCurve = kCACornerCurveContinuous;
    UIStackView *pillContent = [[UIStackView alloc] initWithArrangedSubviews:@[self.unlockSymbol, self.unlockLabel]];
    pillContent.spacing = 6;
    pillContent.alignment = UIStackViewAlignmentCenter;
    pillContent.translatesAutoresizingMaskIntoConstraints = NO;
    [self.unlockStatusPill addSubview:pillContent];
    [NSLayoutConstraint activateConstraints:@[
        [pillContent.topAnchor constraintEqualToAnchor:self.unlockStatusPill.topAnchor constant:6],
        [pillContent.bottomAnchor constraintEqualToAnchor:self.unlockStatusPill.bottomAnchor constant:-6],
        [pillContent.leadingAnchor constraintEqualToAnchor:self.unlockStatusPill.leadingAnchor constant:12],
        [pillContent.trailingAnchor constraintEqualToAnchor:self.unlockStatusPill.trailingAnchor constant:-12],
    ]];

    UIView *headSpacer = [[UIView alloc] init];
    UIStackView *headerRow = [[UIStackView alloc] initWithArrangedSubviews:@[title, headSpacer, self.unlockStatusPill]];
    headerRow.axis = UILayoutConstraintAxisHorizontal;
    headerRow.alignment = UIStackViewAlignmentCenter;
    headerRow.spacing = 12;
    [stack addArrangedSubview:headerRow];

    self.passcode = [NSMutableString string];
    self.passcodeField = [self maskedFieldWithPlaceholder:T(@"iPad 锁屏密码", @"iPad Passcode")];
    [stack addArrangedSubview:self.passcodeField];

    self.saveButton = [self buttonWithTitle:T(@"保存", @"Save") bold:YES action:@selector(savePasscode)];
    self.clearButton = [self pillSecondaryButtonWithTitle:T(@"清除", @"Clear") destructive:YES action:@selector(clearPasscode)];

    UIView *spacer = [[UIView alloc] init];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[spacer, self.clearButton, self.saveButton]];
    row.spacing = 10;
    row.alignment = UIStackViewAlignmentCenter;
    [stack addArrangedSubview:row];
    [self updateButtons];
    return card;
}

// Masked by hand: with secureTextEntry iOS hides the keyboard from screen capture, so a remote
// viewer would see a grey box instead of the keys. The caller owns the backing string.
- (UITextField *)maskedFieldWithPlaceholder:(NSString *)placeholder {
    PaddedTextField *f = [[PaddedTextField alloc] init];
    f.placeholder = placeholder;
    f.accessibilityLabel = placeholder;
    f.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    f.adjustsFontForContentSizeCategory = YES;
    f.delegate = self;
    f.keyboardType = UIKeyboardTypeASCIICapable;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.spellCheckingType = UITextSpellCheckingTypeNo; // keep it out of keyboard learning
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    f.textContentType = UITextContentTypeOneTimeCode; // keep it out of AutoFill/Keychain prompts
    f.returnKeyType = UIReturnKeyDone;
    f.borderStyle = UITextBorderStyleNone;
    f.backgroundColor = FieldFillColor();
    f.layer.cornerRadius = 22;
    f.layer.cornerCurve = kCACornerCurveContinuous;
    [f setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [f.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    return f;
}

- (UIView *)lockCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];

    UIView *badge = [[UIView alloc] init];
    badge.backgroundColor = FieldFillColor();
    badge.layer.cornerRadius = 22;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:44],
        [badge.heightAnchor constraintEqualToConstant:44],
    ]];
    UIImageView *lockIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"
        withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody]]];
    lockIcon.tintColor = [UIColor labelColor];
    lockIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:lockIcon];
    [NSLayoutConstraint activateConstraints:@[
        [lockIcon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [lockIcon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
    ]];

    UILabel *title = LabelWeight(UIFontTextStyleHeadline, UIFontWeightBold, [UIColor labelColor]);
    title.text = T(@"远程结束后锁屏", @"Lock After Session");
    self.lockSwitch = [[UISwitch alloc] init];
    self.lockSwitch.onTintColor = PrimaryActionFillColor();
    self.lockSwitch.accessibilityLabel = title.text;
    [self.lockSwitch addTarget:self action:@selector(lockSwitchChanged) forControlEvents:UIControlEventValueChanged];
    [self.lockSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.lockSwitch setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIView *spacer = [[UIView alloc] init];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[badge, title, spacer, self.lockSwitch]];
    row.spacing = 14;
    row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [stack addArrangedSubview:row];
    return card;
}

#pragma mark - Shortcuts

- (UIView *)shortcutsCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];

    UILabel *title = [self cardTitle:T(@"远程快捷键", @"Remote Shortcuts")];
    self.shortcutPlatform = [[UISegmentedControl alloc] initWithItems:@[@"Windows", @"macOS"]];
    self.shortcutPlatform.selectedSegmentIndex = 0;
    self.shortcutPlatform.accessibilityLabel = T(@"控制端系统", @"Controller platform");
    [self.shortcutPlatform.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.shortcutPlatform addTarget:self action:@selector(shortcutPlatformChanged) forControlEvents:UIControlEventValueChanged];

    UIStackView *headStack = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.shortcutPlatform]];
    headStack.axis = UILayoutConstraintAxisVertical;
    headStack.spacing = 14;
    [stack addArrangedSubview:headStack];

    // 动作在左，按键在右；两种控制端分开显示，窄窗与大字号不再挤压三列。
    self.shortcutValues = @[
        @{@"action": T(@"复制", @"Copy"), @"win": @[@[@"Ctrl", @"C"]], @"mac": @[@[@"Cmd", @"C"]]},
        @{@"action": T(@"粘贴", @"Paste"), @"win": @[@[@"Ctrl", @"V"]], @"mac": @[@[@"Cmd", @"V"]]},
        @{@"action": T(@"全选", @"Select all"), @"win": @[@[@"Ctrl", @"A"]], @"mac": @[@[@"Cmd", @"A"]]},
        @{@"action": T(@"撤销", @"Undo"), @"win": @[@[@"Ctrl", @"Z"]], @"mac": @[@[@"Cmd", @"Z"]]},
        @{@"action": T(@"切换 App", @"Switch apps"), @"win": @[@[@"Alt", @"Tab"]], @"mac": @[@[@"Cmd", @"Tab"]]},
        @{@"action": T(@"多任务界面", @"App switcher"), @"win": @[@[@"Win", @"Tab"]], @"mac": @[@[@"Ctrl", @"↑"]]},
        @{@"action": T(@"回桌面", @"Home screen"),
            @"win": @[@[@"Win", @"D"], @[@"Ctrl", @"H"]], @"mac": @[@[@"Cmd", @"H"]]},
        @{@"action": T(@"切换输入法", @"Switch input method"),
            @"win": @[@[@"Win", @"Space"]], @"mac": @[@[@"Ctrl", @"Space"]]},
        @{@"action": @"Spotlight", @"win": @[@[@"Ctrl", @"Space"]], @"mac": @[@[@"Cmd", @"Space"]]},
    ];
    self.shortcutRows = [[UIStackView alloc] init];
    self.shortcutRows.axis = UILayoutConstraintAxisVertical;
    self.shortcutRows.spacing = 4;
    [stack addArrangedSubview:self.shortcutRows];

    [stack setCustomSpacing:16 afterView:self.shortcutRows];
    UIView *gestureRule = [self hairlineInk:NO];
    [stack addArrangedSubview:gestureRule];
    [stack setCustomSpacing:12 afterView:gestureRule];
    UILabel *gestureTitle = LabelWeight(UIFontTextStyleFootnote, UIFontWeightBold, [UIColor secondaryLabelColor]);
    gestureTitle.text = T(@"底边手势", @"Bottom Edge Gestures");
    gestureTitle.accessibilityTraits = UIAccessibilityTraitHeader;
    [stack addArrangedSubview:gestureTitle];
    NSArray<NSDictionary *> *mouse = @[
        @{@"action": T(@"回桌面", @"Home screen"), @"input": T(@"底边上滑", @"Swipe up")},
        @{@"action": T(@"多任务界面", @"App switcher"), @"input": T(@"上滑并停留 0.3 秒", @"Up and hold 0.3 s")},
        @{@"action": T(@"切到上一个 App", @"Previous app"), @"input": T(@"底边横滑", @"Swipe across")},
    ];
    for (NSDictionary *m in mouse) {
        UIView *row = [self shortcutRow:m[@"action"] trailing:[self plainKey:m[@"input"]] spoken:m[@"input"]];
        [stack addArrangedSubview:row];
    }
    [self rebuildShortcutRows];
    return card;
}

- (UIView *)plainKey:(NSString *)text {
    UIView *pill = [[UIView alloc] init];
    pill.backgroundColor = FieldFillColor();
    pill.layer.cornerRadius = 10;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    UILabel *l = LabelWeight(UIFontTextStyleSubheadline, UIFontWeightMedium, [UIColor secondaryLabelColor]);
    l.text = text;
    l.textAlignment = NSTextAlignmentRight;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:pill.topAnchor constant:5],
        [l.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-5],
        [l.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:10],
        [l.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-10],
    ]];
    return pill;
}

- (UIView *)keycap:(NSString *)key {
    UIView *cap = [[UIView alloc] init];
    cap.backgroundColor = FieldFillColor();
    cap.layer.cornerRadius = 10;
    cap.layer.cornerCurve = kCACornerCurveContinuous;
    UILabel *l = Label(UIFontTextStyleSubheadline, YES, [UIColor labelColor]);
    l.text = key;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [cap addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:cap.topAnchor constant:5],
        [l.bottomAnchor constraintEqualToAnchor:cap.bottomAnchor constant:-5],
        [l.leadingAnchor constraintEqualToAnchor:cap.leadingAnchor constant:10],
        [l.trailingAnchor constraintEqualToAnchor:cap.trailingAnchor constant:-10],
        [cap.heightAnchor constraintGreaterThanOrEqualToConstant:30],
    ]];
    return cap;
}

- (UIView *)keyGroups:(NSArray<NSArray<NSString *> *> *)groups {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6;
    row.alignment = UIStackViewAlignmentCenter;
    for (NSUInteger g = 0; g < groups.count; g++) {
        if (g > 0) {
            UILabel *or = Label(UIFontTextStyleFootnote, NO, [UIColor tertiaryLabelColor]);
            or.text = T(@"或", @"or");
            [row addArrangedSubview:or];
        }
        UIStackView *combo = [[UIStackView alloc] init];
        combo.axis = UILayoutConstraintAxisHorizontal;
        combo.spacing = 5;
        combo.alignment = UIStackViewAlignmentCenter;
        for (NSString *key in groups[g]) [combo addArrangedSubview:[self keycap:key]];
        [row addArrangedSubview:combo];
    }
    return row;
}

- (UIView *)shortcutRow:(NSString *)action trailing:(UIView *)trailing spoken:(NSString *)spoken {
    UILabel *left = LabelWeight(UIFontTextStyleBody, UIFontWeightMedium, [UIColor labelColor]);
    left.text = action;
    [left setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIView *spacer = [[UIView alloc] init];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[left, spacer, trailing]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    row.isAccessibilityElement = YES;
    row.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", action, spoken];
    return row;
}

- (void)rebuildShortcutRows {
    for (UIView *v in self.shortcutRows.arrangedSubviews) [v removeFromSuperview];
    NSInteger platform = self.shortcutPlatform.selectedSegmentIndex;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *item in self.shortcutValues) {
        NSArray<NSArray<NSString *> *> *groups = platform == 0 ? item[@"win"] : item[@"mac"];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSArray<NSString *> *combo in groups) [parts addObject:[combo componentsJoinedByString:@"+"]];
        NSString *spoken = [parts componentsJoinedByString:T(@" 或 ", @" or ")];
        [texts addObject:spoken];
        [self.shortcutRows addArrangedSubview:[self shortcutRow:item[@"action"]
            trailing:[self keyGroups:groups] spoken:spoken]];
    }
    self.shortcutKeyTexts = texts;
}

- (void)shortcutPlatformChanged { [self rebuildShortcutRows]; }

#pragma mark - History

- (UIView *)historyCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    [stack addArrangedSubview:[self cardTitle:T(@"连接记录", @"Recent Connections")]];
    self.historyRows = [[UIStackView alloc] init];
    self.historyRows.axis = UILayoutConstraintAxisVertical;
    self.historyRows.spacing = 0;
    [stack addArrangedSubview:self.historyRows];
    return card;
}

#pragma mark - Passcode

- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)text {
    NSMutableString *value = field == self.installField ? self.installPassword : self.passcode;
    if (NSMaxRange(range) > value.length) range = NSMakeRange(value.length, 0);
    [value replaceCharactersInRange:range withString:text];
    field.text = [@"" stringByPaddingToLength:value.length withString:@"•" startingAtIndex:0];
    [self updateButtons];
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == self.installField) [self installService];
    else if (self.passcode.length) [self savePasscode];
    else [field resignFirstResponder];
    return NO;
}

- (void)updateButtons {
    BOOL saved = [[NSFileManager defaultManager] fileExistsAtPath:kPasscodePath];
    BOOL typed = self.passcode.length > 0;
    if (self.saveButton.enabled != typed) self.saveButton.enabled = typed;
    if (self.clearButton.enabled != (saved || typed)) self.clearButton.enabled = saved || typed;
}

- (void)resetPasscodeField {
    [self.passcode setString:@""];
    self.passcodeField.text = @"";
    [self.passcodeField resignFirstResponder];
}

- (void)savePasscode {
    if (self.passcode.length == 0) return;
    BOOL ok = WritePrivate(kPasscodePath, [self.passcode dataUsingEncoding:NSUTF8StringEncoding]);
    [self resetPasscodeField];
    if (ok) {
        // A result from the previous passcode no longer applies.
        [[NSFileManager defaultManager] removeItemAtPath:kUnlockStatusPath error:nil];
        self.unlockNotice = nil;
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else {
        self.unlockNotice = T(@"保存失败，请重试", @"Couldn't save; try again");
        self.unlockNoticeUntil = [NSDate dateWithTimeIntervalSinceNow:4];
    }
    [self refresh];
}

- (void)clearPasscode {
    [[NSFileManager defaultManager] removeItemAtPath:kPasscodePath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:kUnlockStatusPath error:nil];
    self.unlockNotice = nil;
    [self resetPasscodeField];
    [self refresh];
}

#pragma mark - Account

- (void)accountAction {
    if (!self.logoutButton.enabled) return;
    if (self.signedIn) { [self confirmLogout]; return; }
    self.selectedIndex = 0;
    UIScrollView *scroll = self.scrollViews.firstObject;
    CGRect r = [self.statusPlate convertRect:self.statusPlate.bounds toView:scroll];
    [scroll scrollRectToVisible:r animated:!UIAccessibilityIsReduceMotionEnabled()];
}

- (void)confirmLogout {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:T(@"退出登录？", @"Sign out?")
        message:nil
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:T(@"取消", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:T(@"退出登录", @"Sign out") style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self logout]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)logout {
    if (!self.signedIn || self.loggingOut || self.installing || self.uninstalling) return;
    if (!WritePrivate(kCommandPath, [@"logout\n" dataUsingEncoding:NSUTF8StringEncoding])) {
        self.accountResult.text = T(@"退出请求失败，请重试", @"Couldn't request sign-out; try again");
        [self refresh];
        return;
    }
    self.loggingOut = YES;
    self.logoutDeadline = [NSDate dateWithTimeIntervalSinceNow:90];
    self.qrBeforeRequest = [[NSFileManager defaultManager] attributesOfItemAtPath:kQRPath error:nil];
    self.accountResult.text = @"";
    self.qrView.image = nil;
    self.qrModified = nil;
    [self refresh];
}

- (void)refreshLogin {
    if (!self.hostAvailable || self.signedIn || self.loggingOut || self.requestingLogin || self.installing || self.uninstalling) return;
    if (!WritePrivate(kCommandPath, [@"refresh-login\n" dataUsingEncoding:NSUTF8StringEncoding])) {
        self.accountResult.text = T(@"刷新请求失败，请重试", @"Couldn't request a new QR code; try again");
        [self refresh];
        return;
    }
    self.requestingLogin = YES;
    self.qrBeforeRequest = [[NSFileManager defaultManager] attributesOfItemAtPath:kQRPath error:nil];
    self.loginDeadline = [NSDate dateWithTimeIntervalSinceNow:90];
    self.accountResult.text = @"";
    self.qrView.image = nil;
    self.qrModified = nil;
    [self refresh];
}

#pragma mark - Service install

- (void)installService {
    if (self.installing || self.uninstalling) return;
    NSString *password = self.installPassword.length ? [self.installPassword copy] : @"123";
    [self.installPassword setString:@""];
    self.installField.text = @"";
    [self.installField resignFirstResponder];
    [self runServiceOperation:NO password:password];
}

- (void)confirmUninstall {
    if (self.installing || self.uninstalling) return;
    [self dismissKeyboard];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:T(@"卸载宿主服务？", @"Uninstall host service?")
        message:T(@"远程连接将断开，宿主及其启动项将移除。保留登录、设置、记录与 Frida 程序。",
            @"Remote connections will close and the host and its launch jobs will be removed. Sign-in, settings, history and the Frida binary are kept.")
        preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController *weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = T(@"Root / Sudo 密码（默认 123）", @"Root / Sudo Password (default 123)");
        field.accessibilityLabel = field.placeholder;
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.textContentType = UITextContentTypeOneTimeCode;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:T(@"取消", @"Cancel") style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *a) { weakAlert.textFields.firstObject.text = @""; }]];
    [alert addAction:[UIAlertAction actionWithTitle:T(@"卸载", @"Uninstall") style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            UITextField *field = weakAlert.textFields.firstObject;
            NSString *password = field.text.length ? [field.text copy] : @"123";
            field.text = @"";
            [self runServiceOperation:YES password:password];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runServiceOperation:(BOOL)uninstall password:(NSString *)password {
    if (self.installing || self.uninstalling) return;
    self.installing = !uninstall;
    self.uninstalling = uninstall;
    self.installFinished = NO;
    self.uninstallResult.text = @"";
    self.uninstallOutput.text = @"";
    [self refresh];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok, timedOut;
        NSString *output = RunServiceScript(uninstall ? @"uninstall-service.sh" : @"install-service.sh", password, &ok, &timedOut);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.installing = NO;
            self.uninstalling = NO;
            NSString *statusWord;
            if (uninstall) {
                statusWord = ok ? T(@"卸载完成", @"Uninstalled")
                    : timedOut ? T(@"卸载超时，请重试", @"Uninstall timed out; try again")
                    : T(@"卸载失败，请重试", @"Uninstall failed; try again");
                self.uninstallResult.text = statusWord;
                self.uninstallResult.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
                self.uninstallOutput.text = output;
                if (ok) {
                    [self.installPassword setString:@""];
                    self.installField.text = @"";
                }
            } else {
                self.installFinished = YES;
                statusWord = ok ? T(@"安装完成", @"installed")
                    : timedOut ? T(@"安装超时", @"timed out") : T(@"安装失败", @"failed");
                self.installResult.text = [NSString stringWithFormat:@"$ status: %@", statusWord];
                self.installResult.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
                self.installOutput.text = output;
            }
            [self refresh];
        });
    });
}

#pragma mark - Settings

- (void)lockSwitchChanged {
    NSMutableDictionary *settings = [ReadJSONDict(kSettingsPath) mutableCopy] ?: [NSMutableDictionary dictionary];
    settings[@"lock_after_session"] = @(self.lockSwitch.on);
    NSData *data = [NSJSONSerialization dataWithJSONObject:settings options:NSJSONWritingSortedKeys error:nil];
    if (!data || !WritePrivate(kSettingsPath, data)) [self.lockSwitch setOn:!self.lockSwitch.on animated:YES];
}

#pragma mark - Keyboard

- (void)keyboardWillChange:(NSNotification *)note {
    UIScrollView *scrollView = self.scrollViews[self.selectedIndex];
    // 切换标签页时键盘退场通知可能晚到，清掉上一页的键盘留白。
    for (UIScrollView *other in self.scrollViews) {
        if (other == scrollView) continue;
        other.contentInset = UIEdgeInsetsZero;
        other.verticalScrollIndicatorInsets = UIEdgeInsetsZero;
    }
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    end = [scrollView convertRect:end fromCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
    // Plain arithmetic: build.sh does not link CoreGraphics, so CGRect* functions are unavailable.
    CGRect b = scrollView.bounds;
    BOOL across = end.origin.x < b.origin.x + b.size.width && end.origin.x + end.size.width > b.origin.x;
    CGFloat height = across ? MAX(0, MIN(b.origin.y + b.size.height, end.origin.y + end.size.height)
                                     - MAX(b.origin.y, end.origin.y)) : 0;
    // The automatic inset already covers the bottom safe area.
    CGFloat bottom = MAX(0, height - scrollView.adjustedContentInset.bottom + scrollView.contentInset.bottom);
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        UIEdgeInsets inset = scrollView.contentInset;
        inset.bottom = bottom;
        scrollView.contentInset = inset;
        UIEdgeInsets indicator = scrollView.verticalScrollIndicatorInsets;
        indicator.bottom = bottom;
        scrollView.verticalScrollIndicatorInsets = indicator;
    } completion:^(BOOL finished) {
        UIView *owner = self.passcodeField.isFirstResponder ? self.unlockCard : self.installField.isFirstResponder ? self.installCard : nil;
        if (bottom > 0 && owner) {
            CGRect r = [owner convertRect:owner.bounds toView:scrollView];
            r.origin.y -= 12;
            r.size.height += 24;
            [scrollView scrollRectToVisible:r animated:!UIAccessibilityIsReduceMotionEnabled()];
        }
    }];
}

#pragma mark - Refresh

// 仅“正在远控”时呼吸，用来区分实时状态；减少动态效果或后台时不跑动画。
- (void)updateLivePulse:(BOOL)live {
    if (live && self.view.window && !UIAccessibilityIsReduceMotionEnabled()) {
        if ([self.statusSymbolCircle.layer animationForKey:@"live"]) return;
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @1.0;
        pulse.toValue = @0.55;
        pulse.duration = 1.6;
        pulse.autoreverses = YES;
        pulse.repeatCount = 1e9;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.statusSymbolCircle.layer addAnimation:pulse forKey:@"live"];
    } else {
        [self.statusSymbolCircle.layer removeAnimationForKey:@"live"];
    }
}

- (void)displayState:(HostState)state viewers:(NSInteger)viewers {
    NSString *text, *badge, *detail, *symbol;
    switch (state) {
        case HostDown:
            text = T(@"服务未运行", @"Host Offline");
            badge = T(@"服务离线", @"HOST OFFLINE");
            detail = T(@"后台服务没有响应", @"Service not responding");
            symbol = @"minus"; break;
        case HostActive:
            text = T(@"正在远控", @"Session Active");
            badge = T(@"实时连接", @"SESSION LIVE");
            detail = [NSString stringWithFormat:T(@"%ld 个连接", @"%ld connected"), (long)viewers];
            symbol = @"dot.radiowaves.left.and.right"; break;
        case HostWaiting:
            text = self.loggingOut ? T(@"正在退出…", @"Signing Out…")
                : self.qrView.image ? T(@"等待扫码", @"Sign In") : T(@"正在加载二维码…", @"Loading QR Code…");
            badge = T(@"扫码登录", @"SCAN QR");
            detail = self.qrView.image ? T(@"手机扫码登录", @"Scan to sign in")
                : T(@"未登录", @"Not signed in");
            symbol = @"qrcode"; break;
        case HostOnline:
            text = T(@"已上线", @"Online");
            badge = T(@"在线就绪", @"HOST ONLINE");
            detail = T(@"等待连接", @"Waiting for connection...");
            symbol = @"arrow.right"; break;
    }
    BOOL changed = !self.hasDisplayedState || self.displayedState != state;
    void (^update)(void) = ^{
        self.statusPlate.backgroundColor = HeroSurfaceColor(state);
        SetText(self.statusLabel, text);
        SetText(self.statusBadgeLabel, badge);
        SetText(self.stateDetail, detail);
        self.statusBadgePill.backgroundColor = StatusBadgeFillColor(state);
        self.statusBadgeLabel.textColor = StatusBadgeTextColor(state);
        self.statusSymbolCircle.backgroundColor = StatusBadgeFillColor(state);
        self.statusSymbol.tintColor = StatusBadgeTextColor(state);
        if (changed) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold];
            self.statusSymbol.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        }
    };
    // 仅真实状态变化时转场；轮询刷新、后台和首次绘制不产生动画。
    if (changed && self.hasDisplayedState && self.view.window && self.selectedIndex == 0
        && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        [UIView transitionWithView:self.statusPlate duration:UIAccessibilityIsReduceMotionEnabled() ? 0.1 : 0.22
            options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionBeginFromCurrentState
            | UIViewAnimationOptionAllowUserInteraction animations:update completion:nil];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
    } else update();
    [self updateLivePulse:state == HostActive];
    self.displayedState = state;
    self.hasDisplayedState = YES;
}

- (void)refresh {
    NSString *loginStatus = Trimmed([NSString stringWithContentsOfFile:kStatusPath encoding:NSUTF8StringEncoding error:nil]);
    NSDictionary *status = ReadJSONDict(kStatusJSONPath);
    NSArray<NSDictionary *> *history = ReadHistory();

    self.hostAvailable = status && [[NSDate date] timeIntervalSince1970] - Number(status[@"updated"]) <= kStaleAfter;
    BOOL wasSignedIn = self.signedIn;
    self.signedIn = self.hostAvailable && [status[@"signed_in"] boolValue];
    if (self.signedIn && !wasSignedIn) self.accountResult.text = @"";
    if (self.loggingOut) {
        if ([loginStatus isEqualToString:@"error-logout"] && ![[NSFileManager defaultManager] fileExistsAtPath:kCommandPath]) {
            self.loggingOut = NO;
            self.accountResult.text = T(@"退出失败，请重试", @"Sign-out failed; try again");
        } else if (self.hostAvailable && !self.signedIn) {
            self.loggingOut = NO;
            self.requestingLogin = YES;
            self.loginDeadline = [NSDate dateWithTimeIntervalSinceNow:90];
        } else if (self.logoutDeadline.timeIntervalSinceNow <= 0) {
            self.loggingOut = NO;
            self.accountResult.text = T(@"退出超时，请重试", @"Sign-out timed out; try again");
        }
    }
    if (!self.signedIn && ([loginStatus isEqualToString:@"qr-error"] || [loginStatus isEqualToString:@"qr-expired"])
        && ![[NSFileManager defaultManager] fileExistsAtPath:kCommandPath]) {
        self.requestingLogin = NO;
        self.accountResult.text = [loginStatus isEqualToString:@"qr-expired"]
            ? T(@"二维码已失效，请刷新", @"QR code expired; refresh to retry")
            : T(@"二维码加载失败，请刷新", @"Couldn't load QR code; refresh to retry");
    }
    if (self.signedIn && !self.loggingOut) {
        self.requestingLogin = NO;
        self.qrBeforeRequest = nil;
    } else if (self.requestingLogin && self.loginDeadline.timeIntervalSinceNow <= 0) {
        self.requestingLogin = NO;
        self.accountResult.text = T(@"二维码加载超时，请刷新", @"QR code loading timed out; refresh to retry");
    }

    HostState state;
    if (!self.hostAvailable && !self.loggingOut && !self.requestingLogin) state = HostDown;
    else if (self.loggingOut || !self.signedIn) state = HostWaiting;
    else if (Number(status[@"viewers"]) > 0) state = HostActive;
    else state = HostOnline;

    [self refreshQR:state == HostWaiting && !self.loggingOut];
    [self displayState:state viewers:(NSInteger)Number(status[@"viewers"])];

    NSDictionary *last = history.lastObject;
    SetText(self.lastSessionLabel, last
        ? [NSString stringWithFormat:@"%@ · %@",
              WhenText([NSDate dateWithTimeIntervalSince1970:Number(last[@"at"])]), DurationText(Number(last[@"duration_s"]))]
        : T(@"暂无连接记录", @"No sessions yet"));

    [self refreshAccount:self.signedIn];
    // roothide hides /var/jb from an app, so the daemon binary cannot be probed by path: a fresh
    // status file means the service is installed and running.
    [self refreshInstall:state != HostDown];
    self.refreshLoginButton.enabled = self.hostAvailable && !self.loggingOut && !self.requestingLogin
        && !self.installing && !self.uninstalling;
    SetHidden(self.accountResult, self.accountResult.text.length == 0);
    [self refreshUnlock];
    [self refreshVersion:status];

    BOOL lockAfter = [ReadJSONDict(kSettingsPath)[@"lock_after_session"] boolValue];
    if (!self.lockSwitch.tracking && self.lockSwitch.on != lockAfter) [self.lockSwitch setOn:lockAfter animated:NO];

    [self refreshHistory:history];
}

- (void)refreshAccount:(BOOL)signedIn {
    SetText(self.accountLabel, signedIn ? T(@"已登录", @"Signed in") : T(@"未登录", @"Signed out"));
    self.accountAvatar.backgroundColor = signedIn ? PrimaryActionFillColor() : FieldFillColor();
    self.accountSymbol.tintColor = signedIn ? [UIColor whiteColor] : [UIColor tertiaryLabelColor];
    NSString *title = self.loggingOut ? T(@"正在退出…", @"Signing out…")
        : signedIn ? T(@"退出登录", @"Sign Out") : T(@"扫码登录", @"Sign In");
    if (![[self.logoutButton titleForState:UIControlStateNormal] isEqualToString:title]) {
        [UIView performWithoutAnimation:^{
            [self.logoutButton setTitle:title forState:UIControlStateNormal];
            [self.logoutButton layoutIfNeeded];
        }];
    }
    BOOL enabled = self.hostAvailable && !self.loggingOut && !self.installing && !self.uninstalling;
    if (self.logoutButton.enabled != enabled) self.logoutButton.enabled = enabled;
}

- (void)refreshInstall:(BOOL)installed {
    // 隐藏外层容器，否则被隐藏的卡片仍占着整段高度。
    SetHidden(self.installSection, installed && !self.installFinished && !self.installing);
    SetHidden(self.installCard, installed && !self.installFinished && !self.installing);
    SetHidden(self.installForm, installed);
    NSString *title = self.installing ? T(@"正在安装…", @"Installing…") : T(@"安装", @"Install Service");
    if (![[self.installButton titleForState:UIControlStateNormal] isEqualToString:title]) {
        [UIView performWithoutAnimation:^{
            [self.installButton setTitle:title forState:UIControlStateNormal];
            [self.installButton layoutIfNeeded];
        }];
    }
    BOOL busy = self.installing || self.uninstalling;
    if (self.installButton.enabled != !busy) self.installButton.enabled = !busy;
    if (self.installField.enabled != !busy) self.installField.enabled = !busy;
    SetHidden(self.installResult, !self.installFinished);
    SetHidden(self.installOutput, !self.installFinished || self.installOutput.text.length == 0);
    NSString *uninstallTitle = self.uninstalling ? T(@"正在卸载…", @"Uninstalling…") : T(@"卸载宿主服务", @"Uninstall Host Service");
    if (![[self.uninstallButton titleForState:UIControlStateNormal] isEqualToString:uninstallTitle]) {
        [UIView performWithoutAnimation:^{
            [self.uninstallButton setTitle:uninstallTitle forState:UIControlStateNormal];
            [self.uninstallButton layoutIfNeeded];
        }];
    }
    if (self.uninstallButton.enabled != !busy) self.uninstallButton.enabled = !busy;
    SetHidden(self.uninstallResult, self.uninstallResult.text.length == 0);
    SetHidden(self.uninstallOutput, self.uninstallOutput.text.length == 0);
}

- (void)refreshQR:(BOOL)waiting {
    if (!waiting) {
        self.qrView.image = nil;
        self.qrModified = nil;
        SetHidden(self.qrGroup, YES);
        return;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kQRPath error:nil];
    NSDate *modified = attrs.fileModificationDate;
    // The daemon atomically replaces the PNG; inode + mtime distinguish a new QR even on coarse clocks.
    BOOL previousQR = self.qrBeforeRequest && [modified isEqualToDate:self.qrBeforeRequest.fileModificationDate]
        && [attrs[NSFileSystemFileNumber] isEqual:self.qrBeforeRequest[NSFileSystemFileNumber]];
    if (previousQR) {
        self.qrView.image = nil;
        self.qrModified = nil;
    } else if (!(modified == self.qrModified || [modified isEqualToDate:self.qrModified])) {
        NSData *png = modified ? [NSData dataWithContentsOfFile:kQRPath] : nil;
        UIImage *image = png.length ? [UIImage imageWithData:png] : nil;
        self.qrView.image = image;
        self.qrModified = image ? modified : nil; // retry next tick if the daemon was mid-write
        if (image) {
            self.requestingLogin = NO;
            self.qrBeforeRequest = nil;
            self.accountResult.text = @"";
        }
    }
    SetHidden(self.qrView, self.qrView.image == nil);
    SetHidden(self.qrGroup, NO);
}

- (void)refreshUnlock {
    [self updateButtons];
    NSString *symbol = @"circle";
    UIColor *symbolColor = [UIColor tertiaryLabelColor];
    if (self.unlockNotice && [self.unlockNoticeUntil timeIntervalSinceNow] > 0) {
        SetText(self.unlockLabel, self.unlockNotice);
        SetColor(self.unlockLabel, [UIColor systemRedColor]);
        symbol = @"exclamationmark.circle.fill";
        symbolColor = [UIColor systemRedColor];
        [self setUnlockSymbol:symbol color:symbolColor];
        return;
    }
    self.unlockNotice = nil;
    BOOL saved = [[NSFileManager defaultManager] fileExistsAtPath:kPasscodePath];
    NSArray *parts = [Trimmed([NSString stringWithContentsOfFile:kUnlockStatusPath encoding:NSUTF8StringEncoding error:nil])
        componentsSeparatedByString:@" "];
    NSString *text = saved ? T(@"已保存", @"Saved") : T(@"未保存", @"Not saved");
    UIColor *color = [UIColor secondaryLabelColor];
    if (saved) {
        symbol = @"checkmark.circle.fill";
        symbolColor = [UIColor secondaryLabelColor];
    }
    if (saved && parts.count == 2 && [parts[0] isEqualToString:@"ok"]) {
        NSString *when = WhenText([NSDate dateWithTimeIntervalSince1970:[parts[1] doubleValue]]);
        text = [NSString stringWithFormat:T(@"已解锁 · %@", @"Unlocked · %@"), when];
        color = [UIColor systemGreenColor];
        symbol = @"checkmark.circle.fill";
        symbolColor = [UIColor systemGreenColor];
    } else if (saved && parts.count == 2 && [parts[0] isEqualToString:@"rejected"]) {
        text = T(@"密码被拒，请重存", @"Rejected · Save again");
        color = [UIColor systemRedColor];
        symbol = @"exclamationmark.triangle.fill";
        symbolColor = [UIColor systemRedColor];
    }
    SetText(self.unlockLabel, text);
    SetColor(self.unlockLabel, color);
    [self setUnlockSymbol:symbol color:symbolColor];
}

- (void)setUnlockSymbol:(NSString *)name color:(UIColor *)color {
    UIImage *image = [UIImage systemImageNamed:name
        withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote]];
    if (image != self.unlockSymbol.image) self.unlockSymbol.image = image;
    if (![self.unlockSymbol.tintColor isEqual:color]) self.unlockSymbol.tintColor = color;
}

- (void)refreshHistory:(NSArray<NSDictionary *> *)history {
    NSMutableArray<NSArray<NSString *> *> *items = [NSMutableArray array];
    for (NSDictionary *e in history.reverseObjectEnumerator) {
        if (items.count == 5) break;
        [items addObject:@[WhenText([NSDate dateWithTimeIntervalSince1970:Number(e[@"at"])]), DurationText(Number(e[@"duration_s"]))]];
    }
    // Rows are rebuilt only when their text changes (also rolls 今天 over to 昨天 at midnight).
    if ([items isEqualToArray:self.historyShown]) return;
    self.historyShown = items;
    for (UIView *v in self.historyRows.arrangedSubviews) [v removeFromSuperview];
    if (items.count == 0) {
        UILabel *empty = Label(UIFontTextStyleSubheadline, NO, [UIColor secondaryLabelColor]);
        empty.text = T(@"暂无连接记录", @"No recent sessions");
        [self.historyRows addArrangedSubview:empty];
        return;
    }
    for (NSUInteger i = 0; i < items.count; i++) {
        NSArray<NSString *> *item = items[i];
        UILabel *when = LabelWeight(UIFontTextStyleHeadline, UIFontWeightBold, [UIColor labelColor]);
        when.text = item[0];
        UILabel *duration = Label(UIFontTextStyleSubheadline, NO, [UIColor secondaryLabelColor]);
        duration.text = item[1];
        UIStackView *leftStack = [[UIStackView alloc] initWithArrangedSubviews:@[when, duration]];
        leftStack.axis = UILayoutConstraintAxisVertical;
        leftStack.spacing = 2;

        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
            withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote]]];
        chevron.tintColor = [UIColor tertiaryLabelColor];
        [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIView *spacer = [[UIView alloc] init];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[leftStack, spacer, chevron]];
        row.spacing = 12;
        row.alignment = UIStackViewAlignmentCenter;
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:56].active = YES;
        row.isAccessibilityElement = YES;
        row.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", item[0], item[1]];
        [self.historyRows addArrangedSubview:row];
        if (i + 1 < items.count) [self.historyRows addArrangedSubview:[self hairlineInk:NO]];
    }
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[PanelController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
