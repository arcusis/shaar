#!/usr/bin/env python3
"""Build an ignored, pinned local Swift package for native development."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
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
    return result


def validate_package(root: Path, manifest: dict) -> None:
    if root.is_symlink() or not root.is_dir():
        raise ValueError('unsafe output directory')
    root = root.resolve(strict=True)
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


def command(argv: list[str], cwd: Path, env: dict[str, str], timeout: int = 3600, log_dir: Path | None = None) -> str:
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
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
        modulemaps=sorted(generated.glob('*.modulemap'))
        headers=sorted(generated.glob('*.h'))
        swift=sorted(generated.glob('*.swift'))
        if not modulemaps or not headers or not swift:
            raise ValueError('UniFFI output missing Swift, modulemap, or headers')
        # All SDK FFI module maps and headers stay together; package names derive from generated module declarations.
        pkg=out/'Package'; (pkg/'Sources/ArcusisBitwardenSDK').mkdir(parents=True)
        (pkg/'Sources/BitwardenFFI/include').mkdir(parents=True)
        (pkg/'Sources/BitwardenSdkSupport').mkdir(parents=True)
        for p in swift: shutil.copy2(p,pkg/'Sources/ArcusisBitwardenSDK'/p.name)
        support=sdk/'crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift'
        shutil.copy2(support,pkg/'Sources/BitwardenSdkSupport'/support.name)
        for p in headers: shutil.copy2(p,pkg/'Sources/BitwardenFFI/include'/p.name)
        (pkg/'Sources/BitwardenFFI/shim.c').write_text('void arcusis_bitwarden_ffi_link_anchor(void) {}\n')
        (pkg/'Sources/BitwardenFFI/include/module.modulemap').write_text('\n'.join(p.read_text() for p in modulemaps)+'\n')
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
        manifest_swift='// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "ArcusisBitwardenSDK", platforms: [.macOS("26.0")], products: [.library(name: "ArcusisBitwardenSDK", targets: ["ArcusisBitwardenSDK"])], targets: [.binaryTarget(name: "BitwardenSDK", path: "Frameworks/BitwardenSDK.xcframework"), .target(name: "BitwardenFFI", path: "Sources/BitwardenFFI", publicHeadersPath: "include"), .target(name: "BitwardenSdkSupport", path: "Sources/BitwardenSdkSupport"), .target(name: "ArcusisBitwardenSDK", dependencies: ["BitwardenSDK", "BitwardenFFI", "BitwardenSdkSupport"], path: "Sources/ArcusisBitwardenSDK")])\n'
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
