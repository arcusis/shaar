"""Run the real native engine against a disposable, authored local account fixture."""

import http.server
from http.cookies import SimpleCookie
import argparse
import fcntl
import json
import hashlib
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from urllib.parse import urlparse


def record_bitwarden_summary(root, control_only):
    summary_path = root / 'bitwarden-onboarding-summary.json'
    # A prior passing result must never survive a failed recomputation.
    summary_path.unlink(missing_ok=True)
    if type(control_only) is not bool:
        raise RuntimeError('Bitwarden control mode must be explicit')

    def read_report(path):
        try:
            report = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            raise RuntimeError(f'Malformed Bitwarden report: {path.name}') from error
        if not isinstance(report, dict):
            raise RuntimeError(f'Bitwarden report must be a JSON object: {path.name}')
        return report

    observations = []
    for phase in ('initial', 'restart'):
        host = read_report(root / f'{phase}.json')
        vendor = read_report(root / f'{phase}-bitwarden.json')
        if (host.get('phase') != phase or vendor.get('phase') != phase
                or host.get('bitwardenStoreProbe') is not True
                or host.get('bitwardenOnboardingControl') is not control_only
                or vendor.get('controlOnly') is not control_only
                or type(host.get('passed')) is not bool
                or type(host.get('localFixturesPassed')) is not bool
                or type(vendor.get('passed')) is not bool
                or type(vendor.get('firstClickAcceptancePassed')) is not bool):
            raise RuntimeError('Bitwarden summary has missing or mismatched phase/mode evidence')
        vault_probe = host.get('bitwardenVaultProbe')
        if (('bitwardenVaultProbe' in host and type(vault_probe) is not bool)
                or (vault_probe is True and not control_only)):
            raise RuntimeError('Vault probe evidence requires explicit control mode')
        for report in (host, vendor):
            checks = report.get('checks')
            error = report.get('error')
            if (not isinstance(checks, list) or not checks
                    or not all(isinstance(check, str) and check for check in checks)
                    or error is not None and (not isinstance(error, str) or not error)
                    or report['passed'] and error is not None):
                raise RuntimeError('Bitwarden summary has malformed check/error evidence')
        expected = vendor['passed'] and not control_only
        if vendor['firstClickAcceptancePassed'] is not expected:
            raise RuntimeError('Bitwarden control or failed phase claimed clean first-click acceptance')
        observations.append(dict(phase=phase, passed=host['passed'] and vendor['passed'],
                                 localFixturesPassed=host['localFixturesPassed']))
    summary = dict(schema=1, controlOnly=control_only, phases=observations,
                   firstClickAcceptancePassed=(not control_only and all(
                       p['passed'] and p['localFixturesPassed'] for p in observations)),
                   scope='Signed-out onboarding only. No vault or company credentials tested.')
    payload = json.dumps(summary, indent=2)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=root,
                                         prefix='.bitwarden-onboarding-summary-',
                                         suffix='.tmp', delete=False) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(payload)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, summary_path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    return summary


def validate_host_lock_checkpoint(root, ready, pid, phase):
    canonical = root.resolve()
    if (canonical.parent != Path(tempfile.gettempdir()).resolve()
            or not canonical.name.startswith('arcusis-engine-probe-')
            or (canonical / '.arcusis-probe').read_text() != 'arcusis-engine-probe-v1\n'):
        raise RuntimeError('Host lock verification requires a marked disposable root')
    if (not isinstance(ready, dict) or type(ready.get('schema')) is not int or ready['schema'] != 1
            or type(ready.get('pid')) is not int or ready['pid'] != pid or pid <= 1
            or ready.get('phase') != phase or phase not in ('initial', 'restart')
            or ready.get('lockFile') != 'host-workspace/workspace.lock'
            or not isinstance(ready.get('token'), str)):
        raise RuntimeError('Invalid or foreign host lock checkpoint')
    try:
        if str(uuid.UUID(ready['token'])).upper() != ready['token']:
            raise ValueError('noncanonical token')
    except ValueError as error:
        raise RuntimeError('Invalid host lock token') from error
    path = canonical / 'host-workspace/workspace.lock'
    if path.is_symlink() or path.resolve(strict=True).parent != canonical / 'host-workspace':
        raise RuntimeError('Host lock file escaped its disposable directory')
    return path


