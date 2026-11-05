#import <Foundation/Foundation.h>
#import "status_file.h"
#include <sys/stat.h>
#include <unistd.h>

static NSUInteger checks;
static void Check(BOOL ok, const char *name) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"uu-status-file-%d", getpid()]];
        NSFileManager *fm = NSFileManager.defaultManager;
        Check([fm createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:nil error:nil], "temporary directory");
        NSString *regular = [dir stringByAppendingPathComponent:@"status.json"];
        NSData *body = [@"{\"viewers\":1}" dataUsingEncoding:NSUTF8StringEncoding];
        [body writeToFile:regular atomically:YES];
        Check([UUReadStatusFile(regular) isEqualToData:body], "regular file is read");
        Check(UUReadStatusFile([dir stringByAppendingPathComponent:@"missing"]) == nil, "missing file unavailable");
        NSString *link = [dir stringByAppendingPathComponent:@"link.json"];
        Check(symlink(regular.fileSystemRepresentation, link.fileSystemRepresentation) == 0, "symlink created");
        Check(UUReadStatusFile(link) == nil, "symlink refused");
        Check(UUReadStatusFile(dir) == nil, "directory refused");
        NSString *large = [dir stringByAppendingPathComponent:@"large.json"];
        [[NSMutableData dataWithLength:16385] writeToFile:large atomically:YES];
        Check(UUReadStatusFile(large) == nil, "oversized file refused");
        NSString *limit = [dir stringByAppendingPathComponent:@"limit.json"];
        [[NSMutableData dataWithLength:16384] writeToFile:limit atomically:YES];
        Check(UUReadStatusFile(limit).length == 16384, "size limit included");
        NSString *fifo = [dir stringByAppendingPathComponent:@"fifo"];
        Check(mkfifo(fifo.fileSystemRepresentation, 0600) == 0, "fifo created");
        Check(UUReadStatusFile(fifo) == nil, "fifo refused without blocking");
        [fm removeItemAtPath:dir error:nil];
        printf("status file: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
