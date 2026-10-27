import os
import signal
import subprocess
import sys
import hashlib
import json
import plistlib
import copy
from unittest import mock
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/build-native-bitwarden-sdk.py'
spec = importlib.util.spec_from_file_location('native_sdk_package', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
runner = module.load_runner()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)


def fixture(root):
    files = {
        'Package.swift': '// swift-tools-version: 5.9\n',
        'Sources/ArcusisBitwardenSDK/Bindings.swift': 'import BitwardenFFI\n',
        'Sources/BitwardenSdkSupport/NaiveDateFormatter.swift': 'struct Formatter {}\n',
        'Sources/BitwardenFFI/include/module.modulemap': 'module BitwardenFFI { header "bitwardenFFI.h" export * }\n',
        'Sources/BitwardenFFI/include/bitwardenFFI.h': 'void ffi(void);\n',
        'Frameworks/BitwardenSDK.xcframework/Info.plist': '<plist/>\n',
        'Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib': 'owned dylib\n',
        'ThirdPartyNotices/LICENSE': 'license\n',
        'ThirdPartyNotices/LICENSE_GPL.txt': 'gpl\n',
        'ThirdPartyNotices/LICENSE_SDK.txt': 'terms\n',
        'ThirdPartyNotices/DISCLAIMER.md': 'disclaimer\n',
    }
    for name, value in files.items():
        write(root / name, value)
    manifest = {
        'sourceCommit': runner.SOURCE_COMMIT,
        'sourceGitTree': runner.SOURCE_TREE,
        'sourceCargoLockSHA256': runner.SOURCE_LOCK_SHA,
        'candidateCargoLockSHA256': runner.CANDIDATE_LOCK_SHA,
        'patchSHA256': dict(runner.PATCH_SHAS),
        'changedPaths': sorted(runner.CHANGED_PATHS),
        'bindingTreeSHA256': module.tree_digest(root / 'Sources/ArcusisBitwardenSDK'),
        'generatedModuleNames': ['BitwardenFFI'],
        'supportSHA256': module.digest(root / 'Sources/BitwardenSdkSupport/NaiveDateFormatter.swift'),
        'licenseSHA256': {name: module.digest(root / 'ThirdPartyNotices' / name) for name in
                          ('LICENSE', 'LICENSE_GPL.txt', 'LICENSE_SDK.txt', 'DISCLAIMER.md')},
        'dylibSHA256': module.digest(root / 'Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib'),
    }
    manifest['fileSHA256'] = {p.relative_to(root).as_posix(): module.digest(p) for p in module.safe_tree(root)}
    return manifest


