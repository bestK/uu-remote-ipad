// Experimental, separate-process HUD. It is never installed or started by the panel service.
// The private bootstrap and accessibility hosting approach are informed by TrollSpeed; see NOTICE.TrollSpeed.
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#import "indicator_state.h"
#import "indicator_view.h"
#import "status_file.h"

static const NSTimeInterval kExperimentSeconds = 60;
static BOOL stopping;
static BOOL daemonMode;
// Test-only --fixture overrides statusPath so the badge can be checked without a live session.
static NSString *statusPath = @"/private/var/tmp/uu-status.json";
static NSString *rootfsPath = @"/rootfs/private/var/tmp/uu-status.json";

static void Fail(const char *stage) {
    fprintf(stderr, "indicator unavailable: stage=%s\n", stage);
    exit(1);
}

// Independent of UIKit's run loop: if a private call hangs, kill only this experimental process.
static void *Watchdog(void *unused) {
    (void)unused;
    unsigned int remaining = (unsigned int)kExperimentSeconds + 5;
    while (remaining) remaining = sleep(remaining);
    _exit(0);
    return NULL;
}

@interface UIWindow (UUIndicatorPrivate)
- (unsigned int)_contextId;
@end

@interface UIApplication (UUIndicatorPrivate)
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
@end

@interface UUIndicatorWindow : UIWindow
@end
@implementation UUIndicatorWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
@end

@interface UUIndicatorApplication : UIApplication
@end
@implementation UUIndicatorApplication
@end

@interface UUIndicatorDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation UUIndicatorDelegate {
    UUIndicatorViewController *_view;
    UUIndicatorStatus *_status;
    id _hosting;
    NSTimer *_timer;
    unsigned int _context;
    UUIndicatorState _lastState;
    BOOL _loggedFirst;
}

// A root daemon-like process often reports "en" from NSLocale; the owner's choice lives in
// GlobalPreferences, which is also what the panel follows.
static BOOL PreferredChinese(void) {
    for (NSString *path in @[@"/var/mobile/Library/Preferences/.GlobalPreferences.plist",
                             @"/rootfs/var/mobile/Library/Preferences/.GlobalPreferences.plist"]) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *languages = prefs[@"AppleLanguages"];
        if ([languages isKindOfClass:NSArray.class]) {
            NSString *first = languages.firstObject;
            if ([first isKindOfClass:NSString.class]) return [first hasPrefix:@"zh"];
        }
    }
    return [[NSLocale preferredLanguages].firstObject hasPrefix:@"zh"];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    BOOL chinese = PreferredChinese();
    _view = [[UUIndicatorViewController alloc] initWithChinese:chinese];
    _status = [[UUIndicatorStatus alloc] init];
    self.window = [[UUIndicatorWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = _view;
    self.window.backgroundColor = UIColor.clearColor;
    self.window.userInteractionEnabled = NO;
    self.window.windowLevel = 10000010.0;
    [self.window makeKeyAndVisible];

    Class hostClass = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!hostClass || ![self.window respondsToSelector:@selector(_contextId)]) Fail("hosting-api");
    _hosting = [[hostClass alloc] init];
    SEL selector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    NSMethodSignature *signature = [_hosting methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 4 || strcmp([signature getArgumentTypeAtIndex:2], "I")
        || strcmp([signature getArgumentTypeAtIndex:3], "d")) Fail("hosting-signature");
    unsigned int context = [self.window _contextId];
    if (!context) Fail("window-context");
    _context = context;
    double level = self.window.windowLevel;
    @try {
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = _hosting;
        call.selector = selector;
        [call setArgument:&context atIndex:2];
        [call setArgument:&level atIndex:3];
        [call invoke];
    } @catch (NSException *exception) {
        (void)exception;
        Fail("hosting-register");
    }
    fprintf(stderr, "indicator hosting requested; visibility is not verified\n");
    [self refreshStatus];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refreshStatus)
        userInfo:nil repeats:YES];
    return YES;
}

- (void)refreshStatus {
    @autoreleasepool {
        NSData *direct = UUReadStatusFile(statusPath);
        NSData *rootfs = rootfsPath ? UUReadStatusFile(rootfsPath) : nil;
        UUIndicatorState state = [_status updateDirect:direct rootfs:rootfs now:NSDate.date.timeIntervalSince1970];
        if (!_loggedFirst) {
            // Sizes only: confirms the file view without exposing its contents.
            int err = 0;
            if (!direct.length && statusPath) { errno = 0; (void)access(statusPath.fileSystemRepresentation, R_OK); err = errno; }
            fprintf(stderr, "indicator read direct=%lu rootfs=%lu errno=%d\n",
                (unsigned long)direct.length, (unsigned long)rootfs.length, err);
            _loggedFirst = YES;
        }
        if (state != _lastState) {
            // State only: no account, path or session data.
            fprintf(stderr, "indicator state=%s\n", state == UUIndicatorActive ? "active"
                : state == UUIndicatorIdle ? "idle" : "unknown");
            _lastState = state;
        }
        self.window.frame = UIScreen.mainScreen.bounds;
        [_view showIndicatorState:state];
    }
}

