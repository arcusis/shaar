"""Run Bitwarden extension control against two synthetic local accounts."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import ssl
import stat
import subprocess
import tempfile
import threading
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import (HTTPRedirectHandler, HTTPSHandler, ProxyHandler,
                            Request, build_opener)
import uuid
from http.server import ThreadingHTTPServer

if __package__:
    from . import engine_fixture, vault_crypto, vault_tls
    from .vault_fixture import VaultFixture
else:
    import engine_fixture
    import vault_crypto
    import vault_tls
    from vault_fixture import VaultFixture

REPO = Path(__file__).resolve().parents[1]
VAULT_BINARY = REPO / 'build/VaultFixture/target/ci/vaultwarden'
BROWSER_BINARY = REPO / 'build/Arcusis Browser.app/Contents/MacOS/ArcusisBrowser'
PHASES = ('initial', 'restart')
VAULT_STAGE_LABELS = (
    'store-consent', 'onboarding-control', 'signed-out-alpha', 'signed-out-beta',
    'self-hosted-server-alpha', 'self-hosted-server-beta', 'account-alpha-login',
    'account-beta-login', 'initial-locked-alpha', 'initial-locked-beta',
    'initial-unlock-alpha', 'initial-unlock-beta', 'initial-restart-locked-alpha',
    'initial-restart-locked-beta', 'account-alpha-identity-matches',
    'account-beta-identity-matches', 'account-alpha-cross-profile-mismatch',
    'account-beta-cross-profile-mismatch', 'separate-profile-isolation',
    'shared-alpha-space-retains-profile', 'restart-locked-alpha', 'restart-locked-beta',
    'restart-unlock-alpha', 'restart-unlock-beta', 'first-click-compatibility',
)
VAULT_REQUIRED_STAGES = {
    'initial': frozenset((
        'store-consent', 'onboarding-control', 'signed-out-alpha', 'signed-out-beta',
        'self-hosted-server-alpha', 'self-hosted-server-beta', 'account-alpha-login',
        'account-beta-login', 'initial-locked-alpha', 'initial-locked-beta',
        'initial-unlock-alpha', 'initial-unlock-beta', 'initial-restart-locked-alpha',
        'initial-restart-locked-beta', 'account-alpha-identity-matches',
        'account-beta-identity-matches', 'account-alpha-cross-profile-mismatch',
        'account-beta-cross-profile-mismatch', 'shared-alpha-space-retains-profile',
        'separate-profile-isolation',
    )),
    'restart': frozenset((
        'restart-locked-alpha', 'restart-locked-beta', 'restart-unlock-alpha',
        'restart-unlock-beta', 'account-alpha-login', 'account-beta-login',
        'account-alpha-identity-matches', 'account-beta-identity-matches',
        'account-alpha-cross-profile-mismatch', 'account-beta-cross-profile-mismatch',
        'shared-alpha-space-retains-profile', 'separate-profile-isolation',
    )),
}


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise URLError('Fixture redirect rejected')


def _write_private_json(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())


def _api(opener, base_url, path, payload=None, token=None, form=False,
         expected_status=200, allowed_error=None):
    headers = {'Accept': 'application/json', 'User-Agent': 'Arcusis synthetic fixture',
               'Device-Type': '2'}
    body = None
    if payload is not None:
        headers['Content-Type'] = ('application/x-www-form-urlencoded' if form
                                   else 'application/json')
        body = (urlencode(payload) if form else json.dumps(payload)).encode()
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = Request(base_url + path, data=body, headers=headers)
    try:
        with opener.open(request, timeout=8) as response:
            if response.status != expected_status or response.url != base_url + path:
                raise RuntimeError('Fixture API returned unexpected status or origin')
            raw = response.read(1024 * 1024)
    except HTTPError as error:
        if error.code != expected_status:
            raise RuntimeError(f'Fixture API request failed with status {error.code}') from None
        if allowed_error is None:
            raise RuntimeError('Fixture API rejected synthetic request') from None
        try:
            details = json.loads(error.read(1024 * 1024))
        except (ValueError, UnicodeError):
            raise RuntimeError('Fixture API returned malformed denial') from None
        message = details.get('errorModel', {}).get('message') if isinstance(details, dict) else None
        if message != allowed_error:
            raise RuntimeError('Fixture API returned unexpected denial') from None
        return None
    try:
        return json.loads(raw) if raw else None
    except (ValueError, UnicodeError):
        raise RuntimeError('Fixture API returned malformed JSON') from None


def _validate_fixture_origin(base_url):
    try:
        parsed = urlsplit(base_url)
        port = parsed.port
    except (TypeError, ValueError):
        raise RuntimeError('Fixture origin is malformed') from None
    if (parsed.scheme != 'https' or parsed.hostname != '127.0.0.1'
            or port is None or not 1 <= port <= 65535 or parsed.username is not None
            or parsed.password is not None or parsed.path or parsed.query or parsed.fragment):
        raise RuntimeError('Fixture origin is not an explicit loopback HTTPS origin')
    return base_url


def _register_accounts(fixture_url, opener):
    accounts = []
    for index in range(2):
        account = vault_crypto.SyntheticVaultAccount.generate()
        if not account.email.endswith('.invalid'):
            raise RuntimeError('Generated account is outside reserved .invalid domain')
        verification = _api(opener, fixture_url, '/identity/accounts/register/send-verification-email',
                            {'email': account.email, 'name': 'Disposable fixture'})
        if not isinstance(verification, str) or not verification:
            raise RuntimeError('Fixture registration token missing')
        _api(opener, fixture_url, '/identity/accounts/register/finish',
             account.registration_payload(verification))
        auth = _api(opener, fixture_url, '/identity/connect/token', account.login_payload(), form=True)
        token = auth.get('access_token') if isinstance(auth, dict) else None
        if not isinstance(token, str) or not token:
            raise RuntimeError('Fixture registration login missing access token')
        profile = _api(opener, fixture_url, '/api/accounts/profile', token=token)
        user_id = profile.get('id') if isinstance(profile, dict) else None
        if not isinstance(user_id, str) or not user_id:
            raise RuntimeError('Fixture registration profile missing identity')
        wrapped_key = auth.get('Key', auth.get('key'))
        if not isinstance(wrapped_key, str):
            raise RuntimeError('Fixture registration login missing wrapped key')
        master_key = vault_crypto.derive_master_key(account.password, account.email)
        if vault_crypto.decrypt(vault_crypto.stretch_master_key(master_key), wrapped_key) != account.user_key:
            raise RuntimeError('Fixture registration returned mismatched user key')
        password = uuid.uuid4().hex + uuid.uuid4().hex
        username = 'fixture-' + uuid.uuid4().hex
        encrypt = lambda value: vault_crypto.encrypt(account.user_key, value.encode())
        cipher = {
            'type': 1, 'encryptedFor': user_id, 'name': encrypt(f'Disposable fixture {index}'),
            'notes': None, 'organizationId': None, 'folderId': None, 'key': None,
            'fields': None, 'favorite': False, 'reprompt': 0,
            'login': {'username': encrypt(username), 'password': encrypt(password),
                      'uris': [{'uri': encrypt(fixture_url), 'match': 0}], 'totp': None},
        }
        created = _api(opener, fixture_url, '/api/ciphers', cipher, token=token)
        if not isinstance(created, dict) or not isinstance(created.get('id'), str):
            raise RuntimeError('Fixture account item creation failed')
        accounts.append({'account': account, 'token': token, 'id': user_id,
                         'cipher_id': created['id'], 'verification_token': verification})
    if accounts[0]['id'] == accounts[1]['id']:
        raise RuntimeError('Synthetic accounts are not isolated')
    return accounts


def _read_report(path, phase):
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f'{phase} acceptance report missing')
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError, UnicodeError):
        raise RuntimeError(f'{phase} acceptance report malformed') from None
    if not isinstance(value, dict) or value.get('phase') != phase:
        raise RuntimeError(f'{phase} acceptance report has wrong shape or phase')
    return value


def _phase_evidence(root, phase):
    paths = [root / f'{phase}.json', root / f'{phase}-tls.json',
             root / f'{phase}-bitwarden-vault.json', root / f'{phase}-bitwarden.json']
    paths.extend((root / 'bitwarden-vault').glob('**/*.json'))
    return paths


def _report_evidence(root):
    paths = [root / f'{phase}{suffix}.json'
             for phase in PHASES
             for suffix in ('', '-tls', '-bitwarden-vault', '-bitwarden')]
    for phase in PHASES:
        paths.extend(root.glob(f'{phase}-*.json'))

    def is_private_report(path):
        name = path.name.lower()
        return (name == 'vault-credentials.json' or 'config' in name
                or 'session' in name)

    vault_reports = root / 'bitwarden-vault'
    if vault_reports.is_dir() and not vault_reports.is_symlink():
        paths.extend(path for path in vault_reports.glob('**/*.json')
                     if not is_private_report(path))
    return [path for path in paths if not is_private_report(path)]


def _validate_phase(root, phase, exit_code, secrets):
    _redact_evidence(_phase_evidence(root, phase), secrets)
    host = _read_report(root / f'{phase}.json', phase)
    for field in ('passed', 'localFixturesPassed', 'bitwardenStoreProbe',
                  'bitwardenVaultProbe', 'bitwardenOnboardingControl', 'fixtureTLSProbe'):
        if type(host.get(field)) is not bool or host[field] is not True:
            raise RuntimeError(f'{phase} host acceptance field failed: {field}')
    if type(host.get('checkCount')) is not int or host['checkCount'] < 0:
        raise RuntimeError(f'{phase} host check count malformed')
    if host.get('error') is not None:
        raise RuntimeError(f'{phase} host acceptance report contains failure')

    tls = _read_report(root / f'{phase}-tls.json', phase)
    matched = tls.get('matched')
    unmatched = tls.get('unmatched')
    if (tls.get('passed') is not True or not isinstance(matched, dict)
            or matched.get('success') is not True or type(matched.get('httpStatusCode')) is not int
            or matched['httpStatusCode'] != 200 or not isinstance(unmatched, dict)
            or unmatched.get('success') is not False or type(unmatched.get('netError')) is not int
            or unmatched.get('netError') != -202
            or unmatched.get('netErrorName') != 'net::ERR_CERT_AUTHORITY_INVALID'):
        raise RuntimeError(f'{phase} TLS acceptance fields failed')

    vault = _read_report(root / f'{phase}-bitwarden-vault.json', phase)
    if (vault.get('passed') is not True or vault.get('controlOnly') is not True
            or type(vault.get('firstClickAcceptancePassed')) is not bool
            or vault['firstClickAcceptancePassed'] is not False
            or type(vault.get('accountCount')) is not int or vault['accountCount'] != 2
            or vault.get('lastStage') != 'completed'
            or not isinstance(vault.get('storeObservation'), dict)
            or type(vault.get('storeButtonCount')) is not int):
        raise RuntimeError(f'{phase} vault acceptance fields failed')
    stages = vault.get('stages')
    labels = ([stage.get('label') if isinstance(stage, dict) else None for stage in stages]
              if isinstance(stages, list) else None)
    if labels != list(VAULT_STAGE_LABELS):
        raise RuntimeError(f'{phase} vault stages missing, malformed, or failed')
    stage_results = {stage['label']: stage.get('passed') for stage in stages}
    if (any(type(stage.get('passed')) is not bool for stage in stages)
            or any(stage_results[label] is not True for label in VAULT_REQUIRED_STAGES[phase])
            or stage_results['first-click-compatibility'] is not False):
        raise RuntimeError(f'{phase} vault stages missing, malformed, or failed')
    if exit_code != 0:
        raise RuntimeError(f'{phase} browser process failed with exit {exit_code}')
    return {
        'phase': phase, 'exitCode': exit_code, 'hostPassed': host['passed'],
        'localFixturesPassed': host['localFixturesPassed'], 'hostCheckCount': host['checkCount'],
        'tlsPassed': tls['passed'], 'vaultPassed': vault['passed'],
        'controlOnly': vault['controlOnly'],
        'firstClickAcceptancePassed': vault['firstClickAcceptancePassed'],
        'vaultStageCount': len(stages),
    }


def _redact_evidence(paths, secrets):
    encoded = tuple(secret.encode('utf-8') for secret in secrets if secret)
    for path in paths:
        if not path.is_file() or path.is_symlink():
            continue
        try:
            body = path.read_bytes()
        except OSError:
            raise RuntimeError('Could not verify report redaction') from None
        if any(secret in body for secret in encoded):
            path.unlink(missing_ok=True)
            raise RuntimeError('Redaction boundary failed; offending report removed')


def _stop_owned(process):
    if process is None:
        return
    if process.poll() is None:
        try:
            process.terminate()
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            process.wait(timeout=10)
    else:
        process.wait()


def _run_browser(binary, root, fixture_url, credentials, tls, timeout=940,
                 popen=subprocess.Popen, wait_for_probe=engine_fixture.wait_for_probe,
                 stop_probe=engine_fixture.stop_probe):
    credential_path = root / 'vault-credentials.json'
    process = None
    secrets = [value for row in credentials['accounts']
               for value in (row['account'].email, row['account'].password)]
    try:
        extension = REPO / 'Tests/Fixtures/ProfileExtension'
        shutil.copytree(extension, root / 'Extension')
        (root / 'Downloads').mkdir(mode=0o700)
        _write_private_json(root / 'probe-tls.json', {
            'schema': 1, 'spkiSHA256': tls.spki_sha256,
            'certificateSHA256': hashlib.sha256(tls.certificate.read_bytes()).hexdigest(),
            'matchedURL': credentials['serverURL'] + '/icons/arcusis-fixture.invalid/icon.png',
            'unmatchedURL': credentials['unmatchedURL'],
        })
        if not credential_path.is_file() or credential_path.is_symlink():
            raise RuntimeError('Private credential handoff missing')
        phases = []
        for phase in PHASES:
            output = root / f'{phase}.json'
            args = [str(binary), '--engine-probe', '--probe-data-dir', str(root),
                    '--probe-url', fixture_url, '--probe-phase', phase, '--probe-output', str(output),
                    '--probe-fixture-tls', '--bitwarden', '--bitwarden-onboarding-control',
                    '--bitwarden-vault']
            process = popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True,
                            env=dict(os.environ, ARDIA_DOWNLOADS_DIR=str(root / 'Downloads')))
            try:
                code = wait_for_probe(process, root, phase, timeout=timeout)
            except BaseException:
                _redact_evidence(_phase_evidence(root, phase), secrets)
                raise
            finally:
                owned_process = process
                process = None
                stop_probe(owned_process)
            phases.append(_validate_phase(root, phase, code, secrets))
        return phases
    finally:
        owned_process = process
        process = None
        try:
            if owned_process is not None:
                stop_probe(owned_process)
        finally:
            credential_path.unlink(missing_ok=True)


def _create_root():
    root = Path(tempfile.mkdtemp(prefix='arcusis-engine-probe-'))
    os.chmod(root, 0o700)
    marker = root / '.arcusis-probe'
    descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(b'arcusis-engine-probe-v1\n')
    return root.resolve(strict=True)


def _validate_phase_summaries(phases):
    if not isinstance(phases, list) or len(phases) != len(PHASES):
        raise RuntimeError('Browser phase summaries missing or malformed')
    for phase, summary in zip(PHASES, phases):
        if not isinstance(summary, dict) or summary.get('phase') != phase:
            raise RuntimeError('Browser phase summaries missing or malformed')
        required_true = ('hostPassed', 'localFixturesPassed', 'tlsPassed', 'vaultPassed',
                         'controlOnly')
        if any(type(summary.get(field)) is not bool or summary[field] is not True
               for field in required_true):
            raise RuntimeError('Browser phase summary failed acceptance')
        if (type(summary.get('exitCode')) is not int or summary['exitCode'] != 0
                or type(summary.get('hostCheckCount')) is not int
                or summary['hostCheckCount'] < 0
                or type(summary.get('firstClickAcceptancePassed')) is not bool
                or summary['firstClickAcceptancePassed'] is not False
                or type(summary.get('vaultStageCount')) is not int
                or summary['vaultStageCount'] != len(VAULT_STAGE_LABELS)):
            raise RuntimeError('Browser phase summary malformed')
    safe_fields = ('phase', 'exitCode', 'hostPassed', 'localFixturesPassed',
                   'hostCheckCount', 'tlsPassed', 'vaultPassed', 'controlOnly',
                   'firstClickAcceptancePassed', 'vaultStageCount')
    return [{field: summary[field] for field in safe_fields}
            for summary in phases]


def run_control(binary=VAULT_BINARY, browser_binary=BROWSER_BINARY, timeout=940,
                vault_factory=VaultFixture, browser_runner=_run_browser):
    root = _create_root()
    report = {
        'schema': 1, 'scope': 'Synthetic local Vaultwarden and vendor UI control only.',
        'registeredAccounts': 0, 'distinctAccountIDs': False, 'browserPhases': [],
        'browserVaultControlPassed': False, 'stopped': False, 'error': None,
    }
    credentials_path = root / 'vault-credentials.json'
    try:
        with vault_factory(binary, root, allow_synthetic_registration=True) as vault:
            base_url = _validate_fixture_origin(vault.base_url)
            opener = build_opener(ProxyHandler({}), HTTPSHandler(context=vault.tls.client_context()),
                                  _NoRedirect())
            accounts = _register_accounts(base_url, opener)
            generated_secrets = [secret for row in accounts
                                 for secret in (row['account'].email, row['account'].password,
                                                row.get('token'), row.get('verification_token'))
                                if secret]
            report['registeredAccounts'] = len(accounts)
            report['distinctAccountIDs'] = True
            credentials = {'serverURL': base_url, 'accounts': accounts}
            for row in accounts:
                row.pop('token', None)
                row.pop('verification_token', None)
            _write_private_json(credentials_path, {
                'schema': 1, 'serverURL': base_url,
                'accounts': [{'email': row['account'].email,
                              'masterPassword': row['account'].password} for row in accounts],
            })
            # Browser launch reads private handoff file; outer finally removes it on every path.
            server = ThreadingHTTPServer(('127.0.0.1', 0), engine_fixture.Fixture)
            thread = None
            other_root = None
            other_server = None
            other_thread = None
            try:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                fixture_url = f'http://127.0.0.1:{server.server_port}/account'

                class AliveHandler(engine_fixture.Fixture):
                    def do_GET(self):
                        self.send_response(200)
                        self.send_header('Content-Length', '2')
                        self.end_headers()
                        self.wfile.write(b'{}')

                other_root = _create_root()
                other_tls = vault_tls.create_fixture_tls(other_root)
                other_server = ThreadingHTTPServer(('127.0.0.1', 0), AliveHandler)
                other_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                other_context.load_cert_chain(other_tls.certificate, other_tls.private_key)
                other_server.socket = other_context.wrap_socket(other_server.socket, server_side=True)
                other_thread = threading.Thread(target=other_server.serve_forever, daemon=True)
                other_thread.start()
                credentials['unmatchedURL'] = (
                    f'https://127.0.0.1:{other_server.server_port}/alive')
                phase_output = browser_runner(browser_binary, root,
                    fixture_url, credentials, vault.tls, timeout=timeout)
                safe_phases = _validate_phase_summaries(phase_output)
                report['browserPhases'] = safe_phases
                _redact_evidence(_report_evidence(root), generated_secrets)
            finally:
                if thread is not None and thread.is_alive():
                    server.shutdown()
                server.server_close()
                if other_server is not None:
                    if other_thread is not None and other_thread.is_alive():
                        other_server.shutdown()
                    other_server.server_close()
                if other_root is not None:
                    shutil.rmtree(other_root)
            report['browserVaultControlPassed'] = True
        report['stopped'] = True
    except Exception as error:
        generated_secrets = locals().get('generated_secrets', [])
        _redact_evidence(_report_evidence(root), generated_secrets)
        report['error'] = type(error).__name__
        fixture = locals().get('vault')
        report['stopped'] = (fixture is not None and getattr(fixture, '_process', None) is None
                             and getattr(fixture, 'pid', None) is None)
        raise RuntimeError(
            f'Vault browser control failed; redacted evidence retained at {root}') from None
    finally:
        credentials_path.unlink(missing_ok=True)
        if credentials_path.exists():
            report['plaintextCredentialsRemoved'] = False
        else:
            report['plaintextCredentialsRemoved'] = True
        report_path = root / 'vault-browser-control.json'
        _write_private_json(report_path, report)
        os.chmod(report_path, stat.S_IRUSR | stat.S_IWUSR)
    return root, report


if __name__ == '__main__':
    evidence_root, result = run_control()
    print(json.dumps({'evidenceRoot': str(evidence_root),
                      'browserVaultControlPassed': result['browserVaultControlPassed'],
                      'stopped': result['stopped'],
                      'plaintextCredentialsRemoved': result['plaintextCredentialsRemoved']}))