class NativeSDKPackageTests(unittest.TestCase):
    def test_accepts_exact_valid_package_and_runner_path_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Package'
            manifest = fixture(root)
            self.assertEqual(manifest['changedPaths'], sorted(runner.CHANGED_PATHS))
            module.validate_package(root, manifest)

    def test_rejects_wrong_pin_patch_lock_and_path_set(self):
        mutations = (
            ('sourceCommit', 'wrong', 'source pin'),
            ('sourceGitTree', 'wrong', 'source Git tree'),
            ('sourceCargoLockSHA256', 'wrong', 'Cargo.lock'),
            ('candidateCargoLockSHA256', 'wrong', 'Cargo.lock'),
            ('patchSHA256', {}, 'patch digest'),
            ('changedPaths', ['same'] * 22, 'changed-path'),
        )
        for key, value, message in mutations:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'Package'
                manifest = fixture(root)
                manifest[key] = value
                with self.assertRaisesRegex(ValueError, message):
                    module.validate_package(root, manifest)

    def test_rejects_payload_mutation_missing_or_extra_member(self):
        cases = (
            ('Sources/ArcusisBitwardenSDK/Bindings.swift', 'changed\n'),
            ('Sources/BitwardenSdkSupport/NaiveDateFormatter.swift', 'changed\n'),
            ('Sources/BitwardenFFI/include/bitwardenFFI.h', 'changed\n'),
            ('Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib', 'changed\n'),
            ('ThirdPartyNotices/LICENSE_SDK.txt', 'changed\n'),
        )
        for name, content in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'Package'
                manifest = fixture(root)
                write(root / name, content)
                with self.assertRaisesRegex(ValueError, 'digest|inventory'):
                    module.validate_package(root, manifest)
        for remove in (True, False):
            with self.subTest(remove=remove), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'Package'
                manifest = fixture(root)
                extra = root / 'Unexpected.txt'
                if remove:
                    (root / 'Package.swift').unlink()
                else:
                    write(extra, 'extra\n')
                with self.assertRaises(ValueError):
                    module.validate_package(root, manifest)

    def test_rejects_invalid_modulemap_and_symlinked_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Package'
            manifest = fixture(root)
            write(root / 'Sources/BitwardenFFI/include/module.modulemap', 'module Broken {}\n')
            with self.assertRaisesRegex(ValueError, 'modulemap'):
                module.validate_package(root, manifest)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Package'
            manifest = fixture(root)
            (root / 'Sources/BitwardenFFI/include/escape.h').symlink_to(root / 'Package.swift')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                module.validate_package(root, manifest)

    def test_rejects_unsafe_or_stale_output_and_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'build'
            root.mkdir()
            stale = root / 'output'
            stale.mkdir()
            with self.assertRaisesRegex(ValueError, 'fresh'):
                module.validate_output_path(root, stale)
            existing_cache = root / 'existing-cache'
            existing_cache.mkdir()
            with self.assertRaisesRegex(ValueError, 'Rust cache'):
                module.validate_cache_path(existing_cache)
            target = root / 'cache-link'
            target.symlink_to(root)
            with self.assertRaisesRegex(ValueError, 'Rust cache'):
                module.validate_cache_path(target)
            parent = root / 'parent-link'
            parent.symlink_to(root)
            with self.assertRaisesRegex(ValueError, 'Rust cache'):
                module.validate_cache_path(parent / 'fresh-cache')

    def run_owned_group_case(self, parent_code, timeout, expected_message, expected_log):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pgid_file = root / 'pgid'
            child_code = (
                'import os,signal,time; '
                'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                f"open({str(pgid_file)!r}, 'w').write(str(os.getpgrp())); "
                f"open({str(root / 'child-ready')!r}, 'w').write(str(os.getpid())); "
                'time.sleep(60)'
            )
            parent_code = parent_code.replace('CHILD_CODE', repr(child_code)).replace('READY_PATH', repr(str(root / 'child-ready')))
            try:
                with self.assertRaisesRegex(RuntimeError, expected_message):
                    module.command(
                        [sys.executable, '-c', parent_code], root, os.environ.copy(),
                        timeout=timeout, log_dir=root / 'logs',
                    )
                self.assertTrue(pgid_file.exists(), 'descendant started and recorded owned group')
                pgid = int(pgid_file.read_text())
                with self.assertRaises(ProcessLookupError):
                    os.killpg(pgid, 0)
                logs = list((root / 'logs').glob('*.log'))
                self.assertEqual(len(logs), 1)
                self.assertLessEqual(logs[0].stat().st_size, 65536)
                self.assertIn(expected_log, logs[0].read_text())
            finally:
                # Fixture owns this isolated session; clean it even if assertion fails.
                child_file = root / 'child-ready'
                if child_file.exists():
                    child_pid = int(child_file.read_text())
                    try:
                        if os.getpgid(child_pid) == int(pgid_file.read_text()):
                            os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_timeout_kills_sigterm_ignoring_descendant_with_redirected_pipes(self):
        parent = (
            'import subprocess,sys,time; print("timeout-marker", flush=True); '
            'subprocess.Popen([sys.executable, "-c", CHILD_CODE], '
            'stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); '
            'time.sleep(60)'
        )
        self.run_owned_group_case(parent, 0.2, 'timed out', 'timeout-marker')

    def test_nonzero_exit_kills_sigterm_ignoring_descendant(self):
        parent = (
            'import subprocess,sys; print("failure-marker", flush=True); '
            'subprocess.Popen([sys.executable, "-c", CHILD_CODE], '
            'stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); '
            'import pathlib,time; p=pathlib.Path(READY_PATH); '
            'exec(\"while not p.exists(): time.sleep(0.01)\"); raise SystemExit(7)'
        )
        self.run_owned_group_case(parent, 5, r'failed \(7\)', 'failure-marker')


