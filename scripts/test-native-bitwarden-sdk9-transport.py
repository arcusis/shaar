#!/usr/bin/env python3
"""Pinned SDK9 generated-binding transport proof using the frozen SDK8 fixture primitives."""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import threading
import uuid
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
HELPER_SHA = 'cfb4653252fe700e34c8d8ae735e989657b8d355cb36c63588b81e3b2cf2c680'
RECEIPT_SHA = '9d6dd982c467bce5036f13a6c84bbcb38e223560114231816ddd89ea447f30e3'
MANIFESTS = {'debug': '65583856b2d973ae175c3a8184f87e3cb127edf54f5242a21f58083296cb844c',
             'release': 'fd4b5d40bf571f5bc5f64e78741c8663925c8bea6b0ccb9891b2d28f1392326d'}
SERVICE_CANDIDATE = '9a202a82c43c72c116f2748683adb6c197be7c441ca41d83a5f31c906f20c50d'
SERVICE_PATCH = '8917fd3a357dd3a075391ba9d9aeefbf5343f8a665aebf58c4bdb457ca80d76c'
TREE = 'd43b3922107fb7e760090cb9ec18715c73776b2a'
OWNED = ('scripts/test-native-bitwarden-sdk9-transport.py',
         'Tests/NativeBitwardenSDK9TransportTests/strict_service_consumer.swift',
         'Tests/NativeBitwardenSDK9TransportTests/test_sdk9_transport.py')
OUTPUT_ROOT = ROOT / 'build/NativeBitwardenSDK9Transport'


def load_module(path: Path, expected: str, name: str):
    if (not path.is_absolute() or path.resolve(strict=True) != path or
        any(p.is_symlink() for p in (path, *path.parents)) or
        not stat.S_ISREG(path.stat().st_mode)):
        raise ValueError('unsafe module path')
    source = path.read_bytes()
    if hashlib.sha256(source).hexdigest() != expected:
        raise ValueError('import digest mismatch')
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ValueError('module import failed')
    module = importlib.util.module_from_spec(spec)
    exec(compile(source, str(path), 'exec'), module.__dict__)
    return module


def inputs(helper, args):
    checkpoint = helper.regular(args.checkpoint)
    if helper.digest(checkpoint) != args.checkpoint_sha256:
        raise ValueError('checkpoint digest mismatch')
    data = helper.read_json(checkpoint)
    if set(data) != {'schema', 'files'} or type(data['schema']) is not int or data['schema'] != 1:
        raise ValueError('checkpoint schema')
    files = data['files']
    if not isinstance(files, dict) or set(files) != set(OWNED):
        raise ValueError('checkpoint inventory')
    if any(not isinstance(value, str) or len(value) != 64 or
           any(c not in '0123456789abcdef' for c in value) for value in files.values()):
        raise ValueError('checkpoint hash')
    actual = {name: helper.digest(ROOT / name) for name in OWNED}
    if actual != files:
        raise ValueError('checkpoint source drift')
    if helper.digest(args.helper) != HELPER_SHA or helper.digest(args.receipt) != RECEIPT_SHA:
        raise ValueError('fixed helper or receipt drift')
    receipt = helper.read_json(args.receipt)
    if (receipt.get('profile') != 'sdk9-service-shapes' or receipt.get('candidateGitTree') != TREE
        or receipt.get('serviceCandidateSHA256') != SERVICE_CANDIDATE
        or receipt.get('servicePatchSHA256') != SERVICE_PATCH):
        raise ValueError('SDK9 receipt provenance')
    packages = {}
    for mode, path in (('debug', args.debug), ('release', args.release)):
        packages[mode] = helper.validate_package(path, mode, MANIFESTS[mode])
        manifest = helper.read_json(path / 'build-manifest.json')
        if (manifest.get('profile') != 'sdk9-service-shapes' or manifest.get('candidateGitTree') != TREE
            or manifest.get('serviceCandidateSHA256') != SERVICE_CANDIDATE
            or manifest.get('servicePatchSHA256') != SERVICE_PATCH
            or receipt['packages'][mode]['manifestSHA256'] != MANIFESTS[mode]):
            raise ValueError('SDK9 package provenance')
    vector = args.sdk_source / 'crates/bitwarden-core/src/client/test_accounts.rs'
    if helper.digest(vector) != helper.VECTOR_SHA or helper.digest(args.extractor) != helper.EXTRACTOR_SHA:
        raise ValueError('vector or extractor drift')
    return {'checkpoint': args.checkpoint_sha256, 'sources': actual, 'helper': HELPER_SHA,
            'receipt': RECEIPT_SHA, 'packages': packages, 'vector': helper.VECTOR_SHA,
            'extractor': helper.EXTRACTOR_SHA}


