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

        cache_update = method.index("_shaarHttpsOnly[canonical] = @(enabled);")
        disk_write = method.index("ARCWriteHttpsOnlyPreference(")
        live_apply = method.index("[self applyLiveHttpsOnly:")

        self.assertLess(disk_write, cache_update)
        self.assertLess(live_apply, cache_update)
        self.assertIn("!ARCWriteHttpsOnlyPreference", method)
        self.assertIn("if (changed && ![self applyLiveHttpsOnly", method)


if __name__ == "__main__":
    unittest.main()
