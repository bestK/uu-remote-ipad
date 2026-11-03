// Home-screen panel for the iPad UU host: shows the login QR the daemon writes and keeps the
// lock-screen passcode the host uses to unlock the iPad when a viewer connects.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
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
static const NSTimeInterval kInstallTimeout = 60;

static const NSTimeInterval kStaleAfter = 10; // the host rewrites uu-status.json every 3 s

static NSString *T(NSString *zh, NSString *en) {
    static BOOL chinese;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ chinese = [[NSLocale preferredLanguages].firstObject hasPrefix:@"zh"]; });
    return chinese ? zh : en;
}

// Bold variant that still follows Dynamic Type.
static UIFont *Font(UIFontTextStyle style, BOOL bold) {
    if (!bold) return [UIFont preferredFontForTextStyle:style];
    UITraitCollection *base = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
    UIFontDescriptor *d = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style compatibleWithTraitCollection:base];
    d = [d fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] ?: d;
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont fontWithDescriptor:d size:0]];
}

static UILabel *Label(UIFontTextStyle style, BOOL bold, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.font = Font(style, bold);
    l.adjustsFontForContentSizeCategory = YES;
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

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

// Runs the bundled install-service.sh through sudo. The password only lives in this command line;
// it is never written to a file or logged. Returns the last lines of output (password lines removed).
static NSString *RunInstall(NSString *password, BOOL *success, BOOL *timedOut) {
    *success = NO;
    *timedOut = NO;
    NSString *script = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"service/install-service.sh"];
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
    if (pipe(fds) != 0) { free(envp); return T(@"无法启动安装进程", @"Couldn't start the installer"); }
    if (pipe(stdinPipe) != 0) { close(fds[0]); close(fds[1]); free(envp); return T(@"无法启动安装进程", @"Couldn't start the installer"); }
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
    if (rc != 0) { close(fds[0]); close(stdinPipe[1]); return T(@"无法启动安装进程", @"Couldn't start the installer"); }
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
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kInstallTimeout];
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

@interface PanelController : UIViewController <UITextFieldDelegate>
@property(nonatomic) NSTimer *timer;
@property(nonatomic) UIScrollView *scrollView;
// Status
@property(nonatomic) UIView *dot;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UILabel *lastSessionLabel;
@property(nonatomic) UIStackView *qrGroup;
@property(nonatomic) UIImageView *qrView;
@property(nonatomic) NSDate *qrModified;
// Account
@property(nonatomic) UILabel *accountLabel;
@property(nonatomic) UIButton *logoutButton;
@property(nonatomic) BOOL loggingOut;
// Service install
@property(nonatomic) UIView *installCard;
@property(nonatomic) UIView *installForm;
@property(nonatomic) UITextField *installField;
@property(nonatomic) NSMutableString *installPassword;
@property(nonatomic) UIButton *installButton;
@property(nonatomic) UILabel *installResult;
@property(nonatomic) UILabel *installOutput;
@property(nonatomic) BOOL installing;
@property(nonatomic) BOOL installFinished;
// Auto-unlock
@property(nonatomic) UIView *unlockCard;
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
@end

@implementation PanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self.view action:@selector(endEditing:)];
    tap.cancelsTouchesInView = NO;
    [self.scrollView addGestureRecognizer:tap];

    UIStackView *page = [[UIStackView alloc] init];
    page.axis = UILayoutConstraintAxisVertical;
    page.spacing = 20;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:page];

    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 2;
    UILabel *title = Label(UIFontTextStyleLargeTitle, YES, [UIColor labelColor]);
    title.text = T(@"UU 远程", @"UU Remote");
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    UILabel *subtitle = Label(UIFontTextStyleSubheadline, NO, [UIColor secondaryLabelColor]);
    subtitle.text = [NSString stringWithFormat:@"%@ \u00B7 %@", [UIDevice currentDevice].name, T(@"iPad 宿主", @"iPad host")];
    [header addArrangedSubview:title];
    [header addArrangedSubview:subtitle];
    [page addArrangedSubview:header];

    [page addArrangedSubview:(self.installCard = [self installCardView])];
    [page addArrangedSubview:[self statusCard]];
    [page addArrangedSubview:[self accountCard]];
    [page addArrangedSubview:(self.unlockCard = [self unlockCardView])];
    [page addArrangedSubview:[self lockCard]];
    [page addArrangedSubview:[self shortcutsCard]];
    [page addArrangedSubview:[self historyCard]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *content = self.scrollView.contentLayoutGuide;
    NSLayoutConstraint *preferredWidth = [page.widthAnchor constraintEqualToConstant:680];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [page.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
        [page.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-32],
        [page.centerXAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.centerXAnchor],
        [page.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],
        [page.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],
        preferredWidth,
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:)
        name:UIKeyboardWillChangeFrameNotification object:nil];

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

