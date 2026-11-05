#import <Foundation/Foundation.h>
#import "indicator_state.h"

static NSUInteger checks;
static NSString *const kA = @"0123456789abcdef";
static NSString *const kB = @"fedcba9876543210";

static NSData *JSON(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static NSData *Status(double updated, int viewers, unsigned revision, NSString *instance) {
    return [NSJSONSerialization dataWithJSONObject:@{ @"updated": @(updated), @"viewers": @(viewers),
        @"status_revision": @(revision), @"status_instance": instance } options:0 error:nil];
}
static void Check(BOOL ok, const char *name) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
}

int main(void) {
    @autoreleasepool {
        UUIndicatorStatus *status = [[UUIndicatorStatus alloc] init];
        Check([status updateDirect:nil rootfs:nil now:100] == UUIndicatorUnknown, "missing is unknown");
        Check([status updateDirect:JSON(@"{\"updated\":100,\"viewers\":0}") rootfs:nil now:100] == UUIndicatorUnknown, "legacy unsequenced state is unknown");
        Check([status updateDirect:Status(100, 0, 1, kA) rootfs:nil now:100] == UUIndicatorIdle, "zero viewers idle");
        Check([status updateDirect:Status(100, 1, 2, kA) rootfs:nil now:100] == UUIndicatorActive, "start in same second is ordered");
        Check([status updateDirect:Status(102, 2, 3, kA) rootfs:nil now:102] == UUIndicatorActive, "multiple viewers active");
        Check([status updateDirect:Status(103, 1, 4, kA) rootfs:nil now:103] == UUIndicatorActive, "one viewer remaining active");
        Check([status updateDirect:Status(104, 0, 5, kA) rootfs:nil now:104] == UUIndicatorIdle, "last viewer ends");
        Check([status updateDirect:Status(104, 1, 4, kA) rootfs:nil now:105] == UUIndicatorIdle, "older revision cannot roll back");
        Check([status updateDirect:JSON(@"{") rootfs:nil now:110] == UUIndicatorIdle, "transient invalid read retains fresh snapshot");
        Check([status updateDirect:nil rootfs:nil now:114] == UUIndicatorIdle, "fresh boundary included");
        Check([status updateDirect:nil rootfs:nil now:114.01] == UUIndicatorUnknown, "expired status unknown");
        Check([status updateDirect:nil rootfs:Status(115, 1, 6, kA) now:115] == UUIndicatorActive, "rootfs fallback active");
        Check([status updateDirect:Status(116, 0, 7, kA) rootfs:Status(115, 1, 6, kA) now:116] == UUIndicatorIdle, "newer direct revision wins");
        Check([status updateDirect:Status(116, 0, 7, kA) rootfs:Status(117, 1, 8, kA) now:117] == UUIndicatorActive, "newer rootfs revision wins");
        Check([status updateDirect:Status(118, 0, 9, kA) rootfs:Status(118, 1, 9, kA) now:118] == UUIndicatorUnknown, "same revision with conflicting count unknown");
        Check([status updateDirect:Status(118, 0, 9, kA) rootfs:Status(118, 1, 10, kB) now:118] == UUIndicatorUnknown, "different fresh instances unknown");
        Check([status updateDirect:Status(118, 0, 8, kA) rootfs:nil now:118] == UUIndicatorUnknown, "cached revision conflict unknown");
        Check([status updateDirect:Status(119, 0, 10, kA) rootfs:nil now:119] == UUIndicatorIdle, "newer confirmed idle clears");
        Check([status updateDirect:Status(129, 1, 11, kA) rootfs:nil now:119] == UUIndicatorActive, "future boundary included");
        Check([status updateDirect:nil rootfs:nil now:118.99] == UUIndicatorUnknown, "clock moved behind snapshot");
        Check([status updateDirect:Status(119, 0, 12, kA) rootfs:nil now:119] == UUIndicatorIdle, "recover after clock correction");
        NSArray *invalid = @[@"[]", @"{}", @"{\"updated\":0,\"viewers\":1}",
            @"{\"updated\":200,\"viewers\":1}", @"{\"updated\":120,\"viewers\":true}",
            @"{\"updated\":true,\"viewers\":1}", @"{\"updated\":120,\"viewers\":-1}",
            @"{\"updated\":120,\"viewers\":1.5}", @"{\"updated\":120,\"viewers\":\"1\"}",
            @"{\"updated\":120,\"viewers\":1000001}",
            @"{\"updated\":120,\"viewers\":1,\"status_revision\":true,\"status_instance\":\"0123456789abcdef\"}",
            @"{\"updated\":120,\"viewers\":1,\"status_revision\":1,\"status_instance\":\"not-an-instance!\"}"];
        for (NSString *text in invalid) {
            UUIndicatorStatus *empty = [[UUIndicatorStatus alloc] init];
            Check([empty updateDirect:JSON(text) rootfs:nil now:120] == UUIndicatorUnknown, "invalid snapshot rejected");
        }
        UUIndicatorStatus *active = [[UUIndicatorStatus alloc] init];
        Check([active updateDirect:Status(200, 1, 1, kA) rootfs:nil now:200] == UUIndicatorActive, "active before heartbeat loss");
        Check([active updateDirect:nil rootfs:nil now:211] == UUIndicatorUnknown, "active heartbeat loss is unknown, not idle");
        Check([active updateDirect:Status(212, 0, 2, kA) rootfs:nil now:212] == UUIndicatorIdle, "new idle heartbeat resolves uncertainty");
        UUIndicatorStatus *restart = [[UUIndicatorStatus alloc] init];
        Check([restart updateDirect:Status(200, 1, 50, kA) rootfs:nil now:200] == UUIndicatorActive, "before host restart");
        Check([restart updateDirect:Status(201, 0, 1, kB) rootfs:nil now:201] == UUIndicatorUnknown, "new instance cannot hide fresh old session");
        Check([restart updateDirect:Status(201, 0, 1, kB) rootfs:nil now:211] == UUIndicatorIdle, "new instance accepted when old expires");
        printf("indicator status: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