def verify_host_lock_if_ready(root, pid, phase):
    ready_file = root / f'{phase}-host-lock-ready.json'
    receipt = root / f'{phase}-host-lock-receipt.json'
    if not ready_file.exists() or receipt.exists():
        return
    ready = json.loads(ready_file.read_text())
    path = validate_host_lock_checkpoint(root, ready, pid, phase)
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        status = os.fstat(descriptor)
        if status.st_nlink != 1 or status.st_uid != os.getuid():
            raise RuntimeError('Invalid host lock file ownership')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            raise RuntimeError('Another process acquired the active workspace lock')
    finally:
        os.close(descriptor)
    temporary = receipt.with_suffix('.tmp')
    temporary.write_text(json.dumps(dict(schema=1, blocked=True, pid=pid, parentPID=os.getpid(),
                                       phase=phase, token=ready['token'], lockFile=ready['lockFile'])))
    os.replace(temporary, receipt)


def wait_for_probe(process, root, phase, timeout):
    deadline = time.monotonic() + timeout
    while process.poll() is None:
        verify_host_lock_if_ready(root, process.pid, phase)
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(process.args, timeout)
        time.sleep(0.05)
    return process.wait()


def validate_abrupt_checkpoint(root, ready, pid):
    """Bind the fault checkpoint to this parent's child and its marked temporary files."""
    canonical = root.resolve()
    if (canonical.parent != Path(tempfile.gettempdir()).resolve()
            or not canonical.name.startswith('arcusis-engine-probe-')
            or (canonical / '.arcusis-probe').read_text() != 'arcusis-engine-probe-v1\n'):
        raise RuntimeError('Abrupt termination requires a marked disposable probe root')
    if (not isinstance(ready, dict) or type(ready.get('schema')) is not int or ready['schema'] != 1
            or ready.get('ready') is not True or ready.get('localFixturesPassed') is not True
            or ready.get('phase') != 'initial' or type(ready.get('pid')) is not int
            or ready['pid'] != pid or pid <= 1
            or ready.get('expectedSnapshot') != 'pre-abrupt-session.json'
            or not isinstance(ready.get('checks'), list) or not ready['checks']
            or not all(isinstance(check, str) and check for check in ready['checks'])
            or not isinstance(ready.get('chromiumVersion'), str) or not ready['chromiumVersion']):
        raise RuntimeError('Invalid or foreign abrupt-termination checkpoint')
    files = [canonical / 'session.json', canonical / 'pre-abrupt-session.json']
    if any(path.is_symlink() or path.resolve(strict=True).parent != canonical for path in files):
        raise RuntimeError('Abrupt checkpoint files must belong to the disposable root')
    saved, expected = (path.read_bytes() for path in files)
    if saved != expected:
        raise RuntimeError('Session changed after the abrupt checkpoint')
    # Native startup performs full BrowserSession validation; reject non-object snapshots here too.
    if not isinstance(json.loads(expected), dict):
        raise RuntimeError('Invalid abrupt session snapshot')
    return saved


def process_group_exists(pgid):
    # macOS can reject killpg(..., 0) after SIGKILL. Observe groups without sending a signal.
    result = subprocess.run(['ps', '-axo', 'pgid='], capture_output=True, text=True, check=True, timeout=5)
    groups = {int(value) for value in result.stdout.split()}
    if os.getpgrp() not in groups:
        raise RuntimeError('Process inventory does not include the observer')
    return pgid in groups


