#!/usr/bin/env python3
"""Verify pinned SDK10 generated bindings with owned synthetic loopback fixtures."""
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

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = ROOT / 'build/NativeBitwardenStrictSDK10Transport'
HELPER_SHA = 'cfb4653252fe700e34c8d8ae735e989657b8d355cb36c63588b81e3b2cf2c680'
SDK9_RUNNER_SHA = 'dfc1e36d7f4e6f8d83fb01934652851a49ba0cc88854641d05411d9e25efeb3f'
CONSUMER_SHA = '61e8d9a7cb4f9cbb39c06090ff569cfb92d783ff701903e1ded41649e4d97e0e'
TREE = '3755ee1144f047435a9bc2ba7412b21e2f300f94'
PATCH = 'a1fa54b7affc3101c92b5ecaebee72209c90b4d75da4a9a368ca14642e8c91c4'
CANDIDATE = 'bdda46346fa82ec8aed81337b61d578039e774a76c5c3266d24820b4847c5a6d'
OWNED = ('scripts/test-native-bitwarden-sdk10-transport.py',
         'Tests/NativeBitwardenSDK10TransportTests/test_sdk10_transport.py')

MODE_INSERT = '''    let totpCase = ProcessInfo.processInfo.environment["ARCUSIS_STRICT_TOTP_CASE"]
    let totpValue: String
    switch totpCase {
    case "empty": totpValue = ""
    case "whitespace": totpValue = " "
    case "nonempty": totpValue = "synthetic-preserved-totp"
    case nil: totpValue = "synthetic-note"
    default: throw Failure()
    }
'''
MODE_BRANCH = '''    if let totpCase {
      try require(try await sync.sync(force: true))
      let first = sync.encryptedSnapshot()
      let original = try await client.vault().ciphers().decrypt(cipher: first.ciphers[0])
      try require(original.login?.totp == totpValue)
      guard let preparation = client.strictPreparePersonalLogin(
        cipherId: id, expectedGeneration: first.generation)
      else { throw Failure() }
      guard case .unconfirmed = await client.strictPersonalUpdate(
        preparation: preparation, username: "synthetic-updated-user", password: "synthetic-updated-password")
      else { throw Failure() }
      try require(try await sync.sync(force: true))
      let reconciled = sync.encryptedSnapshot()
      let updated = try await client.vault().ciphers().decrypt(cipher: reconciled.ciphers[0])
      try require(updated.login?.totp == (totpCase == "empty" ? nil : totpValue))
      try require(updated.login?.username == "synthetic-updated-user")
      try require(updated.login?.password == "synthetic-updated-password")
      try require(updated.name == original.name && updated.notes == original.notes)
      try require(updated.fields == original.fields && updated.attachments == original.attachments)
      try require(updated.login?.uris == original.login?.uris && updated.permissions == original.permissions)
      print("strict-sdk10-totp-\\(totpCase)=passed")
      return
    }
'''


def derive_consumer(raw: bytes) -> bytes:
    if hashlib.sha256(raw).hexdigest() != CONSUMER_SHA:
        raise ValueError('SDK9 consumer digest mismatch')
    source = raw.decode('utf-8')
    changes = [
        ('    let view = CipherView(\n', MODE_INSERT + '    let view = CipherView(\n'),
        ('      name: "synthetic-title", notes: "synthetic-note", type: .login,',
         '      name: "synthetic-title", notes: totpValue, type: .login,'),
        ('        "totp": optional(login.totp), "passwordRevisionDate": NSNull(),',
         '        "totp": optional(totpCase == nil ? login.totp : encrypted.notes), "passwordRevisionDate": NSNull(),'),
        ('    let sync = client.sync()\n', '    let sync = client.sync()\n' + MODE_BRANCH),
    ]
    for old, new in changes:
        if source.count(old) != 1:
            raise ValueError('consumer transformation anchor mismatch')
        source = source.replace(old, new, 1)
    return source.encode('utf-8')


def load_module(path, expected, name):
    if (not path.is_absolute() or path.resolve(strict=True) != path or
        any(part.is_symlink() for part in (path, *path.parents)) or not stat.S_ISREG(path.lstat().st_mode)):
        raise ValueError('unsafe module path')
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError('module digest mismatch')
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ValueError('module spec')
    module = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), 'exec'), module.__dict__)
    return module


def parse_bin_path(raw, scratch):
    if len(raw) > 16384:
        raise ValueError('binary directory output too large')
    lines = raw.decode('utf-8').splitlines()
    candidates = [line for line in lines if line.startswith('/')]
    if len(candidates) != 1:
        raise ValueError('ambiguous binary directory')
    directory = Path(candidates[0])
    if (directory.resolve(strict=True) != directory or not directory.is_dir() or
        not directory.is_relative_to(scratch) or
        any(part.is_symlink() for part in (directory, *directory.parents))):
        raise ValueError('unsafe binary directory')
    diagnostics = [line for line in lines if line != candidates[0] and line.strip()]
    if len(diagnostics) > 32 or any(len(line) > 512 for line in diagnostics):
        raise ValueError('binary directory diagnostics too large')
    return directory, diagnostics


