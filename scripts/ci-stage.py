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
from pathlib import Path

from ci_support import Commands, ROOT
from ci_engine import BUNDLE_NAME, archive_bundle, engine_shards, restore_bundle, shard_modes
from sidebar_dnd_fixture import registered_sidebar_type


VISUAL_FILTERS = (
    "SidebarChromeLayoutTests", "SpaceEditorVisualTests", "ExtensionManagerVisualTests",
    "SpaceIconPickerVisualTests", "SidebarFoldersVisualTests", "CommandPanelVisualTests",
)
ENGINE_MODES = ("baseline", "private-window", "quit-exit", "session-recovery")
MINIMUM_REPETITIONS = {"private-window": 3, "quit-exit": 3}


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
    with registered_sidebar_type():
        status = checks.run(name, arguments, cwd=cwd, env=env)
    reports = checks.run("test-reports", [sys.executable, str(ROOT / "scripts/ci-swift-reports.py"),
                        "--log", str(checks.directory / f"{name}.log"),
                        "--directory", str(checks.directory)])
    return int(bool(status or reports))


def test_commands(checks: Commands, *, cwd: Path = ROOT, scratch: str = ".build") -> int:
    flags = ["--scratch-path", scratch, "--jobs", "2", "--force-resolved-versions", "--enable-code-coverage"]
    if checks.run("build", ["swift", "build", "--build-tests", *flags], cwd=cwd):
        return 1
    coverage_path = prepare_coverage(cwd, scratch)
    status = run_swift_tests(checks, "tests", ["swift", "test", "--skip-build", *flags,
                             "--xunit-output", str(checks.directory / "swift.xml")], cwd=cwd)
    if status:
        return status
    shutil.copyfile(coverage_path, checks.directory / "coverage.json")
    return checks.run("resolved-pins", ["git", "diff", "--exit-code", "--", "Package.resolved"])


def check_base_coverage(checks: Commands) -> None:
    base_sha = os.environ.get("CI_BASE_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", base_sha):
        raise ValueError("Coverage baseline requires an immutable 40-character CI_BASE_SHA")
    candidate_metadata = json.loads((ROOT / "build/ci/unit/metadata.json").read_text())
    if candidate_metadata.get("toolchain") != os.environ["CI_TOOLCHAIN_ID"]:
        raise ValueError("Coverage baseline and candidate toolchains differ")
    base = ROOT / "build/ci/base-source"
    base.mkdir(parents=True, exist_ok=False)
    archive = checks.directory / "base-source.tar"
    with archive.open("wb") as output:
        subprocess.run(["git", "archive", base_sha], cwd=ROOT, stdout=output, check=True)
    with tarfile.open(archive) as source:
        source.extractall(base, filter="data")
    archive.unlink()
    baseline = Commands("coverage-base")
    if test_commands(baseline, cwd=base, scratch=str(ROOT / "build/swiftpm/coverage-base")):
        raise RuntimeError("Baseline coverage build/tests failed")
    baseline.finish()
    checks.run("coverage-no-regression", [sys.executable, "scripts/check-coverage.py",
               "--base", str(baseline.directory / "coverage.json"),
               "--candidate", str(ROOT / "build/ci/unit/coverage.json")])


def run_engine(checks: Commands, mode: str, iterations: int) -> None:
    require_hosted_mac()
    if checks.run("verification-build", ["bash", "scripts/bundle-app.sh", "--with-engine", "--verification"]):
        return
    for selected in ENGINE_MODES if mode == "all" else (mode,):
        repetitions = max(iterations, MINIMUM_REPETITIONS.get(selected, 1))
        run_probe_iterations(checks, selected, range(1, repetitions + 1))


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


def run_visuals(checks: Commands) -> None:
    require_hosted_mac()
    if checks.run("visual-build", ["swift", "build", "--build-tests", "--jobs", "2", "--force-resolved-versions"]):
        return
    environment = dict(os.environ, ARCUSIS_SIDEBAR_VISUAL_CI="1")
    for name in VISUAL_FILTERS:
        checks.run(name, ["swift", "test", "--skip-build", "--jobs", "2", "--filter", name], env=environment)


def run_localization(checks: Commands) -> None:
    require_hosted_mac()
    if checks.run("localization-build", ["swift", "build", "--build-tests", "--jobs", "1", "--force-resolved-versions"]):
        return
    if checks.run("localization-captures", [sys.executable, "scripts/test-localization.py"]):
        return
    checks.run("localization-engine", [sys.executable, "scripts/localization-fixture.py"])


def run_sanitizer(checks: Commands, sanitizer: str) -> None:
    environment = dict(os.environ, ASAN_OPTIONS="halt_on_error=1", TSAN_OPTIONS="halt_on_error=1")
    run_swift_tests(checks, sanitizer, ["swift", "test", "--jobs", "2", "--force-resolved-versions",
                    "--scratch-path", f"build/swiftpm/{sanitizer}", "--sanitize", sanitizer,
                    "--xunit-output", str(checks.directory / "swift.xml")], env=environment)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("unit", "coverage", "engine", "engine-build", "engine-shard", "visual", "localization", "shipping", "sanitize", "dead-code"))
    parser.add_argument("--shard", choices=engine_shards(10), default="baseline-lifecycle")
    parser.add_argument("--mode", choices=("all", *ENGINE_MODES), default="all")
    parser.add_argument("--iterations", type=int, choices=range(1, 11), default=1)
    parser.add_argument("--sanitizer", choices=("address", "thread"), default="address")
    options = parser.parse_args()
    suffix = f"-{options.mode}" if options.stage == "engine" and options.mode != "all" else ""
    if options.stage == "engine-shard":
        suffix = f"-{options.shard}"
    suffix += f"-{options.sanitizer}" if options.stage == "sanitize" else ""
    checks = Commands(options.stage + suffix)
    try:
        if options.stage == "unit":
            if not test_commands(checks):
                checks.run("sidebar-dnd-restart", [sys.executable, "scripts/sidebar-dnd-probe.py",
                           "--skip-build", "--enable-code-coverage"])
        elif options.stage == "coverage":
            check_base_coverage(checks)
        elif options.stage == "engine":
            run_engine(checks, options.mode, options.iterations)
        elif options.stage == "engine-build":
            build_engine_bundle(checks, options.iterations)
        elif options.stage == "engine-shard":
            run_engine_shard(checks, options.shard, options.iterations)
        elif options.stage == "visual":
            run_visuals(checks)
        elif options.stage == "localization":
            run_localization(checks)
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
        (checks.directory / "error.txt").write_text(str(error) + "\n")
        print(error, file=sys.stderr)
        checks.finish()
        return 1
    return checks.finish()


if __name__ == "__main__":
    raise SystemExit(main())
