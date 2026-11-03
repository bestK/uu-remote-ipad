// Home-screen panel for the iPad UU host: shows the login QR the daemon writes and keeps the
// lock-screen passcode the host uses to unlock the iPad when a viewer connects.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const kStatusPath = @"/private/var/tmp/uu-status.txt";
static NSString *const kQRPath = @"/private/var/tmp/uu-qr.png";
// Read by the host (root) only to unlock; never leaves the device.
static NSString *const kPasscodeDir = @"/var/mobile/Library/UURemote";
static NSString *const kPasscodePath = @"/var/mobile/Library/UURemote/unlock.key";
static NSString *const kUnlockStatusPath = @"/private/var/tmp/uu-unlock.txt";

@interface PanelController : UIViewController
@property(nonatomic) UIImageView *qrView;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UILabel *hintLabel;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) UITextField *passcodeField;
@property(nonatomic) UILabel *unlockLabel;
@end

@implementation PanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"UU 远程 · iPad 宿主";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    self.qrView = [[UIImageView alloc] init];
    self.qrView.contentMode = UIViewContentModeScaleAspectFit;
    self.qrView.backgroundColor = [UIColor whiteColor];
    self.qrView.layer.cornerRadius = 14;
    self.qrView.clipsToBounds = YES;
    self.qrView.layer.magnificationFilter = kCAFilterNearest;
    self.qrView.layer.minificationFilter = kCAFilterNearest;
    self.qrView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.qrView];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.text = @"用手机上的「网易UU远程」App 扫码，并在手机上确认登录。\n登录成功后本机自动上线，无需其它操作。";
    self.hintLabel.font = [UIFont systemFontOfSize:13];
    self.hintLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.hintLabel];

    UILabel *unlockTitle = [[UILabel alloc] init];
    unlockTitle.text = @"自动解锁";
    unlockTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    unlockTitle.textColor = [UIColor whiteColor];
    unlockTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:unlockTitle];

    self.passcodeField = [[UITextField alloc] init];
    self.passcodeField.placeholder = @"iPad 锁屏密码";
    self.passcodeField.secureTextEntry = YES;
    self.passcodeField.keyboardType = UIKeyboardTypeASCIICapable;
    self.passcodeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.passcodeField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.passcodeField.textContentType = UITextContentTypeOneTimeCode; // keep it out of AutoFill/Keychain prompts
    self.passcodeField.borderStyle = UITextBorderStyleRoundedRect;
    self.passcodeField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.passcodeField];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存" forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [save addTarget:self action:@selector(savePasscode) forControlEvents:UIControlEventTouchUpInside];
    save.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:save];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setTitle:@"清除" forState:UIControlStateNormal];
    [clear setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:16];
    [clear addTarget:self action:@selector(clearPasscode) forControlEvents:UIControlEventTouchUpInside];
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:clear];

    self.unlockLabel = [[UILabel alloc] init];
    self.unlockLabel.font = [UIFont systemFontOfSize:13];
    self.unlockLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    self.unlockLabel.numberOfLines = 0;
    self.unlockLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.unlockLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:28],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [self.qrView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:24],
        [self.qrView.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.qrView.widthAnchor constraintEqualToAnchor:safe.widthAnchor multiplier:0.62],
        [self.qrView.heightAnchor constraintEqualToAnchor:self.qrView.widthAnchor],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.qrView.bottomAnchor constant:24],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [self.hintLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
        [self.hintLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:32],
        [self.hintLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-32],

        [unlockTitle.topAnchor constraintEqualToAnchor:self.hintLabel.bottomAnchor constant:36],
        [unlockTitle.leadingAnchor constraintEqualToAnchor:self.passcodeField.leadingAnchor],

        [self.passcodeField.topAnchor constraintEqualToAnchor:unlockTitle.bottomAnchor constant:10],
        [self.passcodeField.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor constant:-60],
        [self.passcodeField.widthAnchor constraintEqualToConstant:280],
        [self.passcodeField.heightAnchor constraintEqualToConstant:40],

        [save.leadingAnchor constraintEqualToAnchor:self.passcodeField.trailingAnchor constant:16],
        [save.centerYAnchor constraintEqualToAnchor:self.passcodeField.centerYAnchor],
        [clear.leadingAnchor constraintEqualToAnchor:save.trailingAnchor constant:16],
        [clear.centerYAnchor constraintEqualToAnchor:self.passcodeField.centerYAnchor],

        [self.unlockLabel.topAnchor constraintEqualToAnchor:self.passcodeField.bottomAnchor constant:10],
        [self.unlockLabel.leadingAnchor constraintEqualToAnchor:self.passcodeField.leadingAnchor],
        [self.unlockLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-32],
    ]];

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)savePasscode {
    NSString *code = self.passcodeField.text ?: @"";
    if (code.length == 0) { self.unlockLabel.text = @"请先输入锁屏密码。"; return; }
    [[NSFileManager defaultManager] createDirectoryAtPath:kPasscodeDir withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
    // Create 0600 before writing, so the passcode is never readable by others even briefly.
    int fd = open(kPasscodePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    NSData *data = [code dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok = fd >= 0 && fchmod(fd, 0600) == 0 && write(fd, data.bytes, data.length) == (ssize_t)data.length;
    if (fd >= 0) close(fd);
    self.passcodeField.text = @"";
    [self.passcodeField resignFirstResponder];
    if (!ok) { self.unlockLabel.text = @"保存失败，请重试。"; return; }
    [[NSFileManager defaultManager] removeItemAtPath:kUnlockStatusPath error:nil];
    [self refreshUnlock];
}

- (void)clearPasscode {
    [[NSFileManager defaultManager] removeItemAtPath:kPasscodePath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:kUnlockStatusPath error:nil];
    self.passcodeField.text = @"";
    [self.passcodeField resignFirstResponder];
    [self refreshUnlock];
}

- (void)refreshUnlock {
    BOOL saved = [[NSFileManager defaultManager] fileExistsAtPath:kPasscodePath];
    NSString *line = [[NSString stringWithContentsOfFile:kUnlockStatusPath encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *last = @"";
    if (parts.count == 2) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"M月d日 HH:mm";
        NSString *when = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[parts[1] doubleValue]]];
        last = [parts[0] isEqualToString:@"ok"]
            ? [NSString stringWithFormat:@"\n上次自动解锁成功（%@）", when]
            : [NSString stringWithFormat:@"\n%@ 密码被拒绝，已停止自动解锁，请重新保存正确的密码。", when];
    }
    self.unlockLabel.text = saved
        ? [@"已保存。远程连接时如果 iPad 处于锁屏，会自动解锁。" stringByAppendingString:last]
        : @"未保存。保存后，远程连接时 iPad 会自动解锁；密码只存在本机。";
}

- (void)refresh {
    [self refreshUnlock];
    NSString *status = [NSString stringWithContentsOfFile:kStatusPath encoding:NSUTF8StringEncoding error:nil];
    status = [status stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([status isEqualToString:@"logged-in"]) {
        self.qrView.image = nil;
        self.qrView.hidden = YES;
        self.statusLabel.text = @"已登录，设备已上线";
        self.hintLabel.text = @"在手机或电脑的「网易UU远程」里选择这台 iPad 即可连接。";
        return;
    }
    NSData *png = [NSData dataWithContentsOfFile:kQRPath];
    UIImage *image = png.length ? [UIImage imageWithData:png] : nil;
    self.qrView.hidden = image == nil;
    if (image) self.qrView.image = image;
    self.statusLabel.text = image ? @"等待扫码登录" : @"宿主未运行或正在生成二维码…";
    self.hintLabel.text = @"用手机上的「网易UU远程」App 扫码，并在手机上确认登录。\n登录成功后本机自动上线，无需其它操作。";
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
