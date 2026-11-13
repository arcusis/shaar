# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Ensure failed HTTPS-only persistence or live apply remains retryable."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/ChromiumBridge/ChromiumShaarBackend.mm"


class HttpsOnlyCacheCommitTests(unittest.TestCase):
    def test_cache_is_updated_only_after_persistence_and_live_apply(self):
        source = SOURCE.read_text()
        start = source.index("- (BOOL)setHttpsOnlyModeEnabled:")
        end = source.index("- (NSArray<NSString *> *)profileDirectoryEntries", start)
        method = source[start:end]

        self.assertIn("ARCCommitHttpsOnlyModeChange(", method)
        helper = (ROOT / "Sources/ChromiumBridge/ChromiumHttpsOnly.mm").read_text()
        dirty_mark = helper.index("[dirtyProfiles addObject:profileID];")
        retry_write = helper.index(
            "BOOL needsWrite = changed || [dirtyProfiles containsObject:profileID];")
        self.assertLess(retry_write, dirty_mark)


if __name__ == "__main__":
    unittest.main()
