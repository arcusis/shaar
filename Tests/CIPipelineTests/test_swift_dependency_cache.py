# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SwiftDependencyCacheTests(unittest.TestCase):
    def test_dependency_cache_restore_prefix_matches_platform_and_toolchain(self):
        setup = (ROOT / ".github/actions/ci-setup/action.yml").read_text()
        cache = setup.split("- name: Cache SwiftPM dependencies without compiled app objects", 1)[1].split(
            "- name:", 1
        )[0]
        self.assertIn("restore-keys: |", cache)
        self.assertIn(
            "swift-dependencies-${{ runner.os }}-${{ runner.arch }}-${{ steps.toolchain.outputs.identity }}-",
            cache,
        )
