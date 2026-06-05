/* mac_fs.mm — Trash/delete via NSFileManager for the NppFTP port. */
#import <Foundation/Foundation.h>
#include "mac_fs.h"

int MacRecycleOrDeletePath(const char* path, int permanent) {
    @autoreleasepool {
        if (!path || !*path) return -1;
        NSString* p = [NSString stringWithUTF8String:path];
        NSURL* url = [NSURL fileURLWithPath:p];
        NSFileManager* fm = [NSFileManager defaultManager];
        NSError* err = nil;
        BOOL ok;
        if (permanent) {
            ok = [fm removeItemAtURL:url error:&err];
        } else {
            ok = [fm trashItemAtURL:url resultingItemURL:nil error:&err];
        }
        return ok ? 0 : -1;
    }
}
