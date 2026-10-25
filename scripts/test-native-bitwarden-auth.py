#!/usr/bin/env python3
"""Run pinned Bitwarden auth spike in a fresh, local SDK clone."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

PACKAGE_DIR = Path(__file__).resolve().parents[1] / "ThirdParty" / "BitwardenAuthSpike"
PIN_FILE = PACKAGE_DIR / "pin.json"
PATCH_FILE = PACKAGE_DIR / "identity-mfa.patch"
SOURCE_COMMIT = "5cf919837e83b71c2508bf99344ea57cf5f84e88"
RUST_TOOLCHAIN = "1.90-aarch64-apple-darwin"
TARGET = "aarch64-apple-darwin"
MIN_MACOS = "26.0"
TEST_SUMMARY = re.compile(
    r"(\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; (\d+) filtered out"
)
PREFLIGHT_COMMANDS: list[dict[str, object]] = []


class ProofError(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ProofError("Generated Swift output contains symlink")
        if path.is_file():
            relative = path.relative_to(root).as_posix().encode()
            digest.update(relative + b"\0" + bytes.fromhex(sha256_file(path)) + b"\n")
    return digest.hexdigest()


def run_checked(argv: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    try:
        result = subprocess.run(
            argv, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False,
        )
    except OSError:
        raise ProofError("required preflight tool is unavailable") from None
    PREFLIGHT_COMMANDS.append({
        "argv": argv,
        "cwd": str(cwd) if cwd else None,
        "environment": {
            key: env[key]
            for key in ("RUSTUP_TOOLCHAIN", "MACOSX_DEPLOYMENT_TARGET", "RUSTFLAGS")
            if env and key in env
        },
        "exitCode": result.returncode,
    })
    if result.returncode:
        raise ProofError("preflight command failed")
    return result.stdout.strip()


def tracked_source_is_clean(source: Path) -> bool:
    status = run_checked(
        ["git", "-C", str(source), "status", "--porcelain=v1", "--untracked-files=no"]
    )
    return not status


def load_pin() -> dict[str, object]:
    if PIN_FILE.is_symlink() or not PIN_FILE.is_file():
        raise ProofError("accepted pin.json is missing")
    if PATCH_FILE.is_symlink() or not PATCH_FILE.is_file():
        raise ProofError("accepted identity-mfa.patch is missing")
    try:
        pin = json.loads(PIN_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ProofError("pin.json is invalid") from None
    if not isinstance(pin, dict):
        raise ProofError("pin.json has invalid shape")
    if type(pin.get("schema")) is not int or pin["schema"] != 1:
        raise ProofError("pin schema is unsupported")
    if pin.get("repository") != "https://github.com/bitwarden/sdk-internal":
        raise ProofError("pin repository differs from reviewed SDK")
    expected = pin.get("patchSHA256")
    if pin.get("accepted") is not True or not isinstance(expected, str):
        raise ProofError("pin does not contain coordinator-accepted patch SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ProofError("pin patch SHA is malformed")
    if expected != sha256_file(PATCH_FILE):
        raise ProofError("patch SHA does not match accepted pin")
    if pin.get("sourceCommit") != SOURCE_COMMIT:
        raise ProofError("pin source commit differs from reviewed SDK base")
    if pin.get("rustToolchain") != RUST_TOOLCHAIN or pin.get("target") != TARGET:
        raise ProofError("pin Rust target differs from reviewed target")
    if pin.get("minMacOS") != MIN_MACOS:
        raise ProofError("pin minimum macOS differs from reviewed target")
    return pin


def parse_test_count(output: str) -> tuple[int, int, int]:
    passed = failed = suites = 0
    for match in TEST_SUMMARY.finditer(output):
        passed += int(match.group(1))
        failed += int(match.group(2))
        suites += 1
    return passed, failed, suites


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run pinned SDK auth tests/build/Swift bindgen in a fresh private output."
    )
    parser.add_argument("--source", required=True, type=Path, help="existing pristine SDK checkout")
    parser.add_argument("--output", required=True, type=Path, help="new output directory; must not exist")
    args = parser.parse_args()

    source = args.source.expanduser().absolute()
    output_arg = args.output.expanduser().absolute()
    if source.is_symlink() or not source.is_dir():
        raise ProofError("SDK source checkout is missing or symlinked")
    source = source.resolve(strict=True)
    if output_arg.exists() or output_arg.is_symlink():
        raise ProofError("output already exists; choose a fresh path")
    if not output_arg.parent.is_dir():
        raise ProofError("output parent must already exist")
    output = (output_arg.parent.resolve(strict=True) / output_arg.name).resolve(strict=False)
    if output == source or output.is_relative_to(source) or source.is_relative_to(output):
        raise ProofError("output must be separate from SDK source")

    source_head = run_checked(["git", "-C", str(source), "rev-parse", "HEAD"])
    if source_head != SOURCE_COMMIT:
        raise ProofError("SDK source revision differs from pin")
    if not tracked_source_is_clean(source):
        raise ProofError("SDK source has tracked changes")
    if not (source / "Cargo.toml").is_file() or not (source / "Cargo.lock").is_file():
        raise ProofError("SDK source lacks Cargo workspace files")
    pin = load_pin()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ProofError("runner requires aarch64 macOS host")

    env = {
        key: os.environ[key]
        for key in ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "RUSTUP_HOME", "CARGO_HOME")
        if key in os.environ
    }
    env.update(
        RUSTUP_TOOLCHAIN=RUST_TOOLCHAIN,
        MACOSX_DEPLOYMENT_TARGET=MIN_MACOS,
        RUSTFLAGS=(
            "-C link-arg=-Wl,-application_extension "
            "-C link-arg=-mmacosx-version-min=26.0 --cfg bitwarden_ensure_non_commercial"
        ),
        CARGO_NET_OFFLINE="true",
        CARGO_TERM_COLOR="never",
    )
    run_checked(["rustc", "--version"], env=env)
    run_checked(["cargo", "--version"], env=env)
    installed_targets = run_checked(["rustup", "target", "list", "--installed"], env=env)
    if TARGET not in installed_targets.splitlines():
        raise ProofError("required Rust target is not installed; runner will not install toolchains")

    source_tree = run_checked(["git", "-C", str(source), "rev-parse", "HEAD^{tree}"])
    cargo_lock_sha = sha256_file(source / "Cargo.lock")
    host_product = run_checked(["sw_vers", "-productVersion"])
    host_build = run_checked(["sw_vers", "-buildVersion"])

    # mkdir is the first write. Every path and pinned input is validated above.
    try:
        output.mkdir(mode=0o700)
    except FileExistsError:
        raise ProofError("output appeared during preflight; no files changed") from None

    checkout = output / "sdk-internal"
    target_dir = output / "cargo-target"
    generated = output / "GeneratedSwift"
    manifest = checkout / "Cargo.toml"
    receipt: dict[str, object] = {
        "schema": 1,
        "startedAtUTC": datetime.now(timezone.utc).isoformat(),
        "status": "running",
        "source": {
            "repository": "https://github.com/bitwarden/sdk-internal",
            "commit": source_head,
            "tree": source_tree,
            "cargoLockSHA256": cargo_lock_sha,
            "trackedSourceClean": True,
        },
        "patchSHA256": pin["patchSHA256"],
        "host": {
            "system": platform.system(),
            "architecture": platform.machine(),
            "macOSProductVersion": host_product,
            "macOSBuildVersion": host_build,
            "deploymentTarget": MIN_MACOS,
            "rustToolchain": RUST_TOOLCHAIN,
            "target": TARGET,
        },
        "preflightCommands": list(PREFLIGHT_COMMANDS),
        "commands": [],
        "testSummary": {"passed": 0, "failed": 0, "suiteSummaries": 0},
    }

    def step(name: str, argv: list[str], cwd: Path | None = None, step_env: dict[str, str] | None = None):
        command_env = step_env or env
        try:
            result = subprocess.run(
                argv, cwd=cwd, env=command_env, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, check=False,
            )
        except OSError:
            result = subprocess.CompletedProcess(argv, 127, "", "")
        receipt["commands"].append({
            "name": name,
            "argv": argv,
            "cwd": str(cwd) if cwd else None,
            "environment": {
                key: command_env[key]
                for key in ("RUSTUP_TOOLCHAIN", "CARGO_TARGET_DIR", "MACOSX_DEPLOYMENT_TARGET", "RUSTFLAGS", "CARGO_NET_OFFLINE", "RUSTUP_HOME", "CARGO_HOME")
                if key in command_env
            },
            "exitCode": result.returncode,
        })
        return result

    def save_receipt():
        receipt["finishedAtUTC"] = datetime.now(timezone.utc).isoformat()
        receipt_path = output / "receipt.json"
        temporary = output / "receipt.json.tmp"
        temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        temporary.replace(receipt_path)
        receipt_path.chmod(0o600)

    try:
        clone = step(
            "local_clone",
            ["git", "clone", "--local", "--no-hardlinks", "--no-checkout", str(source), str(checkout)],
        )
        if clone.returncode:
            raise ProofError("local SDK clone failed")
        revision = step("checkout", ["git", "-C", str(checkout), "checkout", "--detach", SOURCE_COMMIT])
        if revision.returncode:
            raise ProofError("SDK checkout failed")
        check = step("patch_check", ["git", "-C", str(checkout), "apply", "--check", "--whitespace=error", str(PATCH_FILE)])
        if check.returncode:
            raise ProofError("patch does not apply cleanly")
        applied = step("apply_patch", ["git", "-C", str(checkout), "apply", "--whitespace=error", str(PATCH_FILE)])
        if applied.returncode:
            raise ProofError("patch application failed")
        diff = step("diff_check", ["git", "-C", str(checkout), "diff", "--check"])
        if diff.returncode:
            raise ProofError("patched SDK diff check failed")

        build_env = dict(env)
        build_env["CARGO_TARGET_DIR"] = str(target_dir)
        common = ["--offline", "--locked", "--manifest-path", str(manifest), "--target", TARGET]
        tests = step("full_bitwarden_auth_tests", ["cargo", "test", *common, "--package", "bitwarden-auth"], checkout, build_env)
        passed, failed, suites = parse_test_count(tests.stdout + "\n" + tests.stderr)
        receipt["testSummary"] = {"passed": passed, "failed": failed, "suiteSummaries": suites}
        if tests.returncode or not suites:
            raise ProofError("full bitwarden-auth package suite failed or returned no summaries")

        package_build = step("bitwarden_uniffi_build", ["cargo", "build", *common, "--package", "bitwarden-uniffi"], checkout, build_env)
        if package_build.returncode:
            raise ProofError("bitwarden-uniffi build failed")
        dylib = target_dir / TARGET / "debug" / "libbitwarden_uniffi.dylib"
        if not dylib.is_file() or dylib.is_symlink():
            raise ProofError("UniFFI dylib missing after build")
        minos = step("dylib_min_os", ["vtool", "-show-build", str(dylib)])
        if minos.returncode:
            raise ProofError("could not verify dylib minimum macOS version")
        if not re.search(r"minos\s+26\.0(?:\s|$)", minos.stdout):
            raise ProofError("built dylib minimum macOS version differs from pin")

        generation = step(
            "swift_bindgen",
            [
                "cargo", "run", "--offline", "--locked", "--package", "uniffi-bindgen", "--",
                "generate", str(dylib), "--language", "swift", "--no-format", "--out-dir", str(generated),
            ],
            checkout,
            build_env,
        )
        if generation.returncode:
            raise ProofError("SDK Swift binding generation failed")
        swift_files = sorted(generated.rglob("*.swift"))
        if not swift_files or any(path.is_symlink() for path in swift_files):
            raise ProofError("SDK bindgen did not produce regular Swift source files")
        receipt["artifacts"] = {
            "dylibPath": str(dylib),
            "dylibSHA256": sha256_file(dylib),
            "dylibMinimumMacOS": "26.0",
            "generatedSwiftPath": str(generated),
            "generatedSwiftFileCount": len(swift_files),
            "generatedSwiftTreeSHA256": sha256_tree(generated),
        }
        receipt["status"] = "succeeded"
        save_receipt()
        print(f"Proof succeeded: {passed} tests passed; receipt: {output / 'receipt.json'}")
        return 0
    except ProofError as error:
        receipt["status"] = "failed"
        receipt["failure"] = str(error)
        save_receipt()
        print(f"Proof failed: {error}; receipt: {output / 'receipt.json'}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProofError as error:
        print(f"Preflight failed: {error}", file=sys.stderr)
        raise SystemExit(2)
