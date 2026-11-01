#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Integrity checks for test-only framework assets."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
import json

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('developer_fixture_assets', ROOT / 'scripts/developer_fixture_assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class DeveloperFixtureTests(unittest.TestCase):
    def test_tampered_cache_fails_before_network_fetch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'react.js').write_text('changed')
            manifest = root / 'pins.json'
            manifest.write_text(json.dumps([{'name': 'react', 'sha256': '0' * 64, 'licenseSHA256': '0' * 64}]))
            with self.assertRaisesRegex(RuntimeError, 'differs from its pin'):
                assets.ensure_assets(cache=root, manifest=manifest)

    def test_manifest_rejects_unexpected_package_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / 'pins.json'
            manifest.write_text(json.dumps([{'name': '../outside'}]))
            with self.assertRaisesRegex(RuntimeError, 'Unexpected'):
                assets.ensure_assets(cache=root, manifest=manifest)
