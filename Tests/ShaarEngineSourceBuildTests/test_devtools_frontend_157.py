# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin the Chromium 157 DevTools overlay and its registration patches."""

from pathlib import Path
import hashlib
import importlib.util
import json
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
OVERLAY = ROOT / "ThirdParty/ChromiumEngine/devtools-frontend"
THEME = ROOT / "ThirdParty/ChromiumEngine/patches/0064-shaar-devtools-theme-157.patch"
REGISTRATION = (
    ROOT / "ThirdParty/ChromiumEngine/patches/0065-shaar-devtools-frontend-registration.patch"
)
PANEL = OVERLAY / "front_end/panels/shaar"
FEATURE = PANEL / "build-info"
FEATURE_IMPORT = re.compile(r"import '\./([A-Za-z0-9_-]+)/\1-meta\.js';\Z")


def gn_block(source: str, header: str) -> str:
    match = re.search(rf"{header}\s*\{{(.*?)\n\}}", source, re.DOTALL)
    if match is None:
        raise AssertionError(f"missing {header}")
    return match.group(1)


def gn_strings(block: str, name: str) -> list[str]:
    match = re.search(rf"\b{name}\s*=\s*\[(.*?)\]", block, re.DOTALL)
    if match is None:
        raise AssertionError(f"missing {name}")
    return re.findall(r'"([^"]+)"', match.group(1))


