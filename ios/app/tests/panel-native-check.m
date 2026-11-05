// 以同一份生产视图构建 UIKit/Catalyst 检查，不冒充 iPad 模拟器截图。
#define main PanelOriginalMain
#import "PanelUnderTest.m"
#undef main

static NSMutableArray<NSDictionary *> *checks;
static void Check(BOOL ok, NSString *name) {
    [checks addObject:@{@"name": name, @"passed": @(ok)}];
}

@interface NativeCheckDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) PanelController *panel;
@property(nonatomic) UIViewController *container;
@property(nonatomic) NSMutableArray<NSDictionary *> *captures;
@end

@implementation NativeCheckDelegate

- (void)fixture:(NSString *)state {
    [self fixture:state hostVersion:PanelVersion()];
}

- (void)fixture:(NSString *)state hostVersion:(NSString *)hostVersion {
    BOOL down = [state isEqualToString:@"offline"];
    BOOL waiting = [state isEqualToString:@"waiting"];
    NSMutableDictionary *status = [@{@"updated": @([[NSDate date] timeIntervalSince1970] - (down ? 30 : 0)),
        @"signed_in": @(!waiting && !down), @"viewers": @([state isEqualToString:@"active"] ? 2 : 0)} mutableCopy];
    if (hostVersion) status[@"version"] = hostVersion;
    [[NSJSONSerialization dataWithJSONObject:status options:0 error:nil] writeToFile:kStatusJSONPath atomically:YES];
    [(waiting ? @"waiting-scan" : @"online") writeToFile:kStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:kHistoryPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // Every fixture state is an installed service; an offline one keeps its launch job (leftovers to uninstall).
    NSString *plist = [JailbreakRoot() stringByAppendingPathComponent:@"Library/LaunchDaemons/com.uuremote.host.plist"];
    [[NSFileManager defaultManager] createDirectoryAtPath:plist.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@"synthetic" writeToFile:plist atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)capture:(NSString *)name size:(CGSize)size tab:(NSUInteger)tab dark:(BOOL)dark large:(BOOL)large {
    name = [name stringByAppendingString:UU_TEST_SUFFIX];
    self.panel.selectedIndex = tab;
    self.container.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    UITraitCollection *type = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:
        large ? UIContentSizeCategoryAccessibilityExtraExtraExtraLarge : UIContentSizeCategoryLarge];
    [self.container setOverrideTraitCollection:type forChildViewController:self.panel];
    self.panel.view.frame = (CGRect){CGPointZero, size};
    [self.panel.view setNeedsLayout];
    [self.panel.view layoutIfNeeded];
    UIScrollView *scroll = self.panel.scrollViews[tab];
    [scroll setContentOffset:CGPointMake(0, -scroll.adjustedContentInset.top) animated:NO];
    [self.panel.view layoutIfNeeded];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [self.panel.view.layer renderInContext:context.CGContext];
    }];
    NSString *path = [UU_REVIEW_DIR stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    Check([UIImagePNGRepresentation(image) writeToFile:path atomically:YES], [@"渲染：" stringByAppendingString:name]);
    Check(scroll.contentSize.width <= size.width + 1, [@"无横向滚动：" stringByAppendingString:name]);
    UIView *page = scroll.subviews.firstObject;
    Check(tab == 3 || fabs(page.bounds.size.width - size.width) < 1,
        [@"页面内容通栏：" stringByAppendingString:name]);
    UIView *card = tab == 0 ? self.panel.accountCard
        : tab == 1 ? self.panel.unlockCard : tab == 2 ? self.panel.shortcutRows.superview.superview
        : self.panel.logText.superview.superview;
    Check(fabs(card.bounds.size.width - MIN(680, size.width - 40)) < 1,
        [@"卡片宽度遵循断点：" stringByAppendingString:name]);
    if (tab == 1) {
        UIView *serviceCard = self.panel.uninstallButton.superview.superview;
        Check(fabs(serviceCard.bounds.size.width - MIN(680, size.width - 40)) < 1,
            [@"宿主服务卡宽度遵循断点：" stringByAppendingString:name]);
    }
    if (tab == 0) {
        Check(fabs(self.panel.statusPlate.bounds.size.width - MIN(680, size.width - 40)) < 1
            && fabs(self.panel.statusPlate.layer.cornerRadius - 28) < 1,
            [@"状态主卡遵循28pt圆角与断点：" stringByAppendingString:name]);
    }
    Check(!self.panel.floatingBar.hidden && self.panel.floatingTabButtons.count == 4,
        [@"底部悬浮胶囊栏：" stringByAppendingString:name]);
    [self.captures addObject:@{@"path": path, @"renderer": @"UIKit / Mac Catalyst, not iPad Simulator",
        @"synthetic": @YES, @"tab": @(tab), @"largeType": @(large), @"dark": @(dark),
        @"scrollFrame": NSStringFromCGRect(scroll.frame), @"panelFrame": NSStringFromCGRect(self.panel.view.frame),
        @"scrollContent": NSStringFromCGSize(scroll.contentSize),
        @"typeCategory": self.panel.traitCollection.preferredContentSizeCategory,
        @"statusFont": @(self.panel.statusLabel.font.pointSize)}];
}

