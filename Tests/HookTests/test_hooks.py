# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import os
from pathlib import Path
import random
import shutil
import string
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import git_content
import hook_support
import sensitive_files

SPEC = importlib.util.spec_from_file_location("secret_history", ROOT / "scripts/check-secret-history.py")
HISTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HISTORY)


class HookTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="shaar-hook-test-")
        self.root = Path(self.temporary.name).resolve()
        git_content.git(self.root, "init", "--quiet")

    def tearDown(self):
        self.temporary.cleanup()

    def stage(self, name, value=b"fixture\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value)
        git_content.git(self.root, "add", "--", name)
        return path

    def tree(self):
        return git_content.git(self.root, "write-tree").decode().strip()

    def test_blocklist_is_case_insensitive_and_keeps_public_key_names(self):
        blocked = ["secret.P8", "certificate.PEM", "nested/id_ed25519", "secret.key", "export.p12",
                   "export.pfx", "SparklePrivateKey", "sparkle-secret", ".env", "nested/.env.local",
                   "production.env", ".dev.vars"]
        for name in blocked:
            with self.subTest(name=name):
                self.assertTrue(sensitive_files.blocked_name(name))
        for name in ("scripts/release-config.sh", "public.pub", "public-key.json", "sparkle-fixture.json"):
            self.assertFalse(sensitive_files.blocked_name(name))

    def test_hook_config_preserves_trailing_path_whitespace(self):
        configured_path = "/tmp/previous hooks "
        with patch.object(hook_support, "git", return_value=(configured_path + "\n").encode()):
            self.assertEqual(hook_support.config(self.root, "core.hooksPath", scope="--local", path_value=True),
                             configured_path)

    def test_policy_reads_index_despite_unstaged_replacement(self):
        path = self.stage("notes.txt", b"staged payload")
        path.write_bytes(b"short")
        self.assertTrue(sensitive_files.policy_errors(self.root, maximum=10))
        self.assertFalse(sensitive_files.policy_errors(self.root, maximum=100))

    def test_rename_to_sensitive_path_is_blocked_and_deletion_allowed(self):
        self.stage("notes.txt")
        git_content.git(self.root, "mv", "notes.txt", ".env")
        self.assertIn("sensitive filename", sensitive_files.policy_errors(self.root)[0])
        git_content.git(self.root, "rm", "--cached", ".env")
        self.assertEqual(sensitive_files.policy_errors(self.root), [])

    def test_safe_symlink_allowed_and_escape_rejected(self):
        self.stage("target.txt")
        (self.root / "link").symlink_to("target.txt")
        git_content.git(self.root, "add", "link")
        self.assertEqual(sensitive_files.policy_errors(self.root), [])
        (self.root / "link").unlink()
        (self.root / "link").symlink_to("../outside")
        git_content.git(self.root, "add", "link")
        self.assertIn("symlink", sensitive_files.policy_errors(self.root)[0])

    def test_symlink_cycle_is_rejected(self):
        (self.root / "first").symlink_to("second")
        (self.root / "second").symlink_to("first")
        git_content.git(self.root, "add", "first", "second")
        errors = sensitive_files.policy_errors(self.root)
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("symlink cycle" in error for error in errors))

    def test_symlink_cycle_through_directory_component_is_rejected(self):
        (self.root / "first").symlink_to("directory/inside")
        (self.root / "directory").symlink_to("first")
        git_content.git(self.root, "add", "first", "directory")
        errors = sensitive_files.policy_errors(self.root)
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("symlink cycle" in error for error in errors))

    def test_repeated_noncyclic_symlink_expansion_is_allowed(self):
        (self.root / "target").mkdir()
        (self.root / "target" / "b").write_text("regular target")
        (self.root / "b").symlink_to("target")
        (self.root / "alias").symlink_to("b/b")
        git_content.git(self.root, "add", "target", "b", "alias")
        self.assertEqual(sensitive_files.policy_errors(self.root), [])

    def test_snapshot_preserves_staged_bytes_index_and_worktree(self):
        path = self.stage("nested/source.txt", b"staged bytes")
        path.write_bytes(b"unstaged bytes")
        before = git_content.git(self.root, "ls-files", "--stage", "-z")
        with git_content.snapshot(self.root, self.tree()) as (source, environment):
            self.assertEqual((source / "nested/source.txt").read_bytes(), b"staged bytes")
            self.assertNotIn("GIT_INDEX_FILE", environment)
            self.assertEqual(git_content.git(source, "ls-files", env=environment), b"nested/source.txt\n")
        self.assertFalse(source.exists())
        self.assertEqual(before, git_content.git(self.root, "ls-files", "--stage", "-z"))
        self.assertEqual(path.read_bytes(), b"unstaged bytes")

    def test_real_gitleaks_detects_staged_token_after_worktree_is_sanitized(self):
        scanner = shutil.which("gitleaks")
        self.assertIsNotNone(scanner, "Pinned Gitleaks must be available for hook verification")
        generator = random.Random(335)
        token = "ghp_" + "".join(generator.choices(string.ascii_letters + string.digits, k=36))
        path = self.stage("notes.txt", ("credential=" + token + " # gitleaks:allow\n").encode())
        path.write_text("sanitized working copy\n")
        with git_content.snapshot(self.root, self.tree()) as (source, environment):
            report = source / "redacted.json"
            result = subprocess.run([scanner, "dir", "--no-banner", "--redact", "--ignore-gitleaks-allow",
                                     "--log-level", "error", "--report-format", "json", "--report-path", str(report),
                                     "notes.txt"], cwd=source, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(report.is_file())
            self.assertNotIn(token, report.read_text() + result.stdout + result.stderr)

    def test_history_policy_rejects_sensitive_file_removed_from_final_tree(self):
        self.stage(".env")
        unsafe = self.tree()
        git_content.git(self.root, "rm", "--cached", ".env")
        clean = self.tree()
        self.assertEqual(sensitive_files.policy_errors(self.root, clean), [])
        with patch.object(HISTORY, "history_commits", return_value=[unsafe, clean]), \
                patch.object(HISTORY, "subprocess") as scan:
            self.assertEqual(HISTORY.scan_history(self.root, "a" * 40, "b" * 40, self.root / "report.json"), 1)
            scan.run.assert_not_called()

    def test_history_scan_rejects_symlinked_report_before_running_gitleaks(self):
        target = self.root / "outside-report.json"
        target.write_text("preserve this", encoding="utf-8")
        report = self.root / "report.json"
        report.symlink_to(target)
        with patch.object(HISTORY, "history_commits", return_value=[]), \
                patch.object(HISTORY, "object_id", side_effect=lambda value: value), \
                patch.object(HISTORY.subprocess, "run") as scan:
            with self.assertRaisesRegex(ValueError, "secret scan report must not be a symlink"):
                HISTORY.scan_history(self.root, "a" * 40, "b" * 40, report)
            scan.assert_not_called()
        self.assertEqual(target.read_text(encoding="utf-8"), "preserve this")

    def test_missing_ci_baseline_fails_closed(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}, clear=True), \
                patch.object(sys, "argv", ["check-secret-history.py"]), \
                patch.object(HISTORY, "commit_id", return_value="a" * 40), \
                patch.object(HISTORY, "git", return_value=("a" * 40).encode()):
            with self.assertRaisesRegex(ValueError, "CI_BASE_SHA"):
                HISTORY.main()

    def test_push_parser_checks_all_refs_deduplicates_and_skips_deletions(self):
        head, base, other = "a" * 40, "b" * 40, "c" * 40
        data = f"refs/heads/a {head} refs/heads/a {base}\nrefs/heads/a {head} refs/heads/a {base}\n(delete) {'0' * 40} refs/heads/d {base}\nrefs/heads/b {other} refs/heads/b {'0' * 40}\n"
        self.assertEqual(git_content.push_updates(data.encode()), [(head, base), (other, "0" * 40)])
        for bad in (b"missing fields", b"a invalid b invalid"):
            with self.assertRaises(ValueError):
                git_content.push_updates(bad)

    def test_push_parser_accepts_non_utf8_ref_labels(self):
        head, base = "a" * 40, "b" * 40
        data = b"refs/heads/name-\xff " + head.encode() + b" refs/heads/name-\xff " + base.encode()
        self.assertEqual(git_content.push_updates(data), [(head, base)])

    def test_push_runner_checks_every_outgoing_head_and_propagates_failure(self):
        first, second, base = "a" * 40, "b" * 40, "c" * 40
        data = f"refs/heads/a {first} refs/heads/a {base}\nrefs/heads/b {second} refs/heads/b {base}\n".encode()
        with patch.object(hook_support, "chain_previous", return_value=0), \
                patch.object(hook_support, "push_base", return_value=base), \
                patch.object(hook_support, "check_tree", side_effect=[0, 1]) as checks:
            self.assertEqual(hook_support.run_hook(self.root, "pre-push", [], data), 1)
            self.assertEqual([call.kwargs["head"] for call in checks.call_args_list], [first, second])

    def test_unresolved_index_entries_fail_before_export(self):
        self.stage("source.txt")
        oid = git_content.git(self.root, "rev-parse", ":source.txt").decode().strip()
        git_content.git(self.root, "update-index", "--index-info", input=(f"0 {'0' * 40}\tsource.txt\n100644 {oid} 1\tsource.txt\n100644 {oid} 2\tsource.txt\n").encode())
        with self.assertRaisesRegex(ValueError, "unmerged"):
            sensitive_files.policy_errors(self.root)

    def install_fixture(self):
        self.stage(".githooks/run.sh", (ROOT / ".githooks/run.sh").read_bytes())
        prior = self.root / "previous-hooks"
        prior.mkdir()
        for name in ("pre-commit", "pre-push", "commit-msg"):
            hook = prior / name
            hook.write_text("#!/bin/sh\ncat > previous-input\nexit 0\n")
            hook.chmod(0o755)
        git_content.git(self.root, "config", "--local", "core.hooksPath", str(prior))
        return prior, hook_support.install_hooks(self.root)

    def test_installer_is_worktree_scoped_idempotent_and_preserves_commit_message_guard(self):
        prior, installed = self.install_fixture()
        self.assertEqual(hook_support.config(self.root, "core.hooksPath", scope="--local"), str(prior))
        self.assertEqual(hook_support.config(self.root, "core.hooksPath", scope="--worktree"), str(installed))
        self.assertTrue((installed / "commit-msg").is_file())
        self.assertEqual(hook_support.install_hooks(self.root), installed)
        self.assertEqual(hook_support.config(self.root, "shaar.previousHooksPath", scope="--worktree"), str(prior))
        subprocess.run([str(installed / "commit-msg"), "message-file"], cwd=self.root, input=b"preserved", check=True)
        self.assertEqual((self.root / "previous-input").read_bytes(), b"preserved")
        subprocess.run([str(installed / "pre-push"), "origin", "remote"], cwd=self.root, input=b"older checkout refs", check=True)
        self.assertEqual((self.root / "previous-input").read_bytes(), b"older checkout refs")

    def test_installer_rejects_symlinked_managed_directory_before_writing(self):
        self.stage(".githooks/run.sh", (ROOT / ".githooks/run.sh").read_bytes())
        git_directory = Path(git_content.git(self.root, "rev-parse", "--absolute-git-dir").decode().strip())
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside)
            managed = git_directory / "shaar-hooks"
            managed.symlink_to(external, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "Managed hook directory must not be a symlink"):
                hook_support.install_hooks(self.root)
            self.assertEqual(list(external.iterdir()), [])

    def test_prior_push_hook_receives_original_input_and_abort_stops_new_checks(self):
        prior, _ = self.install_fixture()
        data = b"original ref list\n"
        self.assertEqual(hook_support.chain_previous(self.root, "pre-push", ["origin", "remote"], data), 0)
        self.assertEqual((self.root / "previous-input").read_bytes(), data)
        (prior / "pre-commit").write_text("#!/bin/sh\nexit 23\n")
        with patch.object(hook_support, "check_tree") as checks:
            self.assertEqual(hook_support.run_hook(self.root, "pre-commit", []), 23)
            checks.assert_not_called()

    def test_installer_preserves_git_path_expansion_for_previous_hooks(self):
        self.stage(".githooks/run.sh", (ROOT / ".githooks/run.sh").read_bytes())
        git_content.git(self.root, "config", "--local", "core.hooksPath", "~/shaar-previous-hooks")
        hook_support.install_hooks(self.root)
        self.assertEqual(hook_support.config(self.root, "shaar.previousHooksPath", scope="--worktree"),
                         str(Path.home() / "shaar-previous-hooks"))


if __name__ == "__main__":
    unittest.main()
