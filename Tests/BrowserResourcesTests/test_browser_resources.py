import hashlib
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("stage_browser_resources", ROOT / "scripts/stage-browser-resources.py")
staging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(staging)


class ResourceStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binary = self.root / "bin"
        self.resources = self.root / "app/Contents/Resources"
        self.pin = self.root / "pin"
        shutil.copytree(ROOT / "ThirdParty/PublicSuffix", self.pin)
        self.bundle = self.binary / staging.BUNDLE
        data = self.bundle / "Contents/Resources/public_suffix_list.dat"
        data.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "Sources/BrowserCore/Resources/public_suffix_list.dat", data)
        (self.bundle / "Contents/Info.plist").write_text("fixture", encoding="utf-8")

    def test_stage_exact_data_license_pin_and_replace_stale(self):
        old = self.resources / staging.BUNDLE
        old.mkdir(parents=True)
        (old / "stale").write_text("old", encoding="utf-8")
        staging.stage(self.binary, self.resources, self.pin)
        staged = self.resources / staging.BUNDLE / "Contents/Resources/public_suffix_list.dat"
        self.assertEqual(hashlib.sha256(staged.read_bytes()).hexdigest(), staging.DATA_HASH)
        self.assertEqual((self.resources / "PublicSuffix/LICENSE").read_bytes(), (self.pin / "LICENSE").read_bytes())
        self.assertEqual((self.resources / "PublicSuffix/pin.json").read_bytes(), (self.pin / "pin.json").read_bytes())
        self.assertFalse((old / "stale").exists())

    def test_invalid_inputs_rejected_before_replacing_existing_output(self):
        staging.stage(self.binary, self.resources, self.pin)
        output = self.resources / staging.BUNDLE / "Contents/Resources/public_suffix_list.dat"
        data = self.bundle / "Contents/Resources/public_suffix_list.dat"
        original = data.read_bytes()
        cases = ["data", "missing", "license", "pin", "symlink"]
        for case in cases:
            with self.subTest(case=case):
                if case == "data":
                    data.write_bytes(b"tampered")
                elif case == "missing":
                    data.unlink()
                elif case == "license":
                    (self.pin / "LICENSE").write_text("tampered", encoding="utf-8")
                elif case == "pin":
                    pin = json.loads((self.pin / "pin.json").read_text())
                    pin["sha256"] = "0" * 64
                    (self.pin / "pin.json").write_text(json.dumps(pin))
                else:
                    (self.bundle / "link").symlink_to(data)
                with self.assertRaises((OSError, ValueError)):
                    staging.stage(self.binary, self.resources, self.pin)
                self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), staging.DATA_HASH)
                data.write_bytes(original)
                shutil.copyfile(ROOT / "ThirdParty/PublicSuffix/LICENSE", self.pin / "LICENSE")
                shutil.copyfile(ROOT / "ThirdParty/PublicSuffix/pin.json", self.pin / "pin.json")
                (self.bundle / "link").unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