def candidate_fixture(root):
    base = fixture(root)
    write(root / 'Package.swift', module.SDK_PACKAGE_SWIFT)
    write(root / 'Sources/BitwardenFFI/shim.c', module.SDK_FFI_SHIM)
    framework = root / 'Frameworks/BitwardenSDK.xcframework'
    info = {'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64', 'LibraryPath': 'libbitwarden_uniffi.dylib',
                                   'HeadersPath': 'Headers', 'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'macos'}],
            'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    ffi = root / 'Sources/BitwardenFFI/include'
    headers = framework / 'macos-arm64/Headers'; headers.mkdir(parents=True)
    for name in ('bitwardenFFI.h', 'module.modulemap'):
        (headers / name).write_bytes((ffi / name).read_bytes())
    base['fileSHA256'] = {p.relative_to(root).as_posix(): module.digest(p) for p in module.safe_tree(root)}
    swift = root / 'Sources/ArcusisBitwardenSDK'
    generated = {p.name: module.digest(p) for p in swift.iterdir()}
    generated['bitwardenFFI.h'] = module.digest(ffi / 'bitwardenFFI.h')
    pin = {'sourceCommit': 'source', 'sourceGitTree': 'tree', 'sourceCargoLockSHA256': 'base-lock',
           'candidateCargoLockSHA256': 'candidate-lock', 'patchSHA256': {'patch': 'hash'},
           'changedPaths': ['exact'], 'sourceManifestSHA256': 'manifest', 'fullDiffSHA256': 'diff',
           'licenseSHA256': base['licenseSHA256'], 'supportSHA256': base['supportSHA256'],
           'minMacOS': '26.0', 'architecture': 'arm64', 'accepted': False, 'integration_ready': False,
           'generatedSHA256': generated, 'combinedModuleMapSHA256': module.digest(ffi / 'module.modulemap')}
    manifest = {key: pin[key] for key in ('sourceCommit', 'sourceGitTree', 'sourceCargoLockSHA256',
        'candidateCargoLockSHA256', 'patchSHA256', 'changedPaths', 'sourceManifestSHA256', 'fullDiffSHA256',
        'licenseSHA256', 'supportSHA256', 'minMacOS', 'architecture', 'accepted', 'integration_ready')}
    manifest.update(schema=1, bindingTreeSHA256=base['bindingTreeSHA256'],
                    generatedModuleNames=base['generatedModuleNames'], dylibSHA256=base['dylibSHA256'],
                    fileSHA256=base['fileSHA256'])
    return pin, manifest


class OrganizationCandidateTests(unittest.TestCase):
    def test_frozen_pin_and_exact_layer_order(self):
        pin = module.read_organization_pin()
        self.assertEqual(len(pin['changedPaths']), 31)
        self.assertEqual(list(module.ORG_PATCH_ORDER)[2:], [
            'ThirdParty/BitwardenSyncSpike/sync.patch',
            'ThirdParty/BitwardenSyncSpike/organization-keys.patch',
            'ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch'])
        self.assertIs(pin['accepted'], False)
        self.assertIs(pin['integration_ready'], False)
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'pin.json'; fake.write_text('{}')
            with mock.patch.object(module, 'ORG_PIN', fake), self.assertRaisesRegex(ValueError, 'pin'):
                module.read_organization_pin()

    def test_candidate_manifest_rejects_flags_paths_and_untrusted_dylib(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Package'; pin, manifest = candidate_fixture(root)
            with mock.patch.object(module, 'read_organization_pin', return_value=pin):
                module.validate_package(root, manifest, organization=True, expected_dylib=manifest['dylibSHA256'])
                for key, value in [('accepted', True), ('integration_ready', 0), ('changedPaths', ['foreign']),
                                   ('sourceManifestSHA256', 'bad'), ('fullDiffSHA256', 'bad'), ('schema', True)]:
                    changed = copy.deepcopy(manifest); changed[key] = value
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        module.validate_package(root, changed, organization=True, expected_dylib=manifest['dylibSHA256'])
                changed = copy.deepcopy(manifest); changed['extra'] = 1
                with self.assertRaisesRegex(ValueError, 'shape'):
                    module.validate_package(root, changed, organization=True, expected_dylib=manifest['dylibSHA256'])
                with self.assertRaisesRegex(ValueError, 'provenance'):
                    module.validate_package(root, manifest, organization=True)
                with self.assertRaisesRegex(ValueError, 'provenance'):
                    module.validate_package(root, manifest, organization=True, expected_dylib='wrong')
                extra = root / 'extra.txt'; write(extra, 'extra')
                changed = copy.deepcopy(manifest); changed['fileSHA256']['extra.txt'] = module.digest(extra)
                with self.assertRaisesRegex(ValueError, 'path inventory'):
                    module.validate_package(root, changed, organization=True, expected_dylib=manifest['dylibSHA256'])
                extra.unlink(); (root / 'empty-extra').mkdir()
                with self.assertRaisesRegex(ValueError, 'directory inventory'):
                    module.validate_package(root, manifest, organization=True, expected_dylib=manifest['dylibSHA256'])

    def test_candidate_rejects_generated_or_payload_drift_even_with_rehashed_manifest(self):
        for path in ('Sources/ArcusisBitwardenSDK/Bindings.swift', 'Sources/BitwardenFFI/include/bitwardenFFI.h'):
            with self.subTest(path=path), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'Package'; pin, manifest = candidate_fixture(root)
                write(root / path, 'tampered\n')
                manifest['fileSHA256'][path] = module.digest(root / path)
                if path.endswith('.swift'):
                    manifest['bindingTreeSHA256'] = module.tree_digest(root / 'Sources/ArcusisBitwardenSDK')
                with mock.patch.object(module, 'read_organization_pin', return_value=pin), self.assertRaises(ValueError):
                    module.validate_package(root, manifest, organization=True, expected_dylib=manifest['dylibSHA256'])

    def test_complete_source_manifest_detects_added_and_mutated_files_and_modes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); write(root / 'nested/file', 'one'); first = module.source_manifest(root)
            write(root / 'nested/added', 'two'); self.assertNotEqual(first, module.source_manifest(root))
            (root / 'nested/added').unlink(); self.assertEqual(first, module.source_manifest(root))
            (root / 'nested/file').chmod(0o755); self.assertNotEqual(first, module.source_manifest(root))
            (root / 'nested/file').chmod(0o644); write(root / 'nested/file', 'other'); self.assertNotEqual(first, module.source_manifest(root))
            (root / 'nested/.git').mkdir()
            with self.assertRaisesRegex(ValueError, 'nested source git'):
                module.source_manifest(root)

    def test_cache_rejects_extra_binding_drift_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); (root / 'sdk-frozen').mkdir(); (root / 'cargo-home/registry').mkdir(parents=True)
            write(root / 'generated-final/A.swift', 'generated')
            write(root / 'target-frozen/debug/libbitwarden_uniffi.dylib', 'library')
            write(root / 'target-frozen/debug/deps/libbitwarden_uniffi.dylib', 'library')
            write(root / 'target-frozen/debug/uniffi-bindgen', 'bindgen')
            pin = {'generatedSHA256': {'A.swift': module.digest(root / 'generated-final/A.swift')},
                   'sourceProofDylibSHA256': module.digest(root / 'target-frozen/debug/libbitwarden_uniffi.dylib'),
                   'sourceProofBindgenSHA256': module.digest(root / 'target-frozen/debug/uniffi-bindgen')}
            with mock.patch.object(module, 'validate_organization_source'):
                module.validate_organization_cache(root, pin)
                write(root / 'generated-final/extra.h', 'extra')
                with self.assertRaisesRegex(ValueError, 'binding'):
                    module.validate_organization_cache(root, pin)
                (root / 'generated-final/extra.h').unlink()
                write(root / 'target-frozen/debug/deps/libbitwarden_uniffi.dylib', 'drift')
                with self.assertRaisesRegex(ValueError, 'dylib'):
                    module.validate_organization_cache(root, pin)
                write(root / 'target-frozen/debug/deps/libbitwarden_uniffi.dylib', 'library')
                (root / 'cargo-home/link').symlink_to(root / 'sdk-frozen')
                with self.assertRaisesRegex(ValueError, 'symlink'):
                    module.validate_organization_cache(root, pin)

    def test_successful_candidate_command_reaps_owned_descendant(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); ready = root / 'ready'; group = root / 'group'
            child = ('import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                     f"open({str(group)!r},'w').write(str(os.getpgrp())); "
                     f"open({str(ready)!r},'w').write('ready'); time.sleep(60)")
            parent = ('import subprocess,sys,pathlib,time; '
                      f"subprocess.Popen([sys.executable,'-c',{child!r}], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                      f"p=pathlib.Path({str(ready)!r}); exec(\"while not p.exists(): time.sleep(0.01)\"); "
                      "print('ok')")
            result = module.organization_command([sys.executable, '-c', parent], root, os.environ.copy(), 10)
            self.assertEqual(result.strip(), 'ok')
            with self.assertRaises(ProcessLookupError): os.killpg(int(group.read_text()), 0)

    def test_shared_interface_staging_requires_complete_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); generated = root / 'generated'; generated.mkdir(); sdk = root / 'sdk'
            write(sdk / 'crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift', 'support')
            write(generated / 'A.swift', 'swift'); write(generated / 'A.h', 'header')
            with self.assertRaisesRegex(ValueError, 'missing'):
                module.stage_generated_sources(sdk, generated, root / 'missing')
            write(generated / 'A.modulemap', 'module A { header "A.h" export * }')
            maps = module.stage_generated_sources(sdk, generated, root / 'Package')
            self.assertEqual([p.name for p in maps], ['A.modulemap'])
            self.assertEqual((root / 'Package/Sources/ArcusisBitwardenSDK/A.swift').read_text(), 'swift')
            self.assertEqual((root / 'Package/Sources/BitwardenFFI/include/A.h').read_text(), 'header')
            self.assertEqual((root / 'Package/Sources/BitwardenFFI/include/module.modulemap').read_text(), 'module A { header "A.h" export * }\n')


