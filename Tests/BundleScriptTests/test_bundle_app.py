# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import json
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
ALERT_HELPERS = (
    "Chromium Helper (Alerts).app",
    "Chromium Helper (Aperitif Alerts).app",
)


class BundleAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bundle-app-tests-")
        self.root = Path(self.temp.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.log = self.root / "commands.log"

        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts" / "bundle-app.sh")
        for name in (
            "release-config.sh", "release_feed.py", "engine-signing.sh",
            "check-shipping-harness.py",
        ):
            shutil.copy2(REPO / "scripts" / name, self.root / "scripts" / name)
        shutil.copy2(REPO / "scripts" / "stage-browser-resources.py", self.root / "scripts")
        shutil.copy2(REPO / "scripts" / "fetch-framework-devtools.py", self.root / "scripts")
        shutil.copy2(REPO / "scripts" / "rebrand-engine-framework.py", self.root / "scripts")
        shutil.copytree(REPO / "ThirdParty" / "PublicSuffix", self.root / "ThirdParty" / "PublicSuffix")
        shutil.copytree(REPO / "ThirdParty" / "FrameworkDevTools", self.root / "ThirdParty" / "FrameworkDevTools")
        shutil.copytree(REPO / "ThirdParty" / "ChromiumEngine" / "notices",
                        self.root / "ThirdParty" / "ChromiumEngine" / "notices")
        icon = self.root / "Resources" / "Branding" / "Shaar.icns"
        icon.parent.mkdir(parents=True)
        shutil.copy2(ICON, icon)
        shutil.copytree(REPO / "Resources" / "ExtensionManager", self.root / "Resources" / "ExtensionManager")
        shutil.copytree(REPO / "Resources" / "FrameworkDevTools", self.root / "Resources" / "FrameworkDevTools")
        shutil.copytree(REPO / "Resources" / "Localizations", self.root / "Resources" / "Localizations")
        shutil.copytree(REPO / "Resources" / "Privacy", self.root / "Resources" / "Privacy")
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
        shaar_engine_script = self.root / "scripts" / "fetch-shaar-test-engine.sh"
        shaar_engine_script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "printf 'fetch-shaar-test-engine\\n' >> \"$BUNDLE_TEST_LOG\"\n"
            "printf '%s\\n' \"$BUNDLE_TEST_FRAMEWORK\"\n"
        )
        for name in ("pin.json",):
            path = self.root / "ThirdParty" / "ChromiumEngine" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
            (self.root / name).write_text(name)

        self.binary_dir = self.root / "swift-bin"
        self.binary_dir.mkdir()
        (self.binary_dir / "ArcusisBrowser").write_text("stub binary")
        (self.binary_dir / "ShaarVerification").write_text(
            "stub ShaarVerification EngineProbe --engine-probe ShaarBrowsingEdgeProbe --browsing-edge-probe"
        )
        resource_bundle = self.binary_dir / "ArcusisBrowser_BrowserCore.bundle" / "Contents"
        (resource_bundle / "Resources").mkdir(parents=True)
        shutil.copyfile(PSL, resource_bundle / "Resources" / "public_suffix_list.dat")
        (resource_bundle / "Info.plist").write_text("fixture plist")
        audit = self.binary_dir / "ArcusisBrowser_ArcusisBrowser.bundle" / "Contents"
        (audit / "Resources" / "InspectorAudit").mkdir(parents=True)
        (audit / "Info.plist").write_text("audit plist")
        (audit / "Resources" / "InspectorAudit" / "axe.min.js").write_text("axe")
        (audit / "Resources" / "InspectorAudit" / "runner.js").write_text("runner")
        sparkle = self.binary_dir / "Sparkle.framework" / "Versions" / "B"
        (sparkle / "XPCServices" / "Installer.xpc").mkdir(parents=True)
        (sparkle / "Sparkle").write_text("stub sparkle")
        self.framework = self.root / "engine" / "Chromium Framework.framework"
        libraries = self.framework / "Versions" / "Current" / "Libraries"
        helpers = self.framework / "Versions" / "Current" / "Helpers"
        libraries.mkdir(parents=True)
        helpers.mkdir(parents=True)
        (libraries / "libengine.dylib").write_text("stub library")
        resources = self.framework / "Versions" / "Current" / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "legacy.framework"}))
        for name in (
            "Chromium Helper.app", "Chromium Helper (GPU).app",
            "Chromium Helper (Renderer).app", "Chromium Helper (Alerts).app",
            "Chromium Helper (Aperitif).app", "Chromium Helper (Aperitif GPU).app",
            "Chromium Helper (Aperitif Renderer).app", "Chromium Helper (Aperitif Alerts).app",
        ):
            helper = helpers / name
            (helper / "Contents/MacOS").mkdir(parents=True)
            info = {"CFBundleIdentifier": "legacy.helper"}
            if name in ALERT_HELPERS:
                info.update(CFBundleName=name.removesuffix(".app"),
                            CFBundleDisplayName=name.removesuffix(".app"),
                            CFBundleIconFile="app.icns", CFBundleIconName="AppIcon")
                alert_resources = helper / "Contents/Resources"
                alert_resources.mkdir()
                (alert_resources / "app.icns").write_bytes(b"Chromium placeholder icon")
                (alert_resources / "Assets.car").write_bytes(b"Chromium placeholder assets")
            (helper / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            (helper / "Contents/MacOS/Helper").write_text("stub helper")

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
            SHAAR_FRAMEWORK_DEVTOOLS_CACHE=str(REPO / "build" / "cache" / "framework-devtools"),
        )
        self.env.pop("SHAAR_MOCK_KEYCHAIN", None)

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
        self.assertEqual(
            (resources / "Privacy" / "tracker-domains.json").read_bytes(),
            (REPO / "Resources" / "Privacy" / "tracker-domains.json").read_bytes(),
        )
        self.assertEqual((bundle / "Info.plist").read_text(), "fixture plist")
        audit = resources / "ArcusisBrowser_ArcusisBrowser.bundle" / "Contents/Resources/InspectorAudit"
        self.assertEqual((audit / "axe.min.js").read_text(), "axe")
        self.assertEqual((audit / "runner.js").read_text(), "runner")
        for language in ("en", "he"):
            localized = bundle / "Resources" / f"{language}.lproj"
            for table in ("Core", "Bridge", "Shell", "Settings", "Panels"):
                # The native compiler omits English identity values that equal their keys.
                self.assertTrue(any((localized / f"{table}.{suffix}").is_file()
                                    for suffix in ("strings", "stringsdict")), table)
            self.assertTrue((localized / "Core.stringsdict").is_file())
            self.assertTrue((resources / f"{language}.lproj" / "InfoPlist.strings").is_file())
        hebrew_info = plistlib.loads(
            (resources / "he.lproj" / "InfoPlist.strings").read_bytes())
        self.assertEqual(
            hebrew_info["NSCameraUsageDescription"],
            "אתרים שתאשרו יוכלו להשתמש במצלמה לשיחות וידאו.")
        self.assertEqual(
            hebrew_info["NSMicrophoneUsageDescription"],
            "אתרים שתאשרו יוכלו להשתמש במיקרופון לשיחות.")
        self.assertEqual(
            hebrew_info["NSLocationUsageDescription"],
            "אתרים שתאשרו יוכלו להשתמש במיקום, למשל באתרי מפות ומשלוחים.")
        self.assertEqual(
            hebrew_info["NSLocationWhenInUseUsageDescription"],
            "אתרים שתאשרו יוכלו להשתמש במיקום, למשל באתרי מפות ומשלוחים.")
        self.assertEqual(
            hebrew_info["NSBluetoothAlwaysUsageDescription"],
            "אתרים שתאשרו יוכלו להתחבר להתקני Bluetooth, כגון מפתחות אבטחה וטלפונים שמשמשים לכניסה באמצעות מפתח גישה.")
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
        framework_tools = contents / "Resources" / "FrameworkDevTools"
        pages = {
            "react": "main.html", "vue": "pages/devtools-background.html",
            "angular": "devtools.html",
        }
        for name, page in pages.items():
            manifest = json.loads((framework_tools / name / "manifest.json").read_text())
            self.assertEqual(manifest["devtools_page"], page)
            self.assertNotIn("<all_urls>", manifest["host_permissions"])
            self.assertIn("shaar-devtools.js", (framework_tools / name / page).read_text())
            self.assertTrue((framework_tools / name / page).with_name("shaar-devtools.js").is_file())
            self.assertTrue((framework_tools / "licenses" / f"{name}-LICENSE").is_file())

    def _info_plist(self, app_path):
        with (self.root / app_path / "Contents" / "Info.plist").open("rb") as plist_file:
            return plistlib.load(plist_file)

    def test_framework_devtools_crx_archives_are_not_tracked(self):
        tracked = subprocess.check_output(["git", "ls-files"], cwd=REPO, text=True)
        crx_paths = [line for line in tracked.splitlines() if line.endswith(".crx")]
        self.assertEqual(crx_paths, [])

    def test_bundle_advertises_web_browsing_handoff(self):
        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._info_plist("build/Shaar Shell.app")["NSUserActivityTypes"],
            ["NSUserActivityTypeBrowsingWeb"],
        )

    def test_bundle_registers_web_documents_as_an_alternate_handler(self):
        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        plist = self._info_plist("build/Shaar Shell.app")
        self.assertEqual(
            plist["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["http", "https"]
        )
        web_document = plist["CFBundleDocumentTypes"][0]
        self.assertEqual(web_document["LSHandlerRank"], "Alternate")
        self.assertEqual(
            web_document["LSItemContentTypes"],
            ["public.html", "public.xhtml", "com.apple.web-internet-location"],
        )

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
        self.assertNotIn("ShaarUseMockKeychain", plist)

    def test_engine_bundle_uses_shaar_pin_without_backend_switch(self):
        result = self._run("--with-engine")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("ShaarEngineBackend", self._info_plist("build/Shaar.app"))
        self.assertIn("fetch-engine", self._log())
        bundled_pin = self.root / "build/Shaar.app/Contents/Resources/ChromiumEngine/pin.json"
        self.assertEqual(bundled_pin.read_text(), "pin.json")
        framework_info = self.root / "build/Shaar.app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Resources/Info.plist"
        self.assertEqual(plistlib.loads(framework_info.read_bytes())["CFBundleIdentifier"], "com.arcusis.shaar.framework")

    def test_engine_preview_isolated_from_regular_browser(self):
        result = self._run("--with-engine", "--preview-shaar-engine")

        self.assertEqual(result.returncode, 0, result.stderr)
        plist = self._info_plist("build/Shaar Engine Preview.app")
        regular = release_feed.load_config(RELEASE_CONFIG)
        self.assertEqual(plist["CFBundleIdentifier"], "com.arcusis.browser.engine-preview")
        self.assertNotEqual(plist["CFBundleIdentifier"], regular.bundle_identifier)
        self.assertEqual(plist["CFBundleName"], "Shaar Engine Preview")
        self.assertEqual(plist["CFBundleDisplayName"], "Shaar Engine Preview")
        self.assertEqual(plist["ShaarDataFolderName"], "Shaar Engine Preview")
        self.assertNotEqual(plist["ShaarDataFolderName"], "Arcusis Browser")
        self.assertEqual(plist["ShaarCacheFolderName"], "Shaar Engine Preview")
        self.assertIs(plist["ShaarUseMockKeychain"], True)
        self.assertNotIn("ShaarEngineBackend", plist)
        bundled_pin = self.root / "build/Shaar Engine Preview.app/Contents/Resources/ChromiumEngine/pin.json"
        self.assertEqual(bundled_pin.read_text(), "pin.json")

    def test_alert_helpers_use_product_name_and_icon(self):
        for args, app_path, product_name in (
            (("--with-engine",), "build/Shaar.app", "Shaar"),
            (("--with-engine", "--preview-shaar-engine"),
             "build/Shaar Engine Preview.app", "Shaar Engine Preview"),
        ):
            with self.subTest(product_name=product_name):
                result = self._run(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                helpers = (self.root / app_path / "Contents/Frameworks/Chromium Framework.framework"
                           / "Versions/Current/Helpers")
                for name in ALERT_HELPERS:
                    with self.subTest(helper=name):
                        contents = helpers / name / "Contents"
                        info = plistlib.loads((contents / "Info.plist").read_bytes())
                        self.assertEqual(info["CFBundleIdentifier"],
                                         "com.arcusis.shaar.framework.AlertNotificationService")
                        self.assertEqual(info.get("CFBundleName"), product_name)
                        self.assertEqual(info.get("CFBundleDisplayName"), product_name)
                        self.assertEqual(info.get("CFBundleIconFile"), "app.icns")
                        self.assertNotIn("CFBundleIconName", info)
                        self.assertEqual((contents / "Resources/app.icns").read_bytes(), ICON.read_bytes())
                        self.assertFalse((contents / "Resources/Assets.car").exists())

    def test_preview_shaar_requires_engine_and_excludes_updates(self):
        for args in (("--preview-shaar-engine",),
                     ("--with-engine", "--with-updates", "--preview-shaar-engine")):
            with self.subTest(args=args):
                self.assertEqual(self._run(*args).returncode, 2)

    def test_engine_bundle_respects_swift_job_cap(self):
        environment = dict(self.env, SHAAR_BUNDLE_SWIFT_JOBS="4")
        result = self._run("--with-engine", env=environment)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("swift build --jobs 4", self._log())

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
            (self.root / "build/Shaar Shell.app/Contents/Resources/ChromiumEngine/pin.json").is_file()
        )
        self.assertFalse((self.root / "build/Shaar Shell.app/Contents/Resources/ArdiaCore").exists())
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
        notices = self.root / "build/Shaar.app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Resources/ThirdPartyNotices"
        for name in ("cocoa-display-LICENSE", "cocoa-display-NOTICE"):
            self.assertEqual((notices / name).read_bytes(),
                             (REPO / "ThirdParty/ChromiumEngine/notices" / name).read_bytes())
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
        planted = self.root / "Sources" / "ShaarVerification" / "HarnessMarkers.swift"
        planted.parent.mkdir(parents=True)
        planted.write_text(
            "enum EngineProbe {}\n"
            "enum ShaarBrowsingQA {}\n"
            "enum InspectorIdleSmoke {}\n"
            "enum ShaarDevToolsF12RouteSmoke {}\n"
            "enum WebsitePermissionPromptProbe {}\n"
            "enum ShaarBrowsingEdgeProbe {}\n"
            "enum HttpsOnlyProbe {}\n"
            "enum SleepingTabsProbe {}\n"
            "enum DeviceChooserProbe {}\n"
            "func evaluateDeviceChooserProbeInTabID() {}\n"
            "enum WebShareProbe {}\n"
            "let flag = \"--browsing-qa\"\n"
            "let shareFlag = \"--probe-web-share\"\n"
            "let elementID = \"parity-action\"\n"
            "if arguments.contains(\"--devtools-f12-route\") {}\n"
        )
        for marker in (
            "ShaarVerification",
            "EngineProbe",
            "--engine-probe",
            "--probe-data-dir",
            "ShaarBrowsingQA",
            "--browsing-qa",
            "--probe-extension-install",
            "InspectorIdleSmoke",
            "--inspector-idle-smoke",
            "--probe-measure-inspector",
            "--probe-favicon-url",
            "--probe-favicon-restore",
            "ShaarDevToolsF12RouteSmoke",
            "--devtools-f12-route",
            "WebsitePermissionPromptProbe",
            "--probe-website-permission",
            "ShaarBrowsingEdgeProbe",
            "--browsing-edge-probe",
            "--platform-parity-probe",
            "parity-action",
            "--probe-https-only",
            "HttpsOnlyProbe",
            "--probe-platform-prompts",
            "--probe-web-share",
            "WebShareProbe",
            "testing: true",
            "SleepingTabsProbe",
            "--sleeping-tabs-probe",
            "--probe-device-choosers",
            "DeviceChooserProbe",
            "evaluateDeviceChooserProbe",
            "shaar-chooser:",
        ):
            with self.subTest(marker=marker):
                self.log.unlink(missing_ok=True)
                (self.binary_dir / "ArcusisBrowser").write_text(f"stub binary {marker}")
                result = self._run("--with-engine")

                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("Verification code found", result.stderr)
                self.assertNotIn("codesign", self._log())

    def test_shipping_sources_reject_a_planted_harness(self):
        planted = self.root / "Sources" / "ArcusisBrowser" / "PlantedHarness.swift"
        planted.parent.mkdir(parents=True)
        planted.write_text('let launch = "--planted-probe"\n')
        result = self._run("--with-engine")

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Verification code found", result.stderr)
        self.assertIn("--planted-probe", result.stderr)
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

    def test_shaar_test_engine_is_verification_only_and_selected_explicitly(self):
        environment = {**self.env, "SHAAR_TEST_SHAAR_ENGINE": "1"}
        rejected = self._run("--with-engine", env=environment)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn("allowed only in a verification bundle", rejected.stderr)
        self.assertEqual(self._log(), "")

        accepted = self._run("--with-engine", "--verification", env=environment)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIn("fetch-shaar-test-engine", self._log())
        self.assertNotIn("fetch-engine\n", self._log())
        self.assertTrue(
            (self.root / "build/Shaar Verification.app/Contents/Frameworks/Chromium Framework.framework").is_dir()
        )

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

    def test_unstaged_swiftpm_bundle_stops_before_signing(self):
        extra = self.binary_dir / "ArcusisBrowser_Future.bundle"
        extra.mkdir()
        (extra / "Info.plist").write_text("future")

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("was not staged into the app", result.stderr)
        self.assertIn("ArcusisBrowser_Future.bundle", result.stderr)
        self.assertNotIn("codesign", self._log())

    def test_mock_keychain_marks_every_adhoc_bundle(self):
        cases = (
            ((), "build/Shaar Shell.app"),
            (("--with-engine",), "build/Shaar.app"),
            (("--with-engine", "--configuration", "debug"), "build/Shaar Debug.app"),
            (("--with-engine", "--verification"), "build/Shaar Verification.app"),
            (("--mock-keychain",), "build/Shaar Shell.app"),
        )
        for args, app_path in cases:
            with self.subTest(args=args):
                environment = dict(self.env)
                if "--mock-keychain" not in args:
                    environment["SHAAR_MOCK_KEYCHAIN"] = "1"
                result = self._run(*args, env=environment)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIs(self._info_plist(app_path)["ShaarUseMockKeychain"], True)

    def test_regular_engine_bundle_keeps_the_real_keychain(self):
        result = self._run("--with-engine")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("ShaarUseMockKeychain", self._info_plist("build/Shaar.app"))

    def test_release_bundle_refuses_mock_keychain_before_build(self):
        cases = (
            (("--with-engine", "--with-updates"), {"SHAAR_MOCK_KEYCHAIN": "1"}),
            (("--with-engine", "--with-updates", "--mock-keychain"), {}),
            (("--with-engine", "--with-updates"), {"SHAAR_MOCK_KEYCHAIN": "true"}),
        )
        for args, extra in cases:
            with self.subTest(args=args, extra=extra):
                result = self._run(*args, env=dict(self.env, **extra))

                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("ShaarUseMockKeychain", result.stderr)
                self.assertEqual(self._log(), "")
                self.assertFalse((self.root / "build/Shaar.app").exists())

    def test_invalid_mock_keychain_value_fails_before_build(self):
        result = self._run("--with-engine", env=dict(self.env, SHAAR_MOCK_KEYCHAIN="maybe"))

        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("SHAAR_MOCK_KEYCHAIN", result.stderr)
        self.assertEqual(self._log(), "")

    def test_invalid_duplicate_and_malformed_options_fail_before_build(self):
        invalid_arguments = (
            ("--unknown",),
            ("--configuration",),
            ("--configuration", "fast"),
            ("--configuration", "debug", "--configuration", "release"),
            ("--with-engine", "--with-engine"),
            ("--with-updates", "--with-updates"),
            ("--verification", "--verification"),
            ("--mock-keychain", "--mock-keychain"),
            ("--configuration", "--with-engine"),
        )
        for args in invalid_arguments:
            with self.subTest(args=args):
                result = self._run(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self._log(), "")


if __name__ == "__main__":
    unittest.main()