def inputs(helper, args):
    if helper.digest(args.checkpoint) != args.checkpoint_sha256:
        raise ValueError('checkpoint digest')
    checkpoint = helper.read_json(args.checkpoint)
    if (set(checkpoint) != {'schema', 'files'} or type(checkpoint['schema']) is not int or
        checkpoint['schema'] != 1 or set(checkpoint['files']) != set(OWNED)):
        raise ValueError('checkpoint schema')
    sources = {name: helper.digest(ROOT / name) for name in OWNED}
    if sources != checkpoint['files']:
        raise ValueError('source drift')
    if (helper.digest(args.helper) != HELPER_SHA or helper.digest(args.sdk9_runner) != SDK9_RUNNER_SHA or
        helper.digest(args.consumer) != CONSUMER_SHA or helper.digest(args.receipt) != args.receipt_sha256):
        raise ValueError('fixed input drift')
    receipt = helper.read_json(args.receipt)
    if (receipt.get('profile') != 'sdk10-empty-totp' or receipt.get('candidateGitTree') != TREE or
        receipt.get('normalizationPatchSHA256') != PATCH or
        receipt.get('normalizationCandidateSHA256') != CANDIDATE):
        raise ValueError('SDK10 receipt provenance')
    packages = {}
    for mode, package, expected in (('debug', args.debug, args.debug_manifest_sha256),
                                    ('release', args.release, args.release_manifest_sha256)):
        packages[mode] = helper.validate_package(package, mode, expected)
        manifest = helper.read_json(package / 'build-manifest.json')
        if (manifest.get('profile') != 'sdk10-empty-totp' or manifest.get('candidateGitTree') != TREE or
            manifest.get('normalizationPatchSHA256') != PATCH or
            manifest.get('normalizationCandidateSHA256') != CANDIDATE or
            receipt['packages'][mode]['manifestSHA256'] != expected):
            raise ValueError('SDK10 package provenance')
    vector = args.sdk_source / 'crates/bitwarden-core/src/client/test_accounts.rs'
    if helper.digest(vector) != helper.VECTOR_SHA or helper.digest(args.extractor) != helper.EXTRACTOR_SHA:
        raise ValueError('vector or extractor mismatch')
    derived = derive_consumer(args.consumer.read_bytes())
    return {'checkpoint': args.checkpoint_sha256, 'sources': sources, 'receipt': args.receipt_sha256,
            'packages': packages, 'derived': hashlib.sha256(derived).hexdigest(),
            'helper': HELPER_SHA, 'sdk9Runner': SDK9_RUNNER_SHA, 'consumer': CONSUMER_SHA,
            'vector': helper.VECTOR_SHA, 'extractor': helper.EXTRACTOR_SHA}


def totp_fixture(helper, server, binary, output, vector, mode):
    address = server.server_address
    server.timeout = 0.1
    stop = threading.Event()
    def serve():
        while not stop.is_set():
            server.handle_request()
    worker = threading.Thread(target=serve, daemon=False)
    try:
        worker.start()
        data = dict(vector, endpoint=f'http://127.0.0.1:{address[1]}')
        env = {'ARCUSIS_STRICT_VECTOR': base64.b64encode(json.dumps(data).encode()).decode(),
               'ARCUSIS_STRICT_TOTP_CASE': mode}
        result = helper.run_process(['/usr/bin/sandbox-exec', '-p', helper.runtime_sandbox(address[1]),
                                     str(binary)], output, env, 90)
        if f'strict-sdk10-totp-{mode}=passed'.encode() not in result:
            raise helper.FixtureError('TOTP marker missing')
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
            raise helper.FixtureError('TOTP threads survived')
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(address) == 0:
                raise helper.FixtureError('TOTP listener survived')
        server.cleanup_ok = True
    if server.errors or server.puts != 1 or server.syncs != 2 or server.seed is None:
        raise helper.FixtureError('TOTP fixture counts')
    return {'requests': server.total, 'syncs': server.syncs, 'puts': server.puts,
            'errors': len(server.errors), 'listenerClosed': True, 'threadsStopped': True}


def verify(helper, args, before, output, binaries, hashes):
    if inputs(helper, args) != before:
        raise ValueError('input drift')
    for mode, binary in binaries.items():
        stage = output / mode
        package = args.debug if mode == 'debug' else args.release
        if (helper.inventory(stage / 'SDKPackage') != helper.inventory(package) or
            helper.inventory(stage / 'Harness/Sources') !=
            {'StrictWriteConsumer/StrictWriteConsumer.swift': before['derived']} or
            helper.digest(stage / 'Harness/Package.swift') != hashlib.sha256(helper.PACKAGE_SWIFT.encode()).hexdigest() or
            helper.digest(binary) != hashes[mode]):
            raise ValueError('staged input or binary drift')