def fault_payload(seed, fault):
    altered = json.loads(json.dumps(seed))
    if fault in ('notes', 'history'):
        prefix, mac = altered['notes'].rsplit('|', 1)
        corrupt = prefix + '|' + ('A' if mac[0] != 'A' else 'B') + mac[1:]
        if fault == 'notes':
            altered['notes'] = corrupt
        else:
            altered['passwordHistory'] = [{'password': corrupt, 'lastUsedDate': '2024-01-01T00:00:00Z'}]
    elif fault == 'checksum':
        uri = altered['login']['uris'][0]
        uri['uriChecksum'] = uri['uri']
    elif fault == 'mixed':
        altered['card'] = {'cardholderName': None}
    elif fault != 'valid':
        raise ValueError('unknown negative mode')
    return altered


def negative_types(helper):
    class NegativeHandler(helper.Handler):
        def do_GET(self):
            if self.path.startswith('/fixture/fault-'):
                try:
                    self.count_request()
                    mode = self.path.removeprefix('/fixture/fault-')
                    if mode not in ('notes', 'history', 'checksum', 'mixed', 'valid'):
                        raise helper.FixtureError('unknown negative mode')
                    if self.client_address[0] != '127.0.0.1':
                        raise helper.FixtureError('peer')
                    with self.server.lock:
                        self.server.fault = mode
                    self.send_json(200, {})
                except (ValueError, OSError, helper.FixtureError):
                    self.note_error('negative control rejected')
                return
            if self.path.startswith('/api/sync'):
                try:
                    self.count_request()
                    parts = urlsplit(self.path)
                    if (self.client_address[0] != '127.0.0.1' or parts.path != '/api/sync'
                        or parts.query not in ('', 'excludeDomains=true', 'excludeDomains=false')
                        or self.headers.get('Authorization') != 'Bearer synthetic-owned-token'):
                        raise helper.FixtureError('sync boundary')
                    with self.server.lock:
                        if self.server.seed is None:
                            raise helper.FixtureError('missing seed')
                        self.server.syncs += 1
                        if self.server.syncs > 5:
                            raise helper.FixtureError('sync count')
                        seed = json.loads(json.dumps(self.server.seed))
                        fault = self.server.fault
                    payload = fault_payload(seed, fault)
                    self.send_json(200, {'profile': {'organizations': []}, 'folders': [], 'sends': [],
                                         'policiesNew': [], 'ciphers': [payload]})
                except (ValueError, OSError, KeyError, TypeError, helper.FixtureError):
                    self.note_error('negative sync rejected')
                    self.send_json(400, {})
                return
            return super().do_GET()

    class NegativeServer(helper.Server):
        def __init__(self):
            super().__init__()
            self.RequestHandlerClass = NegativeHandler
            self.fault = 'valid'

    return NegativeServer


