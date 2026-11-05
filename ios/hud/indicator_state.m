#import "indicator_state.h"
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

static const NSTimeInterval kFreshFor = 10;

typedef struct {
    BOOL valid;
    NSTimeInterval updated;
    BOOL active;
    uint64_t revision;
    char instance[17];
} Snapshot;

static BOOL Number(id value, double *result) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number)) return NO;
    *result = number;
    return YES;
}

static Snapshot Decode(NSData *data, NSTimeInterval now) {
    Snapshot snapshot = {0};
    if (!data.length || data.length > 16384 || !isfinite(now)) return snapshot;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) return snapshot;
    double updated = 0, viewers = 0, revision = 0;
    NSString *instance = object[@"status_instance"];
    if (!Number(object[@"updated"], &updated) || !Number(object[@"viewers"], &viewers)
        || !Number(object[@"status_revision"], &revision) || ![instance isKindOfClass:NSString.class] || instance.length != 16
        || updated <= 0 || updated > now + kFreshFor || now - updated > kFreshFor
        || viewers < 0 || viewers > 1000000 || floor(viewers) != viewers
        || revision < 1 || revision > 9007199254740991.0 || floor(revision) != revision) return snapshot;
    for (NSUInteger i = 0; i < instance.length; i++) {
        unichar c = [instance characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return snapshot;
        snapshot.instance[i] = (char)c;
    }
    snapshot.valid = YES;
    snapshot.updated = updated;
    snapshot.active = viewers > 0;
    snapshot.revision = (uint64_t)revision;
    return snapshot;
}

static BOOL SameInstance(Snapshot a, Snapshot b) { return strcmp(a.instance, b.instance) == 0; }
static BOOL SameRevisionConflicts(Snapshot a, Snapshot b) {
    return a.revision == b.revision && (a.active != b.active || a.updated != b.updated);
}

@implementation UUIndicatorStatus {
    Snapshot _last;
}

- (UUIndicatorState)updateDirect:(NSData *)direct rootfs:(NSData *)rootfs now:(NSTimeInterval)now {
    if (isfinite(now) && _last.valid && (now - _last.updated > kFreshFor || _last.updated > now + kFreshFor)) _last.valid = NO;
    Snapshot a = Decode(direct, now), b = Decode(rootfs, now);
    if (a.valid && b.valid && (!SameInstance(a, b) || SameRevisionConflicts(a, b))) return UUIndicatorUnknown;
    Snapshot chosen = a;
    if (b.valid && (!a.valid || b.revision > a.revision)) chosen = b;
    if (chosen.valid && _last.valid && (!SameInstance(chosen, _last) || SameRevisionConflicts(chosen, _last))) return UUIndicatorUnknown;
    if (chosen.valid && (!_last.valid || chosen.revision > _last.revision)) _last = chosen;
    if (!_last.valid || !isfinite(now) || _last.updated <= 0
        || _last.updated > now + kFreshFor || now - _last.updated > kFreshFor) return UUIndicatorUnknown;
    return _last.active ? UUIndicatorActive : UUIndicatorIdle;
}
@end
