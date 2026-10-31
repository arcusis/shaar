#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Testing mode acts only inside a marked, owner-only disposable directory under the temporary directory.
FOUNDATION_EXPORT BOOL ARCProbeRootIsOwned(NSURL *root);

NS_ASSUME_NONNULL_END