def negative_fixture(helper, server, binary, output, vector):
    address = server.server_address
    server.timeout = 0.1
    stop = threading.Event()
    worker = threading.Thread(target=lambda: serve(server, stop), daemon=False)
    try:
        worker.start()
        data = dict(vector, endpoint=f'http://127.0.0.1:{address[1]}')
        extra = {'ARCUSIS_STRICT_VECTOR': base64.b64encode(json.dumps(data).encode()).decode(),
                 'ARCUSIS_STRICT_NEGATIVE': '1'}
        stdout = helper.run_process(['/usr/bin/sandbox-exec', '-p', helper.runtime_sandbox(address[1]),
                                     str(binary)], output, extra, 90)
        if b'strict-sdk9-negative=passed' not in stdout:
            raise helper.FixtureError('negative marker missing')
        outcomes = {}
        for line in stdout.decode('ascii').splitlines():
            if not line.startswith('strict-sdk9-case:'):
                continue
            parts = line.split(':')
            if (len(parts) != 3 or parts[1] not in ('notes', 'history', 'checksum', 'mixed')
                or parts[2] not in ('prep-rejected', 'sync-rejected') or parts[1] in outcomes):
                raise helper.FixtureError('invalid negative marker')
            outcomes[parts[1]] = parts[2]
        if (set(outcomes) != {'notes', 'history', 'checksum', 'mixed'} or
            outcomes['notes'] != 'prep-rejected' or outcomes['history'] != 'prep-rejected'):
            raise helper.FixtureError('missing negative outcomes')
    finally:
        server.release.set()
        stop.set()
        if worker.ident is not None:
            worker.join(timeout=6)
        with server.lock:
            active, threads = list(server.active), list(server.threads)
        for peer in active:
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            peer.close()
        server.server_close()
        for thread in threads:
            thread.join(timeout=6)
        if worker.is_alive() or any(thread.is_alive() for thread in threads):
            raise helper.FixtureError('negative threads survived')
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(address) == 0:
                raise helper.FixtureError('negative listener survived')
        server.cleanup_ok = True
    if server.errors or server.puts != 0 or server.syncs != 5 or server.seed is None:
        raise helper.FixtureError('negative fixture counts')
    return {'outcomes': outcomes, 'requests': server.total, 'syncs': server.syncs, 'puts': server.puts,
            'errors': len(server.errors), 'listenerClosed': True, 'threadsStopped': True}


def serve(server, stop):
    while not stop.is_set():
        server.handle_request()


