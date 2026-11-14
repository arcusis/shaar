# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class CIToolArchiveCacheTests(unittest.TestCase):
    def test_archive_cache_restores_by_runner_before_manifest_hash(self):
        setup = (ROOT / ".github/actions/ci-setup/action.yml").read_text()
        cache = setup.split("- name: Cache checksum-pinned fast-check archives", 1)[1].split(
            "- name:", 1
        )[0]
        self.assertIn("restore-keys: |", cache)
        self.assertIn("ci-tool-archives-v1-${{ runner.os }}-${{ runner.arch }}-", cache)
