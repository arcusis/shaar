# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# shellcheck shell=bash disable=SC2034 # Sourced: the scripts that source this file read every value.
# Release constants shared by bundle-app.sh, release.sh, release_feed.py and the Release workflow.
# Keep plain KEY=value lines: Python reads this file without running it.

SHAAR_BUNDLE_IDENTIFIER=com.arcusis.browser
# Apple's Major.Minor.Patch version shown to users; the release tag is v<this>.
SHAAR_BUNDLE_VERSION=0.1.0
# Strictly increasing build number. Sparkle orders updates by this value.
SHAAR_BUILD_VERSION=1
SHAAR_MINIMUM_SYSTEM_VERSION=26.0

# GitHub Releases in this repository hold the DMG, the Sparkle ZIP and appcast.xml. The Release
# workflow deploys the validated appcast.xml to this repository's GitHub Pages at the feed URL.
SHAAR_RELEASE_REPOSITORY=arcusis/shaar
SHAAR_FEED_URL=https://arcusis.github.io/shaar/appcast.xml

# Public half of the Sparkle EdDSA key (`generate_keys --account shaar -p`). The private key
# lives in the release Mac's login keychain; release.sh checks that the two match.
SHAAR_SPARKLE_PUBLIC_ED_KEY=mAZzywTpmIBYZQRU9LERPRlNASVCm8X31EF9ZmDYX9Y=
SHAAR_SPARKLE_KEY_ACCOUNT=shaar