def load_stage():
    path = ROOT / "scripts/stage-shaar-devtools-frontend.py"
    spec = importlib.util.spec_from_file_location("stage_shaar_devtools_frontend", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DevToolsFrontend157Tests(unittest.TestCase):
    def test_theme_patch_targets_the_157_frontend(self):
        source = THEME.read_text()
        self.assertIn("isShaarEmbedder", source)
        self.assertIn("shaar-theme", source)
        self.assertIn("getChromeDevToolsForAgents", source)
        self.assertIn("domTreeWidget.css", source)
        self.assertIn("#026748", source)
        self.assertIn("#83f0b4", source)
        self.assertNotIn("elementsTreeOutline.css", source)
        self.assertNotIn("getDevToolsMcp", source)

    def test_registration_patch_adds_the_shaar_panel(self):
        source = REGISTRATION.read_text()
        self.assertIn("shaar-meta.js", source)
        self.assertIn("../../panels/shaar:meta", source)
        self.assertIn("panels/shaar:unittests", source)

    def test_proof_panel_lists_the_pinned_build(self):
        panel = (FEATURE / "BuildInfoPanel.ts").read_text()
        self.assertIn("shaar-devtools-frontend", panel)
        self.assertIn("157.0.8103.51", panel)
        self.assertIn("12ada949de6a27116dea47c600da5322f44c64f4", panel)
        meta = (FEATURE / "build-info-meta.ts").read_text()
        self.assertIn("registerViewExtension", meta)
        self.assertIn("ViewLocationValues.PANEL", meta)

    def test_each_feature_has_one_registration_line(self):
        registration = (PANEL / "shaar-meta.ts").read_text()
        features = []
        for line in registration.splitlines():
            if not line.startswith("import './"):
                continue
            match = FEATURE_IMPORT.fullmatch(line)
            self.assertIsNotNone(match, line)
            features.append(match.group(1))
        self.assertEqual(len(features), len(set(features)))
        self.assertGreater(len(features), 0)
        directories = sorted(
            path.name
            for path in PANEL.iterdir()
            if path.is_dir() and (path / "BUILD.gn").is_file()
        )
        self.assertEqual(sorted(features), directories)
        for feature in features:
            meta = PANEL / feature / f"{feature}-meta.ts"
            self.assertTrue(meta.is_file(), str(meta))
        build = (PANEL / "BUILD.gn").read_text()
        meta_block = gn_block(build, r'devtools_entrypoint\("meta"\)')
        unit_block = gn_block(build, r'group\("unittests"\)')
        self.assertEqual(
            gn_strings(meta_block, "ts_deps"),
            [f"{feature}:meta" for feature in features],
        )
        self.assertEqual(
            gn_strings(unit_block, "deps"),
            [f"{feature}:unittests" for feature in features],
        )

    def test_patches_are_pinned_for_the_157_checkout(self):
        manifest = json.loads(MANIFEST.read_text())
        frontend = manifest["devtoolsFrontend157"]
        self.assertEqual(frontend["chromium"], "157.0.8103.51")
        self.assertEqual(
            frontend["devtoolsFrontendRevision"],
            "12ada949de6a27116dea47c600da5322f44c64f4",
        )
        self.assertEqual(
            frontend["overlay"],
            "ThirdParty/ChromiumEngine/devtools-frontend",
        )
        self.assertEqual(
            frontend["featureRoot"],
            "ThirdParty/ChromiumEngine/devtools-frontend/front_end/panels/shaar",
        )
        self.assertEqual(
            frontend["registration"],
            "ThirdParty/ChromiumEngine/devtools-frontend/front_end/panels/shaar/shaar-meta.ts",
        )
        self.assertEqual(
            frontend["copyTo"],
            "third_party/devtools-frontend/src/front_end/panels/shaar",
        )
        self.assertEqual(
            frontend["stageScript"],
            "scripts/stage-shaar-devtools-frontend.py",
        )
        self.assertNotIn("patches", frontend)
        pinned = {entry["file"]: entry["sha256"] for entry in manifest["patches"]}
        self.assertEqual(
            pinned[str(THEME.relative_to(ROOT))],
            hashlib.sha256(THEME.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            pinned[str(REGISTRATION.relative_to(ROOT))],
            hashlib.sha256(REGISTRATION.read_bytes()).hexdigest(),
        )
        active_patches = [entry["file"] for entry in manifest["patches"]]
        self.assertNotIn(
            "ThirdParty/ChromiumEngine/patches/0014-shaar-devtools-theme.patch",
            active_patches,
        )
        self.assertEqual(THEME.name, "0064-shaar-devtools-theme-157.patch")
        self.assertEqual(
            REGISTRATION.name, "0065-shaar-devtools-frontend-registration.patch"
        )
        self.assertEqual(active_patches.count(str(THEME.relative_to(ROOT))), 1)
        self.assertEqual(active_patches.count(str(REGISTRATION.relative_to(ROOT))), 1)
        self.assertLess(active_patches.index(str(THEME.relative_to(ROOT))),
                        active_patches.index(str(REGISTRATION.relative_to(ROOT))))

    def test_stage_hardlinks_the_panel_into_panels_shaar(self):
        stage = load_stage()
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "front_end" / "panels" / "shaar"
            staged = stage.stage(PANEL, destination)
            self.assertIn("shaar-meta.ts", staged)
            self.assertIn("build-info/BuildInfoPanel.ts", staged)
            self.assertIn("BUILD.gn", staged)
            self.assertEqual(
                (destination / "build-info" / "BuildInfoPanel.ts").read_bytes(),
                (FEATURE / "BuildInfoPanel.ts").read_bytes(),
            )

    def test_stage_rejects_symlinked_overlay_files(self):
        stage = load_stage()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            overlay = root / "overlay"
            destination = root / "front_end" / "panels" / "shaar"
            overlay.mkdir()
            external = root / "outside.ts"
            external.write_text("external source")
            (overlay / "linked.ts").symlink_to(external)
            with self.assertRaisesRegex(SystemExit, "overlay symlink"):
                stage.stage(overlay, destination)
            self.assertFalse((destination / "linked.ts").exists())

    def test_stage_rejects_symlinked_overlay_root(self):
        stage = load_stage()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            external = root / "external"
            external.mkdir()
            overlay = root / "overlay"
            overlay.symlink_to(external, target_is_directory=True)
            destination = root / "front_end" / "panels" / "shaar"
            with self.assertRaisesRegex(SystemExit, "Missing overlay"):
                stage.stage(overlay, destination)

    def test_stage_rejects_symlinked_destination_before_writing_outside_tree(self):
        stage = load_stage()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            external = root / "external"
            external.mkdir()
            sentinel = external / "keep.txt"
            sentinel.write_text("leave untouched")
            destination = root / "front_end" / "panels" / "shaar"
            destination.parent.mkdir(parents=True)
            destination.symlink_to(external, target_is_directory=True)

            with self.assertRaisesRegex(SystemExit, "destination.*symlink"):
                stage.stage(PANEL, destination)

            self.assertEqual(list(external.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_text(), "leave untouched")
            self.assertFalse((external / "shaar-meta.ts").exists())

    def test_stage_rejects_symlinked_nested_destination_directory(self):
        stage = load_stage()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "front_end" / "panels" / "shaar"
            (destination / "build-info").mkdir(parents=True)
            external = root / "external"
            external.mkdir()
            nested = destination / "build-info"
            nested.rmdir()
            nested.symlink_to(external, target_is_directory=True)
            with self.assertRaisesRegex(SystemExit, "destination symlink"):
                stage.stage(PANEL, destination)
            self.assertFalse((external / "BuildInfoPanel.ts").exists())

    def test_stage_rejects_symlinked_panels_parent(self):
        stage = load_stage()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            front_end = root / "front_end"
            front_end.mkdir()
            external = root / "external"
            external.mkdir()
            panels = front_end / "panels"
            panels.symlink_to(external, target_is_directory=True)
            destination = panels / "shaar"
            with self.assertRaisesRegex(SystemExit, "symlinked panels directory"):
                stage.stage(PANEL, destination)
            self.assertFalse((external / "shaar-meta.ts").exists())


if __name__ == "__main__":
    unittest.main()
