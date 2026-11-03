// uu-ipad tweak: injected into backboardd (HID injection) and SpringBoard
// (screen capture, lock state, passcode unlock). Unix-socket JSON protocol.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <pthread.h>
#import <mach/mach_time.h>
#include <sys/stat.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
    uint32_t, double, double, double, double, double, bool, bool, uint32_t);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t, int);
extern void IOHIDEventSetIntegerValueWithOptions(IOHIDEventRef, uint32_t, int, int);
extern void IOHIDEventSetFloatValue(IOHIDEventRef, uint32_t, double);
extern void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);
extern CGImageRef UICreateCGImageFromIOSurface(void *surface);

static const char *HID_SOCKET = "/var/run/uu-ipad-hid.sock";
static const char *SCREEN_SOCKET = "/var/run/uu-ipad-screen.sock";
static uint64_t gSender = 0x100000761ULL;
static BOOL gScreenRole = NO;

static id msg_id(id target, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}
static BOOL msg_bool(id target, const char *sel) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}
static id cls_instance(const char *name) {
    Class cls = NSClassFromString([NSString stringWithUTF8String:name]);
    return cls ? msg_id((id)cls, "sharedInstance") : nil;
}

// ---- HID -------------------------------------------------------------------
static void discover_sender(void) {
    @try {
        id iface = cls_instance("BKHIDSystemInterface");
        id cache = iface ? msg_id(iface, "senderCache") : nil;
        id dict = cache ? msg_id(cache, "senderIDToSenderInfo") : nil;
        if (!dict) return;
        for (id key in dict) {
            NSString *desc = [[dict objectForKey:key] description];
            if ([desc containsString:@"primaryUsagePage:0xd"] && [desc containsString:@"primaryUsage:0x1"]) {
                gSender = [key unsignedLongLongValue];
                return;
            }
        }
    } @catch (NSException *e) {}
}

static void inject_touch(int mask, int range, int touch, double nx, double ny) {
    uint64_t now = mach_absolute_time();
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, now, 3, 99, 1, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0);
    if (!parent) return;
    IOHIDEventSetIntegerValue(parent, 0xb0019, 1);
    IOHIDEventSetIntegerValue(parent, 0x4, 1);
    IOHIDEventSetIntegerValueWithOptions(parent, 0xb0019, 1, -268435456);
    IOHIDEventSetIntegerValueWithOptions(parent, 0x4, 1, -268435456);
    IOHIDEventSetIntegerValueWithOptions(parent, 0xb0007, mask == 4 ? 4 : 35, -268435456);
    IOHIDEventSetIntegerValueWithOptions(parent, 0xb0008, touch, -268435456);
    IOHIDEventSetIntegerValueWithOptions(parent, 0xb0009, touch, -268435456);
    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, now, 1, 3, mask,
        nx, ny, 0, 0, 0, range, touch, 0);
    if (!child) { CFRelease(parent); return; }
    IOHIDEventSetFloatValue(child, 0xb0014, 0.04);
    IOHIDEventSetFloatValue(child, 0xb0015, 0.04);
    IOHIDEventAppendEvent(parent, child, 0);
    IOHIDEventSetIntegerValue(parent, 0xb0007, 0x23);
    IOHIDEventSetIntegerValue(parent, 0xb0008, 1);
    IOHIDEventSetIntegerValue(parent, 0xb0009, 1);
    IOHIDEventSetSenderID(parent, gSender);
    @try {
        id iface = cls_instance("BKHIDSystemInterface");
        if (iface) ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(iface, sel_registerName("injectHIDEvent:"), parent);
    } @catch (NSException *e) {}
    CFRelease(child);
    CFRelease(parent);
}

static void handle_hid(NSDictionary *req) {
    NSString *cmd = req[@"cmd"];
    double x = [req[@"x"] doubleValue], y = [req[@"y"] doubleValue];
    if ([cmd isEqualToString:@"tap"]) {
        inject_touch(3, 1, 1, x, y);
        usleep(40000);
        inject_touch(2, 0, 0, x, y);
    } else if ([cmd isEqualToString:@"down"]) {
        inject_touch(3, 1, 1, x, y);
    } else if ([cmd isEqualToString:@"move"]) {
        inject_touch(4, 1, 1, x, y);
    } else if ([cmd isEqualToString:@"up"]) {
        inject_touch(2, 0, 0, x, y);
    } else if ([cmd isEqualToString:@"swipe"]) {
        double x1 = [req[@"x1"] doubleValue], y1 = [req[@"y1"] doubleValue];
        double x2 = [req[@"x2"] doubleValue], y2 = [req[@"y2"] doubleValue];
        int ms = req[@"ms"] ? [req[@"ms"] intValue] : 300;
        int steps = MAX(2, MIN(60, ms / 16));
        inject_touch(3, 1, 1, x1, y1);
        for (int i = 1; i <= steps; i++) {
            usleep(16000);
            double k = (double)i / steps;
            inject_touch(4, 1, 1, x1 + (x2 - x1) * k, y1 + (y2 - y1) * k);
        }
        inject_touch(2, 0, 0, x2, y2);
    }
}

// ---- SpringBoard -----------------------------------------------------------
static BOOL screen_on(void) {
    id bl = cls_instance("SBBacklightController");
    return bl ? msg_bool(bl, "screenIsOn") : YES;
}
static BOOL is_locked(void) {
    id lm = cls_instance("SBLockScreenManager");
    return lm ? msg_bool(lm, "isUILocked") : NO;
}

