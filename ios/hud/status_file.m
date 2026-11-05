#import "status_file.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSData *UUReadStatusFile(NSString *path) {
    if (!path.length) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 || info.st_size > 16384) {
        close(fd);
        return nil;
    }
    unsigned char bytes[16385];
    size_t length = 0;
    while (length < sizeof(bytes)) {
        ssize_t n = read(fd, bytes + length, sizeof(bytes) - length);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { close(fd); return nil; }
        if (n == 0) break;
        length += (size_t)n;
    }
    close(fd);
    return length <= 16384 ? [NSData dataWithBytes:bytes length:length] : nil;
}
