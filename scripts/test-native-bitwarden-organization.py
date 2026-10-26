#!/usr/bin/env python3
"""Opt-in, offline native SDK organization proof against an owned loopback fixture."""
from __future__ import annotations

import argparse
import hashlib
import http.server
import importlib.util
import json
import os
import platform
import re
import signal
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMIT = '5cf919837e83b71c2508bf99344ea57cf5f84e88'
TREE = '9af9432aefeed6796e40e5019ffdc8600f3381e9'
BASE_LOCK = '0496b9d35a9c6fd84f79bcc46aa774aa8a86f09eb8c64ba568bc18f4abd0c46a'
LOCK = 'abdd9afdaa943a2f2ff5599c36ed5260552002478e63006356a9d9f1fb9e2c48'
DIFF = '38901def6cb5e835e979c390e833c065c4fd7a94ad3d8eb0299ec4ed0002a1e3'
FILES = {
    'ThirdParty/BitwardenAuthSpike/identity-mfa.patch': '850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91',
    'ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch': 'f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4',
    'ThirdParty/BitwardenSyncSpike/sync.patch': '26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533',
    'ThirdParty/BitwardenSyncSpike/organization-keys.patch': 'b61303ecba50f6b1e75a083324e231878ae80d5663593302fede22dbd785cf1d',
    'ThirdParty/BitwardenSyncSpike/organization-keys.pin.json': '82d8d7bac96643bfab06528d39b585809344980e9d3bac706e49389f45535925',
    'Tests/NativeBitwardenSyncTests/test_organization_keys_patch.py': '7ac3a6b92ea5c164b1159813bacba10eadd51b2df0991d00fb63761b7553dd54',
}
ARTIFACTS = frozenset(('dylib_sha256', 'generated_bindings_sha256', 'probe_sha256',
    'helper_sha256', 'helper_lock_sha256', 'bindgen_sha256', 'swift_probe_source_sha256',
    'rust_helper_source_sha256', 'shared_fixture_source_sha256', 'driver_source_sha256'))
REVOCATION = ('Empty initializeOrgCrypto returns early and is not revocation proof. '
              'Product must clear and reinitialize all organization keys before a new snapshot or rebuild the session.')
CHECKS = frozenset(('personal_user_unlocked', 'snapshot', 'organization_owner', 'missing_key_rejects', 'malformed_key',
    'malformed_key_rejects_decrypt', 'name_match', 'username_match', 'password_match',
    'decrypted_organization', 'org_decrypt', 'empty_map_retains_key', 'independent_rejects',
    'independent_unlock_decrypts', 'clear_rejects', 'independent_survives_clear'))

class ProofError(Exception):
    pass

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def file_hash(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ProofError('input missing or symlinked')
    return digest(path.read_bytes())

def validate_inputs(root: Path) -> None:
    for name, expected in FILES.items():
        if file_hash(root / name) != expected:
            raise ProofError('candidate file digest mismatch')
    pin = json.loads((root / 'ThirdParty/BitwardenSyncSpike/organization-keys.pin.json').read_text())
    if (pin.get('sourceCommit') != COMMIT or pin.get('sourceTree') != TREE
            or pin.get('accepted') is not False or pin.get('integration_ready') is not False):
        raise ProofError('candidate pin mismatch')

def validate_paths(source: Path, output: Path) -> None:
    if source.is_symlink() or not source.is_dir() or output.is_symlink() or output.exists():
        raise ProofError('source or output path invalid')
    if not output.parent.is_dir() or output.parent.resolve() != output.parent.absolute():
        raise ProofError('output parent must exist without symlinks')
    source = source.resolve()
    out = output.absolute()
    if out == source or source in out.parents or out in source.parents:
        raise ProofError('output must be separate from source')

def run(command: list[str], *, cwd: Path, env: dict[str, str], timeout: int,
        data: bytes | None = None) -> bytes:
    try:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, _ = process.communicate(data, timeout=timeout)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.communicate()
            raise ProofError('child timed out') from None
        finally:
            # Also terminate descendants left behind by an otherwise exited child.
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
        if process.returncode:
            raise ProofError('child command failed')
        return stdout
    except OSError:
        raise ProofError('child command unavailable') from None

def packages(path: Path) -> set[tuple[str, str, str, str]]:
    data = tomllib.loads(path.read_text())
    return {(p['name'], p['version'], p.get('source', ''), p.get('checksum', ''))
            for p in data['package']}

def check_helper_lock(helper: Path, sdk: Path) -> None:
    helper_packages = packages(helper) - {('organization-crypto-fixture', '0.1.0', '', '')}
    if not helper_packages <= packages(sdk):
        raise ProofError('helper lock differs from pinned SDK dependencies')

def parse_checks(raw: bytes) -> dict[str, bool]:
    found = {}
    for line in raw.decode('utf-8', errors='replace').splitlines():
        name, sep, value = line.partition('=')
        if name in CHECKS:
            if not sep or value != 'passed' or name in found:
                raise ProofError('invalid fixture checks')
            found[name] = True
    if set(found) != CHECKS:
        raise ProofError('incomplete fixture checks')
    return found

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    def handle_error(self, *_args): pass

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_args): pass
    def setup(self):
        super().setup()
        self.connection.settimeout(3)
    def do_GET(self):
        if self.client_address[0] != '127.0.0.1' or not self.path.startswith('/api/sync'):
            self.send_error(404)
            return
        self.server.requests += 1
        body = self.server.body
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