#pragma mark - Cards

// Returns the card; its content stack comes back through `stack`.
- (UIView *)cardWithStack:(UIStackView **)stack {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    UIStackView *s = [[UIStackView alloc] init];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 8;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    ]];
    *stack = s;
    return card;
}

- (UILabel *)cardTitle:(NSString *)text {
    UILabel *l = Label(UIFontTextStyleHeadline, NO, [UIColor labelColor]);
    l.text = text;
    l.accessibilityTraits = UIAccessibilityTraitHeader;
    return l;
}

- (UIView *)statusCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];

    self.dot = [[UIView alloc] init];
    self.dot.layer.cornerRadius = 5;
    self.dot.isAccessibilityElement = YES;
    self.dot.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.dot.widthAnchor constraintEqualToConstant:10],
        [self.dot.heightAnchor constraintEqualToConstant:10],
    ]];
    self.statusLabel = Label(UIFontTextStyleHeadline, NO, [UIColor labelColor]);
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.dot, self.statusLabel]];
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    [stack addArrangedSubview:row];

    self.lastSessionLabel = Label(UIFontTextStyleSubheadline, NO, [UIColor secondaryLabelColor]);
    [stack addArrangedSubview:self.lastSessionLabel];

    self.qrView = [[UIImageView alloc] init];
    self.qrView.contentMode = UIViewContentModeScaleAspectFit;
    self.qrView.backgroundColor = [UIColor whiteColor]; // the QR needs a light quiet zone in dark mode too
    self.qrView.layer.cornerRadius = 12;
    self.qrView.clipsToBounds = YES;
    self.qrView.layer.magnificationFilter = kCAFilterNearest;
    self.qrView.layer.minificationFilter = kCAFilterNearest;
    self.qrView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.qrView.widthAnchor constraintEqualToConstant:200],
        [self.qrView.heightAnchor constraintEqualToConstant:200],
    ]];
    UILabel *hint = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
    hint.textAlignment = NSTextAlignmentCenter;
    hint.text = T(@"用手机上的「网易UU远程」App 扫码，并在手机上确认。",
                  @"Scan with the UU Remote app on your phone and confirm there.");
    self.qrGroup = [[UIStackView alloc] initWithArrangedSubviews:@[self.qrView, hint]];
    self.qrGroup.axis = UILayoutConstraintAxisVertical;
    self.qrGroup.alignment = UIStackViewAlignmentCenter;
    self.qrGroup.spacing = 12;
    self.qrGroup.hidden = YES;
    [stack addArrangedSubview:self.qrGroup];
    [stack setCustomSpacing:16 afterView:self.lastSessionLabel];
    return card;
}

- (UIView *)unlockCardView {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    [stack addArrangedSubview:[self cardTitle:T(@"自动解锁", @"Auto-unlock")]];
    UILabel *desc = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
    desc.text = T(@"远程连接时如果 iPad 处于锁屏，会用保存的密码自动解锁。",
                  @"Unlocks the iPad with the saved passcode when a remote session starts on the lock screen.");
    [stack addArrangedSubview:desc];

    self.passcode = [NSMutableString string];
    self.passcodeField = [self maskedFieldWithPlaceholder:T(@"iPad 锁屏密码", @"iPad passcode")];

    self.saveButton = [self buttonWithTitle:T(@"保存", @"Save") bold:YES action:@selector(savePasscode)];
    self.clearButton = [self buttonWithTitle:T(@"清除", @"Clear") bold:NO action:@selector(clearPasscode)];
    [self.clearButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [self.clearButton setTitleColor:[UIColor tertiaryLabelColor] forState:UIControlStateDisabled];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.passcodeField, self.saveButton, self.clearButton]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    [stack addArrangedSubview:row];
    [stack setCustomSpacing:12 afterView:desc];

    self.unlockLabel = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
    [stack addArrangedSubview:self.unlockLabel];
    [self updateButtons];
    return card;
}

