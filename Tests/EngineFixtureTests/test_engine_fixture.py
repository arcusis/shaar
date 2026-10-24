import importlib.util
import fcntl
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('engine_fixture', Path(__file__).resolve().parents[2] / 'scripts/engine_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class HostLockCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / '.arcusis-probe').write_text('arcusis-engine-probe-v1\n')
        (self.root / 'host-workspace').mkdir()
        self.path = self.root / 'host-workspace/workspace.lock'
        self.path.write_text('preserve')
        self.ready = dict(schema=1, phase='initial', pid=os.getpid(),
                          token='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
                          lockFile='host-workspace/workspace.lock')

    def test_foreign_pid_phase_path_or_token_is_rejected(self):
        for change in [dict(pid=True), dict(pid=os.getpid() + 1), dict(phase='restart'),
                       dict(lockFile='../foreign'), dict(token='invalid'), dict(schema=True)]:
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                fixture.validate_host_lock_checkpoint(self.root, self.ready | change, os.getpid(), 'initial')

    def test_symlink_cannot_authorize_a_foreign_lock(self):
        self.path.unlink()
        self.path.symlink_to(self.root / '.arcusis-probe')
        with self.assertRaises(RuntimeError):
            fixture.validate_host_lock_checkpoint(self.root, self.ready, os.getpid(), 'initial')

    def test_unlocked_file_never_produces_a_passing_receipt(self):
        (self.root / 'initial-host-lock-ready.json').write_text(json.dumps(self.ready))
        with self.assertRaises(RuntimeError):
            fixture.verify_host_lock_if_ready(self.root, os.getpid(), 'initial')
        self.assertFalse((self.root / 'initial-host-lock-receipt.json').exists())
        self.assertEqual(self.path.read_text(), 'preserve')

    def test_locked_descriptor_produces_bound_receipt_without_changing_file(self):
        (self.root / 'initial-host-lock-ready.json').write_text(json.dumps(self.ready))
        with self.path.open('r+') as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fixture.verify_host_lock_if_ready(self.root, os.getpid(), 'initial')
        receipt = json.loads((self.root / 'initial-host-lock-receipt.json').read_text())
        self.assertTrue(receipt['blocked'])
        self.assertEqual(receipt['token'], self.ready['token'])
        self.assertEqual(receipt['parentPID'], os.getpid())
        self.assertEqual(self.path.read_text(), 'preserve')


class AbruptCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / '.arcusis-probe').write_text('arcusis-engine-probe-v1\n')
        for name in ['session.json', 'pre-abrupt-session.json']:
            (self.root / name).write_text('{"version":3}\n')
        self.ready = dict(schema=1, ready=True, localFixturesPassed=True, phase='initial',
                          pid=12345, expectedSnapshot='pre-abrupt-session.json',
                          checks=['authored fixture passed'], chromiumVersion='test')

    def test_foreign_or_malformed_checkpoint_never_authorizes_signal(self):
        for change in [dict(pid=54321), dict(pid=True), dict(ready=False), dict(schema=True),
                       dict(localFixturesPassed=False), dict(checks=[]), dict(phase='restart'),
                       dict(expectedSnapshot='../foreign.json')]:
            ready = self.ready | change
            (self.root / 'ready-for-abrupt-termination.json').write_text(json.dumps(ready))
            process = Mock(pid=12345)
            process.poll.return_value = None
            with self.subTest(change=change), patch.object(fixture.os, 'killpg') as kill:
                with self.assertRaises(RuntimeError):
                    fixture.terminate_at_checkpoint(process, self.root, timeout=1)
                kill.assert_not_called()

    def test_changed_snapshot_and_symlink_are_rejected(self):
        (self.root / 'session.json').write_text('{"version":2}')
        with self.assertRaises(RuntimeError):
            fixture.validate_abrupt_checkpoint(self.root, self.ready, 12345)
        (self.root / 'session.json').unlink()
        (self.root / 'session.json').symlink_to(self.root / 'pre-abrupt-session.json')
        with self.assertRaises(RuntimeError):
            fixture.validate_abrupt_checkpoint(self.root, self.ready, 12345)

    def test_signal_requires_owned_group_and_receipt_requires_sigkill_exit(self):
        (self.root / 'ready-for-abrupt-termination.json').write_text(json.dumps(self.ready))
        process = Mock(pid=12345)
        process.poll.return_value = None
        with patch.object(fixture.os, 'getpgid', return_value=54321), patch.object(fixture.os, 'killpg') as kill:
            with self.assertRaises(RuntimeError):
                fixture.terminate_at_checkpoint(process, self.root, timeout=1)
            kill.assert_not_called()
        process.wait.return_value = 0
        with patch.object(fixture.os, 'getpgid', return_value=12345), \
                patch.object(fixture, 'process_group_exists', return_value=True), \
                patch.object(fixture.os, 'killpg') as kill:
            with self.assertRaises(RuntimeError):
                fixture.terminate_at_checkpoint(process, self.root, timeout=1)
            kill.assert_called_once_with(12345, signal.SIGKILL)
        self.assertFalse((self.root / 'abrupt-termination.json').exists())

    def test_success_requires_group_exit_and_preserves_identical_session_bytes(self):
        (self.root / 'ready-for-abrupt-termination.json').write_text(json.dumps(self.ready))
        process = Mock(pid=12345)
        process.poll.return_value = None
        process.wait.return_value = -signal.SIGKILL
        with patch.object(fixture.os, 'getpgid', return_value=12345), \
                patch.object(fixture, 'process_group_exists', side_effect=[True, True, False]), \
                patch.object(fixture.os, 'killpg') as kill:
            fixture.terminate_at_checkpoint(process, self.root, timeout=1)
            self.assertEqual(kill.call_args_list[0].args, (12345, signal.SIGKILL))
        receipt = json.loads((self.root / 'abrupt-termination.json').read_text())
        self.assertEqual(receipt['exitCode'], -signal.SIGKILL)
        self.assertEqual(receipt['sessionSHA256Before'], receipt['sessionSHA256After'])
        self.assertFalse(receipt['controlOnly'])
        self.assertEqual(receipt['idleBeforeKillSeconds'], 0)
        self.assertFalse((self.root / 'restart.json').exists())

    def test_settled_control_cannot_be_reported_as_strict_acceptance(self):
        (self.root / 'ready-for-abrupt-termination.json').write_text(json.dumps(self.ready))
        process = Mock(pid=12345)
        process.poll.return_value = None
        process.wait.return_value = -signal.SIGKILL
        with patch.object(fixture.os, 'getpgid', return_value=12345), \
                patch.object(fixture, 'process_group_exists', side_effect=[True, False]), \
                patch.object(fixture.os, 'killpg'), patch.object(fixture.time, 'sleep') as sleep:
            fixture.terminate_at_checkpoint(process, self.root, timeout=1, settle_seconds=35)
            sleep.assert_called_once_with(35)
        receipt = json.loads((self.root / 'abrupt-termination.json').read_text())
        self.assertTrue(receipt['controlOnly'])
        self.assertEqual(receipt['idleBeforeKillSeconds'], 35)
        self.assertIn('does not establish strict', receipt['scope'])

    def test_process_inventory_observes_current_group_without_signaling(self):
        with patch.object(fixture.os, 'killpg') as kill:
            self.assertTrue(fixture.process_group_exists(os.getpgrp()))
            kill.assert_not_called()

    def test_cleanup_cannot_signal_a_foreign_process_group(self):
        process = Mock(pid=12345)
        process.poll.return_value = None
        with patch.object(fixture.os, 'getpgid', return_value=54321), patch.object(fixture.os, 'killpg') as kill:
            fixture.stop_probe(process)
            kill.assert_not_called()
        process.send_signal.assert_called_once_with(signal.SIGTERM)

    def test_acceptance_summary_keeps_strict_failure_and_control_success_distinct(self):
        for control, restarted, expected in [(False, False, False), (True, True, False), (False, True, True)]:
            receipt = dict(passed=True, exitCode=-signal.SIGKILL, processGroupAbsentAfterKill=True,
                           controlOnly=control, sessionSHA256Before='a' * 64, sessionSHA256After='a' * 64)
            restart = dict(passed=restarted, error=None if restarted else 'Cookie missing',
                           phase='restart', abruptRecoveryProbe=True, bitwardenStoreProbe=False,
                           localFixturesPassed=restarted)
            (self.root / 'abrupt-termination.json').write_text(json.dumps(receipt))
            raw = json.dumps(restart).encode()
            (self.root / 'restart.json').write_bytes(raw)
            summary = fixture.record_abrupt_summary(self.root, control)
            self.assertEqual(summary['strictAcceptancePassed'], expected)
            self.assertEqual((self.root / 'restart.json').read_bytes(), raw)
        with self.assertRaises(RuntimeError):
            fixture.record_abrupt_summary(self.root, control_only=True)
        restart['abruptRecoveryProbe'] = False
        (self.root / 'restart.json').write_text(json.dumps(restart))
        with self.assertRaises(RuntimeError):
            fixture.record_abrupt_summary(self.root, control_only=False)


if __name__ == '__main__':
    unittest.main()
