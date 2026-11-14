# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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
        self.audit = write_audit_bundle(self.binary)

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
        staged_audit = self.resources / staging.AUDIT_BUNDLE / "Contents/Resources/InspectorAudit"
        self.assertEqual((staged_audit / "axe.min.js").read_bytes(), b"axe")
        self.assertEqual((staged_audit / "runner.js").read_bytes(), b"runner")

    def test_stage_rejects_symlinked_destination_directory(self):
        outside = self.root / "outside-resources"
        outside.mkdir()
        sentinel = outside / "keep.txt"
        sentinel.write_text("leave untouched", encoding="utf-8")
        self.resources.parent.mkdir(parents=True)
        self.resources.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "resource output directory must not be a symlink"):
            staging.stage(self.binary, self.resources, self.pin)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "leave untouched")
        self.assertEqual(list(outside.iterdir()), [sentinel])

    def test_stage_rejects_symlinked_destination_parent(self):
        outside = self.root / "outside-contents"
        resources = outside / "Resources"
        resources.mkdir(parents=True)
        sentinel = resources / "keep.txt"
        sentinel.write_text("leave untouched", encoding="utf-8")
        self.resources.parent.parent.mkdir(parents=True)
        self.resources.parent.symlink_to(outside, target_is_directory=True)

        def compile_catalog(_catalog, output):
            for language in ("en", "he"):
                localized = output / f"{language}.lproj"
                localized.mkdir(parents=True, exist_ok=True)
                (localized / "Localizable.strings").write_text("\"key\" = \"value\";\n")

        with self.assertRaisesRegex(ValueError, "resource output parent must not be a symlink"):
            with patch.object(staging, "compile_catalog", side_effect=compile_catalog):
                staging.stage(self.binary, self.resources, self.pin)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "leave untouched")
        self.assertFalse((resources / staging.BUNDLE).exists())

    def test_symlinked_resources_parent_is_rejected_before_staging(self):
        external = self.root / "external-contents"
        external.mkdir()
        self.resources.parent.parent.mkdir(parents=True)
        self.resources.parent.symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "resource output parent must not be a symlink"):
            staging.stage(self.binary, self.resources, self.pin)

        self.assertEqual(list(external.iterdir()), [])

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

    def test_audit_bundle_rejects_symlink_empty_and_oversized_files(self):
        staging.stage(self.binary, self.resources, self.pin)
        axe = self.audit / "Contents/Resources/InspectorAudit/axe.min.js"
        original = axe.read_bytes()
        def replace_with_symlink() -> None:
            axe.unlink()
            axe.symlink_to(self.bundle)

        cases = {
            "symlink": replace_with_symlink,
            "empty": lambda: axe.write_bytes(b""),
            "oversize": lambda: axe.write_bytes(b"x" * 2_000_001),
            "missing": lambda: shutil.rmtree(self.audit),
        }
        for name, mutate in cases.items():
            with self.subTest(case=name):
                write_audit_bundle(self.binary)
                axe = self.audit / "Contents/Resources/InspectorAudit/axe.min.js"
                mutate()
                with self.assertRaises(ValueError):
                    staging.stage(self.binary, self.resources, self.pin)
                staged = self.resources / staging.AUDIT_BUNDLE / "Contents/Resources/InspectorAudit/axe.min.js"
                self.assertEqual(staged.read_bytes(), original)
        write_audit_bundle(self.binary)

    def test_ambiguous_audit_layout_is_rejected(self):
        (self.audit / "InspectorAudit").mkdir()
        (self.audit / "InspectorAudit/runner.js").write_text("runner", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "layout is ambiguous"):
            staging.stage(self.binary, self.resources, self.pin)

    def test_unstaged_shipping_bundle_is_rejected_before_replacing_output(self):
        staging.stage(self.binary, self.resources, self.pin)
        extra = self.binary / "ArcusisBrowser_Future.bundle"
        extra.mkdir()
        (extra / "Info.plist").write_text("future", encoding="utf-8")
        output = self.resources / staging.BUNDLE / "Contents/Resources/public_suffix_list.dat"
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "was not staged"):
            staging.stage(self.binary, self.resources, self.pin)
        self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), digest)
        self.assertFalse((self.resources / extra.name).exists())

    def test_symlinked_resources_root_is_rejected_before_staging(self):
        external = self.root / "external-resources"
        external.mkdir()
        self.resources.parent.mkdir(parents=True)
        self.resources.symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "resource output directory must not be a symlink"):
            staging.stage(self.binary, self.resources, self.pin)

        self.assertEqual(list(external.iterdir()), [])

    def test_flat_audit_bundle_is_staged(self):
        shutil.rmtree(self.audit)
        flat = self.binary / staging.AUDIT_BUNDLE / "InspectorAudit"
        flat.mkdir(parents=True)
        (flat / "axe.min.js").write_bytes(b"flat-axe")
        (flat / "runner.js").write_bytes(b"flat-runner")
        staging.stage(self.binary, self.resources, self.pin)
        staged = self.resources / staging.AUDIT_BUNDLE / "InspectorAudit"
        self.assertEqual((staged / "axe.min.js").read_bytes(), b"flat-axe")
        self.assertEqual((staged / "runner.js").read_bytes(), b"flat-runner")


def write_audit_bundle(binary: Path) -> Path:
    bundle = binary / staging.AUDIT_BUNDLE
    if bundle.exists():
        shutil.rmtree(bundle)
    resources = bundle / "Contents/Resources/InspectorAudit"
    resources.mkdir(parents=True)
    (bundle / "Contents/Info.plist").write_text("audit plist", encoding="utf-8")
    (resources / "axe.min.js").write_bytes(b"axe")
    (resources / "runner.js").write_bytes(b"runner")
    return bundle


if __name__ == "__main__":
    unittest.main()
