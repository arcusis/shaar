#!/usr/bin/env python3
"""Build an ignored, pinned local Swift package for native development."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import plistlib
import stat
import shutil
import subprocess
import signal
import time
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/SDKCache/bitwarden-sdk-5cf9198'
OUTPUT = ROOT / 'build/NativeBitwardenSDK'
RUNNER = ROOT / 'scripts/test-native-bitwarden-lifecycle.py'
ORG_OUTPUT = ROOT / 'build/OrganizationSDKPackage'
ORG_PIN = ROOT / 'ThirdParty/BitwardenSyncSpike/organization-sdk-package.pin.json'
ORG_PIN_SHA256 = 'f8428c821c558732f59155b398b38a55f1a3263e29fc59a423ad6bcb371986e0'
REFRESH_ROOT = ROOT / 'build/NativeBitwardenRefreshSDK'
REFRESH_PIN = ROOT / 'ThirdParty/BitwardenRefreshSpike/sdk-package.pin.json'
REFRESH_PIN_SHA256 = '1b5e8a0a2d6e0e447d049e740aaa6107733280332a69ddc8fec4b254f32a9869'
BOUNDED_ROOT = ROOT / 'build/NativeBitwardenRefreshSDK7'
BOUNDED_PIN = ROOT / 'ThirdParty/BitwardenRefreshSpike/bounded-sdk-package.pin.json'
BOUNDED_PIN_SHA256 = '6c4ec0eb96a3311ef209838aa75b3962c925f2a9b600d12852296b0fc42fcdb1'
DEADLINE_CANDIDATE = ROOT / 'ThirdParty/BitwardenRefreshSpike/deadline.candidate.json'
DEADLINE_CANDIDATE_SHA256 = 'df2c8a5018a2b88edf5e4c5b8f7745488cdea87989413f22144952a00e3100cf'
ORG_PATCH_ORDER = ('ThirdParty/BitwardenAuthSpike/identity-mfa.patch',
                   'ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch',
                   'ThirdParty/BitwardenSyncSpike/sync.patch',
                   'ThirdParty/BitwardenSyncSpike/organization-keys.patch',
                   'ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch')
REFRESH_PATCH_ORDER = ORG_PATCH_ORDER + ('ThirdParty/BitwardenRefreshSpike/refresh.patch',)
BOUNDED_PATCH_ORDER = REFRESH_PATCH_ORDER + ('ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch',)
SDK_PACKAGE_SWIFT = '// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "ArcusisBitwardenSDK", platforms: [.macOS("26.0")], products: [.library(name: "ArcusisBitwardenSDK", targets: ["ArcusisBitwardenSDK"])], targets: [.binaryTarget(name: "BitwardenSDK", path: "Frameworks/BitwardenSDK.xcframework"), .target(name: "BitwardenFFI", path: "Sources/BitwardenFFI", publicHeadersPath: "include"), .target(name: "BitwardenSdkSupport", path: "Sources/BitwardenSdkSupport"), .target(name: "ArcusisBitwardenSDK", dependencies: ["BitwardenSDK", "BitwardenFFI", "BitwardenSdkSupport"], path: "Sources/ArcusisBitwardenSDK")])\n'
SDK_FFI_SHIM = 'void arcusis_bitwarden_ffi_link_anchor(void) {}\n'
LOG_DIR: Path | None = None
COMMANDS: list[list[str]] = []


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_runner():
    spec = importlib.util.spec_from_file_location('native_lifecycle', RUNNER)
    if spec is None or spec.loader is None:
        raise ValueError('accepted lifecycle validator unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_output_path(owned_root: Path, out: Path) -> None:
    if any(path.is_symlink() for path in (ROOT, owned_root, out.parent, out)) or out.parent != owned_root or not out.is_relative_to(owned_root):
        raise ValueError('output outside owned build directory')
    if out.exists() or out.is_symlink() or not owned_root.is_dir():
        raise ValueError('output must be fresh beneath existing build directory')

def validate_cache_path(target: Path) -> None:
    if target.exists() or target.is_symlink() or any(path.is_symlink() for path in target.parents):
        raise ValueError('Rust cache must be fresh and task-owned')

def safe_tree(root: Path) -> list[Path]:
    if root.is_symlink() or not root.is_dir():
        raise ValueError('package input missing or symlinked')
    result = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('package input contains symlink')
        if path.is_file():
            result.append(path)
        elif not path.is_dir():
            raise ValueError('package input contains special file')
    return result


def validate_package(root: Path, manifest: dict, *, organization: bool = False, refresh: bool = False, bounded: bool = False, expected_dylib: str | None = None) -> None:
    if root.is_symlink() or not root.is_dir():
        raise ValueError('unsafe output directory')
    root = root.resolve(strict=True)
    if refresh or bounded:
        manifest_path = root / 'build-manifest.json'
        if manifest_path.is_symlink() or not manifest_path.is_file() or json.loads(manifest_path.read_text()) != manifest:
            raise ValueError('refresh on-disk manifest mismatch')
    if sum((organization, refresh, bounded)) > 1:
        raise ValueError('candidate modes are mutually exclusive')
    if organization or refresh or bounded:
        pin = read_bounded_pin() if bounded else (read_refresh_pin() if refresh else read_organization_pin())
        expected_fields = {'schema', 'sourceCommit', 'sourceGitTree', 'sourceCargoLockSHA256',
                           'candidateCargoLockSHA256', 'patchSHA256', 'changedPaths',
                           'sourceManifestSHA256', 'fullDiffSHA256', 'bindingTreeSHA256',
                           'generatedModuleNames', 'licenseSHA256', 'supportSHA256', 'dylibSHA256',
                           'minMacOS', 'architecture', 'accepted', 'integration_ready', 'fileSHA256'}
        if refresh or bounded:
            expected_fields |= {'candidateGitTree', 'rustToolchain'}
        if set(manifest) != expected_fields or type(manifest.get('schema')) is not int or manifest['schema'] != 1:
            raise ValueError('organization manifest shape invalid')
        for key in ('sourceCommit', 'sourceGitTree', 'sourceCargoLockSHA256', 'candidateCargoLockSHA256',
                    'patchSHA256', 'changedPaths', 'sourceManifestSHA256', 'fullDiffSHA256',
                    'licenseSHA256', 'supportSHA256', 'minMacOS', 'architecture', 'accepted', 'integration_ready'):
            if type(manifest.get(key)) is not type(pin[key]) or manifest[key] != pin[key]:
                raise ValueError('organization manifest pin mismatch: ' + key)
        if refresh or bounded:
            for key in ('candidateGitTree', 'rustToolchain'):
                if manifest.get(key) != pin[key]:
                    raise ValueError('refresh manifest pin mismatch: ' + key)
        if (not expected_dylib or manifest.get('dylibSHA256') != expected_dylib
                or ((refresh or bounded) and expected_dylib != pin['sourceProofDylibSHA256'])):
            raise ValueError('candidate dylib provenance mismatch')
    else:
        runner = load_runner()
        if manifest.get('sourceCommit') != runner.SOURCE_COMMIT:
            raise ValueError('manifest source pin mismatch')
        if manifest.get('sourceGitTree') != runner.SOURCE_TREE:
            raise ValueError('manifest source Git tree mismatch')
        if manifest.get('sourceCargoLockSHA256') != runner.SOURCE_LOCK_SHA or manifest.get('candidateCargoLockSHA256') != runner.CANDIDATE_LOCK_SHA:
            raise ValueError('manifest Cargo.lock pin mismatch')
        if manifest.get('patchSHA256') != runner.PATCH_SHAS:
            raise ValueError('manifest patch digest mismatch')
        changed = manifest.get('changedPaths')
        if not isinstance(changed, list) or len(changed) != 22 or len(set(changed)) != 22 or set(changed) != runner.CHANGED_PATHS:
            raise ValueError('manifest changed-path result mismatch')
    swift = root / 'Sources/ArcusisBitwardenSDK'
    support = root / 'Sources/BitwardenSdkSupport'
    ffi = root / 'Sources/BitwardenFFI/include'
    framework = root / 'Frameworks/BitwardenSDK.xcframework'
    files = safe_tree(swift) + safe_tree(support) + safe_tree(ffi)
    if not any(p.suffix == '.swift' for p in files):
        raise ValueError('generated Swift bindings missing')
    maps = [p for p in files if p.name.endswith('.modulemap')]
    headers = [p for p in files if p.suffix == '.h']
    framework_files = safe_tree(framework)
    if not maps or not headers or not framework_files:
        raise ValueError('modulemap, header, or XCFramework input incomplete')
    expected = manifest.get('bindingTreeSHA256')
    if not isinstance(expected, str) or expected != tree_digest(swift):
        raise ValueError('generated binding digest mismatch')
    if refresh or bounded:
        text = '\n'.join(p.read_text() for p in safe_tree(swift) if p.suffix == '.swift')
        for declaration in ('func refreshPasswordManagerToken(', 'func syncWithOutcome(',
                            'func sync(force:', 'enum SyncOutcome:', 'enum RefreshError:'):
            if declaration not in text:
                raise ValueError('refresh generated API missing')
    modules = []
    import re
    for path in maps:
        text = path.read_text(encoding='utf-8')
        modules.extend(re.findall(r'\bmodule\s+([A-Za-z_][A-Za-z0-9_]*)', text))
        named_headers = re.findall(r'\bheader\s+"([^"]+)"', text)
        if not named_headers or any(Path(name).is_absolute() or '..' in Path(name).parts
                                    or not (path.parent / name).is_file() for name in named_headers):
            raise ValueError('modulemap does not name included header')
    if not modules or sorted(set(modules)) != manifest.get('generatedModuleNames'):
        raise ValueError('generated module names mismatch')
    support_path = support / 'NaiveDateFormatter.swift'
    if manifest.get('supportSHA256') != digest(support_path):
        raise ValueError('support source digest mismatch')
    license_files = safe_tree(root / 'ThirdPartyNotices')
    if manifest.get('licenseSHA256') != {p.name: digest(p) for p in license_files}:
        raise ValueError('license inventory or digest mismatch')
    dylibs = [p for p in framework_files if p.name == 'libbitwarden_uniffi.dylib']
    if (len(dylibs) != 1 or 'macos-arm64' not in dylibs[0].parts
            or manifest.get('dylibSHA256') != digest(dylibs[0])):
        raise ValueError('XCFramework dylib digest mismatch')
    files_in_package = safe_tree(root)
    payload = {p.relative_to(root).as_posix(): digest(p) for p in files_in_package
               if p.relative_to(root).as_posix() != 'build-manifest.json'}
    if manifest.get('fileSHA256') != payload:
        raise ValueError('package inventory or artifact digest mismatch')
    if organization or refresh or bounded:
        generated = pin['generatedSHA256']
        swift_expected = {name: value for name, value in generated.items() if name.endswith('.swift')}
        header_expected = {name: value for name, value in generated.items() if name.endswith('.h')}
        if {p.name: digest(p) for p in safe_tree(swift)} != swift_expected:
            raise ValueError('organization generated Swift inventory mismatch')
        if {p.name: digest(p) for p in headers} != header_expected:
            raise ValueError('organization generated header inventory mismatch')
        if digest(ffi / 'module.modulemap') != pin['combinedModuleMapSHA256']:
            raise ValueError('organization modulemap inventory mismatch')
        expected_paths = {'Package.swift', 'Sources/BitwardenFFI/shim.c',
                          'Sources/BitwardenFFI/include/module.modulemap',
                          'Sources/BitwardenSdkSupport/NaiveDateFormatter.swift',
                          'Frameworks/BitwardenSDK.xcframework/Info.plist',
                          'Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib',
                          'Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers/module.modulemap'}
        expected_paths |= {'Sources/ArcusisBitwardenSDK/' + n for n in swift_expected}
        expected_paths |= {'Sources/BitwardenFFI/include/' + n for n in header_expected}
        expected_paths |= {'Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers/' + n for n in header_expected}
        expected_paths |= {'ThirdPartyNotices/' + n for n in pin['licenseSHA256']}
        if set(payload) != expected_paths:
            raise ValueError('organization package path inventory mismatch')
        expected_dirs = {parent.as_posix() for name in expected_paths for parent in Path(name).parents if parent.as_posix() != '.'}
        actual_dirs = {path.relative_to(root).as_posix() for path in root.rglob('*') if path.is_dir()}
        if actual_dirs != expected_dirs:
            raise ValueError('organization package directory inventory mismatch')
        if ((root / 'Package.swift').read_text() != SDK_PACKAGE_SWIFT
                or (root / 'Sources/BitwardenFFI/shim.c').read_text() != SDK_FFI_SHIM):
            raise ValueError('organization package contract mismatch')
        framework_headers = root / 'Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers'
        if ({p.name: digest(p) for p in safe_tree(framework_headers)}
                != (header_expected | {'module.modulemap': pin['combinedModuleMapSHA256']})):
            raise ValueError('organization framework header mismatch')
        expected_info = {'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64',
                          'LibraryPath': 'libbitwarden_uniffi.dylib', 'HeadersPath': 'Headers',
                          'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'macos'}],
                         'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}
        if (root / 'Frameworks/BitwardenSDK.xcframework/Info.plist').read_bytes() != plistlib.dumps(expected_info, sort_keys=True):
            raise ValueError('organization XCFramework contract mismatch')


def tree_digest(root: Path) -> str:
    h = hashlib.sha256()
    for path in safe_tree(root):
        h.update(path.relative_to(root).as_posix().encode() + b'\0')
        h.update(bytes.fromhex(digest(path)) + b'\n')
    return h.hexdigest()


def process_group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_owned_group(proc: subprocess.Popen[str], grace: float = 5.0) -> None:
    # start_new_session makes proc.pid the process-group/session ID. Reap its
    # leader before checking the group, so its zombie cannot keep group alive.
    pgid = proc.pid
    # A live leader anchors the captured group ID. If it already exited, only
    # signal while surviving members still keep that captured group allocated.
    if proc.poll() is None or process_group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        # Live leader still anchors original group ID, so it cannot be recycled.
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
    deadline = time.monotonic() + 5.0
    while process_group_exists(pgid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if process_group_exists(pgid):
        # Reaped leader leaves only descendants in its owned group. Signal once,
        # then observe; never send another signal after possible group-ID reuse.
        if process_group_exists(pgid):
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5.0
        while process_group_exists(pgid) and time.monotonic() < deadline:
            time.sleep(0.05)
    if process_group_exists(pgid):
        raise RuntimeError('owned process group survived SIGKILL')


def command(argv: list[str], cwd: Path, env: dict[str, str], timeout: int = 3600, log_dir: Path | None = None, *, cleanup_success: bool = False) -> str:
    COMMANDS.append(list(argv))
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    stdout = stderr = ''
    failure = None
    try:
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate_owned_group(proc)
            # Drain after descendants are gone; inherited pipes can no longer hold open.
            stdout, stderr = proc.communicate()
            failure = RuntimeError(f'{Path(argv[0]).name} timed out; owned process group terminated and reaped')
        if failure is None and proc.returncode:
            terminate_owned_group(proc)
            failure = RuntimeError(f'{Path(argv[0]).name} failed ({proc.returncode}): {(stderr or stdout)[-4000:]}')
        elif failure is None and cleanup_success:
            terminate_owned_group(proc)
    finally:
        if log_dir is None:
            log_dir = LOG_DIR
        if log_dir is not None:
            log_dir.mkdir(parents=True, exist_ok=True)
            name = f'{len(list(log_dir.glob("*.log"))):03d}-{Path(argv[0]).name}.log'
            (log_dir/name).write_text((stdout + '\n' + stderr)[-65536:])
    if failure is not None:
        raise failure
    return stdout


def read_organization_pin() -> dict:
    if ORG_PIN.is_symlink() or not ORG_PIN.is_file() or digest(ORG_PIN) != ORG_PIN_SHA256:
        raise ValueError('organization package pin missing or changed')
    pin = json.loads(ORG_PIN.read_text())
    keys = {'schema', 'accepted', 'integration_ready', 'repository', 'sourceCommit', 'sourceGitTree',
            'sourceCargoLockSHA256', 'candidateCargoLockSHA256', 'fullDiffSHA256', 'sourceManifestSHA256',
            'sourceManifestEntries', 'patchSHA256', 'changedPaths', 'rustToolchain', 'target', 'minMacOS',
            'architecture', 'sourceProofDylibSHA256', 'sourceProofBindgenSHA256', 'generatedSHA256',
            'supportSHA256', 'licenseSHA256', 'combinedModuleMapSHA256'}
    if (not isinstance(pin, dict) or set(pin) != keys or type(pin['schema']) is not int or pin['schema'] != 1
            or pin['accepted'] is not False or pin['integration_ready'] is not False
            or len(pin['changedPaths']) != 31 or len(set(pin['changedPaths'])) != 31
            or set(pin['patchSHA256']) != set(ORG_PATCH_ORDER) or pin['sourceManifestEntries'] != 2356):
        raise ValueError('organization package pin invalid')
    for name, expected in pin['patchSHA256'].items():
        path = ROOT / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError('organization prerequisite patch mismatch')
    return pin


def source_manifest(root: Path) -> tuple[str, int]:
    if root.is_symlink() or not root.is_dir():
        raise ValueError('unsafe source tree')
    rows = []
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        here = Path(current)
        if here != root and '.git' in dirs:
            raise ValueError('nested source git directory')
        dirs[:] = sorted(d for d in dirs if d != '.git')
        for name in sorted(dirs + files):
            path = here / name
            rel = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                rows.append({'path': rel, 'kind': 'symlink', 'target': os.readlink(path)})
            elif stat.S_ISREG(mode):
                rows.append({'path': rel, 'kind': 'file', 'executable': bool(mode & 0o111), 'sha256': digest(path)})
            elif not stat.S_ISDIR(mode):
                raise ValueError('unsupported source entry')
    rows.sort(key=lambda row: row['path'])
    data = ''.join(json.dumps(row, sort_keys=True, separators=(',', ':')) + '\n' for row in rows).encode()
    return hashlib.sha256(data).hexdigest(), len(rows)


def generated_inventory(root: Path) -> dict[str, str]:
    files = safe_tree(root)
    if any(p.parent != root for p in files):
        raise ValueError('unexpected nested generated artifact')
    return {p.name: digest(p) for p in files}


def validate_organization_source(root: Path, pin: dict) -> None:
    if source_manifest(root) != (pin['sourceManifestSHA256'], pin['sourceManifestEntries']):
        raise ValueError('organization source manifest mismatch')
    if digest(root / 'Cargo.lock') != pin['candidateCargoLockSHA256']:
        raise ValueError('organization source lock mismatch')
    if digest(root / 'crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift') != pin['supportSHA256']:
        raise ValueError('organization support source mismatch')
    if {name: digest(root / name) for name in pin['licenseSHA256']} != pin['licenseSHA256']:
        raise ValueError('organization license source mismatch')


def validate_organization_cache(root: Path, pin: dict) -> None:
    if root.is_symlink() or not root.is_dir() or root.resolve() != root.absolute():
        raise ValueError('organization cache root unsafe')
    sdk, generated, target, cargo_home = (root / name for name in ('sdk-frozen', 'generated-final', 'target-frozen', 'cargo-home'))
    validate_organization_source(sdk, pin)
    if generated_inventory(generated) != pin['generatedSHA256']:
        raise ValueError('proof binding, header or modulemap mismatch')
    for path in (target / 'debug/libbitwarden_uniffi.dylib', target / 'debug/deps/libbitwarden_uniffi.dylib'):
        if path.is_symlink() or digest(path) != pin['sourceProofDylibSHA256']:
            raise ValueError('proof dylib mismatch')
    if digest(target / 'debug/uniffi-bindgen') != pin['sourceProofBindgenSHA256']:
        raise ValueError('proof bindgen mismatch')
    if not (cargo_home / 'registry').is_dir():
        raise ValueError('offline Cargo cache missing')
    for cache in (cargo_home, target):
        if cache.is_symlink() or not cache.is_dir() or any(p.is_symlink() for p in cache.rglob('*')):
            raise ValueError('offline Cargo cache contains symlink')


def organization_command(argv: list[str], cwd: Path, env: dict[str, str], timeout: int = 3600) -> str:
    return command(argv, cwd, env, timeout, cleanup_success=True)


def stage_generated_sources(sdk: Path, generated: Path, pkg: Path) -> list[Path]:
    maps = sorted(generated.glob('*.modulemap'))
    headers = sorted(generated.glob('*.h'))
    swift_files = sorted(generated.glob('*.swift'))
    if not maps or not headers or not swift_files:
        raise ValueError('UniFFI output missing Swift, modulemap, or headers')
    swift = pkg / 'Sources/ArcusisBitwardenSDK'
    ffi = pkg / 'Sources/BitwardenFFI/include'
    support = pkg / 'Sources/BitwardenSdkSupport'
    for directory in (swift, ffi, support):
        directory.mkdir(parents=True)
    for path in swift_files:
        shutil.copy2(path, swift / path.name)
    for path in headers:
        shutil.copy2(path, ffi / path.name)
    shutil.copy2(sdk / 'crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift', support / 'NaiveDateFormatter.swift')
    (pkg / 'Sources/BitwardenFFI/shim.c').write_text(SDK_FFI_SHIM)
    (ffi / 'module.modulemap').write_text('\n'.join(path.read_text() for path in maps) + '\n')
    return maps


def read_refresh_pin() -> dict:
    if REFRESH_PIN.is_symlink() or not REFRESH_PIN.is_file() or digest(REFRESH_PIN) != REFRESH_PIN_SHA256:
        raise ValueError('refresh package pin missing or changed')
    pin = json.loads(REFRESH_PIN.read_text())
    org = read_organization_pin()
    keys = set(org) | {'candidateGitTree'}
    if set(pin) != keys or type(pin['schema']) is not int or pin['schema'] != 1:
        raise ValueError('refresh pin shape invalid')
    expected = {
        'accepted': False, 'integration_ready': False,
        'sourceCommit': '5cf919837e83b71c2508bf99344ea57cf5f84e88',
        'sourceGitTree': '9af9432aefeed6796e40e5019ffdc8600f3381e9',
        'candidateGitTree': '64151eb07bdbe0bba1b48aeeea6a8b1add2c4ac9',
        'sourceManifestSHA256': 'd1e886cf81c67de7c83a04bfed4b3ff37cb51042c4df28b52e521a4251457112',
        'sourceManifestEntries': 2356,
        'fullDiffSHA256': '30271199b7ccd006fcb5c25afa48148e816f0d65e00772c0e7677db6875598cf',
        'rustToolchain': '1.98.0', 'target': 'aarch64-apple-darwin',
        'architecture': 'arm64', 'minMacOS': '26.0',
    }
    for key, value in expected.items():
        if type(pin.get(key)) is not type(value) or pin[key] != value:
            raise ValueError('refresh pin mismatch: ' + key)
    for key in ('repository', 'sourceCargoLockSHA256', 'candidateCargoLockSHA256', 'supportSHA256', 'licenseSHA256'):
        if pin[key] != org[key]:
            raise ValueError('refresh prerequisite pin mismatch: ' + key)
    patches = dict(org['patchSHA256'])
    patches[REFRESH_PATCH_ORDER[-1]] = 'dbbade935ba424c56bbbe788ff87403c8404af1bd733a1e9a0175f34b836b6e8'
    if pin['patchSHA256'] != patches or len(pin['changedPaths']) != 35 or len(set(pin['changedPaths'])) != 35:
        raise ValueError('refresh patch or path pin mismatch')
    for name in REFRESH_PATCH_ORDER:
        path = ROOT / name
        if path.is_symlink() or not path.is_file() or digest(path) != patches[name]:
            raise ValueError('refresh patch mismatch')
    return pin


def read_bounded_pin() -> dict:
    if BOUNDED_PIN.is_symlink() or not BOUNDED_PIN.is_file() or digest(BOUNDED_PIN) != BOUNDED_PIN_SHA256:
        raise ValueError('bounded package pin missing or changed')
    if (DEADLINE_CANDIDATE.is_symlink() or not DEADLINE_CANDIDATE.is_file()
            or digest(DEADLINE_CANDIDATE) != DEADLINE_CANDIDATE_SHA256):
        raise ValueError('deadline candidate missing or changed')
    pin = json.loads(BOUNDED_PIN.read_text())
    candidate = json.loads(DEADLINE_CANDIDATE.read_text())
    prior = read_refresh_pin()
    if not isinstance(pin, dict) or set(pin) != set(prior):
        raise ValueError('bounded package pin shape invalid')
    fixed = {
        'candidateGitTree': '0a934e609b3dfef012a3477d2973ace834b1a1c2',
        'sourceManifestSHA256': 'a07d87fa57dc49dd53fadc2924c2ad4b9764ae61a708a872b7e8b16bf625ec79',
        'sourceManifestEntries': 2356,
        'fullDiffSHA256': '2dd1ac8411b2285ca214345161d6865d46dee1b868bc8f82bf49716d02ff4588',
    }
    for key, value in fixed.items():
        if type(pin.get(key)) is not type(value) or pin[key] != value:
            raise ValueError('bounded pin mismatch: ' + key)
    import re
    if (not isinstance(pin.get('sourceProofDylibSHA256'), str)
            or not re.fullmatch(r'[0-9a-f]{64}', pin['sourceProofDylibSHA256'])
            or pin['sourceProofDylibSHA256'] == prior['sourceProofDylibSHA256']):
        raise ValueError('bounded dylib pin invalid')
    changed = sorted(set(prior['changedPaths']) | {'crates/bitwarden-api-base/src/client.rs'})
    patches = dict(prior['patchSHA256'])
    patches[BOUNDED_PATCH_ORDER[-1]] = '8ec29eb0694c0624788922950b878d05e324dc344fbcfb5d44f34f307b862b87'
    if pin['changedPaths'] != changed or pin['patchSHA256'] != patches:
        raise ValueError('bounded patch or path mismatch')
    for key in set(prior) - set(fixed) - {'changedPaths', 'patchSHA256', 'sourceProofDylibSHA256'}:
        if type(pin[key]) is not type(prior[key]) or pin[key] != prior[key]:
            raise ValueError('bounded prerequisite mismatch: ' + key)
    patch = ROOT / BOUNDED_PATCH_ORDER[-1]
    if patch.is_symlink() or not patch.is_file() or digest(patch) != patches[BOUNDED_PATCH_ORDER[-1]]:
        raise ValueError('deadline patch mismatch')
    if (candidate.get('accepted') is not False or candidate.get('compiled') is not False
            or candidate.get('integration_ready') is not False or candidate.get('sevenLayerTree') != pin['candidateGitTree']
            or candidate.get('sixLayerTree') != prior['candidateGitTree']
            or candidate.get('patchSHA256') != patches[BOUNDED_PATCH_ORDER[-1]]
            or candidate.get('sourceManifestSHA256') != pin['sourceManifestSHA256']
            or candidate.get('fullDiffSHA256') != pin['fullDiffSHA256']
            or candidate.get('nativeConnectTimeoutSeconds') != 10
            or candidate.get('nativeTotalTimeoutSeconds') != 30):
        raise ValueError('deadline candidate mismatch')
    return pin


def refresh_command(argv: list[str], cwd: Path, env: dict[str, str], timeout: int = 3600) -> str:
    # Command output is retained only in memory; failures expose no subprocess output.
    try:
        return command(argv, cwd, env, timeout, cleanup_success=True)
    except Exception:
        raise ValueError('refresh command failed: ' + Path(argv[0]).name) from None


def validate_refresh_source(sdk: Path, pin: dict, env: dict[str, str]) -> None:
    validate_organization_source(sdk, pin)
    git = lambda *args: refresh_command(['git', '-C', str(sdk), *args], ROOT, env, 120)
    if git('write-tree').strip() != pin['candidateGitTree']:
        raise ValueError('refresh source index tree mismatch')
    git('diff', '--quiet')
    if git('ls-files', '--others', '--exclude-standard').strip():
        raise ValueError('refresh source untracked files')
    if git('rev-parse', pin['sourceCommit'] + '^{tree}').strip() != pin['sourceGitTree']:
        raise ValueError('refresh base tree mismatch')
    diff = git('diff', '--binary', pin['sourceCommit'], pin['candidateGitTree'])
    if hashlib.sha256(diff.encode()).hexdigest() != pin['fullDiffSHA256']:
        raise ValueError('refresh full diff mismatch')
    if git('diff', '--name-only', pin['sourceCommit'], pin['candidateGitTree']).splitlines() != pin['changedPaths']:
        raise ValueError('refresh changed path mismatch')


def validate_refresh_reused_generator(bindgen: Path, pin: dict) -> str:
    if bindgen.is_symlink() or not bindgen.is_file() or digest(bindgen) != pin['sourceProofBindgenSHA256']:
        raise ValueError('refresh reused generator provenance mismatch')
    return digest(bindgen)


def build_refresh_generator(sdk: Path, target: Path, generated: Path, dylib: Path,
                            pin: dict, env: dict[str, str], common: list[str]) -> tuple[str, list[list[str]]]:
    bindgen = target / pin['target'] / 'release/uniffi-bindgen'
    if (target.is_symlink() or not target.is_dir() or target.resolve() != target.absolute()
            or any(path.is_symlink() for path in (bindgen.parent, bindgen.parent.parent))):
        raise ValueError('fresh refresh target unsafe')
    if bindgen.exists() or bindgen.is_symlink() or generated.exists() or generated.is_symlink():
        raise ValueError('fresh refresh generator or output already exists')
    build = ['cargo', '+1.98.0', 'build', *common, '--package', 'uniffi-bindgen']
    refresh_command(build, sdk, env)
    if bindgen.is_symlink() or not bindgen.is_file() or not os.access(bindgen, os.X_OK):
        raise ValueError('fresh refresh generator missing or unsafe')
    generator_sha = digest(bindgen)
    generated.mkdir()
    generate = [str(bindgen), 'generate', str(dylib), '--language', 'swift', '--no-format', '--out-dir', str(generated)]
    refresh_command(generate, sdk, env, 900)
    if bindgen.is_symlink() or digest(bindgen) != generator_sha:
        raise ValueError('fresh refresh generator changed during execution')
    return generator_sha, [build, generate]


def refresh_main(args: argparse.Namespace) -> int:
    global LOG_DIR
    LOG_DIR = None
    pin = read_bounded_pin()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('requires arm64 macOS')
    env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR') if key in os.environ}
    rust = refresh_command(['rustc', '+1.98.0', '-vV'], ROOT, env, 30)
    if not rust.startswith('rustc 1.98.0 (88d9e12ae 2026-08-18)\n') or 'host: aarch64-apple-darwin\n' not in rust:
        raise ValueError('refresh Rust toolchain mismatch')
    out = BOUNDED_ROOT
    sdk = out / 'source'
    target = out / 'target'
    generated = out / 'generated'
    pkg = out / 'Package'
    dylib = target / pin['target'] / 'release/libbitwarden_uniffi.dylib'
    bindgen = target / pin['target'] / 'release/uniffi-bindgen'
    if args.refresh_stage_existing_proof:
        if not out.is_dir() or out.is_symlink() or pkg.exists() or pkg.is_symlink():
            raise ValueError('refresh proof stage output unsafe')
    else:
        validate_output_path(ROOT / 'build', out)
        out.mkdir(mode=0o700)
        source = args.source.expanduser().absolute()
        if source.is_symlink() or not source.is_dir():
            raise ValueError('refresh upstream source unsafe')
        refresh_command(['git', 'clone', '--local', '--no-hardlinks', '--no-checkout', str(source), str(sdk)], ROOT, env, 120)
        refresh_command(['git', '-C', str(sdk), 'checkout', '--detach', pin['sourceCommit']], ROOT, env, 60)
        for name in BOUNDED_PATCH_ORDER:
            refresh_command(['git', '-C', str(sdk), 'apply', '--check', '--whitespace=error', str(ROOT / name)], ROOT, env, 60)
            refresh_command(['git', '-C', str(sdk), 'apply', '--whitespace=error', str(ROOT / name)], ROOT, env, 60)
        refresh_command(['git', '-C', str(sdk), 'add', '-A'], ROOT, env, 60)
        validate_refresh_source(sdk, pin, env)
        validate_cache_path(target)
        build_env = dict(env, CARGO_TARGET_DIR=str(target), CARGO_BUILD_JOBS='2', CARGO_NET_OFFLINE='true',
                         MACOSX_DEPLOYMENT_TARGET='26.0', RUSTUP_AUTO_INSTALL='0', RUSTUP_NO_UPDATE_CHECK='1',
                         RUSTFLAGS='-C link-arg=-mmacosx-version-min=26.0 --cfg bitwarden_ensure_non_commercial')
        common = ['--offline', '--locked', '--release', '--jobs', '2', '--manifest-path', str(sdk / 'Cargo.toml'), '--target', pin['target']]
        refresh_command(['cargo', '+1.98.0', 'rustc', *common, '--package', 'bitwarden-uniffi', '--', '-C',
                         'link-arg=-Wl,-install_name,@rpath/libbitwarden_uniffi.dylib'], sdk, build_env)
        if dylib.is_symlink() or not dylib.is_file() or digest(dylib) != pin['sourceProofDylibSHA256']:
            raise ValueError('fresh refresh dylib provenance mismatch')
        generator_sha, generator_recipe = build_refresh_generator(sdk, target, generated, dylib, pin, build_env, common)
    validate_refresh_source(sdk, pin, env)
    if target.is_symlink() or not target.is_dir() or target.resolve() != target.absolute():
        raise ValueError('refresh target unsafe')
    if any(p.is_symlink() or not p.is_file() for p in (dylib, bindgen)):
        raise ValueError('refresh release artifacts missing or unsafe')
    if digest(dylib) != pin['sourceProofDylibSHA256']:
        raise ValueError('refresh release dylib provenance mismatch')
    if args.refresh_stage_existing_proof:
        generator_sha = validate_refresh_reused_generator(bindgen, pin)
        generator_recipe = []
        generator_environment = {}
        generator_provenance = 'pinned-reused-proof'
    else:
        generator_provenance = 'fresh-source-build'
        generator_environment = {key: build_env[key] for key in ('CARGO_BUILD_JOBS', 'CARGO_NET_OFFLINE',
                                  'MACOSX_DEPLOYMENT_TARGET', 'RUSTFLAGS', 'RUSTUP_AUTO_INSTALL', 'RUSTUP_NO_UPDATE_CHECK')}
        if digest(bindgen) != generator_sha:
            raise ValueError('fresh refresh generator changed after execution')
    if generated_inventory(generated) != pin['generatedSHA256']:
        raise ValueError('refresh generated bindings mismatch')
    import re
    if refresh_command(['otool', '-D', str(dylib)], ROOT, env, 30).splitlines()[1:] != ['@rpath/libbitwarden_uniffi.dylib']:
        raise ValueError('refresh dylib install name mismatch')
    if (refresh_command(['lipo', '-archs', str(dylib)], ROOT, env, 30).strip() != 'arm64'
            or not re.search(r'minos\s+26\.0(?:\s|$)', refresh_command(['vtool', '-show-build', str(dylib)], ROOT, env, 30))):
        raise ValueError('refresh dylib platform mismatch')
    maps = stage_generated_sources(sdk, generated, pkg)
    ffi = pkg / 'Sources/BitwardenFFI/include'
    notices = pkg / 'ThirdPartyNotices'; notices.mkdir()
    for name in pin['licenseSHA256']:
        shutil.copy2(sdk / name, notices / name)
    framework = pkg / 'Frameworks/BitwardenSDK.xcframework'; library = framework / 'macos-arm64'
    (library / 'Headers').mkdir(parents=True)
    shutil.copy2(dylib, library / 'libbitwarden_uniffi.dylib')
    for path in safe_tree(ffi):
        shutil.copy2(path, library / 'Headers' / path.name)
    info = {'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64', 'LibraryPath': 'libbitwarden_uniffi.dylib',
                                    'HeadersPath': 'Headers', 'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'macos'}],
            'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    (pkg / 'Package.swift').write_text(SDK_PACKAGE_SWIFT)
    swift = pkg / 'Sources/ArcusisBitwardenSDK'
    modules = sorted(set(m for path in maps for m in re.findall(r'\bmodule\s+([A-Za-z_][A-Za-z0-9_]*)', path.read_text())))
    keys = ('sourceCommit', 'sourceGitTree', 'candidateGitTree', 'sourceCargoLockSHA256', 'candidateCargoLockSHA256',
            'patchSHA256', 'changedPaths', 'sourceManifestSHA256', 'fullDiffSHA256', 'licenseSHA256', 'supportSHA256',
            'rustToolchain', 'minMacOS', 'architecture', 'accepted', 'integration_ready')
    manifest = {key: pin[key] for key in keys}
    manifest.update(schema=1, bindingTreeSHA256=tree_digest(swift), generatedModuleNames=modules, dylibSHA256=digest(dylib))
    manifest['fileSHA256'] = {p.relative_to(pkg).as_posix(): digest(p) for p in safe_tree(pkg)}
    (pkg / 'build-manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    validate_package(pkg, manifest, bounded=True, expected_dylib=pin['sourceProofDylibSHA256'])
    consumer = out / 'consumer'; (consumer / 'Sources/sdk-consumer').mkdir(parents=True)
    (consumer / 'Package.swift').write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "SDKConsumer", platforms: [.macOS("26.0")], dependencies: [.package(path: '+json.dumps(str(pkg))+')], targets: [.executableTarget(name: "sdk-consumer", dependencies: [.product(name: "ArcusisBitwardenSDK", package: "Package")])])\n')
    shutil.copy2(ROOT / 'Tests/NativeBitwardenRefreshPackageProbe/main.swift', consumer / 'Sources/sdk-consumer/Probe.swift')
    scratch = out / 'swift-build'; cache = out / 'swift-cache'; cache.mkdir()
    swift_env = dict(env, CLANG_MODULE_CACHE_PATH=str(out / 'clang-cache'))
    common_swift = ['swift', 'build', '--jobs', '2', '--package-path', str(consumer), '--scratch-path', str(scratch), '--cache-path', str(cache), '--disable-dependency-cache']
    refresh_command(common_swift + ['--product', 'sdk-consumer', '-Xlinker', '-rpath', '-Xlinker', str(library)], out, swift_env, 900)
    bin_path = Path(refresh_command(common_swift + ['--show-bin-path'], out, swift_env, 60).strip())
    executable = bin_path / 'sdk-consumer'
    if executable.is_symlink() or not executable.is_file():
        raise ValueError('refresh Swift consumer missing')
    if not re.search(r'minos\s+26\.0(?:\s|$)', refresh_command(['vtool', '-show-build', str(executable)], out, env, 30)):
        raise ValueError('refresh consumer minimum macOS mismatch')
    loads = refresh_command(['otool', '-L', str(executable)], out, env, 30)
    rpaths = refresh_command(['otool', '-l', str(executable)], out, env, 30)
    if '@rpath/libbitwarden_uniffi.dylib' not in loads or not re.search(
            r'cmd LC_RPATH\s+cmdsize \d+\s+path ' + re.escape(str(library)) + r' \(offset \d+\)', rpaths):
        raise ValueError('refresh consumer rpath mismatch')
    if refresh_command([str(executable)], out, env, 60).strip() != 'SDK_REFRESH_CANDIDATE_OK':
        raise ValueError('refresh consumer smoke failed')
    validate_refresh_source(sdk, pin, env)
    if (bindgen.is_symlink() or digest(bindgen) != generator_sha or digest(dylib) != pin['sourceProofDylibSHA256']
            or generated_inventory(generated) != pin['generatedSHA256']):
        raise ValueError('refresh build artifacts changed after validation')
    validate_package(pkg, manifest, bounded=True, expected_dylib=pin['sourceProofDylibSHA256'])
    receipt = {'schema': 1, 'accepted': False, 'integration_ready': False, 'consumerSmoke': 'SDK_REFRESH_CANDIDATE_OK',
               'sourceGitTree': pin['candidateGitTree'], 'rustToolchain': pin['rustToolchain'],
               'dylibSHA256': pin['sourceProofDylibSHA256'], 'packageTreeSHA256': tree_digest(pkg),
               'bindgenSHA256': generator_sha, 'bindgenProvenance': generator_provenance,
               'bindgenRecipe': generator_recipe, 'bindgenBuildEnvironment': generator_environment,
               'bindgenWorkingDirectory': str(sdk)}
    (out / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    return 0


def organization_main(args: argparse.Namespace) -> int:
    global LOG_DIR
    pin = read_organization_pin()
    if args.candidate_cache is None:
        raise ValueError('organization candidate requires explicit --candidate-cache')
    cache = args.candidate_cache.expanduser().absolute()
    out = (args.output or ORG_OUTPUT).expanduser().absolute()
    owned = ROOT / 'build'
    owned.mkdir(mode=0o700, exist_ok=True)
    validate_output_path(owned, out)
    if out == OUTPUT or cache == out or cache in out.parents or out in cache.parents:
        raise ValueError('organization output must be separate from accepted package and cache')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('requires arm64 macOS')
    runner = load_runner()
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'SDKROOT', 'RUSTUP_HOME') if k in os.environ}
    runner.read_pin(False)
    source, _ = runner.verify_source(args.source.absolute(), env, {'commands': []})
    # Lifecycle validator checks tracked files; candidate requires a genuinely clean source.
    if organization_command(['git', '-C', str(source), 'status', '--porcelain=v1', '--untracked-files=all'], ROOT, env, 30).strip():
        raise ValueError('organization upstream source must be clean')
    runner.check_toolchain(env, {'commands': []})
    validate_organization_cache(cache, pin)
    out.mkdir(mode=0o700)
    LOG_DIR = out / 'logs'
    work = out / 'work'
    work.mkdir(mode=0o700)
    sdk = work / 'sdk'
    organization_command(['git', 'clone', '--local', '--no-hardlinks', '--no-checkout', str(source), str(sdk)], ROOT, env, 120)
    organization_command(['git', '-C', str(sdk), 'checkout', '--detach', pin['sourceCommit']], ROOT, env, 30)
    for name in ORG_PATCH_ORDER:
        patch = ROOT / name
        organization_command(['git', '-C', str(sdk), 'apply', '--check', '--whitespace=error', str(patch)], ROOT, env, 30)
        organization_command(['git', '-C', str(sdk), 'apply', '--whitespace=error', str(patch)], ROOT, env, 60)
    paths = sorted(line[3:] for line in organization_command(['git', '-C', str(sdk), 'status', '--porcelain=v1', '--untracked-files=all'], ROOT, env, 30).splitlines())
    if paths != pin['changedPaths']:
        raise ValueError('organization changed paths mismatch')
    organization_command(['git', '-C', str(sdk), 'add', '-N', '-A'], ROOT, env, 30)
    diff = organization_command(['git', '-C', str(sdk), 'diff', '--binary', 'HEAD'], ROOT, env, 30)
    if hashlib.sha256(diff.encode()).hexdigest() != pin['fullDiffSHA256']:
        raise ValueError('organization layered diff mismatch')
    validate_organization_source(sdk, pin)
    cargo_home, target = out / 'cargo-home', out / 'cargo-target'
    validate_cache_path(cargo_home); validate_cache_path(target)
    organization_command(['cp', '-cR', str(cache / 'cargo-home'), str(cargo_home)], ROOT, env, 600)
    organization_command(['cp', '-cR', str(cache / 'target-frozen'), str(target)], ROOT, env, 600)
    tmp = out / 'tmp'; tmp.mkdir(mode=0o700)
    home = out / 'home'; home.mkdir(mode=0o700)
    build_env = dict(env, HOME=str(home), RUSTUP_HOME=env.get('RUSTUP_HOME', str(Path.home() / '.rustup')),
                     CARGO_HOME=str(cargo_home), CARGO_TARGET_DIR=str(target), TMPDIR=str(tmp),
                     RUSTUP_TOOLCHAIN=pin['rustToolchain'], RUSTUP_AUTO_INSTALL='0', RUSTUP_NO_UPDATE_CHECK='1',
                     CARGO_BUILD_JOBS='2', CARGO_NET_OFFLINE='true', MACOSX_DEPLOYMENT_TARGET='26.0',
                     CARGO_TERM_COLOR='never', RUSTFLAGS='-C link-arg=-mmacosx-version-min=26.0 --cfg bitwarden_ensure_non_commercial')
    common = ['--offline', '--locked', '--jobs', '2', '--manifest-path', str(sdk / 'Cargo.toml'), '--target', pin['target']]
    organization_command(['cargo', 'rustc', *common, '--package', 'bitwarden-uniffi', '--', '-C',
             'link-arg=-Wl,-install_name,@rpath/libbitwarden_uniffi.dylib'], sdk, build_env)
    dylib = target / pin['target'] / 'debug/libbitwarden_uniffi.dylib'
    dylib_sha = digest(dylib)
    import re
    identity = organization_command(['otool', '-D', str(dylib)], work, env, 30).splitlines()
    if len(identity) != 2 or identity[1].strip() != '@rpath/libbitwarden_uniffi.dylib':
        raise ValueError('organization dylib install name mismatch')
    if (organization_command(['lipo', '-archs', str(dylib)], work, env, 30).strip() != 'arm64'
            or not re.search(r'minos\s+26\.0(?:\s|$)', organization_command(['vtool', '-show-build', str(dylib)], work, env, 30))):
        raise ValueError('organization dylib platform mismatch')
    generated = work / 'GeneratedSwift'; generated.mkdir()
    organization_command(['cargo', 'run', *common, '--package', 'uniffi-bindgen', '--', 'generate', str(dylib),
             '--language', 'swift', '--no-format', '--out-dir', str(generated)], sdk, build_env, 900)
    if digest(dylib) != dylib_sha or generated_inventory(generated) != pin['generatedSHA256']:
        raise ValueError('organization bindings or dylib differ from frozen interfaces')
    validate_organization_source(sdk, pin)
    pkg = out / 'Package'
    maps = stage_generated_sources(sdk, generated, pkg)
    swift = pkg / 'Sources/ArcusisBitwardenSDK'; ffi = pkg / 'Sources/BitwardenFFI/include'
    support = pkg / 'Sources/BitwardenSdkSupport'; notices = pkg / 'ThirdPartyNotices'
    notices.mkdir()
    for name in pin['licenseSHA256']: shutil.copy2(sdk / name, notices / name)
    framework = pkg / 'Frameworks/BitwardenSDK.xcframework'; library = framework / 'macos-arm64'
    (library / 'Headers').mkdir(parents=True)
    shutil.copy2(dylib, library / 'libbitwarden_uniffi.dylib')
    for path in safe_tree(ffi): shutil.copy2(path, library / 'Headers' / path.name)
    info = {'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64', 'LibraryPath': 'libbitwarden_uniffi.dylib',
                                    'HeadersPath': 'Headers', 'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'macos'}],
            'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    (pkg / 'Package.swift').write_text(SDK_PACKAGE_SWIFT)
    modules = sorted(set(m for path in maps for m in re.findall(r'\bmodule\s+([A-Za-z_][A-Za-z0-9_]*)', path.read_text())))
    manifest = {key: pin[key] for key in ('sourceCommit', 'sourceGitTree', 'sourceCargoLockSHA256', 'candidateCargoLockSHA256', 'patchSHA256', 'changedPaths', 'sourceManifestSHA256', 'fullDiffSHA256', 'licenseSHA256', 'supportSHA256', 'minMacOS', 'architecture', 'accepted', 'integration_ready')}
    manifest.update(schema=1, bindingTreeSHA256=tree_digest(swift), generatedModuleNames=modules, dylibSHA256=dylib_sha)
    manifest['fileSHA256'] = {p.relative_to(pkg).as_posix(): digest(p) for p in safe_tree(pkg)}
    (pkg / 'build-manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    validate_package(pkg, manifest, organization=True, expected_dylib=dylib_sha)
    consumer = work / 'consumer'; (consumer / 'Sources/sdk-consumer').mkdir(parents=True)
    (consumer / 'Package.swift').write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "SDKConsumer", platforms: [.macOS("26.0")], dependencies: [.package(path: '+json.dumps(str(pkg))+')], targets: [.executableTarget(name: "sdk-consumer", dependencies: [.product(name: "ArcusisBitwardenSDK", package: "Package")])])\n')
    (consumer / 'Sources/sdk-consumer/main.swift').write_text('import ArcusisBitwardenSDK\nimport Foundation\nfinal class EmptyTokens: ClientManagedTokens { func getAccessToken() async -> String? { nil } }\n@main struct Smoke { static func main() async throws { let client = Client(tokenProvider: EmptyTokens(), settings: nil, managedSettings: ManagedSettingsBindingClient()); await client.requireFreshOrganizationSync(); let snapshot = client.sync().encryptedSnapshot(); guard snapshot.generation == 0 && snapshot.organizationKeys.isEmpty else { fatalError("unexpected snapshot") }; client.crypto().clearUserCryptoKeys(); print("SDK_ORGANIZATION_CANDIDATE_OK") } }\n')
    swift_env = dict(build_env, CLANG_MODULE_CACHE_PATH=str(tmp / 'clang-cache'))
    scratch = out / 'swift-build'; swift_cache = out / 'swift-cache'; swift_cache.mkdir()
    organization_command(['swift', 'build', '--package-path', str(consumer), '--scratch-path', str(scratch), '--cache-path', str(swift_cache), '--disable-dependency-cache', '--product', 'sdk-consumer', '-Xlinker', '-rpath', '-Xlinker', str(library)], work, swift_env, 900)
    bin_path = Path(organization_command(['swift', 'build', '--package-path', str(consumer), '--scratch-path', str(scratch), '--cache-path', str(swift_cache), '--disable-dependency-cache', '--show-bin-path'], work, swift_env, 60).strip())
    executable = bin_path / 'sdk-consumer'
    if executable.is_symlink() or not executable.is_file(): raise ValueError('organization SwiftPM consumer missing')
    if not re.search(r'minos\s+26\.0(?:\s|$)', organization_command(['vtool', '-show-build', str(executable)], work, env, 30)):
        raise ValueError('organization consumer minimum macOS mismatch')
    smoke = organization_command([str(executable)], work, {'PATH': env.get('PATH', ''), 'HOME': str(home), 'TMPDIR': str(tmp)}, 60)
    if smoke.strip() != 'SDK_ORGANIZATION_CANDIDATE_OK': raise ValueError('organization typed consumer smoke failed')
    validate_package(pkg, manifest, organization=True, expected_dylib=dylib_sha)
    validate_organization_source(sdk, pin)
    validate_organization_cache(cache, pin)
    if digest(dylib) != dylib_sha or generated_inventory(generated) != pin['generatedSHA256']:
        raise ValueError('organization build inputs changed')
    receipt = {'schema': 1, 'status': 'built', 'accepted': False, 'integration_ready': False,
               'sourceManifestSHA256': pin['sourceManifestSHA256'], 'fullDiffSHA256': pin['fullDiffSHA256'],
               'dylibSHA256': dylib_sha, 'packageTreeSHA256': tree_digest(pkg), 'consumerSmoke': smoke.strip(),
               'commercialExclusion': True, 'architecture': 'arm64', 'minMacOS': '26.0', 'commands': COMMANDS}
    (out / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--organization-candidate', action='store_true')
    parser.add_argument('--refresh-candidate', action='store_true')
    parser.add_argument('--refresh-stage-existing-proof', action='store_true')
    parser.add_argument('--candidate-cache', type=Path)
    args = parser.parse_args()
    if args.refresh_candidate:
        if args.organization_candidate or args.candidate_cache is not None or args.output is not None:
            raise ValueError('refresh candidate uses only its fixed owned paths')
        return refresh_main(args)
    if args.refresh_stage_existing_proof:
        raise ValueError('refresh proof staging requires refresh-candidate mode')
    if args.organization_candidate:
        return organization_main(args)
    if args.candidate_cache is not None:
        raise ValueError('candidate cache requires organization-candidate mode')
    if args.output is None:
        args.output = OUTPUT
    COMMANDS.clear()
    out = args.output.expanduser().absolute()
    owned_root = ROOT / 'build'
    if owned_root.is_symlink() or out.parent != owned_root or not out.is_relative_to(owned_root):
        raise ValueError('output must be direct child of owned build directory')
    owned_root.mkdir(mode=0o700, exist_ok=True)
    validate_output_path(owned_root,out)
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('requires arm64 macOS')
    if out.exists() or out.is_symlink() or not out.parent.is_dir():
        raise ValueError('output must be fresh beneath existing build directory')
    runner = load_runner()
    env = {k: os.environ[k] for k in ('PATH','HOME','TMPDIR','DEVELOPER_DIR','SDKROOT','RUSTUP_HOME','CARGO_HOME') if k in os.environ}
    pin, patches = runner.read_pin(False)
    source, _ = runner.verify_source(args.source.absolute(), env, {'commands': []})
    runner.check_toolchain(env, {'commands': []})
    out.mkdir(mode=0o700)
    global LOG_DIR
    LOG_DIR = out / 'logs'
    work = Path(tempfile.mkdtemp(prefix='.native-sdk-', dir=out.parent))
    try:
        sdk = work / 'sdk'
        command(['git','clone','--local','--no-hardlinks','--no-checkout',str(source),str(sdk)], ROOT, env, 120)
        command(['git','-C',str(sdk),'checkout','--detach',runner.SOURCE_COMMIT], ROOT, env, 30)
        for name in ('auth','clear','sync'):
            patch = patches[name]
            command(['git','-C',str(sdk),'apply','--check','--whitespace=error',str(patch)], ROOT, env, 30)
            command(['git','-C',str(sdk),'apply','--whitespace=error',str(patch)], ROOT, env, 60)
        changes = command(['git','-C',str(sdk),'status','--porcelain=v1','--untracked-files=all'], ROOT, env, 30)
        paths = {line[3:] for line in changes.splitlines() if len(line) > 3}
        if paths != runner.CHANGED_PATHS or len(paths) != 22:
            raise ValueError('composed SDK result differs from exact 22-path pin')
        if digest(sdk/'Cargo.lock') != runner.CANDIDATE_LOCK_SHA:
            raise ValueError('composed Cargo.lock digest mismatch')
        target = out/'cargo-target'
        validate_cache_path(target)
        target.mkdir(mode=0o700, exist_ok=True)
        build_env = dict(env, CARGO_TARGET_DIR=str(target), RUSTUP_TOOLCHAIN=runner.TOOLCHAIN,
                         CARGO_BUILD_JOBS='2', CARGO_NET_OFFLINE='true', MACOSX_DEPLOYMENT_TARGET='26.0',
                         CARGO_TERM_COLOR='never', RUSTFLAGS='-C link-arg=-mmacosx-version-min=26.0 --cfg bitwarden_ensure_non_commercial')
        common = ['--offline','--locked','--manifest-path',str(sdk/'Cargo.toml'),'--target',runner.TARGET]
        command(['cargo','build',*common,'--package','bitwarden-uniffi'], sdk, build_env)
        dylib=target/runner.TARGET/'debug/libbitwarden_uniffi.dylib'
        generated=work/'GeneratedSwift'; generated.mkdir()
        command(['cargo','run',*common,'--package','uniffi-bindgen','--','generate',str(dylib),'--language','swift','--no-format','--out-dir',str(generated)],sdk,build_env,900)
        # All generated SDK interfaces remain in the existing package layout.
        pkg=out/'Package'
        modulemaps=stage_generated_sources(sdk, generated, pkg)
        staged=pkg/'Frameworks/BitwardenSDK.xcframework'
        staged.parent.mkdir(parents=True)
        dylib_copy=work/'libbitwarden_uniffi.dylib'; shutil.copy2(dylib,dylib_copy)
        command(['install_name_tool','-id','@rpath/libbitwarden_uniffi.dylib',str(dylib_copy)],work,env,30)
        command(['codesign','--force','--sign','-',str(dylib_copy)],work,env,30)
        # XCFramework creation wraps dylib and generated C interface as a binary target.
        command(['xcodebuild','-create-xcframework','-library',str(dylib_copy),'-headers',str(pkg/'Sources/BitwardenFFI/include'),'-output',str(staged)],work,env,120)
        modules=[]
        for p in modulemaps:
            import re
            modules.extend(re.findall(r'\bmodule\s+([A-Za-z_][A-Za-z0-9_]*)',p.read_text()))
        if not modules: raise ValueError('generated module names absent')
        modules=sorted(set(modules))
        notices=pkg/'ThirdPartyNotices'; notices.mkdir()
        for license_name in ('LICENSE','LICENSE_GPL.txt','LICENSE_SDK.txt','DISCLAIMER.md'):
            shutil.copy2(sdk/license_name, notices/license_name)
        manifest={'schema':1,'sourceCommit':runner.SOURCE_COMMIT,'sourceGitTree':runner.SOURCE_TREE,
                  'sourceCargoLockSHA256':runner.SOURCE_LOCK_SHA,'candidateCargoLockSHA256':runner.CANDIDATE_LOCK_SHA,
                  'patchSHA256':dict(runner.PATCH_SHAS),'changedPaths':sorted(paths),
                  'bindingTreeSHA256':tree_digest(pkg/'Sources/ArcusisBitwardenSDK'),
                  'generatedModuleNames':modules,'licenseSHA256':{n:digest(notices/n) for n in ('LICENSE','LICENSE_GPL.txt','LICENSE_SDK.txt','DISCLAIMER.md')},'supportSHA256':digest(pkg/'Sources/BitwardenSdkSupport/NaiveDateFormatter.swift'),
                  'dylibSHA256':digest(next(p for p in safe_tree(staged) if p.name=='libbitwarden_uniffi.dylib')),
                  'minMacOS':'26.0','architecture':'arm64','accepted':True,'integration_ready':False}
        # Public SwiftPM product uses generated bindings and linked binary framework.
        manifest_swift=SDK_PACKAGE_SWIFT
        (pkg/'Package.swift').write_text(manifest_swift)
        manifest['fileSHA256']={p.relative_to(pkg).as_posix():digest(p) for p in safe_tree(pkg)}
        (pkg/'build-manifest.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n')
        validate_package(pkg,manifest)
        consumer=work/'consumer'; (consumer/'Sources/sdk-consumer').mkdir(parents=True)
        (consumer/'Package.swift').write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "SDKConsumer", platforms: [.macOS("26.0")], dependencies: [.package(path: '+json.dumps(str(pkg))+')], targets: [.executableTarget(name: "sdk-consumer", dependencies: [.product(name: "ArcusisBitwardenSDK", package: "Package")])])\n')
        (consumer/'Sources/sdk-consumer/main.swift').write_text('import ArcusisBitwardenSDK\nimport Foundation\nfinal class EmptyTokens: ClientManagedTokens { func getAccessToken() async -> String? { nil } }\n@main struct Smoke { static func main() async throws { let client = Client(tokenProvider: EmptyTokens(), settings: nil, managedSettings: ManagedSettingsBindingClient()); let crypto = client.crypto(); crypto.clearUserCryptoKeys(); print("SDK_TYPED_LOCK_OPERATION_OK") } }\n')
        command(['swift','build','--package-path',str(consumer),'--product','sdk-consumer','-Xlinker','-headerpad_max_install_names'],work,env,900)
        bin_path=Path(command(['swift','build','--package-path',str(consumer),'--show-bin-path'],work,env,60).strip())
        executable=bin_path/'sdk-consumer'
        if executable.is_symlink() or not executable.is_file(): raise ValueError('SwiftPM consumer executable missing or symlinked')
        app=work/'App'; (app/'Contents/MacOS').mkdir(parents=True); (app/'Contents/Frameworks').mkdir()
        app_exec=app/'Contents/MacOS/sdk-consumer'; shutil.copy2(executable,app_exec)
        dylib_name=staged/'macos-arm64/libbitwarden_uniffi.dylib'
        if not dylib_name.is_file(): raise ValueError('XCFramework dylib missing')
        app_lib=app/'Contents/Frameworks/libbitwarden_uniffi.dylib'; shutil.copy2(dylib_name,app_lib)
        load_commands=command(['otool','-l',str(app_exec)],work,env,30)
        import re
        for absolute_rpath in sorted(set(re.findall(r'path (/[^\s]+) \(offset',load_commands))):
            command(['install_name_tool','-delete_rpath',absolute_rpath,str(app_exec)],work,env,30)
        command(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(app_exec)],work,env,30)
        command(['codesign','--force','--sign','-',str(app_exec)],work,env,30)
        arch=command(['lipo','-archs',str(app_lib)],work,env,30).strip()
        minos=command(['vtool','-show-build',str(app_lib)],work,env,30)
        executable_minos=command(['vtool','-show-build',str(app_exec)],work,env,30)
        if arch!='arm64' or not re.search(r'minos\s+26\.0(?:\s|$)',minos) or not re.search(r'minos\s+26\.0(?:\s|$)',executable_minos):
            raise ValueError('consumer or SDK architecture/deployment target mismatch')
        runtime_env={'PATH':env.get('PATH',''),'HOME':env.get('HOME','')}
        smoke=command([str(app_exec)],work,runtime_env,60)
        if 'SDK_TYPED_LOCK_OPERATION_OK' not in smoke: raise ValueError('relocated SwiftPM consumer smoke failed')
        validate_package(pkg,manifest)
        repro=out/'repro'; repro.mkdir()
        shutil.copytree(consumer,repro/'consumer')
        shutil.copy2(app_exec,repro/'sdk-consumer')
        shutil.copy2(app_lib,repro/'libbitwarden_uniffi.dylib')
        shutil.rmtree(work,ignore_errors=True)
        receipt={'schema':1,'status':'built','accepted':True,'integration_ready':False,'sourceCommit':runner.SOURCE_COMMIT,
                 'sourceGitTree':runner.SOURCE_TREE,'changedPathCount':22,
                 'sourceCargoLockSHA256':manifest['sourceCargoLockSHA256'],'candidateCargoLockSHA256':manifest['candidateCargoLockSHA256'],
                 'patchSHA256':dict(runner.PATCH_SHAS),'changedPaths':sorted(paths),
                 'bindingTreeSHA256':manifest['bindingTreeSHA256'],'supportSHA256':manifest['supportSHA256'],
                 'dylibSHA256':manifest['dylibSHA256'],'packageTreeSHA256':tree_digest(pkg),
                 'architecture':arch,'minMacOS':'26.0','consumerSmoke':'SDK_TYPED_LOCK_OPERATION_OK','commands':COMMANDS,
                 'cleanup':{'privateBuildChildrenRemoved':not work.exists(),'consumerProcessExited':True,'ownedAppProcessExited':True},'errors':[]}
        (out/'receipt.json').write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n')
    except Exception as exc:
        if out.is_dir() and not out.is_symlink():
            (out/'receipt.json').write_text(json.dumps({'schema':1,'status':'failed','accepted':True,'integration_ready':False,'errorType':type(exc).__name__,'error':str(exc)},sort_keys=True,indent=2)+'\n')
        raise
    finally:
        shutil.rmtree(work,ignore_errors=True)
    return 0

if __name__ == '__main__':
    try: raise SystemExit(main())
    except Exception as exc:
        print(f'build-native-bitwarden-sdk: {type(exc).__name__}: {exc}',file=sys.stderr)
        raise SystemExit(1)
