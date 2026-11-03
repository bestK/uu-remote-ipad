// Platform probe: can a standalone root process capture the screen, inject HID,
// and reach SpringBoard's lock-screen manager?
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <dlfcn.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, Boolean, Boolean, IOOptionBits);
extern void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);

int main(int argc, char **argv) {
    @autoreleasepool {
        printf("uid=%d\n", getuid());
        Class bkhid = NSClassFromString(@"BKHIDSystemInterface");
        Class lsm = NSClassFromString(@"SBLockScreenManager");
        printf("BKHIDSystemInterface=%s SBLockScreenManager=%s\n", bkhid ? "yes" : "no", lsm ? "yes" : "no");

        // Capture: private class method on UIWindow.
        SEL sel = NSSelectorFromString(@"createScreenIOSurface");
        if ([UIWindow respondsToSelector:sel]) {
            IMP imp = [UIWindow methodForSelector:sel];
            void *(*fn)(id, SEL) = (void *)imp;
            void *surface = fn((id)[UIWindow class], sel);
            printf("screenIOSurface=%p\n", surface);
        } else {
            printf("screenIOSurface=unavailable\n");
        }

        // HID: dispatch a tap at the top-left corner (harmless).
        IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        printf("hidClient=%p\n", client);
        if (client) {
            uint64_t now = mach_absolute_time();
            IOHIDEventRef ev = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, now, 1, 3, 3,
                0.02, 0.02, 0, 0, 0, 1, 1, 0);
            IOHIDEventSetSenderID(ev, 0x100000761ULL);
            IOHIDEventSystemClientDispatchEvent(client, ev);
            CFRelease(ev);
            printf("hidDispatch=sent\n");
        }

        if (lsm) {
            id manager = ((id (*)(id, SEL))objc_msgSend)((id)lsm, NSSelectorFromString(@"sharedInstance"));
            if (manager) {
                BOOL locked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"isUILocked"));
                printf("locked=%d\n", locked);
            }
        }
    }
    return 0;
}
