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
            self.assertEqual(sentinel.read_text(), "legacy receipt must remain unchanged")
            self.assertEqual(BUILD.prepare_owned_output(repo), output)
            owner = output / BUILD.OWNER_FILE
            value = json.loads(owner.read_text())
            value["sourceKind"] = "legacy"
            owner.write_text(json.dumps(value))
            with self.assertRaisesRegex(BUILD.BuildError, "owner record mismatch"):
                BUILD.prepare_owned_output(repo)

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
