# Release constants shared by bundle-app.sh, release.sh, release_feed.py and the Release workflow.
# Keep plain KEY=value lines: Python reads this file without running it.

SHAAR_BUNDLE_IDENTIFIER=com.arcusis.browser
# Apple's Major.Minor.Patch version shown to users; the release tag is v<this>.
SHAAR_BUNDLE_VERSION=0.1.0
# Strictly increasing build number. Sparkle orders updates by this value.
SHAAR_BUILD_VERSION=1
SHAAR_MINIMUM_SYSTEM_VERSION=26.0

# arcusis/shaar is internal, so the feed and update downloads live in a public repository:
# GitHub Pages serves docs/appcast.xml from its default branch; its Releases hold the DMG and ZIP.
SHAAR_RELEASE_REPOSITORY=arcusis/shaar-releases
SHAAR_FEED_URL=https://arcusis.github.io/shaar-releases/appcast.xml

# Replace with the public key printed by Sparkle's `generate_keys --account shaar`.
# Bundles carrying the placeholder never start the updater, and release.sh refuses to
# notarize or upload them.
SHAAR_SPARKLE_PUBLIC_ED_KEY=SHAAR_SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER
SHAAR_SPARKLE_KEY_ACCOUNT=shaar
