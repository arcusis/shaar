import os
import signal
import subprocess
import sys
import hashlib
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


if __name__ == '__main__':
    unittest.main()
