#import <Foundation/Foundation.h>

// Reads only a small regular file. A missing, oversized or symlinked file is unavailable.
NSData *UUReadStatusFile(NSString *path);