def refresh_fixture(root):
    pin, manifest = candidate_fixture(root)
    swift = root / 'Sources/ArcusisBitwardenSDK/Bindings.swift'
    swift.write_text('func refreshPasswordManagerToken(\nfunc syncWithOutcome(\nfunc sync(force:\nenum SyncOutcome:\nenum RefreshError:\n')
    pin['generatedSHA256'][swift.name] = module.digest(swift)
    manifest['bindingTreeSHA256'] = module.tree_digest(swift.parent)
    manifest['fileSHA256'][swift.relative_to(root).as_posix()] = module.digest(swift)
    pin.update(candidateGitTree='six-layer-tree', rustToolchain='1.98.0',
               sourceProofDylibSHA256=manifest['dylibSHA256'])
    manifest.update(candidateGitTree=pin['candidateGitTree'], rustToolchain=pin['rustToolchain'])
    (root / 'build-manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    return pin, manifest


class RefreshCandidateTests(unittest.TestCase):
    def test_pin_fixes_refresh_tree_toolchain_and_patch_order(self):
        pin = module.read_refresh_pin()
        self.assertEqual(pin['candidateGitTree'], '64151eb07bdbe0bba1b48aeeea6a8b1add2c4ac9')
        self.assertEqual(pin['rustToolchain'], '1.98.0')
        self.assertEqual(module.REFRESH_PATCH_ORDER[-1], 'ThirdParty/BitwardenRefreshSpike/refresh.patch')
        self.assertEqual(len(pin['changedPaths']), 35)
        self.assertIs(pin['accepted'], False)
        self.assertIs(pin['integration_ready'], False)
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'pin.json'; fake.write_text('{}')
            with mock.patch.object(module, 'REFRESH_PIN', fake), self.assertRaises(ValueError):
                module.read_refresh_pin()

    def test_refresh_manifest_and_generated_payload_reject_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Package'; pin, manifest = refresh_fixture(root)
            with mock.patch.object(module, 'read_refresh_pin', return_value=pin):
                module.validate_package(root, manifest, refresh=True, expected_dylib=manifest['dylibSHA256'])
                for key, value in [('accepted', True), ('integration_ready', True),
                                   ('candidateGitTree', 'wrong'), ('rustToolchain', '1.90'),
                                   ('sourceManifestSHA256', 'wrong')]:
                    changed = copy.deepcopy(manifest); changed[key] = value
                    (root / 'build-manifest.json').write_text(json.dumps(changed))
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        module.validate_package(root, changed, refresh=True, expected_dylib=manifest['dylibSHA256'])
                (root / 'build-manifest.json').write_text('{}')
                with self.assertRaisesRegex(ValueError, 'on-disk manifest'):
                    module.validate_package(root, manifest, refresh=True, expected_dylib=manifest['dylibSHA256'])
                path = root / 'Sources/ArcusisBitwardenSDK/Bindings.swift'
                path.write_text(path.read_text() + 'changed binding')
                changed = copy.deepcopy(manifest)
                changed['bindingTreeSHA256'] = module.tree_digest(path.parent)
                changed['fileSHA256'][path.relative_to(root).as_posix()] = module.digest(path)
                (root / 'build-manifest.json').write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'generated Swift inventory'):
                    module.validate_package(root, changed, refresh=True, expected_dylib=manifest['dylibSHA256'])

    def test_refresh_rejects_rehashed_extra_and_foreign_dylib(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Package'; pin, manifest = refresh_fixture(root)
            with mock.patch.object(module, 'read_refresh_pin', return_value=pin):
                with self.assertRaisesRegex(ValueError, 'provenance'):
                    module.validate_package(root, manifest, refresh=True, expected_dylib='foreign')
                dylib = root / 'Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib'
                original = dylib.read_text(); dylib.write_text('foreign library')
                changed = copy.deepcopy(manifest); changed['dylibSHA256'] = module.digest(dylib)
                changed['fileSHA256'][dylib.relative_to(root).as_posix()] = module.digest(dylib)
                (root / 'build-manifest.json').write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'provenance'):
                    module.validate_package(root, changed, refresh=True, expected_dylib=changed['dylibSHA256'])
                dylib.write_text(original)
                extra = root / 'extra.txt'; write(extra, 'extra')
                changed = copy.deepcopy(manifest); changed['fileSHA256']['extra.txt'] = module.digest(extra)
                (root / 'build-manifest.json').write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'path inventory'):
                    module.validate_package(root, changed, refresh=True, expected_dylib=manifest['dylibSHA256'])


