# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ShaarOnlyBridgeTests(unittest.TestCase):
    def test_compiled_bridge_sources_have_no_ardia_dependency(self):
        for directory in ("Sources/ChromiumBridge", "Sources/ChromiumBridgeVerification"):
            for source in (ROOT / directory).rglob("*"):
                if source.suffix not in {".h", ".mm", ".m", ".cc", ".cpp"}:
                    continue
                with self.subTest(source=source.relative_to(ROOT)):
                    self.assertFalse("ArdiaCore" in source.read_text(), source.relative_to(ROOT))

    def test_bundled_verification_probes_construct_shaar_runtime(self):
        for name in ("EngineProbe.swift", "MarketingScreenshots.swift", "ProfileOnboardingProbe.swift"):
            source = (ROOT / "Sources" / "ShaarVerification" / name).read_text()
            with self.subTest(source=name):
                self.assertIn("try ARCShaarRuntime(", source)
                self.assertNotIn("try ARCChromiumRuntime(", source)

    def test_shaar_first_tab_verification_has_no_backend_opt_in(self):
        for name in (
            ".github/workflows/source-checks.yml",
            "Tests/ShaarVerificationTests/ShaarFirstTabProbeTests.swift",
            "Tests/ShaarVerificationTests/ShaarPreviewProbeTests.swift",
        ):
            with self.subTest(source=name):
                self.assertNotIn("--shaar-engine-backend", (ROOT / name).read_text())

    def test_tab_evaluation_uses_shaar_devtools(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumShaarBackend.mm").read_text()
        method = source.split("- (void)evaluateInTabID:", 1)[1].split(
            "- (void)bookmarksForProfileID:", 1
        )[0]
        self.assertIn('shaarDevToolsCall:@"Runtime.evaluate"', method)
        self.assertIn('returnByValue', method)

    def test_engine_shutdown_notifies_window_clients(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumShaarBackend.mm").read_text()
        run = source.split("- (int)runWithDataDirectory:", 1)[1].split(
            "- (void)receiveEvent:", 1
        )[0]
        self.assertIn("[self finishWindowID:windowID]", run)

    def test_normal_browsing_probe_uses_shaar_tab_identity(self):
        source = (ROOT / "Sources/ShaarVerification/EngineProbe.swift").read_text()
        method = source.split("private func normalBrowsingSmoke()", 1)[1].split(
            "\n  private func ", 1
        )[0]
        self.assertNotIn("runtime.nativeTabID(forID:", method)

    def test_fixture_snapshot_polls_page_without_navigation_event_dependency(self):
        source = (ROOT / "Sources/ShaarVerification/EngineProbe.swift").read_text()
        snapshot = source.split("private func snapshot(", 1)[1].split(
            "\n  private func ", 1
        )[0]
        self.assertNotIn("loadedTabs.contains", snapshot)

    def test_recovery_fixture_navigation_uses_shaar_tab_route(self):
        source = (ROOT / "Sources/ShaarVerification/SessionRecoveryProbe.swift").read_text()
        navigate = source.split("private func navigate(", 1)[1].split(
            "\n  private func ", 1
        )[0]
        self.assertIn("runtime.navigateTabID(", navigate)
        self.assertNotIn("runtime.evaluate(", navigate)


if __name__ == "__main__":
    unittest.main()
