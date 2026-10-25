"""Ownership, pinned-build, startup, readiness, and cleanup checks."""

import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, Mock, patch
from urllib.error import URLError


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('vault_fixture', ROOT / 'scripts/vault_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class VaultFixtureTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='arcusis-engine-probe-')).resolve()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.root.chmod(0o700)
        marker = self.root / '.arcusis-probe'
        marker.write_bytes(b'arcusis-engine-probe-v1\n')
        marker.chmod(0o600)
        self.files = tempfile.TemporaryDirectory(prefix='vault-fixture-test-')
        self.addCleanup(self.files.cleanup)
        self.files_path = Path(self.files.name)
        self.binary = self.files_path / 'vaultwarden'
        self.binary.write_bytes(b'pinned fake executable')
        self.binary.chmod(0o700)
        self.pin = self.files_path / 'pin.json'
        self.pin_bytes = json.dumps(dict(version='1.37.4', sourceCommit='abc123')).encode()
        self.pin.write_bytes(self.pin_bytes)
        self.receipt = self.files_path / 'build-receipt.json'
        self._write_receipt()
        self.pin_patch = patch.object(fixture, 'PIN_FILE', self.pin)
        self.receipt_patch = patch.object(fixture, 'RECEIPT_FILE', self.receipt)
        self.pin_patch.start()
        self.receipt_patch.start()
        self.addCleanup(self.receipt_patch.stop)
        self.addCleanup(self.pin_patch.stop)

    def _write_receipt(self, **changes):
        receipt = dict(schema=1, pinSHA256=hashlib.sha256(self.pin_bytes).hexdigest(),
                       sourceCommit='abc123', binarySHA256=hashlib.sha256(self.binary.read_bytes()).hexdigest())
        receipt.update(changes)
        self.receipt.write_text(json.dumps(receipt))

    def _tls(self):
        value = Mock()
        value.certificate = self.files_path / 'certificate.pem'
        value.private_key = self.files_path / 'private-key.pem'
        value.client_context.return_value = object()
        return value

    def _ready_opener(self):
        opener = Mock()

        def open_url(url, timeout):
            response = MagicMock()
            response.__enter__ = Mock(return_value=response)
            response.__exit__ = Mock(return_value=False)
            if url.endswith('/api/config'):
                response.read.return_value = b'{"version":"compat-version"}'
            elif url.endswith('/api/version'):
                response.read.return_value = b'1.37.4'
            else:
                response.read.return_value = b''
            return response

        opener.open.side_effect = open_url
        return opener

    def _mock_startup(self, process=None, opener=None):
        process = process or Mock(pid=9123)
        process.poll.return_value = None
        opener = opener or self._ready_opener()
        return process, opener

    def test_rejects_invalid_root_and_marker(self):
        with self.assertRaises(ValueError):
            with fixture.VaultFixture(self.binary, self.root / 'missing'):
                pass
        marker = self.root / '.arcusis-probe'
        marker.write_bytes(b'wrong marker\n')
        with self.assertRaises(ValueError):
            with fixture.VaultFixture(self.binary, self.root):
                pass
        marker.write_bytes(b'arcusis-engine-probe-v1\n')
        marker.chmod(0o600)
        alias = self.root.with_name(self.root.name + '-alias')
        alias.symlink_to(self.root, target_is_directory=True)
        self.addCleanup(alias.unlink)
        with self.assertRaises(ValueError):
            with fixture.VaultFixture(self.binary, alias):
                pass

    def test_rejects_bad_receipt_binary_and_reused_data(self):
        self._write_receipt(binarySHA256='0' * 64)
        with self.assertRaises(ValueError):
            fixture.VaultFixture(self.binary, self.root).__enter__()
        self._write_receipt()
        symlink = self.files_path / 'binary-link'
        symlink.symlink_to(self.binary)
        with self.assertRaises(ValueError):
            fixture.VaultFixture(symlink, self.root).__enter__()
        data = self.root / 'vault-data'
        data.mkdir(mode=0o700)
        with self.assertRaises(FileExistsError):
            fixture.VaultFixture(self.binary, self.root).__enter__()

    def test_rejects_missing_wrong_pin_and_malformed_receipts(self):
        cases = (
            ('missing receipt', lambda: self.receipt.unlink()),
            ('wrong pin', lambda: self._write_receipt(pinSHA256='0' * 64)),
            ('malformed receipt', lambda: self.receipt.write_text('{')),
            ('missing pin', lambda: self.pin.unlink()),
        )
        for label, corrupt in cases:
            with self.subTest(label=label):
                self._write_receipt()
                corrupt()
                with self.assertRaises(ValueError):
                    fixture.VaultFixture(self.binary, self.root).__enter__()

    def test_rejects_nonexecutable_and_hardlinked_binaries(self):
        self.binary.chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'regular executable'):
            fixture.VaultFixture(self.binary, self.root).__enter__()
        self.binary.chmod(0o700)
        alias = self.files_path / 'vaultwarden-hardlink'
        os.link(self.binary, alias)
        with self.assertRaisesRegex(ValueError, 'regular executable'):
            fixture.VaultFixture(self.binary, self.root).__enter__()

    def test_rejects_nonfinite_startup_timeout(self):
        for value in (float('nan'), float('inf'), float('-inf')):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'Startup timeout'):
                fixture.VaultFixture(self.binary, self.root, startup_timeout=value)

    def test_default_and_opt_in_environments_are_exact_and_disable_other_services(self):
        tls = self._tls()
        with patch.dict(os.environ, {'AWS_SECRET_ACCESS_KEY': 'never-forward', 'ROCKET_CLI_COLORS': 'off'}, clear=True):
            default_environment = fixture._environment(self.root / 'vault-data', tls, 41234)
            opt_in_environment = fixture._environment(
                self.root / 'vault-data', tls, 41234, allow_synthetic_registration=True)
        expected = {
            'HOME': str(self.root / 'vault-data'),
            'TMPDIR': str(self.root / 'vault-data'),
            'ENV_FILE': '/dev/null',
            'DATA_FOLDER': str(self.root / 'vault-data'),
            'DOMAIN': 'https://127.0.0.1:41234',
            'ROCKET_ADDRESS': '127.0.0.1',
            'ROCKET_PORT': '41234',
            'ROCKET_TLS': f'{{certs={json.dumps(str(tls.certificate))},key={json.dumps(str(tls.private_key))}}}',
            'ROCKET_CLI_COLORS': 'false',
            'WEB_VAULT_ENABLED': 'false',
            'SMTP_SECURITY': 'off',
            'USE_SENDMAIL': 'false',
            'PUSH_ENABLED': 'false',
            'ICON_DOWNLOAD_TIMEOUT': '0',
            'DISABLE_ICON_DOWNLOAD': 'true',
            'HTTP_REQUEST_BLOCK_REGEX': '.*',
            'SIGNUPS_ALLOWED': 'false',
            'SIGNUPS_VERIFY': 'false',
            'INVITATIONS_ALLOWED': 'false',
        }
        self.assertEqual(default_environment, expected)
        self.assertEqual(opt_in_environment, dict(expected, SIGNUPS_ALLOWED='true'))
        self.assertNotIn('AWS_SECRET_ACCESS_KEY', default_environment)
        self.assertNotIn('ADMIN_TOKEN', default_environment)
        self.assertNotIn('SMTP_HOST', default_environment)
        self.assertNotIn('SMTP_PASSWORD', default_environment)

    def test_synthetic_registration_requires_strict_bool(self):
        for value in (None, 0, 1, 'true', object()):
            with self.subTest(value=value), self.assertRaisesRegex(TypeError, 'must be a bool'):
                fixture.VaultFixture(self.binary, self.root, allow_synthetic_registration=value)
            with self.subTest(environment_value=value), self.assertRaisesRegex(TypeError, 'must be a bool'):
                fixture._environment(self.root / 'vault-data', self._tls(), 41234, value)
        with self.assertRaises(TypeError):
            fixture.VaultFixture(self.binary, self.root, 20, True)

    def test_synthetic_registration_requires_fresh_marked_root(self):
        (self.root / 'preexisting').write_text('do not use')
        with patch.object(fixture.subprocess, 'Popen') as popen:
            with self.assertRaisesRegex(ValueError, 'fresh marked private temp root'):
                fixture.VaultFixture(
                    self.binary, self.root, allow_synthetic_registration=True).__enter__()
        popen.assert_not_called()

    def test_listener_requires_exact_owned_loopback_port(self):
        good = Mock(stdout='p9123\nn127.0.0.1:41234\n')
        foreign = Mock(stdout='p9123\nn127.0.0.1:41235\n')
        mixed = Mock(stdout='p9123\nn127.0.0.1:41234\nn*:41234\n')
        ipv6 = Mock(stdout='p9123\nn127.0.0.1:41234\nn[::1]:41234\n')
        foreign_address = Mock(stdout='p9123\nn127.0.0.1:41234\nn192.0.2.8:41234\n')
        no_names = Mock(stdout='p9123\n')
        with patch.object(fixture.subprocess, 'run', return_value=good) as run:
            self.assertTrue(fixture._verify_listener(9123, 41234))
            self.assertEqual(run.call_args.args[0], [
                '/usr/sbin/lsof', '-nP', '-a', '-p', '9123', '-iTCP:41234', '-sTCP:LISTEN', '-F', 'n'])
        with patch.object(fixture.subprocess, 'run', return_value=foreign):
            self.assertFalse(fixture._verify_listener(9123, 41234))
        for result in (mixed, ipv6, foreign_address, no_names):
            with self.subTest(stdout=result.stdout), patch.object(fixture.subprocess, 'run', return_value=result):
                self.assertFalse(fixture._verify_listener(9123, 41234))
        with patch.object(fixture.subprocess, 'run', side_effect=__import__('subprocess').CalledProcessError(1, 'lsof')):
            self.assertFalse(fixture._verify_listener(9123, 41234))

    def test_startup_sends_no_http_before_listener_ownership(self):
        process, opener = self._mock_startup()
        server = fixture.VaultFixture(self.binary, self.root, startup_timeout=0.05)
        server._process = process
        server.pid = process.pid
        server.tls = self._tls()
        with patch.object(fixture, '_opener', return_value=opener), \
                patch.object(fixture, '_verify_listener', return_value=False) as verify, \
                patch.object(fixture.time, 'monotonic', side_effect=[0, 0, 0, 0, 0.1]), \
                patch.object(fixture.time, 'sleep'):
            with self.assertRaisesRegex(TimeoutError, 'startup timed out'):
                server._wait_ready(41237)
        verify.assert_called_once()
        opener.open.assert_not_called()

    def test_running_fixture_exposes_https_and_reaps_only_its_child(self):
        process, opener = self._mock_startup()
        tls = self._tls()
        with patch.object(fixture.vault_tls, 'create_fixture_tls', return_value=tls), \
                patch.object(fixture, '_choose_port', return_value=41234), \
                patch.object(fixture, '_verify_listener', return_value=True), \
                patch.object(fixture, '_opener', return_value=opener), \
                patch.object(fixture.subprocess, 'Popen', return_value=process) as popen:
            with fixture.VaultFixture(self.binary, self.root) as server:
                self.assertEqual(server.base_url, 'https://127.0.0.1:41234')
                self.assertEqual(server.pid, 9123)
                self.assertIs(server.tls, tls)
                command, options = popen.call_args.args[0], popen.call_args.kwargs
                self.assertEqual(command, [str(self.binary)])
                self.assertEqual(options['env']['ENV_FILE'], '/dev/null')
                self.assertEqual(options['env']['SIGNUPS_ALLOWED'], 'false')
                self.assertEqual(options['env']['INVITATIONS_ALLOWED'], 'false')
                self.assertEqual(options['env']['SIGNUPS_VERIFY'], 'false')
                self.assertEqual(options['env']['DISABLE_ICON_DOWNLOAD'], 'true')
                self.assertTrue((self.root / 'vault-data').is_dir())
                self.assertEqual(stat.S_IMODE((self.root / 'vault-data').stat().st_mode), 0o700)
            process.terminate.assert_called_once_with()
            process.wait.assert_called_once_with(timeout=5)
            self.assertIsNone(server.pid)

    def test_startup_exit_cleans_child_and_hides_response_details(self):
        process = Mock(pid=9124)
        process.poll.return_value = 17
        with patch.object(fixture.vault_tls, 'create_fixture_tls', return_value=self._tls()), \
                patch.object(fixture, '_choose_port', return_value=41235), \
                patch.object(fixture.subprocess, 'Popen', return_value=process):
            with self.assertRaisesRegex(RuntimeError, 'exited before HTTPS readiness'):
                with fixture.VaultFixture(self.binary, self.root):
                    pass
        process.wait.assert_called_once_with()

    def test_startup_timeout_cleans_child_and_kills_if_terminate_does_not_finish(self):
        process = Mock(pid=9125)
        process.poll.return_value = None
        process.wait.side_effect = [__import__('subprocess').TimeoutExpired('vaultwarden', 5), None]
        with patch.object(fixture.vault_tls, 'create_fixture_tls', return_value=self._tls()), \
                patch.object(fixture, '_choose_port', return_value=41236), \
                patch.object(fixture, '_verify_listener', return_value=False), \
                patch.object(fixture.subprocess, 'Popen', return_value=process) as popen, \
                patch.object(fixture.time, 'sleep'), \
                patch.object(fixture.time, 'monotonic', side_effect=[10, 11, 12]):
            with self.assertRaisesRegex(TimeoutError, 'startup timed out'):
                with fixture.VaultFixture(
                        self.binary, self.root, startup_timeout=1,
                        allow_synthetic_registration=True):
                    pass
        self.assertEqual(popen.call_args.kwargs['env']['SIGNUPS_ALLOWED'], 'true')
        self.assertEqual(popen.call_args.kwargs['env']['INVITATIONS_ALLOWED'], 'false')
        self.assertEqual(popen.call_args.kwargs['env']['SIGNUPS_VERIFY'], 'false')
        self.assertEqual(popen.call_args.kwargs['env']['DISABLE_ICON_DOWNLOAD'], 'true')
        process.terminate.assert_called_once_with()
        process.kill.assert_called_once_with()
        self.assertEqual(process.wait.call_count, 2)

    def test_cleanup_retains_owned_child_until_reap_succeeds(self):
        process = Mock(pid=9126)
        process.poll.return_value = None
        process.wait.side_effect = [OSError('wait failed'), None]
        server = fixture.VaultFixture(self.binary, self.root)
        server._process = process
        server.pid = process.pid
        with self.assertRaisesRegex(OSError, 'wait failed'):
            server._stop()
        self.assertIs(server._process, process)
        self.assertEqual(server.pid, process.pid)
        server._stop()
        self.assertIsNone(server._process)
        self.assertIsNone(server.pid)
        self.assertEqual(process.terminate.call_count, 2)
        self.assertEqual(process.wait.call_count, 2)

    def test_exception_in_context_body_still_reaps_owned_child(self):
        process, opener = self._mock_startup()
        tls = self._tls()
        with patch.object(fixture.vault_tls, 'create_fixture_tls', return_value=tls), \
                patch.object(fixture, '_choose_port', return_value=41238), \
                patch.object(fixture, '_verify_listener', return_value=True), \
                patch.object(fixture, '_opener', return_value=opener), \
                patch.object(fixture.subprocess, 'Popen', return_value=process):
            with self.assertRaisesRegex(RuntimeError, 'body failure'):
                with fixture.VaultFixture(self.binary, self.root):
                    raise RuntimeError('body failure')
        process.terminate.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=5)

    def test_same_origin_redirect_handler_rejects_foreign_origin(self):
        handler = fixture._SameOriginRedirectHandler(('https', '127.0.0.1', 41234))
        request = Mock(full_url='https://127.0.0.1:41234/alive')
        with self.assertRaises(URLError):
            handler.redirect_request(request, None, 302, 'Found', {}, 'https://example.com/steal')


if __name__ == '__main__':
    unittest.main()