class RefreshGeneratorProvenanceTests(unittest.TestCase):
    def test_fresh_build_executes_constructed_tool_and_reuse_requires_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); sdk = root / 'sdk'; sdk.mkdir(); target = root / 'target'; target.mkdir()
            generated = root / 'generated'; dylib = root / 'sdk.dylib'; write(dylib, 'dylib')
            bindgen = target / 'aarch64-apple-darwin/release/uniffi-bindgen'
            pin = {'target': 'aarch64-apple-darwin', 'sourceProofBindgenSHA256': hashlib.sha256(b'historical').hexdigest()}
            common = ['--offline', '--locked', '--release', '--jobs', '2', '--target', pin['target']]
            calls = []
            def command(argv, cwd, env, timeout=3600):
                calls.append((list(argv), cwd))
                if argv[:3] == ['cargo', '+1.98.0', 'build']:
                    bindgen.parent.mkdir(parents=True); bindgen.write_bytes(b'fresh-compiled'); bindgen.chmod(0o755)
                else:
                    self.assertEqual(argv[0], str(bindgen)); write(generated / 'Interface.swift', 'generated')
                return ''
            with mock.patch.object(module, 'refresh_command', side_effect=command):
                observed, recipe = module.build_refresh_generator(sdk, target, generated, dylib, pin, {}, common)
            self.assertEqual(observed, hashlib.sha256(b'fresh-compiled').hexdigest())
            self.assertEqual(recipe, [call[0] for call in calls])
            self.assertEqual(calls[0][0], ['cargo', '+1.98.0', 'build', *common, '--package', 'uniffi-bindgen'])
            self.assertEqual(calls[1][0][0:3], [str(bindgen), 'generate', str(dylib)])
            with self.assertRaisesRegex(ValueError, 'reused generator provenance'):
                module.validate_refresh_reused_generator(bindgen, pin)
            bindgen.write_bytes(b'historical')
            self.assertEqual(module.validate_refresh_reused_generator(bindgen, pin), pin['sourceProofBindgenSHA256'])

    def test_fresh_refuses_existing_tool_and_tool_changed_during_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); sdk = root / 'sdk'; sdk.mkdir(); target = root / 'target'; generated = root / 'generated'
            bindgen = target / 'aarch64-apple-darwin/release/uniffi-bindgen'; write(bindgen, 'preexisting'); bindgen.chmod(0o755)
            pin = {'target': 'aarch64-apple-darwin'}
            with mock.patch.object(module, 'refresh_command') as command, self.assertRaisesRegex(ValueError, 'already exists'):
                module.build_refresh_generator(sdk, target, generated, root / 'dylib', pin, {}, [])
            command.assert_not_called()
            bindgen.unlink()
            def mutate(argv, cwd, env, timeout=3600):
                if argv[:3] == ['cargo', '+1.98.0', 'build']:
                    bindgen.write_bytes(b'built'); bindgen.chmod(0o755)
                else:
                    bindgen.write_bytes(b'changed')
                return ''
            with mock.patch.object(module, 'refresh_command', side_effect=mutate), self.assertRaisesRegex(ValueError, 'changed during execution'):
                module.build_refresh_generator(sdk, target, generated, root / 'dylib', pin, {}, [])