// Masked by hand: with secureTextEntry iOS hides the keyboard from screen capture, so a remote
// viewer would see a grey box instead of the keys. The caller owns the backing string.
- (UITextField *)maskedFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = placeholder;
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
    f.borderStyle = UITextBorderStyleRoundedRect;
    [f setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [f.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return f;
}

- (UIView *)accountCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    [stack addArrangedSubview:[self cardTitle:T(@"账号", @"Account")]];
    self.accountLabel = Label(UIFontTextStyleBody, NO, [UIColor labelColor]);
    self.logoutButton = [self buttonWithTitle:T(@"退出登录", @"Sign out") bold:NO action:@selector(confirmLogout)];
    [self.logoutButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [self.logoutButton setTitleColor:[UIColor tertiaryLabelColor] forState:UIControlStateDisabled];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.accountLabel, self.logoutButton]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [stack addArrangedSubview:row];
    return card;
}

- (UIView *)installCardView {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    [stack addArrangedSubview:[self cardTitle:T(@"安装服务", @"Install service")]];
    UILabel *desc = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
    desc.text = T(@"把宿主服务安装到系统后才能被远程控制。", @"Install the host service to the system to allow remote control.");
    [stack addArrangedSubview:desc];

    self.installPassword = [NSMutableString string];
    self.installField = [self maskedFieldWithPlaceholder:T(@"设备密码，默认 123", @"Device password, default 123")];
    self.installButton = [self buttonWithTitle:T(@"安装", @"Install") bold:YES action:@selector(installService)];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.installField, self.installButton]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    self.installForm = row;
    [stack addArrangedSubview:row];
    [stack setCustomSpacing:12 afterView:desc];

    self.installResult = Label(UIFontTextStyleSubheadline, YES, [UIColor labelColor]);
    self.installResult.hidden = YES;
    [stack addArrangedSubview:self.installResult];
    self.installOutput = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
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
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return b;
}

- (UIView *)lockCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    UILabel *title = Label(UIFontTextStyleBody, NO, [UIColor labelColor]);
    title.text = T(@"远程结束后锁屏", @"Lock when the session ends");
    self.lockSwitch = [[UISwitch alloc] init];
    self.lockSwitch.accessibilityLabel = title.text;
    [self.lockSwitch addTarget:self action:@selector(lockSwitchChanged) forControlEvents:UIControlEventValueChanged];
    [self.lockSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.lockSwitch setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.lockSwitch]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [stack addArrangedSubview:row];
    UILabel *desc = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
    desc.text = T(@"最后一个远程连接结束后，iPad 会锁屏。", @"Locks the iPad when the last remote session ends.");
    [stack addArrangedSubview:desc];
    return card;
}

- (UIView *)shortcutsCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    [stack addArrangedSubview:[self cardTitle:T(@"远程快捷键", @"Remote shortcuts")]];

    // {Windows key, Mac key, action}
    NSArray<NSArray<NSString *> *> *keys = @[
        @[@"Ctrl+C", @"Cmd+C", T(@"复制", @"Copy")],
        @[@"Ctrl+V", @"Cmd+V", T(@"粘贴", @"Paste")],
        @[@"Ctrl+A", @"Cmd+A", T(@"全选", @"Select all")],
        @[@"Ctrl+Z", @"Cmd+Z", T(@"撤销", @"Undo")],
        @[@"Alt+Tab", @"Cmd+Tab", T(@"切换 App", @"Switch apps")],
        @[@"Win+Tab", @"Ctrl+\u2191", T(@"多任务界面", @"App switcher")],
        @[[@"Win+D " stringByAppendingString:T(@"或 Ctrl+H", @"or Ctrl+H")], @"Cmd+H", T(@"回桌面", @"Home screen")],
        @[@"Win+Space", @"Ctrl+Space", T(@"切换输入法", @"Switch input method")],
        @[@"Ctrl+Space", @"Cmd+Space", @"Spotlight"],
    ];
    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 6;
    NSMutableArray<UILabel *> *winLabels = [NSMutableArray array];
    for (NSArray<NSString *> *k in keys) {
        UILabel *win = Label(UIFontTextStyleFootnote, NO, [UIColor labelColor]);
        win.text = k[0];
        win.numberOfLines = 1;
        UILabel *mac = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
        mac.text = [@"Mac " stringByAppendingString:k[1]];
        mac.numberOfLines = 1;
        [winLabels addObject:win];
        UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[win, mac]];
        left.spacing = 12;
        [rows addArrangedSubview:[self shortcutRow:left action:k[2]]];
    }
    NSArray<NSArray<NSString *> *> *mouse = @[
        @[T(@"鼠标从屏幕最底部往上拖", @"Mouse: drag up from the bottom edge"), T(@"回桌面", @"Home screen")],
        @[T(@"往上拖并停住 0.3 秒", @"Drag up and hold 0.3 s"), T(@"多任务界面", @"App switcher")],
    ];
    UIView *gap = [[UIView alloc] init];
    [gap.heightAnchor constraintEqualToConstant:4].active = YES;
    [rows addArrangedSubview:gap];
    for (NSArray<NSString *> *m in mouse) {
        UILabel *gesture = Label(UIFontTextStyleFootnote, NO, [UIColor labelColor]);
        gesture.text = m[0];
        [rows addArrangedSubview:[self shortcutRow:gesture action:m[1]]];
    }
    [stack addArrangedSubview:rows];
    // Line the Mac column up across rows. Activated only now: a constraint between two views that
    // share no ancestor yet makes UIKit throw (NSLayoutConstraintIsPotentiallyDanglyInContainer).
    for (NSUInteger i = 1; i < winLabels.count; i++) {
        [winLabels[i].widthAnchor constraintEqualToAnchor:winLabels[0].widthAnchor].active = YES;
    }
    return card;
}