def main():
    parser = argparse.ArgumentParser()
    for flag in ('helper', 'sdk9-runner', 'consumer', 'checkpoint', 'receipt', 'debug', 'release', 'sdk-source', 'extractor'):
        parser.add_argument('--' + flag, type=Path, required=True)
    for flag in ('checkpoint-sha256', 'receipt-sha256', 'debug-manifest-sha256', 'release-manifest-sha256'):
        parser.add_argument('--' + flag, required=True)
    args = parser.parse_args()
    for path in (args.helper, args.sdk9_runner, args.consumer, args.checkpoint, args.receipt,
                 args.debug, args.release, args.sdk_source, args.extractor):
        if not path.is_absolute() or '..' in path.parts:
            raise ValueError('absolute paths required')
    helper = load_module(args.helper, HELPER_SHA, 'frozen_sdk8_transport')
    sdk9 = load_module(args.sdk9_runner, SDK9_RUNNER_SHA, 'frozen_sdk9_transport')
    before = inputs(helper, args)
    if not OUTPUT_ROOT.is_dir() or any(part.is_symlink() for part in (OUTPUT_ROOT, *OUTPUT_ROOT.parents)):
        raise ValueError('unsafe output root')
    output = OUTPUT_ROOT / ('run-' + uuid.uuid4().hex)
    output.mkdir(mode=0o700)
    receipt = {'status': 'incomplete', 'inputs': before, 'scope': 'synthetic generated SDK10 only'}
    binaries, hashes = {}, {}
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
            (consumer / 'StrictWriteConsumer.swift').write_bytes(derive_consumer(args.consumer.read_bytes()))
            (harness / 'Package.swift').write_text(helper.PACKAGE_SWIFT)
            if (inputs(helper, args) != before or helper.inventory(stage / 'SDKPackage') != helper.inventory(package) or
                helper.inventory(harness / 'Sources') != {'StrictWriteConsumer/StrictWriteConsumer.swift': before['derived']} or
                helper.digest(harness / 'Package.swift') != hashlib.sha256(helper.PACKAGE_SWIFT.encode()).hexdigest()):
                raise ValueError('pre-build drift')
            scratch, cache = stage / 'swift-build', stage / 'swift-cache'
            cache.mkdir(mode=0o700)
            library = stage / 'SDKPackage/Frameworks/BitwardenSDK.xcframework/macos-arm64'
            command = ['swift', 'build', '--package-path', str(harness), '--scratch-path', str(scratch),
                       '--cache-path', str(cache), '--jobs', '2', '--disable-keychain', '--disable-netrc',
                       '--disable-dependency-cache', '--disable-prefetching', '--manifest-cache', 'none',
                       '--disable-sandbox', '-Xlinker', '-rpath', '-Xlinker', str(library)]
            sandboxed = ['/usr/bin/sandbox-exec', '-p', helper.BUILD_SANDBOX, *command]
            helper.run_process(sandboxed, output, {}, 300)
            directory, diagnostics = parse_bin_path(
                helper.run_process(sandboxed + ['--show-bin-path'], output, {}, 60), scratch)
            receipt[mode + 'BinPathDiagnostics'] = diagnostics
            binaries[mode] = helper.regular(directory / 'StrictWriteConsumer')
            hashes[mode] = helper.digest(binaries[mode])
            verify(helper, args, before, output, binaries, hashes)
        for mode in ('release', 'debug'):
            verify(helper, args, before, output, binaries, hashes)
            server = helper.Server()
            try:
                receipt[mode] = helper.serve_fixture(server, [str(binaries[mode])], output, vector, mode == 'release')
            finally:
                receipt[mode + 'Counts'] = {'requests': server.total, 'syncs': server.syncs, 'puts': server.puts,
                                            'errors': len(server.errors), 'listenerClosed': server.cleanup_ok}
            if mode == 'release' and server.total != 0:
                raise ValueError('release made HTTP request')
        verify(helper, args, before, output, binaries, hashes)
        server = sdk9.negative_types(helper)()
        try:
            receipt['negative'] = sdk9.negative_fixture(helper, server, binaries['debug'], output, vector)
        finally:
            receipt['negativeCounts'] = {'requests': server.total, 'syncs': server.syncs, 'puts': server.puts,
                                         'errors': len(server.errors), 'listenerClosed': server.cleanup_ok}
        for mode in ('empty', 'whitespace', 'nonempty'):
            verify(helper, args, before, output, binaries, hashes)
            server = helper.Server()
            try:
                receipt['totp-' + mode] = totp_fixture(helper, server, binaries['debug'], output, vector, mode)
            finally:
                receipt['totp-' + mode + '-counts'] = {'requests': server.total, 'syncs': server.syncs,
                    'puts': server.puts, 'errors': len(server.errors), 'listenerClosed': server.cleanup_ok}
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
    print('SDK10 synthetic transport passed: ' + str(output))


if __name__ == '__main__':
    main()
