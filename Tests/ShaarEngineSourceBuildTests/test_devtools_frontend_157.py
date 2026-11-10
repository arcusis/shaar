# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin the Chromium 157 DevTools overlay and its registration patches."""

from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
OVERLAY = ROOT / "ThirdParty/ChromiumEngine/devtools-frontend"
THEME = ROOT / "ThirdParty/ChromiumEngine/patches/0061-shaar-devtools-theme-157.patch"
REGISTRATION = (
    ROOT / "ThirdParty/ChromiumEngine/patches/0062-shaar-devtools-frontend-registration.patch"
)
PANEL = OVERLAY / "front_end/panels/shaar"
FEATURE = PANEL / "build-info"


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

    def test_proof_panel_lists_the_pinned_build(self):
        panel = (FEATURE / "BuildInfoPanel.ts").read_text()
        self.assertIn("shaar-devtools-frontend", panel)
        self.assertIn("157.0.8103.51", panel)
        self.assertIn("12ada949de6a27116dea47c600da5322f44c64f4", panel)
        meta = (FEATURE / "build-info-meta.ts").read_text()
        self.assertIn("registerViewExtension", meta)
        self.assertIn("ViewLocationValues.PANEL", meta)

    def test_each_feature_has_one_registration_line(self):
        features = sorted(
            path.name
            for path in PANEL.iterdir()
            if path.is_dir() and (path / "BUILD.gn").is_file()
        )
        self.assertEqual(features, ["build-info"])
        registration = (PANEL / "shaar-meta.ts").read_text()
        imports = [
            line
            for line in registration.splitlines()
            if line.startswith("import './")
        ]
        self.assertEqual(imports, ["import './build-info/build-info-meta.js';"])
        build = (PANEL / "BUILD.gn").read_text()
        self.assertIn('"build-info:meta"', build)
        self.assertEqual(registration.count("import './"), len(features))

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
            frontend["replacesPatch"],
            "ThirdParty/ChromiumEngine/patches/0014-shaar-devtools-theme.patch",
        )
        self.assertEqual(
            frontend["stageScript"],
            "scripts/stage-shaar-devtools-frontend.py",
        )
        pinned = {entry["file"]: entry["sha256"] for entry in frontend["patches"]}
        self.assertEqual(
            pinned[str(THEME.relative_to(ROOT))],
            hashlib.sha256(THEME.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            pinned[str(REGISTRATION.relative_to(ROOT))],
            hashlib.sha256(REGISTRATION.read_bytes()).hexdigest(),
        )
        chromium_155_patches = [entry["file"] for entry in manifest["patches"]]
        self.assertIn(
            "ThirdParty/ChromiumEngine/patches/0014-shaar-devtools-theme.patch",
            chromium_155_patches,
        )
        self.assertNotIn(str(THEME.relative_to(ROOT)), chromium_155_patches)

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


if __name__ == "__main__":
    unittest.main()
