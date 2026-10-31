#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

NS_ASSUME_NONNULL_BEGIN

void DiskCleanRecycleApplicationFileReference(CFURLRef reference,
    void (^completion)(NSString * _Nullable destination, NSError * _Nullable error));

NS_ASSUME_NONNULL_END
