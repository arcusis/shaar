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
SWIFT_REPORTS = load_script("ci-swift-reports")
EXTRACTION = load_script("check-codeql-extraction")
CODEQL_BUILD = load_script("codeql-build")


class PipelineGateTests(unittest.TestCase):
    def test_known_non_native_diffs_and_unknown_changes_select_required_coverage(self):
        for paths in (["Notebook/Note.md"], ["README.md", "CONTRIBUTING.md"]):
            self.assertEqual(PLAN.select_stages(paths, "pull_request"), (False, False, True))
        for paths in (["website/src/Page.svelte"], ["website/package.json", "Notebook/Note.md"]):
            self.assertEqual(PLAN.select_stages(paths, "pull_request"), (False, True, True))
            self.assertEqual(PLAN.select_stages(paths, "merge_group"), (False, True, True))
        for paths in (None, [], ["unclassified-input"]):
            self.assertTrue(PLAN.select_stages(paths, "pull_request")[0])
        self.assertEqual(PLAN.select_stages(["Sources/App.swift"], "pull_request"), (True, False, True))
        self.assertEqual(PLAN.select_stages(["scripts/tool.py"], "pull_request"), (True, False, True))
        for paths in (["scripts/codeql-build.py"], [".github/workflows/ci-codeql.yml"],
                      [".github/actions/ci-setup/action.yml"]):
            self.assertTrue(PLAN.select_stages(paths, "pull_request")[2])
        for event in ("push", "schedule", "workflow_dispatch"):
            self.assertEqual(PLAN.select_stages(["Notebook/Note.md"], event), (True, True, True))
        self.assertTrue(PLAN.select_stages(["scripts/tool.py"], "merge_group")[2])

    def test_website_gate_rejects_unexpected_skip_or_missing_result(self):
        needs = self.results(native="skipped")
        self.assertTrue(GATE.gate_errors(needs, False, False, True))
        needs["website"] = {"result": "skipped"}
        self.assertTrue(GATE.gate_errors(needs, False, False, True))
        needs["website"] = {"result": "success"}
        self.assertEqual(GATE.gate_errors(needs, False, False, True), [])

    def test_new_branch_push_uses_immutable_production_merge_base(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text(json.dumps({"before": "0" * 40}))
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_SHA": "c" * 40, "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with (patch.dict(os.environ, env),
                  patch.object(PLAN.subprocess, "check_output", return_value="b" * 40 + "\n") as baseline,
                  patch.object(PLAN.subprocess, "run") as command):
                command.return_value.returncode = 0
                command.return_value.stdout = b"Sources/ArcusisBrowser/InspectorPanel.swift\0"
                PLAN.main()
            baseline.assert_called_once_with(["git", "merge-base", "origin/production", "HEAD"], text=True)
            self.assertEqual(command.call_args.args[0], ["git", "diff", "--name-only", "-z", "b" * 40, "HEAD"])
            self.assertIn("full=true", (root / "output").read_text())
            self.assertIn("base=" + "b" * 40, (root / "output").read_text())

    def test_existing_branch_push_preserves_before_sha(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text(json.dumps({"before": "a" * 40}))
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_SHA": "c" * 40, "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with (patch.dict(os.environ, env),
                  patch.object(PLAN.subprocess, "check_output") as baseline,
                  patch.object(PLAN.subprocess, "run") as command):
                command.return_value.returncode = 0
                command.return_value.stdout = b"README.md\0"
                PLAN.main()
            baseline.assert_not_called()
            self.assertIn("full=true", (root / "output").read_text())
            self.assertIn("base=" + "a" * 40, (root / "output").read_text())

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
        results.update({name: {"result": native} for name in ("build", "coverage", "visuals", "localization", "engine", "shipping", "codeql", "inspector-contracts")})
        results.update({name: {"result": nightly} for name in ("sanitizers", "dead-code")})
        results["codeql"] = {"result": "success"}
        return results

    def test_full_pipeline_rejects_failed_cancelled_skipped_or_missing_stage(self):
        for stage in ("engine", "localization", "inspector-contracts"):
            for result in ("failure", "cancelled", "skipped", None):
                with self.subTest(stage=stage, result=result):
                    needs = self.results()
                    if result is None:
                        del needs[stage]
                    else:
                        needs[stage]["result"] = result
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


class SwiftReportTests(unittest.TestCase):
    def transcript(self, state="passed"):
        return ("Test Suite 'All tests' started at now.\n"
                "Test Case '-[Fixture.Cases sample]' started.\n"
                "authored diagnostic\n"
                f"Test Case '-[Fixture.Cases sample]' {state} (0.125 seconds).\n"
                f"Test Suite 'All tests' {state if state == 'failed' else 'passed'} at now.\n"
                f" Executed 1 test, with {int(state == 'failed')} failures in 0.125 seconds\n")

    def test_xctest_report_keeps_multiple_products_skips_and_native_swift_testing(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "tests.log"
            log.write_text(self.transcript() + self.transcript("skipped") + "Test run with 1 test passed\n")
            native = directory / "swift-swift-testing.xml"
            native.write_text('<testsuite tests="1"><testcase name="native"/></testsuite>')
            (directory / "swift.xml").write_text('<testsuite tests="2"/>')
            SWIFT_REPORTS.write_reports(log, directory)
            suite = ET.parse(directory / "xctest.xml").getroot()
            self.assertEqual(suite.attrib["tests"], "2")
            self.assertEqual(suite.attrib["skipped"], "1")
            self.assertEqual(suite[0].attrib["classname"], "Fixture.Cases")
            self.assertEqual(suite[0].attrib["name"], "sample")
            self.assertTrue(native.is_file())
            self.assertFalse((directory / "swift.xml").exists())

    def test_xctest_failure_keeps_diagnostic_and_duration(self):
        cases = SWIFT_REPORTS.xctest_cases(self.transcript("failed"))
        self.assertEqual(cases[0].attrib["time"], "0.125")
        self.assertIn("authored diagnostic", cases[0].find("failure").text)

    def test_truncated_unpaired_and_mismatched_xctest_logs_fail(self):
        malformed = (self.transcript().split("Test Case", 1)[0],
                     self.transcript().replace(" started.\n", "\n"),
                     self.transcript().replace("Executed 1 test", "Executed 2 tests"))
        for text in malformed:
            with self.subTest(text=text), self.assertRaises(ValueError):
                SWIFT_REPORTS.xctest_cases(text)

    def test_missing_native_swift_testing_report_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "tests.log"
            log.write_text(self.transcript() + "Test run with 1 test passed\n")
            with self.assertRaisesRegex(ValueError, "native JUnit"):
                SWIFT_REPORTS.write_reports(log, directory)


class ProbeSoakTests(unittest.TestCase):
    def test_shards_cover_every_original_iteration_once_without_retry(self):
        from collections import Counter
        from ci_engine import engine_shards, shard_modes
        for iterations in (1, 2, 3, 10):
            expected = Counter((mode, index) for mode in STAGES.ENGINE_MODES
                               for index in range(1, max(iterations, STAGES.MINIMUM_REPETITIONS.get(mode, 1)) + 1))
            actual = Counter((mode, index) for shard in engine_shards(iterations)
                             for mode, indexes in shard_modes(shard, iterations) for index in indexes)
            self.assertEqual(actual, expected)
        with self.assertRaises(ValueError):
            shard_modes("private-window-4", 1)

    def test_all_modes_share_one_build_and_preserve_each_iteration(self):
        checks = unittest.mock.Mock()
        checks.run.return_value = 0
        with tempfile.TemporaryDirectory() as directory, patch.object(STAGES, "ROOT", Path(directory)), patch.object(STAGES, "require_hosted_mac"):
            STAGES.run_engine(checks, "all", 2)
        names = [call.args[0] for call in checks.run.call_args_list]
        self.assertEqual(names, ["verification-build", "baseline-1", "baseline-2",
                                 "private-window-1", "private-window-2", "private-window-3",
                                 "quit-exit-1", "quit-exit-2", "quit-exit-3",
                                 "session-recovery-1", "session-recovery-2"])

    def test_soak_keeps_all_iteration_failures_without_retrying(self):
        checks = unittest.mock.Mock()
        checks.run.side_effect = [0, 1, 0, 1]
        with patch.object(STAGES, "require_hosted_mac"), patch.dict(os.environ, {}):
            STAGES.run_engine(checks, "quit-exit", 1)
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


class EngineTransferTests(unittest.TestCase):
    def test_transferred_bundle_preserves_exec_and_links_and_rejects_wrong_context_or_digest(self):
        from ci_engine import BUNDLE_NAME, archive_bundle, restore_bundle
        import shutil
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            "GITHUB_SHA": "a" * 40, "CI_TOOLCHAIN_ID": "toolchain",
        }):
            root = Path(temporary)
            pin = root / "ThirdParty/ArdiaCore/pin.json"
            pin.parent.mkdir(parents=True)
            pin.write_text(json.dumps({"sha256": "b" * 64}))
            bundle = root / "build" / BUNDLE_NAME
            bundle.mkdir(parents=True)
            executable = bundle / "Main"
            executable.write_bytes(b"authored executable")
            executable.chmod(0o755)
            (bundle / "Alias").symlink_to("Main")
            directory = root / "evidence"
            directory.mkdir()
            archive_bundle(root, directory)
            shutil.rmtree(bundle)
            with patch.dict(os.environ, {"GITHUB_SHA": "c" * 40}), self.assertRaises(ValueError):
                restore_bundle(root, directory)
            restore_bundle(root, directory)
            self.assertEqual(executable.read_bytes(), b"authored executable")
            self.assertEqual(executable.stat().st_mode & 0o111, 0o111)
            self.assertEqual((bundle / "Alias").readlink(), Path("Main"))
            shutil.rmtree(bundle)
            with (directory / "verification.tar.gz").open("ab") as archive:
                archive.write(b"tampered")
            with self.assertRaisesRegex(ValueError, "digest"):
                restore_bundle(root, directory)


class SwiftExtractionTests(unittest.TestCase):
    def test_missing_source_fails_even_when_other_modules_have_more_files(self):
        root = Path("/checkout")
        report = {"#select": {"tuples": [[{"label": "/checkout/Sources/Core/One.swift"}, "extracted"],
                                          [{"label": "One.swift", "url": {"uri": "file:///checkout/Sources/App/Two.swift"}}, "extracted"]]}}
        expected = {"Sources/Core/One.swift", "Sources/App/Two.swift", "Sources/App/Missing.swift"}
        self.assertEqual(EXTRACTION.missing_sources(report, expected, root), ["Sources/App/Missing.swift"])
        self.assertEqual(EXTRACTION.missing_sources(report, expected - {"Sources/App/Missing.swift"}, root), [])
        with self.assertRaises(ValueError):
            EXTRACTION.missing_sources(report, set(), root)


class SwiftCompilerPlanTests(unittest.TestCase):
    def test_analysis_target_matches_shipping_arm64_on_every_runner(self):
        CODEQL_BUILD.validate_compilation([
            "swiftc", "-whole-module-optimization", "-target", "arm64-apple-macosx26.0"])
        for arguments in (["swiftc", "-whole-module-optimization", "-target", "x86_64-apple-macosx26.0"],
                          ["swiftc", "-target", "arm64-apple-macosx26.0"],
                          ["swiftc", "-whole-module-optimization"]):
            with self.assertRaisesRegex(ValueError, "arm64"):
                CODEQL_BUILD.validate_compilation(arguments)

    def test_native_graph_materializes_response_files_and_framework_links_without_compiling(self):
        from swift_build_plan import manifest_commands, prepare_inputs
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            scratch = root / "build/plan"
            scratch.mkdir(parents=True)
            framework = root / "artifacts/Example.framework"
            framework.mkdir(parents=True)
            (framework / "Binary").write_bytes(b"authored binary")
            (framework / "Alias").symlink_to("Binary")
            response = scratch / "Core.build/sources"
            source = root / "Sources/With Space.swift"
            copied = scratch / "Example.framework"
            manifest = scratch / "debug.yaml"
            manifest.write_text("commands:\n  \"source-list\":\n    tool: write-auxiliary-file\n    inputs: "
                                + json.dumps(["<sources-file-list>", str(source)]) + "\n    outputs: "
                                + json.dumps([str(response)]) + "\n  \"framework\":\n    tool: copy-tool\n    inputs: "
                                + json.dumps([str(framework)]) + "\n    outputs: " + json.dumps([str(copied)]) + "\n")
            prepare_inputs(manifest_commands(manifest), root, scratch)
            self.assertEqual(CODEQL_BUILD.command_sources(["@" + str(response)], root), {"Sources/With Space.swift"})
            self.assertEqual((copied / "Binary").read_bytes(), b"authored binary")
            self.assertEqual((copied / "Alias").readlink(), Path("Binary"))
            self.assertEqual(list(scratch.rglob("*.o")), [])

    def test_native_graph_refuses_outputs_outside_scratch_and_dependency_cycles(self):
        from swift_build_plan import ordered_modules, prepare_inputs
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            with self.assertRaisesRegex(ValueError, "escaped"):
                prepare_inputs([{"outputs": [str(root / "outside")]}], root, root / "build/plan")
        first = ["swiftc", "-module-name", "First", "-emit-module-path", "First.swiftmodule"]
        second = ["swiftc", "-module-name", "Second", "-emit-module-path", "Second.swiftmodule"]
        nodes = [{"args": first, "inputs": ["Second.swiftmodule"]},
                 {"args": second, "inputs": ["First.swiftmodule"]}]
        with self.assertRaisesRegex(ValueError, "cycle"):
            ordered_modules(nodes, [first, second])
        nodes[1]["inputs"] = []
        self.assertEqual(ordered_modules(nodes, [first, second]), [second, first])

    def test_full_extraction_inventory_includes_manifest_and_compilation_plugins(self):
        from ci_support import swift_source_files
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            names = {"Sources/App/A.swift", "Plugins/CompileLocalizations/plugin.swift", "Package.swift"}
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// authored fixture")
            self.assertEqual(swift_source_files(root, "full", tracked=False, include_build_inputs=True), names)
            self.assertEqual(swift_source_files(root, "shipping", tracked=False), {"Sources/App/A.swift"})

    def test_replay_inventory_detects_new_untracked_swift_file_without_running_git(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Sources/App/A.swift"
            source.parent.mkdir(parents=True)
            source.write_text("struct A {}")
            with patch("ci_support.subprocess.check_output", return_value=b"Sources/App/A.swift\0"):
                before = CODEQL_BUILD.source_hashes(root)
            source.with_name("B.swift").write_text("struct B {}")
            with patch("ci_support.subprocess.check_output") as git_command:
                after = CODEQL_BUILD.source_hashes(root, tracked=False)
            git_command.assert_not_called()
            self.assertNotEqual(before, after)
            self.assertEqual(set(after), {"Sources/App/A.swift", "Sources/App/B.swift"})

    def test_mutated_compiler_binary_rejects_replay_before_compiling(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            compiler = directory / "swiftc"
            compiler.write_bytes(b"changed compiler")
            plan = directory / "plan.json"
            plan.write_text(json.dumps({"scope": "full", "compiler": str(compiler), "compiler_sha256": "old",
                                        "revision": "a", "toolchain": "one", "sources": {}}))
            with (patch.object(CODEQL_BUILD, "PLAN", plan),
                  patch.object(CODEQL_BUILD, "identity", return_value={"revision": "a", "toolchain": "one"}),
                  patch.object(CODEQL_BUILD, "source_hashes", return_value={}),
                  self.assertRaisesRegex(ValueError, "compiler changed")):
                CODEQL_BUILD.replay()

    def test_shipping_scope_retains_support_warmup_and_excludes_verification_module(self):
        from ci_support import swift_source_files
        names = b"Sources/App/A.swift\0Sources/ShaarVerification/Probe.swift\0Tests/TestSupport/Seed.swift\0"
        with patch("ci_support.subprocess.check_output", return_value=names):
            self.assertEqual(len(swift_source_files(ROOT)), 3)
            self.assertEqual(swift_source_files(ROOT, "shipping"), {"Sources/App/A.swift", "Tests/TestSupport/Seed.swift"})
            with self.assertRaises(ValueError):
                swift_source_files(ROOT, "unknown")

    def test_scope_mismatch_rejects_plan_before_any_compiler_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            plan = Path(temporary) / "plan.json"
            plan.write_text(json.dumps({"scope": "full"}))
            with patch.object(CODEQL_BUILD, "PLAN", plan), self.assertRaisesRegex(ValueError, "scope changed"):
                CODEQL_BUILD.replay("shipping")

    def test_compiler_inventory_includes_test_targets_for_complete_pr_analysis(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(CODEQL_BUILD.command_sources([
                "Tests/TestSupport/SeededGenerator.swift", "Tests/BrowserCoreTests/Cases.swift",
            ], root), {"Tests/TestSupport/SeededGenerator.swift", "Tests/BrowserCoreTests/Cases.swift"})

    def test_semantic_commands_drop_cached_outputs_but_keep_every_input_and_definition(self):
        arguments = ["/toolchain/swiftc", "-module-name", "App", "-whole-module-optimization",
                     "-target", "arm64-apple-macosx26.0", "-emit-module", "-emit-module-path", "old.swiftmodule",
                     "-c", "@build/sources", "-output-file-map", "old.json", "-incremental",
                     "-D", "FEATURE", "-module-cache-path", "old-cache", "-I", "Modules"]
        actual = CODEQL_BUILD.typecheck_arguments(arguments)
        for absent in ("-c", "-emit-module", "old.swiftmodule", "old.json", "-incremental", "old-cache"):
            self.assertNotIn(absent, actual)
        for retained in ("@build/sources", "FEATURE", "Modules", "-whole-module-optimization"):
            self.assertIn(retained, actual)
        self.assertEqual(actual[-1], "-typecheck")

    def test_complete_inventory_includes_tests_manifest_plugins_and_unknown_swift_paths(self):
        from ci_support import swift_source_files
        names = b"Sources/App.swift\0Tests/Unit.swift\0Package.swift\0Plugins/Compile/Plugin.swift\0Other.swift\0"
        with patch("ci_support.subprocess.check_output", return_value=names) as command:
            self.assertEqual(len(swift_source_files(ROOT, "all")), 5)
        self.assertEqual(command.call_args.args[0][-1], "*.swift")

    def test_docs_prs_still_require_swift_analysis(self):
        needs = PipelineGateTests().results(native="skipped")
        self.assertEqual(GATE.gate_errors(needs, False, False), [])
        needs["codeql"] = {"result": "skipped"}
        self.assertIn("codeql: skipped", GATE.gate_errors(needs, False, False))

    def test_plan_keeps_argument_arrays_and_rejects_missing_or_duplicate_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Sources/Core/With Space.swift"
            source.parent.mkdir(parents=True)
            source.write_text("struct Example {}")
            response = root / "build/sources"
            response.parent.mkdir()
            response.write_text(json.dumps(str(source)))
            compiler = Path("/toolchain/swiftc")
            line = f"{compiler} -module-name Core -whole-module-optimization -target arm64-apple-macosx26.0 @{response}"
            expected = {"Sources/Core/With Space.swift"}
            commands = CODEQL_BUILD.compiler_commands(line, root, compiler, expected)
            self.assertEqual(commands[0][-1], "@" + str(response))
            with self.assertRaisesRegex(ValueError, "omitted"):
                CODEQL_BUILD.compiler_commands(line, root, compiler, expected | {"Sources/Other.swift"})
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                CODEQL_BUILD.compiler_commands(line + "\n" + line, root, compiler, expected)

    def test_response_file_cannot_escape_owned_build_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            response = root / "outside"
            response.write_text("Sources/Core.swift")
            with self.assertRaisesRegex(ValueError, "response file"):
                CODEQL_BUILD.command_sources(["@" + str(response)], root)

    def test_changed_source_or_toolchain_rejects_replay_before_compiling(self):
        with tempfile.TemporaryDirectory() as temporary:
            plan = Path(temporary) / "plan.json"
            plan.write_text(json.dumps({"scope": "full", "revision": "a", "toolchain": "one", "sources": {"Sources/A.swift": "old"}}))
            with (patch.object(CODEQL_BUILD, "PLAN", plan),
                  patch.object(CODEQL_BUILD, "identity", return_value={"revision": "a", "toolchain": "one"}),
                  patch.object(CODEQL_BUILD, "source_hashes", return_value={"Sources/A.swift": "new"}),
                  patch.object(CODEQL_BUILD.subprocess, "check_output") as compile_command,
                  self.assertRaisesRegex(ValueError, "source content changed")):
                CODEQL_BUILD.replay()
            compile_command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
