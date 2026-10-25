import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from scripts import vault_browser_control as runner


class Process:
    def __init__(self):
        self.terminated = 0
        self.killed = 0
        self.waited = 0
        self.running = True

    def poll(self):
        return None if self.running else 0

    def terminate(self):
        self.terminated += 1
        self.running = False

    def kill(self):
        self.killed += 1
        self.running = False

    def wait(self, timeout=None):
        self.waited += 1
        return 0


class VaultBrowserControlTests(unittest.TestCase):
    def write_reports(self, root, phase, overrides=None):
        host = {'phase': phase, 'passed': True, 'localFixturesPassed': True,
                'bitwardenStoreProbe': True, 'bitwardenVaultProbe': True,
                'bitwardenOnboardingControl': True, 'fixtureTLSProbe': True,
                'checkCount': 0, 'error': None}
        tls = {'phase': phase, 'passed': True,
               'matched': {'success': True, 'httpStatusCode': 200},
               'unmatched': {'success': False, 'netError': -202,
                             'netErrorName': 'net::ERR_CERT_AUTHORITY_INVALID'}}
        vault = {'phase': phase, 'passed': True, 'controlOnly': True,
                 'firstClickAcceptancePassed': False, 'accountCount': 2,
                 'lastStage': 'completed', 'storeObservation': {}, 'storeButtonCount': 1,
                 'stages': [{'label': label,
                             'passed': label in runner.VAULT_REQUIRED_STAGES[phase]}
                            for label in runner.VAULT_STAGE_LABELS]}
        reports = {'host': host, 'tls': tls, 'vault': vault}
        if overrides:
            for report, changes in overrides.items():
                reports[report].update(changes)
        for report, filename in (('host', f'{phase}.json'), ('tls', f'{phase}-tls.json'),
                                 ('vault', f'{phase}-bitwarden-vault.json')):
            (root / filename).write_text(json.dumps(reports[report]))

    def test_accepts_only_complete_typed_control_receipts_and_false_first_click(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_reports(root, 'initial')
            result = runner._validate_phase(root, 'initial', 0, [])
            self.assertTrue(result['hostPassed'])
            self.assertFalse(result['firstClickAcceptancePassed'])

    def test_rejects_false_missing_and_typed_wrong_receipts(self):
        cases = [
            {'host': {'passed': False}},
            {'host': {'localFixturesPassed': 1}},
            {'host': {'bitwardenVaultProbe': False}},
            {'tls': {'passed': 'true'}},
            {'tls': {'unmatched': {'success': False, 'netError': -200,
                                    'netErrorName': 'net::ERR_CERT_AUTHORITY_INVALID'}}},
            {'vault': {'passed': False}},
            {'vault': {'controlOnly': 1}},
            {'vault': {'firstClickAcceptancePassed': 0}},
            {'vault': {'firstClickAcceptancePassed': True}},
            {'vault': {'stages': [{'label': 'store-consent', 'passed': False}]}},
        ]
        for changes in cases:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.write_reports(root, 'initial', changes)
                with self.assertRaises(RuntimeError):
                    runner._validate_phase(root, 'initial', 0, [])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_reports(root, 'initial')
            (root / 'initial-tls.json').unlink()
            with self.assertRaisesRegex(RuntimeError, 'missing'):
                runner._validate_phase(root, 'initial', 0, [])
        for phase in runner.PHASES:
            for label in runner.VAULT_REQUIRED_STAGES[phase]:
                with self.subTest(phase=phase, label=label), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    self.write_reports(root, phase)
                    path = root / f'{phase}-bitwarden-vault.json'
                    receipt = json.loads(path.read_text())
                    next(stage for stage in receipt['stages'] if stage['label'] == label)['passed'] = False
                    path.write_text(json.dumps(receipt))
                    with self.assertRaises(RuntimeError):
                        runner._validate_phase(root, phase, 0, [])
            for bad_value in (None, 1, 'true'):
                with self.subTest(phase=phase, required_type=bad_value), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    self.write_reports(root, phase)
                    path = root / f'{phase}-bitwarden-vault.json'
                    receipt = json.loads(path.read_text())
                    next(stage for stage in receipt['stages']
                         if stage['label'] in runner.VAULT_REQUIRED_STAGES[phase])['passed'] = bad_value
                    path.write_text(json.dumps(receipt))
                    with self.assertRaises(RuntimeError):
                        runner._validate_phase(root, phase, 0, [])
            with self.subTest(phase=phase, nonapplicable='false'), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.write_reports(root, phase)
                path = root / f'{phase}-bitwarden-vault.json'
                receipt = json.loads(path.read_text())
                for stage in receipt['stages']:
                    if stage['label'] not in runner.VAULT_REQUIRED_STAGES[phase] and stage['label'] != 'first-click-compatibility':
                        stage['passed'] = False
                path.write_text(json.dumps(receipt))
                self.assertEqual(runner._validate_phase(root, phase, 0, [])['phase'], phase)

    def test_fixture_origin_must_be_explicit_loopback_https(self):
        self.assertEqual(runner._validate_fixture_origin('https://127.0.0.1:4444'),
                         'https://127.0.0.1:4444')
        for origin in ('https://example.invalid', 'http://127.0.0.1:4444',
                       'https://user@127.0.0.1:4444', 'https://127.0.0.1:4444/path'):
            with self.subTest(origin=origin), self.assertRaises(RuntimeError):
                runner._validate_fixture_origin(origin)

    def test_redacts_and_removes_report_containing_plaintext_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'initial.json'
            path.write_text('{"diagnostic":"fixture@example.invalid"}')
            with self.assertRaisesRegex(RuntimeError, 'Redaction boundary'):
                runner._redact_evidence([path], ['fixture@example.invalid'])
            self.assertFalse(path.exists())

    def test_report_evidence_ignores_profile_tree_and_private_config_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / 'Chromium' / 'Profile-UUID'
            profile.mkdir(parents=True)
            sentinel = profile / 'sentinel.json'
            sentinel.write_text('{"private":"profile sentinel"}')
            vault_reports = root / 'bitwarden-vault'
            vault_reports.mkdir()
            allowed = vault_reports / 'acceptance.json'
            allowed.write_text('{}')
            for name in ('vault-credentials.json', 'vault-config.json',
                         'account-session.json'):
                (vault_reports / name).write_text('{"private":true}')

            paths = runner._report_evidence(root)
            self.assertIn(allowed, paths)
            self.assertNotIn(sentinel, paths)
            self.assertFalse({'vault-credentials.json', 'vault-config.json',
                              'account-session.json'} & {path.name for path in paths})
            original_read_bytes = Path.read_bytes

            def guarded_read_bytes(path):
                if path == sentinel:
                    raise AssertionError('profile sentinel was read')
                return original_read_bytes(path)

            with patch.object(Path, 'rglob', side_effect=AssertionError('broad scan used')), \
                    patch.object(Path, 'read_bytes', guarded_read_bytes):
                runner._redact_evidence(paths, [])
            self.assertEqual(sentinel.read_text(), '{"private":"profile sentinel"}')

    def test_browser_launch_uses_all_explicit_control_flags_and_reaps_owned_child(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / 'root'
            root.mkdir()
            extension = base / 'repo' / 'Tests' / 'Fixtures' / 'ProfileExtension'
            extension.mkdir(parents=True)
            (extension / 'manifest.json').write_text('{}')
            cert = base / 'certificate.pem'
            cert.write_text('fixture certificate')
            credential = root / 'vault-credentials.json'
            credential.write_text('{"private":true}')
            account = SimpleNamespace(email='one@arcusis-fixture.invalid', password='secret-one')
            credentials = {'serverURL': 'https://127.0.0.1:4444',
                           'unmatchedURL': 'https://127.0.0.1:4445/alive',
                           'accounts': [{'account': account}]}
            tls = SimpleNamespace(spki_sha256='fingerprint', certificate=cert)
            processes = []
            launches = []

            def popen(args, **kwargs):
                launches.append((args, kwargs))
                process = Process()
                processes.append(process)
                return process

            def wait(process, report_root, phase, timeout):
                self.write_reports(report_root, phase)
                return 0

            stopped = []
            with patch.object(runner, 'REPO', base / 'repo'):
                phases = runner._run_browser('/browser', root, 'http://127.0.0.1:8000/account',
                    credentials, tls, popen=popen, wait_for_probe=wait,
                    stop_probe=lambda proc: stopped.append(proc))
            expected = {'--bitwarden', '--bitwarden-onboarding-control', '--bitwarden-vault',
                        '--probe-fixture-tls'}
            self.assertEqual(len(phases), 2)
            self.assertTrue(all(expected.issubset(set(args)) for args, _ in launches))
            self.assertEqual([call[0][call[0].index('--probe-phase') + 1]
                              for call in launches], ['initial', 'restart'])
            self.assertEqual(stopped, processes)
            self.assertFalse(credential.exists())
            self.assertEqual((root / 'vault-credentials.json').exists(), False)

    def test_run_control_removes_plaintext_credentials_on_success_and_failure(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'probe'
                account = SimpleNamespace(email='one@arcusis-fixture.invalid', password='secret-one')
                accounts = [{'account': account}, {'account': SimpleNamespace(
                    email='two@arcusis-fixture.invalid', password='secret-two')}]
                tls = SimpleNamespace(client_context=lambda: object())

                class Fixture:
                    def __init__(self, binary, fixture_root, allow_synthetic_registration):
                        self.base_url = 'https://127.0.0.1:4444'
                        self.tls = tls
                        self.stopped = False
                        self.allow_registration = allow_synthetic_registration

                    def __enter__(self):
                        return self

                    def __exit__(self, *_):
                        self.stopped = True

                def browser_runner(binary, fixture_root, url, credentials, material, timeout):
                    handoff = fixture_root / 'vault-credentials.json'
                    self.assertTrue(handoff.exists())
                    self.assertIn('secret-one', handoff.read_text())
                    if fail:
                        raise RuntimeError('controlled failure')
                    return [{'phase': phase, 'exitCode': 0, 'hostPassed': True,
                             'localFixturesPassed': True, 'hostCheckCount': 0,
                             'tlsPassed': True, 'vaultPassed': True, 'controlOnly': True,
                             'firstClickAcceptancePassed': False, 'vaultStageCount': 25}
                            for phase in runner.PHASES]

                root.mkdir()
                original_create_root = runner._create_root
                with patch.object(runner, '_create_root', side_effect=[root, original_create_root()]), \
                     patch.object(runner, '_register_accounts', return_value=accounts):
                    if fail:
                        with self.assertRaisesRegex(RuntimeError, 'evidence retained'):
                            runner.run_control(browser_runner=browser_runner, vault_factory=Fixture)
                    else:
                        result_root, report = runner.run_control(browser_runner=browser_runner, vault_factory=Fixture)
                        self.assertEqual(result_root, root)
                        self.assertTrue(report['browserVaultControlPassed'])
                self.assertFalse((root / 'vault-credentials.json').exists())
                report = json.loads((root / 'vault-browser-control.json').read_text())
                self.assertTrue(report['plaintextCredentialsRemoved'])
                self.assertNotIn('secret-one', json.dumps(report))
                self.assertNotIn('secret-two', json.dumps(report))
                self.assertEqual(report['error'], 'RuntimeError' if fail else None)

    def test_run_control_rejects_forged_two_phase_summaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'probe'
            root.mkdir()
            accounts = [{'account': SimpleNamespace(email='one@arcusis-fixture.invalid', password='p1')},
                        {'account': SimpleNamespace(email='two@arcusis-fixture.invalid', password='p2')}]
            tls = SimpleNamespace(client_context=lambda: object())

            class Fixture:
                def __init__(self, *args, **kwargs):
                    self.base_url = 'https://127.0.0.1:4444'
                    self.tls = tls
                    self._process = None
                    self.pid = None
                def __enter__(self): return self
                def __exit__(self, *_): pass

            with patch.object(runner, '_create_root', side_effect=[root, runner._create_root()]), \
                    patch.object(runner, '_register_accounts', return_value=accounts):
                with self.assertRaisesRegex(RuntimeError, 'evidence retained'):
                    runner.run_control(browser_runner=lambda *args, **kwargs:
                                       [{'phase': 'initial'}, {'phase': 'restart'}],
                                       vault_factory=Fixture)
            self.assertFalse((root / 'vault-credentials.json').exists())
            report = json.loads((root / 'vault-browser-control.json').read_text())
            self.assertEqual(report['browserPhases'], [])

    def test_run_control_whitelists_phase_summaries_and_discards_invalid_output(self):
        generated = ('one@arcusis-fixture.invalid', 'password-generated',
                     'access-token-generated', 'verification-token-generated')
        valid = [{'phase': phase, 'exitCode': 0, 'hostPassed': True,
                  'localFixturesPassed': True, 'hostCheckCount': 1,
                  'tlsPassed': True, 'vaultPassed': True, 'controlOnly': True,
                  'firstClickAcceptancePassed': False, 'vaultStageCount': 25,
                  'account': generated[0], 'password': generated[1],
                  'token': generated[2]} for phase in runner.PHASES]
        cases = ((valid, True), ([{'phase': 'initial', 'password': generated[1]}], False))
        for phase_output, succeeds in cases:
            with self.subTest(succeeds=succeeds), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'probe'
                root.mkdir()
                accounts = [
                    {'account': SimpleNamespace(email=generated[0], password=generated[1]),
                     'token': generated[2], 'verification_token': generated[3]},
                    {'account': SimpleNamespace(email='two@arcusis-fixture.invalid',
                                                password='password-two'),
                     'token': 'access-token-two', 'verification_token': 'verification-token-two'},
                ]
                tls = SimpleNamespace(client_context=lambda: object())

                class Fixture:
                    def __init__(self, *args, **kwargs):
                        self.base_url = 'https://127.0.0.1:4444'
                        self.tls = tls
                        self._process = None
                        self.pid = None
                    def __enter__(self): return self
                    def __exit__(self, *_): pass

                with patch.object(runner, '_create_root',
                                  side_effect=[root, runner._create_root()]), \
                        patch.object(runner, '_register_accounts', return_value=accounts):
                    if succeeds:
                        _, result = runner.run_control(
                            browser_runner=lambda *args, **kwargs: phase_output,
                            vault_factory=Fixture)
                        self.assertEqual(set(result['browserPhases'][0]), {
                            'phase', 'exitCode', 'hostPassed', 'localFixturesPassed',
                            'hostCheckCount', 'tlsPassed', 'vaultPassed', 'controlOnly',
                            'firstClickAcceptancePassed', 'vaultStageCount'})
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'evidence retained'):
                            runner.run_control(
                                browser_runner=lambda *args, **kwargs: phase_output,
                                vault_factory=Fixture)
                report = json.loads((root / 'vault-browser-control.json').read_text())
                if not succeeds:
                    self.assertEqual(report['browserPhases'], [])
                serialized = json.dumps(report)
                for secret in generated:
                    self.assertNotIn(secret, serialized)
                self.assertNotIn('account', report['browserPhases'][0] if succeeds else {})

    def test_owned_process_cleanup_terminates_and_waits(self):
        process = Process()
        runner._stop_owned(process)
        self.assertEqual(process.terminated, 1)
        self.assertEqual(process.waited, 1)
        self.assertEqual(process.killed, 0)

    def test_browser_failure_paths_remove_handoff_and_reap_owned_child(self):
        for failure in ('launch', 'wait', 'phase', 'cleanup'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                root = base / 'root'
                root.mkdir()
                extension = base / 'repo' / 'Tests' / 'Fixtures' / 'ProfileExtension'
                extension.mkdir(parents=True)
                (extension / 'manifest.json').write_text('{}')
                cert = base / 'certificate.pem'
                cert.write_text('fixture certificate')
                handoff = root / 'vault-credentials.json'
                handoff.write_text('{}')
                credentials = {'serverURL': 'https://127.0.0.1:4444',
                               'unmatchedURL': 'https://127.0.0.1:4445/alive',
                               'accounts': [{'account': SimpleNamespace(
                                   email='one@arcusis-fixture.invalid', password='private')} ]}
                tls = SimpleNamespace(spki_sha256='fingerprint', certificate=cert)
                process = Process()
                stop_calls = []

                def popen(*args, **kwargs):
                    if failure == 'launch':
                        raise OSError('launch failed')
                    return process

                def wait(*args, **kwargs):
                    self.write_reports(root, 'initial', {'vault': {'passed': False}}
                                       if failure == 'phase' else None)
                    if failure == 'wait':
                        raise RuntimeError('wait failed')
                    return 0

                def stop(child):
                    stop_calls.append(child)
                    if failure == 'cleanup':
                        runner._stop_owned(child)
                        raise RuntimeError('cleanup failed')

                with patch.object(runner, 'REPO', base / 'repo'):
                    with self.assertRaises((OSError, RuntimeError)):
                        runner._run_browser('/browser', root, 'http://127.0.0.1:8000/account',
                                            credentials, tls, popen=popen, wait_for_probe=wait,
                                            stop_probe=stop)
                self.assertFalse(handoff.exists())
                if failure == 'launch':
                    self.assertEqual(stop_calls, [])
                else:
                    self.assertEqual(stop_calls, [process])


if __name__ == '__main__':
    unittest.main()
