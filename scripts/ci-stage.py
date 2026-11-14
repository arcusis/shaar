#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run staged CI commands with durable command-level JUnit and log evidence."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from ci_support import Commands, ROOT
from ci_engine import (
    BUNDLE_NAME, archive_bundle, engine_shards, restore_bundle, shard_modes,
    validate_bundle_archive,
)
from sidebar_dnd_fixture import registered_sidebar_type


VISUAL_FILTERS = (
    "SidebarChromeLayoutTests", "SpaceEditorVisualTests", "ExtensionManagerVisualTests",
    "SpaceIconPickerVisualTests", "SidebarFoldersVisualTests", "CommandPanelVisualTests",
    "SettingsVisualTests",
)
VISUAL_SHARDS = {
    "1": ("SidebarChromeLayoutTests", "SpaceEditorVisualTests", "SettingsVisualTests"),
    "2": ("ExtensionManagerVisualTests", "SpaceIconPickerVisualTests", "SidebarFoldersVisualTests",
          "CommandPanelVisualTests"),
}
ENGINE_MODES = ("baseline", "dev-mode", "private-multitab", "private-window", "quit-exit", "session-recovery")
MINIMUM_REPETITIONS = {"private-window": 3, "quit-exit": 3}
SWIFT_TEST_CRASH_PROCESSES = ("swiftpm-testing-helper", "ArcusisBrowserPackageTests")


def require_hosted_mac() -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_OS") != "macOS":
        raise RuntimeError("Native fixtures and visual captures require a hosted macOS CI job")


def prepare_coverage(cwd: Path, scratch: str) -> Path:
    filename = subprocess.check_output(
        ["swift", "test", "--scratch-path", scratch, "--show-codecov-path"], cwd=cwd, text=True).strip()
    path = Path(filename)
    if path.parent.name != "codecov" or not path.resolve().is_relative_to((cwd / scratch).resolve()):
        raise ValueError("Swift coverage path escaped its scratch directory")
    if path.parent.exists():
        shutil.rmtree(path.parent)
    return path


def run_swift_tests(checks: Commands, name: str, arguments: list[str], *, cwd: Path = ROOT, env=None) -> int:
    for report in (*checks.directory.glob("swift*.xml"), checks.directory / "xctest.xml"):
        report.unlink(missing_ok=True)
    started = time.time()
    with registered_sidebar_type():
        status = checks.run(name, arguments, cwd=cwd, env=env)
    if status and "unexpected signal code" in (checks.directory / f"{name}.log").read_text():
        copy_swift_test_crash_reports(checks.directory, started)
    reports = checks.run("test-reports", [sys.executable, str(ROOT / "scripts/ci-swift-reports.py"),
                        "--log", str(checks.directory / f"{name}.log"),
                        "--directory", str(checks.directory)])
    return int(bool(status or reports))


def copy_swift_test_crash_reports(directory: Path, started: float) -> None:
    report_root = Path.home() / "Library/Logs/DiagnosticReports"
    deadline = time.monotonic() + 5
    reports = []
    while time.monotonic() < deadline:
        candidates = [path for folder in (report_root, report_root / "Retired")
                      for process in SWIFT_TEST_CRASH_PROCESSES
                      for path in folder.glob(f"{process}-*.ips")
                      if not path.is_symlink() and path.is_file()]
        for path in sorted(candidates):
            try:
                if path.stat().st_mtime >= started:
                    reports.append(path)
            except OSError:
                continue
        if reports:
            break
        time.sleep(0.25)
    copied = 0
    for index, path in enumerate(reports[:4], start=1):
        try:
            if path.is_symlink() or not path.is_file():
                continue
            shutil.copyfile(path, directory / f"swift-test-crash-{index}.ips")
            copied += 1
        except OSError:
            continue
    print(f"Swift Testing crash reports captured: {copied}", flush=True)


