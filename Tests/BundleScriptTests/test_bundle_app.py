import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "bundle-app.sh"
ICON = REPO / "Resources" / "Branding" / "Arcusis.icns"


class BundleAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bundle-app-tests-")
        self.root = Path(self.temp.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.log = self.root / "commands.log"

        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts" / "bundle-app.sh")
        icon = self.root / "Resources" / "Branding" / "Arcusis.icns"
        icon.parent.mkdir(parents=True)
        shutil.copy2(ICON, icon)
        engine_script = self.root / "scripts" / "fetch-engine.sh"
        engine_script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "printf 'fetch-engine\\n' >> \"$BUNDLE_TEST_LOG\"\n"
            "printf '%s\\n' \"$BUNDLE_TEST_FRAMEWORK\"\n"
        )
        for name in ("LICENSE", "NOTICE", "pin.json"):
            path = self.root / "ThirdParty" / "ArdiaCore" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)

        self.binary_dir = self.root / "swift-bin"
        self.binary_dir.mkdir()
        (self.binary_dir / "ArcusisBrowser").write_text("stub binary")
        self.framework = self.root / "engine" / "Chromium Framework.framework"
        libraries = self.framework / "Versions" / "Current" / "Libraries"
        helpers = self.framework / "Versions" / "Current" / "Helpers"
        libraries.mkdir(parents=True)
        helpers.mkdir(parents=True)
        (libraries / "libengine.dylib").write_text("stub library")
        helper = helpers / "Renderer.app"
        (helper / "Contents").mkdir(parents=True)
        (helper / "Contents" / "MacOS").mkdir()
        (helper / "Contents" / "MacOS" / "Renderer").write_text("stub helper")

        self._tool(
            "swift",
            "printf 'swift %s\\n' \"$*\" >> \"$BUNDLE_TEST_LOG\"\n"
            "if [[ \"$*\" == *--show-bin-path* ]]; then printf '%s\\n' \"$BUNDLE_TEST_BIN\"; fi\n",
        )
        self._tool(
            "codesign",
            "printf 'codesign %s\\n' \"$*\" >> \"$BUNDLE_TEST_LOG\"\n",
        )
        self._tool(
            "ditto",
            "printf 'ditto %s\\n' \"$*\" >> \"$BUNDLE_TEST_LOG\"\n"
            "/bin/cp -R \"$1\" \"$2\"\n",
        )
        self.env = os.environ.copy()
        self.env.update(
            PATH=f"{self.tools}:{self.env['PATH']}",
            BUNDLE_TEST_LOG=str(self.log),
            BUNDLE_TEST_BIN=str(self.binary_dir),
            BUNDLE_TEST_FRAMEWORK=str(self.framework),
        )

    def tearDown(self):
        self.temp.cleanup()

    def _tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(self.root / "scripts" / "bundle-app.sh"), *args],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def _log(self):
        return self.log.read_text() if self.log.exists() else ""

    def _assert_icon_bundle(self, app_path):
        contents = self.root / app_path / "Contents"
        with (contents / "Info.plist").open("rb") as plist_file:
            plist = plistlib.load(plist_file)
        self.assertEqual(plist["CFBundleIconFile"], "Arcusis.icns")
        self.assertEqual((contents / "Resources" / "Arcusis.icns").read_bytes(), ICON.read_bytes())

    def test_default_build_remains_release_shell_bundle(self):
        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build -c release", self._log())
        self.assertIn("Built build/Arcusis Browser Shell.app", result.stdout)
        self.assertIn("not notarized", result.stdout)
        self._assert_icon_bundle("build/Arcusis Browser Shell.app")
        self.assertTrue(
            (self.root / "build/Arcusis Browser Shell.app/Contents/Resources/ArdiaCore/pin.json").is_file()
        )
        self.assertIn("codesign --force --timestamp=none --sign -", self._log())
        self.assertIn("codesign --verify --deep --strict", self._log())

    def test_with_engine_keeps_release_app_and_fetches_pinned_engine(self):
        result = self._run("--with-engine")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build -c release", self._log())
        self.assertIn("fetch-engine", self._log())
        self.assertIn("Built build/Arcusis Browser.app", result.stdout)
        self._assert_icon_bundle("build/Arcusis Browser.app")
        self.assertTrue(
            (self.root / "build/Arcusis Browser.app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Libraries/libengine.dylib").is_file()
        )
        self.assertIn("codesign --verify --deep --strict", self._log())

    def test_debug_configuration_uses_debug_build_and_is_not_release_ready(self):
        result = self._run("--configuration", "debug")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build -c debug", self._log())
        self.assertIn("Built build/Arcusis Browser Shell Debug.app", result.stdout)
        self.assertIn("not notarized or release-ready", result.stdout)
        self._assert_icon_bundle("build/Arcusis Browser Shell Debug.app")
        self.assertIn("codesign --force --timestamp=none --sign -", self._log())
        self.assertNotIn("release-ready", self._log())
        self.assertIn("codesign --verify --deep --strict", self._log())

    def test_debug_with_engine_routes_both_options(self):
        result = self._run("--with-engine", "--configuration", "debug")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build -c debug", self._log())
        self.assertIn("fetch-engine", self._log())
        self.assertIn("Built build/Arcusis Browser Debug.app", result.stdout)
        self.assertIn("not notarized or release-ready", result.stdout)
        self._assert_icon_bundle("build/Arcusis Browser Debug.app")

    def test_invalid_duplicate_and_malformed_options_fail_before_build(self):
        invalid_arguments = (
            ("--unknown",),
            ("--configuration",),
            ("--configuration", "fast"),
            ("--configuration", "debug", "--configuration", "release"),
            ("--with-engine", "--with-engine"),
            ("--configuration", "--with-engine"),
        )
        for args in invalid_arguments:
            with self.subTest(args=args):
                result = self._run(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self._log(), "")


if __name__ == "__main__":
    unittest.main()
