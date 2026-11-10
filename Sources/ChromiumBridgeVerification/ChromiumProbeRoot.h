// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Testing mode acts only inside a marked, owner-only disposable directory under the temporary directory.
FOUNDATION_EXPORT BOOL ARCProbeRootIsOwned(NSURL *root);

NS_ASSUME_NONNULL_END
