"""Pure safety tests; these do not claim native SDK proof."""
import importlib.util
import errno
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/test-native-bitwarden-organization.py'
spec = importlib.util.spec_from_file_location('organization_proof', SCRIPT)
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)

class OrganizationProofTests(unittest.TestCase):
    def test_opt_in_required_without_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'out'
            result = subprocess.run([sys.executable, str(SCRIPT), '--source', directory, '--output', str(out), '--cargo-cache', directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(out.exists())
            self.assertNotIn(directory, result.stderr)

    def test_candidate_digest_mismatch_before_children(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(proof, 'FILES', {'patch': '0' * 64}):
                (root / 'patch').write_text('wrong')
                with mock.patch.object(proof, 'run') as child:
                    with self.assertRaises(proof.ProofError): proof.validate_inputs(root)
                    child.assert_not_called()

    def test_source_output_overlap_and_symlink_denied(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / 'source'; source.mkdir()
            with self.assertRaises(proof.ProofError): proof.validate_paths(source, source / 'out')
            link = root / 'link'; link.symlink_to(source)
            with self.assertRaises(proof.ProofError): proof.validate_paths(link, root / 'out')
            proof.validate_paths(source, root / 'out')

    def test_failure_redacts_child_output(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(proof.ProofError) as error:
                proof.run([sys.executable, '-c', 'import sys; print("PRIVATE_FIXTURE", file=sys.stderr); sys.exit(1)'], cwd=Path(directory), env=os.environ.copy(), timeout=5)
            self.assertNotIn('PRIVATE_FIXTURE', str(error.exception))

    def test_oserror_reports_redacted_stage_and_errno(self):
        private = 'PRIVATE_FIXTURE_PATH'
        cases = (
            ('launch', OSError(errno.EMFILE, private), None, None, errno.EMFILE),
            ('communicate', None, [OSError(errno.EIO, private)], None, errno.EIO),
            ('cleanup signal', None, [(b'', b'')], [OSError(errno.EPERM, private)], errno.EPERM),
            ('timeout cleanup signal', None, [subprocess.TimeoutExpired('private', 1)],
             [OSError(errno.EPERM, private), None], errno.EPERM),
            ('timeout cleanup communicate', None,
             [subprocess.TimeoutExpired('private', 1), OSError(errno.EIO, private)],
             [None, None], errno.EIO),
        )
        for stage, launch_error, communicate, signals, code in cases:
            with self.subTest(stage=stage):
                process = mock.Mock(pid=123, returncode=0)
                process.communicate.side_effect = communicate
                with mock.patch.object(proof.subprocess, 'Popen', return_value=process,
                                       side_effect=launch_error), \
                     mock.patch.object(proof.os, 'killpg', side_effect=signals) as kill:
                    with self.assertRaises(proof.ProofError) as caught:
                        proof.run(['private'], cwd=Path('.'), env={}, timeout=1)
                self.assertEqual(str(caught.exception), f'child {stage} failed (errno={code})')
                self.assertNotIn(private, str(caught.exception))
                if launch_error:
                    kill.assert_not_called()
                else:
                    kill.assert_called_with(process.pid, proof.signal.SIGKILL)

    def test_timeout_kills_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'marker'
            child = 'import time, pathlib; time.sleep(2); pathlib.Path(' + repr(str(marker)) + ').touch()'
            parent = 'import subprocess, sys, time; subprocess.Popen([sys.executable, "-c", ' + repr(child) + ']); time.sleep(10)'
            with self.assertRaisesRegex(proof.ProofError, 'timed out'):
                proof.run([sys.executable, '-c', parent], cwd=Path(directory), env=os.environ.copy(), timeout=1)
            import time
            time.sleep(2.2)
            self.assertFalse(marker.exists())

    def test_listener_closed_on_child_failure(self):
        real_server = proof.Server
        addresses = []
        def make_server(*args):
            server = real_server(*args); addresses.append(server.server_address); return server
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(proof, 'Server', side_effect=make_server), mock.patch.object(proof, 'run', side_effect=proof.ProofError('failed')):
            with self.assertRaises(proof.ProofError):
                proof.exercise(Path('/unused'), b'', {}, {'userID': 'id', 'email': 'email'}, 'org', 'key', Path(directory), {})
        with socket.socket() as sock:
            sock.settimeout(.5)
            self.assertNotEqual(sock.connect_ex(addresses[0]), 0)

    def test_result_schema_requires_exact_passed_checks(self):
        raw = ''.join(f'{name}=passed\n' for name in sorted(proof.CHECKS)).encode()
        result = proof.parse_checks(raw)
        self.assertEqual(set(result), proof.CHECKS)
        self.assertTrue(all(value is True for value in result.values()))
        for invalid in (raw + b'snapshot=passed\n', b'', raw.replace(b'snapshot=passed', b'snapshot=failed')):
            with self.assertRaises(proof.ProofError): proof.parse_checks(invalid)

    def test_report_schema_rejects_invalid_provenance_and_unknown_fields(self):
        hashes = {key: 'a' * 64 for key in ('driver_source_sha256', 'swift_probe_source_sha256',
                    'rust_helper_source_sha256', 'shared_fixture_source_sha256')}
        report = {'schema': 1, 'status': 'passed', 'scope': 'native_sdk_console_synthetic_loopback',
                  'integration_ready': False, 'vendor_or_product_acceptance': False,
                  'source_commit': proof.COMMIT, 'source_tree': proof.TREE,
                  'patch_sha256': proof.FILES, 'candidate_diff_sha256': proof.DIFF,
                  'cargo_lock_sha256': proof.LOCK, 'target': 'arm64-apple-macosx26.0',
                  'host_macos': '27.0.1', 'host_architecture': 'arm64', 'offline': True,
                  'max_cargo_jobs': 2, 'revocation': proof.REVOCATION,
                  'checks': {key: True for key in proof.CHECKS | {'listener_cleanup'}},
                  'artifacts': {key: 'a' * 64 for key in proof.ARTIFACTS}}
        proof.validate_report(report, hashes)
        for key, wrong in [('schema', True), ('source_commit', 'wrong'), ('source_tree', 'wrong'),
                           ('patch_sha256', {}), ('candidate_diff_sha256', 'wrong'),
                           ('cargo_lock_sha256', 'wrong'), ('target', 'wrong'), ('offline', 1),
                           ('max_cargo_jobs', True), ('scope', 'wrong'), ('revocation', 'wrong'),
                           ('integration_ready', 0), ('host_macos', 'unknown')]:
            with self.subTest(key=key):
                bad = dict(report, **{key: wrong})
                with self.assertRaises(proof.ProofError): proof.validate_report(bad, hashes)
        for key in report:
            bad = dict(report); del bad[key]
            with self.subTest(missing=key), self.assertRaises(proof.ProofError):
                proof.validate_report(bad, hashes)
        with self.assertRaises(proof.ProofError): proof.validate_report(dict(report, extra=True), hashes)
        bad = dict(report, artifacts=dict(report['artifacts'], driver_source_sha256='b' * 64))
        with self.assertRaises(proof.ProofError): proof.validate_report(bad, hashes)
        bad = dict(report, checks=dict(report['checks'], snapshot=False))
        with self.assertRaises(proof.ProofError): proof.validate_report(bad, hashes)

    def test_source_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source'; source.write_text('original')
            paths = {'source': source}; hashes = {'source': proof.file_hash(source)}
            proof.verify_source_hashes(paths, hashes)
            source.write_text('changed')
            with self.assertRaises(proof.ProofError): proof.verify_source_hashes(paths, hashes)

    def test_source_tree_mismatch_fails_before_output_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); source = root / 'source'; source.mkdir()
            cache = root / 'cache'; (cache / 'registry').mkdir(parents=True)
            output = root / 'output'
            argv = ['proof', '--run', '--source', str(source), '--output', str(output), '--cargo-cache', str(cache)]
            with mock.patch.object(sys, 'argv', argv), mock.patch.object(proof, 'validate_inputs'), \
                 mock.patch.object(proof.platform, 'system', return_value='Darwin'), \
                 mock.patch.object(proof.platform, 'machine', return_value='arm64'), \
                 mock.patch.object(proof, 'run', return_value=b'wrong-tree'):
                with self.assertRaises(proof.ProofError): proof.main()
            self.assertFalse(output.exists())

    def test_helper_lock_must_be_pinned_subset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk, helper = root / 'sdk', root / 'helper'
            sdk.write_text('[[package]]\nname="x"\nversion="1"\nchecksum="good"\n')
            helper.write_text('[[package]]\nname="x"\nversion="1"\nchecksum="bad"\n')
            with self.assertRaises(proof.ProofError): proof.check_helper_lock(helper, sdk)

if __name__ == '__main__': unittest.main()
