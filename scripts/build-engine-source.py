#!/usr/bin/env python3
"""Build the pinned Ardia Chromium framework in an isolated ignored directory."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid
import zipfile


OWNER_FILE = ".engine-source-owner.json"
RECEIPT_FILE = "receipt.json"
LOCK_FILE = ".lock"
OWNER_VERSION = 1
GIB = 1024**3
PIN_RE = re.compile(r"^[0-9a-f]{40}$")
EXECUTION_STAGE_NAMES = [
    "01-sync.sh", "03-ungoogled.py", "04-domain-substitution.sh",
    "profile-patch", "02-gn-args.sh", "05-build.sh",
]


class BuildError(RuntimeError):
    pass


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha256(root: pathlib.Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    count = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise BuildError(f"symlink rejected in owned tree: {path}")
        if not path.is_file():
            continue
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(sha256(path).encode())
        digest.update(b"\n")
        count += 1
    return digest.hexdigest(), count


def load_config(repo: pathlib.Path) -> dict:
    path = repo / "ThirdParty/ArdiaCore/source-build.json"
    config = json.loads(path.read_text())
    for section, field in (("source", "commit"), ("chromium", "commit"), ("depotTools", "commit"),
                           ("ungoogled", "commit"), ("ungoogled", "macosCommit")):
        value = config[section][field]
        if not PIN_RE.fullmatch(value):
            raise BuildError(f"invalid pinned commit {section}.{field}")
    if config["patch"]["sha256"] == "REPLACE_AFTER_PATCH_REVIEW":
        raise BuildError("source-build.json has no reviewed patch digest")
    if not re.fullmatch(r"[0-9a-f]{64}", config["gitLfs"]["archiveSha256"]):
        raise BuildError("invalid pinned git-lfs archive digest")
    patch = repo / config["patch"]["file"]
    if sha256(patch) != config["patch"]["sha256"]:
        raise BuildError("profile download patch digest mismatch")
    if "latest" in json.dumps(config).lower():
        raise BuildError("floating latest input rejected")
    return config


def guarded_output(repo: pathlib.Path) -> pathlib.Path:
    repo = repo.resolve(strict=True)
    relative = pathlib.Path("build/EngineSource")
    current = repo
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise BuildError(f"symlink rejected in output path: {current}")
    output = repo / relative
    if output.parent.exists() and not output.parent.is_dir():
        raise BuildError("build output parent is not a directory")
    return output


def owner_record(repo: pathlib.Path) -> dict:
    return {
        "schemaVersion": OWNER_VERSION,
        "uid": os.getuid(),
        "repo": str(repo.resolve(strict=True)),
        "output": str((repo / "build/EngineSource").absolute()),
    }


def prepare_owned_output(repo: pathlib.Path) -> tuple[pathlib.Path, dict]:
    output = guarded_output(repo)
    expected = owner_record(repo)
    if output.exists():
        if output.is_symlink() or not output.is_dir():
            raise BuildError("existing build output is not a real directory")
        owner_path = output / OWNER_FILE
        if owner_path.is_symlink() or not owner_path.is_file():
            raise BuildError("existing output lacks a valid owner receipt")
        try:
            owner = json.loads(owner_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise BuildError("existing output owner receipt is unreadable") from exc
        if owner != expected:
            raise BuildError("existing output owner receipt does not match this checkout")
        if output.stat().st_uid != os.getuid() or stat.S_IMODE(output.stat().st_mode) & 0o077:
            raise BuildError("existing output is not owner-only and current-user owned")
    else:
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if output.parent.is_symlink():
            raise BuildError("build parent became a symlink")
        output.mkdir(mode=0o700)
        os.chmod(output, 0o700)
        if output.stat().st_uid != os.getuid():
            raise BuildError("new output is not current-user owned")
        write_private_json(output / OWNER_FILE, expected)
    return output, expected


def write_private_json(path: pathlib.Path, value: dict) -> None:
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def acquire_lock(output: pathlib.Path) -> int:
    path = output / LOCK_FILE
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
    except FileExistsError as exc:
        raise BuildError("owned build lock already exists; refusing concurrent or stale run") from exc
    os.write(fd, json.dumps({"pid": os.getpid(), "uid": os.getuid()}).encode())
    os.fsync(fd)
    return fd


def pid_is_absent(pid: int) -> bool:
    if pid <= 1:
        raise BuildError("stale lock contains an invalid process id")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError as exc:
        raise BuildError(f"cannot prove stale lock process {pid} is absent") from exc
    raise BuildError(f"stale lock process {pid} is still alive")


def recover_stale_lock(output: pathlib.Path, owner: dict, receipt: dict) -> dict | None:
    """Recover only an interrupted build lock whose recorded processes are gone."""
    lock = output / LOCK_FILE
    if not lock.exists() and not lock.is_symlink():
        return None
    if lock.is_symlink() or not lock.is_file():
        raise BuildError("existing build lock is not a regular file")
    lock_info = lock.lstat()
    if lock_info.st_uid != os.getuid() or stat.S_IMODE(lock_info.st_mode) & 0o077:
        raise BuildError("existing build lock ownership or mode rejected")
    try:
        lock_bytes = lock.read_bytes()
        lock_value = json.loads(lock_bytes)
    except (OSError, json.JSONDecodeError) as exc:
        raise BuildError("existing build lock is unreadable") from exc
    if lock_value.get("uid") != os.getuid() or not isinstance(lock_value.get("pid"), int):
        raise BuildError("existing build lock owner or process id mismatch")
    if receipt.get("owner") != owner or receipt.get("status") == "succeeded":
        raise BuildError("stale lock receipt does not match an incomplete owned build")
    attempts = receipt.get("stages", {}).get("05-build", {}).get("attempts", [])
    if not attempts or attempts[-1].get("status") != "running":
        raise BuildError("stale lock lacks matching interrupted build stage receipt")
    build_pid = attempts[-1].get("pid")
    if not isinstance(build_pid, int):
        raise BuildError("interrupted build stage lacks a process id")
    if not pid_is_absent(lock_value["pid"]) or not pid_is_absent(build_pid):
        raise BuildError("interrupted build processes remain active")
    try:
        os.killpg(build_pid, 0)
    except ProcessLookupError:
        pass
    except PermissionError as exc:
        raise BuildError(f"cannot prove interrupted build process group {build_pid} is absent") from exc
    else:
        raise BuildError(f"interrupted build process group {build_pid} is still alive")

    log_relative = attempts[-1].get("log")
    if not isinstance(log_relative, str):
        raise BuildError("interrupted build stage lacks a log receipt")
    log = output / log_relative
    assert_real_owned_path(log, output)
    if log.is_symlink() or not log.is_file() or log.stat().st_uid != os.getuid():
        raise BuildError("interrupted build log ownership or path rejected")
    recovery = {
        "schemaVersion": 1,
        "at": utc_now(),
        "owner": owner,
        "lock": {
            "pid": lock_value["pid"], "uid": lock_value["uid"],
            "sha256": hashlib.sha256(lock_bytes).hexdigest(),
            "contents": lock_bytes.decode("utf-8", errors="strict"),
            "mode": stat.S_IMODE(lock_info.st_mode),
        },
        "interruptedBuild": {
            "pid": build_pid, "stage": "05-build",
            "attempt": attempts[-1].get("attempt"), "log": log_relative,
            "logSha256": sha256(log), "logBytes": log.stat().st_size,
        },
        "processChecks": {
            "lockPidAbsent": True, "buildPidAbsent": True,
            "buildProcessGroupAbsent": True,
        },
        "receiptRunId": receipt.get("runId"),
        "configDigest": receipt.get("configDigest"),
    }
    recovery_path = output / "logs" / f"stale-lock-recovery-{lock_value['pid']}-{uuid.uuid4().hex}.json"
    recovery_path.parent.mkdir(mode=0o700, exist_ok=True)
    assert_real_owned_path(recovery_path.parent, output)
    write_private_json(recovery_path, recovery)
    current = lock.lstat()
    if (current.st_dev, current.st_ino, current.st_uid) != (
            lock_info.st_dev, lock_info.st_ino, os.getuid()):
        raise BuildError("stale lock changed during recovery")
    pid_is_absent(lock_value["pid"])
    pid_is_absent(build_pid)
    try:
        os.killpg(build_pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise BuildError(f"interrupted build process group {build_pid} reappeared")
    lock.unlink()
    return recovery


def free_bytes(path: pathlib.Path) -> int:
    return shutil.disk_usage(path).free


def require_capacity(repo: pathlib.Path, minimum: int) -> None:
    remaining = free_bytes(repo)
    if remaining < minimum:
        raise BuildError(f"free space {remaining} is below required floor {minimum}")


def cache_record_matches(record: dict, expected: dict) -> bool:
    keys = ("url", "commit", "tree", "archiveSha256")
    return all(record.get(key) == expected.get(key) for key in keys)


def source_precondition_errors(contents: dict[str, str]) -> list[str]:
    required = {
        "ardiaDownloads": (
            "UseTestDownloadsDir(profile);",
            "AC_ENGINE_CALL(ac_downloads_remove)",
        ),
        "ardiaEngine": (
            "void Error(std::string_view message);",
            "OffTheRecord off_the_record = OffTheRecord::kRefuse",
            "Profile* ProfileAt(std::string_view dir);",
        ),
        "ardiaExports": ("_ac_*",),
        "chromiumDownloadPrefs": (
            "base::FilePath DownloadPath() const;",
            "void SetDownloadPath(const base::FilePath& path);",
            "bool IsDownloadPathManaged() const;",
        ),
        "chromiumPrefService": ("GetFilePath(std::string_view path) const",),
        "chromiumFileUtil": ("PathIsWritable", "DirectoryExists"),
        "chromiumProfile": ("IsOffTheRecord()",),
        "chromiumBrowserContext": ("ShutdownStarted()",),
    }
    errors = []
    for name, needles in required.items():
        value = contents.get(name, "")
        for needle in needles:
            if needle not in value:
                errors.append(f"{name} missing pinned API anchor: {needle}")
    return errors


def metal_toolchain_precondition_errors(expected: dict, actual: dict) -> list[str]:
    errors = []
    for field in ("component", "metalPath", "metalRealPath", "metalVersion",
                  "metalSha256", "codesignVerifyReturnCode", "codesignDisplay",
                  "assetPath", "assetSha256"):
        if expected.get(field) != actual.get(field):
            errors.append(f"Metal Toolchain {field} changed after preflight")
    component = actual.get("component", {})
    if component.get("status") != "installed":
        errors.append("Metal Toolchain component is not installed")
    if actual.get("codesignVerifyReturnCode") != 0:
        errors.append("Metal compiler signature verification failed")
    return errors


def series_path_precondition_errors(contents: str) -> list[str]:
    required = (
        'SRC = os.environ.get("CHROMIUM_SRC",',
        'BASE = os.environ.get("AC_SERIES_BASE",',
    )
    return [f"Ardia series.py missing owned path override: {anchor}"
            for anchor in required if anchor not in contents]


def verify_source_preconditions(ardia: pathlib.Path, chromium: pathlib.Path) -> None:
    files = {
        "ardiaDownloads": aria_read(ardia, "engine/chromium/src/chrome/browser/ardia/ac_downloads.cc"),
        "ardiaEngine": aria_read(ardia, "engine/chromium/src/chrome/browser/ardia/ac_engine.h"),
        "ardiaExports": aria_read(ardia, "engine/chromium/src/chrome/browser/ardia/ac_engine.exports"),
        "chromiumDownloadPrefs": read_text(chromium / "chrome/browser/download/download_prefs.h"),
        "chromiumPrefService": read_text(chromium / "components/prefs/pref_service.h"),
        "chromiumFileUtil": read_text(chromium / "base/files/file_util.h"),
        "chromiumProfile": read_text(chromium / "chrome/browser/profiles/profile.h"),
        "chromiumBrowserContext": read_text(chromium / "content/public/browser/browser_context.h"),
    }
    errors = source_precondition_errors(files)
    if errors:
        raise BuildError("source API preconditions failed: " + "; ".join(errors))


def read_text(path: pathlib.Path) -> str:
    if path.is_symlink() or not path.is_file():
        return ""
    return path.read_text(errors="replace")


def aria_read(root: pathlib.Path, relative: str) -> str:
    return read_text(root / relative)


def assert_real_owned_path(path: pathlib.Path, root: pathlib.Path) -> None:
    root = root.resolve(strict=True)
    candidate = path.absolute()
    base = None
    for ancestor in (candidate, *candidate.parents):
        if ancestor.resolve(strict=False) == root:
            if ancestor.is_symlink():
                raise BuildError(f"symlink rejected in owned output path: {ancestor}")
            base = ancestor
            break
    if base is None:
        raise BuildError(f"path escapes owned output: {path}")
    relative = candidate.relative_to(base)
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise BuildError(f"symlink rejected in owned output: {current}")
        if current.exists() and current.stat().st_uid != os.getuid():
            raise BuildError(f"foreign-owned path rejected: {current}")


def process_group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def terminate_process_group(process: subprocess.Popen, grace: float = 10.0) -> None:
    pgid = process.pid
    with contextlib.suppress(ProcessLookupError):
        os.killpg(pgid, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while process_group_exists(pgid) and time.monotonic() < deadline:
        process.poll()
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    if process_group_exists(pgid):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pgid, signal.SIGKILL)
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pgid, signal.SIGKILL)
        process.wait(timeout=grace)
    group_deadline = time.monotonic() + grace
    while process_group_exists(pgid):
        if time.monotonic() >= group_deadline:
            raise BuildError(f"owned child process group did not terminate: {pgid}")
        time.sleep(0.05)


class Runner:
    def __init__(self, repo: pathlib.Path, output: pathlib.Path, config: dict):
        self.repo = repo.resolve(strict=True)
        self.output = output
        self.config = config
        self.receipt_path = output / RECEIPT_FILE
        self.receipt = self._load_receipt()
        recovery = recover_stale_lock(output, owner_record(self.repo), self.receipt)
        self.lock_fd = acquire_lock(output)
        self.lock_identity = os.fstat(self.lock_fd)
        if recovery:
            self.receipt.setdefault("recoveries", []).append(recovery)
            self.save()

    def _load_receipt(self) -> dict:
        if self.receipt_path.exists():
            if self.receipt_path.is_symlink() or self.receipt_path.stat().st_uid != os.getuid():
                raise BuildError("build receipt ownership/path rejected")
            data = json.loads(self.receipt_path.read_text())
            if data.get("owner") != owner_record(self.repo):
                raise BuildError("build receipt owner does not match checkout")
            current_config_digest = sha256(self.repo / "ThirdParty/ArdiaCore/source-build.json")
            if data.get("configDigest") != current_config_digest:
                old_pins = json.loads(json.dumps(data.get("pins", {})))
                new_pins = json.loads(json.dumps(self.config))
                old_pins.pop("gitLfs", None)
                new_pins.pop("gitLfs", None)
                old_patch_digest = old_pins.get("patch", {}).get("sha256")
                new_patch_digest = new_pins.get("patch", {}).get("sha256")
                added_chromium_commit = False
                old_chromium_commit = old_pins.get("chromium", {}).get("commit")
                new_chromium_commit = new_pins.get("chromium", {}).get("commit")
                if old_chromium_commit is None and isinstance(new_chromium_commit, str) and PIN_RE.fullmatch(new_chromium_commit):
                    chromium = pathlib.Path(data["owner"]["output"]) / "chromium_git/chromium/src"
                    assert_real_owned_path(chromium, pathlib.Path(data["owner"]["output"]))
                    git_env = {"PATH": os.environ.get("PATH", ""),
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_TERMINAL_PROMPT": "0"}
                    resolved = subprocess.run(["/usr/bin/git", "-C", str(chromium), "rev-parse", "HEAD"],
                                              cwd=self.repo, env=git_env, capture_output=True,
                                              text=True, timeout=15)
                    if resolved.returncode or resolved.stdout.strip() != new_chromium_commit:
                        raise BuildError("new Chromium commit pin does not match owned source checkout")
                    old_pins.setdefault("chromium", {})["commit"] = new_chromium_commit
                    added_chromium_commit = True
                added_depot_python = False
                old_depot_tools = old_pins.get("depotTools", {})
                new_depot_tools = new_pins.get("depotTools", {})
                for key, expected in (
                        ("pythonPackage", "infra/3pp/tools/cpython3/mac-arm64"),
                        ("pythonVersionTag", "version:2@3.11.8.chromium.35")):
                    if key not in old_depot_tools and new_depot_tools.get(key) == expected:
                        old_depot_tools[key] = expected
                        added_depot_python = True
                if "patch" in old_pins:
                    old_pins["patch"]["sha256"] = "PATCH_DIGEST"
                if "patch" in new_pins:
                    new_pins["patch"]["sha256"] = "PATCH_DIGEST"
                patch_not_applied = not data.get("inputs", {}).get("profilePatchApplied")
                if (data.get("status") != "failed" or
                        (not patch_not_applied and not added_depot_python) or old_pins != new_pins):
                    raise BuildError("build config changed after a non-compatible receipt was created")
                added_inputs = []
                if "gitLfs" not in data.get("pins", {}):
                    added_inputs.append("gitLfs")
                if old_patch_digest != new_patch_digest:
                    added_inputs.append("patch.sha256")
                if added_chromium_commit:
                    added_inputs.append("chromium.commit")
                if added_depot_python:
                    added_inputs.extend(["depotTools.pythonPackage", "depotTools.pythonVersionTag"])
                data.setdefault("configUpdates", []).append({
                    "previousDigest": data.get("configDigest"),
                    "currentDigest": current_config_digest,
                    "changedPins": added_inputs,
                    "at": utc_now(),
                })
                data["configDigest"] = current_config_digest
                data["pins"] = self.config
            current_runner = sha256(pathlib.Path(__file__))
            if data.get("runnerSha256") != current_runner:
                if data.get("status") != "failed":
                    raise BuildError("build runner changed after a non-failed receipt was created")
                data.setdefault("runnerUpdates", []).append({
                    "previousSha256": data.get("runnerSha256"),
                    "currentSha256": current_runner,
                    "at": utc_now(),
                })
                data["runnerSha256"] = current_runner
            return data
        return {
            "schemaVersion": 1,
            "runId": str(uuid.uuid4()),
            "owner": owner_record(self.repo),
            "configDigest": sha256(self.repo / "ThirdParty/ArdiaCore/source-build.json"),
            "runnerSha256": sha256(pathlib.Path(__file__)),
            "pins": self.config,
            "host": self.host_inputs(self.repo),
            "stages": {},
            "framework": None,
            "status": "started",
            "startedAt": utc_now(),
        }

    @staticmethod
    def host_inputs(repo: pathlib.Path) -> dict:
        def output(args: list[str]) -> str:
            result = subprocess.run(args, capture_output=True, text=True, timeout=15)
            if result.returncode:
                raise BuildError(f"cannot resolve host input: {args[0]}")
            return result.stdout.strip()

        return {
            "os": sys.platform,
            "architecture": output(["/usr/bin/uname", "-m"]),
            "xcode": output(["/usr/bin/xcodebuild", "-version"]),
            "sdk": output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]),
            "clang": output(["/usr/bin/clang", "--version"]).splitlines()[0],
            "processors": int(output(["/usr/sbin/sysctl", "-n", "hw.ncpu"])),
            "memoryBytes": int(output(["/usr/sbin/sysctl", "-n", "hw.memsize"])),
            "freeBytesAtStart": free_bytes(repo),
        }

    def save(self) -> None:
        write_private_json(self.receipt_path, self.receipt)

    @staticmethod
    def stage_succeeded(record: dict) -> bool:
        attempts = record.get("attempts", [])
        return (record.get("status") == "succeeded"
                and (attempts[-1].get("status") if attempts else record.get("status")) == "succeeded")

    def child_environment(self) -> dict:
        environment = os.environ.copy()
        for key in tuple(environment):
            if re.search(r"TOKEN|PASSWORD|SECRET|CREDENTIAL|PRIVATE_KEY|API_KEY|AUTHORIZATION|COOKIE", key, re.I):
                environment.pop(key, None)
        environment.update({
            "PATH": str(self.output / "tools") + os.pathsep + environment.get("PATH", ""),
            "CHROMIUM_SRC": str(self.output / "chromium_git/chromium/src"),
            "AC_SERIES_BASE": str(self.output / "series-base"),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "4",
            "GIT_CONFIG_KEY_0": "filter.lfs.clean",
            "GIT_CONFIG_VALUE_0": "git-lfs clean -- %f",
            "GIT_CONFIG_KEY_1": "filter.lfs.smudge",
            "GIT_CONFIG_VALUE_1": "git-lfs smudge -- %f",
            "GIT_CONFIG_KEY_2": "filter.lfs.process",
            "GIT_CONFIG_VALUE_2": "git-lfs filter-process",
            "GIT_CONFIG_KEY_3": "filter.lfs.required",
            "GIT_CONFIG_VALUE_3": "true",
            "VPYTHON_VIRTUALENV_ROOT": str(self.output / "vpython-root"),
            "BOTO_CONFIG": "/dev/null",
            "CLOUDSDK_CONFIG": str(self.output / "cloudsdk"),
            "LUCI_CONTEXT": str(self.output / ".no-auth-luci-context.json"),
            "DEPOT_TOOLS_UPDATE": "0",
            "DEPOT_TOOLS_METRICS": "0",
            "GIT_TERMINAL_PROMPT": "0",
        })
        return environment

    def close(self) -> None:
        path = self.output / LOCK_FILE
        with contextlib.suppress(OSError):
            os.close(self.lock_fd)
        try:
            info = path.lstat()
            if (info.st_dev, info.st_ino, info.st_uid) == (
                    self.lock_identity.st_dev, self.lock_identity.st_ino, os.getuid()):
                path.unlink()
        except FileNotFoundError:
            pass

    def prepare_git_lfs(self) -> pathlib.Path:
        config = self.config["gitLfs"]
        tools = self.output / "tools"
        downloads = self.output / "downloads"
        for directory in (tools, downloads, self.output / "cloudsdk"):
            if directory.exists() or directory.is_symlink():
                assert_real_owned_path(directory, self.output)
                if directory.is_symlink() or not directory.is_dir():
                    raise BuildError(f"git-lfs directory is not a real owned directory: {directory.name}")
            else:
                directory.mkdir(mode=0o700)
        luci_context = self.output / ".no-auth-luci-context.json"
        context_value = {"local_auth": {}}
        if luci_context.exists() or luci_context.is_symlink():
            assert_real_owned_path(luci_context, self.output)
            if luci_context.is_symlink() or not luci_context.is_file() or json.loads(
                    luci_context.read_text()) != context_value:
                raise BuildError("existing no-auth LUCI context is invalid")
        else:
            write_private_json(luci_context, context_value)
        binary = tools / "git-lfs"
        record = self.receipt.get("inputs", {}).get("gitLfs")
        if binary.exists() or binary.is_symlink():
            if binary.is_symlink() or not binary.is_file() or not record:
                raise BuildError("existing git-lfs binary lacks an exact receipt")
            assert_real_owned_path(binary, self.output)
            if (record.get("url") != config["url"] or
                    record.get("version") != config["version"] or
                    record.get("archiveSha256") != config["archiveSha256"] or
                    record.get("binary") != "tools/git-lfs" or
                    record.get("binarySha256") != sha256(binary)):
                raise BuildError("existing git-lfs binary does not match pinned receipt")
            archive = self.output / record["archive"]
            assert_real_owned_path(archive, self.output)
            if archive.is_symlink() or not archive.is_file() or sha256(archive) != config["archiveSha256"]:
                raise BuildError("existing git-lfs archive does not match pinned receipt")
        else:
            archive = downloads / f"git-lfs-{config['version']}-{uuid.uuid4().hex}.zip"
            self.run("git-lfs-download", [
                "/usr/bin/curl", "--disable", "--fail", "--location", "--silent",
                "--show-error", "--retry", "2", "--connect-timeout", "20",
                "--max-time", "300", "--output", str(archive), config["url"],
            ], self.output, 360)
            if not archive.is_file() or sha256(archive) != config["archiveSha256"]:
                raise BuildError("downloaded git-lfs archive digest mismatch")
            assert_real_owned_path(archive, self.output)
            try:
                with zipfile.ZipFile(archive) as source:
                    matches = [entry for entry in source.infolist()
                               if pathlib.PurePosixPath(entry.filename).name == "git-lfs"
                               and not entry.is_dir()]
                    if len(matches) != 1:
                        raise BuildError("pinned git-lfs archive has an unexpected binary layout")
                    mode = matches[0].external_attr >> 16
                    if stat.S_ISLNK(mode):
                        raise BuildError("pinned git-lfs archive binary is a symlink")
                    fd = os.open(binary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
                    with os.fdopen(fd, "wb") as target, source.open(matches[0]) as payload:
                        shutil.copyfileobj(payload, target)
                        target.flush()
                        os.fsync(target.fileno())
            except (OSError, zipfile.BadZipFile) as exc:
                raise BuildError(f"cannot extract pinned git-lfs binary: {exc}") from exc
            os.chmod(binary, 0o700)
            assert_real_owned_path(binary, self.output)
        self.receipt.setdefault("inputs", {})["gitLfs"] = {
            "url": config["url"], "version": config["version"],
            "archiveSha256": config["archiveSha256"],
            "archive": str(archive.relative_to(self.output)),
            "binary": str(binary.relative_to(self.output)),
            "binarySha256": sha256(binary),
            "cacheRoot": "depot_tools/.cipd_bin and vpython-root (owned output)",
            "cloudConfig": "disabled user boto config; isolated owner-only Cloud SDK root",
        }
        self.save()
        self.run("git-lfs-version", [str(binary), "version"], self.output, 30)
        version_log = self.output / "logs/git-lfs-version.log"
        version = version_log.read_text(errors="replace").strip()
        if not version.startswith(f"git-lfs/{config['version']} "):
            raise BuildError(f"unexpected pinned git-lfs version output: {version[:120]}")
        self.receipt["inputs"]["gitLfs"]["observedVersion"] = version
        self.receipt["inputs"]["cloudAuthIsolation"] = {
            "BOTO_CONFIG": "/dev/null",
            "CLOUDSDK_CONFIG": str(self.output / "cloudsdk"),
            "LUCI_CONTEXT": str(luci_context.relative_to(self.output)),
            "luciContextSha256": sha256(luci_context),
            "homeOverridden": False,
        }
        self.save()
        return binary

    def run(self, stage: str, args: list[str], cwd: pathlib.Path,
            timeout_seconds: int, env: dict | None = None) -> None:
        assert_real_owned_path(cwd, self.output)
        require_capacity(self.repo, self.config["build"]["minimumFreeBytes"])
        prior = self.receipt["stages"].get(stage, {})
        attempts = list(prior.get("attempts", []))
        if prior and not attempts:
            attempts.append({key: value for key, value in prior.items() if key != "attempts"})
        attempt = len(attempts) + 1
        filename = f"{stage}.log" if attempt == 1 else f"{stage}.attempt-{attempt:02d}.log"
        log = self.output / "logs" / filename
        log.parent.mkdir(mode=0o700, exist_ok=True)
        assert_real_owned_path(log.parent, self.output)
        if log.exists() or log.is_symlink():
            raise BuildError(f"stage log already exists or is symlinked: {log.name}")
        started = utc_now()
        record = {"attempt": attempt, "status": "running", "args": args,
                  "cwd": str(cwd.relative_to(self.output)),
                  "timeoutSeconds": timeout_seconds, "startedAt": started,
                  "log": str(log.relative_to(self.output))}
        attempts.append(record)
        stage_record = {"status": "running", "attempts": attempts}
        self.receipt["stages"][stage] = stage_record
        self.save()
        base_env = self.child_environment()
        base_env.update({"CB": str(self.output), "ENGINE_BUILD_ROOT": str(self.output),
            "AC_REPO": str(self.output / "source/ardia-build"),
                         "JOBS": str(self.config["build"]["buildJobs"]),
                         })
        if env:
            base_env.update(env)
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        process = None
        try:
            with os.fdopen(fd, "wb") as stream:
                try:
                    process = subprocess.Popen(args, cwd=cwd, env=base_env,
                                               stdout=stream, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                except OSError as exc:
                    record.update({"status": "spawn_failed", "spawnError": str(exc),
                                   "finishedAt": utc_now()})
                    stage_record["status"] = "spawn_failed"
                    self.save()
                    raise BuildError(f"could not start stage {stage}: {exc}") from exc
                record["pid"] = process.pid
                self.save()
                deadline = time.monotonic() + timeout_seconds
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        terminate_process_group(process)
                        record.update({"status": "timeout", "finishedAt": utc_now(),
                                       "returnCode": process.returncode})
                        stage_record["status"] = "timeout"
                        self.save()
                        raise BuildError(f"stage timed out: {stage}; see {log}")
                    try:
                        result = process.wait(timeout=min(10, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        try:
                            require_capacity(self.repo, self.config["build"]["minimumFreeBytes"])
                        except BuildError:
                            terminate_process_group(process)
                            record.update({"status": "capacity_stopped", "finishedAt": utc_now(),
                                           "returnCode": process.returncode})
                            stage_record["status"] = "capacity_stopped"
                            self.save()
                            raise
            record.update({"status": "succeeded" if result == 0 else "failed",
                           "finishedAt": utc_now(), "returnCode": result,
                           "logSha256": sha256(log)})
            stage_record["status"] = record["status"]
            self.save()
            require_capacity(self.repo, self.config["build"]["minimumFreeBytes"])
            if result != 0:
                raise BuildError(f"stage failed: {stage} (exit {result}); see {log}")
        except Exception:
            if process:
                terminate_process_group(process)
            raise

    def git(self, stage: str, cwd: pathlib.Path, *args: str, timeout: int = 900) -> str:
        require_capacity(self.repo, self.config["build"]["minimumFreeBytes"])
        logs = self.output / "logs"
        logs.mkdir(mode=0o700, exist_ok=True)
        log = logs / f"{stage}.log"
        attempt = 1
        while log.exists() or log.is_symlink():
            attempt += 1
            log = logs / f"{stage}.attempt-{attempt:02d}.log"
        log.parent.mkdir(mode=0o700, exist_ok=True)
        assert_real_owned_path(log.parent, self.output)
        command = ["/usr/bin/git", "-C", str(cwd), *args]
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                                env=self.child_environment())
        if result.returncode:
            fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write((result.stdout or "") + (result.stderr or ""))
            raise BuildError(f"git stage failed: {stage}; see {log}")
        return result.stdout.strip()

    def clone_pinned(self, name: str, url: str, commit: str) -> pathlib.Path:
        destination = self.output / name
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        assert_real_owned_path(destination.parent, self.output)
        if destination.is_symlink():
            raise BuildError(f"symlink rejected for {name} checkout")
        if destination.exists():
            assert_real_owned_path(destination, self.output)
            actual = self.git(name + "-verify", destination, "rev-parse", "HEAD")
            if actual != commit:
                raise BuildError(f"existing {name} checkout is not pinned commit")
            dirty = self.git(name + "-status", destination, "status", "--porcelain")
            if dirty:
                raise BuildError(f"existing {name} checkout is modified; refusing cache reuse")
            tree = self.git(name + "-tree", destination, "rev-parse", "HEAD^{tree}")
            prior = self.receipt.get("sources", {}).get(name)
            if prior:
                expected = {"url": url, "commit": actual, "tree": tree,
                            "archiveSha256": self.git_archive_digest(name, destination, commit)}
                if not cache_record_matches(prior, expected):
                    raise BuildError(f"existing {name} receipt does not match checkout")
            else:
                raise BuildError(f"existing {name} checkout lacks a matching cache receipt")
            return destination
        self.run(name + "-clone", ["/usr/bin/git", "clone", "--depth=1", "--filter=blob:none",
                                  "--no-checkout", "--no-tags", url, str(destination)],
                 self.output, self.config["build"]["timeoutsSeconds"]["clone"])
        self.run(name + "-fetch", ["/usr/bin/git", "-C", str(destination), "fetch",
                                  "--depth=1", "origin", commit], self.output,
                 self.config["build"]["timeoutsSeconds"]["clone"])
        self.run(name + "-checkout", ["/usr/bin/git", "-C", str(destination), "checkout",
                                     "--detach", "--force", commit], self.output,
                 self.config["build"]["timeoutsSeconds"]["clone"])
        actual = self.git(name + "-verify", destination, "rev-parse", "HEAD")
        if actual != commit:
            raise BuildError(f"{name} checkout did not resolve to pinned commit")
        self.receipt.setdefault("sources", {})[name] = {
            "url": url, "commit": actual,
            "tree": self.git(name + "-tree", destination, "rev-parse", "HEAD^{tree}"),
            "archiveSha256": self.git_archive_digest(name, destination, commit),
        }
        self.save()
        return destination

    def git_archive_digest(self, name: str, cwd: pathlib.Path, commit: str) -> str:
        archive = self.output / "archives" / f"{name.replace('/', '__')}-{commit}.tar"
        archive.parent.mkdir(mode=0o700, exist_ok=True)
        assert_real_owned_path(archive.parent, self.output)
        if archive.exists() or archive.is_symlink():
            raise BuildError(f"archive path already exists: {archive.name}")
        with archive.open("xb") as stream:
            process = subprocess.Popen(["/usr/bin/git", "-C", str(cwd), "archive", "--format=tar",
                                        commit], stdout=stream, stderr=subprocess.PIPE,
                                       env=self.child_environment(), start_new_session=True)
            try:
                _, error = process.communicate(timeout=900)
            except subprocess.TimeoutExpired:
                terminate_process_group(process)
                raise BuildError(f"git archive timed out for {name}")
            if process.returncode:
                raise BuildError(f"git archive failed for {name}: {error.decode(errors='replace')[:300]}")
        os.chmod(archive, 0o600)
        digest = sha256(archive)
        archive.unlink()
        return digest

    def stage_upstream_scripts(self, aria: pathlib.Path) -> pathlib.Path:
        src = aria / "engine/patches/build"
        scripts = self.output / "scripts"
        if scripts.is_symlink():
            raise BuildError("symlink rejected for staged scripts")
        if scripts.exists():
            assert_real_owned_path(scripts, self.output)
            expected = self.receipt.get("inputs", {}).get("stagedBuildScriptSha256")
            actual = {
                path.name: sha256(path) for path in sorted(scripts.iterdir())
                if path.is_file() and not path.is_symlink()
            }
            if expected and actual == expected:
                sync_script = scripts / "01-sync.sh"
                sync_text = sync_script.read_text()
                needs_cache_adaptation = (
                    'cache_dir = r"$CB/gclient-cache"' not in sync_text or
                    'gclient --cache-dir="$CB/gclient-cache" sync' in sync_text)
                apply_script = scripts / "apply-chromium-patches.sh"
                capture_base = 'python3 "$series" capture-base --phase chromium'
                needs_resume_adaptation = capture_base in apply_script.read_text()
                gn_script = scripts / "02-gn-args.sh"
                gn_text = gn_script.read_text()
                needs_pinned_gn = (
                    bool(re.search(r'(?m)^gn gen "out/\$GN_OUT_CONFIGS"$', gn_text)) or
                    './buildtools/mac/./buildtools/mac/gn gen "out/$GN_OUT_CONFIGS"' in gn_text)
                build_script = scripts / "05-build.sh"
                build_text = build_script.read_text()
                needs_priority_adaptation = (
                    "exec autoninja " in build_text or "exec lowprio autoninja " in build_text)
                if (not self.has_unadapted_home_paths(scripts) and not needs_cache_adaptation
                        and not needs_resume_adaptation and not needs_pinned_gn
                        and not needs_priority_adaptation):
                    return scripts
                if self.has_unadapted_home_paths(scripts):
                    self.checked_replace(
                        scripts / "02-gn-args.sh",
                        "source ~/chromium-build/scripts/gn_defines.sh",
                        'source "$CB/scripts/gn_defines.sh"', 1)
                    self.checked_replace(
                        scripts / "env.sh",
                        "# ~/Documents/ardia for the copy in ~/chromium-build/scripts that the step scripts source.",
                        "# Set AC_REPO explicitly to the pinned Ardia source checkout.", 1)
                    self.checked_replace(
                        scripts / "env.sh",
                        '_ac_repo="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"\n'
                        '[[ -f "$_ac_repo/engine/patches/series" ]] || _ac_repo="$HOME/Documents/ardia"\n'
                        'export AC_REPO="${AC_REPO:-$_ac_repo}"\n'
                        'unset _ac_repo',
                        'if [[ -z "${AC_REPO:-}" || ! -f "$AC_REPO/engine/patches/series" ]]; then\n'
                        '  echo "AC_REPO must point to the pinned Ardia source checkout" >&2\n'
                        '  exit 1\n'
                        'fi', 1)
                    self.checked_replace(
                        scripts / "03-ungoogled.py",
                        "~/chromium-build/ungoogled{,-macos} first",
                        "the pinned EngineSource trees", 1)
                if needs_cache_adaptation:
                    self.checked_replace(
                        sync_script,
                        "target_os = ['mac']",
                        'target_os = [\'mac\']\ncache_dir = r"$CB/gclient-cache"', 1)
                    if 'gclient --cache-dir="$CB/gclient-cache" sync' in sync_text:
                        self.checked_replace(
                            sync_script,
                            'lowprio_net gclient --cache-dir="$CB/gclient-cache" sync',
                            "lowprio_net gclient sync", 1)
                if needs_resume_adaptation:
                    self.checked_replace(
                        apply_script, capture_base,
                        'if [[ ! -d "$AC_SERIES_BASE" ]]; then\n'
                        '  python3 "$series" capture-base --phase chromium\n'
                        'fi', 1)
                if needs_pinned_gn:
                    self.adapt_pinned_gn_script(gn_script)
                if needs_priority_adaptation:
                    self.adapt_build_priority_script(build_script)
                self.validate_staged_paths(scripts)
                self.record_staged_scripts(scripts)
                substitutions = self.receipt["inputs"].setdefault("scriptSubstitutions", [])
                for item in (
                    "gn_defines.sh source -> owner-checked ENGINE_BUILD_ROOT",
                    "AC_REPO fallback -> explicit pinned source requirement",
                    "upstream home-tree comments -> owned EngineSource paths",
                    "gclient cache -> owned EngineSource/gclient-cache",
                    "Ardia series paths -> owned CHROMIUM_SRC and AC_SERIES_BASE",
                    "series base capture -> resumable in owned AC_SERIES_BASE",
                    "GN invocation -> Chromium pinned buildtools/mac/gn",
                ):
                    if item not in substitutions:
                        substitutions.append(item)
                self.receipt["inputs"]["cacheRoots"] = {
                    "gclient": str(self.output / "gclient-cache"),
                    "cipd": str(self.output / "depot_tools/.cipd_bin"),
                    "vpython": str(self.output / "vpython-root"),
                    "gitLfs": str(self.output / "tools/git-lfs"),
                    "cloudsdk": str(self.output / "cloudsdk"),
                    "luciContext": str(self.output / ".no-auth-luci-context.json"),
                }
                self.receipt["inputs"]["effectiveCommands"] = self.effective_commands()
                self.save()
                return scripts
            raise BuildError("existing staged scripts lack a matching receipt")
        upstream_digests = {
            path.name: sha256(path) for path in sorted(src.iterdir())
            if path.is_file() and not path.is_symlink()
        }
        shutil.copytree(src, scripts, symlinks=True)
        for path in scripts.rglob("*"):
            if path.is_symlink():
                raise BuildError(f"upstream script symlink rejected: {path.relative_to(self.output)}")
        self.checked_replace(scripts / "env.sh", "export CB=~/chromium-build",
                             'export CB="$ENGINE_BUILD_ROOT"', 1)
        replacements = [
            ("source ~/chromium-build/scripts/env.sh", 'source "$CB/scripts/env.sh"', 1),
            ("source ~/chromium-build/scripts/gn_defines.sh",
             'source "$CB/scripts/gn_defines.sh"', 1),
        ]
        for name in ("01-sync.sh", "02-gn-args.sh", "04-domain-substitution.sh",
                     "05-build.sh", "apply-chromium-patches.sh", "game-resource.sh"):
            path = scripts / name
            if not path.exists():
                continue
            for old, new, count in replacements:
                self.checked_replace(path, old, new, count)
        sync = scripts / "01-sync.sh"
        self.checked_replace(sync, "'siso_version': 'latest'",
                             f"'siso_version': '{self.config['chromium']['sisoVersion']}'", 1)
        self.checked_replace(sync, "lowprio_net timeout 3600 git", "lowprio_net git", 1)
        self.checked_replace(sync, "lowprio_net timeout 7200 gclient sync", "lowprio_net gclient sync", 1)
        self.checked_replace(sync, "-j 16", f"-j {self.config['build']['syncJobs']}", 1)
        self.checked_replace(
            sync, "target_os = ['mac']",
            'target_os = [\'mac\']\ncache_dir = r"$CB/gclient-cache"', 1)
        python_patches = scripts / "03-ungoogled.py"
        self.checked_replace(python_patches, "import pathlib\n", "import os\nimport pathlib\n", 1)
        self.checked_replace(python_patches, "CB = pathlib.Path.home() / 'chromium-build'",
                             "CB = pathlib.Path(os.environ['ENGINE_BUILD_ROOT'])", 1)
        self.checked_replace(
            python_patches,
            "~/chromium-build/ungoogled{,-macos} first",
            "the pinned EngineSource trees", 1)
        env_script = scripts / "env.sh"
        self.checked_replace(
            env_script,
            "# ~/Documents/ardia for the copy in ~/chromium-build/scripts that the step scripts source.",
            "# Set AC_REPO explicitly to the pinned Ardia source checkout.", 1)
        self.checked_replace(
            env_script,
            '_ac_repo="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"\n'
            '[[ -f "$_ac_repo/engine/patches/series" ]] || _ac_repo="$HOME/Documents/ardia"\n'
            'export AC_REPO="${AC_REPO:-$_ac_repo}"\n'
            'unset _ac_repo',
            'if [[ -z "${AC_REPO:-}" || ! -f "$AC_REPO/engine/patches/series" ]]; then\n'
            '  echo "AC_REPO must point to the pinned Ardia source checkout" >&2\n'
            '  exit 1\n'
            'fi', 1)
        apply_script = scripts / "apply-chromium-patches.sh"
        self.checked_replace(
            apply_script,
            'python3 "$series" capture-base --phase chromium',
            'if [[ ! -d "$AC_SERIES_BASE" ]]; then\n'
            '  python3 "$series" capture-base --phase chromium\n'
            'fi', 1)
        build = scripts / "05-build.sh"
        self.adapt_build_priority_script(build)
        gn_script = scripts / "02-gn-args.sh"
        self.adapt_pinned_gn_script(gn_script)
        self.validate_staged_paths(scripts)
        self.receipt["inputs"]["upstreamBuildScriptSha256"] = upstream_digests
        self.receipt["inputs"]["scriptSubstitutions"] = [
            "~/chromium-build -> owner-checked ENGINE_BUILD_ROOT",
            "siso_version latest -> pinned Chromium DEPS revision",
            "sync jobs 16 -> 4",
            "gclient cache -> owned EngineSource/gclient-cache",
            "series base capture -> resumable in owned AC_SERIES_BASE",
            "GN invocation -> Chromium pinned buildtools/mac/gn",
            "network wrappers retain runner process-group timeout",
            "autoninja runs at background QoS with 6 jobs",
        ]
        self.receipt["inputs"]["cacheRoots"] = {
            "gclient": str(self.output / "gclient-cache"),
            "cipd": str(self.output / "depot_tools/.cipd_bin"),
            "vpython": str(self.output / "vpython-root"),
            "gitLfs": str(self.output / "tools/git-lfs"),
            "cloudsdk": str(self.output / "cloudsdk"),
            "luciContext": str(self.output / ".no-auth-luci-context.json"),
        }
        self.receipt["inputs"]["effectiveCommands"] = self.effective_commands()
        self.record_staged_scripts(scripts)
        self.save()
        return scripts

    def effective_commands(self) -> dict:
        return {
            "seriesPathEnvironment": {
                "CHROMIUM_SRC": "chromium_git/chromium/src",
                "AC_SERIES_BASE": "series-base",
            },
            "sync": ["taskpolicy", "-c", "utility", "-d", "throttle", "nice", "-n", "19",
                     "gclient", "sync", "--no-history", "--nohooks", "--reset", "--force",
                     "-D", "-j", "4"],
            "runhooks": ["taskpolicy", "-c", "utility", "-d", "throttle", "nice", "-n", "19",
                         "gclient", "runhooks"],
            "gn": ["chromium_git/chromium/src/buildtools/mac/gn", "gen",
                   "out/Release_GN_arm64"],
            "build": ["taskpolicy", "-b", "nice", "-n", "19", "autoninja", "-j", "6",
                      "-k", "0", "-C", "out/Release_GN_arm64", "chrome_framework"],
        }

    def record_staged_scripts(self, scripts: pathlib.Path) -> None:
        self.receipt["inputs"]["stagedBuildScriptSha256"] = {
            path.name: sha256(path) for path in sorted(scripts.iterdir())
            if path.is_file() and not path.is_symlink()
        }

    @staticmethod
    def validate_staged_paths(scripts: pathlib.Path) -> None:
        if Runner.has_unadapted_home_paths(scripts):
            raise BuildError("unadapted home path in staged scripts")

    @staticmethod
    def has_unadapted_home_paths(scripts: pathlib.Path) -> bool:
        forbidden = ("~/chromium-build", "~/Documents/ardia", "$HOME")
        for path in sorted(scripts.iterdir()):
            if not path.is_file() or path.is_symlink():
                continue
            content = path.read_text(errors="replace")
            if any(marker in content for marker in forbidden):
                return True
        return False

    @staticmethod
    def checked_replace(path: pathlib.Path, old: str, new: str, count: int) -> None:
        text = path.read_text()
        actual = text.count(old)
        if actual != count:
            raise BuildError(f"script adaptation anchor mismatch in {path.name}: expected {count}, found {actual}")
        path.write_text(text.replace(old, new, count))

    @staticmethod
    def adapt_pinned_gn_script(path: pathlib.Path) -> None:
        old = 'gn gen "out/$GN_OUT_CONFIGS"'
        adapted = './buildtools/mac/gn gen "out/$GN_OUT_CONFIGS"'
        duplicated = './buildtools/mac/./buildtools/mac/gn gen "out/$GN_OUT_CONFIGS"'
        text = path.read_text()
        if duplicated in text:
            Runner.checked_replace(path, duplicated, adapted, 1)
            text = path.read_text()
        if re.search(r'(?m)^gn gen "out/\$GN_OUT_CONFIGS"$', text):
            Runner.checked_replace(path, old, adapted, 1)
            text = path.read_text()
        if not re.search(r'(?m)^\./buildtools/mac/gn gen "out/\$GN_OUT_CONFIGS"$', text):
            raise BuildError("pinned Chromium GN invocation adaptation anchor mismatch")

    @staticmethod
    def adapt_build_priority_script(path: pathlib.Path) -> None:
        old = "exec autoninja "
        incorrect = "exec lowprio autoninja "
        adapted = "exec taskpolicy -b nice -n 19 autoninja "
        text = path.read_text()
        if incorrect in text:
            Runner.checked_replace(path, incorrect, adapted, 1)
            text = path.read_text()
        if old in text:
            Runner.checked_replace(path, old, adapted, 1)
            text = path.read_text()
        if adapted not in text:
            raise BuildError("background QoS build invocation adaptation anchor mismatch")

    def verify_engine_tree(self, aria: pathlib.Path) -> None:
        tree = self.git("ardia-engine-tree", aria, "rev-parse", "HEAD:engine")
        expected = self.config["source"]["engineTree"]
        if tree != expected:
            raise BuildError(f"Ardia engine subtree mismatch: expected {expected}, got {tree}")
        self.receipt.setdefault("sources", {}).setdefault("ardia", {})["engineTree"] = tree
        self.save()

    def stage_ardia_source(self, aria: pathlib.Path) -> pathlib.Path:
        staged = self.output / "source/ardia-build"
        if staged.exists() or staged.is_symlink():
            assert_real_owned_path(staged, self.output)
            expected = self.receipt.get("inputs", {}).get("stagedArdiaSource", {})
            digest, count = tree_sha256(staged)
            if not expected or expected.get("treeSha256") != digest or expected.get("fileCount") != count:
                raise BuildError("existing staged Ardia source lacks matching owner receipt")
            return staged
        for current, directories, files in os.walk(aria, topdown=True, followlinks=False):
            for name in directories + files:
                if (pathlib.Path(current) / name).is_symlink():
                    raise BuildError(f"symlink rejected in pinned Ardia source: {pathlib.Path(current) / name}")
        shutil.copytree(aria, staged, ignore=shutil.ignore_patterns(".git"), symlinks=True)
        assert_real_owned_path(staged, self.output)
        series = staged / "engine/patches/series.py"
        self.checked_replace(
            series,
            'run([os.path.join(HERE, "build", "game-resource.sh")], HERE, check=True)',
            'run([os.path.join(os.environ["ENGINE_BUILD_ROOT"], "scripts", "game-resource.sh")], '
            'HERE, check=True)', 1)
        digest, count = tree_sha256(staged)
        self.receipt.setdefault("inputs", {})["stagedArdiaSource"] = {
            "path": str(staged.relative_to(self.output)),
            "treeSha256": digest,
            "fileCount": count,
            "scriptSubstitution": "Ardia game-resource call -> owned EngineSource/scripts/game-resource.sh",
        }
        self.save()
        return staged

    def prepare_sources(self) -> tuple[pathlib.Path, pathlib.Path]:
        aria = self.clone_pinned("source/ardia", self.config["source"]["repository"],
                                 self.config["source"]["commit"])
        self.verify_engine_tree(aria)
        series_file = aria / "engine/patches/series.py"
        errors = series_path_precondition_errors(read_text(series_file))
        if errors:
            raise BuildError("Ardia series path preconditions failed: " + "; ".join(errors))
        self.receipt["inputs"]["engineSeriesPathSourceSha256"] = sha256(series_file)
        self.receipt["inputs"]["seriesPathEnvironment"] = self.effective_commands()["seriesPathEnvironment"]
        self.save()
        self.clone_pinned("depot_tools", self.config["depotTools"]["repository"],
                          self.config["depotTools"]["commit"])
        ug = self.clone_pinned("ungoogled", self.config["ungoogled"]["repository"],
                               self.config["ungoogled"]["commit"])
        ugmac = self.clone_pinned("ungoogled-macos", self.config["ungoogled"]["macosRepository"],
                                  self.config["ungoogled"]["macosCommit"])
        self.receipt["sources"]["ungoogled"]["tag"] = self.config["ungoogled"]["tag"]
        self.receipt["sources"]["ungoogled-macos"] = {
            **self.receipt["sources"].get("ungoogled-macos", {}),
            "url": self.config["ungoogled"]["macosRepository"],
            "commit": self.config["ungoogled"]["macosCommit"],
            "tag": self.config["ungoogled"]["macosTag"],
            "tree": self.git("ungoogled-macos-tree", ugmac, "rev-parse", "HEAD^{tree}"),
        }
        self.receipt["sources"]["ungoogled"]["tag"] = self.config["ungoogled"]["tag"]
        self.receipt["inputs"] = {
            **self.receipt.get("inputs", {}),
            "patchSha256": sha256(self.repo / self.config["patch"]["file"]),
            "chromiumVersion": self.config["chromium"]["version"],
            "sisoVersion": self.config["chromium"]["sisoVersion"],
            "depotToolsCommit": self.config["depotTools"]["commit"],
            "ungoogledCommit": self.config["ungoogled"]["commit"],
            "ungoogledMacosCommit": self.config["ungoogled"]["macosCommit"],
        }
        self.save()
        staged_aria = self.stage_ardia_source(aria)
        return aria, self.stage_upstream_scripts(staged_aria)

    def source_stage(self, scripts: pathlib.Path, name: str, timeout: str) -> None:
        stage_timeout = self.config["build"]["timeoutsSeconds"][timeout]
        entry = scripts / name
        assert_real_owned_path(scripts, self.output)
        assert_real_owned_path(entry, self.output)
        if not entry.is_file():
            raise BuildError(f"required staged script is missing: {name}")
        if name == "01-sync.sh":
            for target in (self.output / "chromium_git", self.output / "series-base"):
                if target.exists() or target.is_symlink():
                    assert_real_owned_path(target, self.output)
        else:
            source_root = self.output / "chromium_git/chromium/src"
            if source_root.exists() or source_root.is_symlink():
                assert_real_owned_path(source_root, self.output)
            if name == "04-domain-substitution.sh":
                for target in (self.output / "series-base", self.output / "domsubcache.tar.gz"):
                    if target.exists() or target.is_symlink():
                        assert_real_owned_path(target, self.output)
                self.record_series_base_if_present()
        args = ["/bin/bash", str(entry)] if entry.suffix == ".sh" else [sys.executable, str(entry)]
        try:
            self.run(name.removesuffix(".sh").removesuffix(".py"), args,
                     self.output, stage_timeout)
        except Exception:
            if name == "04-domain-substitution.sh":
                self.record_series_base_if_present()
            raise
        if name == "04-domain-substitution.sh":
            self.record_series_base_if_present()

    def record_series_base_if_present(self) -> None:
        base = self.output / "series-base"
        if not base.exists() and not base.is_symlink():
            return
        assert_real_owned_path(base, self.output)
        if base.is_symlink() or not base.is_dir():
            raise BuildError("owned series base path rejected")
        for path in base.rglob("*"):
            assert_real_owned_path(path, self.output)
            if path.is_symlink() or (path.is_file() and path.stat().st_uid != os.getuid()):
                raise BuildError(f"unsafe owner or symlink in series base: {path}")
        digest, count = tree_sha256(base)
        prior = self.receipt.get("inputs", {}).get("seriesBase")
        if prior and (prior.get("treeSha256") != digest or prior.get("fileCount") != count):
            raise BuildError("owned series base changed after capture")
        capture_log_hash = None
        if not prior:
            stage = self.receipt.get("stages", {}).get("04-domain-substitution", {})
            attempts = stage.get("attempts", [])
            if attempts and attempts[-1].get("status") in ("failed", "succeeded"):
                log = self.output / attempts[-1]["log"]
                if log.is_file() and not log.is_symlink():
                    contents = log.read_text(errors="replace")
                    marker = f"captured {count} files into {base}"
                    if marker not in contents:
                        raise BuildError("series base lacks prior owned capture evidence")
                    capture_log_hash = sha256(log)
            if capture_log_hash is None and stage:
                raise BuildError("series base exists without owner capture receipt")
        self.receipt.setdefault("inputs", {})["seriesBase"] = {
            "path": str(base.relative_to(self.output)),
            "treeSha256": digest,
            "fileCount": count,
            "captureLogSha256": capture_log_hash or (prior or {}).get("captureLogSha256"),
        }
        self.save()

    def verify_chromium_checkout(self) -> pathlib.Path:
        chromium = self.output / "chromium_git/chromium/src"
        assert_real_owned_path(chromium, self.output)
        revision = self.git("chromium-source-revision", chromium, "rev-parse", "HEAD")
        expected = self.config["chromium"]["commit"]
        if revision != expected:
            raise BuildError(f"Chromium source commit mismatch: expected {expected}, got {revision}")
        tree = self.git("chromium-source-tree", chromium, "rev-parse", "HEAD^{tree}")
        self.receipt.setdefault("sources", {})["chromium"] = {
            "url": self.config["chromium"]["repository"],
            "tag": self.config["chromium"]["tag"],
            "commit": revision,
            "tree": tree,
        }
        self.save()
        return chromium

    def reset_partial_source_patch_output(self) -> None:
        chromium = self.verify_chromium_checkout()
        checkout_roots = []
        for current, directories, files in os.walk(chromium, topdown=True, followlinks=False):
            if ".git" in directories or ".git" in files:
                checkout = pathlib.Path(current)
                assert_real_owned_path(checkout, self.output)
                metadata = checkout / ".git"
                if metadata.is_symlink():
                    raise BuildError(f"git metadata symlink rejected: {metadata}")
                checkout_roots.append(checkout)
                if ".git" in directories:
                    directories.remove(".git")
        checkout_roots.sort(key=lambda path: len(path.parts), reverse=True)

        cache = self.output / "domsubcache.tar.gz"
        preserved_cache = None
        if cache.exists() or cache.is_symlink():
            assert_real_owned_path(cache, self.output)
            if cache.is_symlink() or not cache.is_file():
                raise BuildError("domain substitution cache path rejected during recovery")
            index = 1
            preserved = self.output / f"domsubcache.failed-before-resume-{index:02d}.tar.gz"
            while preserved.exists() or preserved.is_symlink():
                index += 1
                preserved = self.output / f"domsubcache.failed-before-resume-{index:02d}.tar.gz"
            assert_real_owned_path(preserved, self.output)
            preserved_cache = {"path": str(preserved.relative_to(self.output)),
                               "sha256": sha256(cache)}
            cache.rename(preserved)

        series_base = self.output / "series-base"
        preserved_series_base = None
        if series_base.exists() or series_base.is_symlink():
            assert_real_owned_path(series_base, self.output)
            if series_base.is_symlink() or not series_base.is_dir():
                raise BuildError("owned series base path rejected during recovery")
            digest, count = tree_sha256(series_base)
            prior = self.receipt.get("inputs", {}).get("seriesBase")
            if prior and (prior.get("treeSha256") != digest or prior.get("fileCount") != count):
                raise BuildError("owned series base changed before recovery")
            index = 1
            preserved = self.output / f"series-base.failed-before-resume-{index:02d}"
            while preserved.exists() or preserved.is_symlink():
                index += 1
                preserved = self.output / f"series-base.failed-before-resume-{index:02d}"
            assert_real_owned_path(preserved, self.output)
            preserved_series_base = {"path": str(preserved.relative_to(self.output)),
                                     "treeSha256": digest, "fileCount": count}
            series_base.rename(preserved)

        dirty_checkouts = []
        environment = self.child_environment()
        for index, checkout in enumerate(checkout_roots, start=1):
            head = subprocess.run(["/usr/bin/git", "-C", str(checkout), "rev-parse", "HEAD"],
                                  cwd=self.output, env=environment, capture_output=True,
                                  text=True, timeout=60, check=True).stdout.strip()
            status = subprocess.run(
                ["/usr/bin/git", "-C", str(checkout), "status", "--porcelain", "-z",
                 "--untracked-files=all"],
                cwd=self.output, env=environment, capture_output=True,
                timeout=60, check=True,
            ).stdout
            if not status:
                continue
            untracked = []
            for record in status.split(b"\0"):
                if not record.startswith(b"?? "):
                    continue
                relative = pathlib.Path(os.fsdecode(record[3:]))
                if relative.is_absolute() or ".." in relative.parts:
                    raise BuildError(f"unsafe untracked Ardia patch path: {relative}")
                candidate = checkout / relative
                assert_real_owned_path(candidate, self.output)
                info = candidate.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                    raise BuildError(f"unsafe untracked Ardia patch output: {relative}")
                untracked.append({"path": relative.as_posix(), "sha256": sha256(candidate)})
            if checkout == chromium and head != self.config["chromium"]["commit"]:
                raise BuildError("Chromium source revision changed before owned patch recovery")
            self.run(f"chromium-recovery-reset-{index:03d}",
                     ["/usr/bin/git", "-C", str(checkout), "reset", "--hard", head],
                     checkout, 300)
            for item in untracked:
                candidate = checkout / pathlib.PurePosixPath(item["path"])
                assert_real_owned_path(candidate, self.output)
                if candidate.is_symlink() or not candidate.is_file() or sha256(candidate) != item["sha256"]:
                    raise BuildError(f"untracked Ardia patch output changed before cleanup: {item['path']}")
                candidate.unlink()
            remaining = subprocess.run(
                ["/usr/bin/git", "-C", str(checkout), "status", "--porcelain", "-z",
                 "--untracked-files=all"],
                cwd=self.output, env=environment, capture_output=True,
                timeout=60, check=True,
            ).stdout
            if remaining:
                raise BuildError(f"owned Chromium checkout remains dirty after reset: {checkout}")
            dirty_checkouts.append({
                "path": str(checkout.relative_to(chromium)),
                "head": head,
                "untrackedRemoved": untracked,
            })
        self.receipt["inputs"]["partialPatchRecovery"] = {
            "chromiumCommit": self.config["chromium"]["commit"],
            "dirtyCheckoutsReset": dirty_checkouts,
            "preservedDomainCache": preserved_cache,
            "preservedSeriesBase": preserved_series_base,
        }
        self.save()

        for key in ("03-ungoogled", "04-domain-substitution"):
            record = self.receipt["stages"].get(key)
            if record:
                record["status"] = "recovery_required"
        self.save()

        environment = self.child_environment()
        environment["PATH"] = str(self.output / "depot_tools") + os.pathsep + environment["PATH"]
        self.run("chromium-recovery-runhooks", self.effective_commands()["runhooks"],
                 self.output / "chromium_git/chromium",
                 self.config["build"]["timeoutsSeconds"]["sync"], env=environment)

    def patch_overlay(self) -> None:
        chromium = self.output / "chromium_git/chromium/src"
        verify_source_preconditions(self.output / "source/ardia", chromium)
        patch = self.repo / self.config["patch"]["file"]
        reverse_args = ["/usr/bin/git", "-C", str(chromium), "apply", "--reverse", "--check", str(patch)]
        reverse = subprocess.run(reverse_args, cwd=self.output, env=self.child_environment(),
                                 capture_output=True, text=True,
                                 timeout=self.config["build"]["timeoutsSeconds"]["patches"])
        diagnostic = {
            "command": reverse_args,
            "cwd": str(self.output),
            "returnCode": reverse.returncode,
            "stdout": reverse.stdout,
            "stderr": reverse.stderr,
        }
        diagnostic_path = self.output / "logs/profile-patch-reverse-check.json"
        attempt = 1
        while diagnostic_path.exists() or diagnostic_path.is_symlink():
            attempt += 1
            diagnostic_path = self.output / f"logs/profile-patch-reverse-check.attempt-{attempt:02d}.json"
        assert_real_owned_path(diagnostic_path.parent, self.output)
        write_private_json(diagnostic_path, diagnostic)
        if reverse.returncode == 0:
            self.receipt["inputs"]["profilePatchState"] = "already-applied"
            self.receipt["inputs"]["profilePatchCheckPath"] = str(diagnostic_path.relative_to(self.output))
            self.receipt["inputs"]["profilePatchCheckSha256"] = sha256(diagnostic_path)
            self.receipt["inputs"]["profilePatchApplied"] = True
            self.receipt["inputs"]["chromiumRevision"] = self.git(
                "chromium-revision", chromium, "rev-parse", "HEAD")
            self.save()
            return
        self.receipt["inputs"]["profilePatchState"] = "not-applied"
        self.receipt["inputs"]["profilePatchCheckPath"] = str(diagnostic_path.relative_to(self.output))
        self.receipt["inputs"]["profilePatchCheckSha256"] = sha256(diagnostic_path)
        self.save()
        args = ["/usr/bin/git", "-C", str(chromium), "apply", "--check", str(patch)]
        self.run("profile-patch-check", args, self.output,
                 self.config["build"]["timeoutsSeconds"]["patches"])
        self.run("profile-patch-apply", ["/usr/bin/git", "-C", str(chromium), "apply", str(patch)],
                 self.output, self.config["build"]["timeoutsSeconds"]["patches"])
        self.receipt["inputs"]["profilePatchApplied"] = True
        self.receipt["inputs"]["chromiumRevision"] = self.git("chromium-revision", chromium, "rev-parse", "HEAD")
        self.save()

    def collect_sync_inputs(self) -> None:
        chromium = self.output / "chromium_git/chromium/src"
        self.run("gclient-revinfo", [str(self.output / "depot_tools/gclient"), "revinfo", "-a"],
                 chromium, self.config["build"]["timeoutsSeconds"]["sync"])
        gn_args = chromium / "out/Release_GN_arm64/args.gn"
        if gn_args.exists():
            self.receipt["inputs"]["gnArgsSha256"] = sha256(gn_args)
            self.receipt["inputs"]["gnArgs"] = gn_args.read_text()
        self.receipt["inputs"]["depsSha256"] = sha256(chromium / "DEPS")
        gclient_config = self.output / "chromium_git/chromium/.gclient"
        if gclient_config.is_file() and not gclient_config.is_symlink():
            self.receipt["inputs"]["gclientConfigSha256"] = sha256(gclient_config)
            self.receipt["inputs"]["gclientConfig"] = gclient_config.read_text()
        sync_log = self.output / "logs/01-sync.log"
        if sync_log.is_file() and not sync_log.is_symlink():
            self.receipt["inputs"]["syncLogSha256"] = sha256(sync_log)
        ensure_files = sorted(chromium.glob("**/*.ensure"))
        self.receipt["inputs"]["cipdEnsureFiles"] = {
            str(path.relative_to(chromium)): sha256(path)
            for path in ensure_files if path.is_file() and not path.is_symlink()
        }
        revinfo_log = self.output / "logs/gclient-revinfo.log"
        if revinfo_log.is_file() and not revinfo_log.is_symlink():
            self.receipt["inputs"]["gclientRevinfoLogSha256"] = sha256(revinfo_log)
        profiles = sorted(path for path in chromium.glob("**/*.profdata")
                          if path.is_file() and not path.is_symlink())
        if self.config["chromium"]["checkoutPgoProfiles"] and not profiles:
            raise BuildError("pinned PGO profile inputs were not found after sync")
        self.receipt["inputs"]["pgoProfiles"] = {
            str(path.relative_to(chromium)): sha256(path) for path in profiles
        }
        clang = chromium / "third_party/llvm-build/Release+Asserts/bin/clang"
        if not clang.is_file() or clang.is_symlink():
            raise BuildError("pinned Chromium clang toolchain is missing")
        clang_version = subprocess.run([str(clang), "--version"], capture_output=True,
                                       text=True, timeout=30, check=True).stdout.splitlines()[0]
        self.receipt["inputs"]["chromiumClang"] = {
            "path": str(clang.relative_to(chromium)),
            "sha256": sha256(clang),
            "version": clang_version,
        }
        gn = chromium / "buildtools/mac/gn"
        if not gn.is_file() or gn.is_symlink():
            raise BuildError("pinned Chromium GN binary is missing")
        gn_version = subprocess.run([str(gn), "--version"], capture_output=True,
                                    text=True, timeout=30, check=True,
                                    env=self.child_environment()).stdout.strip()
        gn_arch = subprocess.run(["/usr/bin/lipo", "-archs", str(gn)], capture_output=True,
                                 text=True, timeout=30, check=True).stdout.strip()
        if gn_arch != "arm64":
            raise BuildError(f"pinned Chromium GN architecture mismatch: {gn_arch}")
        self.receipt["inputs"]["chromiumGn"] = {
            "path": str(gn.relative_to(chromium)),
            "sha256": sha256(gn),
            "version": gn_version,
            "architecture": gn_arch,
        }
        self.save()

    def verify_metal_toolchain(self) -> None:
        """Verify current Apple Metal component and bind it into local provenance."""
        evidence_path = self.output / "logs/metal-toolchain-preflight.json"
        if evidence_path.exists() or evidence_path.is_symlink():
            assert_real_owned_path(evidence_path, self.output)
            if evidence_path.is_symlink() or not evidence_path.is_file() or evidence_path.stat().st_uid != os.getuid():
                raise BuildError("Metal Toolchain preflight evidence ownership rejected")
            evidence = json.loads(evidence_path.read_text())
            if evidence.get("owner") != owner_record(self.repo):
                raise BuildError("Metal Toolchain preflight evidence belongs to another output")
            expected = evidence.get("metalToolchain", {})
        else:
            expected = None

        def run(args: list[str]) -> subprocess.CompletedProcess:
            try:
                return subprocess.run(args, capture_output=True, text=True, timeout=30)
            except subprocess.TimeoutExpired as exc:
                raise BuildError(f"Metal Toolchain preflight timed out: {args[0]}") from exc

        component_result = run(["/usr/bin/xcodebuild", "-showComponent", "MetalToolchain", "-json"])
        if component_result.returncode:
            raise BuildError("cannot query installed Metal Toolchain component")
        try:
            component = json.loads(component_result.stdout)
        except json.JSONDecodeError as exc:
            raise BuildError("Metal Toolchain component metadata is invalid JSON") from exc
        if component.get("status") != "installed":
            raise BuildError("Metal Toolchain component is not installed")
        found = run(["/usr/bin/xcrun", "--find", "metal"])
        version = run(["/usr/bin/xcrun", "metal", "--version"])
        if found.returncode or version.returncode:
            raise BuildError("Metal compiler is unavailable in active Xcode toolchain")
        metal_path = found.stdout.strip()
        metal = pathlib.Path(metal_path)
        if metal.is_symlink() or not metal.is_file():
            raise BuildError("Metal compiler executable path is not a real file")
        real_path = metal.resolve(strict=True)
        verify_args = ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(metal)]
        verify = run(verify_args)
        display = run(["/usr/bin/codesign", "--display", "--verbose=4", str(metal)])
        if verify.returncode or display.returncode:
            raise BuildError("Metal compiler code signature verification failed")
        exported_asset = self.output / "logs/metal-toolchain-export-evidence.json"
        asset_path = None
        asset_sha256 = None
        if exported_asset.exists() or exported_asset.is_symlink():
            assert_real_owned_path(exported_asset, self.output)
            if exported_asset.is_symlink() or not exported_asset.is_file() or exported_asset.stat().st_uid != os.getuid():
                raise BuildError("Metal Toolchain export evidence ownership rejected")
            export_record = json.loads(exported_asset.read_text())
            if export_record.get("ownerReceipt") != owner_record(self.repo):
                raise BuildError("Metal Toolchain export evidence belongs to another output")
            asset_path = export_record.get("assetPath")
            asset_sha256 = export_record.get("assetSha256")
            if asset_path:
                asset = self.output / asset_path
                assert_real_owned_path(asset, self.output)
                if asset.is_symlink() or not asset.is_file() or sha256(asset) != asset_sha256:
                    raise BuildError("exported Metal Toolchain asset digest mismatch")
        actual = {
            "component": component,
            "metalPath": metal_path,
            "metalRealPath": str(real_path),
            "metalVersion": version.stdout.strip(),
            "metalSha256": sha256(real_path),
            "codesignVerifyReturnCode": verify.returncode,
            "codesignVerifyStdout": verify.stdout,
            "codesignVerifyStderr": verify.stderr,
            "codesignDisplay": display.stdout + display.stderr,
            "assetPath": asset_path,
            "assetSha256": asset_sha256,
            "commands": {
                "component": ["/usr/bin/xcodebuild", "-showComponent", "MetalToolchain", "-json"],
                "findMetal": ["/usr/bin/xcrun", "--find", "metal"],
                "metalVersion": ["/usr/bin/xcrun", "metal", "--version"],
                "signatureVerify": verify_args,
                "signatureDisplay": ["/usr/bin/codesign", "--display", "--verbose=4", str(metal)],
            },
        }
        if expected is not None:
            errors = metal_toolchain_precondition_errors(expected, actual)
            if errors:
                raise BuildError("Metal Toolchain changed after preflight: " + "; ".join(errors))
        else:
            evidence_path.parent.mkdir(mode=0o700, exist_ok=True)
            assert_real_owned_path(evidence_path.parent, self.output)
            write_private_json(evidence_path, {
                "schemaVersion": 1,
                "capturedAt": utc_now(),
                "owner": owner_record(self.repo),
                "metalToolchain": actual,
                "buildAttempt": None,
            })
        self.receipt.setdefault("inputs", {})["metalToolchain"] = {
            **actual,
            "preflightPath": str(evidence_path.relative_to(self.output)),
            "preflightSha256": sha256(evidence_path),
        }
        self.save()

    def validate_interrupted_build_inputs(self) -> None:
        """Bind incremental Ninja resume to the inputs recorded before reboot."""
        build = self.receipt.get("stages", {}).get("05-build", {})
        attempts = build.get("attempts", [])
        if not attempts or attempts[-1].get("status") not in ("running", "failed"):
            return
        chromium = self.verify_chromium_checkout()
        aria = self.output / "source/ardia"
        self.verify_engine_tree(aria)
        expected = self.receipt.get("inputs", {})
        if not expected.get("profilePatchApplied"):
            raise BuildError("interrupted build lacks applied profile patch receipt")
        patch = self.repo / self.config["patch"]["file"]
        if sha256(patch) != expected.get("patchSha256"):
            raise BuildError("profile patch changed after interrupted build")
        args_file = chromium / "out/Release_GN_arm64/args.gn"
        if (not args_file.is_file() or args_file.is_symlink() or
                sha256(args_file) != expected.get("gnArgsSha256") or
                args_file.read_text() != expected.get("gnArgs")):
            raise BuildError("GN args changed after interrupted build")
        for key, relative in (
                ("chromiumGn", "buildtools/mac/gn"),
                ("chromiumClang", "third_party/llvm-build/Release+Asserts/bin/clang")):
            record = expected.get(key, {})
            path = chromium / relative
            if (record.get("path") != relative or path.is_symlink() or not path.is_file() or
                    sha256(path) != record.get("sha256")):
                raise BuildError(f"{key} changed after interrupted build")
        if sha256(chromium / "DEPS") != expected.get("depsSha256"):
            raise BuildError("Chromium DEPS changed after interrupted build")
        ensure_hashes = {
            str(path.relative_to(chromium)): sha256(path)
            for path in sorted(chromium.glob("**/*.ensure"))
            if path.is_file() and not path.is_symlink()
        }
        if ensure_hashes != expected.get("cipdEnsureFiles"):
            raise BuildError("Chromium CIPD ensure inputs changed after interrupted build")
        profile_hashes = {
            str(path.relative_to(chromium)): sha256(path)
            for path in sorted(chromium.glob("**/*.profdata"))
            if path.is_file() and not path.is_symlink()
        }
        if profile_hashes != expected.get("pgoProfiles"):
            raise BuildError("Chromium PGO profiles changed after interrupted build")
        staged_hashes = expected.get("stagedBuildScriptSha256", {})
        scripts = self.output / "scripts"
        for name, digest in staged_hashes.items():
            path = scripts / name
            assert_real_owned_path(path, self.output)
            if path.is_symlink() or not path.is_file() or sha256(path) != digest:
                raise BuildError(f"staged upstream build input changed after interruption: {name}")
        command = ["/usr/bin/git", "-C", str(chromium), "apply", "--reverse", "--check", str(patch)]
        self.run("resume-profile-patch-check", command, self.output,
                 self.config["build"]["timeoutsSeconds"]["patches"])
        recorded_build = expected.get("effectiveCommands", {}).get("build")
        if recorded_build != self.effective_commands()["build"]:
            raise BuildError("effective Chromium build command changed after interruption")

    def bootstrap_depot_tools_python(self) -> None:
        depot_tools = self.output / "depot_tools"
        manifest_source = depot_tools / "bootstrap/manifest.txt"
        package = self.config["depotTools"]["pythonPackage"]
        version_tag = self.config["depotTools"]["pythonVersionTag"]
        version = version_tag.removeprefix("version:2@")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\.chromium\.[0-9]+", version):
            raise BuildError("depot_tools Python version pin malformed")
        expected_manifest = (
            "$VerifiedPlatform windows-amd64 windows-arm64 linux-amd64 mac-amd64 mac-arm64\n\n"
            "@Subdir python3\n"
            f"{package} {version_tag}\n"
        )
        original = manifest_source.read_text()
        if f"{version_tag}" not in original or ".bleeding_edge" in original:
            raise BuildError("pinned depot_tools Python manifest changed or is floating")
        manifest = self.output / "inputs/depot-tools-python.ensure"
        resolved = self.output / "inputs/depot-tools-python.resolved.ensure"
        bootstrap_root = depot_tools / f"bootstrap-{version}_bin"
        for path in (manifest, resolved, bootstrap_root):
            if path.exists() or path.is_symlink():
                assert_real_owned_path(path, self.output)
        manifest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if manifest.is_symlink() or resolved.is_symlink():
            raise BuildError("depot_tools bootstrap input symlink rejected")
        manifest.write_text(expected_manifest)
        os.chmod(manifest, 0o600)
        self.receipt.setdefault("inputs", {})["depotToolsPython"] = {
            "manifestPath": str(manifest.relative_to(self.output)),
            "manifestSha256": sha256(manifest),
            "sourceManifestSha256": sha256(manifest_source),
            "package": package,
            "versionTag": version_tag,
            "resolvedPath": str(resolved.relative_to(self.output)),
            "bootstrapRoot": str(bootstrap_root.relative_to(self.output)),
        }
        self.save()
        timeout = self.config["build"]["timeoutsSeconds"]["sync"]
        cipd = depot_tools / "cipd"
        self.run("depot-tools-python-cipd", self.depot_tools_python_ensure_args(
            cipd, manifest, resolved, bootstrap_root), self.output, timeout)
        if not resolved.is_file() or resolved.is_symlink():
            raise BuildError("pinned depot_tools Python CIPD resolution missing")
        resolved_text = resolved.read_text()
        if package not in resolved_text or not re.search(
                rf"{re.escape(package)}\s+([A-Za-z0-9_-]{{40,64}})\s*$", resolved_text):
            raise BuildError("pinned depot_tools Python did not resolve to an immutable instance")
        python = bootstrap_root / "python3/bin/python3"
        if not python.is_file():
            raise BuildError("pinned depot_tools Python executable missing after CIPD ensure")
        python_target = python.resolve(strict=True)
        try:
            python_target.relative_to(bootstrap_root.resolve(strict=True))
        except ValueError as exc:
            raise BuildError("pinned depot_tools Python executable escapes owned bootstrap root") from exc
        if python_target.stat().st_uid != os.getuid():
            raise BuildError("pinned depot_tools Python executable owner mismatch")
        bootstrap_args = self.depot_tools_python_bootstrap_args(
            python, depot_tools / "bootstrap/bootstrap.py", bootstrap_root.name)
        self.run("depot-tools-python-bootstrap", bootstrap_args, depot_tools, 300)
        relptr = depot_tools / "python3_bin_reldir.txt"
        if relptr.is_symlink() or not relptr.is_file() or relptr.read_text().strip() != (
                f"bootstrap-{version}_bin/python3/bin"):
            raise BuildError("depot_tools Python bootstrap pointer mismatch")
        self.run("depot-tools-python-version", [str(python), "--version"], depot_tools, 30)
        version_log = self.output / self.receipt["stages"]["depot-tools-python-version"]["attempts"][-1]["log"]
        self.receipt["inputs"]["depotToolsPython"].update({
            "resolvedSha256": sha256(resolved),
            "resolved": resolved_text,
            "pythonPath": str(python.relative_to(self.output)),
            "pythonSha256": sha256(python_target),
            "pythonTarget": str(python_target.relative_to(self.output)),
            "pythonVersion": version_log.read_text(errors="replace").strip(),
            "pointerPath": str(relptr.relative_to(self.output)),
            "pointerSha256": sha256(relptr),
        })
        self.save()

    def verify_depot_tools_python_cache(self) -> None:
        """Verify previously resolved CIPD Python without contacting CIPD."""
        record = self.receipt.get("inputs", {}).get("depotToolsPython", {})
        package = self.config["depotTools"]["pythonPackage"]
        version_tag = self.config["depotTools"]["pythonVersionTag"]
        expected_manifest = (
            "$VerifiedPlatform windows-amd64 windows-arm64 linux-amd64 mac-amd64 mac-arm64\n\n"
            "@Subdir python3\n"
            f"{package} {version_tag}\n"
        )
        manifest = self.output / record.get("manifestPath", "")
        resolved = self.output / record.get("resolvedPath", "")
        python = self.output / record.get("pythonPath", "")
        pointer = self.output / record.get("pointerPath", "")
        for path in (manifest, resolved, python.parent, pointer):
            assert_real_owned_path(path, self.output)
        if (record.get("package") != package or record.get("versionTag") != version_tag or
                manifest.is_symlink() or not manifest.is_file() or
                sha256(manifest) != record.get("manifestSha256") or
                manifest.read_text() != expected_manifest or
                resolved.is_symlink() or not resolved.is_file() or
                sha256(resolved) != record.get("resolvedSha256") or
                resolved.read_text() != record.get("resolved") or
                package not in record.get("resolved", "") or
                not re.search(rf"{re.escape(package)}\s+([A-Za-z0-9_-]{{40,64}})\s*$",
                              record.get("resolved", ""))):
            raise BuildError("pinned depot_tools Python cache receipt mismatch")
        version = version_tag.removeprefix("version:2@")
        bootstrap_root = self.output / f"depot_tools/bootstrap-{version}_bin"
        target_root = bootstrap_root.resolve(strict=True)
        try:
            target_root.relative_to(self.output.resolve(strict=True))
        except ValueError as exc:
            raise BuildError("pinned depot_tools Python cache escapes owned output") from exc
        if (python.is_symlink() and os.readlink(python) != "python3.11") or not python.is_file():
            raise BuildError("pinned depot_tools Python cache executable is missing")
        python_target = python.resolve(strict=True)
        try:
            python_target.relative_to(target_root)
        except ValueError as exc:
            raise BuildError("pinned depot_tools Python cache executable escapes bootstrap root") from exc
        if sha256(python_target) != record.get("pythonSha256"):
            raise BuildError("pinned depot_tools Python cache executable digest mismatch")
        expected_pointer = f"bootstrap-{version}_bin/python3/bin"
        if (pointer.is_symlink() or not pointer.is_file() or pointer.read_text().strip() != expected_pointer or
                sha256(pointer) != record.get("pointerSha256")):
            raise BuildError("pinned depot_tools Python cache pointer mismatch")
        stage = self.receipt.get("stages", {}).get("depot-tools-python-version", {})
        attempts = stage.get("attempts", [])
        if not attempts or attempts[-1].get("status") != "succeeded":
            raise BuildError("pinned depot_tools Python cache lacks a successful version receipt")
        version_log = self.output / attempts[-1].get("log", "")
        assert_real_owned_path(version_log, self.output)
        if (version_log.is_symlink() or not version_log.is_file() or
                sha256(version_log) != attempts[-1].get("logSha256") or
                version_log.read_text(errors="replace").strip() != record.get("pythonVersion")):
            raise BuildError("pinned depot_tools Python version log changed")

    @staticmethod
    def depot_tools_python_ensure_args(cipd: pathlib.Path, manifest: pathlib.Path,
                                       resolved: pathlib.Path, root: pathlib.Path) -> list[str]:
        return [str(cipd), "ensure", "-ensure-file", str(manifest), "-ensure-file-output",
                str(resolved), "-root", str(root), "-max-threads", "2",
                "-application-default-credentials", "never"]

    @staticmethod
    def depot_tools_python_bootstrap_args(python: pathlib.Path, script: pathlib.Path,
                                          bootstrap_name: str) -> list[str]:
        return [str(python), str(script), "--bootstrap-name", bootstrap_name]

    def collect_framework(self) -> None:
        out = self.output / "chromium_git/chromium/src/out/Release_GN_arm64"
        candidates = list(out.glob("**/Chromium Framework.framework/Versions/A/Chromium Framework"))
        candidates = [p for p in candidates if p.is_file() and not p.is_symlink()]
        if len(candidates) != 1:
            raise BuildError(f"expected one built Chromium Framework binary, found {len(candidates)}")
        binary = candidates[0]
        file_hashes = {}
        framework = binary.parents[2]
        for path in sorted(p for p in framework.rglob("*") if p.is_file() and not p.is_symlink()):
            file_hashes[str(path.relative_to(framework))] = sha256(path)
        arch = subprocess.run(["/usr/bin/lipo", "-archs", str(binary)], capture_output=True,
                              text=True, timeout=30, check=True).stdout.strip()
        if arch != "arm64":
            raise BuildError(f"built framework architecture mismatch: {arch}")
        build_info = subprocess.run(["/usr/bin/vtool", "-show-build", str(binary)],
                                    capture_output=True, text=True, timeout=30, check=True).stdout
        symbols = subprocess.run(["/usr/bin/nm", "-gU", str(binary)], capture_output=True,
                                 text=True, timeout=60, check=True).stdout.splitlines()
        exported = sorted({line.split()[-1].lstrip("_") for line in symbols if line.split()})
        required = ["ac_downloads_directory_get", "ac_downloads_directory_set"]
        missing = [symbol for symbol in required if symbol not in exported]
        if missing:
            raise BuildError(f"built framework lacks expected exports: {', '.join(missing)}")
        self.receipt["framework"] = {
            "path": str(binary.relative_to(self.output)),
            "sha256": sha256(binary),
            "fileSha256": file_hashes,
            "architecture": arch,
            "buildInfo": build_info,
            "minimumOS": sorted(set(re.findall(r"minos ([0-9.]+)", build_info))),
            "exports": exported,
            "requiredExports": required,
            "sourcePatchSha256": self.receipt["inputs"]["patchSha256"],
        }
        self.save()

    def execute(self) -> None:
        if sys.platform != "darwin" or self.host_inputs_arch() != "arm64":
            raise BuildError("source build requires Apple Silicon macOS")
        if self.receipt.get("status") == "succeeded":
            raise BuildError("this owned output already has a successful build receipt")
        previous_failure = self.receipt.pop("failure", None)
        if previous_failure:
            self.receipt.setdefault("failureHistory", []).append(previous_failure)
        self.receipt["status"] = "started"
        self.receipt["resumeStartedAt"] = utc_now()
        self.save()
        self.verify_metal_toolchain()
        self.prepare_git_lfs()
        aria, scripts = self.prepare_sources()
        self.validate_interrupted_build_inputs()
        ungoogled = self.receipt["stages"].get("03-ungoogled", {})
        domain = self.receipt["stages"].get("04-domain-substitution", {})
        ungoogled_attempts = ungoogled.get("attempts", [])
        domain_attempts = domain.get("attempts", [])
        previous_ungoogled_success = any(item.get("status") == "succeeded"
                                         for item in ungoogled_attempts)
        domain_failed = bool(domain_attempts) and not self.stage_succeeded(domain)
        ungoogled_failed_after_success = bool(ungoogled_attempts) and not self.stage_succeeded(ungoogled) and previous_ungoogled_success
        if domain_failed and self.stage_succeeded(ungoogled) or ungoogled_failed_after_success:
            self.reset_partial_source_patch_output()
        for stage in EXECUTION_STAGE_NAMES:
            stage_key = stage.removesuffix(".sh").removesuffix(".py")
            prior = self.receipt["stages"].get(stage_key, {})
            attempts = prior.get("attempts", [])
            if self.stage_succeeded(prior):
                if stage == "01-sync.sh":
                    self.verify_chromium_checkout()
                continue
            if stage == "03-ungoogled.py":
                self.verify_chromium_checkout()
            if stage == "profile-patch":
                self.patch_overlay()
            elif stage == "01-sync.sh":
                self.source_stage(scripts, stage, "sync")
            elif stage in ("03-ungoogled.py", "04-domain-substitution.sh"):
                self.source_stage(scripts, stage, "patches")
            elif stage == "02-gn-args.sh":
                self.source_stage(scripts, stage, "gn")
                self.collect_sync_inputs()
            elif stage == "05-build.sh":
                if self.stage_succeeded(self.receipt["stages"].get("depot-tools-python-version", {})):
                    self.verify_depot_tools_python_cache()
                else:
                    self.bootstrap_depot_tools_python()
                self.source_stage(scripts, stage, "build")
            else:
                raise BuildError(f"unknown pinned stage: {stage}")
        self.collect_framework()
        self.receipt["status"] = "succeeded"
        self.receipt["finishedAt"] = utc_now()
        self.save()

    def host_inputs_arch(self) -> str:
        return self.receipt["host"]["architecture"]


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="run pinned source preparation and build")
    args = parser.parse_args(argv)
    repo = pathlib.Path(__file__).resolve().parents[1]
    try:
        config = load_config(repo)
        if not args.run:
            print(json.dumps({"output": config["build"]["output"], "pins": config,
                              "execution": "opt-in; pass --run"}, indent=2))
            return 0
        output, _ = prepare_owned_output(repo)
        runner = Runner(repo, output, config)
        try:
            runner.execute()
        except Exception as exc:
            runner.receipt["status"] = "failed"
            runner.receipt["failure"] = {"type": type(exc).__name__, "message": str(exc),
                                          "at": utc_now()}
            runner.receipt["finishedAt"] = utc_now()
            runner.save()
            raise
        finally:
            runner.close()
        print(f"Build receipt: {output / RECEIPT_FILE}")
        return 0
    except (BuildError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"build-engine-source: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