static NSData *capture_jpeg(double quality, NSString **error) {
    __block NSData *jpeg = nil;
    __block NSString *failure = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!screen_on()) { failure = @"screen off"; return; }
        if (is_locked()) { failure = @"locked"; return; }
        SEL sel = sel_registerName("createScreenIOSurface");
        if (![UIWindow respondsToSelector:sel]) { failure = @"no surface api"; return; }
        IMP imp = [UIWindow methodForSelector:sel];
        void *(*fn)(id, SEL) = (void *)imp;
        void *surface = fn((id)[UIWindow class], sel);
        if (!surface) { failure = @"no surface"; return; }
        CGImageRef cg = UICreateCGImageFromIOSurface(surface);
        if (!cg) { CFRelease(surface); failure = @"no image"; return; }
        UIImage *image = [UIImage imageWithCGImage:cg];
        jpeg = UIImageJPEGRepresentation(image, quality);
        CGImageRelease(cg);
        CFRelease(surface);
    });
    if (error) *error = failure;
    return jpeg;
}

static NSDictionary *screen_state(void) {
    __block NSDictionary *state = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIScreen *screen = [UIScreen mainScreen];
        CGRect bounds = screen.bounds;
        state = @{ @"locked": @(is_locked()), @"screenOn": @(screen_on()),
                   @"width": @((int)bounds.size.width), @"height": @((int)bounds.size.height) };
    });
    return state;
}

static BOOL wake_screen(void) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        id bl = cls_instance("SBBacklightController");
        if (bl) { ((void (*)(id, SEL, long long))objc_msgSend)(bl, sel_registerName("turnOnScreenFullyWithBacklightSource:"), 0); ok = YES; }
    });
    return ok;
}

static BOOL unlock_passcode(NSString *passcode) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        id lm = cls_instance("SBLockScreenManager");
        if (lm && [lm respondsToSelector:sel_registerName("attemptUnlockWithPasscode:finishUIUnlock:completion:")]) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(lm,
                sel_registerName("attemptUnlockWithPasscode:finishUIUnlock:completion:"), passcode, YES, nil);
            ok = YES;
        }
    });
    return ok;
}

// ---- socket server ---------------------------------------------------------
static BOOL read_all(int fd, void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = read(fd, (char *)buf + done, len - done);
        if (n <= 0) return NO;
        done += (size_t)n;
    }
    return YES;
}
static BOOL write_all(int fd, const void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, (const char *)buf + done, len - done);
        if (n <= 0) return NO;
        done += (size_t)n;
    }
    return YES;
}

static void send_response(int fd, NSDictionary *json, NSData *payload) {
    NSData *head = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    uint32_t n = htonl((uint32_t)head.length);
    if (!write_all(fd, &n, 4) || !write_all(fd, head.bytes, head.length)) return;
    if (payload) {
        uint32_t m = htonl((uint32_t)payload.length);
        if (!write_all(fd, &m, 4)) return;
        write_all(fd, payload.bytes, payload.length);
    }
}

static void *client_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    BOOL screen = gScreenRole;
    for (;;) {
        uint32_t len = 0;
        if (!read_all(fd, &len, 4)) break;
        len = ntohl(len);
        if (len == 0 || len > 1 << 20) break;
        NSMutableData *body = [NSMutableData dataWithLength:len];
        if (!read_all(fd, body.mutableBytes, len)) break;
        NSDictionary *req = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if (![req isKindOfClass:[NSDictionary class]]) break;
        NSString *cmd = req[@"cmd"] ?: @"";

        if (screen) {
            if ([cmd isEqualToString:@"capture"]) {
                NSString *error = nil;
                double q = req[@"quality"] ? [req[@"quality"] doubleValue] : 0.5;
                NSData *jpeg = capture_jpeg(q, &error);
                if (jpeg) send_response(fd, @{@"ok": @YES, @"payload": @YES}, jpeg);
                else send_response(fd, @{@"ok": @NO, @"error": error ?: @"capture failed"}, nil);
            } else if ([cmd isEqualToString:@"state"]) {
                send_response(fd, screen_state(), nil);
            } else if ([cmd isEqualToString:@"wake"]) {
                send_response(fd, @{@"ok": @(wake_screen())}, nil);
            } else if ([cmd isEqualToString:@"unlock"]) {
                NSString *passcode = req[@"passcode"] ?: @"";
                BOOL ok = unlock_passcode(passcode);
                send_response(fd, @{@"ok": @(ok)}, nil);
            } else {
                send_response(fd, @{@"ok": @NO, @"error": @"unknown"}, nil);
            }
        } else {
            handle_hid(req);
            send_response(fd, @{@"ok": @YES}, nil);
        }
    }
    close(fd);
    return NULL;
}

static void *accept_thread(void *arg) {
    const char *path = (const char *)arg;
    unlink(path);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return NULL;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(server); return NULL; }
    chmod(path, 0666);
    listen(server, 4);
    for (;;) {
        int fd = accept(server, NULL, NULL);
        if (fd < 0) continue;
        pthread_t thread;
        if (pthread_create(&thread, NULL, client_thread, (void *)(intptr_t)fd) == 0) pthread_detach(thread);
        else close(fd);
    }
    return NULL;
}

static void start_server(const char *path, BOOL screen) {
    pthread_t thread;
    gScreenRole = screen;
    pthread_create(&thread, NULL, accept_thread, (void *)path);
    pthread_detach(thread);
}

__attribute__((constructor)) static void uu_ipad_init(void) {
    @autoreleasepool {
        NSString *process = [NSProcessInfo processInfo].processName;
        if ([process isEqualToString:@"backboardd"]) {
            discover_sender();
            start_server(HID_SOCKET, NO);
        } else if ([process isEqualToString:@"SpringBoard"]) {
            start_server(SCREEN_SOCKET, YES);
        }
    }
}
