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
            "printf 'swift sdk=%s %s\\n' \"${ARCUSIS_NATIVE_BITWARDEN_SDK-<unset>}\" \"$*\" >> \"$BUNDLE_TEST_LOG\"\n"
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
        self.assertIn("swift sdk=0 build --manifest-cache none --scratch-path build/swiftpm/default -c release", self._log())
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
        self.assertIn("swift sdk=0 build --manifest-cache none --scratch-path build/swiftpm/default -c release", self._log())
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
        self.assertIn("swift sdk=0 build --manifest-cache none --scratch-path build/swiftpm/default -c debug", self._log())
        self.assertIn("Built build/Arcusis Browser Shell Debug.app", result.stdout)
        self.assertIn("not notarized or release-ready", result.stdout)
        self._assert_icon_bundle("build/Arcusis Browser Shell Debug.app")
        self.assertIn("codesign --force --timestamp=none --sign -", self._log())
        self.assertNotIn("release-ready", self._log())
        self.assertIn("codesign --verify --deep --strict", self._log())

    def test_debug_with_engine_routes_both_options(self):
        result = self._run("--with-engine", "--configuration", "debug")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift sdk=0 build --manifest-cache none --scratch-path build/swiftpm/default -c debug", self._log())
        self.assertIn("fetch-engine", self._log())
        self.assertIn("Built build/Arcusis Browser Debug.app", result.stdout)
        self.assertIn("not notarized or release-ready", result.stdout)
        self._assert_icon_bundle("build/Arcusis Browser Debug.app")

    def test_sdk_free_rebundle_removes_stale_sdk_payload(self):
        app = self.root / "build/Arcusis Browser Shell Debug.app/Contents"
        stale_library = app / "Frameworks/libbitwarden_uniffi.dylib"
        stale_notice = app / "Resources/NativeBitwardenSDK/ThirdPartyNotices/LICENSE_SDK.txt"
        stale_library.parent.mkdir(parents=True)
        stale_notice.parent.mkdir(parents=True)
        stale_library.write_text("stale sdk")
        stale_notice.write_text("stale notice")

        result = self._run("--configuration", "debug")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale_library.exists())
        self.assertFalse((app / "Resources/NativeBitwardenSDK").exists())

    def test_bundle_mode_owns_sdk_flag_and_removes_stale_payload(self):
        app = self.root / "build/Arcusis Browser Shell Debug.app/Contents"
        stale_library = app / "Frameworks/libbitwarden_uniffi.dylib"
        stale_notice = app / "Resources/NativeBitwardenSDK/ThirdPartyNotices/LICENSE_SDK.txt"
        stale_library.parent.mkdir(parents=True)
        stale_notice.parent.mkdir(parents=True)
        stale_library.write_text("stale sdk")
        stale_notice.write_text("stale notice")
        inherited_sdk_environment = self.env | {"ARCUSIS_NATIVE_BITWARDEN_SDK": "1"}

        source_only = subprocess.run(
            ["bash", str(self.root / "scripts/bundle-app.sh"), "--configuration", "debug"],
            cwd=self.root,
            env=inherited_sdk_environment,
            capture_output=True,
            text=True,
        )

        self.assertEqual(source_only.returncode, 0, source_only.stderr)
        self.assertFalse(stale_library.exists())
        self.assertFalse((app / "Resources/NativeBitwardenSDK").exists())
        self.assertIn("swift sdk=0 build --manifest-cache none --scratch-path build/swiftpm/default", self._log())
        self.assertIn("swift sdk=0 build --manifest-cache none --scratch-path build/swiftpm/default -c debug --show-bin-path", self._log())

        package = self.root / "build/NativeBitwardenSDK/Package"
        dylib = package / "Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib"
        dylib.parent.mkdir(parents=True)
        dylib.write_bytes(b"validated sdk dylib")
        notices = package / "ThirdPartyNotices"
        notices.mkdir()
        for name in ("DISCLAIMER.md", "LICENSE", "LICENSE_GPL.txt", "LICENSE_SDK.txt"):
            (notices / name).write_text(name)
        validator = self.tools / "python-validator"
        validator.write_text("#!/bin/bash\nset -euo pipefail\ncat >/dev/null\n")
        validator.chmod(0o755)
        self._tool("install_name_tool", "printf 'install_name_tool %s\\n' \"$*\" >> \"$BUNDLE_TEST_LOG\"\n")

        sdk_enabled = subprocess.run(
            [
                "bash", str(self.root / "scripts/bundle-app.sh"), "--configuration", "debug",
                "--with-native-bitwarden-sdk",
            ],
            cwd=self.root,
            env=inherited_sdk_environment | {"PYTHON": str(validator)},
            capture_output=True,
            text=True,
        )

        self.assertEqual(sdk_enabled.returncode, 0, sdk_enabled.stderr)
        log = self._log()
        self.assertIn("swift sdk=1 build --manifest-cache none --scratch-path build/swiftpm/native-bitwarden-sdk", log)
        self.assertIn("swift sdk=1 build --manifest-cache none --scratch-path build/swiftpm/native-bitwarden-sdk -c debug --show-bin-path", log)

    def test_default_sdk_default_switch_keeps_mode_scratch_and_removes_sdk_payload(self):
        first = self._run("--configuration", "debug")
        self.assertEqual(first.returncode, 0, first.stderr)
        default_scratch = self.root / "build/swiftpm/default"
        default_marker = default_scratch / "cache-marker"
        default_marker.write_text("preserved")

        package = self.root / "build/NativeBitwardenSDK/Package"
        dylib = package / "Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib"
        dylib.parent.mkdir(parents=True)
        dylib.write_bytes(b"validated sdk dylib")
        notices = package / "ThirdPartyNotices"
        notices.mkdir()
        for name in ("DISCLAIMER.md", "LICENSE", "LICENSE_GPL.txt", "LICENSE_SDK.txt"):
            (notices / name).write_text(name)
        validator = self.tools / "python-validator"
        validator.write_text("#!/bin/bash\nset -euo pipefail\ncat >/dev/null\n")
        validator.chmod(0o755)
        self._tool(
            "install_name_tool",
            "printf 'install_name_tool %s\\n' \"$*\" >> \"$BUNDLE_TEST_LOG\"\n",
        )
        environment = self.env | {"PYTHON": str(validator)}
        sdk = subprocess.run(
            ["bash", str(self.root / "scripts/bundle-app.sh"), "--configuration", "debug",
             "--with-native-bitwarden-sdk"],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(sdk.returncode, 0, sdk.stderr)
        sdk_scratch = self.root / "build/swiftpm/native-bitwarden-sdk"
        sdk_marker = sdk_scratch / "cache-marker"
        sdk_marker.write_text("preserved")

        final = self._run("--configuration", "debug")
        self.assertEqual(final.returncode, 0, final.stderr)
        self.assertTrue(default_marker.is_file())
        self.assertTrue(sdk_marker.is_file())
        app = self.root / "build/Arcusis Browser Shell Debug.app/Contents"
        self.assertFalse((app / "Frameworks/libbitwarden_uniffi.dylib").exists())
        self.assertFalse((app / "Resources/NativeBitwardenSDK").exists())
        log = self._log()
        self.assertNotIn("swift package reset", log)
        self.assertIn("--manifest-cache none --scratch-path build/swiftpm/default", log)
        self.assertIn("--manifest-cache none --scratch-path build/swiftpm/native-bitwarden-sdk", log)

    def test_sdk_bundle_requires_package_before_build(self):
        result = self._run("--with-native-bitwarden-sdk")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Native Bitwarden SDK package missing", result.stderr)
        self.assertEqual(self._log(), "")

    def test_opt_in_sdk_bundle_validates_then_copies_only_dylib_and_notices(self):
        package = self.root / "build/NativeBitwardenSDK/Package"
        dylib = package / "Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib"
        notices = package / "ThirdPartyNotices"
        dylib.parent.mkdir(parents=True)
        notices.mkdir(parents=True)
        dylib.write_bytes(b"validated sdk dylib")
        for name in ("DISCLAIMER.md", "LICENSE", "LICENSE_GPL.txt", "LICENSE_SDK.txt"):
            (notices / name).write_text(name)
        (notices / "unrelated-source.txt").write_text("must not be bundled")
        validator = self.tools / "python-validator"
        validator.write_text(
            "#!/bin/bash\nset -euo pipefail\n"
            "printf 'validate sdk package\\n' >> \"$BUNDLE_TEST_LOG\"\n"
            "cat >/dev/null\n"
        )
        validator.chmod(0o755)
        self._tool(
            "install_name_tool",
            "printf 'install_name_tool %s\\n' \"$*\" >> \"$BUNDLE_TEST_LOG\"\n",
        )
        environment = self.env | {"PYTHON": str(validator)}

        result = subprocess.run(
            [
                "bash", str(self.root / "scripts/bundle-app.sh"), "--configuration", "debug",
                "--with-native-bitwarden-sdk",
            ],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not notarized or release-ready", result.stdout)
        app = self.root / "build/Arcusis Browser Shell Debug.app/Contents"
        bundled_library = app / "Frameworks/libbitwarden_uniffi.dylib"
        self.assertEqual(bundled_library.read_bytes(), b"validated sdk dylib")
        self.assertEqual(
            (app / "Resources/NativeBitwardenSDK/ThirdPartyNotices/LICENSE_SDK.txt").read_text(),
            "LICENSE_SDK.txt",
        )
        self.assertFalse(
            (app / "Resources/NativeBitwardenSDK/ThirdPartyNotices/unrelated-source.txt").exists()
        )
        log = self._log()
        self.assertLess(log.index("validate sdk package"), log.index("swift sdk=1 build"))
        self.assertIn("@rpath/libbitwarden_uniffi.dylib", log)
        self.assertIn("install_name_tool -delete_rpath", log)
        self.assertIn("PackageFrameworks", log)
        self.assertIn("codesign --force --timestamp=none --sign -", log)

    def test_invalid_duplicate_and_malformed_options_fail_before_build(self):
        invalid_arguments = (
            ("--unknown",),
            ("--configuration",),
            ("--configuration", "fast"),
            ("--configuration", "debug", "--configuration", "release"),
            ("--with-engine", "--with-engine"),
            ("--with-native-bitwarden-sdk", "--with-native-bitwarden-sdk"),
            ("--configuration", "--with-engine"),
        )
        for args in invalid_arguments:
            with self.subTest(args=args):
                result = self._run(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self._log(), "")


if __name__ == "__main__":
    unittest.main()
