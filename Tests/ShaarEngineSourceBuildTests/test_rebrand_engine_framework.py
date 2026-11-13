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
    def test_rebrand_rejects_symlinked_helper_bundle_before_modifying_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            framework = root / "Chromium Framework.framework"
            version = framework / "Versions/Current"
            (version / "Resources").mkdir(parents=True)
            (version / "Resources/Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": "com.ardia.browser"})
            )
            helpers = version / "Helpers"
            helpers.mkdir()
            target = root / "outside-helper"
            info = target / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.external.target"}))
            for name in REBRAND.HELPER_IDS:
                path = helpers / name
                if name == "Chromium Helper.app":
                    path.symlink_to(target, target_is_directory=True)
                    continue
                (path / "Contents").mkdir(parents=True)
                (path / "Contents/Info.plist").write_bytes(
                    plistlib.dumps({"CFBundleIdentifier": "com.ardia.browser"})
                )

            with self.assertRaisesRegex(ValueError, "helper bundles must be real directories"):
                REBRAND.rebrand(framework)

            self.assertEqual(
                plistlib.loads(info.read_bytes())["CFBundleIdentifier"], "com.external.target"
            )

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
                if "Helpers" in path.parts:
                    localized = path.parent / "Resources/base.lproj/InfoPlist.strings"
                    localized.parent.mkdir(parents=True)
                    localized.write_bytes(plistlib.dumps(
                        {"CFBundleDisplayName": "Chromium", "Unrelated": "preserved"},
                        fmt=plistlib.FMT_BINARY))
            REBRAND.rebrand(framework)
            for path, identifier in info_paths.items():
                values = plistlib.loads(path.read_bytes())
                self.assertEqual(values["CFBundleIdentifier"], identifier)
                self.assertFalse(identifier.startswith("com.ardia."))
                self.assertTrue(values["CFBundleDisplayName"].startswith("Shaar"))
                if "Helpers" in path.parts:
                    self.assertEqual(values["CFBundleIconFile"], "Shaar.icns")
                    resources = path.parent / "Resources"
                    self.assertEqual((resources / "Shaar.icns").read_bytes(),
                                     REBRAND.SHAAR_ICON.read_bytes())
                    self.assertFalse((resources / "Assets.car").exists())
                    localized = plistlib.loads(
                        (resources / "base.lproj/InfoPlist.strings").read_bytes())
                    self.assertEqual(localized["CFBundleDisplayName"], values["CFBundleDisplayName"])
                    self.assertEqual(localized["Unrelated"], "preserved")


if __name__ == "__main__":
    unittest.main()
