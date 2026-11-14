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
from types import SimpleNamespace
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
PYTHON_INSTALL = load_script("install-ci-python")
EVIDENCE = load_script("ci-evidence")
STAGES = load_script("ci-stage")
PINS = load_script("ci-checks")
PYTHON_TESTS = load_script("test-python")
SBOM = load_script("ci-sbom")
SWIFT_REPORTS = load_script("ci-swift-reports")
EXTRACTION = load_script("check-codeql-extraction")
CODEQL_BUILD = load_script("codeql-build")
RELEASE_CI = load_script("check-release-ci")
SCANNING_ISSUES = load_script("sync-code-scanning-issues")


class PipelineGateTests(unittest.TestCase):
    def test_ci_gate_validates_needs_json_and_stage_results(self):
        for raw, message in (
            ("{", "CI_NEEDS is not valid JSON"),
            ("[]", "CI_NEEDS must be a JSON object"),
            ('{"engine": []}', "CI_NEEDS entry 'engine' must contain a string result"),
            ('{"engine": {}}', "CI_NEEDS entry 'engine' must contain a string result"),
            ('{"engine": {"result": 1}}', "CI_NEEDS entry 'engine' must contain a string result"),
        ):
            with self.subTest(raw=raw), self.assertRaisesRegex(ValueError, message):
                GATE.parse_needs(raw)
        self.assertEqual(GATE.parse_needs('{"engine": {"result": "success"}}'),
                         {"engine": {"result": "success"}})

    def test_ci_evidence_collection_runs_after_failure_but_not_cancellation(self):
        action = (ROOT / ".github/actions/ci-evidence/action.yml").read_text()
        collector = action.split("    - name: Collect scoped native probe reports\n", 1)[1]
        collector = collector.split("    - name: Upload logs, reports and authored images", 1)[0]
        self.assertIn("if: ${{ !cancelled() }}", collector)
    def test_python_junit_destination_is_validated_before_suite_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            parent_file = directory / "file"
            parent_file.write_text("not a directory")
            self.assertEqual(PYTHON_TESTS.junit_output_path(str(directory / "report.xml")),
                             directory / "report.xml")
            for path in (directory, parent_file / "report.xml"):
                with self.subTest(path=path), self.assertRaises(
                    PYTHON_TESTS.argparse.ArgumentTypeError
                ):
                    PYTHON_TESTS.junit_output_path(str(path))

    def test_evidence_directory_argument_requires_an_existing_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.assertEqual(EVIDENCE.existing_directory(str(directory)), directory)
            missing = directory / "missing"
            regular_file = directory / "file"
            symlink = directory / "linked-directory"
            regular_file.write_text("not a directory")
            symlink.symlink_to(directory, target_is_directory=True)
            for path in (missing, regular_file, symlink):
                with self.subTest(path=path), self.assertRaisesRegex(
                    EVIDENCE.argparse.ArgumentTypeError,
                    "does not exist or is not a directory",
                ):
                    EVIDENCE.existing_directory(str(path))

    def test_ci_stage_exceptions_are_recorded_as_junit_failures(self):
        from ci_support import Commands
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            summary = root / "summary.md"
            with (patch("ci_support.ROOT", root),
                  patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}),
                  patch("sys.stderr", new=io.StringIO())):
                checks = Commands("stage-error")
                STAGES.record_stage_error(checks, RuntimeError("bundle metadata is invalid"))
                self.assertEqual(checks.finish(), 1)
            report = ET.parse(root / "build/ci/stage-error/commands.xml").getroot()
            self.assertEqual(report.attrib["tests"], "1")
            self.assertEqual(report.attrib["failures"], "1")
            self.assertEqual(report.find("testcase").attrib["name"], "stage-error")
            self.assertEqual((root / "build/ci/stage-error/error.txt").read_text(),
                             "bundle metadata is invalid\n")
            self.assertEqual((root / "build/ci/stage-error/stage-error.log").read_text(),
                             "bundle metadata is invalid\n")

    def test_hosted_visual_shards_run_each_existing_filter_once(self):
        selected = [name for shard in STAGES.VISUAL_SHARDS.values() for name in shard]
        self.assertEqual(sorted(selected), sorted(STAGES.VISUAL_FILTERS))
        self.assertEqual(len(selected), len(set(selected)))

    def test_shipping_probe_guard_runs_for_shipping_sources_on_pull_requests(self):
        self.assertTrue(PLAN.needs_shipping_probe_guard(["Sources/ChromiumBridge/ChromiumPictureInPicture.mm"]))
        self.assertTrue(PLAN.needs_shipping_probe_guard(["Sources/ArcusisBrowser/BrowserEngine.swift"]))
        self.assertTrue(PLAN.needs_shipping_probe_guard(["Sources/ChromiumBridge/PrivateAPI.inc"]))
        self.assertTrue(PLAN.needs_shipping_probe_guard(["Package.swift"]))
        self.assertFalse(PLAN.needs_shipping_probe_guard(["Sources/ChromiumBridgeVerification/ChromiumBridgeVerification.mm"]))
        self.assertFalse(PLAN.needs_shipping_probe_guard(["Notebook/Engine_Shaar_Layer_Design.md"]))
        workflow = (ROOT / ".github" / "workflows" / "source-checks.yml").read_text()
        self.assertIn("shipping-probe-guard:\n", workflow)
        self.assertIn("bash scripts/bundle-app.sh --with-engine", workflow)
        self.assertIn("CI_SHIPPING_GUARD:", workflow)
        needs = self.results(native="skipped")
        needs["basic-browsing"]["result"] = "skipped"
        needs["shipping-probe-guard"] = {"result": "failure"}
        self.assertIn("shipping-probe-guard: failure",
                      GATE.gate_errors(needs, False, False, shipping_guard=True))

    def test_abi_contract_is_selected_for_engine_and_bridge_changes_including_drafts(self):
        self.assertTrue(PLAN.needs_abi_contract(["ThirdParty/ChromiumEngine/pin.json"]))
        self.assertTrue(PLAN.needs_abi_contract(["Sources/ChromiumBridge/ChromiumShaarBackend.mm"]))
        self.assertTrue(PLAN.needs_abi_contract(["scripts/check-engine-abi-contract.py"]))
        self.assertFalse(PLAN.needs_abi_contract(["Sources/ArcusisBrowser/BrowserWindow.swift"]))
        self.assertTrue(PLAN.needs_abi_contract(None))
        self.assertFalse(PLAN.select_stages(["Sources/ChromiumBridge/ChromiumShaarBackend.mm"],
                                            "pull_request", draft=True)[0])
        self.assertTrue(PLAN.needs_abi_contract(["Sources/ChromiumBridge/ChromiumShaarBackend.mm"]))
        workflow = (ROOT / ".github" / "workflows" / "source-checks.yml").read_text()
        self.assertIn("abi_contract: ${{ steps.plan.outputs.abi_contract }}", workflow)
        self.assertIn("scripts/ci-stage.py abi-contract", workflow)
        setup = (ROOT / ".github" / "actions" / "ci-setup" / "action.yml").read_text()
        self.assertIn("inputs.mode == 'fast'", setup)

    def test_codeql_permissions_are_read_only_by_default_and_scoped_to_analysis(self):
        workflow = (ROOT / ".github" / "workflows" / "ci-codeql.yml").read_text()
        defaults = workflow.split("jobs:", 1)[0]
        analyze = workflow.split("  analyze:\n", 1)[1].split("    runs-on:", 1)[0]

        self.assertIn("permissions:\n  contents: read", defaults)
        self.assertNotIn("security-events: write", defaults)
        self.assertIn("permissions:\n      contents: read\n      security-events: write", analyze)

    def test_website_dependency_lock_uses_only_patched_esbuild(self):
        manifest = json.loads((ROOT / "website" / "package.json").read_text())
        lockfile = (ROOT / "website" / "pnpm-lock.yaml").read_text()

        self.assertEqual(manifest["pnpm"]["overrides"]["esbuild"], "0.28.2")
        self.assertIn("esbuild@0.28.2:", lockfile)
        self.assertNotIn("esbuild@0.27.7", lockfile)

    def test_inspector_job_caches_playwright_browser_for_locked_version(self):
        workflow = (ROOT / ".github" / "workflows" / "source-checks.yml").read_text()
        inspector = workflow.split("  inspector-contracts:\n", 1)[1].split("  website:\n", 1)[0]

        self.assertIn("Cache Playwright Chromium shell", inspector)
        self.assertIn("path: build/PlaywrightBrowsers", inspector)
        self.assertIn(
            "key: playwright-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('Tests/InspectorContractTests/pnpm-lock.yaml') }}",
            inspector)
        playwright_cache = inspector.split("      - name: Cache Playwright Chromium shell", 1)[1].split(
            "\n      - name:", 1)[0]
        self.assertIn("restore-keys: |", playwright_cache)
        self.assertIn("playwright-${{ runner.os }}-${{ runner.arch }}-", playwright_cache)
        self.assertIn("playwright install chromium --with-deps --only-shell", inspector)

    def test_pnpm_store_caches_fall_back_after_lockfile_changes(self):
        workflows = (
            ROOT / ".github/workflows/source-checks.yml",
            ROOT / ".github/workflows/website-checks.yml",
        )
        for path in workflows:
            with self.subTest(workflow=path.name):
                workflow = path.read_text()
                cache = workflow.split("      - name: Cache pnpm store", 1)[1].split(
                    "\n      - name:", 1)[0]
                self.assertIn("restore-keys: |", cache)
                self.assertIn("pnpm-${{ runner.os }}-${{ runner.arch }}-", cache)

    def test_release_gate_requires_both_exact_production_workflows_and_zero_alerts(self):
        revision = "a" * 40
        valid = {"id": 9, "head_sha": revision, "head_branch": "production", "event": "push",
                 "status": "completed", "conclusion": "success"}
        for change in ({"head_sha": "b" * 40}, {"event": "pull_request"}, {"event": "workflow_dispatch"},
                       {"status": "in_progress"}, {"conclusion": "failure"}, {"head_branch": "feature"}):
            self.assertEqual(RELEASE_CI.production_runs({"workflow_runs": [dict(valid, **change)]}, revision), [])
        for alerts in ([], [{"number": 1, "state": "open"}]):
            responses = [{"workflow_runs": [valid]},
                         {"jobs": [{"name": "CI required", "status": "completed", "conclusion": "success"}]},
                         {"workflow_runs": [dict(valid, id=10, event="schedule")]},
                         {"jobs": [{"name": "Swift security required", "status": "completed", "conclusion": "success"}]},
                         alerts]
            with patch.object(RELEASE_CI, "api", side_effect=responses):
                if alerts:
                    with self.assertRaisesRegex(ValueError, "open code-scanning"):
                        RELEASE_CI.require_release_ci("arcusis/shaar", revision)
                else:
                    self.assertEqual(RELEASE_CI.require_release_ci("arcusis/shaar", revision),
                                     {"Source checks": 9, "Swift security": 10})
        with patch.object(RELEASE_CI, "api", side_effect=[{"workflow_runs": [valid]}, {"jobs": []}]):
            with self.assertRaises(ValueError):
                RELEASE_CI.require_release_ci("arcusis/shaar", revision)
        swift_events = RELEASE_CI.SWIFT_SECURITY_EVENTS
        for event in ("schedule", "workflow_dispatch"):
            run = dict(valid, event=event)
            self.assertEqual(RELEASE_CI.production_runs({"workflow_runs": [run]}, revision, swift_events), [run])
        for event in ("push", "pull_request", "merge_group"):
            run = dict(valid, event=event)
            self.assertEqual(RELEASE_CI.production_runs({"workflow_runs": [run]}, revision, swift_events), [])

    def test_release_artifact_downloads_have_connection_and_total_timeouts(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        validate = workflow.split("      - name: Validate appcast, update signature and public download\n", 1)[1]
        validate = validate.split("      - name: Require a newer build than the live feed", 1)[0]
        curl_commands = [line.strip() for line in validate.splitlines() if line.strip().startswith("curl ")]

        self.assertEqual(len(curl_commands), 2)
        for command in curl_commands:
            with self.subTest(command=command):
                self.assertIn("--connect-timeout 10", command)
                self.assertIn("--max-time 120", command)

    def test_code_scanning_issue_sync_opens_reopens_and_closes_by_alert_number(self):
        def alert(number):
            return {"number": number, "html_url": f"https://example.invalid/{number}",
                    "rule": {"id": f"swift/rule-{number}", "description": "Rule", "security_severity_level": "high"},
                    "tool": {"name": "CodeQL"},
                    "most_recent_instance": {"location": {"path": "Sources/A.swift", "start_line": 3}}}

        def issue(number, alert_number, state):
            return {"number": number, "state": state, "title": f"[code-scanning #{alert_number}] Rule"}

        alerts = [alert(1), alert(2), alert(3)]
        issues = [issue(10, 1, "open"), issue(11, 2, "closed"), issue(12, 4, "open"), issue(13, 5, "closed"),
                  {"number": 14, "state": "open", "title": "Unrelated"}]
        to_create, to_reopen, to_close = SCANNING_ISSUES.plan(alerts, issues)
        self.assertEqual([a["number"] for a in to_create], [3])
        self.assertEqual([i["number"] for i in to_reopen], [11])
        self.assertEqual([i["number"] for i in to_close], [12])
        self.assertEqual(SCANNING_ISSUES.issue_title(alert(3)), "[code-scanning #3] Rule")
        body = SCANNING_ISSUES.issue_body(alert(3))
        self.assertIn("`swift/rule-3`", body)
        self.assertIn("`Sources/A.swift:3`", body)
        self.assertIn("high", body)

    def test_code_scanning_issue_sync_bounds_github_api_calls(self):
        with patch.object(SCANNING_ISSUES.subprocess, "check_output", return_value="[]") as check_output:
            self.assertEqual(SCANNING_ISSUES.gh("repos/arcusis/shaar/issues"), [])
        self.assertEqual(check_output.call_args.kwargs["timeout"], SCANNING_ISSUES.GH_API_TIMEOUT_SECONDS)
        self.assertGreater(SCANNING_ISSUES.GH_API_TIMEOUT_SECONDS, 0)

    def test_app_icon_changes_skip_website_jobs_but_logo_changes_keep_them(self):
        self.assertEqual(PLAN.select_stages(["Branding/shaar-logo.svg"], "pull_request"),
                         (False, True, True))
        self.assertEqual(PLAN.select_stages(["Branding/shaar-app-icon.svg"], "pull_request"),
                         (True, False, True))
        self.assertEqual(PLAN.select_stages([".github/workflows/ci-codeql.yml"], "pull_request"),
                         (True, False, True))
        self.assertEqual(PLAN.select_stages([".github/workflows/website-checks.yml"], "pull_request"),
                         (False, True, True))
        self.assertEqual(PLAN.select_stages([".github/workflows/ci-codeql.yml"], "pull_request", draft=True),
                         (False, False, True))
        self.assertEqual(PLAN.select_stages([".github/workflows/website-deploy.yml"], "pull_request", draft=True),
                         (False, True, True))
        deploy = (ROOT / ".github/workflows/website-deploy.yml").read_text()
        self.assertIn("Branding/shaar-logo.svg", deploy)
        self.assertNotIn("Branding/**", deploy)

    def test_known_non_native_diffs_and_unknown_changes_select_required_coverage(self):
        for paths in (["Notebook/Note.md"], ["Notebook/probe.py"], ["README.md", "CONTRIBUTING.md"],
                      ["ThirdParty/Foo/README.md"]):
            self.assertEqual(PLAN.select_stages(paths, "pull_request"), (False, False, True))
        for paths in (["website/src/Page.svelte"], ["website/package.json", "Notebook/Note.md"],
                      [".github/assets/overview.png"], [".github/workflows/website-deploy.yml"]):
            self.assertEqual(PLAN.select_stages(paths, "pull_request"), (False, True, True))
            self.assertEqual(PLAN.select_stages(paths, "merge_group"), (False, True, True))
        for paths in (None, [], ["unclassified-input"]):
            self.assertTrue(PLAN.select_stages(paths, "pull_request")[0])
        self.assertEqual(PLAN.select_stages(["Sources/App.swift"], "pull_request"), (True, False, True))
        self.assertEqual(PLAN.select_stages(["Design/shaar_engine.h"], "pull_request"), (True, False, True))
        self.assertEqual(PLAN.select_stages(["Sources/X.md"], "pull_request"), (True, False, True))
        self.assertEqual(PLAN.select_stages(["Design/Mockup.sketch", "Sources/App.swift"], "pull_request"),
                         (True, False, True))
        self.assertEqual(PLAN.select_stages(["scripts/tool.py"], "pull_request"), (True, False, True))
        for paths in (["scripts/codeql-build.py"], [".github/workflows/ci-codeql.yml"],
                      [".github/actions/ci-setup/action.yml"]):
            self.assertTrue(PLAN.select_stages(paths, "pull_request")[2])
        for event in ("push", "schedule", "workflow_dispatch"):
            self.assertEqual(PLAN.select_stages(["Notebook/Note.md"], event), (True, True, True))
        self.assertTrue(PLAN.select_stages(["scripts/tool.py"], "merge_group")[2])

    def test_only_pull_requests_use_the_fast_lane(self):
        self.assertTrue(PLAN.uses_fast_lane("pull_request"))
        for event in ("merge_group", "push", "schedule", "workflow_dispatch"):
            self.assertFalse(PLAN.uses_fast_lane(event))

    def test_draft_pull_requests_skip_native_stages_and_preserve_website_checks(self):
        for paths in (None, []):
            self.assertEqual(PLAN.select_stages(paths, "pull_request", draft=True), (False, True, True))
        for paths in (["Sources/App.swift"], ["unclassified-input"]):
            self.assertEqual(PLAN.select_stages(paths, "pull_request", draft=True), (False, False, True))
        self.assertEqual(PLAN.select_stages(["website/src/Page.svelte"], "pull_request", draft=True),
                         (False, True, True))
        self.assertEqual(PLAN.select_stages(["Sources/App.swift"], "pull_request"), (True, False, True))
        self.assertEqual(PLAN.select_stages(["Sources/App.swift"], "merge_group", draft=True),
                         (True, False, True))
        needs = self.results(native="skipped")
        needs["basic-browsing"]["result"] = "skipped"
        self.assertEqual(GATE.gate_errors(needs, False, False, browsing=False), [])
        self.assertTrue(GATE.gate_errors(needs, True, False, browsing=True))

    def test_draft_pull_request_event_outputs_reduced_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text(json.dumps({"pull_request": {
                "draft": True, "base": {"sha": "b" * 40},
            }}))
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_EVENT_NAME": "pull_request",
                   "GITHUB_SHA": "c" * 40, "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with patch.dict(os.environ, env), patch.object(PLAN.subprocess, "run") as command:
                command.return_value.returncode = 0
                command.return_value.stdout = b"Sources/App.swift\0"
                PLAN.main()
            self.assertIn("full=false", (root / "output").read_text())
            self.assertIn("Draft pull request: **True**", (root / "summary").read_text())

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

    def test_ci_git_path_inventories_preserve_non_utf8_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (patch.object(PINS, "ROOT", root),
                  patch.object(PINS.subprocess, "check_output", return_value=bytes([255]) + b"-script.sh\0")):
                self.assertEqual(PINS.tracked_shell_files(), ["\udcff-script.sh"])
            from ci_support import swift_source_files
            with patch("ci_support.subprocess.check_output", return_value=b"Sources/\xff.swift\0"):
                self.assertEqual(swift_source_files(root), {"Sources/\udcff.swift"})

    def test_non_utf8_diff_paths_select_full_checks_instead_of_crashing_planning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text(json.dumps({"merge_group": {"base_sha": "b" * 40}}))
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_EVENT_NAME": "merge_group",
                   "GITHUB_SHA": "c" * 40, "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with (patch.dict(os.environ, env), patch.object(PLAN.subprocess, "run") as command):
                command.return_value.returncode = 0
                command.return_value.stdout = b"unclassified-\xff.swift\0"
                PLAN.main()
            self.assertIn("full=true", (root / "output").read_text())

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

    def test_diff_failure_warns_when_falling_back_to_full_ci(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text(json.dumps({"before": "a" * 40}))
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_SHA": "c" * 40, "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with (patch.dict(os.environ, env),
                  patch.object(PLAN.subprocess, "run", return_value=SimpleNamespace(returncode=128)),
                  patch("sys.stderr", new=io.StringIO()) as errors):
                PLAN.main()
            self.assertIn("git diff exited 128", errors.getvalue())
            self.assertIn("selecting the full CI plan", errors.getvalue())
            self.assertIn("full=true", (root / "output").read_text())

    def test_probe_count_normalizes_dispatch_strings_before_typed_workflow_call(self):
        for value in (1, "1", 10, "10"):
            self.assertEqual(PLAN.iteration_count({"inputs": {"probe_iterations": value}}, "workflow_dispatch"), int(value))
        for value in (0, "0", 11, -1, "1.5", True, "invalid"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                PLAN.iteration_count({"inputs": {"probe_iterations": value}}, "workflow_dispatch")
        self.assertEqual(PLAN.iteration_count({}, "schedule"), 3)
        self.assertEqual(PLAN.iteration_count({}, "pull_request"), 1)

    def test_merge_group_concurrency_key_uses_validated_pull_request_number(self):
        event = {"merge_group": {"head_ref": "gh-readonly-queue/production/pr-378-" + "a" * 40}}
        self.assertEqual(PLAN.merge_group_pr_number(event, "merge_group"), "378")
        real_event = {"merge_group": {"head_ref": (
            "refs/heads/gh-readonly-queue/production/pr-448-"
            "09c679deb204edf116007c1db51f88a1bac39a56"
        )}}
        self.assertEqual(PLAN.merge_group_pr_number(real_event, "merge_group"), "448")
        self.assertEqual(PLAN.merge_group_pr_number({}, "pull_request"), "")
        malformed_refs = (
            "gh-readonly-queue/production/pr-378-short",
            "refs/heads/other/pr-378-" + "a" * 40,
            "gh-readonly-queue/production/pr-nope-" + "a" * 40,
        )
        for head_ref in malformed_refs:
            with self.subTest(head_ref=head_ref):
                self.assertEqual(PLAN.merge_group_pr_number(
                    {"merge_group": {"head_ref": head_ref}}, "merge_group"), "")

    def test_merge_group_compares_synthetic_head_to_immutable_base_and_fails_open_to_full_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text(json.dumps({"merge_group": {
                "base_sha": "b" * 40,
                "head_ref": "gh-readonly-queue/production/pr-378-" + "c" * 40,
            }}))
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_EVENT_NAME": "merge_group",
                   "GITHUB_SHA": "c" * 40, "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with patch.dict(os.environ, env), patch.object(PLAN.subprocess, "run") as command:
                command.return_value.returncode = 128
                PLAN.main()
            self.assertEqual(command.call_args.args[0], ["git", "diff", "--name-only", "-z", "b" * 40, "HEAD"])
            self.assertIn("full=true", (root / "output").read_text())
            self.assertIn("base=" + "b" * 40, (root / "output").read_text())
            self.assertIn("queue_pr=378", (root / "output").read_text())

    def test_unparseable_merge_group_ref_disables_only_cancellation_grouping(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text(json.dumps({"merge_group": {
                "base_sha": "b" * 40,
                "head_ref": "refs/heads/gh-readonly-queue/production/pr-448-invalid",
            }}))
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_EVENT_NAME": "merge_group",
                   "GITHUB_SHA": "c" * 40, "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with patch.dict(os.environ, env), patch.object(PLAN.subprocess, "run") as command:
                command.return_value.returncode = 128
                PLAN.main()
            output = (root / "output").read_text()
            self.assertIn("full=true", output)
            self.assertIn("queue_pr=\n", output)
            self.assertEqual(GATE.gate_errors(self.results(), True, False), [])

    def results(self, native="success", nightly="skipped"):
        results = {name: {"result": "success"} for name in ("plan", "fast", "dependency-review")}
        results.update({name: {"result": native} for name in (
            "python-tests", "build", "coverage", "visuals", "localization", "localization-captures", "engine",
            "shipping", "codeql", "inspector-contracts", "basic-browsing",
            "shaar-engine-simulation",
        )})
        results.update({name: {"result": nightly} for name in ("sanitizers", "dead-code")})
        results["codeql"] = {"result": "success"}
        return results

    def test_full_pipeline_rejects_failed_cancelled_skipped_or_missing_stage(self):
        for stage in ("engine", "shaar-engine-simulation", "localization", "localization-captures",
                      "inspector-contracts", "basic-browsing"):
            for result in ("failure", "cancelled", "skipped", None):
                with self.subTest(stage=stage, result=result):
                    needs = self.results()
                    if result is None:
                        del needs[stage]
                    else:
                        needs[stage]["result"] = result
                    self.assertTrue(GATE.gate_errors(needs, True, False, browsing=stage == "basic-browsing"))

    def test_advisory_stage_failure_reports_without_blocking(self):
        needs = self.results()
        needs["engine"]["result"] = "failure"
        self.assertIn("engine: failure", GATE.gate_errors(needs, True, False))
        self.assertEqual(GATE.gate_errors(needs, True, False, advisory={"engine"}), [])
        self.assertEqual(GATE.advisory_stages(" engine, ,visuals "), {"engine", "visuals"})
        self.assertEqual(GATE.advisory_stages(None), set())

    def test_core_stages_can_never_be_advisory(self):
        for stage in ("fast", "dependency-review", "codeql", "build"):
            with self.subTest(stage=stage):
                needs = self.results()
                needs[stage]["result"] = "failure"
                self.assertTrue(GATE.gate_errors(needs, True, False, advisory={stage}))

    def test_ci_gate_rejects_unclassified_workflow_jobs(self):
        needs = self.results()
        needs["new-stage"] = {"result": "failure"}
        self.assertIn("new-stage: not classified by CI required gate",
                      GATE.gate_errors(needs, True, False))

    def test_cancelled_stale_merge_group_fails_gate_but_replacement_can_pass(self):
        stale = self.results()
        stale["engine"]["result"] = "cancelled"
        self.assertIn("engine: cancelled", GATE.gate_errors(stale, True, False))
        replacement = self.results()
        self.assertEqual(GATE.gate_errors(replacement, True, False), [])

    def test_docs_skip_native_but_never_skip_fast_gates(self):
        needs = self.results(native="skipped")
        needs["basic-browsing"]["result"] = "skipped"
        self.assertEqual(GATE.gate_errors(needs, False, False), [])
        for stage in ("fast", "dependency-review", "codeql"):
            with self.subTest(stage=stage):
                changed = {name: dict(result) for name, result in needs.items()}
                changed[stage]["result"] = "skipped"
                self.assertTrue(GATE.gate_errors(changed, False, False))

    def test_nightly_requires_deep_checks(self):
        self.assertTrue(GATE.gate_errors(self.results(), True, True))
        self.assertEqual(GATE.gate_errors(self.results(nightly="success"), True, True), [])

    def test_known_documentation_paths_skip_native_stages(self):
        self.assertTrue(PLAN.documentation_only(["README.md", "Notebook/_INDEX_Main.md",
                                                 "ThirdParty/Foo/README.md"]))
        for paths in ([], ["scripts/tool.py"], [".github/workflows/ci.yml"],
                      ["Notebook/Note.md", "Package.resolved"], ["Design/shaar_engine.h"],
                      ["Sources/X.md"], ["Tests/Fixture.md"], ["ThirdParty/README.md"],
                      ["ThirdParty/Foo/README.txt"]):
            self.assertFalse(PLAN.documentation_only(paths))


class CoverageGateTests(unittest.TestCase):
    def test_coverage_report_reader_identifies_missing_and_malformed_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "base coverage report"):
                COVERAGE.load_report(root / "missing.json", "base")
            malformed = root / "malformed.json"
            malformed.write_text("{")
            with self.assertRaisesRegex(ValueError, "candidate coverage report"):
                COVERAGE.load_report(malformed, "candidate")
            malformed.write_bytes(b"\xff\xfe")
            with self.assertRaisesRegex(ValueError, "Cannot read base coverage report"):
                COVERAGE.load_report(malformed, "base")

    def test_parallel_coverage_reports_require_matching_toolchain_and_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / "build/ci/unit"
            baseline = root / "build/ci/coverage-base"
            candidate.mkdir(parents=True)
            baseline.mkdir(parents=True)
            metadata = {"toolchain": "swift-toolchain", "revision": "a" * 40}
            (candidate / "metadata.json").write_text(json.dumps(metadata))
            (baseline / "metadata.json").write_text(json.dumps(metadata))
            checks = SimpleNamespace(run=lambda *_: 0)
            with patch.object(STAGES, "ROOT", root), patch.dict(os.environ, GITHUB_SHA="a" * 40):
                STAGES.compare_coverage(checks)
                for changed in ({"toolchain": "other"}, {"revision": "b" * 40}):
                    (baseline / "metadata.json").write_text(json.dumps(metadata | changed))
                    with self.assertRaises(ValueError):
                        STAGES.compare_coverage(checks)
                (candidate / "metadata.json").write_bytes(b"\xff\xfe")
                with self.assertRaisesRegex(ValueError, "Cannot read candidate coverage metadata"):
                    STAGES.compare_coverage(checks)

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

    def test_engine_only_browsing_smoke_is_excluded_from_unit_coverage(self):
        report = self.report()
        report["data"][0]["files"] += [
            {"filename": "/checkout/Sources/ShaarVerification/BasicBrowsingProbe.swift",
             "summary": {"lines": {"covered": 0, "count": 168}}},
            {"filename": "/checkout/Sources/ShaarVerification/EngineProbe.swift",
             "summary": {"lines": {"covered": 0, "count": 1093}}},
        ]
        coverage = COVERAGE.module_coverage(report)
        self.assertEqual(coverage["ShaarVerification"], (0, 1093))

    def test_shaar_first_tab_simulation_is_excluded_from_unit_coverage(self):
        report = self.report()
        report["data"][0]["files"] += [
            {"filename": "/checkout/Sources/ShaarVerification/ShaarFirstTabProbe.swift",
             "summary": {"lines": {"covered": 0, "count": 158}}},
            {"filename": "/checkout/Sources/ShaarVerification/EngineProbe.swift",
             "summary": {"lines": {"covered": 967, "count": 17929}}},
        ]
        self.assertEqual(COVERAGE.module_coverage(report)["ShaarVerification"], (967, 17929))

    def test_native_devtools_route_is_excluded_from_unit_coverage(self):
        report = self.report()
        report["data"][0]["files"] += [
            {"filename": "/checkout/Sources/ShaarVerification/DevToolsRouteProbe.swift",
             "summary": {"lines": {"covered": 0, "count": 342}}},
            {"filename": "/checkout/Sources/ShaarVerification/EngineProbe.swift",
             "summary": {"lines": {"covered": 1220, "count": 19834}}},
        ]
        self.assertEqual(COVERAGE.module_coverage(report)["ShaarVerification"], (1220, 19834))

    def test_timing_noise_passes_but_real_drop_fails(self):
        base = {"ArcusisBrowser": (22697, 36330)}
        self.assertEqual(COVERAGE.regressions(base, {"ArcusisBrowser": (22694, 36330)}), [])
        self.assertEqual(len(COVERAGE.regressions(base, {"ArcusisBrowser": (22680, 36330)})), 1)

    def test_missing_malformed_and_duplicate_source_data_fail(self):
        reports = [
            {},
            {"type": "llvm.coverage.json.export", "data": [{"files": []}]},
            {"type": "llvm.coverage.json.export", "data": [{}]},
            {"type": "llvm.coverage.json.export", "data": [{"files": [
                {"filename": "/checkout/Sources/ArcusisBrowser/File.swift"},
            ]}]},
            self.report(core=(11, 10)),
        ]
        duplicated = self.report()
        duplicated["data"][0]["files"].append(duplicated["data"][0]["files"][0])
        reports.append(duplicated)
        for report in reports:
            with self.subTest(report=report), self.assertRaises(ValueError):
                COVERAGE.module_coverage(report)

    def test_engine_only_private_host_probe_is_excluded_from_unit_coverage(self):
        report = self.report()
        report["data"][0]["files"].extend([
            {"filename": "/checkout/Sources/ShaarVerification/PrivateProductHostProbe.swift",
             "summary": {"lines": {"covered": 1, "count": 259}}},
            {"filename": "/checkout/Sources/ShaarVerification/PrivateWindowProbe.swift",
             "summary": {"lines": {"covered": 20, "count": 30}}},
        ])
        self.assertEqual(COVERAGE.module_coverage(report)["ShaarVerification"], (20, 30))

    def test_native_private_page_replacement_uses_engine_coverage(self):
        report = self.report()
        report["data"][0]["files"].extend([
            {"filename": "/checkout/Sources/ArcusisBrowser/PrivateBrowserWindow.swift",
             "summary": {"lines": {"covered": 6, "count": 10}}},
            {"filename": "/checkout/Sources/ArcusisBrowser/PrivatePageSession.swift",
             "summary": {"lines": {"covered": 2, "count": 10}}},
            {"filename": "/checkout/Sources/ArcusisBrowser/BrowserWindow.swift",
             "summary": {"lines": {"covered": 3, "count": 10}}},
        ])
        self.assertEqual(COVERAGE.module_coverage(report)["ArcusisBrowser"], (7, 20))


class SupplyChainTests(unittest.TestCase):
    def test_installer_refuses_symlinked_tool_output_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            target = Path(outside) / "sentinel"
            target.write_bytes(b"keep")
            output = root / "actionlint"
            output.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symlinked tool output"):
                INSTALL.write_binary(output, b"replace", True)
            self.assertEqual(target.read_bytes(), b"keep")

    def test_spdx_inventory_rejects_symlinked_app_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "outside-app"
            app.mkdir()
            (app / "Main").write_bytes(b"external executable")
            link = root / "Shaar.app"
            link.symlink_to(app, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "inventory root is not a regular directory"):
                SBOM.inventory_files(link)

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
            pin = {
                "schemaVersion": 1, "sourceKind": "shaar",
                "releaseTag": "engine-1.2.3-shaar.1",
                "asset": "ShaarEngine-1.2.3-shaar.1.tar.xz", "sha256": "a" * 64,
            }
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

    def test_installer_reuses_only_checksum_verified_archive_cache(self):
        payload = self.archive()
        digest = hashlib.sha256(payload).hexdigest()
        pin = {"url": "https://example.invalid/tool", "sha256": digest}
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            with patch.object(INSTALL.urllib.request, "urlopen", return_value=io.BytesIO(payload)) as fetch:
                self.assertEqual(INSTALL.archive_payload(pin, cache), payload)
                self.assertEqual(INSTALL.archive_payload(pin, cache), payload)
                fetch.assert_called_once()

            (cache / f"{digest}.archive").write_bytes(b"corrupt cached payload")
            with patch.object(INSTALL.urllib.request, "urlopen", return_value=io.BytesIO(payload)) as fetch:
                self.assertEqual(INSTALL.archive_payload(pin, cache), payload)
                fetch.assert_called_once()

            (cache / f"{digest}.archive").unlink()
            with patch.object(INSTALL.urllib.request, "urlopen", return_value=io.BytesIO(b"wrong")):
                with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                    INSTALL.archive_payload(pin, cache)
            self.assertFalse((cache / f"{digest}.archive").exists())

    def test_installer_rejects_dangling_archive_cache_symlink_before_download(self):
        payload = self.archive()
        digest = hashlib.sha256(payload).hexdigest()
        pin = {"url": "https://example.invalid/tool", "sha256": digest}
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            cache = Path(directory)
            external_target = Path(outside) / "downloaded.archive"
            (cache / f"{digest}.archive").symlink_to(external_target)
            with patch.object(INSTALL.urllib.request, "urlopen", return_value=io.BytesIO(payload)) as fetch:
                with self.assertRaisesRegex(ValueError, "Refusing symlinked cached archive"):
                    INSTALL.archive_payload(pin, cache)
                fetch.assert_not_called()
            self.assertFalse(external_target.exists())

    def test_installer_rejects_symlinked_archive_cache_directory(self):
        payload = self.archive()
        digest = hashlib.sha256(payload).hexdigest()
        pin = {"url": "https://example.invalid/tool", "sha256": digest}
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            cache = Path(directory) / "cache"
            external = Path(outside)
            cache.symlink_to(external, target_is_directory=True)
            with patch.object(INSTALL.urllib.request, "urlopen", return_value=io.BytesIO(payload)) as fetch:
                with self.assertRaisesRegex(ValueError, "Archive cache directory is a symlink"):
                    INSTALL.archive_payload(pin, cache)
                fetch.assert_not_called()
            self.assertEqual(list(external.iterdir()), [])

    def test_managed_python_install_retries_only_transient_download_failures(self):
        calls = []
        sleeps = []

        def run(command, **kwargs):
            calls.append(command)
            result = SimpleNamespace(returncode=1, stdout="", stderr="operation timed out")
            if len(calls) == 2:
                result = SimpleNamespace(returncode=0, stdout="installed\n", stderr="")
            return result

        self.assertEqual(PYTHON_INSTALL.install_python("3.13", run, sleeps.append), 0)
        self.assertEqual(calls, [["uv", "python", "install", "3.13"]] * 2)
        self.assertEqual(sleeps, [5])

        permanent = SimpleNamespace(returncode=2, stdout="", stderr="checksum mismatch")
        self.assertEqual(
            PYTHON_INSTALL.install_python("3.13", lambda *args, **kwargs: permanent, sleeps.append), 2
        )
        self.assertEqual(sleeps, [5])

    def test_managed_python_install_retries_subprocess_timeouts(self):
        calls = []
        sleeps = []

        def run(command, **kwargs):
            calls.append(kwargs["timeout"])
            if len(calls) == 1:
                raise PYTHON_INSTALL.subprocess.TimeoutExpired(command, kwargs["timeout"], output=b"partial")
            return SimpleNamespace(returncode=0, stdout="installed\n", stderr="")

        self.assertEqual(PYTHON_INSTALL.install_python("3.13", run, sleeps.append), 0)
        self.assertEqual(calls, [PYTHON_INSTALL.INSTALL_TIMEOUT_SECONDS] * 2)
        self.assertEqual(sleeps, [5])

    def test_managed_python_install_retries_are_bounded(self):
        calls = []
        sleeps = []
        failure = SimpleNamespace(returncode=1, stdout="", stderr="operation timed out")

        def run(command, **kwargs):
            calls.append(command)
            return failure

        self.assertEqual(PYTHON_INSTALL.install_python("3.13", run, sleeps.append), 1)
        self.assertEqual(len(calls), PYTHON_INSTALL.INSTALL_ATTEMPTS)
        self.assertEqual(sleeps, [5, 15])

    def test_ci_setup_pins_and_caches_managed_python_and_tool_archives(self):
        setup = (ROOT / ".github/actions/ci-setup/action.yml").read_text()
        self.assertIn("version: '0.13.8'", setup)
        self.assertIn("python-version: '3.13'", setup)
        self.assertIn("cache-python: true", setup)
        self.assertIn("python3 scripts/install-ci-python.py 3.13", setup)
        self.assertIn("ci-tool-archives-v1-${{ runner.os }}-${{ runner.arch }}", setup)
        self.assertIn("scripts/install-ci-tools.py --cache-directory build/ci-tool-archives", setup)

    def test_engine_download_has_connection_and_retry_timeouts(self):
        fetch = (ROOT / "scripts/fetch-engine.sh").read_text()
        curl = next(line for line in fetch.splitlines() if line.strip().startswith("curl "))
        self.assertIn("--connect-timeout 30", curl)
        self.assertIn("--max-time 900", curl)
        self.assertIn("--retry 3", curl)
        self.assertIn("--retry-max-time 180", curl)

    def test_test_engine_framework_fetch_has_a_step_timeout(self):
        workflow = (ROOT / ".github/workflows/source-checks.yml").read_text()
        fetch = workflow.split("      - name: Fetch SHA-256 pinned Shaar test framework\n", 1)[1]
        fetch = fetch.split("      - name: Build the headless Shaar verification bundle", 1)[0]

        self.assertIn("timeout-minutes: 10", fetch)

    def test_swiftpm_cache_key_tracks_build_plugin_sources(self):
        setup = (ROOT / ".github/actions/ci-setup/action.yml").read_text()
        self.assertIn("hashFiles('Package.swift', 'Package.resolved', 'Sources/**', 'Tests/**', 'Plugins/**')", setup)
    def test_swiftpm_dependency_cache_reuses_same_toolchain_sources_after_lock_changes(self):
        setup = (ROOT / ".github/actions/ci-setup/action.yml").read_text()
        cache = setup.split("    - name: Cache SwiftPM dependencies without compiled app objects\n", 1)[1]
        cache = cache.split("    - name:", 1)[0]
        self.assertIn("restore-keys: |", cache)
        self.assertIn(
            "swift-dependencies-${{ runner.os }}-${{ runner.arch }}-${{ steps.toolchain.outputs.identity }}-",
            cache,
        )

    def test_installer_retries_transient_download_failures_only(self):
        def http_error(code):
            return INSTALL.urllib.error.HTTPError("https://example.invalid/tool", code, "error", {}, None)

        sleeps = []
        responses = [http_error(504), http_error(502), io.BytesIO(b"payload")]
        with patch.object(INSTALL.urllib.request, "urlopen", side_effect=responses):
            self.assertEqual(INSTALL.download("https://example.invalid/tool", sleeps.append), b"payload")
        self.assertEqual(sleeps, [2, 4])
        with patch.object(INSTALL.urllib.request, "urlopen", side_effect=[http_error(408), io.BytesIO(b"payload")]):
            self.assertEqual(INSTALL.download("https://example.invalid/tool", sleeps.append), b"payload")
        self.assertEqual(sleeps[-1], 2)
        with patch.object(INSTALL.urllib.request, "urlopen", side_effect=[http_error(404)]):
            with self.assertRaises(INSTALL.urllib.error.HTTPError):
                INSTALL.download("https://example.invalid/tool", sleeps.append)
        failures = [http_error(503)] * INSTALL.DOWNLOAD_ATTEMPTS
        with patch.object(INSTALL.urllib.request, "urlopen", side_effect=failures):
            with self.assertRaises(INSTALL.urllib.error.HTTPError):
                INSTALL.download("https://example.invalid/tool", lambda seconds: None)

    def test_installer_retries_short_archive_responses(self):
        class Response(io.BytesIO):
            def __init__(self, payload, expected_length):
                super().__init__(payload)
                self.headers = {"Content-Length": str(expected_length)}

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

        class TruncatedResponse(Response):
            def read(self, *_):
                raise INSTALL.http.client.IncompleteRead(b"short", 12)

        class ResetResponse(Response):
            def read(self, *_):
                raise ConnectionResetError("connection reset while reading archive")

        sleeps = []
        responses = [Response(b"short", 12), Response(b"complete", 8)]
        with patch.object(INSTALL.urllib.request, "urlopen", side_effect=responses):
            self.assertEqual(INSTALL.download("https://example.invalid/tool", sleeps.append), b"complete")
        self.assertEqual(sleeps, [2])
        responses = [TruncatedResponse(b"", 0), Response(b"complete", 8)]
        with patch.object(INSTALL.urllib.request, "urlopen", side_effect=responses):
            self.assertEqual(INSTALL.download("https://example.invalid/tool", sleeps.append), b"complete")
        self.assertEqual(sleeps, [2, 2])
        responses = [ResetResponse(b"", 0), Response(b"complete", 8)]
        with patch.object(INSTALL.urllib.request, "urlopen", side_effect=responses):
            self.assertEqual(INSTALL.download("https://example.invalid/tool", sleeps.append), b"complete")
        self.assertEqual(sleeps, [2, 2, 2])
        oversized = Response(b"", INSTALL.MAX_ARCHIVE_BYTES + 1)
        with patch.object(INSTALL.urllib.request, "urlopen", return_value=oversized):
            with self.assertRaisesRegex(ValueError, "maximum size"):
                INSTALL.download("https://example.invalid/tool", sleeps.append)

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

    def test_installer_rejects_symlink_members_in_zip_archives(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            member = zipfile.ZipInfo("nested/tool")
            member.external_attr = 0o120777 << 16
            archive.writestr(member, "../../outside")
        payload = output.getvalue()
        with self.assertRaisesRegex(ValueError, "Invalid binary member"):
            INSTALL.binary_from_archive(payload, "tool", hashlib.sha256(payload).hexdigest())

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

    def test_evidence_rejects_non_utf8_probe_markers_without_aborting_collection(self):
        with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as directory, tempfile.TemporaryDirectory() as output:
            root = Path(directory)
            (root / ".arcusis-probe").write_bytes(b"\xff\xfe")
            log = Path(output) / "probe.log"
            log.write_text(f"Probe evidence: {root}\n")
            with self.assertRaisesRegex(ValueError, "Refusing foreign probe evidence"):
                EVIDENCE.collect(log, Path(output) / "evidence")

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

    def test_evidence_rejects_symlinked_output_directory(self):
        with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as directory, \
                tempfile.TemporaryDirectory() as output, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
            (root / "initial.json").write_text("{}")
            log = Path(output) / "probe.log"
            log.write_text(f"Probe evidence: {root}\n")
            destination = Path(output) / "evidence"
            external = Path(outside)
            sentinel = external / "keep.txt"
            sentinel.write_text("leave untouched")
            destination.symlink_to(external, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "evidence destination"):
                EVIDENCE.collect(log, destination)
            self.assertEqual(list(external.iterdir()), [sentinel])

    def test_evidence_rejects_symlinked_output_file_without_overwriting_target(self):
        with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as directory, \
                tempfile.TemporaryDirectory() as output, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
            (root / "initial.json").write_text("new report")
            log = Path(output) / "probe.log"
            log.write_text(f"Probe evidence: {root}\n")
            evidence_dir = Path(output) / "evidence" / root.name
            evidence_dir.mkdir(parents=True)
            sentinel = Path(outside) / "keep.txt"
            sentinel.write_text("preserve")
            (evidence_dir / "initial.json").symlink_to(sentinel)
            with self.assertRaisesRegex(ValueError, "evidence output file is a symlink"):
                EVIDENCE.collect(log, Path(output) / "evidence")
            self.assertEqual(sentinel.read_text(), "preserve")

    def test_evidence_rejects_malformed_utf8_probe_marker(self):
        with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as directory, \
                tempfile.TemporaryDirectory() as output:
            root = Path(directory)
            (root / ".arcusis-probe").write_bytes(b"\xff\xfe")
            log = Path(output) / "probe.log"
            log.write_text(f"Probe evidence: {root}\n")
            with self.assertRaisesRegex(ValueError, "Refusing foreign probe evidence"):
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

    def test_empty_native_swift_testing_report_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "tests.log"
            log.write_text(self.transcript() + "Test run with 1 test passed\n")
            (directory / "swift-swift-testing.xml").write_text('<testsuite tests="0"/>')
            with self.assertRaisesRegex(ValueError, "contains no test cases"):
                SWIFT_REPORTS.write_reports(log, directory)


class ProbeSoakTests(unittest.TestCase):
    def test_shards_cover_every_original_iteration_once_without_retry(self):
        from collections import Counter
        from ci_engine import (
            ENGINE_PROBE_WEIGHTS_SECONDS, _engine_shard_assignments, engine_shards, shard_modes,
        )
        self.assertEqual(engine_shards(1), ["engine-1", "engine-2", "engine-3", "engine-4"])
        for iterations in (1, 2, 3, 10):
            expected = Counter((mode, index) for mode in STAGES.ENGINE_MODES
                               for index in range(1, max(iterations, STAGES.MINIMUM_REPETITIONS.get(mode, 1)) + 1))
            actual = Counter((mode, index) for shard in engine_shards(iterations)
                             for mode, indexes in shard_modes(shard, iterations) for index in indexes)
            self.assertEqual(actual, expected)
            self.assertEqual(len(engine_shards(iterations)), 4)
        with self.assertRaises(ValueError):
            shard_modes("engine-5", 1)

        for shard in engine_shards(1):
            modes = [mode for mode, _ in shard_modes(shard, 1)]
            if "dev-mode" in modes:
                self.assertEqual(modes[0], "dev-mode")

        assignments = _engine_shard_assignments(1)
        estimated_loads = {
            shard: sum(ENGINE_PROBE_WEIGHTS_SECONDS[mode] for mode, _ in probes)
            for shard, probes in assignments.items()
        }
        self.assertLessEqual(max(estimated_loads.values()) - min(estimated_loads.values()), 60)

    def test_all_modes_share_one_build_and_preserve_each_iteration(self):
        checks = unittest.mock.Mock()
        checks.run.return_value = 0
        with tempfile.TemporaryDirectory() as directory, patch.object(STAGES, "ROOT", Path(directory)), patch.object(STAGES, "require_hosted_mac"):
            STAGES.run_engine(checks, "all", 2)
        names = [call.args[0] for call in checks.run.call_args_list]
        self.assertEqual(names, ["verification-build", "baseline-1", "baseline-2",
                                 "dev-mode-1", "dev-mode-2",
                                 "private-multitab-1", "private-multitab-2",
                                 "private-window-1", "private-window-2", "private-window-3",
                                 "quit-exit-1", "quit-exit-2", "quit-exit-3",
                                 "session-recovery-1", "session-recovery-2"])

    def test_cached_engine_bundle_counts_as_a_successful_stage_check(self):
        checks = unittest.mock.Mock()
        checks.results = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checks.directory = root / "cached-bundle"
            checks.directory.mkdir()
            (checks.directory / "bundle.json").write_text("{}")
            with (patch.object(STAGES, "ROOT", root),
                  patch.object(STAGES, "require_hosted_mac"),
                  patch.object(STAGES, "validate_bundle_archive"),
                  patch.dict(os.environ, {"GITHUB_OUTPUT": str(root / "output")})):
                STAGES.build_engine_bundle(checks, 1)
        self.assertEqual(checks.results, [
            dict(name="verification-bundle-cache-validation",
                 command=["validate cached source tree, build inputs and archive digest"],
                 status=0, seconds=0.0),
            dict(name="cached-verification-bundle", command=[], status=0, seconds=0.0),
        ])

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

    def test_swift_crash_report_collection_skips_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            reports = home / "Library/Logs/DiagnosticReports"
            reports.mkdir(parents=True)
            unrelated = root / "private.txt"
            unrelated.write_text("not a crash report")
            (reports / "ArcusisBrowserPackageTests-a.ips").symlink_to(unrelated)
            (reports / "swiftpm-testing-helper-b.ips").write_text("authored crash report")
            destination = root / "evidence"
            destination.mkdir()
            with patch.object(STAGES.Path, "home", return_value=home):
                STAGES.copy_swift_test_crash_reports(destination, started=0)
            copied = sorted(destination.iterdir())
            self.assertEqual([path.name for path in copied], ["swift-test-crash-1.ips"])
            self.assertEqual(copied[0].read_text(), "authored crash report")

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

    def test_command_stage_rejects_symlinked_output_directory(self):
        from ci_support import Commands
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            external = root / "external"
            external.mkdir()
            (root / "build/ci").mkdir(parents=True)
            (root / "build/ci/unsafe").symlink_to(external, target_is_directory=True)
            with patch("ci_support.ROOT", root):
                with self.assertRaisesRegex(ValueError, "must not be a symlink"):
                    Commands("unsafe")
            self.assertEqual(list(external.iterdir()), [])

    def test_command_stage_must_be_a_single_directory_name(self):
        from ci_support import Commands
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch("ci_support.ROOT", root):
                for stage in ("../outside", "nested/stage", ""):
                    with self.subTest(stage=stage), self.assertRaisesRegex(
                        ValueError, "single directory name"
                    ):
                        Commands(stage)
            self.assertFalse((root / "outside").exists())

    def test_command_logs_replace_invalid_utf8_and_malformed_reports_do_not_mask_failure(self):
        from ci_support import Commands
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = root / "summary.md"
            with (
                patch("ci_support.ROOT", root),
                patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}),
            ):
                checks = Commands("sanitize")
                status = checks.run(
                    "malformed-output",
                    [sys.executable, "-c", "import os; os.write(1, bytes([226])); raise SystemExit(7)"],
                )
                self.assertEqual(status, 7)
                self.assertIn("\ufffd", (checks.directory / "malformed-output.log").read_text())
                (checks.directory / "swift-swift-testing.xml").write_text('<?xml version="1.0"?>\n')

                self.assertEqual(checks.finish(), 1)
                suite = ET.parse(checks.directory / "commands.xml").getroot()
                self.assertEqual(suite.attrib["failures"], "2")
                self.assertIn("Could not parse swift-swift-testing.xml", summary.read_text())

    def test_command_summary_rejects_non_numeric_junit_counts_without_crashing(self):
        from ci_support import Commands
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = root / "summary.md"
            with (
                patch("ci_support.ROOT", root),
                patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}),
            ):
                checks = Commands("report")
                (checks.directory / "swift.xml").write_text('<testsuite tests="unknown"/>')

                self.assertEqual(checks.finish(), 1)
                suite = ET.parse(checks.directory / "commands.xml").getroot()
                self.assertEqual(suite.attrib["failures"], "1")
                self.assertIn("Could not validate swift.xml: invalid tests count", summary.read_text())

    def test_junit_non_numeric_counts_are_reported_without_raising(self):
        from ci_support import Commands
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = root / "summary.md"
            with patch("ci_support.ROOT", root), patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
                checks = Commands("invalid-counts")
                (checks.directory / "swift.xml").write_text('<testsuite tests="many" failures="0"/>')
                self.assertEqual(checks.finish(), 1)
                self.assertIn("Could not validate swift.xml: invalid tests count 'many'", summary.read_text())

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

    def test_python_module_import_error_is_reported_without_skipping_other_modules(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "Tests"
            fixture = tests / "Fixture"
            fixture.mkdir(parents=True)
            (fixture / "test_broken.py").write_text("raise RuntimeError('fixture import failed')\n")
            (fixture / "test_valid.py").write_text(
                "import unittest\n"
                "class ValidTest(unittest.TestCase):\n"
                "    def test_runs(self):\n"
                "        self.assertTrue(True)\n"
            )
            report = root / "python.xml"
            text_runner = unittest.TextTestRunner

            def quiet_runner(**kwargs):
                return text_runner(stream=io.StringIO(), **kwargs)

            with (
                patch.object(PYTHON_TESTS, "TESTS_ROOT", tests),
                patch.object(PYTHON_TESTS.unittest, "TextTestRunner", side_effect=quiet_runner),
                patch.object(sys, "argv", ["test-python.py", "--junit", str(report)]),
            ):
                self.assertEqual(PYTHON_TESTS.main(), 1)

            suite = ET.parse(report).getroot()
            self.assertEqual(suite.get("tests"), "2")
            self.assertEqual(suite.get("errors"), "1")
            cases = {case.get("name"): case for case in suite.findall("testcase")}
            self.assertIn("Could not import test module", cases["test_broken.py"].find("error").text)
            self.assertIsNone(cases["test_valid.ValidTest.test_runs"].find("error"))


class EngineTransferTests(unittest.TestCase):
    def test_transferred_bundle_rejects_symlinked_or_missing_build_directory(self):
        from ci_engine import BUNDLE_NAME, archive_bundle, restore_bundle
        import shutil
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            "CI_SOURCE_TREE": "a" * 40, "CI_BUNDLE_INPUTS": "b" * 64, "CI_TOOLCHAIN_ID": "toolchain",
        }):
            root = Path(temporary)
            pin = root / "ThirdParty/ChromiumEngine/pin.json"
            pin.parent.mkdir(parents=True)
            pin.write_text(json.dumps({"sha256": "b" * 64}))
            bundle = root / "build" / BUNDLE_NAME
            bundle.mkdir(parents=True)
            (bundle / "Main").write_text("authored executable")
            evidence = root / "evidence"
            evidence.mkdir()
            archive_bundle(root, evidence)
            shutil.rmtree(root / "build")
            outside = root / "outside"
            outside.mkdir()
            (root / "build").symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "destination is not a directory"):
                restore_bundle(root, evidence)
            self.assertEqual(list(outside.iterdir()), [])
            (root / "build").unlink()
            with self.assertRaisesRegex(ValueError, "destination is not a directory"):
                restore_bundle(root, evidence)

    def test_merge_group_bundle_selection_rejects_fork_pull_request_runs(self):
        from ci_engine import matching_pr_bundle_run_id
        response = {"workflow_runs": [
            {"id": 10, "run_number": 10, "conclusion": "success",
             "head_repository": {"full_name": "contributor/shaar"},
             "pull_requests": [{"number": 448}]},
            {"id": 11, "run_number": 11, "conclusion": "success",
             "head_repository": {"full_name": "arcusis/shaar"},
             "pull_requests": [{"number": 448}]},
            {"id": 12, "run_number": 12, "conclusion": "success",
             "head_repository": None, "pull_requests": [{"number": 448}]},
        ]}
        self.assertEqual(matching_pr_bundle_run_id(response, 448, "arcusis/shaar"), "11")
        self.assertEqual(matching_pr_bundle_run_id(response, 448, "other/shaar"), "")

    def test_merge_group_bundle_lookup_is_bounded_and_fail_open(self):
        workflow = (ROOT / ".github/workflows/ci-engine-bundle.yml").read_text()
        lookup = workflow.split("      - name: Find the matching successful PR bundle for this merge group\n", 1)[1]
        lookup = lookup.split("      - name: Download the verified bundle artifact", 1)[0]
        self.assertIn("continue-on-error: true", lookup)
        self.assertIn("timeout-minutes: 2", lookup)
    def test_bundle_metadata_errors_identify_missing_invalid_and_wrong_shape_inputs(self):
        from ci_engine import validate_bundle_archive
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence"
            evidence.mkdir()
            with self.assertRaisesRegex(ValueError, "metadata is missing or invalid"):
                validate_bundle_archive(root, evidence)
            metadata = evidence / "bundle.json"
            metadata.write_text("not json")
            with self.assertRaisesRegex(ValueError, "metadata is missing or invalid"):
                validate_bundle_archive(root, evidence)
            metadata.write_text("[]")
            with self.assertRaisesRegex(ValueError, "must be a JSON object"):
                validate_bundle_archive(root, evidence)

    def test_merge_group_bundle_download_is_bounded_and_fail_open(self):
        workflow = (ROOT / ".github/workflows/ci-engine-bundle.yml").read_text()
        download = workflow.split("      - name: Download the verified bundle artifact", 1)[1]
        download = download.split("      - name: Build or reuse bundle", 1)[0]
        self.assertIn("continue-on-error: true", download)
        self.assertIn("timeout-minutes: 5", download)

    def test_transferred_bundle_preserves_exec_and_links_and_rejects_wrong_context_or_digest(self):
        from ci_engine import BUNDLE_NAME, archive_bundle, restore_bundle
        import shutil
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            "CI_SOURCE_TREE": "a" * 40, "CI_BUNDLE_INPUTS": "b" * 64, "CI_TOOLCHAIN_ID": "toolchain",
        }):
            root = Path(temporary)
            pin = root / "ThirdParty/ChromiumEngine/pin.json"
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
            with patch.dict(os.environ, {"CI_SOURCE_TREE": "c" * 40}), self.assertRaises(ValueError):
                restore_bundle(root, directory)
            with patch.dict(os.environ, {"CI_BUNDLE_INPUTS": "c" * 64}), self.assertRaises(ValueError):
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

    def test_bundle_restore_rejects_dangling_destination_symlinks(self):
        from ci_engine import BUNDLE_NAME, archive_bundle, restore_bundle
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            "CI_SOURCE_TREE": "a" * 40, "CI_BUNDLE_INPUTS": "b" * 64, "CI_TOOLCHAIN_ID": "toolchain",
        }):
            root = Path(temporary)
            pin = root / "ThirdParty/ChromiumEngine/pin.json"
            pin.parent.mkdir(parents=True)
            pin.write_text(json.dumps({"sha256": "b" * 64}))
            bundle = root / "build" / BUNDLE_NAME
            bundle.mkdir(parents=True)
            (bundle / "Main").write_bytes(b"authored executable")
            evidence = root / "evidence"
            evidence.mkdir()
            archive_bundle(root, evidence)
            import shutil
            shutil.rmtree(bundle)
            bundle.symlink_to(root / "missing-target")

            with self.assertRaisesRegex(ValueError, "destination already exists"):
                restore_bundle(root, evidence)

    def test_normal_browsing_restores_the_shared_exact_source_bundle(self):
        from ci_engine import BUNDLE_NAME, archive_bundle
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            "CI_SOURCE_TREE": "a" * 40, "CI_BUNDLE_INPUTS": "b" * 64, "CI_TOOLCHAIN_ID": "toolchain",
        }):
            root = Path(temporary)
            pin = root / "ThirdParty/ChromiumEngine/pin.json"
            pin.parent.mkdir(parents=True)
            pin.write_text(json.dumps({"sha256": "b" * 64}))
            (root / "build" / BUNDLE_NAME).mkdir(parents=True)
            evidence = root / "build/ci/engine-build"
            evidence.mkdir(parents=True)
            archive_bundle(root, evidence)
            import shutil
            shutil.rmtree(root / "build" / BUNDLE_NAME)
            checks = SimpleNamespace(run=unittest.mock.Mock(return_value=0))
            with patch.object(STAGES, "ROOT", root), patch.object(STAGES, "require_hosted_mac"):
                STAGES.run_basic_browsing(checks)
            self.assertEqual([call.args[0] for call in checks.run.call_args_list], ["normal-window-browsing"])
            self.assertTrue((root / "build" / BUNDLE_NAME).is_dir())

    def test_localization_engine_requires_restored_bundle_without_rebuilding_it(self):
        checks = SimpleNamespace(run=unittest.mock.Mock(return_value=0))
        with patch.object(STAGES, "require_hosted_mac"), patch.object(
            STAGES, "restore_shared_verification_bundle", return_value=True
        ):
            STAGES.run_localization_engine(checks)
        localization_engine = checks.run.call_args_list[-1].args
        self.assertEqual(localization_engine[0], "localization-engine")
        self.assertEqual(localization_engine[1][-1], "--skip-build")
        with patch.object(STAGES, "require_hosted_mac"), patch.object(
            STAGES, "restore_shared_verification_bundle", return_value=False
        ), self.assertRaises(RuntimeError):
            STAGES.run_localization_engine(checks)

    def test_cached_engine_bundle_counts_as_a_successful_stage_with_shards(self):
        from ci_engine import BUNDLE_NAME, archive_bundle, engine_shards
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pin = root / "ThirdParty/ChromiumEngine/pin.json"
            pin.parent.mkdir(parents=True)
            pin.write_text(json.dumps({"sha256": "b" * 64}))
            (root / "build" / BUNDLE_NAME).mkdir(parents=True)
            evidence = root / "build/ci/engine-build"
            evidence.mkdir(parents=True)
            output = root / "outputs"
            with (patch.object(STAGES, "ROOT", root), patch.object(STAGES, "require_hosted_mac"),
                  patch.dict(os.environ, {"CI_SOURCE_TREE": "a" * 40, "CI_BUNDLE_INPUTS": "a" * 64, "CI_TOOLCHAIN_ID": "toolchain",
                                          "GITHUB_OUTPUT": str(output)})):
                archive_bundle(root, evidence)
                checks = SimpleNamespace(directory=evidence, results=[], write_reports=lambda: None)
                STAGES.build_engine_bundle(checks, 2)
                self.assertEqual(STAGES.Commands.finish(checks), 0)
            self.assertEqual(
                [item["name"] for item in checks.results],
                ["verification-bundle-cache-validation", "cached-verification-bundle"])
            self.assertIn(f"shards={json.dumps(engine_shards(2))}", output.read_text())


