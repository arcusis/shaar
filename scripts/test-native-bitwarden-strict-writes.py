#!/usr/bin/env python3
"""Owned SDK8 generated-binding transport fixture; disabled until package receipt is pinned."""
from __future__ import annotations
import argparse
import base64
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import socketserver
import stat
import subprocess
import threading
import time
import uuid
import sys
from unittest.mock import patch
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
CONSUMER = ROOT / 'Tests/NativeBitwardenSDK8TransportTests/strict_write_consumer.swift'
SOURCE_COMMIT = '5cf919837e83b71c2508bf99344ea57cf5f84e88'
WRITE_PATCH_SHA = 'e030b6a6eab842b11a1de1f293e75e09aa9bfca73330752296a266d2d1fc5b77'
WRITE_CANDIDATE_SHA = '0398b31e2640dc92bcb77ebb8840659831593c34da84f06f3a98d603130c923c'
VECTOR_SHA = '2347b7c7b3856b4672c38354fcaa00b0a2bb8afdbf842145230328bb6b9fb2c7'
EXTRACTOR_SHA = 'ed4436414633d5d89be69d7ef89f241e775f13b5a5b9c6ad167884ea05d807bb'
# Independent parent-reviewed paired package receipt.
EXPECTED_RECEIPT_SHA256 = 'd5cadc8fcd0e231b9578aff1613a75cfb95aa486beeb12f84439ac70167a3c70'
CIPHER_ID = '11111111-1111-4111-8111-111111111111'
BUILD_SANDBOX = '(version 1)(allow default)(deny network*)'

def runtime_sandbox(port: int) -> str:
    if type(port) is not int or not 1 <= port <= 65535: raise FixtureError('invalid loopback port')
    return ('(version 1)(allow default)(deny process-fork)(deny network-bind)'
            '(deny network-inbound)(deny network-outbound '
            f'(require-not (remote ip \"localhost:{port}\")))')
PACKAGE_SWIFT = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "StrictWriteFixture", platforms: [.macOS("26.0")],
  dependencies: [.package(name: "SDKPackage", path: "../SDKPackage")],
  targets: [.executableTarget(name: "StrictWriteConsumer", dependencies:
    [.product(name: "ArcusisBitwardenSDK", package: "SDKPackage")])])