def main():
    parser = argparse.ArgumentParser()
    for flag in ('helper', 'checkpoint', 'receipt', 'debug', 'release', 'sdk-source', 'extractor'):
        parser.add_argument('--' + flag, type=Path, required=True)
    parser.add_argument('--checkpoint-sha256', required=True)
    args = parser.parse_args()
    for path in (args.helper, args.checkpoint, args.receipt, args.debug, args.release, args.sdk_source, args.extractor):
        if not path.is_absolute() or '..' in path.parts:
            raise ValueError('absolute paths required')
    helper = load_module(args.helper, HELPER_SHA, 'frozen_sdk8_transport')
    before = inputs(helper, args)
    if not OUTPUT_ROOT.is_dir() or any(p.is_symlink() for p in (OUTPUT_ROOT, *OUTPUT_ROOT.parents)):
        raise ValueError('unsafe output root')
    output = OUTPUT_ROOT / ('run-' + uuid.uuid4().hex)
    output.mkdir(mode=0o700)
    receipt = {'status': 'incomplete', 'inputs': before, 'scope': 'synthetic generated SDK9 only'}
    binaries = {}
    hashes = {}
    try:
        receipt['cleanupChecks'] = helper.verify_cleanup(output, receipt)
        vector = load_module(args.extractor, helper.EXTRACTOR_SHA, 'sdk_public_vector').sdk_vector(args.sdk_source)
        for mode, package in (('debug', args.debug), ('release', args.release)):
            stage = output / mode
            stage.mkdir(mode=0o700)
            shutil.copytree(package, stage / 'SDKPackage', symlinks=False)
            harness = stage / 'Harness'
            consumer = harness / 'Sources/StrictWriteConsumer'
            consumer.mkdir(parents=True)
            shutil.copyfile(ROOT / OWNED[1], consumer / 'StrictWriteConsumer.swift')
            (harness / 'Package.swift').write_text(helper.PACKAGE_SWIFT)
            if (inputs(helper, args) != before or
                helper.inventory(stage / 'SDKPackage') != helper.inventory(package) or
                helper.inventory(harness / 'Sources') !=
                {'StrictWriteConsumer/StrictWriteConsumer.swift': before['sources'][OWNED[1]]} or
                helper.digest(harness / 'Package.swift') != hashlib.sha256(helper.PACKAGE_SWIFT.encode()).hexdigest()):
                raise ValueError('pre-build input drift')
            scratch = stage / 'swift-build'
            cache = stage / 'swift-cache'
            cache.mkdir(mode=0o700)
            library = stage / 'SDKPackage/Frameworks/BitwardenSDK.xcframework/macos-arm64'
            command = ['swift', 'build', '--package-path', str(harness), '--scratch-path', str(scratch),
                       '--cache-path', str(cache), '--jobs', '2', '--disable-keychain', '--disable-netrc',
                       '--disable-dependency-cache', '--disable-prefetching', '--manifest-cache', 'none',
                       '--disable-sandbox', '-Xlinker', '-rpath', '-Xlinker', str(library)]
            sandboxed = ['/usr/bin/sandbox-exec', '-p', helper.BUILD_SANDBOX, *command]
            helper.run_process(sandboxed, output, {}, 300)
            lines = helper.run_process(sandboxed + ['--show-bin-path'], output, {}, 60).decode().splitlines()
            if len(lines) != 1:
                raise ValueError('ambiguous binary directory')
            directory = Path(lines[0])
            if (not directory.is_absolute() or directory.resolve(strict=True) != directory
                or not directory.is_relative_to(scratch) or any(p.is_symlink() for p in (directory, *directory.parents))):
                raise ValueError('unsafe binary directory')
            binaries[mode] = helper.regular(directory / 'StrictWriteConsumer')
            hashes[mode] = helper.digest(binaries[mode])
            verify(helper, args, before, output, binaries, hashes)
        for mode in ('release', 'debug'):
            verify(helper, args, before, output, binaries, hashes)
            server = helper.Server()
            try:
                receipt[mode] = helper.serve_fixture(server, [str(binaries[mode])], output, vector, mode == 'release')
            finally:
                receipt[mode + 'Counts'] = {'requests': server.total, 'syncs': server.syncs,
                                           'puts': server.puts, 'errors': len(server.errors),
                                           'listenerClosed': server.cleanup_ok}
            if mode == 'release' and server.total != 0:
                raise ValueError('release made HTTP request')
        verify(helper, args, before, output, binaries, hashes)
        server = negative_types(helper)()
        try:
            receipt['negative'] = negative_fixture(helper, server, binaries['debug'], output, vector)
        finally:
            receipt['negativeCounts'] = {'requests': server.total, 'syncs': server.syncs,
                                         'puts': server.puts, 'errors': len(server.errors),
                                         'listenerClosed': server.cleanup_ok}
        verify(helper, args, before, output, binaries, hashes)
        receipt['binarySHA256'] = hashes
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt['errorType'] = type(error).__name__
        raise
    finally:
        try:
            receipt['inputsUnchanged'] = inputs(helper, args) == before
        except BaseException:
            receipt['inputsUnchanged'] = False
        if not receipt['inputsUnchanged']:
            receipt['status'] = 'failed-input-drift'
        path = output / 'receipt.json'
        with path.open('x', encoding='utf-8') as stream:
            os.chmod(path, 0o600)
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write('\n')
        if not receipt['inputsUnchanged']:
            raise ValueError('input drift')
    print('SDK9 synthetic transport passed: ' + str(output))


def verify(helper, args, before, output, binaries, hashes):
    if inputs(helper, args) != before:
        raise ValueError('input drift')
    for mode, binary in binaries.items():
        package = args.debug if mode == 'debug' else args.release
        stage = output / mode
        if (helper.inventory(stage / 'SDKPackage') != helper.inventory(package)
            or helper.inventory(stage / 'Harness/Sources') !=
            {'StrictWriteConsumer/StrictWriteConsumer.swift': before['sources'][OWNED[1]]}
            or helper.digest(stage / 'Harness/Package.swift') != hashlib.sha256(helper.PACKAGE_SWIFT.encode()).hexdigest()
            or helper.digest(binary) != hashes[mode]):
            raise ValueError('staged input or binary drift')


if __name__ == '__main__':
    main()
