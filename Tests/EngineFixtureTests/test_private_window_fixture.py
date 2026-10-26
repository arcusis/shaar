import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import uuid


spec = importlib.util.spec_from_file_location(
    'engine_fixture', Path(__file__).resolve().parents[2] / 'scripts/engine_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class PrivateWindowFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run_id = str(uuid.uuid4()).upper()

    def report(self, phase):
        return dict(phase=phase, passed=True, probeMode=fixture.PRIVATE_WINDOW_MODE,
                    privateWindowOnly=True, privateWindowProbe=True,
                    savedTabCapacityOnly=False, externalAppConsentOnly=False,
                    bitwardenStoreProbe=False, fixtureTLSProbe=False,
                    localFixturesPassed=True)

    def evidence(self, phase):
        return dict(schema=1, mode=fixture.PRIVATE_WINDOW_MODE, phase=phase,
                    runID=self.run_id, passed=True,
                    checkCount=len(fixture.PRIVATE_WINDOW_CHECKS),
                    requiredCheckCount=len(fixture.PRIVATE_WINDOW_CHECKS),
                    checks={name: True for name in fixture.PRIVATE_WINDOW_CHECKS},
                    historyEntryCount=1,
                    historyQuerySucceeded=True,
                    historyPathDigest='a' * 64,
                    cleanup=dict(windowsRemaining=0, contextsRemaining=0, passed=True),
                    scope=fixture.PRIVATE_WINDOW_SCOPE)

    def write_phase(self, phase, evidence=None):
        (self.root / f'{phase}.json').write_text(json.dumps(self.report(phase)))
        (self.root / f'{phase}-private-window.json').write_text(
            json.dumps(evidence or self.evidence(phase)))

    def test_flag_exclusive_and_child_arguments_preserve_phase(self):
        self.assertTrue(fixture.argument_parser().parse_args(['--private-window']).private_window)
        for other in ('--bitwarden', '--abrupt-restart', '--saved-tab-capacity',
                      '--external-app-consent'):
            with self.subTest(other=other), self.assertRaises(SystemExit):
                fixture.argument_parser().parse_args(['--private-window', other])
        for phase in ('initial', 'restart'):
            args = fixture.build_engine_probe_arguments(
                '/tmp/ArcusisBrowser', self.root, 'http://127.0.0.1:43123/account', phase,
                include_bitwarden=False, onboarding_control=False, abrupt=False,
                saved_tab_capacity=False, private_window=True,
                private_window_run_id=self.run_id)
            self.assertIn('--probe-private-window', args)
            self.assertEqual(args[args.index('--probe-private-window-run-id') + 1], self.run_id)
            self.assertEqual(args[args.index('--probe-phase') + 1], phase)
            self.assertNotIn('--probe-external-app-consent', args)

    def test_valid_report_binds_phase_checks_digest_and_cleanup(self):
        for phase in ('initial', 'restart'):
            self.write_phase(phase)
            fixture.validate_private_window_report(self.root, phase, self.report(phase), 0)
        children = [dict(phase=phase, pid=100 + index, childExited=True,
                         processGroupAbsent=True)
                    for index, phase in enumerate(('initial', 'restart'))]
        result = fixture.record_private_window_summary(
            self.root, listener_closed=True, child_receipts=children,
            proof_directory=self.root / 'proof')
        self.assertTrue(result['passed'])
        self.assertEqual(result['mode'], fixture.PRIVATE_WINDOW_MODE)
        self.assertEqual([item['phase'] for item in result['phases']], ['initial', 'restart'])
        self.assertTrue(result['listenerClosed'])
        self.assertEqual(len(result['childProcesses']), 2)
        self.assertEqual(result['phases'][0]['requiredCheckCount'], len(fixture.PRIVATE_WINDOW_CHECKS))
        self.assertTrue((self.root / 'proof' / 'private-window-summary.json').exists())

    def test_summary_preserves_failing_observed_count_and_runs_both_phases(self):
        initial = self.evidence('initial')
        initial['checks'].pop('staleContextRejected')
        initial['checkCount'] = len(initial['checks'])
        initial['passed'] = False
        initial['requiredCheckCount'] = len(fixture.PRIVATE_WINDOW_CHECKS)
        restart = self.evidence('restart')
        self.write_phase('initial', initial)
        self.write_phase('restart', restart)
        children = [dict(phase=phase, pid=200 + index, childExited=True,
                         processGroupAbsent=True)
                    for index, phase in enumerate(('initial', 'restart'))]
        result = fixture.record_private_window_summary(
            self.root, listener_closed=True, child_receipts=children,
            proof_directory=self.root / 'proof')
        self.assertFalse(result['passed'])
        self.assertEqual(result['phases'][0]['checkCount'], len(fixture.PRIVATE_WINDOW_CHECKS) - 1)
        self.assertEqual(result['phases'][0]['requiredCheckCount'], len(fixture.PRIVATE_WINDOW_CHECKS))
        self.assertEqual([phase['phase'] for phase in result['phases']], ['initial', 'restart'])

    def test_listener_cleanup_probe_distinguishes_bound_port(self):
        import socket
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
            self.assertFalse(fixture.verify_fixture_listener_closed(port))
        self.assertTrue(fixture.verify_fixture_listener_closed(port))

    def test_schema_rejects_missing_check_failed_check_digest_and_cleanup(self):
        mutations = (
            lambda value: value['checks'].pop('staleContextRejected'),
            lambda value: value['checks'].__setitem__('closedWindowRejected', False),
            lambda value: value['checks'].pop('multipleTabsShareNativePrivateWindow'),
            lambda value: value['checks'].__setitem__('privateNavigationReloadBackForward', False),
            lambda value: value['checks'].__setitem__('privateCallbacksUseOwnersWithoutRegularContamination', False),
            lambda value: value['checks'].pop('privateTabCloseConfirmedAndStaleRejected'),
            lambda value: value['checks'].__setitem__('privateWindowCloseCallbackOwnerRouted', False),
            lambda value: value['checks'].__setitem__('normalFactoriesRejectPrivateIdentities', False),
            lambda value: value['checks'].pop('releaseWhileOwnedWindowRejected'),
            lambda value: value.__setitem__('runID', self.run_id.lower()),
            lambda value: value.__setitem__('checkCount', 1),
            lambda value: value.__setitem__('historyEntryCount', 0),
            lambda value: value.__setitem__('historyQuerySucceeded', False),
            lambda value: value.__setitem__('historyPathDigest', 'raw-path'),
            lambda value: value['cleanup'].__setitem__('windowsRemaining', 1),
        )
        for mutate in mutations:
            evidence = self.evidence('initial')
            mutate(evidence)
            with self.subTest(mutation=mutate), self.assertRaises(RuntimeError):
                self.write_phase('initial', evidence)
                fixture.validate_private_window_report(
                    self.root, 'initial', self.report('initial'), 0)

    def test_phase_mismatch_unknown_check_and_zero_child_exit_rejected(self):
        evidence = self.evidence('restart')
        evidence['checks']['unreviewed'] = True
        self.write_phase('initial', evidence)
        with self.assertRaises(RuntimeError):
            fixture.validate_private_window_report(self.root, 'initial', self.report('initial'), 0)
        self.write_phase('initial')
        with self.assertRaises(RuntimeError):
            fixture.validate_private_window_report(self.root, 'initial', self.report('initial'), 1)


if __name__ == '__main__':
    unittest.main()