- (UIView *)shortcutRow:(UIView *)left action:(NSString *)action {
    UILabel *right = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
    right.text = action;
    right.textAlignment = NSTextAlignmentRight;
    [left setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh + 1 forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentFirstBaseline;
    row.isAccessibilityElement = YES;
    row.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", action,
        [left isKindOfClass:[UILabel class]] ? ((UILabel *)left).text
            : [[((UIStackView *)left).arrangedSubviews valueForKey:@"text"] componentsJoinedByString:@", "]];
    return row;
}

- (UIView *)historyCard {
    UIStackView *stack;
    UIView *card = [self cardWithStack:&stack];
    [stack addArrangedSubview:[self cardTitle:T(@"连接记录", @"Recent sessions")]];
    self.historyRows = [[UIStackView alloc] init];
    self.historyRows.axis = UILayoutConstraintAxisVertical;
    self.historyRows.spacing = 8;
    [stack addArrangedSubview:self.historyRows];
    return card;
}

#pragma mark - Passcode

- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)text {
    NSMutableString *value = field == self.installField ? self.installPassword : self.passcode;
    if (NSMaxRange(range) > value.length) range = NSMakeRange(value.length, 0);
    [value replaceCharactersInRange:range withString:text];
    field.text = [@"" stringByPaddingToLength:value.length withString:@"\u2022" startingAtIndex:0];
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

- (void)confirmLogout {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:T(@"退出登录？", @"Sign out?")
        message:T(@"退出后需要重新扫码登录。", @"You will need to scan the QR code to sign in again.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:T(@"取消", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:T(@"退出登录", @"Sign out") style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self logout]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)logout {
    if (!WritePrivate(kCommandPath, [@"logout\n" dataUsingEncoding:NSUTF8StringEncoding])) return;
    self.loggingOut = YES;
    [self refresh];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.loggingOut = NO;
        [self refresh];
    });
}

#pragma mark - Service install

