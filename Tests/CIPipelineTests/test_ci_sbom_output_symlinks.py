# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


def load_sbom():
    spec = importlib.util.spec_from_file_location("ci_sbom", ROOT / "scripts/ci-sbom.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SBOM = load_sbom()


class SBOMOutputSymlinkTests(unittest.TestCase):
    def test_main_rejects_symlinked_sbom_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "build/ci/shipping"
            output.mkdir(parents=True)
            app = root / "build/Shaar.app"
            app.mkdir(parents=True)
            (app / "Main").write_bytes(b"executable")
            outside = root / "external.json"
            outside.write_text("preserve this file")
            (output / "sbom.spdx.json").symlink_to(outside)
            (root / "ThirdParty/ChromiumEngine").mkdir(parents=True)
            (root / "ThirdParty/ChromiumEngine/pin.json").write_text(json.dumps({
                "releaseTag": "engine-1.2.3-shaar.1",
                "asset": "ShaarEngine-1.2.3-shaar.1.tar.xz",
                "sha256": "a" * 64,
            }))
            (root / "Package.resolved").write_text(json.dumps({"pins": []}))

            def create_candidate(arguments, check):
                Path(arguments[-1]).write_bytes(b"candidate archive")

            with patch.object(SBOM, "ROOT", root), \
                    patch.object(SBOM.subprocess, "run", side_effect=create_candidate), \
                    patch.object(SBOM.subprocess, "check_output", return_value="b" * 40):
                with self.assertRaisesRegex(ValueError, "must not be a symlink"):
                    SBOM.main()

            self.assertEqual(outside.read_text(), "preserve this file")


if __name__ == "__main__":
    unittest.main()