'''

class FixtureError(Exception):
    pass

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise FixtureError('duplicate JSON key')
        result[key] = value
    return result

def regular(path: Path) -> Path:
    if not path.is_absolute() or '..' in path.parts: raise FixtureError('absolute non-traversal path required')
    for part in (path, *path.parents):
        if part.is_symlink(): raise FixtureError('symlink rejected')
    if not stat.S_ISREG(path.stat().st_mode): raise FixtureError('regular file required')
    return path

def read_json(path: Path):
    return json.loads(regular(path).read_text(), object_pairs_hook=unique)

def digest(path: Path) -> str:
    return hashlib.sha256(regular(path).read_bytes()).hexdigest()

def inventory(root: Path) -> dict[str, str]:
    if not root.is_absolute() or '..' in root.parts or not root.is_dir(): raise FixtureError('directory required')
    for part in (root, *root.parents):
        if part.is_symlink(): raise FixtureError('symlink rejected')
    result = {}
    for path in sorted(root.rglob('*')):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode): raise FixtureError('symlink rejected')
        if stat.S_ISREG(info.st_mode): result[path.relative_to(root).as_posix()] = digest(path)
        elif not stat.S_ISDIR(info.st_mode): raise FixtureError('special file rejected')
    return result

def validate_package(root: Path, mode: str, expected_manifest_sha: str):
    if mode not in ('debug', 'release'): raise FixtureError('unsupported mode')
    manifest_path = root / 'build-manifest.json'
    if digest(manifest_path) != expected_manifest_sha: raise FixtureError('manifest pin mismatch')
    manifest = read_json(manifest_path)
    if (type(manifest.get('schema')) is not int or manifest['schema'] != 1
        or manifest.get('accepted') is not False or manifest.get('integrationReady') is not False
        or manifest.get('mode') != mode or manifest.get('testOnly') is not (mode == 'debug')
        or manifest.get('sourceCommit') != SOURCE_COMMIT or manifest.get('writeCandidateSHA256') != WRITE_CANDIDATE_SHA
        or manifest.get('architecture') != 'arm64' or manifest.get('minMacOS') != '26.0'):
        raise FixtureError('package provenance mismatch')
    actual = inventory(root)
    actual.pop('build-manifest.json')
    expected = manifest.get('fileSHA256')
    if not isinstance(expected, dict) or not expected or actual != expected:
        raise FixtureError('package inventory mismatch')
    lib = 'Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib'
    generated = manifest.get('generatedSHA256'); licenses = manifest.get('licenseSHA256')
    modules = manifest.get('generatedModules')
    if (actual.get(lib) != manifest.get('dylibSHA256') or lib not in actual
        or not isinstance(generated, dict) or not generated or not isinstance(licenses, dict) or not licenses
        or not isinstance(modules, list) or not modules or not all(isinstance(x, str) and x for x in modules)):
        raise FixtureError('package artifact provenance')
    if any(not any(isinstance(name, str) and name.endswith(ext) for name in generated)
           for ext in ('.swift', '.h', '.modulemap')):
        raise FixtureError('generated families')
    for name, value in generated.items():
        if not isinstance(name, str) or '/' in name or not isinstance(value, str): raise FixtureError('generated name')
        if name.endswith('.swift'):
            paths = ['Sources/ArcusisBitwardenSDK/' + name]
        elif name.endswith('.h'):
            paths = ['Sources/BitwardenFFI/include/' + name,
                     'Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers/' + name]
        elif name.endswith('.modulemap'):
            continue  # Builder verifies individual maps before merging their module map.
        else: raise FixtureError('generated suffix')
        if any(actual.get(path) != value for path in paths): raise FixtureError('generated digest')
    if any(not isinstance(name, str) or '/' in name or actual.get('ThirdPartyNotices/' + name) != value for name, value in licenses.items()):
        raise FixtureError('license digest')
    return {'manifest': expected_manifest_sha, 'files': actual}

def pinned_receipt(path: Path):
    if EXPECTED_RECEIPT_SHA256 is None: raise FixtureError('SDK8 receipt pin pending coordinator review')
    if digest(path) != EXPECTED_RECEIPT_SHA256: raise FixtureError('receipt pin mismatch')
    receipt = read_json(path)
    if not isinstance(receipt, dict): raise FixtureError('invalid receipt')
    return receipt

def absolute(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute() or any(part in ('.', '..') for part in value.split('/')):
        raise argparse.ArgumentTypeError('absolute non-traversal path required')
    return path

def run_process(command: list[str], cwd: Path, extra: dict[str, str], timeout: int):
    environment = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR') if k in os.environ}
    environment.update(extra)
    process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
        if process.returncode != 0:
            # Expose only bounded sandbox diagnostics; never forward arbitrary child output.
            lines = output.decode('ascii', errors='ignore').splitlines()
            safe = next((line for line in lines if line.startswith('sandbox-exec:')), '')
            safe = ''.join(char for char in safe if 32 <= ord(char) <= 126)[:512]
            raise FixtureError(f'owned process failed ({process.returncode})' + (': ' + safe if safe else ''))
        return output
    finally:
        # Never signal a reaped process group: its numeric ID may be reused.
        if process.poll() is None:
            try:
                if os.getpgid(process.pid) != process.pid:
                    raise FixtureError('owned process group changed')
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired as error:
            raise FixtureError('child cleanup timeout') from error
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise FixtureError('child process group survived cleanup')

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def setup(self):
        super().setup(); self.connection.settimeout(5)
    def send_json(self, status, body, location=None):
        data = json.dumps(body, separators=(',', ':')).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        if location: self.send_header('Location', location)
        self.end_headers(); self.wfile.write(data)
    def note_error(self, label):
        with self.server.lock:
            if len(self.server.errors) < 120: self.server.errors.append(label)
    def count_request(self):
        with self.server.lock:
            self.server.total += 1
            if self.server.total > 120: raise FixtureError('request budget')
    def body(self):
        if self.client_address[0] != '127.0.0.1' or self.headers.get('Transfer-Encoding'):
            raise FixtureError('request boundary')
        n = int(self.headers.get('Content-Length', '-1'))
        if not 0 <= n <= 65536: raise FixtureError('body bound')
        raw = self.rfile.read(n)
        if len(raw) != n: raise FixtureError('truncated body')
        return json.loads(raw, object_pairs_hook=unique)
    def do_POST(self):
        try:
            self.count_request()
            if self.path != '/fixture/seed' or self.server.seed is not None: raise FixtureError('unexpected POST')
            seed = self.body()
            if seed.get('id') != CIPHER_ID: raise FixtureError('seed id')
            self.server.seed = {**seed, 'object': 'cipher', 'organizationId': None, 'type': 1,
                'data': None, 'partialData': None, 'card': None, 'identity': None, 'secureNote': None,
                'sshKey': None, 'bankAccount': None, 'driversLicense': None, 'passport': None,
                'passwordHistory': None, 'organizationUseTotp': False,
                'revisionDate': '2025-01-01T00:00:00.123456789Z', 'creationDate': '2024-01-01T00:00:00Z',
                'deletedDate': None, 'reprompt': 0, 'folderId': None, 'favorite': True,
                'edit': True, 'viewPassword': True, 'archivedDate': None, 'permissions': None,
                'collectionIds': []}
            self.server.seed['login']['uri'] = None
            self.send_json(200, {})
        except (ValueError, OSError, FixtureError, KeyError):
            self.note_error('seed rejected'); self.send_json(400, {})
    def do_GET(self):
        try:
            self.count_request()
            if self.client_address[0] != '127.0.0.1': raise FixtureError('peer')
            if self.path == '/fixture/status':
                with self.server.lock:
                    self.server.controls += 1
                    if self.server.controls > 80: raise FixtureError('control bound')
                data = b'ready' if self.server.pending.is_set() else b'waiting'
                self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
            if self.path == '/fixture/release':
                self.server.release.set(); self.send_json(200, {}); return
            parts = urlsplit(self.path)
            if parts.path != '/api/sync' or parts.query not in ('', 'excludeDomains=true', 'excludeDomains=false'):
                raise FixtureError('unexpected GET')
            if self.headers.get('Authorization') != 'Bearer synthetic-owned-token' or self.server.seed is None: raise FixtureError('sync auth')
            with self.server.lock:
                self.server.syncs += 1
                if self.server.syncs > 10: raise FixtureError('sync count')
                payload = json.loads(json.dumps(self.server.seed))
            self.send_json(200, {'profile': {'organizations': []}, 'folders': [], 'sends': [],
                                 'policiesNew': [], 'ciphers': [payload]})
        except (ValueError, OSError, FixtureError):
            self.note_error('GET rejected'); self.send_json(400, {})
    def do_PUT(self):
        try:
            self.count_request()
            if self.path != '/api/ciphers/' + CIPHER_ID or self.headers.get('Authorization') != 'Bearer synthetic-owned-token': raise FixtureError('unexpected PUT')
            obj = self.body()
            with self.server.lock:
                self.server.puts += 1
                n = self.server.puts
            if n > 10: raise FixtureError('duplicate PUT')
            expected_revision = '2025-01-01T00:00:00.123456789Z' if n == 1 else '2025-01-01T00:00:00.123456790Z'
            if obj.get('lastKnownRevisionDate') != expected_revision: raise FixtureError('revision')
            original = self.server.seed
            if obj.get('key') != original['key']: raise FixtureError('item key changed')
            attachment = original['attachments'][0]
            if obj.get('attachments2') != {'attachment-a': {'fileName': attachment['fileName'], 'key': attachment['key']}}: raise FixtureError('attachment changed')
            password = obj.get('login', {}).get('password')
            username = obj.get('login', {}).get('username')
            if not isinstance(password, str) or not password.startswith('2.'):
                raise FixtureError('unencrypted password')
            if username is not None and (not isinstance(username, str) or not username.startswith('2.')):
                raise FixtureError('unencrypted username')
            if any(word in json.dumps(obj) for word in ('synthetic-new', 'synthetic-old', 'synthetic-note', 'synthetic-attachment')): raise FixtureError('plaintext')
            if n == 1:
                for key in ('name', 'notes', 'key'):
                    original[key] = obj.get(key)
                incoming = obj['login']
                original['login'] = {key: incoming.get(key) for key in
                    ('uri', 'uris', 'username', 'password', 'passwordRevisionDate', 'totp',
                     'autofillOnPageLoad', 'fido2Credentials')}
                if original['login']['uris'] is not None:
                    original['login']['uris'] = [{key: uri.get(key) for key in ('uri', 'uriChecksum', 'match')}
                                                  for uri in original['login']['uris']]
                fields = obj.get('fields')
                original['fields'] = None if fields is None else [
                    {key: field.get(key) for key in ('type', 'name', 'value', 'linkedId')} for field in fields]
                history = obj.get('passwordHistory')
                original['passwordHistory'] = None if history is None else [
                    {key: item.get(key) for key in ('password', 'lastUsedDate')} for item in history]
                original['revisionDate'] = '2025-01-01T00:00:00.123456790Z'
                self.send_json(200, {})
            elif n in (2, 3, 4): self.send_json({2:409, 3:401, 4:403}[n], {})
            elif n == 5: self.send_json(200, {})
            elif n == 6:
                data = b'{'; self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            elif n == 7:
                mismatch = dict(original, id='44444444-4444-4444-8444-444444444444')
                self.send_json(200, mismatch)
            elif n == 8: self.close_connection = True; self.connection.shutdown(socket.SHUT_RDWR)
            elif n == 9: self.send_json(307, {}, f'http://127.0.0.1:{self.server.server_address[1]}/fixture/redirect-target')
            elif n == 10:
                self.server.pending.set()
                if not self.server.release.wait(5): raise FixtureError('release timeout')
                try: self.send_json(200, {})
                except OSError: pass  # Cancellation may close the owned socket.
        except (ValueError, OSError, FixtureError, KeyError, TypeError):
            self.note_error('PUT rejected')
            try: self.send_json(400, {})
            except OSError: pass

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = False
    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.seed = None; self.puts = self.syncs = self.controls = self.total = 0; self.errors = []
        self.pending = threading.Event(); self.release = threading.Event(); self.cleanup_ok = False
        self.lock = threading.RLock(); self.active = set(); self.threads = []
    def process_request(self, request, address):
        def serve_request():
            try: self.process_request_thread(request, address)
            finally:
                with self.lock: self.active.discard(request)
        thread = threading.Thread(target=serve_request, daemon=False)
        with self.lock:
            self.active.add(request); self.threads.append(thread)
        try: thread.start()
        except BaseException:
            with self.lock: self.active.discard(request); self.threads.remove(thread)
            raise
    def handle_error(self, *_): pass

def serve_fixture(server: Server, command: list[str], cwd: Path, vector: dict, release: bool, timeout: int = 90):
    address = server.server_address
    server.timeout = 0.1
    stop = threading.Event()
    def serve():
        while not stop.is_set(): server.handle_request()
    worker = threading.Thread(target=serve, daemon=False)
    try:
        worker.start()
        vector = dict(vector, endpoint=f'http://127.0.0.1:{address[1]}')
        extra = {'ARCUSIS_STRICT_VECTOR': base64.b64encode(json.dumps(vector).encode()).decode()}
        if release: extra['ARCUSIS_STRICT_RELEASE'] = '1'
        output = run_process(['/usr/bin/sandbox-exec', '-p', runtime_sandbox(address[1]), *command], cwd, extra, timeout)
        marker = b'strict-sdk8-release-http=rejected' if release else b'strict-sdk8-consumer=passed'
        if marker not in output: raise FixtureError('missing consumer marker')
    finally:
        server.release.set(); stop.set()
        if worker.ident is not None: worker.join(timeout=6)
        with server.lock: active = list(server.active); threads = list(server.threads)
        for peer in active:
            try: peer.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            peer.close()
        server.server_close()
        for thread in threads: thread.join(timeout=6)
        if worker.is_alive() or any(thread.is_alive() for thread in threads):
            raise FixtureError('fixture threads survived')
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(address) == 0: raise FixtureError('listener survived')
        server.cleanup_ok = True
    if server.errors: raise FixtureError('fixture request rejected')
    if release and (server.syncs or server.puts or server.seed is not None): raise FixtureError('release made HTTP request')
    if not release and (server.puts != 10 or server.syncs != 10 or server.seed is None): raise FixtureError('unexpected request counts')
    return {'puts': server.puts, 'syncs': server.syncs, 'releaseRejected': release,
            'listenerClosed': True, 'threadsStopped': True}

def verify_cleanup(output: Path, result: dict):
    # Synthetic children never access SDK or network; each owns a new process group.
    cases = {
        'success': [sys.executable, '-B', '-c', 'print("strict-sdk8-release-http=rejected")'],
        'error': [sys.executable, '-B', '-c', 'raise SystemExit(7)'],
        'timeout': [sys.executable, '-B', '-c', 'import time; time.sleep(30)'],
        'interrupt': [sys.executable, '-B', '-c', 'import time; time.sleep(30)'],
    }
    for name, command in cases.items():
        server = Server()
        try:
            if name == 'interrupt':
                with patch.object(subprocess.Popen, 'communicate', side_effect=KeyboardInterrupt()):
                    serve_fixture(server, command, output, {}, True, timeout=1)
            else:
                serve_fixture(server, command, output, {}, True, timeout=1)
        except FixtureError as error:
            if name != 'error' or str(error) != 'owned process failed (7)': raise
        except subprocess.TimeoutExpired:
            if name != 'timeout': raise
        except KeyboardInterrupt:
            if name != 'interrupt': raise
        else:
            if name != 'success': raise FixtureError('cleanup test failed to trigger')
        finally:
            result.setdefault('cleanupObservations', {})[name] = {
                'listenerClosed': server.cleanup_ok, 'requests': server.total,
                'errors': len(server.errors),
            }
        if not server.cleanup_ok: raise FixtureError('cleanup test listener survived')
    return {'success': True, 'error': True, 'timeout': True, 'interrupt': True}

def run_fixture(debug: Path, release: Path, source: Path, extractor: Path, receipt: Path,
                debug_manifest: str, release_manifest: str):
    # All inputs are immutable and fingerprinted before staging, build, execution and cleanup.
    before = {'debug': validate_package(debug, 'debug', debug_manifest),
              'release': validate_package(release, 'release', release_manifest),
              'consumer': digest(CONSUMER), 'guard': digest(ROOT / 'Tests/NativeBitwardenSDK8TransportTests/test_strict_sdk_transport.py'),
              'runner': digest(Path(__file__).absolute()),
              'vector': digest(source / 'crates/bitwarden-core/src/client/test_accounts.rs'),
              'extractor': digest(extractor), 'receipt': digest(receipt)}
    if before['vector'] != VECTOR_SHA or before['extractor'] != EXTRACTOR_SHA: raise FixtureError('vector pin')
    output_root = ROOT / 'build/NativeBitwardenStrictSDK8Transport'
    if not output_root.is_dir() or any(part.is_symlink() for part in (output_root, *output_root.parents)):
        raise FixtureError('output root')
    output = output_root / ('run-' + uuid.uuid4().hex)
    output.mkdir(mode=0o700, exist_ok=False)
    result = {'status': 'incomplete', 'protocolNack': 'not simulated',
              'evidence': 'synthetic generated SDK and loopback only', 'inputs': before}
    try:
        result['cleanupChecks'] = verify_cleanup(output, result)
        spec = importlib.util.spec_from_file_location('strict_public_vector', extractor)
        if spec is None or spec.loader is None: raise FixtureError('vector extractor')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        vector = module.sdk_vector(source)
        binaries = {}
        binary_hashes = {}
        for mode, package in (('debug', debug), ('release', release)):
            stage = output / mode; stage.mkdir(mode=0o700)
            shutil.copytree(package, stage / 'SDKPackage', symlinks=False)
            harness = stage / 'Harness'; consumer_dir = harness / 'Sources/StrictWriteConsumer'
            consumer_dir.mkdir(parents=True)
            shutil.copyfile(CONSUMER, consumer_dir / 'StrictWriteConsumer.swift')
            (harness / 'Package.swift').write_text(PACKAGE_SWIFT)
            if (inventory(stage / 'SDKPackage') != inventory(package) or
                inventory(harness / 'Sources') != {'StrictWriteConsumer/StrictWriteConsumer.swift': before['consumer']}):
                raise FixtureError('staged input drift')
            scratch = stage / 'swift-build'
            cache = stage / 'swift-cache'; cache.mkdir(mode=0o700)
            runtime_lib = stage / 'SDKPackage/Frameworks/BitwardenSDK.xcframework/macos-arm64'
            build = ['swift', 'build', '--package-path', str(harness), '--scratch-path', str(scratch),
                     '--cache-path', str(cache), '--jobs', '2', '--disable-keychain', '--disable-netrc',
                     '--disable-dependency-cache', '--disable-prefetching', '--manifest-cache', 'none', '--disable-sandbox',
                     '-Xlinker', '-rpath', '-Xlinker', str(runtime_lib)]
            run_process(['/usr/bin/sandbox-exec', '-p', BUILD_SANDBOX, *build], output, {}, 300)
            lines = run_process(['/usr/bin/sandbox-exec', '-p', BUILD_SANDBOX, *build, '--show-bin-path'], output, {}, 60).decode('utf-8').splitlines()
            if len(lines) != 1: raise FixtureError('ambiguous binary directory')
            bin_dir = Path(lines[0])
            if (not bin_dir.is_absolute() or '..' in bin_dir.parts or not bin_dir.is_dir()
                or any(part.is_symlink() for part in (bin_dir, *bin_dir.parents))
                or bin_dir.resolve(strict=True) != bin_dir or not bin_dir.is_relative_to(scratch)):
                raise FixtureError('unsafe binary directory')
            binaries[mode] = bin_dir / 'StrictWriteConsumer'
            regular(binaries[mode]); binary_hashes[mode] = digest(binaries[mode])
            if (inventory(stage / 'SDKPackage') != inventory(package) or
                inventory(harness / 'Sources') != {'StrictWriteConsumer/StrictWriteConsumer.swift': before['consumer']} or
                digest(harness / 'Package.swift') != hashlib.sha256(PACKAGE_SWIFT.encode()).hexdigest() or
                digest(CONSUMER) != before['consumer'] or
                digest(ROOT / 'Tests/NativeBitwardenSDK8TransportTests/test_strict_sdk_transport.py') != before['guard'] or
                digest(Path(__file__).absolute()) != before['runner'] or
                digest(receipt) != before['receipt']):
                raise FixtureError('post-build input drift')
            validate_package(package, mode, debug_manifest if mode == 'debug' else release_manifest)
        def verify():
            current = {'debug': validate_package(debug, 'debug', debug_manifest),
                       'release': validate_package(release, 'release', release_manifest),
                       'consumer': digest(CONSUMER),
                       'guard': digest(ROOT / 'Tests/NativeBitwardenSDK8TransportTests/test_strict_sdk_transport.py'),
                       'runner': digest(Path(__file__).absolute()),
                       'vector': digest(source / 'crates/bitwarden-core/src/client/test_accounts.rs'),
                       'extractor': digest(extractor), 'receipt': digest(receipt)}
            if before != current: raise FixtureError('input drift')
            for mode, package in (('debug', debug), ('release', release)):
                stage = output / mode
                if inventory(stage / 'SDKPackage') != inventory(package): raise FixtureError('staged package drift')
                if inventory(stage / 'Harness/Sources') != {'StrictWriteConsumer/StrictWriteConsumer.swift': before['consumer']}:
                    raise FixtureError('staged consumer drift')
                if digest(stage / 'Harness/Package.swift') != hashlib.sha256(PACKAGE_SWIFT.encode()).hexdigest():
                    raise FixtureError('harness manifest drift')
                if digest(binaries[mode]) != binary_hashes[mode]: raise FixtureError('built binary drift')
        verify()
        release_server = Server()
        try: result['release'] = serve_fixture(release_server, [str(binaries['release'])], output, vector, True)
        finally:
            result['releaseCleanup'] = release_server.cleanup_ok
            result['releaseCounts'] = {'puts': release_server.puts, 'syncs': release_server.syncs,
                                       'requests': release_server.total, 'errors': len(release_server.errors)}
        verify()
        debug_server = Server()
        try: result['debug'] = serve_fixture(debug_server, [str(binaries['debug'])], output, vector, False)
        finally:
            result['debugCleanup'] = debug_server.cleanup_ok
            result['debugCounts'] = {'puts': debug_server.puts, 'syncs': debug_server.syncs,
                                     'requests': debug_server.total, 'errors': len(debug_server.errors)}
        verify()
        result['status'] = 'passed'
        return output
    except BaseException as error:
        result['errorType'] = type(error).__name__
        raise
    finally:
        try:
            result['inputFinal'] = {'debug': validate_package(debug, 'debug', debug_manifest),
                'release': validate_package(release, 'release', release_manifest),
                'consumer': digest(CONSUMER),
                'guard': digest(ROOT / 'Tests/NativeBitwardenSDK8TransportTests/test_strict_sdk_transport.py'),
                'runner': digest(Path(__file__).absolute()),
                'vector': digest(source / 'crates/bitwarden-core/src/client/test_accounts.rs'),
                'extractor': digest(extractor), 'receipt': digest(receipt)}
            result['inputsUnchanged'] = result['inputFinal'] == before
            if not result['inputsUnchanged']: result['status'] = 'failed-input-drift'
        except BaseException:
            result['inputsUnchanged'] = False
            result['status'] = 'failed-input-check'
        receipt_path = output / 'receipt.json'
        with receipt_path.open('x', encoding='utf-8') as stream:
            os.chmod(receipt_path, 0o600)
            stream.write(json.dumps(result, indent=2, sort_keys=True) + '\n')
        if result['status'] == 'failed-input-drift' or result['status'] == 'failed-input-check':
            raise FixtureError('input changed during fixture')

def main():
    parser = argparse.ArgumentParser()
    for flag in ('receipt', 'sdk-debug', 'sdk-release', 'sdk-source', 'extractor'):
        parser.add_argument('--' + flag, required=True, type=absolute)
    args = parser.parse_args()
    receipt = pinned_receipt(args.receipt)
    if (type(receipt.get('schema')) is not int or receipt['schema'] != 1
        or receipt.get('accepted') is not False or receipt.get('integrationReady') is not False
        or receipt.get('sourceCommit') != SOURCE_COMMIT
        or receipt.get('sourceGitTree') != '9af9432aefeed6796e40e5019ffdc8600f3381e9'
        or not isinstance(receipt.get('patches'), list) or len(receipt['patches']) != 9
        or receipt['patches'][-1] != {'path': 'ThirdParty/BitwardenStrictEditSpike/strict-personal-write.patch', 'sha256': WRITE_PATCH_SHA}
        or not isinstance(receipt.get('packages'), dict)
        or set(receipt['packages']) != {'debug', 'release'}):
        raise FixtureError('receipt provenance mismatch')
    manifests = {}
    for mode, root in (('debug', args.sdk_debug), ('release', args.sdk_release)):
        info = receipt['packages'][mode]
        if (not isinstance(info, dict) or info.get('testOnly') is not (mode == 'debug')
            or info.get('consumerCompiled') is not True or info.get('consumerExecuted') is not False
            or not isinstance(info.get('manifestSHA256'), str) or not isinstance(info.get('files'), dict)):
            raise FixtureError('receipt package record')
        manifests[mode] = info['manifestSHA256']
        validate_package(root, mode, manifests[mode])
        manifest = read_json(root / 'build-manifest.json')
        if (inventory(root) != info['files'] or manifest.get('dylibSHA256') != info.get('dylibSHA256')
            or manifest.get('candidateGitTree') != receipt.get('candidateGitTree')
            or manifest.get('sourceManifestSHA256') != receipt.get('sourceManifestSHA256')):
            raise FixtureError('receipt inventory mismatch')
    output = run_fixture(args.sdk_debug, args.sdk_release, args.sdk_source, args.extractor,
                         args.receipt, manifests['debug'], manifests['release'])
    print('strict-sdk8-receipt=' + str(output / 'receipt.json'))

if __name__ == '__main__':
    main()