- (void)installService {
    if (self.installing) return;
    NSString *password = self.installPassword.length ? [self.installPassword copy] : @"123";
    [self.installPassword setString:@""];
    self.installField.text = @"";
    [self.installField resignFirstResponder];
    self.installing = YES;
    self.installFinished = NO;
    [self refresh];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok, timedOut;
        NSString *output = RunInstall(password, &ok, &timedOut);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.installing = NO;
            self.installFinished = YES;
            self.installResult.text = ok ? T(@"安装完成", @"Installed")
                : timedOut ? T(@"安装超时", @"Install timed out") : T(@"安装失败", @"Install failed");
            self.installResult.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
            self.installOutput.text = output;
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
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    end = [self.view convertRect:end fromCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
    // Plain arithmetic: build.sh does not link CoreGraphics, so CGRect* functions are unavailable.
    CGRect b = self.view.bounds;
    BOOL across = end.origin.x < b.origin.x + b.size.width && end.origin.x + end.size.width > b.origin.x;
    CGFloat height = across ? MAX(0, MIN(b.origin.y + b.size.height, end.origin.y + end.size.height)
                                     - MAX(b.origin.y, end.origin.y)) : 0;
    // The automatic inset already covers the bottom safe area.
    CGFloat bottom = MAX(0, height - self.view.safeAreaInsets.bottom);
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        UIEdgeInsets inset = self.scrollView.contentInset;
        inset.bottom = bottom;
        self.scrollView.contentInset = inset;
        UIEdgeInsets indicator = self.scrollView.verticalScrollIndicatorInsets;
        indicator.bottom = bottom;
        self.scrollView.verticalScrollIndicatorInsets = indicator;
    } completion:^(BOOL finished) {
        UIView *owner = self.passcodeField.isFirstResponder ? self.unlockCard : self.installField.isFirstResponder ? self.installCard : nil;
        if (bottom > 0 && owner) {
            CGRect r = [owner convertRect:owner.bounds toView:self.scrollView];
            r.origin.y -= 12;
            r.size.height += 24;
            [self.scrollView scrollRectToVisible:r animated:YES];
        }
    }];
}

#pragma mark - Refresh

- (void)refresh {
    NSString *loginStatus = Trimmed([NSString stringWithContentsOfFile:kStatusPath encoding:NSUTF8StringEncoding error:nil]);
    NSDictionary *status = ReadJSONDict(kStatusJSONPath);
    NSArray<NSDictionary *> *history = ReadHistory();

    HostState state;
    if (!status || [[NSDate date] timeIntervalSince1970] - Number(status[@"updated"]) > kStaleAfter) state = HostDown;
    else if (Number(status[@"viewers"]) > 0) state = HostActive;
    else if ([loginStatus isEqualToString:@"waiting-scan"]) state = HostWaiting;
    else state = HostOnline;

    NSString *text;
    UIColor *color;
    switch (state) {
        case HostDown: text = T(@"宿主未运行", @"Host not running"); color = [UIColor systemGrayColor]; break;
        case HostActive: text = T(@"正在被远程控制", @"Remote session active"); color = [UIColor systemGreenColor]; break;
        case HostWaiting: text = T(@"等待扫码登录", @"Waiting for sign-in"); color = [UIColor systemOrangeColor]; break;
        case HostOnline: text = T(@"已上线，等待连接", @"Online, waiting for a connection"); color = [UIColor systemBlueColor]; break;
    }
    SetText(self.statusLabel, text);
    if (![self.dot.backgroundColor isEqual:color]) self.dot.backgroundColor = color;
    if (![self.dot.accessibilityLabel isEqualToString:text]) self.dot.accessibilityLabel = text;

    NSDictionary *last = history.lastObject;
    SetText(self.lastSessionLabel, last
        ? [NSString stringWithFormat:T(@"最近一次远程：%@，用时 %@", @"Last session: %@, %@"),
              WhenText([NSDate dateWithTimeIntervalSince1970:Number(last[@"at"])]), DurationText(Number(last[@"duration_s"]))]
        : T(@"还没有远程连接", @"No remote connections yet"));

    [self refreshQR:state == HostWaiting];
    [self refreshAccount:[status[@"signed_in"] boolValue]];
    // roothide hides /var/jb from an app, so the daemon binary cannot be probed by path: a fresh
    // status file means the service is installed and running.
    [self refreshInstall:state != HostDown];
    [self refreshUnlock];

    BOOL lockAfter = [ReadJSONDict(kSettingsPath)[@"lock_after_session"] boolValue];
    if (!self.lockSwitch.tracking && self.lockSwitch.on != lockAfter) [self.lockSwitch setOn:lockAfter animated:NO];

    [self refreshHistory:history];
}

- (void)refreshAccount:(BOOL)signedIn {
    SetText(self.accountLabel, signedIn ? T(@"已登录", @"Signed in") : T(@"未登录", @"Signed out"));
    NSString *title = self.loggingOut ? T(@"正在退出…", @"Signing out…") : T(@"退出登录", @"Sign out");
    if (![[self.logoutButton titleForState:UIControlStateNormal] isEqualToString:title]) {
        [UIView performWithoutAnimation:^{
            [self.logoutButton setTitle:title forState:UIControlStateNormal];
            [self.logoutButton layoutIfNeeded];
        }];
    }
    BOOL enabled = signedIn && !self.loggingOut;
    if (self.logoutButton.enabled != enabled) self.logoutButton.enabled = enabled;
}

