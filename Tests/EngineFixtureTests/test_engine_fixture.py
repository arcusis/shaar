import importlib.util
import contextlib
import io
import fcntl
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('engine_fixture', Path(__file__).resolve().parents[2] / 'scripts/engine_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class SavedTabCapacityRunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.run_id = 'C766672E-AB82-4F84-8ED3-2C6D75AEB1D1'

    def main_report(self, phase):
        return dict(phase=phase, passed=True, probeMode=fixture.SAVED_TAB_CAPACITY_MODE,
                    savedTabCapacityOnly=True, savedTabCapacityProbe=True,
                    externalAppConsentOnly=False, externalAppConsentProbe=False,
                    savedTabCapacityRunID=self.run_id, scope=fixture.SAVED_TAB_CAPACITY_SCOPE,
                    localFixturesPassed=False, bitwardenStoreProbe=False,
                    bitwardenVaultProbe=False, bitwardenOnboardingControl=False,
                    fixtureTLSProbe=False,
                    abruptRecoveryProbe=False, error=None)

    def capacity_report(self, phase):
        profiles = [str(uuid.UUID(int=index)).upper() for index in range(1, 5)]
        spaces = [str(uuid.UUID(int=index)).upper() for index in range(11, 23)]
        selected_tabs = [str(uuid.UUID(int=index)).upper() for index in range(101, 113)]
        native_ids = list(range(501, 509))
        visit_timings = [dict(spaceID=spaces[index], profileID=profiles[index % 4],
                              nativeTabID=native_ids[index], nativeLiveTabs=index + 1,
                              elapsedMilliseconds=float(index + 1)) for index in range(8)]
        cleanup = dict(mode=fixture.SAVED_TAB_CAPACITY_MODE, phase=phase,
                       runID=self.run_id, scope=fixture.SAVED_TAB_CAPACITY_SCOPE,
                       engineClosed=True, primaryWindowClosed=True,
                       routerClientCount=0, passed=True)
        return dict(schema=1, mode=fixture.SAVED_TAB_CAPACITY_MODE, phase=phase,
                    runID=self.run_id, scope=fixture.SAVED_TAB_CAPACITY_SCOPE,
                    passed=True, profileCount=4, spaceCount=12, savedTabs=1440,
                    visitedSpaces=8, visitedProfiles=4, initialNativeLiveTabs=1,
                    peakNativeLiveTabs=8, liveTabsAfterVisits=8,
                    unvisitedTabsMaterialized=0, checks=['native selected tab loaded'],
                    workspaceSnapshot='saved-tab-capacity-workspace.json',
                    identityCheckpoint='saved-tab-capacity-identities.json',
                    selectedSpaceID=spaces[0], profileIDs=profiles, savedSpaceIDs=spaces,
                    selectedTabIDs=selected_tabs, initialNativeTabID=native_ids[0],
                    visitedNativeTabIDs=native_ids, initialDocumentWaitMilliseconds=7.5,
                    visitDurationMilliseconds=sum(item['elapsedMilliseconds'] for item in visit_timings),
                    visitTimings=visit_timings,
                    cleanup=cleanup)

    def write_phase(self, phase):
        (self.root / f'{phase}.json').write_text(json.dumps(self.main_report(phase)))
        (self.root / f'{phase}-saved-tab-capacity.json').write_text(
            json.dumps(self.capacity_report(phase)))

    def test_capacity_flag_is_mutually_exclusive_with_other_runner_modes(self):
        options = fixture.argument_parser().parse_args(['--saved-tab-capacity'])
        self.assertTrue(options.saved_tab_capacity)
        for other in ('--bitwarden', '--bitwarden-onboarding-control',
                      '--abrupt-restart', '--abrupt-control'):
            with self.subTest(other=other), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                fixture.argument_parser().parse_args(['--saved-tab-capacity', other])

    def test_public_capacity_mode_forwards_to_both_child_phases(self):
        for phase in ('initial', 'restart'):
            arguments = fixture.build_engine_probe_arguments(
                '/tmp/ArcusisBrowser', self.root, 'http://127.0.0.1:43123/account', phase,
                include_bitwarden=False, onboarding_control=False, abrupt=False,
                saved_tab_capacity=True)
            self.assertIn('--probe-saved-tab-capacity', arguments)
            self.assertEqual(arguments[arguments.index('--probe-phase') + 1], phase)
            self.assertNotIn('--bitwarden', arguments)
            self.assertNotIn('--probe-await-abrupt-termination', arguments)

    def test_capacity_reports_bind_phase_mode_scope_cleanup_and_shared_run(self):
        for phase in ('initial', 'restart'):
            self.write_phase(phase)
            fixture.validate_saved_tab_capacity_report(
                self.root, phase, self.main_report(phase), 0)
        summary = fixture.record_saved_tab_capacity_summary(self.root)
        self.assertTrue(summary['passed'])
        self.assertEqual(summary['mode'], fixture.SAVED_TAB_CAPACITY_MODE)
        self.assertEqual(summary['runID'], self.run_id)
        self.assertEqual([phase['phase'] for phase in summary['phases']], ['initial', 'restart'])

    def test_capacity_validation_rejects_wrong_phase_scope_or_cleanup_receipt(self):
        cases = (
            ('main phase', lambda main, cap: main.update(phase='restart')),
            ('main mode', lambda main, cap: main.update(probeMode='full-fixture')),
            ('capacity scope', lambda main, cap: cap.update(scope='full fixture')),
            ('cleanup phase', lambda main, cap: cap['cleanup'].update(phase='restart')),
            ('cleanup window', lambda main, cap: cap['cleanup'].update(primaryWindowClosed=False)),
            ('unvisited live count', lambda main, cap: cap.update(unvisitedTabsMaterialized=1)),
            ('visit timing ownership', lambda main, cap: cap['visitTimings'][0].update(nativeTabID=0)),
            ('local fixtures', lambda main, cap: main.update(localFixturesPassed=True)),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                main = self.main_report('initial')
                capacity = self.capacity_report('initial')
                mutate(main, capacity)
                (self.root / 'initial-saved-tab-capacity.json').write_text(json.dumps(capacity))
                with self.assertRaises(RuntimeError):
                    fixture.validate_saved_tab_capacity_report(self.root, 'initial', main, 0)

    def test_default_full_runner_rejects_capacity_even_with_local_fixture_pass(self):
        report = self.main_report('initial')
        report['localFixturesPassed'] = True
        with self.assertRaises(RuntimeError):
            fixture.validate_full_fixture_report(report, 'initial')

    def test_capacity_summary_rejects_initial_restart_run_id_mismatch(self):
        self.write_phase('initial')
        self.write_phase('restart')
        restart = self.capacity_report('restart')
        restart['runID'] = 'F29A09F3-FAF9-4938-A25B-260F67F42CC3'
        restart['cleanup']['runID'] = restart['runID']
        (self.root / 'restart-saved-tab-capacity.json').write_text(json.dumps(restart))
        main = self.main_report('restart')
        main['savedTabCapacityRunID'] = restart['runID']
        (self.root / 'restart.json').write_text(json.dumps(main))
        with self.assertRaises(RuntimeError):
            fixture.record_saved_tab_capacity_summary(self.root)
        self.assertFalse((self.root / 'saved-tab-capacity-summary.json').exists())


class BitwardenSummaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def reports(self, control=False, passed=True):
        for phase in ('initial', 'restart'):
            host = dict(phase=phase, passed=passed, bitwardenStoreProbe=True,
                        probeMode='full-fixture', savedTabCapacityOnly=False,
                        savedTabCapacityProbe=False,
                      externalAppConsentOnly=False, externalAppConsentProbe=False,
                        bitwardenOnboardingControl=control, localFixturesPassed=True,
                        checks=['authored fixture observed'])
            vendor = dict(phase=phase, passed=passed, controlOnly=control,
                          firstClickAcceptancePassed=passed and not control,
                          checks=['signed-out vendor result observed'])
            (self.root / f'{phase}.json').write_text(json.dumps(host))
            (self.root / f'{phase}-bitwarden.json').write_text(json.dumps(vendor))

    def test_passing_control_can_never_claim_clean_acceptance(self):
        self.reports(control=True)
        summary = fixture.record_bitwarden_summary(self.root, control_only=True)
        self.assertTrue(summary['controlOnly'])
        self.assertFalse(summary['firstClickAcceptancePassed'])
        self.assertTrue(all(p['passed'] for p in summary['phases']))

    def test_clean_success_requires_both_phases_and_local_fixtures(self):
        self.reports()
        self.assertTrue(fixture.record_bitwarden_summary(self.root, False)['firstClickAcceptancePassed'])
        path = self.root / 'restart.json'
        report = json.loads(path.read_text())
        report['localFixturesPassed'] = False
        path.write_text(json.dumps(report))
        self.assertFalse(fixture.record_bitwarden_summary(self.root, False)['firstClickAcceptancePassed'])

    def test_failed_clean_run_stays_failed(self):
        self.reports(passed=False)
        self.assertFalse(fixture.record_bitwarden_summary(self.root, False)['firstClickAcceptancePassed'])

    def test_wrong_or_missing_mode_phase_or_vendor_claim_is_rejected(self):
        for change in (dict(controlOnly=True), dict(controlOnly=0), dict(phase='restart'),
                       dict(firstClickAcceptancePassed=False), dict(passed=1), dict(checks=[]),
                       dict(error='failure')):
            self.reports()
            path = self.root / 'initial-bitwarden.json'
            path.write_text(json.dumps(json.loads(path.read_text()) | change))
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                fixture.record_bitwarden_summary(self.root, False)
        self.reports(control=True)
        with self.assertRaises(RuntimeError):
            fixture.record_bitwarden_summary(self.root, False)

        for change in (dict(probeMode=fixture.SAVED_TAB_CAPACITY_MODE),
                       dict(savedTabCapacityOnly=True)):
            self.reports()
            path = self.root / 'initial.json'
            path.write_text(json.dumps(json.loads(path.read_text()) | change))
            with self.subTest(host_change=change), self.assertRaises(RuntimeError):
                fixture.record_bitwarden_summary(self.root, False)

    def test_missing_report_cannot_produce_acceptance(self):
        self.reports()
        (self.root / 'restart-bitwarden.json').unlink()
        with self.assertRaises(FileNotFoundError):
            fixture.record_bitwarden_summary(self.root, False)
        self.assertFalse((self.root / 'bitwarden-onboarding-summary.json').exists())

    def test_failed_recomputation_removes_prior_passing_summary(self):
        cases = ('missing', 'malformed', 'array', 'mismatched')
        for case in cases:
            with self.subTest(case=case):
                self.reports()
                summary_path = self.root / 'bitwarden-onboarding-summary.json'
                fixture.record_bitwarden_summary(self.root, False)
                self.assertTrue(json.loads(summary_path.read_text())['firstClickAcceptancePassed'])

                report_path = self.root / 'restart-bitwarden.json'
                if case == 'missing':
                    report_path.unlink()
                    expected_error = FileNotFoundError
                elif case == 'malformed':
                    report_path.write_text('{')
                    expected_error = RuntimeError
                elif case == 'array':
                    report_path.write_text('[]')
                    expected_error = RuntimeError
                else:
                    report = json.loads(report_path.read_text())
                    report['phase'] = 'initial'
                    report_path.write_text(json.dumps(report))
                    expected_error = RuntimeError

                with self.assertRaises(expected_error):
                    fixture.record_bitwarden_summary(self.root, False)
                self.assertFalse(summary_path.exists())

    def test_vault_probe_requires_control_and_rejects_mixed_clean_claim(self):
        self.reports()
        host_path = self.root / 'initial.json'
        host = json.loads(host_path.read_text())
        host['bitwardenVaultProbe'] = True
        host_path.write_text(json.dumps(host))
        with self.assertRaises(RuntimeError):
            fixture.record_bitwarden_summary(self.root, False)
        self.assertFalse((self.root / 'bitwarden-onboarding-summary.json').exists())

        self.reports(control=True)
        host_path = self.root / 'initial.json'
        host = json.loads(host_path.read_text())
        host['bitwardenVaultProbe'] = 'true'
        host_path.write_text(json.dumps(host))
        with self.assertRaises(RuntimeError):
            fixture.record_bitwarden_summary(self.root, True)

    def test_passed_control_vendor_report_must_explicitly_deny_acceptance(self):
        self.reports(control=True)
        path = self.root / 'initial-bitwarden.json'
        report = json.loads(path.read_text())
        report['firstClickAcceptancePassed'] = True
        path.write_text(json.dumps(report))
        with self.assertRaises(RuntimeError):
            fixture.record_bitwarden_summary(self.root, True)
        self.assertFalse((self.root / 'bitwarden-onboarding-summary.json').exists())


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
                           probeMode='full-fixture', savedTabCapacityOnly=False,
                           savedTabCapacityProbe=False,
            externalAppConsentOnly=False, externalAppConsentProbe=False,
                           phase='restart', abruptRecoveryProbe=True, bitwardenStoreProbe=False,
                           localFixturesPassed=restarted)
            initial = restart | dict(phase='initial', passed=True, localFixturesPassed=True)
            (self.root / 'initial.json').write_text(json.dumps(initial))
            (self.root / 'abrupt-termination.json').write_text(json.dumps(receipt))
            raw = json.dumps(restart).encode()
            (self.root / 'restart.json').write_bytes(raw)
            summary = fixture.record_abrupt_summary(self.root, control)
            self.assertEqual(summary['strictAcceptancePassed'], expected)
            self.assertEqual((self.root / 'restart.json').read_bytes(), raw)
        with self.assertRaises(RuntimeError):
            fixture.record_abrupt_summary(self.root, control_only=True)
        restart['probeMode'] = fixture.SAVED_TAB_CAPACITY_MODE
        (self.root / 'restart.json').write_text(json.dumps(restart))
        with self.assertRaises(RuntimeError):
            fixture.record_abrupt_summary(self.root, control_only=False)
        restart['probeMode'] = 'full-fixture'
        restart['abruptRecoveryProbe'] = False
        (self.root / 'restart.json').write_text(json.dumps(restart))
        with self.assertRaises(RuntimeError):
            fixture.record_abrupt_summary(self.root, control_only=False)


class ExternalAppConsentRunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.run_id = 'C766672E-AB82-4F84-8ED3-2C6D75AEB1D1'

    def main_report(self, phase):
        return dict(phase=phase, passed=True, probeMode=fixture.EXTERNAL_APP_CONSENT_MODE,
                    externalAppConsentOnly=True, externalAppConsentProbe=True,
                    externalAppConsentRunID=self.run_id, savedTabCapacityOnly=False,
                    savedTabCapacityProbe=False, bitwardenStoreProbe=False,
                    bitwardenVaultProbe=False, bitwardenOnboardingControl=False,
                    abruptRecoveryProbe=False, localFixturesPassed=False, error=None,
                    checks=['native external-app consent evidence'], chromiumVersion='test')

    def evidence(self, phase):
        return dict(schema=1, mode=fixture.EXTERNAL_APP_CONSENT_MODE,
                    scope=fixture.EXTERNAL_APP_CONSENT_SCOPE, phase=phase, runID=self.run_id,
                    passed=True, checks=list(fixture.EXTERNAL_APP_CONSENT_CHECKS),
                    checkCount=len(fixture.EXTERNAL_APP_CONSENT_CHECKS),
                    **{key: True for key in fixture.EXTERNAL_APP_CONSENT_BOOLEAN_FIELDS},
                    approvedRequests=2, launchCount=2, deniedRequests=6,
                    cleanup=dict(mode=fixture.EXTERNAL_APP_CONSENT_MODE,
                                 scope=fixture.EXTERNAL_APP_CONSENT_SCOPE, phase=phase,
                                 runID=self.run_id, engineClosed=True, primaryWindowClosed=True,
                                 routerClientCount=0, pendingRequests=0, passed=True))

    def write_phase(self, phase, report=None, evidence=None):
        (self.root / f'{phase}.json').write_text(json.dumps(report or self.main_report(phase)))
        if evidence is not None:
            (self.root / f'{phase}-external-app-consent.json').write_text(json.dumps(evidence))
        else:
            (self.root / f'{phase}-external-app-consent.json').write_text(
                json.dumps(self.evidence(phase)))

    def test_mode_is_exclusive_and_arguments_include_only_fixed_no_launch_flags(self):
        self.assertTrue(fixture.argument_parser().parse_args(['--external-app-consent']).external_app_consent)
        for other in ('--bitwarden', '--bitwarden-onboarding-control', '--abrupt-restart',
                      '--abrupt-control', '--saved-tab-capacity'):
            with self.subTest(other=other), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                fixture.argument_parser().parse_args(['--external-app-consent', other])
        for phase in ('initial', 'restart'):
            args = fixture.build_engine_probe_arguments(
                '/tmp/ArcusisBrowser', self.root, 'http://127.0.0.1:43123/account', phase,
                include_bitwarden=False, onboarding_control=False, abrupt=False,
                saved_tab_capacity=False, external_app_consent=True)
            self.assertIn('--probe-external-app-consent', args)
            self.assertIn('--ardia-test-external-protocol-no-launch', args)
            self.assertEqual(sum(arg.startswith('--probe-external') for arg in args), 1)
            self.assertFalse(any(arg.startswith('--probe-external-app-consent=') for arg in args))

    def test_valid_reports_bind_each_phase_and_write_shared_run_summary(self):
        for phase in ('initial', 'restart'):
            self.write_phase(phase)
            fixture.validate_external_app_consent_report(self.root, phase,
                                                         self.main_report(phase), 0)
        summary = fixture.record_external_app_consent_summary(self.root)
        self.assertTrue(summary['passed'])
        self.assertEqual(summary['mode'], fixture.EXTERNAL_APP_CONSENT_MODE)
        self.assertEqual(summary['runID'], self.run_id)
        self.assertEqual([item['phase'] for item in summary['phases']], ['initial', 'restart'])

    def test_public_main_forwards_mode_both_phases_and_sets_marker_permissions(self):
        for phase in ('initial', 'restart'):
            self.write_phase(phase)
        server = Mock(server_port=43123)
        process = Mock()
        with contextlib.redirect_stdout(io.StringIO()), \
                patch.object(fixture.tempfile, 'mkdtemp', return_value=str(self.root)), \
                patch.object(fixture.shutil, 'copytree'), \
                patch.object(fixture.http.server, 'ThreadingHTTPServer', return_value=server), \
                patch.object(fixture.threading.Thread, 'start'), \
                patch.object(fixture.subprocess, 'Popen', return_value=process) as popen, \
                patch.object(fixture, 'wait_for_probe', return_value=0) as wait, \
                patch.object(fixture, 'stop_probe'):
            fixture.main(['--external-app-consent'])
        self.assertEqual(popen.call_count, 2)
        for call in popen.call_args_list:
            args = call.args[0]
            self.assertIn('--probe-external-app-consent', args)
            self.assertIn('--ardia-test-external-protocol-no-launch', args)
        self.assertEqual([call.kwargs['timeout'] for call in wait.call_args_list], [180, 180])
        self.assertEqual((self.root / '.arcusis-probe').stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.root / 'external-app-consent-summary.json').exists())

    def test_validation_rejects_wrong_phase_identity_and_malformed_counters_or_booleans(self):
        cases = (
            ('main phase', lambda main, item: main.update(phase='restart')),
            ('main mode', lambda main, item: main.update(probeMode='full-fixture')),
            ('evidence phase', lambda main, item: item.update(phase='restart')),
            ('run identity binding', lambda main, item: main.update(externalAppConsentRunID='F29A09F3-FAF9-4938-A25B-260F67F42CC3')),
            ('strict bool', lambda main, item: item.update(handlerAvailable=1)),
            ('approved numeric', lambda main, item: item.update(approvedRequests=True)),
            ('launch count', lambda main, item: item.update(launchCount=3)),
            ('denied count', lambda main, item: item.update(deniedRequests=5)),
            ('cleanup pending', lambda main, item: item['cleanup'].update(pendingRequests=False)),
            ('forbidden field', lambda main, item: item.update(title='private')),
            ('check list', lambda main, item: item.update(checkCount=1)),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                main, evidence = self.main_report('initial'), self.evidence('initial')
                mutate(main, evidence)
                self.write_phase('initial', main, evidence)
                with self.assertRaises(RuntimeError):
                    fixture.validate_external_app_consent_report(self.root, 'initial', main, 0)

    def test_missing_phase_and_cross_phase_identity_remove_stale_summary(self):
        self.write_phase('initial')
        self.write_phase('restart')
        fixture.record_external_app_consent_summary(self.root)
        summary_path = self.root / 'external-app-consent-summary.json'
        restart = self.evidence('restart')
        restart['runID'] = 'F29A09F3-FAF9-4938-A25B-260F67F42CC3'
        restart['cleanup']['runID'] = restart['runID']
        report = self.main_report('restart')
        report['externalAppConsentRunID'] = restart['runID']
        self.write_phase('restart', report, restart)
        with self.assertRaises(RuntimeError):
            fixture.record_external_app_consent_summary(self.root)
        self.assertFalse(summary_path.exists())
        (self.root / 'restart-external-app-consent.json').unlink()
        with self.assertRaises(FileNotFoundError):
            fixture.record_external_app_consent_summary(self.root)
        self.assertFalse(summary_path.exists())

    def test_external_mode_cannot_pass_full_capacity_or_vendor_gates(self):
        main = self.main_report('initial')
        with self.assertRaises(RuntimeError):
            fixture.validate_full_fixture_report(main, 'initial')
        self.write_phase('initial')
        (self.root / 'initial-saved-tab-capacity.json').write_text('{}')
        with self.assertRaises(RuntimeError):
            fixture.validate_saved_tab_capacity_report(self.root, 'initial', main, 0)
        host = main | dict(bitwardenStoreProbe=True, bitwardenOnboardingControl=False)
        (self.root / 'initial.json').write_text(json.dumps(host))
        (self.root / 'restart.json').write_text(json.dumps(self.main_report('restart')))
        for phase in ('initial', 'restart'):
            (self.root / f'{phase}-bitwarden.json').write_text(json.dumps(dict(
                phase=phase, passed=True, controlOnly=False, firstClickAcceptancePassed=True,
                checks=['vendor evidence'])))
        with self.assertRaises(RuntimeError):
            fixture.record_bitwarden_summary(self.root, False)
        self.assertFalse((self.root / 'bitwarden-onboarding-summary.json').exists())


if __name__ == '__main__':
    unittest.main()
