# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("shaar_favicon_probe", ROOT / "scripts/test-shaar-favicon.py")
PROBE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROBE
SPEC.loader.exec_module(PROBE)


class FaviconProbeOutputTests(unittest.TestCase):
    def test_evidence_copy_rejects_symlink_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.png"
            source.write_bytes(b"new screenshot")
            target = root / "outside.png"
            target.write_bytes(b"preserve image")
            output = root / "copied.png"
            output.symlink_to(target)

            with self.assertRaisesRegex(ValueError, "favicon evidence output must not be a symlink"):
                PROBE.copy_evidence(source, output)

            self.assertEqual(target.read_bytes(), b"preserve image")


if __name__ == "__main__":
    unittest.main()