- (void)refreshInstall:(BOOL)installed {
    SetHidden(self.installCard, installed && !self.installFinished && !self.installing);
    SetHidden(self.installForm, installed);
    NSString *title = self.installing ? T(@"正在安装…", @"Installing…") : T(@"安装", @"Install");
    if (![[self.installButton titleForState:UIControlStateNormal] isEqualToString:title]) {
        [UIView performWithoutAnimation:^{
            [self.installButton setTitle:title forState:UIControlStateNormal];
            [self.installButton layoutIfNeeded];
        }];
    }
    if (self.installButton.enabled != !self.installing) self.installButton.enabled = !self.installing;
    if (self.installField.enabled != !self.installing) self.installField.enabled = !self.installing;
    SetHidden(self.installResult, !self.installFinished);
    SetHidden(self.installOutput, !self.installFinished || self.installOutput.text.length == 0);
}

- (void)refreshQR:(BOOL)waiting {
    if (!waiting) {
        SetHidden(self.qrGroup, YES);
        return;
    }
    NSDate *modified = [[NSFileManager defaultManager] attributesOfItemAtPath:kQRPath error:nil].fileModificationDate;
    if (!(modified == self.qrModified || [modified isEqualToDate:self.qrModified])) {
        NSData *png = modified ? [NSData dataWithContentsOfFile:kQRPath] : nil;
        UIImage *image = png.length ? [UIImage imageWithData:png] : nil;
        self.qrView.image = image;
        self.qrModified = image ? modified : nil; // retry next tick if the daemon was mid-write
    }
    SetHidden(self.qrView, self.qrView.image == nil);
    SetHidden(self.qrGroup, NO);
}

- (void)refreshUnlock {
    [self updateButtons];
    if (self.unlockNotice && [self.unlockNoticeUntil timeIntervalSinceNow] > 0) {
        SetText(self.unlockLabel, self.unlockNotice);
        SetColor(self.unlockLabel, [UIColor systemRedColor]);
        return;
    }
    self.unlockNotice = nil;
    BOOL saved = [[NSFileManager defaultManager] fileExistsAtPath:kPasscodePath];
    NSArray *parts = [Trimmed([NSString stringWithContentsOfFile:kUnlockStatusPath encoding:NSUTF8StringEncoding error:nil])
        componentsSeparatedByString:@" "];
    NSString *text = saved ? T(@"已保存", @"Saved") : T(@"未保存", @"Not saved");
    UIColor *color = [UIColor secondaryLabelColor];
    if (saved && parts.count == 2 && [parts[0] isEqualToString:@"ok"]) {
        NSString *when = WhenText([NSDate dateWithTimeIntervalSince1970:[parts[1] doubleValue]]);
        text = [NSString stringWithFormat:T(@"上次自动解锁成功（%@）", @"Last auto-unlock succeeded (%@)"), when];
        color = [UIColor systemGreenColor];
    } else if (saved && parts.count == 2 && [parts[0] isEqualToString:@"rejected"]) {
        text = T(@"上次密码被拒绝，请重新保存正确的密码", @"The saved passcode was rejected; save it again");
        color = [UIColor systemRedColor];
    }
    SetText(self.unlockLabel, text);
    SetColor(self.unlockLabel, color);
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
        UILabel *empty = Label(UIFontTextStyleFootnote, NO, [UIColor secondaryLabelColor]);
        empty.text = T(@"还没有远程连接记录", @"No remote sessions yet");
        [self.historyRows addArrangedSubview:empty];
        return;
    }
    for (NSArray<NSString *> *item in items) {
        UILabel *when = Label(UIFontTextStyleSubheadline, NO, [UIColor labelColor]);
        when.text = item[0];
        UILabel *duration = Label(UIFontTextStyleSubheadline, NO, [UIColor secondaryLabelColor]);
        duration.text = item[1];
        duration.textAlignment = NSTextAlignmentRight;
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[when, duration]];
        row.spacing = 12;
        row.alignment = UIStackViewAlignmentFirstBaseline;
        row.isAccessibilityElement = YES;
        row.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", item[0], item[1]];
        [self.historyRows addArrangedSubview:row];
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
