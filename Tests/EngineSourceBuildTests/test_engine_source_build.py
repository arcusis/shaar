import importlib.util
import json
import os
import pathlib
import tempfile
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-engine-source.py"
SPEC = importlib.util.spec_from_file_location("build_engine_source", SCRIPT)
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class SourceBuildTests(unittest.TestCase):
    def _term_resistant_group_code(self, parent_exits: bool):
        code = (
            "import os,signal,time; child=os.fork(); "
            "(signal.signal(signal.SIGTERM,signal.SIG_IGN),time.sleep(60),os._exit(0)) "
            "if child==0 else os._exit(9)"
            if parent_exits else
            "import os,signal,time; child=os.fork(); "
            "(signal.signal(signal.SIGTERM,signal.SIG_IGN),time.sleep(60),os._exit(0)) "
            "if child==0 else time.sleep(60)"
        )
        return code

    def _runner_for_process_test(self, output):
        runner = BUILD.Runner.__new__(BUILD.Runner)
        runner.repo = output
        runner.output = output
        runner.config = {"build": {"minimumFreeBytes": 0, "buildJobs": 6}}
        runner.receipt = {"stages": {}}
        runner.child_environment = lambda: os.environ.copy()
        runner.save = lambda: None
        return runner

    def _assert_group_stopped(self, process_id):
        deadline = time.monotonic() + 5
        while BUILD.process_group_exists(process_id) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(BUILD.process_group_exists(process_id))

    def test_timeout_cleanup_kills_term_resistant_descendant(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            runner = self._runner_for_process_test(output)
            with self.assertRaisesRegex(BUILD.BuildError, "stage timed out"):
                runner.run("timeout", [os.sys.executable, "-c", self._term_resistant_group_code(False)],
                           output, 1)
            process_id = runner.receipt["stages"]["timeout"]["attempts"][-1]["pid"]
            self._assert_group_stopped(process_id)

    def test_nonzero_parent_exit_still_kills_term_resistant_descendant(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            runner = self._runner_for_process_test(output)
            with self.assertRaisesRegex(BUILD.BuildError, "stage failed"):
                runner.run("nonzero", [os.sys.executable, "-c", self._term_resistant_group_code(True)],
                           output, 5)
            process_id = runner.receipt["stages"]["nonzero"]["attempts"][-1]["pid"]
            self._assert_group_stopped(process_id)

    def test_source_pins_and_patch_digest_are_frozen(self):
        config = BUILD.load_config(ROOT)
        self.assertEqual(config["source"]["commit"], "91e17a5655519d2dc385ec8452432469232ff9af")
        self.assertEqual(config["source"]["engineTree"], "0fd438ac5e7847948832ff6dd080ce9ab0206464")
        self.assertEqual(config["chromium"]["version"], "155.0.8059.84")
        self.assertEqual(config["chromium"]["commit"], "5869fe313571d75152b77813cf0a4ee26a4e6df0")
        self.assertEqual(config["depotTools"]["commit"], "b86fc981b72ab966f8260f73b4eca600b3b12677")
        self.assertEqual(config["depotTools"]["pythonPackage"],
                         "infra/3pp/tools/cpython3/mac-arm64")
        self.assertEqual(config["depotTools"]["pythonVersionTag"],
                         "version:2@3.11.8.chromium.35")
        self.assertEqual(config["ungoogled"]["commit"], "c7b4b99027bb6f9f33848fdbee8a319a3ba3b238")
        self.assertEqual(config["ungoogled"]["macosCommit"], "b1238bb72b02cd36219991d9029c1c65183ea295")
        self.assertEqual(config["gitLfs"]["version"], "3.8.1")
        self.assertEqual(config["gitLfs"]["archiveSha256"],
                         "0ba10e897e0496412cd86eacaed4ed554c97ddc29bc5c709d28faa5eaaa2222c")
        patch = ROOT / config["patch"]["file"]
        self.assertEqual(BUILD.sha256(patch), config["patch"]["sha256"])
        self.assertNotIn("latest", json.dumps(config).lower())

    def test_patch_preconditions_bind_existing_api_and_chromium_downloadprefs(self):
        contents = {
            "ardiaDownloads": "UseTestDownloadsDir(profile); AC_ENGINE_CALL(ac_downloads_remove)",
            "ardiaEngine": "void Error(std::string_view message); OffTheRecord off_the_record = OffTheRecord::kRefuse Profile* ProfileAt(std::string_view dir);",
            "ardiaExports": "_ac_*",
            "chromiumDownloadPrefs": "base::FilePath DownloadPath() const; void SetDownloadPath(const base::FilePath& path); bool IsDownloadPathManaged() const;",
            "chromiumPrefService": "base::FilePath GetFilePath(std::string_view path) const",
            "chromiumFileUtil": "PathIsWritable DirectoryExists",
            "chromiumProfile": "IsOffTheRecord()",
            "chromiumBrowserContext": "ShutdownStarted()",
        }
        self.assertEqual(BUILD.source_precondition_errors(contents), [])
        contents["ardiaDownloads"] = contents["ardiaDownloads"].replace("UseTestDownloadsDir(profile);", "")
        self.assertTrue(any("UseTestDownloadsDir" in item
                            for item in BUILD.source_precondition_errors(contents)))

    def test_metal_toolchain_resume_requires_same_installed_signed_binary(self):
        expected = {
            "component": {"status": "installed", "buildVersion": "27A266a",
                          "toolchainIdentifier": "com.apple.dt.toolchain.Metal.32023.921.5"},
            "metalPath": "/toolchain/usr/bin/metal",
            "metalRealPath": "/toolchain/usr/bin/metal",
            "metalVersion": "Apple metal version 32023.921",
            "metalSha256": "a" * 64,
            "codesignVerifyReturnCode": 0,
            "codesignDisplay": "Apple Code Signing Certification Authority",
            "assetPath": "downloads/metal.dmg",
            "assetSha256": "b" * 64,
        }
        self.assertEqual(BUILD.metal_toolchain_precondition_errors(expected, expected), [])
        changed = json.loads(json.dumps(expected))
        changed["component"]["status"] = "uninstalled"
        changed["metalSha256"] = "c" * 64
        changed["codesignVerifyReturnCode"] = 1
        errors = BUILD.metal_toolchain_precondition_errors(expected, changed)
        self.assertTrue(any("component" in item for item in errors))
        self.assertTrue(any("metalSha256" in item for item in errors))
        self.assertTrue(any("signature" in item for item in errors))

    def test_ardia_series_must_support_explicit_owned_path_overrides(self):
        series = ('SRC = os.environ.get("CHROMIUM_SRC", "/unsafe/default")\n'
                  'BASE = os.environ.get("AC_SERIES_BASE", "/unsafe/default")\n')
        self.assertEqual(BUILD.series_path_precondition_errors(series), [])
        self.assertEqual(len(BUILD.series_path_precondition_errors(
            series.replace("CHROMIUM_SRC", "SRC"))), 1)

    def test_staged_ardia_source_redirects_game_resource_to_owned_runner_script(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            aria = output / "source/ardia"
            build = aria / "engine/patches/build"
            build.mkdir(parents=True)
            (aria / "engine/patches/series.py").write_text(
                'run([os.path.join(HERE, "build", "game-resource.sh")], HERE, check=True)\n')
            runner = BUILD.Runner.__new__(BUILD.Runner)
            runner.output = output
            runner.receipt = {"inputs": {}}
            runner.save = lambda: None
            staged = runner.stage_ardia_source(aria)
            self.assertEqual(
                (staged / "engine/patches/series.py").read_text(),
                'run([os.path.join(os.environ["ENGINE_BUILD_ROOT"], "scripts", "game-resource.sh")], '
                'HERE, check=True)\n',
            )
            self.assertEqual(runner.receipt["inputs"]["stagedArdiaSource"]["fileCount"], 1)

    def test_staged_ardia_source_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            aria = output / "source/ardia"
            aria.mkdir(parents=True)
            outside = output / "outside"
            outside.write_text("outside")
            (aria / "link").symlink_to(outside)
            runner = BUILD.Runner.__new__(BUILD.Runner)
            runner.output = output
            runner.receipt = {"inputs": {}}
            runner.save = lambda: None
            with self.assertRaisesRegex(BUILD.BuildError, "symlink"):
                runner.stage_ardia_source(aria)

    def test_pinned_gn_script_adaptation_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = pathlib.Path(temporary) / "02-gn-args.sh"
            script.write_text('cd "$src"\ngn gen "out/$GN_OUT_CONFIGS"\n')
            BUILD.Runner.adapt_pinned_gn_script(script)
            BUILD.Runner.adapt_pinned_gn_script(script)
            self.assertEqual(script.read_text().count("./buildtools/mac/gn gen"), 1)
            self.assertNotIn("./buildtools/mac/./buildtools/mac/gn", script.read_text())

    def test_build_priority_adaptation_calls_taskpolicy_directly(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = pathlib.Path(temporary) / "05-build.sh"
            script.write_text("exec lowprio autoninja -j 6 target\n")
            BUILD.Runner.adapt_build_priority_script(script)
            BUILD.Runner.adapt_build_priority_script(script)
            self.assertEqual(script.read_text(),
                             "exec taskpolicy -b nice -n 19 autoninja -j 6 target\n")

    def test_depot_tools_python_bootstrap_uses_resolved_pinned_cipd_and_exact_args(self):
        self.assertEqual(BUILD.Runner.depot_tools_python_ensure_args(
            pathlib.Path("depot_tools/cipd"), pathlib.Path("inputs/python.ensure"),
            pathlib.Path("inputs/python.resolved.ensure"), pathlib.Path("depot_tools/python")), [
                "depot_tools/cipd", "ensure", "-ensure-file", "inputs/python.ensure",
                "-ensure-file-output", "inputs/python.resolved.ensure", "-root", "depot_tools/python",
                "-max-threads", "2", "-application-default-credentials", "never",
            ])
        self.assertEqual(BUILD.Runner.depot_tools_python_bootstrap_args(
            pathlib.Path("depot_tools/python3"), pathlib.Path("depot_tools/bootstrap.py"), "python-pin"), [
                "depot_tools/python3", "depot_tools/bootstrap.py", "--bootstrap-name", "python-pin",
            ])

    def test_cache_reuse_requires_exact_url_commit_tree_and_archive_hash(self):
        expected = {"url": "https://example.invalid/src", "commit": "a" * 40,
                    "tree": "b" * 40, "archiveSha256": "c" * 64}
        self.assertTrue(BUILD.cache_record_matches(expected, expected))
        for key in expected:
            changed = dict(expected)
            changed[key] = "wrong"
            self.assertFalse(BUILD.cache_record_matches(changed, expected))

    def test_output_path_rejects_symlink_component(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = pathlib.Path(temporary) / "repo"
            repo.mkdir()
            outside = pathlib.Path(temporary) / "outside"
            outside.mkdir()
            (repo / "build").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(BUILD.BuildError, "symlink"):
                BUILD.guarded_output(repo)

    def test_staged_upstream_scripts_reject_home_tree_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            scripts = pathlib.Path(temporary)
            script = scripts / "02-gn-args.sh"
            script.write_text('source ~/chromium-build/scripts/gn_defines.sh\n')
            with self.assertRaisesRegex(BUILD.BuildError, "unadapted home path"):
                BUILD.Runner.validate_staged_paths(scripts)
            script.write_text('source "$CB/scripts/gn_defines.sh"\n')
            BUILD.Runner.validate_staged_paths(scripts)

    def test_child_environment_uses_owned_caches_and_drops_credentials(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(
                os.environ, {"HOME": "/home/unchanged", "GITHUB_TOKEN": "secret-test"}):
            runner = BUILD.Runner.__new__(BUILD.Runner)
            runner.output = pathlib.Path(temporary)
            environment = runner.child_environment()
            self.assertEqual(environment["HOME"], "/home/unchanged")
            self.assertNotIn("GITHUB_TOKEN", environment)
            self.assertEqual(environment["VPYTHON_VIRTUALENV_ROOT"],
                             str(pathlib.Path(temporary) / "vpython-root"))
            self.assertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
            self.assertEqual(environment["GIT_CONFIG_VALUE_2"], "git-lfs filter-process")
            self.assertEqual(environment["BOTO_CONFIG"], "/dev/null")
            self.assertEqual(environment["CLOUDSDK_CONFIG"],
                             str(pathlib.Path(temporary) / "cloudsdk"))
            self.assertEqual(environment["LUCI_CONTEXT"],
                             str(pathlib.Path(temporary) / ".no-auth-luci-context.json"))
            self.assertEqual(environment["CHROMIUM_SRC"],
                             str(pathlib.Path(temporary) / "chromium_git/chromium/src"))
            self.assertEqual(environment["AC_SERIES_BASE"],
                             str(pathlib.Path(temporary) / "series-base"))
            self.assertIn(str(pathlib.Path(temporary) / "tools"), environment["PATH"])

    def test_depot_tools_python_cache_reuse_is_read_only_and_digest_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            package = "infra/3pp/tools/cpython3/mac-arm64"
            version_tag = "version:2@3.11.8.chromium.35"
            manifest = output / "inputs/depot-tools-python.ensure"
            resolved = output / "inputs/depot-tools-python.resolved.ensure"
            manifest.parent.mkdir()
            manifest.write_text(
                "$VerifiedPlatform windows-amd64 windows-arm64 linux-amd64 mac-amd64 mac-arm64\n\n"
                f"@Subdir python3\n{package} {version_tag}\n")
            resolved.write_text(
                "$ServiceURL https://chrome-infra-packages.appspot.com\n\n"
                f"@Subdir python3\n{package} {'a' * 40}\n")
            python_dir = output / "depot_tools/bootstrap-3.11.8.chromium.35_bin/python3/bin"
            python_dir.mkdir(parents=True)
            python_target = python_dir / "python3.11"
            python_target.write_bytes(b"pinned python executable")
            (python_dir / "python3").symlink_to("python3.11")
            pointer = output / "depot_tools/python3_bin_reldir.txt"
            pointer.parent.mkdir(parents=True, exist_ok=True)
            pointer.write_text("bootstrap-3.11.8.chromium.35_bin/python3/bin\n")
            log = output / "logs/python-version.log"
            log.parent.mkdir()
            log.write_text("Python 3.11.8\n")
            record = {
                "package": package, "versionTag": version_tag,
                "manifestPath": str(manifest.relative_to(output)),
                "manifestSha256": BUILD.sha256(manifest),
                "resolvedPath": str(resolved.relative_to(output)),
                "resolvedSha256": BUILD.sha256(resolved), "resolved": resolved.read_text(),
                "pythonPath": str((python_dir / "python3").relative_to(output)),
                "pythonSha256": BUILD.sha256(python_target),
                "pointerPath": str(pointer.relative_to(output)),
                "pointerSha256": BUILD.sha256(pointer), "pythonVersion": "Python 3.11.8",
            }
            runner = BUILD.Runner.__new__(BUILD.Runner)
            runner.output = output
            runner.config = {"depotTools": {"pythonPackage": package,
                                             "pythonVersionTag": version_tag}}
            runner.receipt = {
                "inputs": {"depotToolsPython": record},
                "stages": {"depot-tools-python-version": {"attempts": [{
                    "status": "succeeded", "log": str(log.relative_to(output)),
                    "logSha256": BUILD.sha256(log),
                }]}},
            }
            runner.verify_depot_tools_python_cache()
            resolved.write_text(resolved.read_text() + "tampered\n")
            with self.assertRaisesRegex(BUILD.BuildError, "cache receipt mismatch"):
                runner.verify_depot_tools_python_cache()

    def test_gclient_cache_is_explicitly_owned(self):
        runner = BUILD.Runner.__new__(BUILD.Runner)
        runner.output = pathlib.Path("/owned/EngineSource")
        sync = runner.effective_commands()["sync"]
        self.assertNotIn("--cache-dir", sync)
        self.assertIn("gclient", sync)
        self.assertIn("sync", sync)
        self.assertEqual(sync[sync.index("-j") + 1], "4")
        self.assertEqual(runner.effective_commands()["gn"], [
            "chromium_git/chromium/src/buildtools/mac/gn", "gen", "out/Release_GN_arm64",
        ])
        with tempfile.TemporaryDirectory() as temporary:
            script = pathlib.Path(temporary) / "01-sync.sh"
            script.write_text("target_os = ['mac']\n")
            BUILD.Runner.checked_replace(
                script, "target_os = ['mac']",
                'target_os = [\'mac\']\ncache_dir = r"$CB/gclient-cache"', 1)
            self.assertIn('cache_dir = r"$CB/gclient-cache"', script.read_text())

    def test_owner_receipt_must_match_checkout_and_uid(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = pathlib.Path(temporary) / "repo"
            repo.mkdir()
            output, owner = BUILD.prepare_owned_output(repo)
            self.assertEqual(json.loads((output / BUILD.OWNER_FILE).read_text()), owner)
            with self.assertRaisesRegex(BUILD.BuildError, "does not match"):
                BUILD.write_private_json(output / BUILD.OWNER_FILE,
                                         {**owner, "repo": str(repo / "foreign")})
                BUILD.prepare_owned_output(repo)

    def test_lock_rejects_second_owner(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            fd = BUILD.acquire_lock(output)
            try:
                with self.assertRaisesRegex(BUILD.BuildError, "lock already exists"):
                    BUILD.acquire_lock(output)
            finally:
                os.close(fd)
                (output / BUILD.LOCK_FILE).unlink()

    def test_stale_lock_recovery_requires_absent_runner_and_build_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            (output / "logs").mkdir(mode=0o700)
            log = output / "logs/05-build.attempt-03.log"
            log.write_text("interrupted incremental build\n")
            lock_bytes = json.dumps({"pid": 23456, "uid": os.getuid()}).encode()
            lock = output / BUILD.LOCK_FILE
            lock.write_bytes(lock_bytes)
            os.chmod(lock, 0o600)
            owner = {"repo": str(output), "output": str(output), "uid": os.getuid(),
                     "schemaVersion": BUILD.OWNER_VERSION}
            receipt = {
                "owner": owner, "status": "failed", "runId": "run-1",
                "configDigest": "config-digest",
                "stages": {"05-build": {"status": "running", "attempts": [{
                    "attempt": 3, "status": "running", "pid": 34567,
                    "log": "logs/05-build.attempt-03.log",
                }]}},
            }
            with mock.patch.object(BUILD.os, "kill", side_effect=ProcessLookupError), \
                    mock.patch.object(BUILD.os, "killpg", side_effect=ProcessLookupError):
                recovered = BUILD.recover_stale_lock(output, owner, receipt)
            self.assertFalse(lock.exists())
            self.assertEqual(recovered["lock"]["contents"], lock_bytes.decode())
            self.assertEqual(recovered["interruptedBuild"]["logSha256"], BUILD.sha256(log))
            recovery_files = list((output / "logs").glob("stale-lock-recovery-*.json"))
            self.assertEqual(len(recovery_files), 1)
            self.assertEqual(
                json.loads(recovery_files[0].read_text())["lock"]["sha256"],
                BUILD.hashlib.sha256(lock_bytes).hexdigest(),
            )

    def test_stale_lock_rejects_active_runner_or_child_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            (output / "logs").mkdir(mode=0o700)
            log = output / "logs/build.log"
            log.write_text("partial\n")
            lock = output / BUILD.LOCK_FILE
            lock.write_text(json.dumps({"pid": 23456, "uid": os.getuid()}))
            os.chmod(lock, 0o600)
            owner = {"repo": str(output), "output": str(output), "uid": os.getuid(),
                     "schemaVersion": BUILD.OWNER_VERSION}
            receipt = {"owner": owner, "status": "failed", "stages": {"05-build": {
                "status": "running", "attempts": [{"status": "running", "pid": 34567,
                "log": "logs/build.log"}]}}}
            with mock.patch.object(BUILD.os, "kill", return_value=None):
                with self.assertRaisesRegex(BUILD.BuildError, "still alive"):
                    BUILD.recover_stale_lock(output, owner, receipt)
            self.assertTrue(lock.exists())
            with mock.patch.object(BUILD.os, "kill", side_effect=ProcessLookupError), \
                    mock.patch.object(BUILD.os, "killpg", return_value=None):
                with self.assertRaisesRegex(BUILD.BuildError, "process group .* still alive"):
                    BUILD.recover_stale_lock(output, owner, receipt)
            self.assertTrue(lock.exists())

    def test_free_space_floor_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(BUILD, "free_bytes", return_value=99):
                with self.assertRaisesRegex(BUILD.BuildError, "below required floor"):
                    BUILD.require_capacity(pathlib.Path(temporary), 100)

    def test_source_stage_uses_exact_argv_and_pinned_timeout(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            scripts = output / "scripts"
            scripts.mkdir()
            python_file = scripts / "03-ungoogled.py"
            python_file.write_text("pass\n")
            shell_file = scripts / "01-sync.sh"
            shell_file.write_text("true\n")
            runner = BUILD.Runner.__new__(BUILD.Runner)
            runner.output = output
            runner.config = {"build": {"timeoutsSeconds": {"patches": 14400, "sync": 28800}}}
            calls = []
            runner.run = lambda *args: calls.append(args)
            runner.source_stage(scripts, "03-ungoogled.py", "patches")
            self.assertEqual(calls[0][0], "03-ungoogled")
            self.assertEqual(calls[0][1], [os.sys.executable, str(python_file)])
            self.assertEqual(calls[0][2], output)
            self.assertEqual(calls[0][3], 14400)
            runner.source_stage(scripts, "01-sync.sh", "sync")
            self.assertEqual(calls[1][0], "01-sync")
            self.assertEqual(calls[1][1], ["/bin/bash", str(shell_file)])
            self.assertEqual(calls[1][3], 28800)

    def test_stage_order_keeps_fresh_upstream_sequence(self):
        self.assertEqual(
            ["01-sync.sh", "03-ungoogled.py", "04-domain-substitution.sh",
             "profile-patch", "02-gn-args.sh", "05-build.sh"],
            BUILD.EXECUTION_STAGE_NAMES,
        )

    def test_stage_resume_skips_only_last_successful_attempt(self):
        self.assertTrue(BUILD.Runner.stage_succeeded({"status": "succeeded",
                                                      "attempts": [{"status": "failed"},
                                                                   {"status": "succeeded"}]}))
        self.assertFalse(BUILD.Runner.stage_succeeded({"status": "failed",
                                                       "attempts": [{"status": "succeeded"},
                                                                    {"status": "failed"}]}))


if __name__ == "__main__":
    unittest.main()
