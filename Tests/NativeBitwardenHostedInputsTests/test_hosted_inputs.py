import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('hosted_inputs', ROOT / 'scripts/prepare-native-bitwarden-hosted-inputs.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
BUILDER_SPEC = importlib.util.spec_from_file_location('sdk_builder', ROOT / 'scripts/build-native-bitwarden-strict-sdk.py')
BUILDER = importlib.util.module_from_spec(BUILDER_SPEC)
BUILDER_SPEC.loader.exec_module(BUILDER)


def archive():
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as tar:
        for name, data in [('Cargo.toml', b'[package]\nname="a"\nversion="1.0.0"\n'),
                           ('src/lib.rs', b'synthetic'), ('.gitignore', b'ignored'),
                           ('docs/.gitattributes', b'ignored')]:
            item = tarfile.TarInfo('a-1.0.0/' + name)
            item.mode = 0o644
            item.size = len(data)
            tar.addfile(item, io.BytesIO(data))
    return output.getvalue()


def sample_lock(source, checksum='a' * 64):
    return (f'[[package]]\nname="a"\nversion="1.0.0"\nsource="{source}"\n'
            f'checksum="{checksum}"\n').encode()


class HostedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()

    def tearDown(self):
        self.tmp.cleanup()

    def test_command_cleans_exited_leader_group_on_success_failure_and_timeout(self):
        for outcome in ('success', 'failure', 'timeout'):
            with self.subTest(outcome=outcome):
                calls = []

                class Process:
                    pid = 4242
                    returncode = None

                    def wait(self, timeout):
                        calls.append(('wait', timeout))
                        self.returncode = {'success': 0, 'failure': 23, 'timeout': -9}[outcome]
                        return self.returncode

                def spawn(argv, **kwargs):
                    self.assertTrue(kwargs['start_new_session'])
                    kwargs['stdout'].write(b'synthetic-output')
                    kwargs['stderr'].write(b'error: synthetic failure\n')
                    return Process()

                def killpg(pid, sig):
                    calls.append(('killpg', pid, sig))
                    if sig == 0:
                        raise ProcessLookupError()

                wait_result = None if outcome == 'timeout' else object()
                clock = [0, 1801, 1801] if outcome == 'timeout' else [0, 0]
                with patch.object(MODULE.subprocess, 'Popen', side_effect=spawn), \
                     patch.object(MODULE.os, 'waitid', return_value=wait_result), \
                     patch.object(MODULE.os, 'killpg', side_effect=killpg), \
                     patch.object(MODULE.time, 'monotonic', side_effect=clock):
                    if outcome == 'success':
                        self.assertEqual(MODULE.command(['synthetic'], self.root, {}, offline=False), 'synthetic-output')
                    elif outcome == 'failure':
                        with self.assertRaisesRegex(ValueError, r'owned command failed \(23\): error: synthetic failure'):
                            MODULE.command(['synthetic'], self.root, {}, offline=False)
                    else:
                        with self.assertRaises(subprocess.TimeoutExpired):
                            MODULE.command(['synthetic'], self.root, {}, offline=False)
                self.assertEqual(calls, [('killpg', 4242, signal.SIGKILL), ('wait', 5), ('killpg', 4242, 0)])

    def test_command_preserves_failure_when_cleanup_also_fails(self):
        class Process:
            pid = 4242
            returncode = None

            def wait(self, timeout):
                self.returncode = 23
                return 23

        def spawn(argv, **kwargs):
            kwargs['stderr'].write(b'error: synthetic failure\n')
            return Process()

        def killpg(pid, sig):
            if sig == signal.SIGKILL:
                raise PermissionError('synthetic cleanup failure')
            raise ProcessLookupError()

        with patch.object(MODULE.subprocess, 'Popen', side_effect=spawn), \
             patch.object(MODULE.os, 'waitid', return_value=object()), \
             patch.object(MODULE.os, 'killpg', side_effect=killpg):
            with self.assertRaisesRegex(ValueError, 'owned command failed') as result:
                MODULE.command(['synthetic'], self.root, {}, offline=False)
        self.assertEqual(result.exception.__notes__, ['owned process cleanup failed: PermissionError'])

    def test_command_retries_permission_unknown_until_absent_or_deadline(self):
        class Process:
            pid = 4242
            returncode = None

            def wait(self, timeout):
                self.returncode = 0
                return 0

        for persistent in (False, True):
            with self.subTest(persistent=persistent):
                probes = []

                def killpg(pid, sig):
                    if sig == signal.SIGKILL:
                        return
                    probes.append(pid)
                    if not persistent and len(probes) == 2:
                        raise ProcessLookupError()
                    raise PermissionError()

                clock = [0, 0, 6] if persistent else [0, 0, 1]
                with patch.object(MODULE.subprocess, 'Popen', return_value=Process()), \
                     patch.object(MODULE.os, 'waitid', return_value=object()), \
                     patch.object(MODULE.os, 'killpg', side_effect=killpg), \
                     patch.object(MODULE.time, 'monotonic', side_effect=clock), \
                     patch.object(MODULE.time, 'sleep'):
                    if persistent:
                        with self.assertRaisesRegex(ValueError, 'process group survived'):
                            MODULE.command(['synthetic'], self.root, {}, offline=False)
                    else:
                        self.assertEqual(MODULE.command(['synthetic'], self.root, {}, offline=False), '')
                self.assertEqual(len(probes), 1 if persistent else 2)

    def test_lock_unknown_duplicate_and_checksum(self):
        good = sample_lock(MODULE.REGISTRY)
        self.assertEqual(len(MODULE.parse_lock(good)), 1)
        for bad in (sample_lock('registry+https://other.invalid'), good + good,
                    sample_lock(MODULE.REGISTRY, 'bad')):
            with self.assertRaises(ValueError): MODULE.parse_lock(bad)

    def make_vendor(self):
        raw = archive()
        checksum = hashlib.sha256(raw).hexdigest()
        packages = {('a', '1.0.0'): (MODULE.REGISTRY, checksum)}
        cache = self.root / 'cargo/registry/cache/index'
        cache.mkdir(parents=True)
        (cache / 'a-1.0.0.crate').write_bytes(raw)
        vendor = self.root / 'vendor/a-1.0.0'
        (vendor / 'src').mkdir(parents=True)
        (vendor / 'Cargo.toml').write_bytes(b'[package]\nname="a"\nversion="1.0.0"\n')
        (vendor / 'src/lib.rs').write_bytes(b'synthetic')
        files = {key: entry['sha256'] for key, entry in MODULE.inventory(vendor).items()}
        (vendor / '.cargo-checksum.json').write_text(json.dumps(
            {'$comment': MODULE.CARGO_CHECKSUM_COMMENT, 'files': files, 'package': checksum}))
        return packages

    def test_vendor_complete_and_archive_bound(self):
        packages = self.make_vendor()
        MODULE.verify_archives(self.root / 'cargo', packages)
        MODULE.verify_vendor(self.root / 'vendor', packages)
        MODULE.verify_registry_vendor(self.root / 'cargo', self.root / 'vendor', packages)
        (self.root / 'vendor/a-1.0.0/src/lib.rs').write_text('tampered')
        with self.assertRaises(ValueError): MODULE.verify_vendor(self.root / 'vendor', packages)
        with self.assertRaises(ValueError): MODULE.verify_registry_vendor(self.root / 'cargo', self.root / 'vendor', packages)

    def test_exact_cargo_vendor_exclusions_only(self):
        for name in ('.gitignore', 'docs/.gitattributes', '.git/config', 'src/.git/config', '.cargo-ok'):
            self.assertTrue(MODULE.cargo_ignored(name))
        for name in ('src/.cargo-ok', 'src/lib.rs', 'src/.gitignored', 'Cargo.toml'):
            self.assertFalse(MODULE.cargo_ignored(name))

    def test_cargo_commit_identity_checked(self):
        valid = ('cargo 1.98.0 (797e8a9bc 2026-08-05)\ncommit-hash: ' + MODULE.CARGO_COMMIT +
                 '\nhost: aarch64-apple-darwin\n')
        with patch.object(MODULE, 'command', return_value=valid):
            MODULE.check_cargo_version(self.root / 'cargo', self.root, {})
        with patch.object(MODULE, 'command', return_value=valid.replace(MODULE.CARGO_COMMIT, '0' * 40)):
            with self.assertRaises(ValueError): MODULE.check_cargo_version(self.root / 'cargo', self.root, {})

    def test_metadata_missing_extra_and_stale_archive(self):
        packages = self.make_vendor()
        checksum = self.root / 'vendor/a-1.0.0/.cargo-checksum.json'
        original = json.loads(checksum.read_text())
        original['$comment'] = 'modified'
        checksum.write_text(json.dumps(original))
        with self.assertRaises(ValueError): MODULE.verify_vendor(self.root / 'vendor', packages)
        checksum.write_text('{"files":{},"package":"bad"}')
        with self.assertRaises(ValueError): MODULE.verify_vendor(self.root / 'vendor', packages)
        (self.root / 'cargo/registry/cache/index/extra.crate').write_bytes(b'x')
        with self.assertRaises(ValueError): MODULE.verify_archives(self.root / 'cargo', packages)
        (self.root / 'cargo/registry/cache/index/extra.crate').unlink()
        (self.root / 'cargo/registry/cache/index/a-1.0.0.crate').unlink()
        with self.assertRaises(ValueError): MODULE.verify_archives(self.root / 'cargo', packages)

    def test_symlinks_and_duplicate_json(self):
        packages = self.make_vendor()
        (self.root / 'vendor/a-1.0.0/src/link').symlink_to(self.root / 'vendor/a-1.0.0/src/lib.rs')
        with self.assertRaises(ValueError): MODULE.verify_vendor(self.root / 'vendor', packages)
        with self.assertRaises(ValueError): json.loads('{"x":1,"x":2}', object_pairs_hook=MODULE.unique)

    def test_special_file_and_extra_vendor_package(self):
        packages = self.make_vendor()
        extra = self.root / 'vendor/unknown-1.0.0'
        extra.mkdir()
        with self.assertRaises((ValueError, FileNotFoundError)): MODULE.verify_vendor(self.root / 'vendor', packages)
        extra.rmdir()
        os.mkfifo(self.root / 'vendor/a-1.0.0/src/fifo')
        with self.assertRaises(ValueError): MODULE.verify_vendor(self.root / 'vendor', packages)

    def test_git_tree_and_checkout_mismatch(self):
        db = self.root / 'git/db/passkey-rs-test'
        db.mkdir(parents=True)
        (db / 'config').write_text('[core]\nbare=true\n')
        checkout = self.root / 'git/checkouts/passkey-rs-test/043279e'
        checkout.mkdir(parents=True)
        (checkout / '.git').mkdir()
        (checkout / '.git/config').write_text('[core]\nbare=false\n[remote "origin"]\nurl=' + db.as_uri() + '\n')
        (checkout / 'file').write_bytes(b'ok')
        blob = hashlib.sha1(b'blob 2\0ok').hexdigest()
        def fake(argv, cwd, env, **kwargs):
            if 'rev-parse' in argv: return MODULE.GIT_TREE + '\n'
            if 'ls-tree' in argv: return '100644 blob ' + blob + '\tfile\0'
            return ''
        with patch.object(MODULE, 'command', side_effect=fake):
            self.assertEqual(MODULE.git_check(self.root, {})['tree'], MODULE.GIT_TREE)
            (checkout / 'file').write_bytes(b'bad')
            with self.assertRaises(ValueError): MODULE.git_check(self.root, {})
        with patch.object(MODULE, 'command', return_value='bad-tree\n'):
            with self.assertRaises(ValueError): MODULE.git_check(self.root, {})

    def test_unpinned_lock_and_pin_rejected(self):
        path = self.root / 'input'
        path.write_text('synthetic')
        with self.assertRaises(ValueError): MODULE.load_pin(path, path)

    def test_mixed_historical_and_hosted_profiles_rejected(self):
        full = ('inputs', 'preparer', 'checkpoint', 'digest', 'rustup', 'cargo')
        self.assertTrue(BUILDER.hosted_input_profile(BUILDER.SDK9_PROFILE, (None, None), full))
        self.assertFalse(BUILDER.hosted_input_profile(BUILDER.SDK8_PROFILE, ('registry', 'git'), (None,) * 6))
        with self.assertRaises(ValueError): BUILDER.hosted_input_profile(BUILDER.SDK8_PROFILE, (None, None), full)
        with self.assertRaises(ValueError): BUILDER.hosted_input_profile(BUILDER.SDK9_PROFILE, ('registry', None), full)
        with self.assertRaises(ValueError): BUILDER.hosted_input_profile(BUILDER.SDK9_PROFILE, (None, None), full[:-1] + (None,))

    def test_vendor_config_pins_source_and_rejects_extra(self):
        origin = self.root / 'vendor'
        config = ('[source.crates-io]\nreplace-with="vendored-sources"\n'
                  '[source."git+https://github.com/bitwarden/passkey-rs?rev=' + MODULE.COMMIT + '"]\n'
                  'git="https://github.com/bitwarden/passkey-rs"\nrev="' + MODULE.COMMIT + '"\n'
                  'replace-with="vendored-sources"\n[source.vendored-sources]\ndirectory="' + str(origin) + '"\n')
        self.assertIn(str(self.root / 'copy'), MODULE.replacement_config(config, origin, self.root / 'copy'))
        with self.assertRaises(ValueError): MODULE.replacement_config(config + '\n[source.extra]\nfoo="bar"\n', origin, self.root / 'copy')

    def test_source_tree_bytes_and_modes_ignore_index_flags(self):
        source = self.root / 'source'
        (source / 'nested').mkdir(parents=True)
        item = source / 'nested/file'
        item.write_bytes(b'good')
        blob = hashlib.sha1(b'blob 4\0good').hexdigest()
        tree = '100644 blob ' + blob + '\tnested/file\0'
        MODULE.verify_worktree(source, tree)
        item.write_bytes(b'evil')
        with self.assertRaises(ValueError): MODULE.verify_worktree(source, tree)
        item.write_bytes(b'good')
        item.chmod(0o755)
        with self.assertRaises(ValueError): MODULE.verify_worktree(source, tree)
        item.chmod(0o644)
        (source / 'extra').mkdir()
        with self.assertRaises(ValueError): MODULE.verify_worktree(source, tree)

    def test_explicit_checkpoint_rejects_source_or_digest_drift(self):
        preparer = self.root / 'preparer.py'
        preparer.write_text('value = 7\n')
        pin = self.root / 'ThirdParty/BitwardenStrictEditSpike/hosted-inputs.pin.json'
        pin.parent.mkdir(parents=True)
        pin.write_text('synthetic pin')
        path = self.root / 'checkpoint.json'
        record = {'schema': 1, 'files': {
            'scripts/build-native-bitwarden-strict-sdk.py': BUILDER.digest(Path(BUILDER.__file__).absolute()),
            'scripts/prepare-native-bitwarden-hosted-inputs.py': BUILDER.digest(preparer),
            'ThirdParty/BitwardenStrictEditSpike/hosted-inputs.pin.json': BUILDER.digest(pin)}}
        path.write_text(json.dumps(record))
        with patch.object(BUILDER, 'ROOT', self.root), patch.object(BUILDER, 'HOSTED_PIN_SHA256', BUILDER.digest(pin)):
            self.assertEqual(BUILDER.load_hosted_preparer(preparer, path, BUILDER.digest(path))[0].value, 7)
            with self.assertRaises(ValueError): BUILDER.load_hosted_preparer(preparer, path, '0' * 64)
            preparer.write_text('value = 8\n')
            with self.assertRaises(ValueError): BUILDER.load_hosted_preparer(preparer, path, BUILDER.digest(path))


if __name__ == '__main__':
    unittest.main()