def terminate_at_checkpoint(process, root, timeout, settle_seconds=0):
    """SIGKILL only the new process group created for this disposable native probe."""
    checkpoint = root / 'ready-for-abrupt-termination.json'
    deadline = time.monotonic() + timeout
    while process.poll() is None:
        verify_host_lock_if_ready(root, process.pid, 'initial')
        if checkpoint.exists():
            ready = json.loads(checkpoint.read_text())
            before = validate_abrupt_checkpoint(root, ready, process.pid)
            if os.getpgid(process.pid) != process.pid:
                raise RuntimeError('Probe does not own a separate process group')
            if not process_group_exists(process.pid):
                raise RuntimeError('Disposable process group is not observable before termination')
            if settle_seconds:
                print(f'CONTROL ONLY: idle {settle_seconds}s before SIGKILL; strict recovery acceptance is not evaluated', flush=True)
                time.sleep(settle_seconds)
                if process.poll() is not None or os.getpgid(process.pid) != process.pid:
                    raise RuntimeError('Probe ended or ownership changed during settled control')
                if validate_abrupt_checkpoint(root, ready, process.pid) != before:
                    raise RuntimeError('Session changed during settled control')
            print('initial: checkpoint ready; sending SIGKILL to disposable probe group', flush=True)
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait(timeout=10)
            if code != -signal.SIGKILL:
                raise RuntimeError(f'Unexpected abrupt termination exit: {code}')
            group_deadline = time.monotonic() + 10
            while process_group_exists(process.pid):
                if time.monotonic() >= group_deadline:
                    raise RuntimeError('Disposable probe group did not finish terminating')
                time.sleep(0.05)
            after = (root / 'session.json').read_bytes()
            if before != after:
                raise RuntimeError('Saved session changed during abrupt termination')
            receipt = {
                'passed': True, 'pid': process.pid, 'signal': 'SIGKILL', 'exitCode': code,
                'processGroupAbsentAfterKill': True,
                'controlOnly': settle_seconds != 0, 'idleBeforeKillSeconds': settle_seconds,
                'sessionSHA256Before': hashlib.sha256(before).hexdigest(),
                'sessionSHA256After': hashlib.sha256(after).hexdigest(),
                'chromiumVersion': ready['chromiumVersion'], 'checks': ready['checks'],
                'scope': ('Settled diagnostic control. The idle interval may allow pending engine writes to commit; this does not establish strict abrupt-restart acceptance.'
                          if settle_seconds else 'Fault delivery after completed fixture saves. Recovery is evaluated separately by restart.json. No graceful quit or final cookie-drain delay occurred.'),
            }
            (root / 'abrupt-termination.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
            print(f'initial: {len(ready["checks"])} checks before SIGKILL; saved session bytes intact', flush=True)
            return
        if time.monotonic() >= deadline:
            raise RuntimeError('Timed out waiting for abrupt-termination checkpoint')
        time.sleep(0.05)
    raise RuntimeError(f'Probe exited before abrupt-termination checkpoint ({process.returncode})')


def signal_probe(process, requested_signal):
    try:
        if os.getpgid(process.pid) == process.pid:
            os.killpg(process.pid, requested_signal)
        else:
            # If ownership changed, cleanup may signal the known child only.
            process.send_signal(requested_signal)
    except ProcessLookupError:
        pass


def record_abrupt_summary(root, control_only):
    """Derive acceptance without modifying either raw child report or fault receipt."""
    receipt = json.loads((root / 'abrupt-termination.json').read_text())
    restart = json.loads((root / 'restart.json').read_text())
    if (receipt.get('passed') is not True or receipt.get('exitCode') != -signal.SIGKILL
            or receipt.get('processGroupAbsentAfterKill') is not True
            or receipt.get('controlOnly', False) is not control_only
            or not isinstance(receipt.get('sessionSHA256Before'), str)
            or len(receipt['sessionSHA256Before']) != 64
            or receipt['sessionSHA256Before'] != receipt.get('sessionSHA256After')):
        raise RuntimeError('Abrupt fault receipt does not match the requested test mode')
    verified_recovery = (restart.get('phase') == 'restart'
                         and restart.get('abruptRecoveryProbe') is True
                         and restart.get('bitwardenStoreProbe') is False
                         and restart.get('localFixturesPassed') is True)
    if restart.get('passed') is True and not verified_recovery:
        raise RuntimeError('Successful restart report lacks abrupt-recovery context')
    summary = {
        'schema': 1, 'controlOnly': control_only, 'faultInjected': True,
        'restartPassed': restart.get('passed') is True,
        'recoveryModeVerified': verified_recovery,
        'strictAcceptancePassed': not control_only and verified_recovery and restart.get('passed') is True,
        'error': restart.get('error'),
        'sourceReports': ['abrupt-termination.json', 'restart.json'],
        'scope': 'Derived acceptance summary. Raw reports remain unchanged. A settled control never passes strict acceptance.',
    }
    (root / 'abrupt-recovery-summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    return summary


def stop_probe(process):
    if process.poll() is not None:
        return
    signal_probe(process, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        signal_probe(process, signal.SIGKILL)
        process.wait(timeout=10)


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path.startswith('/download/'):
            self.download(path.rsplit('/', 1)[-1])
            return
        body = b"""<!doctype html><html data-arcusis-fixture="v1"><meta charset="utf-8">
<title>Arcusis account isolation fixture</title>
<style>body{font:18px system-ui;padding:60px;color:#293445;background:#f0f4f8}</style>
<h1>Local account isolation fixture</h1><p>Disposable test data only.</p>
<p>OrbitFindMarker OrbitFindMarker OrbitFindMarker</p>
<form><label>Username <input id="username" autocomplete="username"></label>
<label>Password <input id="password" type="password" autocomplete="current-password"></label></form>
<script>window.arcusisInstance=crypto.randomUUID();</script></html>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def download(self, name):
        cookies = SimpleCookie(self.headers.get('Cookie', ''))
        account = cookies['account'].value if 'account' in cookies else 'none'
        account = account if account in ('alpha', 'beta') else 'none'
        slow = name in ('slow.txt', 'cancel.txt')
        body = f'account={account}\narcusis-download-fixture\n'.encode() + b'x' * (4 * 1024 * 1024 if slow else 1024)
        offset = 0
        requested = self.headers.get('Range', '')
        if requested.startswith('bytes='):
            offset = int(requested[6:].split('-', 1)[0])
        if offset >= len(body):
            self.send_error(416)
            return
        self.send_response(206 if offset else 200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Disposition', f'attachment; filename="{name}"')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('ETag', f'"{account}-{name}-v1"')
        self.send_header('Content-Length', str(len(body) - offset))
        if offset:
            self.send_header('Content-Range', f'bytes {offset}-{len(body)-1}/{len(body)}')
        self.end_headers()
        try:
            for start in range(offset, len(body), 16384):
                self.wfile.write(body[start:start+16384])
                if slow:
                    time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--bitwarden", action="store_true", help="Install Bitwarden from the real Chrome Web Store in a disposable profile")
    mode.add_argument("--bitwarden-onboarding-control", action="store_true",
                      help="Diagnostic only: wait two seconds on intro before Log in; cannot establish clean first-click acceptance")
    mode.add_argument("--abrupt-restart", action="store_true", help="SIGKILL the disposable probe after its fixture checkpoint, then verify recovery")
    mode.add_argument("--abrupt-control", action="store_true", help="Diagnostic only: idle 35s before SIGKILL; does not establish strict crash-recovery acceptance")
    options = parser.parse_args()
    include_bitwarden = options.bitwarden or options.bitwarden_onboarding_control
    if options.bitwarden_onboarding_control:
        print('CONTROL ONLY: two-second intro-screen age; clean first-click acceptance is not evaluated', flush=True)
    abrupt = options.abrupt_restart or options.abrupt_control
    root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
    (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
    shutil.copytree("Tests/Fixtures/ProfileExtension", root / "Extension")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    executable = Path("build/Arcusis Browser.app/Contents/MacOS/ArcusisBrowser").resolve()
    (root / 'Downloads').mkdir(mode=0o700)
    probe_env = dict(os.environ, ARDIA_DOWNLOADS_DIR=str(root / 'Downloads'))
    print(f"Probe evidence: {root}", flush=True)
    failures = []
    try:
        for phase in ("initial", "restart"):
            output = root / f"{phase}.json"
            arguments = [str(executable), "--engine-probe", "--probe-data-dir", str(root),
                         "--probe-url", f"http://127.0.0.1:{server.server_port}/account",
                         "--probe-phase", phase, "--probe-output", str(output)]
            if include_bitwarden:
                arguments.append("--bitwarden")
            if options.bitwarden_onboarding_control:
                arguments.append('--bitwarden-onboarding-control')
            if abrupt:
                arguments.append('--probe-await-abrupt-termination' if phase == 'initial' else '--probe-expect-abrupt-recovery')
            with (root / f"{phase}.log").open("w") as log:
                process = subprocess.Popen(arguments, stdout=log, stderr=log, start_new_session=True, env=probe_env)
                try:
                    if abrupt and phase == 'initial':
                        terminate_at_checkpoint(process, root, timeout=90, settle_seconds=35 if options.abrupt_control else 0)
                        continue
                    code = wait_for_probe(process, root, phase, timeout=170 if include_bitwarden else 90)
                except subprocess.TimeoutExpired:
                    raise RuntimeError(f"{phase} timed out; see {root}/{phase}.log")
                finally:
                    stop_probe(process)
            if not output.exists():
                raise RuntimeError(f"{phase} failed ({code}); see {root}/{phase}.log")
            report = json.loads(output.read_text())
            if include_bitwarden and phase == 'restart':
                record_bitwarden_summary(root, control_only=options.bitwarden_onboarding_control)
            if abrupt and phase == 'restart':
                record_abrupt_summary(root, control_only=options.abrupt_control)
            if code != 0 or not report["passed"]:
                failure = f"{phase}: {report.get('error') or f'process exit {code}'}"
                failures.append(failure)
                print(f"FAILED {failure}", flush=True)
                if include_bitwarden and report.get("localFixturesPassed") and (root / f"{phase}-bitwarden.json").exists():
                    # Preserve cold-install failure while also collecting restart evidence.
                    continue
                raise RuntimeError(failure)
            print(f"{phase}: {len(report['checks'])} checks passed; Chromium {report['chromiumVersion']}", flush=True)
        if failures:
            raise RuntimeError("; ".join(failures))
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
