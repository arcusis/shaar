# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Safety and fixture contracts for the hosted v0.1.0 upgrade runner."""

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import upgrade_from_v010


class UpgradeFromV010Tests(unittest.TestCase):
    def test_runner_requires_disposable_account(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "disposable macOS runner"):
                upgrade_from_v010.require_disposable_runner(
                    {"GITHUB_ACTIONS": "false", "RUNNER_TEMP": directory}, "david")

    def test_runner_rejects_home_outside_owned_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "temporary HOME"):
                upgrade_from_v010.check_isolated_home(
                    root, {"HOME": str(root / "other"),
                           "CFFIXED_USER_HOME": str(root / "home")})

    def test_old_harness_patch_requires_exact_mock_keychain_switch(self):
        with self.assertRaisesRegex(RuntimeError, "v0.1.0 bridge source changed"):
            upgrade_from_v010.remove_mock_keychain_switch("unrelated source")

    def test_account_url_ignores_other_saved_loopback_tabs(self):
        session = {"spaces": [{"tabs": [
            {"url": "http://127.0.0.1:32100/library-alpha-saved"},
            {"url": "http://127.0.0.1:32100/account"},
        ]}]}
        self.assertEqual(upgrade_from_v010.account_url_from_session(session),
                         "http://127.0.0.1:32100/account")

    def test_account_url_rejects_foreign_origins(self):
        session = {"spaces": [{"tabs": [{"url": "https://example.com/account"}]}]}
        with self.assertRaisesRegex(RuntimeError, "one loopback account URL"):
            upgrade_from_v010.account_url_from_session(session)

    def test_v010_bookmark_patch_calls_native_bridge(self):
        source = subprocess.check_output(
            ["git", "show", "v0.1.0:Sources/ShaarVerification/EngineProbe.swift"],
            cwd=upgrade_from_v010.ROOT, text=True)
        patched = upgrade_from_v010.add_legacy_bookmarks(source)
        self.assertIn("runtime.applyBookmarkOperation(operation, profileID: profile)", patched)
        self.assertEqual(patched.count("Alpha console"), 1)

    def test_old_fixture_uses_precreated_system_temp_root(self):
        source = subprocess.check_output(
            ["git", "show", "v0.1.0:scripts/engine_fixture.py"],
            cwd=upgrade_from_v010.ROOT, text=True)
        patched = upgrade_from_v010.patch_legacy_fixture_root(source)
        self.assertIn('os.environ["SHAAR_UPGRADE_FIXTURE_ROOT"]', patched)
        compile(patched, "engine_fixture.py", "exec")

    def test_upgrade_home_and_fixture_share_system_temp_root(self):
        with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as directory:
            root = Path(directory)
            home = root / "home"
            home.mkdir()
            environment = upgrade_from_v010.upgrade_environment(
                {"HOME": "/not-used", "TMPDIR": "/not-used"}, root)
            self.assertEqual(environment["HOME"], str(home))
            self.assertEqual(environment["CFFIXED_USER_HOME"], str(home))
            self.assertEqual(environment["SHAAR_UPGRADE_FIXTURE_ROOT"], str(root))
            self.assertEqual(environment["TMPDIR"], str(root.parent))

    def test_system_temp_matches_macos_user_temp(self):
        expected = Path(subprocess.check_output(
            ["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()).resolve()
        self.assertEqual(upgrade_from_v010.system_temporary_directory({}), expected)

    def test_annotated_release_tag_resolves_to_pinned_commit(self):
        self.assertEqual(upgrade_from_v010.v010_commit(),
                         "f887d5d7308670fd3c2215ebe4814abe457afa0f")

    def test_password_fixture_uses_decryptable_chromium_v10_blob(self):
        encrypted = upgrade_from_v010.encrypt_password("synthetic-password", "legacy-secret")
        self.assertTrue(encrypted.startswith(b"v10"))
        self.assertNotIn(b"synthetic-password", encrypted)
        self.assertEqual(upgrade_from_v010.decrypt_password(encrypted, "legacy-secret"),
                         "synthetic-password")
        with self.assertRaises(subprocess.CalledProcessError):
            upgrade_from_v010.decrypt_password(encrypted, "wrong-secret")

    def test_fresh_temporary_home_needs_no_prior_default_keychain(self):
        calls = []

        def security(arguments, **_options):
            calls.append(arguments)
            if arguments[:2] == ["security", "default-keychain"] and "-s" not in arguments:
                raise RuntimeError("security failed (1)")
            return ""

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(upgrade_from_v010, "run_checked", side_effect=security):
                with upgrade_from_v010.throwaway_keychain(Path(directory), {}):
                    pass
        restores = [call for call in calls if call[:3] ==
                    ["security", "default-keychain", "-d"] and "-s" in call]
        self.assertEqual(len(restores), 1)
        self.assertTrue(restores[0][-1].endswith("upgrade.keychain-db"))

    def test_keychain_search_list_can_exist_without_a_default(self):
        calls = []

        def security(arguments, **_options):
            calls.append(arguments)
            if arguments[:2] == ["security", "list-keychains"] and "-s" not in arguments:
                return '"/tmp/existing.keychain-db"\n'
            if arguments[:2] == ["security", "default-keychain"] and "-s" not in arguments:
                raise RuntimeError("security failed (1)")
            return ""

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(upgrade_from_v010, "run_checked", side_effect=security):
                with upgrade_from_v010.throwaway_keychain(Path(directory), {}):
                    pass
        restores = [call for call in calls if call[:2] ==
                    ["security", "default-keychain"] and "-s" in call]
        self.assertEqual(len(restores), 1)
        self.assertIn(["security", "list-keychains", "-d", "user", "-s",
                       "/tmp/existing.keychain-db"], calls)

    def test_timed_out_probe_reports_owned_process_group_failure(self):
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            upgrade_from_v010.run_checked(["sleep", "1"], timeout=0.01)

    def test_failed_old_fixture_preserves_only_owned_child_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "arcusis-engine-probe-example"
            fixture.mkdir()
            (fixture / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
            (fixture / "initial.log").write_text("old engine failure\n")
            evidence = root / "evidence"
            evidence.mkdir()

            upgrade_from_v010.retain_old_fixture_evidence(
                f"Probe evidence: {fixture}\n", root, evidence)

            self.assertEqual((evidence / "old-fixture-initial.log").read_text(),
                             "old engine failure\n")
            with self.assertRaisesRegex(RuntimeError, "escaped"):
                upgrade_from_v010.retain_old_fixture_evidence(
                    "Probe evidence: /tmp/unrelated\n", root, evidence)

    def test_old_crash_capture_keeps_only_recent_probe_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = root / "Library/Logs/DiagnosticReports"
            reports.mkdir(parents=True)
            (reports / "ShaarVerification-2026.ips").write_text("probe crash\n")
            (reports / "OtherApp-2026.ips").write_text("unrelated\n")
            evidence = root / "evidence"
            evidence.mkdir()

            captured = upgrade_from_v010.retain_crash_evidence(
                [reports], evidence, started=0)

            self.assertTrue(captured)
            self.assertEqual((evidence / "old-probe-crash.ips").read_text(), "probe crash\n")
            self.assertEqual(len(list(evidence.iterdir())), 1)


if __name__ == "__main__":
    unittest.main()