def exercise(probe: Path, payload: bytes, cipher: dict, fixture: dict, org: str, key: str,
             cwd: Path, env: dict[str, str]) -> tuple[dict[str, bool], bool]:
    profile = {'id': fixture['userID'], 'email': fixture['email'], 'emailVerified': True,
               'organizationsNew': [{'id': org, 'key': key}]}
    server = Server(('127.0.0.1', 0), Handler)
    server.requests = 0
    server.body = json.dumps({'profile': profile, 'folders': [], 'ciphers': [cipher],
        'sends': [], 'policiesNew': [], 'userDecryption': {}}).encode()
    address = server.server_address
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        raw = run([str(probe), f'http://127.0.0.1:{address[1]}/'], cwd=cwd, env=env, timeout=90, data=payload)
        checks = parse_checks(raw)
        if server.requests != 1: raise ProofError('unexpected loopback request count')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
    with socket.socket() as sock:
        sock.settimeout(.5)
        closed = sock.connect_ex(address) != 0
    if thread.is_alive() or not closed: raise ProofError('listener cleanup failed')
    return checks, True

def verify_source_hashes(paths: dict[str, Path], expected: dict[str, str]) -> None:
    if set(paths) != set(expected) or any(file_hash(path) != expected[name] for name, path in paths.items()):
        raise ProofError('proof source changed during execution')

def validate_report(report: dict, source_hashes: dict[str, str]) -> None:
    fields = {'schema', 'status', 'scope', 'integration_ready', 'vendor_or_product_acceptance',
              'source_commit', 'source_tree', 'patch_sha256', 'candidate_diff_sha256',
              'cargo_lock_sha256', 'target', 'host_macos', 'host_architecture', 'offline',
              'max_cargo_jobs', 'revocation', 'checks', 'artifacts'}
    fixed = {'status': 'passed', 'scope': 'native_sdk_console_synthetic_loopback',
             'source_commit': COMMIT, 'source_tree': TREE, 'patch_sha256': FILES,
             'candidate_diff_sha256': DIFF, 'cargo_lock_sha256': LOCK,
             'target': 'arm64-apple-macosx26.0', 'host_architecture': 'arm64',
             'revocation': REVOCATION}
    if (not isinstance(report, dict) or set(report) != fields
            or type(report.get('schema')) is not int or report['schema'] != 1
            or any(report.get(key) != value for key, value in fixed.items())
            or report.get('integration_ready') is not False
            or report.get('vendor_or_product_acceptance') is not False
            or report.get('offline') is not True
            or type(report.get('max_cargo_jobs')) is not int or report['max_cargo_jobs'] != 2
            or not isinstance(report.get('host_macos'), str)
            or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', report['host_macos'])):
        raise ProofError('report provenance invalid')
    checks, artifacts = report.get('checks'), report.get('artifacts')
    if (not isinstance(checks, dict) or set(checks) != CHECKS | {'listener_cleanup'}
            or any(value is not True for value in checks.values())
            or not isinstance(artifacts, dict) or set(artifacts) != ARTIFACTS
            or any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value) for value in artifacts.values())
            or set(source_hashes) != {'driver_source_sha256', 'swift_probe_source_sha256',
                                      'rust_helper_source_sha256', 'shared_fixture_source_sha256'}
            or any(artifacts.get(key) != value for key, value in source_hashes.items())):
        raise ProofError('report checks or artifacts invalid')

