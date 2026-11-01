# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "bundle-app.sh"
RELEASE_CONFIG = REPO / "scripts" / "release-config.sh"
FEED_SPEC = importlib.util.spec_from_file_location("release_feed", REPO / "scripts" / "release_feed.py")
release_feed = importlib.util.module_from_spec(FEED_SPEC)
sys.modules[FEED_SPEC.name] = release_feed
FEED_SPEC.loader.exec_module(release_feed)
ICON = REPO / "Resources" / "Branding" / "Shaar.icns"
PSL = REPO / "Sources" / "BrowserCore" / "Resources" / "public_suffix_list.dat"


class BundleAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bundle-app-tests-")
        self.root = Path(self.temp.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.log = self.root / "commands.log"

        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts" / "bundle-app.sh")
        for name in ("release-config.sh", "release_feed.py", "engine-signing.sh"):
            shutil.copy2(REPO / "scripts" / name, self.root / "scripts" / name)
        shutil.copy2(REPO / "scripts" / "stage-browser-resources.py", self.root / "scripts")
        shutil.copytree(REPO / "ThirdParty" / "PublicSuffix", self.root / "ThirdParty" / "PublicSuffix")
        icon = self.root / "Resources" / "Branding" / "Shaar.icns"
        icon.parent.mkdir(parents=True)
        shutil.copy2(ICON, icon)
        shutil.copytree(REPO / "Resources" / "ExtensionManager", self.root / "Resources" / "ExtensionManager")
        shutil.copytree(REPO / "Resources" / "Localizations", self.root / "Resources" / "Localizations")
        catalog_dir = self.root / "Sources" / "BrowserCore" / "Resources"
        catalog_dir.mkdir(parents=True)
        for catalog in (REPO / "Sources" / "BrowserCore" / "Resources").glob("*.xcstrings"):
            shutil.copy2(catalog, catalog_dir / catalog.name)
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
        (self.binary_dir / "ShaarVerification").write_text("stub ShaarVerification EngineProbe --engine-probe")
        resource_bundle = self.binary_dir / "ArcusisBrowser_BrowserCore.bundle" / "Contents"
        (resource_bundle / "Resources").mkdir(parents=True)
        shutil.copyfile(PSL, resource_bundle / "Resources" / "public_suffix_list.dat")
        (resource_bundle / "Info.plist").write_text("fixture plist")
        sparkle = self.binary_dir / "Sparkle.framework" / "Versions" / "B"
        (sparkle / "XPCServices" / "Installer.xpc").mkdir(parents=True)
        (sparkle / "Sparkle").write_text("stub sparkle")
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
            "if [[ \"$*\" == *--show-bin-path* ]]; then printf '%s\\n' \"$BUNDLE_TEST_BIN\"; fi\n"
            "arguments=\"$*\"; scratch=${arguments#*--scratch-path }; scratch=${scratch%% *}\n"
            "mkdir -p \"$scratch/artifacts/sparkle/Sparkle\"\n"
            "printf 'sparkle license' > \"$scratch/artifacts/sparkle/Sparkle/LICENSE\"\n",
        )
        self._tool(
            "codesign",
            "if [[ $# -eq 5 && $1 == --force && $2 == --timestamp=none && $3 == --sign && $4 == - ]] || "
            "[[ $# -eq 4 && $1 == --verify && $2 == --deep && $3 == --strict ]]; then\n"
            "  printf 'codesign %s\\n' \"$*\" >> \"$BUNDLE_TEST_LOG\"\n"
            "else printf 'unexpected codesign arguments\\n' >&2; exit 97; fi\n",
        )
        self._tool("security", "printf 'unexpected security invocation\\n' >&2; exit 97\n")
        self._tool("install_name_tool", "printf 'install_name_tool %s\\n' \"$*\" >> \"$BUNDLE_TEST_LOG\"\n")
        self._tool("otool", "printf '         path %s/PackageFrameworks (offset 12)\\n' \"$BUNDLE_TEST_BIN\"\n")
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

    def _run(self, *args, env=None):
        environment = self.env if env is None else env
        for name in ("codesign", "security"):
            self.assertEqual(Path(shutil.which(name, path=environment["PATH"])), self.tools / name)
        return subprocess.run(
            ["bash", str(self.root / "scripts" / "bundle-app.sh"), *args],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
        )

    def _log(self):
        return self.log.read_text() if self.log.exists() else ""

    def _assert_staged_resources(self, contents):
        resources = contents / "Resources"
        bundle = resources / "ArcusisBrowser_BrowserCore.bundle" / "Contents"
        self.assertEqual((bundle / "Resources" / "public_suffix_list.dat").read_bytes(), PSL.read_bytes())
        self.assertEqual((bundle / "Info.plist").read_text(), "fixture plist")
        for language in ("en", "he"):
            localized = bundle / "Resources" / f"{language}.lproj"
            for table in ("Core", "Bridge", "Shell", "Settings", "Panels"):
                # The native compiler omits English identity values that equal their keys.
                self.assertTrue(any((localized / f"{table}.{suffix}").is_file()
                                    for suffix in ("strings", "stringsdict")), table)
            self.assertTrue((localized / "Core.stringsdict").is_file())
            self.assertTrue((resources / f"{language}.lproj" / "InfoPlist.strings").is_file())
        for name in ("LICENSE", "pin.json"):
            self.assertEqual(
                (resources / "PublicSuffix" / name).read_bytes(),
                (REPO / "ThirdParty" / "PublicSuffix" / name).read_bytes(),
            )

    def _assert_icon_bundle(self, app_path):
        contents = self.root / app_path / "Contents"
        self._assert_staged_resources(contents)
        with (contents / "Info.plist").open("rb") as plist_file:
            plist = plistlib.load(plist_file)
        self.assertEqual(plist["CFBundleIconFile"], "Shaar.icns")
        self.assertIn("passkey", plist["NSBluetoothAlwaysUsageDescription"])
        self.assertEqual((contents / "Resources" / "Shaar.icns").read_bytes(), ICON.read_bytes())
        manager = contents / "Resources" / "ExtensionManager" / "manifest.json"
        self.assertEqual(manager.read_bytes(), (REPO / "Resources" / "ExtensionManager" / "manifest.json").read_bytes())

    def _info_plist(self, app_path):
        with (self.root / app_path / "Contents" / "Info.plist").open("rb") as plist_file:
            return plistlib.load(plist_file)

    def test_every_bundle_embeds_sparkle_without_update_feed(self):
        for args, app_path in (((), "build/Shaar Shell.app"), (("--with-engine",), "build/Shaar.app")):
            with self.subTest(args=args):
                result = self._run(*args)

                self.assertEqual(result.returncode, 0, result.stderr)
                sparkle = self.root / app_path / "Contents/Frameworks/Sparkle.framework/Versions/B"
                self.assertEqual((sparkle / "Sparkle").read_text(), "stub sparkle")
                self.assertTrue((sparkle / "XPCServices/Installer.xpc").is_dir())
                license_path = self.root / app_path / "Contents/Resources/Sparkle/LICENSE"
                self.assertEqual(license_path.read_text(), "sparkle license")
                self.assertNotIn("Sparkle.framework", "".join(
                    line for line in self._log().splitlines(keepends=True) if line.startswith("codesign --force")
                ))
                plist = self._info_plist(app_path)
                self.assertFalse({key for key in plist if key.startswith("SU")})
                config = release_feed.load_config(RELEASE_CONFIG)
                self.assertEqual(plist["CFBundleIdentifier"], config.bundle_identifier)
                self.assertEqual(plist["CFBundleShortVersionString"], config.bundle_version)
                self.assertEqual(plist["CFBundleVersion"], str(config.build_version))
                self.assertEqual(plist["LSMinimumSystemVersion"], config.minimum_system_version)
                self.assertIn(f"install_name_tool -delete_rpath {self.binary_dir}/PackageFrameworks", self._log())

    def test_with_updates_writes_sparkle_feed_keys_from_release_config(self):
        result = self._run("--with-engine", "--with-updates")

        self.assertEqual(result.returncode, 0, result.stderr)
        plist = self._info_plist("build/Shaar.app")
        config = release_feed.load_config(RELEASE_CONFIG)
        self.assertEqual(plist["SUFeedURL"], config.feed_url)
        self.assertEqual(plist["SUPublicEDKey"], config.public_ed_key)
        self.assertIs(plist["SUEnableAutomaticChecks"], True)
        self.assertIs(plist["SUEnableInstallerLauncherService"], True)

    def test_with_updates_is_rejected_outside_release_engine_bundles(self):
        for args in (
            ("--with-updates",),
            ("--with-updates", "--configuration", "debug"),
            ("--with-engine", "--with-updates", "--configuration", "debug"),
        ):
            with self.subTest(args=args):
                result = self._run(*args)

                self.assertEqual(result.returncode, 2)
                self.assertIn("--with-updates requires --configuration release and --with-engine", result.stderr)
                self.assertEqual(self._log(), "")
                self.assertFalse((self.root / "build").exists())

    def test_unsafe_release_config_is_rejected_before_bash_sources_it(self):
        config = self.root / "scripts" / "release-config.sh"
        config.write_text(config.read_text().replace("SHAAR_BUILD_VERSION=1", "SHAAR_BUILD_VERSION=1;touch pwned"))

        result = self._run("--with-engine")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHAAR_KEY=value", result.stderr)
        self.assertFalse((self.root / "pwned").exists())
        self.assertEqual(self._log(), "")

    def test_default_build_remains_release_shell_bundle(self):
        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build --manifest-cache none --scratch-path build/swiftpm/default -c release", self._log())
        self.assertIn("Built build/Shaar Shell.app", result.stdout)
        self.assertIn("not notarized", result.stdout)
        self._assert_icon_bundle("build/Shaar Shell.app")
        self.assertTrue(
            (self.root / "build/Shaar Shell.app/Contents/Resources/ArdiaCore/pin.json").is_file()
        )
        self.assertIn("codesign --force --timestamp=none --sign -", self._log())
        self.assertIn("codesign --verify --deep --strict", self._log())

    def test_with_engine_keeps_release_app_and_fetches_pinned_engine(self):
        result = self._run("--with-engine")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build --manifest-cache none --scratch-path build/swiftpm/default -c release", self._log())
        self.assertIn("fetch-engine", self._log())
        self.assertIn("Built build/Shaar.app", result.stdout)
        self._assert_icon_bundle("build/Shaar.app")
        self.assertTrue(
            (self.root / "build/Shaar.app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Libraries/libengine.dylib").is_file()
        )
        self.assertIn("codesign --verify --deep --strict", self._log())

    def test_debug_configuration_uses_debug_build_and_is_not_release_ready(self):
        result = self._run("--configuration", "debug")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build --manifest-cache none --scratch-path build/swiftpm/default -c debug", self._log())
        self.assertIn("Built build/Shaar Shell Debug.app", result.stdout)
        self.assertIn("not notarized or release-ready", result.stdout)
        self._assert_icon_bundle("build/Shaar Shell Debug.app")
        self.assertIn("codesign --force --timestamp=none --sign -", self._log())
        self.assertNotIn("release-ready", self._log())
        self.assertIn("codesign --verify --deep --strict", self._log())

    def test_debug_with_engine_routes_both_options(self):
        result = self._run("--with-engine", "--configuration", "debug")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build --manifest-cache none --scratch-path build/swiftpm/default -c debug", self._log())
        self.assertIn("fetch-engine", self._log())
        self.assertIn("Built build/Shaar Debug.app", result.stdout)
        self.assertIn("not notarized or release-ready", result.stdout)
        self._assert_icon_bundle("build/Shaar Debug.app")

    def test_shipping_builds_never_enable_testing_or_build_the_harness(self):
        for args in ((), ("--with-engine",), ("--with-engine", "--with-updates")):
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                result = self._run(*args)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("-c release --product ArcusisBrowser\n", self._log())
                self.assertNotIn("enable-testing", self._log())
                self.assertNotIn("ShaarVerification", self._log())

    def test_shipping_bundle_rejects_executable_with_verification_code(self):
        for marker in ("ShaarVerification", "EngineProbe", "--engine-probe", "--probe-data-dir"):
            with self.subTest(marker=marker):
                self.log.unlink(missing_ok=True)
                (self.binary_dir / "ArcusisBrowser").write_text(f"stub binary {marker}")
                result = self._run("--with-engine")

                self.assertEqual(result.returncode, 1)
                self.assertIn("Verification code found", result.stderr)
                self.assertNotIn("codesign", self._log())

    def test_verification_builds_separate_testable_harness_bundle(self):
        result = self._run("--with-engine", "--verification")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "swift build --manifest-cache none --scratch-path build/swiftpm/verification -c release "
            "--product ShaarVerification -Xswiftc -enable-testing",
            self._log(),
        )
        self.assertNotIn("build/swiftpm/default", self._log())
        self.assertIn("Built build/Shaar Verification.app", result.stdout)
        plist = self._info_plist("build/Shaar Verification.app")
        config = release_feed.load_config(RELEASE_CONFIG)
        self.assertEqual(plist["CFBundleExecutable"], "ShaarVerification")
        self.assertEqual(plist["CFBundleIdentifier"], config.verification_bundle_identifier)
        self.assertNotEqual(plist["CFBundleIdentifier"], config.bundle_identifier)
        self.assertTrue((self.root / "build/Shaar Verification.app/Contents/MacOS/ShaarVerification").is_file())
        self.assertFalse((self.root / "build/Shaar Verification.app/Contents/MacOS/ArcusisBrowser").exists())
        self.assertTrue(
            (self.root / "build/Shaar Verification.app/Contents/Frameworks/Chromium Framework.framework").is_dir()
        )
        self.assertFalse((self.root / "build/Shaar.app").exists())

    def test_verification_requires_engine_and_never_carries_updates(self):
        for args in (("--verification",), ("--with-engine", "--with-updates", "--verification")):
            with self.subTest(args=args):
                result = self._run(*args)

                self.assertEqual(result.returncode, 2)
                self.assertIn("--verification requires --with-engine and excludes --with-updates", result.stderr)
                self.assertEqual(self._log(), "")

    def test_resource_corruption_stops_bundle_before_signing(self):
        data = self.binary_dir / "ArcusisBrowser_BrowserCore.bundle/Contents/Resources/public_suffix_list.dat"
        data.write_text("corrupt")

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BrowserCore resource hash mismatch", result.stderr)
        self.assertNotIn("codesign", self._log())

    def test_invalid_duplicate_and_malformed_options_fail_before_build(self):
        invalid_arguments = (
            ("--unknown",),
            ("--configuration",),
            ("--configuration", "fast"),
            ("--configuration", "debug", "--configuration", "release"),
            ("--with-engine", "--with-engine"),
            ("--with-updates", "--with-updates"),
            ("--verification", "--verification"),
            ("--configuration", "--with-engine"),
        )
        for args in invalid_arguments:
            with self.subTest(args=args):
                result = self._run(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self._log(), "")


if __name__ == "__main__":
    unittest.main()