- (void)waitForServiceOperation {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (self.panel.serviceBusy && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Check(!self.panel.serviceBusy, @"服务操作回到主线程并结束忙碌状态");
}

- (void)runChecks {
    checks = [NSMutableArray array];
    self.captures = [NSMutableArray array];
    Check(self.panel.viewControllers.count == 4, @"原生四栏导航（含日志）");
    Check(self.panel.shortcutKeyTexts.count == 9, @"保留九项快捷键");
    Check(self.panel.shortcutRows.arrangedSubviews.count == 9, @"快捷键行与数据一致");
    Check(self.panel.displayedState == HostOnline, @"在线状态");
    Check(self.panel.statusBadgePill.hidden && [self.panel.statusLabel.text isEqualToString:T(@"服务运行中", @"Service Running")],
        @"在线状态仅显示一次，隐藏重复胶囊");
    Check(self.panel.installCard.hidden, @"在线时隐藏安装入口");
    Check(self.panel.lastSessionRow.hidden, @"无连接记录时隐藏状态卡摘要，只保留列表空态");
    Check(self.panel.logoutButton.enabled, @"已登录时允许退出");
    Check(self.panel.uninstallButton.enabled, @"在线时可卸载宿主服务");
    [self capture:@"tablet-light" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];
    [self capture:@"tablet-dark" size:CGSizeMake(768, 1024) tab:0 dark:YES large:NO];

    double now = [[NSDate date] timeIntervalSince1970];
    Check(HostStatusFresh(@{@"updated": @(now - kStaleAfter)}, now)
        && HostStatusFresh(@{@"updated": @(now + kStaleAfter)}, now), @"心跳新鲜度包含前后边界");
    Check(!HostStatusFresh(@{@"updated": @(now - kStaleAfter - 1)}, now)
        && !HostStatusFresh(@{@"updated": @(now + kStaleAfter + 1)}, now)
        && !HostStatusFresh(@{@"updated": @0}, now) && !HostStatusFresh(@{}, now), @"陈旧、过远未来和缺失心跳不可用");
    NSString *alternateStatus = HostTmpPath(kStatusJSONPath, YES);
    [[NSFileManager defaultManager] createDirectoryAtPath:alternateStatus.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *alt = @{@"updated": @(now), @"signed_in": @NO, @"viewers": @0};
    [[NSJSONSerialization dataWithJSONObject:alt options:0 error:nil] writeToFile:alternateStatus atomically:YES];
    [self.panel refresh];
    Check(!self.panel.hostFilesFromRootfs && self.panel.displayedState == HostOnline, @"直接视图新鲜时优先直接视图");
    [self fixture:@"offline"];
    [self.panel refresh];
    Check(self.panel.hostFilesFromRootfs && self.panel.displayedState == HostWaiting, @"直接视图陈旧时使用新鲜 rootfs 视图");
    alt = @{@"updated": @(now + kStaleAfter + 60), @"signed_in": @YES};
    [[NSJSONSerialization dataWithJSONObject:alt options:0 error:nil] writeToFile:alternateStatus atomically:YES];
    [self.panel refresh];
    Check(!self.panel.hostFilesFromRootfs && self.panel.displayedState == HostDown, @"过远未来 rootfs 不覆盖陈旧直接视图");
    [[NSFileManager defaultManager] removeItemAtPath:alternateStatus error:nil];
    [self fixture:@"active"];
    [self.panel refresh];
    Check(self.panel.displayedState == HostActive, @"远控状态");
    Check(self.panel.statusBadgePill.hidden, @"状态由主标题单一呈现，全状态避免一个字段两个状态");
    Check([self.panel.stateDetail.text containsString:@"2"], @"连接数来自状态文件");
    NSArray *history = @[@{@"at": @([[NSDate date] timeIntervalSince1970] - 120), @"duration_s": @720}];
    [self.panel refreshHistory:history];
    Check(!self.panel.lastSessionRow.hidden && [self.panel.lastSessionLabel.text containsString:@"·"],
        @"状态卡摘要与连接记录同源，不再各自维护");
    [self capture:@"tablet-active" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];

    [self fixture:@"waiting"];
    [self.panel refresh];
    Check(self.panel.displayedState == HostWaiting && !self.panel.qrGroup.hidden, @"扫码状态");
    Check(self.panel.qrView.hidden && self.panel.logoutButton.enabled
        && [[self.panel.logoutButton titleForState:UIControlStateNormal] isEqualToString:T(@"扫码登录", @"Sign In")],
        @"未登录隐藏空图且账号入口切换为扫码登录");
    [self capture:@"tablet-waiting-empty" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];
    // 使用系统符号生成不可用于登录的合成图，只检查尺寸和显隐。
    UIGraphicsImageRenderer *qr = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(200, 200)];
    UIImage *synthetic = [qr imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [[UIColor whiteColor] setFill];
        [c fillRect:CGRectMake(0, 0, 200, 200)];
        UIImage *symbol = [[UIImage systemImageNamed:@"qrcode"] imageWithTintColor:[UIColor blackColor]
            renderingMode:UIImageRenderingModeAlwaysOriginal];
        [symbol drawInRect:CGRectMake(20, 20, 160, 160)];
    }];
    [UIImagePNGRepresentation(synthetic) writeToFile:kQRPath atomically:YES];
    [self.panel refresh];
    Check(!self.panel.qrView.hidden && self.panel.qrView.image != nil, @"合成二维码图读取与显示");
    [self capture:@"tablet-waiting" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];
    Check(fabs(self.panel.qrView.bounds.size.width - 200) < 1
        && fabs(self.panel.qrView.bounds.size.height - 200) < 1, @"合成二维码保持200点尺寸");
    [self capture:@"tablet-waiting-narrow" size:CGSizeMake(375, 812) tab:0 dark:YES large:NO];
    NSString *alternateQR = HostTmpPath(kQRPath, YES);
    [[NSFileManager defaultManager] createDirectoryAtPath:alternateQR.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    [UIImagePNGRepresentation(synthetic) writeToFile:alternateQR atomically:YES];
    NSDate *sameQRTime = [[NSFileManager defaultManager] attributesOfItemAtPath:kQRPath error:nil].fileModificationDate;
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: sameQRTime} ofItemAtPath:alternateQR error:nil];
    [self.panel refreshLogin];
    [self fixture:@"offline"];
    alt = @{@"updated": @([[NSDate date] timeIntervalSince1970]), @"signed_in": @NO};
    [[NSJSONSerialization dataWithJSONObject:alt options:0 error:nil] writeToFile:alternateStatus atomically:YES];
    [self.panel refresh];
    Check(self.panel.hostFilesFromRootfs && self.panel.qrView.image == nil && self.panel.requestingLogin,
        @"切换视图后不复用刷新前的 rootfs 二维码");
    [UIImagePNGRepresentation(synthetic) writeToFile:alternateQR atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: sameQRTime} ofItemAtPath:alternateQR error:nil];
    [self.panel refresh];
    Check(self.panel.qrView.image != nil && !self.panel.requestingLogin, @"rootfs 同时间戳原子替换识别为新二维码");
    [[NSFileManager defaultManager] removeItemAtPath:alternateStatus error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:kCommandPath error:nil];
    [self fixture:@"waiting"];
    [self.panel refresh];
    Check(!self.panel.hostFilesFromRootfs && self.panel.qrView.image != nil, @"切回直接视图重新读取二维码");

    [self fixture:@"online"];
    [self.panel refresh];
    Check(self.panel.qrView.image == nil && self.panel.qrGroup.hidden, @"登录完成后清除二维码视图");
    [self.panel refreshLogin];
    Check(![[NSFileManager defaultManager] fileExistsAtPath:kCommandPath], @"已登录时刷新二维码不触发退出或重启");
    [self.panel logout];
    Check(self.panel.loggingOut && !self.panel.logoutButton.enabled && self.panel.qrView.image == nil
        && [Trimmed([NSString stringWithContentsOfFile:kCommandPath encoding:NSUTF8StringEncoding error:nil]) isEqualToString:@"logout"],
        @"退出仅写入命令并等待后台确认，不显示旧二维码");
    [self.panel refresh];
    Check(self.panel.loggingOut, @"后台仍报告已登录时保持退出等待");
    [self fixture:@"offline"];
    [self.panel refresh];
    Check(self.panel.loggingOut && self.panel.installCard.hidden, @"退出重启期间不误显示服务安装");
    [[NSFileManager defaultManager] removeItemAtPath:kCommandPath error:nil];
    [self fixture:@"waiting"];
    [self.panel refresh];
    Check(!self.panel.loggingOut && self.panel.requestingLogin && self.panel.qrView.image == nil
        && self.panel.logoutButton.enabled, @"后台确认退出后在App里等待新二维码，拒绝复用旧码");
    NSDate *oldModified = [[NSFileManager defaultManager] attributesOfItemAtPath:kQRPath error:nil].fileModificationDate;
    [UIImagePNGRepresentation(synthetic) writeToFile:kQRPath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:oldModified} ofItemAtPath:kQRPath error:nil];
    [self.panel refresh];
    Check(self.panel.qrView.image != nil && !self.panel.requestingLogin && self.panel.refreshLoginButton.enabled,
        @"退出后的新二维码直接显示，同时间戳的原子替换也可识别");
    self.panel.selectedIndex = 1;
    [self.panel accountAction];
    Check(self.panel.selectedIndex == 0 && self.panel.qrView.image != nil, @"扫码登录入口回到App内二维码而非外部网页");
    [self capture:@"tablet-relogin" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];
    [self.panel refreshLogin];
    Check(self.panel.requestingLogin && self.panel.qrView.image == nil && !self.panel.refreshLoginButton.enabled
        && [Trimmed([NSString stringWithContentsOfFile:kCommandPath encoding:NSUTF8StringEncoding error:nil]) isEqualToString:@"refresh-login"],
        @"刷新写入专用命令，清除旧视图并阻止重复刷新");
    [[NSFileManager defaultManager] removeItemAtPath:kCommandPath error:nil];
    self.panel.loginDeadline = [NSDate dateWithTimeIntervalSinceNow:-1];
    [self.panel refresh];
    Check(!self.panel.requestingLogin && !self.panel.accountResult.hidden && self.panel.refreshLoginButton.enabled,
        @"二维码超时可见且允许重试");
    [@"qr-error\n" writeToFile:kStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.panel refresh];
    Check([self.panel.accountResult.text isEqualToString:T(@"二维码加载失败，请刷新", @"Couldn't load QR code; refresh to retry")],
        @"后台二维码失败可在App内刷新重试");
    [@"qr-expired\n" writeToFile:kStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.panel refresh];
    Check([self.panel.accountResult.text isEqualToString:T(@"二维码已失效，请刷新", @"QR code expired; refresh to retry")]
        && self.panel.refreshLoginButton.enabled, @"只有服务端确认过期时显示失效并允许刷新");
    [self fixture:@"online"];
    [self.panel refresh];
    Check(self.panel.signedIn && self.panel.accountResult.hidden && self.panel.qrGroup.hidden
        && [[self.panel.logoutButton titleForState:UIControlStateNormal] isEqualToString:T(@"退出登录", @"Sign Out")],
        @"重新扫码登录完成后恢复账号状态并隐藏二维码");
    [self.panel logout];
    [[NSFileManager defaultManager] removeItemAtPath:kCommandPath error:nil];
    [@"error-logout\n" writeToFile:kStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.panel refresh];
    Check(!self.panel.loggingOut && self.panel.logoutButton.enabled && !self.panel.accountResult.hidden,
        @"后台退出失败不伪装成退出成功");
    [self fixture:@"online"];
    [self.panel logout];
    self.panel.logoutDeadline = [NSDate dateWithTimeIntervalSinceNow:-1];
    [self.panel refresh];
    Check(!self.panel.loggingOut && self.panel.logoutButton.enabled
        && [self.panel.accountResult.text isEqualToString:T(@"退出超时，请重试", @"Sign-out timed out; try again")],
        @"退出超时恢复重试而非永久等待");
    [[NSFileManager defaultManager] removeItemAtPath:kCommandPath error:nil];
    [self fixture:@"online"];
    [self.panel refresh];
    Check([self.panel.versionLabel.text containsString:PanelVersion()]
        && ![self.panel.versionLabel.text containsString:@"\n"], @"面板与宿主版本一致时只显示版本号");
    [self fixture:@"online" hostVersion:@"ipad-v0.0.1"];
    [self.panel refresh];
    Check([self.panel.versionLabel.text containsString:@"ipad-v0.0.1"]
        && [self.panel.versionLabel.text containsString:T(@"版本不一致，请重新安装宿主服务", @"Versions differ; reinstall the host service")],
        @"宿主版本不同时提示重新安装服务");
    [self fixture:@"online" hostVersion:nil];
    [self.panel refresh];
    Check([self.panel.versionLabel.text containsString:T(@"版本不一致", @"Versions differ")]
        && ![self.panel.versionLabel.text containsString:T(@"未运行", @"not running")],
        @"旧宿主提示版本不一致且不自相矛盾显示未运行");
    [self fixture:@"offline"];
    [self.panel refresh];
    Check(self.panel.displayedState == HostDown && self.panel.installCard.hidden
        && [self.panel.accountLabel.text isEqualToString:T(@"状态未知", @"Status unknown")], @"陈旧状态未知且保留已有服务");
    Check([self.panel.versionLabel.text containsString:T(@"状态未知", @"status unknown")]
        && ![self.panel.versionLabel.text containsString:T(@"版本不一致", @"Versions differ")],
        @"陈旧状态的宿主版本未知而非断言未运行");
    Check(self.panel.qrGroup.hidden, @"离开扫码状态时隐藏二维码");
    Check(self.panel.uninstallButton.enabled, @"服务离线时仍可卸载残留文件");
    // Signing out while online and losing the host: the "try again" text has no button to retry.
    [self fixture:@"online"];
    [self.panel refresh];
    [self.panel logout];
    [self fixture:@"offline"];
    self.panel.logoutDeadline = [NSDate dateWithTimeIntervalSinceNow:-1];
    [self.panel refresh];
    Check(self.panel.accountResult.hidden, @"服务离线时不显示无法重试的退出提示");
    [[NSFileManager defaultManager] removeItemAtPath:kCommandPath error:nil];
    [self fixture:@"offline"];
    [self.panel refresh];
    [self capture:@"tablet-offline" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];
    [self capture:@"tablet-narrow" size:CGSizeMake(375, 812) tab:0 dark:NO large:NO];
    [self capture:@"tablet-offline-large" size:CGSizeMake(768, 1024) tab:0 dark:NO large:YES];

    [self.panel textField:self.panel.passcodeField shouldChangeCharactersInRange:NSMakeRange(0, 0) replacementString:@"2468"];
    Check([self.panel.passcodeField.text isEqualToString:@"••••"] && self.panel.saveButton.enabled, @"密码遮罩与保存按钮");
    [self.panel savePasscode];
    struct stat st;
    Check(stat(kPasscodePath.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0600, @"密码仍以0600保存在隔离路径");
    Check(!self.panel.passcode.length && !self.panel.saveButton.enabled && self.panel.clearButton.enabled, @"保存后清空输入并更新按钮");
    [@"rejected 1" writeToFile:kUnlockStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.panel refreshUnlock];
    [self capture:@"tablet-security" size:CGSizeMake(768, 1024) tab:1 dark:NO large:NO];
    [self capture:@"tablet-security-large" size:CGSizeMake(375, 812) tab:1 dark:YES large:YES];

    Check(!self.panel.uninstallButton.hidden && self.panel.uninstallButton.bounds.size.height >= 44,
        @"卸载入口位于安全页且触摸高度至少44点");
    [self.panel confirmUninstall];
    UIAlertController *confirmation = (UIAlertController *)self.panel.presentedViewController;
    Check([confirmation isKindOfClass:[UIAlertController class]] && confirmation.actions.count == 2,
        @"卸载需要原生二次确认且可以取消");
    Check(confirmation.textFields.firstObject.secureTextEntry, @"卸载确认的sudo密码安全输入");
    Check(fixtureServiceCalls == 0, @"仅打开卸载确认不执行服务操作");
    [self.panel dismissViewControllerAnimated:NO completion:nil];

    fixtureServiceOK = NO;
    [self.panel runServiceOperation:YES password:@"synthetic-password"];
    Check(self.panel.uninstalling && !self.panel.uninstallButton.enabled
        && !self.panel.installButton.enabled && !self.panel.installField.enabled, @"卸载期间禁止重复卸载与并发安装");
    [self.panel installService];
    [self waitForServiceOperation];
    Check(fixtureServiceCalls == 1 && [fixtureServiceScript isEqualToString:@"uninstall-service.sh"]
        && !fixtureDefaultPassword, @"卸载运行正确脚本且阻止并发安装");
    Check([self.panel.uninstallResult.text isEqualToString:T(@"卸载失败，请重试", @"Uninstall failed; try again")]
        && !self.panel.uninstallOutput.hidden && self.panel.uninstallButton.enabled, @"卸载失败显示结果并可重试");
    [self capture:@"tablet-uninstall-failed" size:CGSizeMake(375, 812) tab:1 dark:YES large:NO];

    fixtureServiceTimeout = YES;
    [self.panel runServiceOperation:YES password:@"synthetic-password"];
    [self waitForServiceOperation];
    Check([self.panel.uninstallResult.text isEqualToString:T(@"卸载超时，请重试", @"Uninstall timed out; try again")],
        @"卸载超时不显示成功");
    fixtureServiceOK = YES;
    fixtureServiceTimeout = NO;
    [self.panel.installPassword setString:@"synthetic-password"];
    [self.panel runServiceOperation:YES password:@"synthetic-password"];
    [self waitForServiceOperation];
    Check([self.panel.uninstallResult.text isEqualToString:T(@"卸载完成", @"Uninstalled")]
        && self.panel.installButton.enabled && self.panel.installCard.hidden
        && !self.panel.installFinished && !self.panel.installPassword.length, @"模拟卸载完成清空输入；残留启动项仍视为已安装");
    [self capture:@"tablet-uninstalled" size:CGSizeMake(768, 1024) tab:1 dark:NO large:NO];
    // The uninstall script deletes the status files; with no launch job left the card offers install.
    NSDictionary *savedStatus = ReadJSONDict(kStatusJSONPath);
    NSString *plist = [JailbreakRoot() stringByAppendingPathComponent:@"Library/LaunchDaemons/com.uuremote.host.plist"];
    [[NSFileManager defaultManager] removeItemAtPath:kStatusJSONPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:plist error:nil];
    [self.panel refresh];
    Check(!self.panel.serviceInstallButton.hidden && self.panel.uninstallButton.hidden && self.panel.restartButton.hidden
        && [self.panel.uninstallResult.text isEqualToString:T(@"卸载完成", @"Uninstalled")], @"卸载后安全页改为安装入口");
    [self capture:@"tablet-security-install" size:CGSizeMake(768, 1024) tab:1 dark:NO large:NO];
    NSUInteger callsBeforeInstall = fixtureServiceCalls;
    [self.panel confirmInstall];
    UIAlertController *installAlert = (UIAlertController *)self.panel.presentedViewController;
    Check([installAlert isKindOfClass:[UIAlertController class]] && installAlert.textFields.firstObject.secureTextEntry
        && fixtureServiceCalls == callsBeforeInstall, @"安全页安装需要确认与sudo密码安全输入");
    [self.panel dismissViewControllerAnimated:NO completion:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:plist.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@"synthetic" writeToFile:plist atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.panel refresh];
    Check(self.panel.serviceInstallButton.hidden && !self.panel.uninstallButton.hidden, @"服务离线但有残留启动项时仍可卸载");
    [[NSJSONSerialization dataWithJSONObject:savedStatus options:0 error:nil] writeToFile:kStatusJSONPath atomically:YES];
    [self.panel installService];
    Check(self.panel.installing && !self.panel.uninstallButton.enabled, @"安装期间禁止卸载");
    [self waitForServiceOperation];
    Check([fixtureServiceScript isEqualToString:@"install-service.sh"] && fixtureDefaultPassword
        && self.panel.installFinished && [self.panel.uninstallResult.text isEqualToString:T(@"安装完成", @"Installed")],
        @"重新安装仍用原脚本与默认密码且以安装结果替换旧卸载结果");
    fixtureServiceOK = NO;
    fixtureServiceOutput = @"different Frida agent at alternate path; not overwriting";
    [self.panel runService:ServiceInstall password:@"synthetic-password"];
    [self waitForServiceOperation];
    Check([self.panel.uninstallResult.text isEqualToString:T(@"其他 Frida 组件冲突，未覆盖", @"Existing Frida agent differs; not overwritten")],
        @"已有不同 Frida 组件时用当前语言解释安装失败");
    fixtureServiceOutput = nil;
    fixtureServiceOK = YES;

    NSUInteger callsBeforeRestart = fixtureServiceCalls;
    [self.panel confirmRestart];
    UIAlertController *restartAlert = (UIAlertController *)self.panel.presentedViewController;
    Check([restartAlert isKindOfClass:[UIAlertController class]] && restartAlert.actions.count == 2
        && restartAlert.textFields.firstObject.secureTextEntry && fixtureServiceCalls == callsBeforeRestart, @"重启需要确认与sudo密码安全输入");
    [self.panel dismissViewControllerAnimated:NO completion:nil];
    fixtureServiceOK = NO;
    [self.panel runService:ServiceRestart password:@"synthetic-password"];
    Check(self.panel.restarting && !self.panel.restartButton.enabled && !self.panel.uninstallButton.enabled
        && !self.panel.installButton.enabled, @"重启期间禁止其他服务操作");
    [self waitForServiceOperation];
    Check([fixtureServiceScript isEqualToString:@"restart-service.sh"]
        && [self.panel.uninstallResult.text isEqualToString:T(@"重启失败，请重试", @"Restart failed; try again")]
        && self.panel.restartButton.enabled, @"重启运行重启脚本，失败显示结果并可重试");
    fixtureServiceOK = YES;
    [self.panel runService:ServiceRestart password:@"synthetic-password"];
    [self waitForServiceOperation];
    Check([self.panel.uninstallResult.text isEqualToString:T(@"已重启", @"Restarted")], @"重启成功显示结果");

    NSString *logDir = [JailbreakRoot() stringByAppendingPathComponent:@"var/log"];
    [[NSFileManager defaultManager] removeItemAtPath:logDir error:nil];
    self.panel.selectedIndex = 3;
    Check([self.panel.logText.text isEqualToString:T(@"还没有日志：宿主服务未安装或尚未启动。", @"No log yet: the host service is not installed or has not started.")]
        && !self.panel.logCopyButton.enabled && !self.panel.logShareButton.enabled, @"无日志时提示且禁止复制分享");
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    [@"synthetic host line 1\nsynthetic host line 2\n" writeToFile:[logDir stringByAppendingPathComponent:@"uuremote.log"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"synthetic frida line\n" writeToFile:[logDir stringByAppendingPathComponent:@"frida-server.log"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.panel reloadLog];
    Check([self.panel.logTimezoneLabel.text isEqualToString:T(@"时间末尾的 Z 表示 UTC", @"Timestamps ending in Z use UTC")]
        && [[self.panel logExport] containsString:@"(UTC)"], @"日志时区说明与导出头标注 UTC");
    Check([self.panel.logText.text containsString:@"synthetic host line 2"] && self.panel.logCopyButton.enabled
        && [self.panel.logPathLabel.text hasSuffix:@"var/log/uuremote.log"], @"日志页显示宿主日志与路径");
    [self.panel copyLog];
    NSString *copied = [UIPasteboard generalPasteboard].string;
    Check([copied hasPrefix:@"# UURemotePanel "] && [copied containsString:@"synthetic host line 1"],
        @"复制日志附带版本头与日志内容");
    self.panel.logSource.selectedSegmentIndex = 1;
    [self.panel reloadLog];
    Check([self.panel.logText.text containsString:@"synthetic frida line"], @"切换到 frida-server 日志");
    self.panel.logSource.selectedSegmentIndex = 0;
    [self.panel reloadLog];
    [self capture:@"tablet-logs" size:CGSizeMake(768, 1024) tab:3 dark:NO large:NO];
    [self capture:@"tablet-logs-large" size:CGSizeMake(375, 812) tab:3 dark:YES large:YES];
    Check(self.panel.logShareButton.bounds.size.height >= 44 && self.panel.logText.bounds.size.height >= 120,
        @"日志按钮触摸高度至少44点且日志区可见");
    [self.panel shareLog];
    NSDate *shareDeadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!self.panel.selectedViewController.presentedViewController && shareDeadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check([self.panel.selectedViewController.presentedViewController isKindOfClass:[UIActivityViewController class]],
        @"点击分享显示系统分享面板");
    [self.panel.selectedViewController dismissViewControllerAnimated:NO completion:nil];
    [self.panel runDiagnostics:@"synthetic-password"];
    Check(self.panel.diagnosing && !self.panel.diagnoseButton.enabled, @"诊断运行时禁止重复执行");
    [self waitForServiceOperation];
    Check([fixtureServiceScript isEqualToString:@"diagnose-service.sh"]
        && [self.panel.logText.text isEqualToString:@"synthetic service result"]
        && [[self.panel logExport] containsString:@"synthetic service result"], @"诊断结果可查看和导出");
    [self.panel reloadLog];
    Check(self.panel.diagnosticOutput == nil && [self.panel.logText.text containsString:@"synthetic host line"], @"刷新返回日志");

    NSUInteger beforeClear = fixtureServiceCalls;
    [self.panel confirmClearLog];
    UIAlertController *clearAlert = (UIAlertController *)self.panel.presentedViewController;
    Check([clearAlert isKindOfClass:[UIAlertController class]] && clearAlert.textFields.firstObject.secureTextEntry
        && fixtureServiceCalls == beforeClear, @"清除日志需要确认且不立即执行");
    [self.panel dismissViewControllerAnimated:NO completion:nil];
    [self.panel clearLog:@"host" password:@"synthetic-password"];
    Check(self.panel.clearingLog && !self.panel.logClearButton.enabled && !self.panel.logSource.enabled, @"清除期间禁止重复执行和切换日志");
    [self waitForServiceOperation];
    Check([fixtureServiceScript isEqualToString:@"clear-log.sh"] && [fixtureServiceArgument isEqualToString:@"host"]
        && [self.panel.logPathLabel.text isEqualToString:T(@"日志已清除", @"Log cleared")], @"清除仅运行当前日志的脚本");
    fixtureServiceOK = NO;
    [self.panel clearLog:@"frida" password:@"synthetic-password"];
    [self waitForServiceOperation];
    Check([self.panel.logPathLabel.text isEqualToString:T(@"清除失败", @"Clear failed")] && self.panel.logClearButton.enabled,
        @"清除失败显示错误并可重试");
    fixtureServiceOK = YES;

    LogTextView *logView = (LogTextView *)self.panel.logText;
    NSMutableString *longLog = [NSMutableString string];
    for (int i = 0; i < 1000; i++) [longLog appendFormat:@"synthetic log line %d\n", i];
    logView.text = longLog;
    [logView layoutIfNeeded];
    [logView setContentOffset:CGPointZero animated:NO];
    [logView layoutIfNeeded];
    Check(!logView.scrollHandle.hidden && logView.scrollHandle.bounds.size.width >= 44, @"长日志有44点可拖动滚动条");
    logView.dragStartOffset = 0;
    logView.dragRange = logView.contentSize.height - logView.bounds.size.height;
    logView.dragTravel = logView.bounds.size.height - 16 - logView.scrollHandle.bounds.size.height;
    [logView scrollFromHandle:logView.dragTravel];
    Check(fabs(logView.contentOffset.y - logView.dragRange) < 1, @"拖动滚动条到末端跳到日志底部");
    [logView scrollFromHandle:0];
    Check(fabs(logView.contentOffset.y) < 1, @"拖回起点回到日志顶部");
    [logView.scrollHandle accessibilityIncrement];
    Check(logView.contentOffset.y > 0, @"滚动条支持辅助功能翻页");
    [longLog writeToFile:[logDir stringByAppendingPathComponent:@"uuremote.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self capture:@"tablet-logs-scroll" size:CGSizeMake(768, 1024) tab:3 dark:NO large:NO];
    [self capture:@"tablet-logs-scroll-dark" size:CGSizeMake(375, 812) tab:3 dark:YES large:NO];
    logView.text = @"short log";
    [logView layoutIfNeeded];
    Check(logView.scrollHandle.hidden, @"短日志隐藏滚动条");

    self.panel.lockSwitch.on = YES;
    [self.panel lockSwitchChanged];
    Check([ReadJSONDict(kSettingsPath)[@"lock_after_session"] boolValue], @"锁屏开关仍保存原有字段");
    [self.panel clearPasscode];
    Check(![[NSFileManager defaultManager] fileExistsAtPath:kPasscodePath] && !self.panel.clearButton.enabled, @"清除密码状态");
    self.panel.shortcutPlatform.selectedSegmentIndex = 1;
    [self.panel shortcutPlatformChanged];
    Check([self.panel.shortcutKeyTexts.firstObject isEqualToString:@"Cmd+C"], @"切换macOS快捷键");
    Check([self.panel.shortcutRows.arrangedSubviews.firstObject.accessibilityLabel containsString:@"Cmd+C"], @"快捷键无障碍同步");
    Check([self.panel.shortcutKeyTexts[7] containsString:@"Ctrl+Space"], @"macOS 输入法快捷键保留");
    [self capture:@"tablet-shortcuts" size:CGSizeMake(768, 1024) tab:2 dark:NO large:NO];
    [self capture:@"tablet-shortcuts-large" size:CGSizeMake(375, 812) tab:2 dark:NO large:YES];
    Check(WhenText([NSDate date]).length > 0 && DurationText(720).length > 0, @"记录时间与时长格式保留");
    [self.panel pauseRefresh];
    Check(self.panel.timer == nil, @"后台停止轮询");
    [self.panel resumeRefresh];
    Check(self.panel.timer.valid, @"前台恢复轮询");
    [self.panel pauseRefresh];

    NSDictionary *result = @{@"checks": checks, @"captures": self.captures,
        @"limitations": @[@"非iPad模拟器或实机截图", @"未运行安装器、登录或真实远控", @"减少动态效果需iPad实测",
            @"Catalyst大字号仅覆盖类别，字体未放大，不能视为iPad Dynamic Type验收",
            @"Catalyst标签栏在窗口工具栏，内容PNG不包含iPad底部标签栏"]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    NSString *resultName = [NSString stringWithFormat:@"native-check-results%@.json", UU_TEST_SUFFIX];
    [data writeToFile:[UU_REVIEW_DIR stringByAppendingPathComponent:resultName] atomically:YES];
    exit([checks filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"passed == NO"]].count ? 1 : 0);
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    [self fixture:@"online"];
    self.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 1024, 1366)];
    self.container = [UIViewController new];
    self.window.rootViewController = self.container;
    self.panel = [PanelController new];
    [self.container addChildViewController:self.panel];
    [self.container.view addSubview:self.panel.view];
    [self.panel didMoveToParentViewController:self.container];
    [self.window makeKeyAndVisible];
    [self.panel pauseRefresh];
    // 待 UIKit 完成原生导航初始化后批量检查；测试总耗时控制在60秒内。
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:NO block:^(NSTimer *timer) {
        [UIView setAnimationsEnabled:NO];
        [self runChecks];
    }];
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([NativeCheckDelegate class])); }
}