- (void)stop {
    if (stopping) return;
    stopping = YES;
    // A stuck main thread or a nested plugin run loop must not keep the window alive.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ _exit(0); });
    [_timer invalidate];
    self.window.hidden = YES;
    SEL unregister = NSSelectorFromString(@"unregisterWindowWithContextID:");
    NSMethodSignature *signature = [_hosting respondsToSelector:unregister] ? [_hosting methodSignatureForSelector:unregister] : nil;
    if (signature.numberOfArguments == 3 && !strcmp([signature getArgumentTypeAtIndex:2], "I") && _context) {
        @try {
            NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
            call.target = _hosting;
            call.selector = unregister;
            unsigned int context = _context;
            [call setArgument:&context atIndex:2];
            [call invoke];
        } @catch (NSException *exception) { (void)exception; }
    }
    self.window.rootViewController = nil;
    self.window = nil;
    _hosting = nil;
    CFRunLoopStop(CFRunLoopGetMain());
}
@end

static UUIndicatorDelegate *delegate;
static dispatch_source_t termination;

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--probe-paths") == 0) {
            // Diagnostic: which of these files this process can actually read.
            NSArray *paths = @[@"/private/var/tmp/uu-status.json",
                               @"/rootfs/private/var/tmp/uu-status.json",
                               @"/var/mobile/uu-hud.VQ9D23Tn/fixture.json",
                               @"/rootfs/var/mobile/uu-hud.VQ9D23Tn/fixture.json",
                               @"/private/var/tmp/uu-hud-fixture.json"];
            for (NSString *path in paths) {
                NSData *data = UUReadStatusFile(path);
                errno = 0;
                (void)access(path.fileSystemRepresentation, R_OK);
                fprintf(stderr, "probe bytes=%lu errno=%d\n", (unsigned long)data.length, errno);
            }
            return 0;
        }
        BOOL experimental = argc >= 2 && strcmp(argv[1], "--experimental") == 0;
        daemonMode = argc >= 2 && strcmp(argv[1], "--daemon") == 0;
        if (!experimental && !daemonMode) {
            fprintf(stderr, "usage: UUStatusHUD (--experimental [--fixture PATH] | --daemon)\n");
            return 2;
        }
        if (argc == 4 && strcmp(argv[2], "--fixture") == 0) {
            statusPath = [NSString stringWithUTF8String:argv[3]];
            rootfsPath = nil;
            fprintf(stderr, "indicator fixture=%s\n", argv[3]);
        } else if (argc != 2) {
            fprintf(stderr, "usage: UUStatusHUD --experimental [--fixture PATH]\n");
            return 2;
        }
        if (!daemonMode) {
            pthread_t watchdog;
            if (pthread_create(&watchdog, NULL, Watchdog, NULL) != 0) Fail("watchdog");
            pthread_detach(watchdog);
        }
        void *graphics = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_NOW | RTLD_GLOBAL);
        void *backboard = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW | RTLD_GLOBAL);
        void *springboard = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW | RTLD_GLOBAL);
        if (!graphics || !backboard || !springboard) Fail("frameworks");
        void (*gsInit)(void) = dlsym(graphics, "GSInitialize");
        void (*displayStart)(void) = dlsym(backboard, "BKSDisplayServicesStart");
        void (*appInit)(void) = dlsym(RTLD_DEFAULT, "UIApplicationInitialize");
        void (*appCreate)(Class) = dlsym(RTLD_DEFAULT, "UIApplicationInstantiateSingleton");
        void (*eventInit)(Boolean) = dlsym(graphics, "GSEventInitialize");
        void (*pushMode)(CFStringRef) = dlsym(graphics, "GSEventPushRunLoopMode");
        if (!gsInit || !displayStart || !appInit || !appCreate || !eventInit || !pushMode) Fail("symbols");
        (void)UIScreen.mainScreen;
        (void)CFRunLoopGetCurrent();
        gsInit();
        displayStart();
        appInit();
        appCreate(UUIndicatorApplication.class);
        UIApplication *application = UIApplication.sharedApplication;
        if (!application || ![application respondsToSelector:@selector(_accessibilityInit)]
            || ![application respondsToSelector:@selector(__completeAndRunAsPlugin)]) Fail("application-api");
        delegate = [[UUIndicatorDelegate alloc] init];
        application.delegate = delegate;
        [application _accessibilityInit];
        eventInit(false);
        pushMode(kCFRunLoopDefaultMode);
        signal(SIGTERM, SIG_IGN);
        termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(termination, ^{ [delegate stop]; });
        dispatch_resume(termination);
        int bootToken = 0;
        if (notify_register_dispatch("SBSpringBoardDidLaunchNotification", &bootToken, dispatch_get_main_queue(), ^(int token) {
            notify_cancel(token);
            [delegate stop];
            // A daemon is restarted by launchd with a fresh SpringBoard hosting context.
            if (daemonMode) _exit(0);
        }) != NOTIFY_STATUS_OK) Fail("restart-notification");
        if (!daemonMode) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kExperimentSeconds * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ [delegate stop]; });
        }
        [application __completeAndRunAsPlugin];
        if (!stopping) CFRunLoopRun();
        return 0;
    }
}