def test_commands(checks: Commands, *, cwd: Path = ROOT, scratch: str = ".build") -> int:
    flags = ["--scratch-path", scratch, "--jobs", "2", "--force-resolved-versions", "--enable-code-coverage"]
    # Keep wall-clock scale assertions independent of other Swift Testing cases.
    test_flags = [*flags, "--no-parallel"]
    if checks.run("build", ["swift", "build", "--build-tests", *flags], cwd=cwd):
        return 1
    coverage_path = prepare_coverage(cwd, scratch)
    # SwiftUI focus in a hidden window needs its own AppKit process; both invocations still count.
    isolated_focus = "BrowserWindowSidebarTests.openingPaneCommandMakesSearchFieldFirstResponderOffscreen"
    status = run_swift_tests(checks, "tests", ["swift", "test", "--skip-build", *test_flags,
                             "--skip", isolated_focus,
                             "--xunit-output", str(checks.directory / "swift.xml")], cwd=cwd)
    if status:
        return status
    preserve_test_reports(checks.directory)
    first_profile = checks.directory / "other-tests.profdata"
    shutil.copyfile(coverage_path.parent / "default.profdata", first_profile)
    status = run_swift_tests(checks, "isolated-focus", ["swift", "test", "--skip-build", *test_flags,
                             "--filter", isolated_focus,
                             "--xunit-output", str(checks.directory / "swift.xml")], cwd=cwd)
    if status:
        return status
    require_isolated_focus_result(checks.directory, isolated_focus)
    merge_test_coverage(coverage_path, first_profile)
    shutil.copyfile(coverage_path, checks.directory / "coverage.json")
    return checks.run("resolved-pins", ["git", "diff", "--exit-code", "--", "Package.resolved"])


def preserve_test_reports(directory: Path) -> None:
    for report in (*directory.glob("swift*-swift-testing.xml"), directory / "xctest.xml"):
        report.rename(directory / f"suite-{report.name}")


def require_isolated_focus_result(directory: Path, name: str) -> None:
    report = ET.parse(directory / "swift-swift-testing.xml")
    cases = list(report.iter("testcase"))
    if len(cases) != 1 or cases[0].get("name") != f"{name.split('.')[-1]}()":
        raise RuntimeError("Isolated offscreen focus test did not run exactly once")


def merge_test_coverage(coverage_path: Path, first_profile: Path) -> None:
    second_profile = coverage_path.parent / "default.profdata"
    merged_profile = coverage_path.parent / "combined.profdata"
    executable = (coverage_path.parent.parent / "ArcusisBrowserPackageTests.xctest" /
                  "Contents" / "MacOS" / "ArcusisBrowserPackageTests")
    subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", str(first_profile),
                    str(second_profile), "-o", str(merged_profile)], check=True)
    with coverage_path.open("w") as output:
        subprocess.run(["xcrun", "llvm-cov", "export", "-instr-profile", str(merged_profile),
                        str(executable)], stdout=output, check=True)


def build_base_coverage(checks: Commands) -> None:
    base_sha = os.environ.get("CI_BASE_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", base_sha):
        raise ValueError("Coverage baseline requires an immutable 40-character CI_BASE_SHA")
    base = ROOT / "build/ci/base-source"
    base.mkdir(parents=True, exist_ok=False)
    archive = checks.directory / "base-source.tar"
    with archive.open("wb") as output:
        subprocess.run(["git", "archive", base_sha], cwd=ROOT, stdout=output, check=True)
    with tarfile.open(archive) as source:
        source.extractall(base, filter="data")
    archive.unlink()
    if test_commands(checks, cwd=base, scratch=str(ROOT / "build/swiftpm/coverage-base")):
        raise RuntimeError("Baseline coverage build/tests failed")


def load_coverage_metadata(path: Path, label: str) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"Cannot read {label} coverage metadata {path}: {error}") from error


def compare_coverage(checks: Commands) -> None:
    candidate = ROOT / "build/ci/unit"
    baseline = ROOT / "build/ci/coverage-base"
    candidate_metadata = load_coverage_metadata(candidate / "metadata.json", "candidate")
    baseline_metadata = load_coverage_metadata(baseline / "metadata.json", "base")
    if (not candidate_metadata.get("toolchain")
            or candidate_metadata["toolchain"] != baseline_metadata.get("toolchain")):
        raise ValueError("Coverage baseline and candidate toolchains differ")
    revision = os.environ.get("GITHUB_SHA")
    if not revision or candidate_metadata.get("revision") != revision or baseline_metadata.get("revision") != revision:
        raise ValueError("Coverage reports came from different CI revisions")
    checks.run("coverage-no-regression", [sys.executable, "scripts/check-coverage.py",
               "--base", str(baseline / "coverage.json"),
               "--candidate", str(candidate / "coverage.json")])


def run_engine(checks: Commands, mode: str, iterations: int) -> None:
    require_hosted_mac()
    if checks.run("verification-build", ["bash", "scripts/bundle-app.sh", "--with-engine", "--verification"]):
        return
    for selected in ENGINE_MODES if mode == "all" else (mode,):
        repetitions = max(iterations, MINIMUM_REPETITIONS.get(selected, 1))
        run_probe_iterations(checks, selected, range(1, repetitions + 1))


def restore_shared_verification_bundle() -> bool:
    directory = ROOT / "build/ci/engine-build"
    if not (directory / "bundle.json").is_file():
        return False
    restore_bundle(ROOT, directory)
    return True


