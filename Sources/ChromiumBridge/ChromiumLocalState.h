// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

FOUNDATION_EXPORT BOOL ARCDisableBackgroundMode(NSURL *userDataDirectory);

/// Keeps the full-page HTTPS-only interstitial. Merges the labs flag; leaves an unreadable file in place.
FOUNDATION_EXPORT BOOL ARCDisableHttpsFirstDialog(NSURL *userDataDirectory);

#ifdef __cplusplus
}
#endif
