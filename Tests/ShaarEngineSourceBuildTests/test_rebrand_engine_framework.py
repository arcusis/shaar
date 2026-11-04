# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The test framework package must carry Shaar bundle identities."""

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "rebrand_engine_framework", ROOT / "scripts/rebrand-engine-framework.py")
REBRAND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REBRAND)


class RebrandEngineFrameworkTests(unittest.TestCase):
    def test_framework_and_helpers_have_shaar_bundle_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            framework = Path(temporary) / "Chromium Framework.framework"
            version = framework / "Versions/Current"
            info_paths = {version / "Resources/Info.plist": REBRAND.FRAMEWORK_ID}
            info_paths.update({
                version / "Helpers" / name / "Contents/Info.plist": identifier
                for name, identifier in REBRAND.HELPER_IDS.items()
            })
            for path in info_paths:
                path.parent.mkdir(parents=True)
                path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.ardia.browser"}))
            REBRAND.rebrand(framework)
            for path, identifier in info_paths.items():
                self.assertEqual(plistlib.loads(path.read_bytes())["CFBundleIdentifier"],
                                 identifier)
                self.assertFalse(identifier.startswith("com.ardia."))


if __name__ == "__main__":
    unittest.main()