def discard_shared_verification_bundle() -> None:
    directory = ROOT / "build/ci/engine-build"
    for name in ("bundle.json", "verification.tar.gz"):
        (directory / name).unlink(missing_ok=True)
    bundle = ROOT / "build" / BUNDLE_NAME
    if bundle.is_symlink() or bundle.is_file():
        bundle.unlink()
    elif bundle.exists():
        shutil.rmtree(bundle)


def run_basic_browsing(checks: Commands) -> None:
    require_hosted_mac()
    try:
        restored = restore_shared_verification_bundle()
    except (OSError, ValueError, tarfile.TarError, EOFError) as error:
        print(f"Shared verification bundle could not be restored; rebuilding it: {error}")
        discard_shared_verification_bundle()
        restored = False
    if not restored and checks.run(
        "verification-build", ["bash", "scripts/bundle-app.sh", "--with-engine", "--verification"]
    ):
        return
    checks.run("normal-window-browsing", [sys.executable, "scripts/engine_fixture.py", "--basic-browsing"])


def run_probe_iterations(checks: Commands, mode: str, iterations: range) -> None:
    environment = dict(os.environ, SHAAR_PROBE_TIMEOUT_SCALE="3", ARCUSIS_PRIVATE_WINDOW_CI="1")
    for iteration in iterations:
        flags = [] if mode == "baseline" else [f"--{mode}"]
        proof = ROOT / "build/private-window-evidence"
        if mode == "private-window" and proof.exists():
            shutil.rmtree(proof)
        # Every iteration is evaluated. A later pass never erases an earlier failure.
        checks.run(f"{mode}-{iteration}", [sys.executable, "scripts/engine_fixture.py", *flags], env=environment)
        if mode == "private-window" and proof.is_dir():
            shutil.copytree(proof, checks.directory / f"private-window-{iteration}")


def build_engine_bundle(checks: Commands, iterations: int) -> None:
    require_hosted_mac()
    if (checks.directory / "bundle.json").is_file():
        try:
            validate_bundle_archive(ROOT, checks.directory)
        except (OSError, ValueError, tarfile.TarError) as error:
            print(f"Discarding unusable verification bundle cache and rebuilding: {error}")
            (checks.directory / "bundle.json").unlink(missing_ok=True)
            (checks.directory / "verification.tar.gz").unlink(missing_ok=True)
        else:
            checks.results.append({
                "name": "verification-bundle-cache-validation",
                "command": ["validate cached source tree, build inputs and archive digest"],
                "status": 0,
                "seconds": 0.0,
            })
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
                output.write(f"shards={json.dumps(engine_shards(iterations))}\n")
            checks.results.append(dict(name="cached-verification-bundle", command=[],
                                        status=0, seconds=0.0))
            print("Reusing integrity-checked verification bundle for this exact source tree and build inputs")
            return
    if checks.run("verification-build", ["bash", "scripts/bundle-app.sh", "--with-engine", "--verification"]):
        return
    archive_bundle(ROOT, checks.directory)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"shards={json.dumps(engine_shards(iterations))}\n")


def run_engine_shard(checks: Commands, shard: str, iterations: int) -> None:
    require_hosted_mac()
    modes = shard_modes(shard, iterations)
    restore_bundle(ROOT, ROOT / "build/ci/engine-build")
    if checks.run("verification-signature", ["codesign", "--verify", "--deep", "--strict", "--verbose=2",
                                            f"build/{BUNDLE_NAME}"]):
        return
    for mode, repetitions in modes:
        run_probe_iterations(checks, mode, repetitions)


def run_visuals(checks: Commands, shard: str) -> None:
    require_hosted_mac()
    if checks.run("visual-build", ["swift", "build", "--build-tests", "--jobs", "2", "--force-resolved-versions"]):
        return
    environment = dict(os.environ, ARCUSIS_SIDEBAR_VISUAL_CI="1")
    filters = VISUAL_FILTERS if shard == "all" else VISUAL_SHARDS[shard]
    for name in filters:
        checks.run(name, ["swift", "test", "--skip-build", "--jobs", "2", "--filter", name], env=environment)


def run_localization_captures(checks: Commands) -> None:
    require_hosted_mac()
    if checks.run("localization-build", ["swift", "build", "--build-tests", "--jobs", "2", "--force-resolved-versions"]):
        return
    checks.run("localization-captures", [sys.executable, "scripts/test-localization.py"])


