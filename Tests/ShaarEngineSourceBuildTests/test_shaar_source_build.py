# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Focused step-0 checks; these never run a Chromium source build."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-shaar-engine-source.py"
SPEC = importlib.util.spec_from_file_location("build_shaar_engine_source", SCRIPT)
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class ShaarSourceBuildTests(unittest.TestCase):
    def test_reference_requires_applied_safe_storage_migration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            path = source / "components/os_crypt/common/keychain_password_mac.mm"
            path.parent.mkdir(parents=True)
            old = 'const char name[] = "Ardia Safe Storage";\n'
            new = 'const char name[] = "Shaar Safe Storage";\n'
            patch = root / "migration.patch"
            patch.write_text("diff --git a/components/os_crypt/common/keychain_password_mac.mm "
                             "b/components/os_crypt/common/keychain_password_mac.mm\n"
                             "--- a/components/os_crypt/common/keychain_password_mac.mm\n"
                             "+++ b/components/os_crypt/common/keychain_password_mac.mm\n"
                             "@@ -1 +1 @@\n-" + old + "+" + new)
            path.write_text(old)
            with self.assertRaisesRegex(BUILD.BuildError, "Safe Storage migration"):
                BUILD.verify_safe_storage_migration(source, patch)
            path.write_text(new)
            BUILD.verify_safe_storage_migration(source, patch)

    def fixture_repo(self, temporary: str) -> Path:
        repo = Path(temporary) / "repo"
        layer_parent = repo / "ThirdParty/ChromiumEngine"
        layer_parent.mkdir(parents=True)
        shutil.copytree(ROOT / BUILD.LAYER, layer_parent / "layer")
        shutil.copytree(ROOT / "ThirdParty/ChromiumEngine/patches", layer_parent / "patches")
        shutil.copy2(ROOT / BUILD.CONFIG, layer_parent / "source-build.json")
        return repo

    def test_dry_run_is_shaar_only_and_creates_no_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.fixture_repo(temporary)
            config = BUILD.load_config(repo)
            plan = BUILD.dry_run(repo, config)
            self.assertEqual(plan["sourceKind"], "shaar")
            self.assertEqual(plan["target"], "chrome_framework")
            self.assertEqual(config["build"]["output"], "build/ShaarEngineSource")
            self.assertNotIn("source", config)
            self.assertNotIn("mantrakp04/ardia", json.dumps(config))
            self.assertFalse((repo / "build").exists())
            self.assertNotIn("build/EngineSource", json.dumps(plan))

    def test_execution_requires_reference_before_any_output_is_created(self):
        with mock.patch.object(BUILD, "prepare_owned_output") as prepare_output:
            self.assertEqual(BUILD.main(["--run"]), 1)
            self.assertEqual(BUILD.main(["--relink-from-reference"]), 1)
            prepare_output.assert_not_called()

    def test_manifest_and_output_guards_reject_tamper_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.fixture_repo(temporary)
            layer_file = repo / BUILD.LAYER / "chrome/browser/shaar/BUILD.gn"
            layer_file.write_text(layer_file.read_text() + "# tampered\n")
            with self.assertRaisesRegex(BUILD.BuildError, "manifest or tree digest"):
                BUILD.load_config(repo)
            shutil.copy2(ROOT / BUILD.LAYER / "chrome/browser/shaar/BUILD.gn", layer_file)
            patch = repo / "ThirdParty/ChromiumEngine/patches/0001-shaar-framework-hook.patch"
            patch.write_text(patch.read_text() + "# tampered\n")
            with self.assertRaisesRegex(BUILD.BuildError, "patch digest mismatch"):
                BUILD.load_config(repo)
            shutil.copy2(ROOT / "ThirdParty/ChromiumEngine/patches/0001-shaar-framework-hook.patch", patch)
            dual_patch = repo / "ThirdParty/ChromiumEngine/patches/0005-shaar-dual-export-main-delegate.patch"
            dual_patch.write_text(dual_patch.read_text() + "# tampered\n")
            with self.assertRaisesRegex(BUILD.BuildError, "delegate patch digest mismatch"):
                BUILD.load_config(repo)
            shutil.copy2(ROOT / "ThirdParty/ChromiumEngine/patches/0005-shaar-dual-export-main-delegate.patch", dual_patch)
            (repo / "build").symlink_to(Path(temporary) / "outside", target_is_directory=True)
            with self.assertRaisesRegex(BUILD.BuildError, "symlink rejected in output"):
                BUILD.load_config(repo)

    def test_owner_receipt_never_adopts_legacy_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.fixture_repo(temporary)
            legacy = repo / "build/EngineSource"
            legacy.mkdir(parents=True)
            sentinel = legacy / "receipt.json"
            sentinel.write_text("legacy receipt must remain unchanged")
            output = BUILD.prepare_owned_output(repo)
            self.assertEqual(output, repo.resolve() / "build/ShaarEngineSource")
            self.assertTrue((output / ".metadata_never_index").is_file())
            self.assertEqual(sentinel.read_text(), "legacy receipt must remain unchanged")
            self.assertEqual(BUILD.prepare_owned_output(repo), output)
            owner = output / BUILD.OWNER_FILE
            value = json.loads(owner.read_text())
            value["sourceKind"] = "legacy"
            owner.write_text(json.dumps(value))
            with self.assertRaisesRegex(BUILD.BuildError, "owner record mismatch"):
                BUILD.prepare_owned_output(repo)

    def test_resume_removes_only_a_dead_siso_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            lock = output / ".siso_lock"
            lock.write_text("pid=12345")
            with mock.patch.object(BUILD.os, "kill", return_value=None):
                with self.assertRaisesRegex(BUILD.BuildError, "still owns"):
                    BUILD.clear_stale_siso_lock(output)
            self.assertTrue(lock.exists())
            with mock.patch.object(BUILD.os, "kill", side_effect=ProcessLookupError):
                BUILD.clear_stale_siso_lock(output)
            self.assertFalse(lock.exists())
            lock.symlink_to(output / "outside")
            with self.assertRaisesRegex(BUILD.BuildError, "symlinked Siso lock"):
                BUILD.clear_stale_siso_lock(output)

    def test_layer_tests_reuse_owned_output_and_record_fake_runner_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.fixture_repo(temporary)
            config = BUILD.load_config(repo)
            output = BUILD.prepare_owned_output(repo)
            chromium = output / "chromium_git/chromium/src"
            build_dir = chromium / "out" / config["build"]["configuration"]
            build_dir.mkdir(parents=True)
            (output / "depot_tools").mkdir()
            (output / "depot_tools/gn").write_text("fake gn\n")
            (output / "depot_tools/siso").write_text("fake siso\n")
            (build_dir / "args.gn").write_text("is_debug = false\n")
            receipt = {
                "schemaVersion": 1,
                "sourceKind": "shaar",
                "output": str(output),
                "configSha256": BUILD.sha256(repo / BUILD.CONFIG),
                "layerSha256": config["layer"]["sha256"],
            }
            (output / BUILD.RECEIPT_FILE).write_text(json.dumps(receipt))

            class FakeRunner:
                def __init__(self):
                    self.calls = []

                def __call__(self, args, **kwargs):
                    self.calls.append((list(args), kwargs))
                    if args[0].endswith("gn"):
                        return subprocess.CompletedProcess(args, 0, "generated", "")
                    if args[0].endswith("siso"):
                        (build_dir / "shaar_layer_unittests").write_text("fake test binary")
                        return subprocess.CompletedProcess(args, 0, "built", "")
                    report = Path(args[2].split("json:", 1)[1])
                    report.write_text(json.dumps({
                        "tests": [{"name": "ShaarLayerTest.Passes", "result": "COMPLETED"}],
                        "failures": [],
                    }))
                    return subprocess.CompletedProcess(args, 0, "passed", "")

            fake_runner = FakeRunner()
            stage = BUILD.run_layer_tests(repo, config, runner=fake_runner)
            self.assertEqual(stage["status"], "succeeded")
            self.assertEqual(len(fake_runner.calls), 3)
            self.assertEqual(fake_runner.calls[0][0][1], "gen")
            self.assertEqual(fake_runner.calls[1][0][-1], "//chrome:shaar_layer_unittests")
            self.assertEqual(fake_runner.calls[1][0][5:7], ["-local_jobs", "6"])
            self.assertEqual(fake_runner.calls[2][0][1], "--headless")
            self.assertTrue(fake_runner.calls[2][0][2].startswith("--gtest_output=json:"))
            self.assertIn("shaar_layer_tests = true", (build_dir / "args.gn").read_text())
            saved = json.loads((output / BUILD.RECEIPT_FILE).read_text())
            self.assertEqual(saved["stages"]["layer-tests"]["result"]["failures"], [])

    def test_export_receipt_requires_shaar_symbols_and_rejects_legacy(self):
        symbols = "\n".join(BUILD.REQUIRED_EXPORTS) + "\n_ChromeMain\n"
        checked = BUILD.check_exports(symbols)
        self.assertEqual(checked["required"], list(BUILD.REQUIRED_EXPORTS))
        with self.assertRaisesRegex(BUILD.BuildError, "missing Shaar"):
            BUILD.check_exports("_shaar_abi_major\n")
        for forbidden in ("_ac_engine_call", "_OBJC_CLASS_$_ArdiaCoreEngine"):
            with self.subTest(forbidden=forbidden), self.assertRaisesRegex(
                    BUILD.BuildError, "legacy framework exports"):
                BUILD.check_exports(symbols + forbidden + "\n")
        with self.assertRaisesRegex(BUILD.BuildError, "legacy framework exports"):
            BUILD.check_exports(symbols, "0000000000001000 t _ac_hidden_helper\n")
        dual = BUILD.check_exports(symbols + "_ac_engine_abi_version\n", mode="dual-export")
        self.assertIn("_ac_engine_abi_version", dual["legacyFound"])
        with self.assertRaisesRegex(BUILD.BuildError, "lacks pinned Ardia"):
            BUILD.check_exports(symbols, mode="dual-export")

        with tempfile.TemporaryDirectory() as temporary:
            repo = self.fixture_repo(temporary)
            config = BUILD.load_config(repo)
            output = BUILD.prepare_owned_output(repo)
            binary = output / config["build"]["frameworkBinary"]
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fake Mach-O for mocked nm")
            receipt = output / BUILD.RECEIPT_FILE
            with mock.patch.object(BUILD.subprocess, "run", return_value=mock.Mock(stdout=symbols)):
                record = BUILD.verify_framework(repo, binary, receipt, config)
            self.assertEqual(record["framework"]["exports"]["legacyFound"], [])
            self.assertEqual(record["status"], "succeeded")
            self.assertEqual(json.loads(receipt.read_text()), record)
            self.assertEqual(receipt.stat().st_mode & 0o077, 0)
            with self.assertRaisesRegex(BUILD.BuildError, "outside Shaar output|layout"):
                BUILD.verify_framework(repo, repo / "build/EngineSource/binary", receipt, config)

    def test_native_scaffold_compiles_and_event_bridge_contract_runs(self):
        layer = ROOT / BUILD.LAYER
        source = layer / "chrome/browser/shaar/engine"
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "shaar-event-bridge-test"
            subprocess.run([
                "clang++", "-std=c++20", "-I", str(layer),
                str(source / "shaar_engine.cc"),
                str(source / "shaar_event_bridge.cc"),
                str(Path(__file__).with_name("shaar_event_bridge_test.cc")),
                "-o", str(binary),
            ], check=True, capture_output=True, text=True, timeout=60)
            subprocess.run([str(binary)], check=True, capture_output=True,
                           text=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
