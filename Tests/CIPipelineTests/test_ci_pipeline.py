# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import sys
import tarfile
import tempfile
import tomllib
import unittest
import zipfile
from unittest.mock import patch
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PLAN = load_script("ci-plan")
GATE = load_script("ci-gate")
COVERAGE = load_script("check-coverage")
INSTALL = load_script("install-ci-tools")
EVIDENCE = load_script("ci-evidence")
STAGES = load_script("ci-stage")
PINS = load_script("ci-checks")
PYTHON_TESTS = load_script("test-python")
SBOM = load_script("ci-sbom")


class PipelineGateTests(unittest.TestCase):
    def test_probe_count_normalizes_dispatch_strings_before_typed_workflow_call(self):
        for value in (1, "1", 10, "10"):
            self.assertEqual(PLAN.iteration_count({"inputs": {"probe_iterations": value}}, "workflow_dispatch"), int(value))
        for value in (0, "0", 11, -1, "1.5", True, "invalid"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                PLAN.iteration_count({"inputs": {"probe_iterations": value}}, "workflow_dispatch")
        self.assertEqual(PLAN.iteration_count({}, "schedule"), 3)
        self.assertEqual(PLAN.iteration_count({}, "pull_request"), 1)

    def test_merge_group_compares_synthetic_head_to_immutable_base_and_fails_open_to_full_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text(json.dumps({"merge_group": {"base_sha": "b" * 40}}))
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_EVENT_NAME": "merge_group",
                   "GITHUB_SHA": "c" * 40, "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with patch.dict(os.environ, env), patch.object(PLAN.subprocess, "run") as command:
                command.return_value.returncode = 128
                PLAN.main()
            self.assertEqual(command.call_args.args[0], ["git", "diff", "--name-only", "-z", "b" * 40, "HEAD"])
            self.assertIn("full=true", (root / "output").read_text())
            self.assertIn("base=" + "b" * 40, (root / "output").read_text())

    def results(self, native="success", nightly="skipped"):
        results = {name: {"result": "success"} for name in ("plan", "fast", "dependency-review")}
        results.update({name: {"result": native} for name in ("build", "coverage", "visuals", "engine", "shipping", "codeql")})
        results.update({name: {"result": nightly} for name in ("sanitizers", "dead-code")})
        return results

    def test_full_pipeline_rejects_failed_cancelled_skipped_or_missing_stage(self):
        for result in ("failure", "cancelled", "skipped", None):
            with self.subTest(result=result):
                needs = self.results()
                if result is None:
                    del needs["engine"]
                else:
                    needs["engine"]["result"] = result
                self.assertTrue(GATE.gate_errors(needs, True, False))

    def test_docs_skip_native_but_never_skip_fast_gates(self):
        needs = self.results(native="skipped")
        self.assertEqual(GATE.gate_errors(needs, False, False), [])
        needs["fast"]["result"] = "skipped"
        self.assertTrue(GATE.gate_errors(needs, False, False))

    def test_nightly_requires_deep_checks(self):
        self.assertTrue(GATE.gate_errors(self.results(), True, True))
        self.assertEqual(GATE.gate_errors(self.results(nightly="success"), True, True), [])

    def test_only_known_markdown_paths_skip_native_stages(self):
        self.assertTrue(PLAN.documentation_only(["README.md", "Notebook/_INDEX_Main.md"]))
        for paths in ([], ["scripts/tool.py"], [".github/workflows/ci.yml"], ["Sources/New.md"],
                      ["Notebook/probe.py"], ["Notebook/Note.md", "Package.resolved"]):
            self.assertFalse(PLAN.documentation_only(paths))


class CoverageGateTests(unittest.TestCase):
    def test_cached_profiles_are_removed_only_inside_expected_scratch_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            coverage = root / "scratch/debug/codecov/coverage.json"
            coverage.parent.mkdir(parents=True)
            coverage.with_suffix(".profraw").write_text("stale")
            with patch.object(STAGES.subprocess, "check_output", return_value=str(coverage)):
                self.assertEqual(STAGES.prepare_coverage(root, "scratch"), coverage)
            self.assertFalse(coverage.parent.exists())
            foreign = root / "foreign/codecov/coverage.json"
            foreign.parent.mkdir(parents=True)
            with patch.object(STAGES.subprocess, "check_output", return_value=str(foreign)), self.assertRaises(ValueError):
                STAGES.prepare_coverage(root, "scratch")
            self.assertTrue(foreign.parent.exists())

    def report(self, app=(4, 10), core=(8, 10)):
        return {"type": "llvm.coverage.json.export", "data": [{"files": [
            {"filename": f"/checkout/Sources/{module}/File.swift",
             "summary": {"lines": {"covered": counts[0], "count": counts[1]}}}
            for module, counts in (("ArcusisBrowser", app), ("BrowserCore", core))
        ]}]}

    def test_aggregate_improvement_does_not_hide_core_regression(self):
        base = COVERAGE.module_coverage(self.report())
        candidate = COVERAGE.module_coverage(self.report(app=(10, 10), core=(7, 10)))
        self.assertEqual(len(COVERAGE.regressions(base, candidate)), 1)
        self.assertIn("BrowserCore", COVERAGE.regressions(base, candidate)[0])

    def test_equal_ratio_and_improvement_pass(self):
        self.assertEqual(COVERAGE.regressions({"BrowserCore": (8, 10)}, {"BrowserCore": (16, 20)}), [])
        self.assertEqual(COVERAGE.regressions({"BrowserCore": (8, 10)}, {"BrowserCore": (9, 10)}), [])

    def test_missing_malformed_and_duplicate_source_data_fail(self):
        reports = [{}, {"type": "llvm.coverage.json.export", "data": [{"files": []}]}, self.report(core=(11, 10))]
        duplicated = self.report()
        duplicated["data"][0]["files"].append(duplicated["data"][0]["files"][0])
        reports.append(duplicated)
        for report in reports:
            with self.subTest(report=report), self.assertRaises(ValueError):
                COVERAGE.module_coverage(report)


class SupplyChainTests(unittest.TestCase):
    def test_generated_directory_exclusions_never_cover_nested_source_paths(self):
        config = tomllib.loads((ROOT / ".gitleaks.toml").read_text())
        patterns = config["allowlists"][0]["paths"]
        for path in (".git/objects/a", ".build/product", ".venv/package.py", "build/EngineCache/archive"):
            self.assertTrue(any(re.search(pattern, path) for pattern in patterns), path)
        for path in ("Sources/build/Probe.swift", "scripts/build/check.sh", "Tests/.venv/fixture.py", "build.swift"):
            self.assertFalse(any(re.search(pattern, path) for pattern in patterns), path)

    def test_spdx_file_checksums_and_package_verification_cover_real_files_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Shaar.app"
            app.mkdir()
            (app / "Main").write_bytes(b"executable")
            (app / "Resource").write_bytes(b"resource")
            (app / "Alias").symlink_to("Main")
            candidate = root / "candidate.zip"
            candidate.write_bytes(b"authored candidate")
            pin = {"chromiumVersion": "1.2.3", "archiveURL": "https://example.invalid/engine.zip", "sha256": "a" * 64}
            document, links = SBOM.build_document(app, candidate, "b" * 40, pin, [])
            self.assertEqual(len(document["files"]), 2)
            self.assertEqual(links, {"./Shaar.app/Alias": "Main"})
            self.assertTrue(document["packages"][0]["filesAnalyzed"])
            expected = sorted(hashlib.sha1(data, usedforsecurity=False).hexdigest() for data in (b"executable", b"resource"))
            verification = hashlib.sha1("".join(expected).encode(), usedforsecurity=False).hexdigest()
            self.assertEqual(document["packages"][0]["packageVerificationCode"]["packageVerificationCodeValue"], verification)
            for file in document["files"]:
                self.assertEqual({item["algorithm"] for item in file["checksums"]}, {"SHA1", "SHA256"})

    def test_installer_keeps_pinned_zip_runtime_companion_beside_executable(self):
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            archive.writestr("periphery", b"executable")
            archive.writestr("libIndexStore.dylib", b"runtime library")
        data = payload.getvalue()
        manifest = {"periphery": {"Darwin-arm64": {
            "url": "https://example.invalid/periphery.zip", "sha256": hashlib.sha256(data).hexdigest(),
            "companions": ["libIndexStore.dylib"],
        }}}
        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(INSTALL.json, "loads", return_value=manifest),
                patch.object(INSTALL.platform, "system", return_value="Darwin"),
                patch.object(INSTALL.platform, "machine", return_value="arm64"),
                patch.object(INSTALL.urllib.request, "urlopen", return_value=io.BytesIO(data)),
                patch.object(sys, "argv", ["installer", "--include-periphery", "--destination", directory]),
            ):
                INSTALL.main()
            self.assertEqual((Path(directory) / "periphery").read_bytes(), b"executable")
            self.assertEqual((Path(directory) / "libIndexStore.dylib").read_bytes(), b"runtime library")

    def archive(self, symbolic=False):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            member = tarfile.TarInfo("nested/tool")
            member.size = 6
            if symbolic:
                member.type = tarfile.SYMTYPE
                member.linkname = "/private/file"
            archive.addfile(member, io.BytesIO(b"binary"))
        return output.getvalue()

    def test_installer_rejects_checksum_mismatch_and_symlink_member(self):
        payload = self.archive()
        with self.assertRaises(ValueError):
            INSTALL.binary_from_archive(payload, "tool", "0" * 64)
        symbolic = self.archive(symbolic=True)
        with self.assertRaises(ValueError):
            INSTALL.binary_from_archive(symbolic, "tool", hashlib.sha256(symbolic).hexdigest())
        self.assertEqual(INSTALL.binary_from_archive(payload, "tool", hashlib.sha256(payload).hexdigest()), b"binary")

    def test_pin_check_covers_workflows_and_composite_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            actions = root / ".github/actions/setup"
            actions.mkdir(parents=True)
            (root / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "fixture", "state": {"revision": "a" * 40, "version": "1.0"}}]}))
            (actions / "action.yml").write_text("steps:\n  - uses: actions/checkout@v5\n")
            self.assertTrue(PINS.pin_errors(root))
            (actions / "action.yml").write_text(f"steps:\n  - uses: actions/checkout@{'a' * 40}\n")
            self.assertEqual(PINS.pin_errors(root), [])

    def test_evidence_ignores_profiles_and_rejects_foreign_roots(self):
        with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as directory, tempfile.TemporaryDirectory() as output:
            root = Path(directory)
            (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
            (root / "initial.json").write_text("{}")
            (root / "Chromium").mkdir()
            (root / "Chromium/Cookies").write_text("private")
            (root / "foreign.json").symlink_to(root / "Chromium/Cookies")
            log = Path(output) / "probe.log"
            log.write_text(f"Probe evidence: {root}\n")
            EVIDENCE.collect(log, Path(output) / "evidence")
            files = list((Path(output) / "evidence" / root.name).iterdir())
            self.assertEqual([path.name for path in files], ["initial.json"])
            (root / ".arcusis-probe").unlink()
            with self.assertRaises(ValueError):
                EVIDENCE.collect(log, Path(output) / "evidence")


class ProbeSoakTests(unittest.TestCase):
    def test_all_modes_share_one_build_and_preserve_each_iteration(self):
        checks = unittest.mock.Mock()
        checks.run.return_value = 0
        with tempfile.TemporaryDirectory() as directory, patch.object(STAGES, "ROOT", Path(directory)), patch.object(STAGES, "require_hosted_mac"):
            STAGES.run_engine(checks, "all", 2)
        names = [call.args[0] for call in checks.run.call_args_list]
        self.assertEqual(names, ["verification-build", "baseline-1", "baseline-2",
                                 "private-window-1", "private-window-2", "quit-exit-1",
                                 "quit-exit-2", "session-recovery-1", "session-recovery-2"])

    def test_soak_keeps_all_iteration_failures_without_retrying(self):
        checks = unittest.mock.Mock()
        checks.run.side_effect = [0, 1, 0, 1]
        with patch.object(STAGES, "require_hosted_mac"), patch.dict(os.environ, {}):
            STAGES.run_engine(checks, "quit-exit", 3)
        names = [call.args[0] for call in checks.run.call_args_list]
        self.assertEqual(names, ["verification-build", "quit-exit-1", "quit-exit-2", "quit-exit-3"])
        self.assertTrue(all(call.args[1][-1] == "--quit-exit" for call in checks.run.call_args_list[1:]))

    def test_native_stages_refuse_local_execution(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(RuntimeError):
            STAGES.require_hosted_mac()

    def test_command_failure_survives_later_success_in_junit(self):
        from ci_support import Commands
        with (
            tempfile.TemporaryDirectory() as directory,
            patch("ci_support.ROOT", Path(directory)),
            patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}),
        ):
            checks = Commands("soak")
            checks.run("failed", [sys.executable, "-c", "raise SystemExit(7)"])
            checks.run("passed", [sys.executable, "-c", "pass"])
            self.assertEqual(checks.finish(), 1)
            suite = ET.parse(checks.directory / "commands.xml").getroot()
            self.assertEqual(suite.attrib["failures"], "1")

    def test_python_junit_records_subtest_failure_and_skip(self):
        class Example(unittest.TestCase):
            def test_subtests(self):
                with self.subTest(value=1):
                    self.fail("authored failure")

            @unittest.skip("authored skip")
            def test_skip(self):
                pass

            def test_subtest_skip(self):
                with self.subTest(value=2):
                    self.skipTest("authored subtest skip")

        result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=PYTHON_TESTS.ReportResult).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(Example))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.xml"
            result.write_report(path)
            suite = ET.parse(path).getroot()
            self.assertFalse(result.wasSuccessful())
            self.assertEqual(suite.attrib["tests"], "3")
            self.assertEqual(len(suite.findall("testcase/failure")), 1)
            self.assertEqual(len(suite.findall("testcase/skipped")), 2)


if __name__ == "__main__":
    unittest.main()
