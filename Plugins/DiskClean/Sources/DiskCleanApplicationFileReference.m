#import "DiskCleanApplicationFileReference.h"
#import <AppKit/AppKit.h>

void DiskCleanRecycleApplicationFileReference(CFURLRef reference,
    void (^completion)(NSString * _Nullable destination, NSError * _Nullable error)) {
    // Keep the reference in Objective-C: bridging it through Swift URL resolves it to a pathname.
    NSURL *url = (__bridge NSURL *)reference;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSWorkspace sharedWorkspace] recycleURLs:@[url] completionHandler:^(NSDictionary<NSURL *, NSURL *> *result, NSError *error) {
            if (result.count == 1 && error == nil) {
                completion(result.allValues.firstObject.path, nil);
            } else {
                completion(nil, error ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil]);
            }
        }];
    });
}