class SwiftExtractionTests(unittest.TestCase):
    def test_cli_reports_malformed_json_without_name_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / "extraction.json"
            report.write_text("{")
            error_output = io.StringIO()
            with (patch.object(EXTRACTION, "ROOT", root),
                  patch.object(EXTRACTION, "swift_source_files", return_value={"Sources/App.swift"}),
                  patch.object(sys, "argv", ["check-codeql-extraction.py", str(report)]),
                  patch.object(sys, "stderr", error_output)):
                status = EXTRACTION.main()
            self.assertEqual(status, 2)
            self.assertIn("Invalid CodeQL extraction report", error_output.getvalue())

    def test_malformed_extraction_tuple_fails_with_a_value_error(self):
        report = {"#select": {"tuples": [[]]}}
        with self.assertRaisesRegex(ValueError, "tuple 0 is malformed"):
            EXTRACTION.extracted_paths(report, Path("/checkout"))

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
    def test_traced_modules_share_the_four_cpu_codeql_runner_budget(self):
        command = ["swiftc", "-num-threads", "2", "-module-name", "ArcusisBrowser"]
        self.assertEqual(CODEQL_BUILD.compiler_threads(command, 1)[2], "4")
        self.assertEqual(CODEQL_BUILD.compiler_threads(command, 2)[2], "2")
        with self.assertRaisesRegex(ValueError, "CPU budget"):
            CODEQL_BUILD.compiler_threads(command, 5)

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
        from swift_build_plan import ordered_modules, parallel_module_batches, prepare_inputs
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

    def test_parallel_native_batches_only_start_modules_after_dependencies(self):
        from swift_build_plan import parallel_module_batches
        def module(name, output, inputs=()):
            return ["swiftc", "-module-name", name, "-emit-module-path", output]
        core = module("Core", "Core.swiftmodule")
        app = module("App", "App.swiftmodule")
        support = module("Support", "Support.swiftmodule")
        nodes = [{"args": core, "inputs": []},
                 {"args": app, "inputs": ["Core.swiftmodule"]},
                 {"args": support, "inputs": []}]
        batches = parallel_module_batches(nodes, [app, support, core], max_parallel=2)
        self.assertEqual([[item[item.index("-module-name") + 1] for item in batch]
                          for batch in batches], [["Core", "Support"], ["App"]])
        self.assertEqual({item[item.index("-module-name") + 1]
                          for batch in batches for item in batch}, {"Core", "App", "Support"})
        with self.assertRaisesRegex(ValueError, "positive"):
            parallel_module_batches(nodes, [core, app, support], max_parallel=0)

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

    def test_support_module_is_retained_but_test_targets_are_outside_default_build_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(CODEQL_BUILD.command_sources([
                "Tests/TestSupport/SeededGenerator.swift", "Tests/BrowserCoreTests/Cases.swift",
            ], root), {"Tests/TestSupport/SeededGenerator.swift"})

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
