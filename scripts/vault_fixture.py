"""Run the pinned Vaultwarden build as an owned, disposable HTTPS fixture."""

import hashlib
import json
import math
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
import urllib.request

if __package__:
    from . import vault_tls
else:
    import vault_tls


REPO = Path(__file__).resolve().parents[1]
PIN_FILE = REPO / 'ThirdParty/VaultwardenFixture/pin.json'
RECEIPT_FILE = REPO / 'build/VaultFixture/build-receipt.json'
LISTENER_COMMAND = ['/usr/sbin/lsof', '-nP', '-a']


class _SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, origin):
        super().__init__()
        self.origin = origin

    def redirect_request(self, request, response, code, message, headers, new_url):
        target = urljoin(request.full_url, new_url)
        parsed = urlsplit(target)
        if (parsed.scheme, parsed.hostname, parsed.port) != self.origin:
            raise URLError('Cross-origin fixture redirect rejected')
        return super().redirect_request(request, response, code, message, headers, target)


def _sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _single_link_regular_file(path):
    try:
        details = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(details.st_mode) and details.st_nlink == 1


def _validate_binary(binary):
    path = Path(binary)
    if not _single_link_regular_file(path) or not os.access(path, os.X_OK):
        raise ValueError('Vault fixture binary must be a regular executable file')
    try:
        pin_bytes = PIN_FILE.read_bytes()
        pin = json.loads(pin_bytes)
        if not _single_link_regular_file(RECEIPT_FILE):
            raise ValueError
        receipt = json.loads(RECEIPT_FILE.read_text())
        if not isinstance(pin, dict) or not isinstance(receipt, dict):
            raise ValueError
        valid = (type(receipt.get('schema')) is int and receipt['schema'] == 1
                 and receipt.get('pinSHA256') == hashlib.sha256(pin_bytes).hexdigest()
                 and receipt.get('sourceCommit') == pin.get('sourceCommit')
                 and receipt.get('binarySHA256') == _sha256(path))
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        valid = False
    if not valid:
        raise ValueError('Vault fixture binary does not match this checkout build receipt')
    return path


def _choose_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def _environment(data_folder, tls, port):
    environment = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL', 'SYSTEMROOT')
                   if key in os.environ}
    environment.update({
        'HOME': str(data_folder),
        'TMPDIR': str(data_folder),
        'ENV_FILE': '/dev/null',
        'DATA_FOLDER': str(data_folder),
        'DOMAIN': f'https://127.0.0.1:{port}',
        'ROCKET_ADDRESS': '127.0.0.1',
        'ROCKET_PORT': str(port),
        'ROCKET_TLS': f'{{certs={json.dumps(str(tls.certificate))},key={json.dumps(str(tls.private_key))}}}',
        'ROCKET_CLI_COLORS': 'false',
        'WEB_VAULT_ENABLED': 'false',
        'SMTP_SECURITY': 'off',
        'USE_SENDMAIL': 'false',
        'PUSH_ENABLED': 'false',
        'ICON_DOWNLOAD_TIMEOUT': '0',
        'HTTP_REQUEST_BLOCK_REGEX': '.*',
        'SIGNUPS_ALLOWED': 'false',
        'INVITATIONS_ALLOWED': 'false',
    })
    return environment


def _verify_listener(pid, port, timeout=3):
    command = LISTENER_COMMAND + ['-p', str(pid), '-iTCP:' + str(port), '-sTCP:LISTEN', '-F', 'n']
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return False
    expected = f'n127.0.0.1:{port}'
    names = [line for line in result.stdout.splitlines() if line.startswith('n')]
    return bool(names) and all(line == expected for line in names)


def _opener(tls, port):
    origin = ('https', '127.0.0.1', port)
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=tls.client_context()),
        _SameOriginRedirectHandler(origin),
    )


class VaultFixture:
    """Context manager for one receipt-verified Vaultwarden child process."""

    def __init__(self, binary, root, startup_timeout=20):
        if (isinstance(startup_timeout, bool) or not isinstance(startup_timeout, (int, float))
                or not math.isfinite(startup_timeout) or startup_timeout <= 0):
            raise ValueError('Startup timeout must be positive')
        self.binary = Path(binary)
        self.root = Path(root)
        self.startup_timeout = float(startup_timeout)
        self.base_url = None
        self.pid = None
        self.tls = None
        self._process = None

    def __enter__(self):
        try:
            self.root = vault_tls.validated_probe_root(self.root)
            self.binary = _validate_binary(self.binary)
            data_folder = self.root / 'vault-data'
            data_folder.mkdir(mode=0o700)
            os.chmod(data_folder, 0o700)
            details = data_folder.lstat()
            if (not stat.S_ISDIR(details.st_mode) or details.st_uid != os.getuid()
                    or stat.S_IMODE(details.st_mode) != 0o700):
                raise ValueError('Vault fixture data folder is not a fresh owned private directory')
            self.tls = vault_tls.create_fixture_tls(self.root)
            port = _choose_port()
            self.base_url = f'https://127.0.0.1:{port}'
            environment = _environment(data_folder, self.tls, port)
            self._process = subprocess.Popen(
                [str(self.binary)], cwd=self.root, env=environment,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                close_fds=True,
            )
            self.pid = self._process.pid
            self._wait_ready(port)
            return self
        except BaseException:
            self._stop()
            raise

    def __exit__(self, exc_type, exc_value, traceback):
        self._stop()
        return False

    def _wait_ready(self, port):
        deadline = time.monotonic() + self.startup_timeout
        opener = _opener(self.tls, port)
        version = json.loads(PIN_FILE.read_text())['version']
        ready = set()
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                raise RuntimeError('Pinned Vaultwarden fixture exited before HTTPS readiness')
            if not _verify_listener(self.pid, port, timeout=max(0.01, min(3, deadline - time.monotonic()))):
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))
                continue
            for endpoint in ('/alive', '/api/config', '/api/version'):
                if endpoint in ready:
                    continue
                try:
                    with opener.open(self.base_url + endpoint,
                                     timeout=min(1.0, max(0.05, deadline - time.monotonic()))) as response:
                        body = response.read(1024 * 1024)
                    if endpoint == '/api/config':
                        if not isinstance(json.loads(body), dict):
                            continue
                    elif endpoint == '/api/version':
                        observed = body.decode('utf-8').strip().strip('"')
                        if observed != version:
                            raise RuntimeError('Vaultwarden fixture version differs from pinned release')
                    ready.add(endpoint)
                except (HTTPError, URLError, OSError, TimeoutError, UnicodeError, json.JSONDecodeError):
                    continue
            if ready == {'/alive', '/api/config', '/api/version'}:
                return
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        if self._process.poll() is not None:
            raise RuntimeError('Pinned Vaultwarden fixture exited before HTTPS readiness')
        raise TimeoutError('Pinned Vaultwarden fixture HTTPS startup timed out')

    def _stop(self):
        process = self._process
        if process is None:
            return
        if process.poll() is None:
            try:
                process.terminate()
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
        else:
            process.wait()
        self._process = None
        self.pid = None