def run_localization_engine(checks: Commands) -> None:
    require_hosted_mac()
    if not restore_shared_verification_bundle():
        raise RuntimeError("Localization engine probe requires the shared verification bundle")
    checks.run("localization-engine", [sys.executable, "scripts/localization-fixture.py", "--skip-build"])


def run_sanitizer(checks: Commands, sanitizer: str) -> None:
    environment = dict(os.environ, ASAN_OPTIONS="halt_on_error=1", TSAN_OPTIONS="halt_on_error=1")
    run_swift_tests(checks, sanitizer, ["swift", "test", "--jobs", "2", "--force-resolved-versions",
                    "--scratch-path", f"build/swiftpm/{sanitizer}", "--sanitize", sanitizer,
                    "--xunit-output", str(checks.directory / "swift.xml")], env=environment)


def record_stage_error(checks: Commands, error: Exception) -> None:
    message = str(error)
    (checks.directory / "error.txt").write_text(message + "\n")
    (checks.directory / "stage-error.log").write_text(message + "\n")
    checks.results.append(dict(name="stage-error", command=["report CI stage exception"],
                               status=1, seconds=0.0))
    print(message, file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("unit", "coverage-base", "coverage-compare", "abi-contract", "engine", "engine-build", "engine-shard", "basic-browsing", "visual", "localization", "localization-captures", "shipping", "sanitize", "dead-code"))
    parser.add_argument("--shard", choices=engine_shards(10), default="baseline-1")
    parser.add_argument("--visual-shard", choices=("all", *VISUAL_SHARDS), default="all")
    parser.add_argument("--mode", choices=("all", *ENGINE_MODES), default="all")
    parser.add_argument("--iterations", type=int, choices=range(1, 11), default=1)
    parser.add_argument("--sanitizer", choices=("address", "thread"), default="address")
    options = parser.parse_args()
    suffix = f"-{options.mode}" if options.stage == "engine" and options.mode != "all" else ""
    if options.stage == "engine-shard":
        suffix = f"-{options.shard}"
    if options.stage == "visual" and options.visual_shard != "all":
        suffix = f"-{options.visual_shard}"
    suffix += f"-{options.sanitizer}" if options.stage == "sanitize" else ""
    checks = Commands(options.stage + suffix)
    try:
        if options.stage == "unit":
            if not test_commands(checks):
                checks.run("sidebar-dnd-restart", [sys.executable, "scripts/sidebar-dnd-probe.py",
                           "--skip-build", "--enable-code-coverage"])
        elif options.stage == "abi-contract":
            checks.run("engine-abi-contract", [sys.executable, "scripts/check-engine-abi-contract.py"])
        elif options.stage == "coverage-base":
            build_base_coverage(checks)
        elif options.stage == "coverage-compare":
            compare_coverage(checks)
        elif options.stage == "engine":
            run_engine(checks, options.mode, options.iterations)
        elif options.stage == "engine-build":
            build_engine_bundle(checks, options.iterations)
        elif options.stage == "engine-shard":
            run_engine_shard(checks, options.shard, options.iterations)
        elif options.stage == "basic-browsing":
            run_basic_browsing(checks)
        elif options.stage == "visual":
            run_visuals(checks, options.visual_shard)
        elif options.stage == "localization":
            run_localization_engine(checks)
        elif options.stage == "localization-captures":
            run_localization_captures(checks)
        elif options.stage == "sanitize":
            run_sanitizer(checks, options.sanitizer)
        elif options.stage == "dead-code":
            checks.run("periphery", ["periphery", "scan", "--disable-update-check", "--retain-public",
                                    "--retain-objc-accessible", "--retain-swift-ui-previews",
                                    "--retain-codable-properties", "--format", "json",
                                    "--write-results", str(checks.directory / "periphery.json"),
                                    "--", "--jobs", "2", "--force-resolved-versions"])
        elif options.stage == "shipping":
            if not checks.run("shipping-build", ["bash", "scripts/bundle-app.sh", "--with-engine"]):
                checks.run("signature", ["codesign", "--verify", "--deep", "--strict", "--verbose=2", "build/Shaar.app"])
                checks.run("sbom", [sys.executable, "scripts/ci-sbom.py"])
                checks.run("sbom-validation", [sys.executable, "-m", "spdx_tools.spdx.clitools.pyspdxtools",
                                               "--infile", str(checks.directory / "sbom.spdx.json")])
                if not any(item["status"] for item in checks.results):
                    checks.run("sparkle-update", [sys.executable, "scripts/ci-sparkle.py"])
    except Exception as error:
        record_stage_error(checks, error)
        checks.finish()
        return 1
    return checks.finish()


if __name__ == "__main__":
    raise SystemExit(main())
