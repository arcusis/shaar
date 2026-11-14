# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("web_share_probe", ROOT / "scripts/test-web-share.py")
PROBE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROBE
SPEC.loader.exec_module(PROBE)


class WebShareProbeOutputTests(unittest.TestCase):
    def test_receipt_writer_rejects_symlink_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "outside.json"
            target.write_text("preserve this", encoding="utf-8")
            output = root / "receipt.json"
            output.symlink_to(target)

            with self.assertRaisesRegex(ValueError, "web-share receipt path must not be a symlink"):
                PROBE.write_receipt(output, {"passed": True})

            self.assertEqual(target.read_text(encoding="utf-8"), "preserve this")

    def test_screenshot_copy_rejects_symlink_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.png"
            source.write_bytes(b"new image")
            target = root / "outside.png"
            target.write_bytes(b"preserve image")
            output = root / "share-sheet.png"
            output.symlink_to(target)

            with self.assertRaisesRegex(ValueError, "web-share screenshot path must not be a symlink"):
                PROBE.copy_screenshot(source, output)

            self.assertEqual(target.read_bytes(), b"preserve image")


if __name__ == "__main__":
    unittest.main()