class BoundedCandidateTests(unittest.TestCase):
    def test_seventh_layer_pin_preserves_interfaces_and_historical_pin(self):
        prior = module.read_refresh_pin()
        bounded = module.read_bounded_pin()
        self.assertEqual(bounded['candidateGitTree'], '0a934e609b3dfef012a3477d2973ace834b1a1c2')
        self.assertEqual(bounded['generatedSHA256'], prior['generatedSHA256'])
        self.assertEqual(bounded['sourceProofBindgenSHA256'], prior['sourceProofBindgenSHA256'])
        self.assertEqual(len(bounded['changedPaths']), 36)
        self.assertIs(bounded['accepted'], False)
        self.assertIs(bounded['integration_ready'], False)
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'pin.json'; fake.write_text('{}')
            with mock.patch.object(module, 'BOUNDED_PIN', fake), self.assertRaises(ValueError):
                module.read_bounded_pin()

    def test_bounded_manifest_rejects_rehashed_bindings_and_false_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Package'; pin, manifest = refresh_fixture(root)
            with mock.patch.object(module, 'read_bounded_pin', return_value=pin):
                module.validate_package(root, manifest, bounded=True, expected_dylib=manifest['dylibSHA256'])
                changed = copy.deepcopy(manifest); changed['accepted'] = True
                (root / 'build-manifest.json').write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    module.validate_package(root, changed, bounded=True, expected_dylib=manifest['dylibSHA256'])
                (root / 'build-manifest.json').write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, 'mutually exclusive'):
                    module.validate_package(root, manifest, refresh=True, bounded=True, expected_dylib=manifest['dylibSHA256'])
                binding = root / 'Sources/ArcusisBitwardenSDK/Bindings.swift'
                binding.write_text(binding.read_text() + 'tamper')
                changed = copy.deepcopy(manifest)
                changed['bindingTreeSHA256'] = module.tree_digest(binding.parent)
                changed['fileSHA256'][binding.relative_to(root).as_posix()] = module.digest(binding)
                (root / 'build-manifest.json').write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    module.validate_package(root, changed, bounded=True, expected_dylib=manifest['dylibSHA256'])


if __name__ == '__main__':
    unittest.main()