def tree_hash(root: Path) -> str:
    h = hashlib.sha256()
    files = sorted(p for p in root.iterdir() if p.is_file() and not p.is_symlink())
    if not files or any(p.is_symlink() or not p.is_file() for p in root.iterdir()):
        raise ProofError('generated bindings invalid')
    for path in files:
        h.update(path.name.encode() + b'\0' + bytes.fromhex(file_hash(path)) + b'\n')
    return h.hexdigest()

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='explicitly opt into offline native build and loopback')
    parser.add_argument('--source', required=True, type=Path, help='local SDK git repository containing pinned commit')
    parser.add_argument('--output', required=True, type=Path, help='fresh private output under an existing directory')
    parser.add_argument('--cargo-cache', required=True, type=Path, help='existing Cargo home to copy for offline dependencies')
    args = parser.parse_args()
    if not args.run: raise ProofError('explicit --run required')
    source, output = args.source.expanduser().absolute(), args.output.expanduser().absolute()
    validate_inputs(ROOT)
    validate_paths(source, output)
    cache = args.cargo_cache.expanduser().absolute()
    if (cache.is_symlink() or not (cache / 'registry').is_dir()
            or cache.resolve() == source.resolve() or cache.resolve() in output.parents
            or output in cache.resolve().parents):
        raise ProofError('Cargo cache invalid')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ProofError('arm64 macOS required')
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'SDKROOT', 'RUSTUP_HOME', 'CARGO_HOME') if k in os.environ}
    env.update(RUSTUP_TOOLCHAIN='1.90-aarch64-apple-darwin', MACOSX_DEPLOYMENT_TARGET='26.0',
               CARGO_NET_OFFLINE='true', CARGO_BUILD_JOBS='2', CARGO_TERM_COLOR='never',
               RUSTUP_AUTO_INSTALL='0', RUSTUP_NO_UPDATE_CHECK='1',
               RUSTFLAGS='-C link-arg=-mmacosx-version-min=26.0')
    def cmd(argv, cwd=ROOT, timeout=1200, data=None):
        return run(argv, cwd=cwd, env=env, timeout=timeout, data=data)
    source_files = {
        'driver_source_sha256': Path(__file__).resolve(),
        'swift_probe_source_sha256': ROOT / 'Tests/NativeBitwardenOrganizationProbe/main.swift',
        'rust_helper_source_sha256': ROOT / 'Tests/NativeBitwardenOrganizationProbe/KeyFixture.rs',
        'shared_fixture_source_sha256': ROOT / 'Tests/NativeBitwardenSyncProbe/Fixtures.swift',
    }
    source_hashes = {name: file_hash(path) for name, path in source_files.items()}
    if cmd(['git', '-C', str(source), 'rev-parse', COMMIT + '^{tree}'], timeout=10).decode().strip() != TREE:
        raise ProofError('source tree mismatch')
    if digest(cmd(['git', '-C', str(source), 'show', COMMIT + ':Cargo.lock'], timeout=10)) != BASE_LOCK:
        raise ProofError('source lock mismatch')
    output.mkdir(mode=0o700)
    report = {'schema': 1, 'status': 'failed', 'scope': 'native_sdk_console_synthetic_loopback',
              'integration_ready': False, 'vendor_or_product_acceptance': False,
              'source_commit': COMMIT, 'source_tree': TREE, 'patch_sha256': FILES,
              'candidate_diff_sha256': DIFF, 'cargo_lock_sha256': LOCK,
              'target': 'arm64-apple-macosx26.0', 'host_macos': platform.mac_ver()[0],
              'host_architecture': platform.machine(), 'offline': True, 'max_cargo_jobs': 2,
              'revocation': REVOCATION,
              'checks': {}, 'artifacts': {}}
    stage = 'copy_cache'
    try:
        cargo_home = output / 'cargo-home'
        cargo_home.mkdir(mode=0o700)
        for name in ('registry', 'git'):
            path = cache / name
            if path.exists():
                if path.is_symlink() or any(p.is_symlink() for p in path.rglob('*')):
                    raise ProofError('Cargo cache contains symlink')
                shutil.copytree(path, cargo_home / name)
        env['CARGO_HOME'] = str(cargo_home)
        stage = 'source_copy_and_patches'
        sdk = output / 'sdk'
        cmd(['git', 'clone', '--local', '--no-hardlinks', '--no-checkout', str(source), str(sdk)], timeout=120)
        cmd(['git', '-C', str(sdk), 'checkout', '--detach', COMMIT], timeout=120)
        for name in list(FILES)[:4]:
            cmd(['git', '-C', str(sdk), 'apply', '--check', '--whitespace=error', str(ROOT / name)], timeout=30)
            cmd(['git', '-C', str(sdk), 'apply', '--whitespace=error', str(ROOT / name)], timeout=30)
        cmd(['git', '-C', str(sdk), 'add', '-N', '-A'], timeout=30)
        if digest(cmd(['git', '-C', str(sdk), 'diff', '--binary', 'HEAD'], timeout=30)) != DIFF or file_hash(sdk / 'Cargo.lock') != LOCK:
            raise ProofError('layered candidate mismatch')
        stage = 'sdk_build_and_bindings'
        target = output / 'target'
        env['CARGO_TARGET_DIR'] = str(target)
        common = ['--offline', '--locked', '--manifest-path', str(sdk / 'Cargo.toml')]
        cmd(['cargo', 'build', *common, '-p', 'bitwarden-uniffi'])
        dylib = target / 'debug/libbitwarden_uniffi.dylib'
        dylib_sha = file_hash(dylib)
        generated = output / 'generated'
        generated.mkdir(mode=0o700)
        cmd(['cargo', 'run', *common, '-p', 'uniffi-bindgen', '--', 'generate', str(dylib), '--language', 'swift', '--no-format', '--out-dir', str(generated)], cwd=sdk)
        if file_hash(dylib) != dylib_sha: raise ProofError('dylib changed during binding generation')
        bindings_sha = tree_hash(generated)
        stage = 'helper_build'
        helper = output / 'helper'
        (helper / 'src').mkdir(parents=True, mode=0o700)
        (helper / 'Cargo.toml').write_text('[package]\nname = "organization-crypto-fixture"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nbitwarden-crypto = { path = ' + json.dumps(str(sdk / 'crates/bitwarden-crypto')) + ' }\n')
        (helper / 'src/main.rs').write_bytes((ROOT / 'Tests/NativeBitwardenOrganizationProbe/KeyFixture.rs').read_bytes())
        (helper / 'Cargo.lock').write_bytes((sdk / 'Cargo.lock').read_bytes())
        cmd(['cargo', 'metadata', '--offline', '--format-version', '1', '--manifest-path', str(helper / 'Cargo.toml')])
        check_helper_lock(helper / 'Cargo.lock', sdk / 'Cargo.lock')
        cmd(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(helper / 'Cargo.toml')])
        stage = 'swift_build_and_platform'
        work = output / 'work'; work.mkdir(mode=0o700)
        for name, filename in (('swift_probe_source_sha256', 'main.swift'),
                               ('shared_fixture_source_sha256', 'Fixtures.swift')):
            (work / filename).write_bytes(source_files[name].read_bytes())
            if file_hash(work / filename) != source_hashes[name]:
                raise ProofError('copied proof source mismatch')
        support = sdk / 'crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift'
        obj = work / 'BitwardenSdkSupport.o'
        cmd(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macosx26.0', '-module-name', 'BitwardenSdkSupport', '-emit-module', '-emit-module-path', str(work / 'BitwardenSdkSupport.swiftmodule'), '-emit-object', '-o', str(obj), str(support)], timeout=120)
        probe = work / 'probe'
        maps = [x for p in sorted(generated.glob('*.modulemap')) for x in ('-Xcc', '-fmodule-map-file=' + str(p))]
        sources = [str(p) for p in sorted(generated.glob('*.swift'))]
        if not maps or not sources: raise ProofError('generated bindings missing')
        cmd(['swiftc', '-target', 'arm64-apple-macosx26.0', '-I', str(work), '-I', str(generated), *maps,
             '-L', str(dylib.parent), '-lbitwarden_uniffi', '-Xlinker', '-rpath', '-Xlinker', str(dylib.parent),
             *sources, str(obj), str(work / 'Fixtures.swift'), str(work / 'main.swift'), '-o', str(probe)], timeout=300)
        for path in (dylib, probe, target / 'debug/organization-crypto-fixture', target / 'debug/uniffi-bindgen'):
            if cmd(['lipo', '-archs', str(path)], timeout=30).decode().strip() != 'arm64' or not re.search(rb'minos\s+26\.0(?:\s|$)', cmd(['vtool', '-show-build', str(path)], timeout=30)):
                raise ProofError('native architecture or minimum macOS mismatch')
        stage = 'native_fixture'
        spec = importlib.util.spec_from_file_location('sync_fixture', ROOT / 'scripts/test-native-bitwarden-sync.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        fixture = module.sdk_vector(sdk)
        source_text = (sdk / 'crates/bitwarden-core/src/client/test_accounts.rs').read_text()
        sql = source_text.split('INSERT INTO vault_dev.dbo.[User]', 1)[1].split('INSERT INTO vault_dev.dbo.Organization', 1)[0]
        public = re.search(r"N\s*'(MIIBIjAN[^']+)'", sql)
        if not public: raise ProofError('public fixture unavailable')
        key = cmd([str(target / 'debug/organization-crypto-fixture')], cwd=work, timeout=30, data=public.group(1).encode()).decode()
        org = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        payload = json.dumps({'fixture': fixture, 'org': org, 'key': key}).encode()
        prepared = cmd([str(probe), 'prepare'], cwd=work, timeout=60, data=payload)
        cipher = json.loads(prepared[prepared.index(b'{'):])['cipher']
        checks, cleanup = exercise(probe, payload, cipher, fixture, org, key, work, env)
        verify_source_hashes(source_files, source_hashes)
        if (file_hash(dylib) != dylib_sha or tree_hash(generated) != bindings_sha
                or file_hash(work / 'main.swift') != source_hashes['swift_probe_source_sha256']
                or file_hash(work / 'Fixtures.swift') != source_hashes['shared_fixture_source_sha256']
                or file_hash(helper / 'src/main.rs') != source_hashes['rust_helper_source_sha256']):
            raise ProofError('native artifacts or proof sources changed during fixture')
        report['checks'] = checks | {'listener_cleanup': cleanup}
        report['artifacts'] = {'dylib_sha256': dylib_sha, 'generated_bindings_sha256': bindings_sha,
            'probe_sha256': file_hash(probe), 'helper_sha256': file_hash(target / 'debug/organization-crypto-fixture'),
            'helper_lock_sha256': file_hash(helper / 'Cargo.lock'),
            'bindgen_sha256': file_hash(target / 'debug/uniffi-bindgen'),
            **source_hashes}
        report['status'] = 'passed'
        try: validate_report(report, source_hashes)
        except ProofError:
            report['status'] = 'failed'
            raise
    finally:
        if report['status'] != 'passed': report['failed_stage'] = stage
        report_path = output / 'report.json'
        report_path.write_text(json.dumps(report, sort_keys=True, indent=2) + '\n')
        report_path.chmod(0o600)
    print('organization proof passed; redacted report written')

if __name__ == '__main__':
    try: main()
    except (ProofError, OSError, ValueError, KeyError, IndexError, json.JSONDecodeError):
        print('organization proof failed; no fixture material logged', file=sys.stderr)
        sys.exit(1)
