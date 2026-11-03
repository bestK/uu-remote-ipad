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
    BOOL down = [state isEqualToString:@"offline"];
    BOOL waiting = [state isEqualToString:@"waiting"];
    NSDictionary *status = @{@"updated": @([[NSDate date] timeIntervalSince1970] - (down ? 30 : 0)),
        @"signed_in": @(!waiting && !down), @"viewers": @([state isEqualToString:@"active"] ? 2 : 0)};
    [[NSJSONSerialization dataWithJSONObject:status options:0 error:nil] writeToFile:kStatusJSONPath atomically:YES];
    [(waiting ? @"waiting-scan" : @"online") writeToFile:kStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:kHistoryPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
    Check(fabs(page.bounds.size.width - size.width) < 1,
        [@"页面内容通栏：" stringByAppendingString:name]);
    UIView *card = tab == 0 ? self.panel.accountCard
        : tab == 1 ? self.panel.unlockCard : self.panel.shortcutRows.superview.superview;
    Check(fabs(card.bounds.size.width - MIN(680, size.width - 40)) < 1,
        [@"卡片宽度遵循断点：" stringByAppendingString:name]);
    if (tab == 0) {
        Check(fabs(self.panel.statusPlate.bounds.size.width - MIN(680, size.width - 40)) < 1
            && fabs(self.panel.statusPlate.layer.cornerRadius - 28) < 1,
            [@"状态主卡遵循28pt圆角与断点：" stringByAppendingString:name]);
    }
    Check(!self.panel.floatingBar.hidden && self.panel.floatingTabButtons.count == 3,
        [@"底部悬浮胶囊栏：" stringByAppendingString:name]);
    [self.captures addObject:@{@"path": path, @"renderer": @"UIKit / Mac Catalyst, not iPad Simulator",
        @"synthetic": @YES, @"tab": @(tab), @"largeType": @(large), @"dark": @(dark),
        @"scrollFrame": NSStringFromCGRect(scroll.frame), @"panelFrame": NSStringFromCGRect(self.panel.view.frame),
        @"scrollContent": NSStringFromCGSize(scroll.contentSize),
        @"typeCategory": self.panel.traitCollection.preferredContentSizeCategory,
        @"statusFont": @(self.panel.statusLabel.font.pointSize)}];
}

- (void)runChecks {
    checks = [NSMutableArray array];
    self.captures = [NSMutableArray array];
    Check(self.panel.viewControllers.count == 3, @"原生三栏导航");
    Check(self.panel.shortcutKeyTexts.count == 9, @"保留九项快捷键");
    Check(self.panel.shortcutRows.arrangedSubviews.count == 9, @"快捷键行与数据一致");
    Check(self.panel.displayedState == HostOnline, @"在线状态");
    Check(self.panel.installCard.hidden, @"在线时隐藏安装入口");
    Check(self.panel.logoutButton.enabled, @"已登录时允许退出");
    [self capture:@"tablet-light" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];
    [self capture:@"tablet-dark" size:CGSizeMake(768, 1024) tab:0 dark:YES large:NO];

    [self fixture:@"active"];
    [self.panel refresh];
    Check(self.panel.displayedState == HostActive, @"远控状态");
    Check([self.panel.stateDetail.text containsString:@"2"], @"连接数来自状态文件");
    NSArray *history = @[@{@"at": @([[NSDate date] timeIntervalSince1970] - 120), @"duration_s": @720}];
    [self.panel refreshHistory:history];
    [self capture:@"tablet-active" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];

    [self fixture:@"waiting"];
    [self.panel refresh];
    Check(self.panel.displayedState == HostWaiting && !self.panel.qrGroup.hidden, @"扫码状态");
    Check(self.panel.qrView.hidden && !self.panel.logoutButton.enabled, @"无二维码时隐藏空图且禁用退出");
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
    [self.panel refreshQR:YES];
    Check(!self.panel.qrView.hidden && self.panel.qrView.image != nil, @"合成二维码图读取与显示");
    [self capture:@"tablet-waiting" size:CGSizeMake(768, 1024) tab:0 dark:NO large:NO];
    Check(fabs(self.panel.qrView.bounds.size.width - 200) < 1
        && fabs(self.panel.qrView.bounds.size.height - 200) < 1, @"合成二维码保持200点尺寸");
    [self capture:@"tablet-waiting-narrow" size:CGSizeMake(375, 812) tab:0 dark:YES large:NO];

    [self fixture:@"offline"];
    [self.panel refresh];
    Check(self.panel.displayedState == HostDown && !self.panel.installCard.hidden, @"陈旧状态显示离线与安装入口");
    Check(self.panel.qrGroup.hidden, @"离开扫码状态时隐藏二维码");
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [UIView setAnimationsEnabled:NO];
        [self runChecks];
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([NativeCheckDelegate class])); }
}
