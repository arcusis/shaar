# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run the real native engine against a disposable, authored local account fixture."""

import http.server
from http.cookies import SimpleCookie
import argparse
import fcntl
import json
import hashlib
import math
import os
import re
from pathlib import Path
import signal
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import uuid
import zlib
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
                or host.get('probeMode') != 'full-fixture'
                or host.get('savedTabCapacityOnly') is not False
                or host.get('savedTabCapacityProbe') is not False
                or host.get('externalAppConsentOnly') is not False
                or host.get('externalAppConsentProbe') is not False
                or host.get('bitwardenStoreProbe') is not True
                or host.get('bitwardenOnboardingControl') is not control_only
                or vendor.get('controlOnly') is not control_only
                or type(host.get('passed')) is not bool
                or type(host.get('localFixturesPassed')) is not bool
                or type(vendor.get('passed')) is not bool
                or type(vendor.get('firstClickAcceptancePassed')) is not bool):
            raise RuntimeError('Bitwarden summary has missing or mismatched phase/mode evidence')
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
                   scope='Signed-out extension onboarding only. No account credentials tested.')
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


def probe_timeout(seconds):
    """Stretch a probe deadline on slower machines; SHAAR_PROBE_TIMEOUT_SCALE is at least 1."""
    try:
        scale = float(os.environ.get('SHAAR_PROBE_TIMEOUT_SCALE', '1'))
    except ValueError:
        scale = 1.0
    return seconds * max(1.0, scale)


def wait_for_probe(process, root, phase, timeout):
    timeout = probe_timeout(timeout)
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
    deadline = time.monotonic() + probe_timeout(timeout)
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
    initial = json.loads((root / 'initial.json').read_text())
    if (initial.get('probeMode') != 'full-fixture'
            or initial.get('externalAppConsentOnly') is not False
            or initial.get('externalAppConsentProbe') is not False
            or restart.get('probeMode') != 'full-fixture'
            or restart.get('savedTabCapacityOnly') is not False
            or restart.get('savedTabCapacityProbe') is not False
            or restart.get('externalAppConsentOnly') is not False
            or restart.get('externalAppConsentProbe') is not False):
        raise RuntimeError('Abrupt summary requires full-fixture restart evidence')
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


# Stands in for the Chrome Web Store, which fixes its body minimum width at 1280 px.
WEB_STORE_FIT_PAGE = b"""<!doctype html><html data-arcusis-fixture="web-store-fit"><meta charset="utf-8">
<title>Web Store fit fixture</title>
<style>body{margin:0;min-width:1280px;font:18px system-ui}</style>
<p>Fixed minimum width, like the Chrome Web Store.</p></html>"""


# A silent canvas stream: no network or audio device. The handlers log each Media Session
# action so the probe can confirm what reached the page. The clip is a 40 second silent
# WebM loaded as a blob, so it has a duration to skip within.
MEDIA_SESSION_PAGE = b"""<!doctype html><html data-arcusis-fixture="media"><meta charset="utf-8">
<title>Media session fixture</title>
<canvas id="canvas" width="320" height="180"></canvas>
<video id="video" width="320" height="180" playsinline></video>
<video id="clip" width="320" height="180" playsinline loop></video>
<script>
const canvas=document.getElementById('canvas'),video=document.getElementById('video');
const context=canvas.getContext('2d');let hue=0;
setInterval(()=>{context.fillStyle=`hsl(${hue=(hue+9)%360} 60% 50%)`;context.fillRect(0,0,320,180);},50);
video.srcObject=canvas.captureStream(20);
fetch('/media-clip.webm').then(r=>r.blob()).then(b=>{document.getElementById('clip').src=URL.createObjectURL(b);});
window.arcusisMediaLog=[];
navigator.mediaSession.metadata=new MediaMetadata({title:'Fixture Song',artist:'Fixture Artist',
  album:'Fixture Album',artwork:[{src:'/favicon-initial.png',sizes:'64x48',type:'image/png'}]});
for(const action of ['play','pause','previoustrack','nexttrack']){
  navigator.mediaSession.setActionHandler(action,()=>{window.arcusisMediaLog.push(action);
    if(action==='play')video.play();if(action==='pause')video.pause();});
}
</script></html>"""

PAGE_CSP = "default-src 'none'; img-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'"
MEDIA_SESSION_CSP = PAGE_CSP + "; connect-src 'self'; media-src blob:"
MEDIA_CLIP = Path(__file__).resolve().parent.parent / 'Tests/Fixtures/Media/seekable-clip.webm'


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        favicon_colors = {
            '/favicon-initial.png': (52, 86, 120),
            '/favicon-restart.png': (138, 75, 18),
        }
        if path in favicon_colors:
            red, green, blue = favicon_colors[path]
            rows = b''.join(b'\0' + bytes((red, green, blue)) * 64 for _ in range(48))

            def chunk(kind, data):
                return (struct.pack('!I', len(data)) + kind + data
                        + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff))

            body = (b'\x89PNG\r\n\x1a\n'
                    + chunk(b'IHDR', struct.pack('!IIBBBBB', 64, 48, 8, 2, 0, 0, 0))
                    + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.startswith('/download/'):
            self.download(path.rsplit('/', 1)[-1])
            return
        if path == '/web-store-fit':
            self.html(WEB_STORE_FIT_PAGE)
            return
        if path == '/media':
            self.html(MEDIA_SESSION_PAGE, csp=MEDIA_SESSION_CSP)
            return
        if path == '/media-clip.webm':
            body = MEDIA_CLIP.read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'video/webm')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.html(b"""<!doctype html><html data-arcusis-fixture="v1"><meta charset="utf-8">
<title>Arcusis account isolation fixture</title>
<style>body{font:18px system-ui;padding:60px;color:#293445;background:#f0f4f8}</style>
<h1>Local account isolation fixture</h1><p>Disposable test data only.</p>
<p>OrbitFindMarker OrbitFindMarker OrbitFindMarker</p>
<form><label>Username <input id="username" autocomplete="username"></label>
<label>Password <input id="password" type="password" autocomplete="current-password"></label></form>
<script>window.arcusisInstance=crypto.randomUUID();</script></html>""")

    def html(self, body, csp=PAGE_CSP):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", csp)
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


SAVED_TAB_CAPACITY_MODE = 'saved-tab-capacity-only'
SAVED_TAB_CAPACITY_SCOPE = (
    'Owned managed workspace with authored loopback fixture; 1440 saved tabs, '
    'four profiles, eight visited Spaces, at most eight live tabs; no user profile '
    'or external host. Does not measure hundreds of renderers or process memory.'
)
EXTERNAL_APP_CONSENT_MODE = 'external-app-consent-only'
EXTERNAL_APP_CONSENT_SCOPE = (
    'Owned loopback external-app consent with native no-launch resolver; no operating-system handler launch '
    'and no real account.'
)
EXTERNAL_APP_CONSENT_CHECKS = (
    'handlerAvailable', 'noLaunchGuardEnabled', 'profileAApproved', 'profileBApproved',
    'denyWithoutLaunch', 'replayIgnored', 'unpresentedDenied', 'profileSwitchDenied',
    'navigationDenied', 'sameURLReloadDenied', 'tabCloseDenied', 'windowCloseDenied',
    'foreignWindowDenied', 'engineQuitDenied', 'allUnremembered',
)
EXTERNAL_APP_CONSENT_BOOLEAN_FIELDS = EXTERNAL_APP_CONSENT_CHECKS
EXTERNAL_APP_CONSENT_FORBIDDEN_KEYS = {
    'url', 'apppath', 'icon', 'title', 'message', 'rememberdestination',
}
EXTERNAL_APP_CONSENT_REPORT_KEYS = {
    'schema', 'mode', 'scope', 'phase', 'runID', 'passed', 'checks', 'checkCount',
    *EXTERNAL_APP_CONSENT_BOOLEAN_FIELDS, 'approvedRequests', 'launchCount',
    'deniedRequests', 'cleanup',
}
EXTERNAL_APP_CONSENT_CLEANUP_KEYS = {
    'mode', 'scope', 'phase', 'runID', 'engineClosed', 'primaryWindowClosed',
    'routerClientCount', 'pendingRequests', 'passed',
}
PRIVATE_WINDOW_MODE = 'private-window-owned-engine-fixture'
PRIVATE_WINDOW_SCOPE = (
    'Owned hidden native product and engine windows on synthetic loopback origin. No real accounts, '
    'third-party endpoints or physical input.'
)
PRIVATE_WINDOW_CHECKS = (
    'freshMarkedRoot', 'sourceProfileAccepted', 'unknownSourceRejected', 'otrSourceRejected',
    'malformedContextRejected',
    'normalProfileIDCollisionRejected', 'normalWindowIDCollisionRejected',
    'normalTabIDCollisionRejected',
    'multipleTabsShareNativePrivateWindow', 'privateSelectionAndNativeViewsOwned',
    'privateNavigationReloadBackForward', 'privateCallbacksUseOwnersWithoutRegularContamination',
    'invalidPrivateOperationsRejected', 'privateTabCloseConfirmedAndStaleRejected',
    'privateWindowCloseCallbackOwnerRouted', 'repeatedPrivateWindowCloseRejected',
    'normalFactoriesRejectPrivateIdentities', 'releaseWhileOwnedWindowRejected',
    'sameSourcePendingCallbacksShareOTR',
    'releaseDuringPendingWindowCreationRejected',
    'nativePrivateTabOwnedByActiveWebContents',
    'hiddenWindowsRemainUnordered',
    'sameSourceWindowsShareCookiesAndLocalStorage', 'sameSourceSessionStorageIsTabLocal',
    'differentSourceContextsIsolated', 'closingOneSharedWindowRetainsOther',
    'closeCancellationRetainsOwnership',
    'normalDocumentAndStorageRemainLive', 'normalHistoryIncludesAuthoredVisit',
    'normalHistoryExcludesPrivateVisitsBeforeClose', 'normalHistoryExcludesPrivateVisitsAfterClose',
    'lastCloseReopenClearsPrivateData', 'normalSelectionUnchanged', 'staleContextRejected',
    'closedWindowRejected', 'cleanupChildrenClosed', 'cleanupContextsRetired',
    'productHostOwnsPrivateNativeWindow', 'productCommandTUsesPrivateOpaqueSearch',
    'productCommandLTargetsCurrentPrivateTab',
    'productPrivateNavigationReloadBackForwardCallbacks',
    'productPrivateFocusUsesOwnedTab',
    'productSameSourceWindowsShareContext', 'productDifferentSourceWindowsIsolateContext',
    'productCancelledCloseRetainsOwner', 'productNormalHistoryExcludesPrivateVisit',
    'productCancelledQuitRetainsLivePrivateLease',
    'productNativeQuitCancellationReturned', 'productCancelledQuitRestoredRuntimeState',
    'productCancelledQuitRetainedPrivateWindow', 'productCancelledQuitRetainedPrivateContext',
    'productCancelledQuitRetainedNormalWindow',
    'productFinalCloseAfterCancelledQuitReleasesLease',
    'productFinalPrivateWindowCloseRequestedWhileQuitAndReleasedAfterConfirmation',
    'productWorkspaceBytesUnchanged', 'productWorkspaceBytesUnchangedAfterClose',
    'productFinalCloseReleasesOwners', 'productWeakStoreReleasedAfterConfirmedClose',
    'productWeakHostingReleasedAfterConfirmedClose',
    'productBeforeUnloadUsesRendererUserActivation',
    'productNativeCDPHoldConfirmedPending',
    'productNativeBeforeUnloadHandlerFired',
    'productBeforeUnloadRemovedBeforeFinalFixtureQuit',
    'productCancelledQuitRetiresOnlyConfirmedPrivateLease',
)


def argument_parser():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--bitwarden", action="store_true", help="Install Bitwarden from the real Chrome Web Store in a disposable profile")
    mode.add_argument("--bitwarden-onboarding-control", action="store_true",
                      help="Diagnostic only: wait two seconds on intro before Log in; cannot establish clean first-click acceptance")
    mode.add_argument("--abrupt-restart", action="store_true", help="SIGKILL the disposable probe after its fixture checkpoint, then verify recovery")
    mode.add_argument("--abrupt-control", action="store_true", help="Diagnostic only: idle 35s before SIGKILL; does not establish strict crash-recovery acceptance")
    mode.add_argument("--saved-tab-capacity", action="store_true",
                      help="Run only the owned 1440-saved-tab capacity probe in both phases")
    mode.add_argument("--external-app-consent", action="store_true",
                      help="Run only the external-app consent probe with native no-launch guard")
    mode.add_argument("--private-window", action="store_true",
                      help="Compose owned native OTR windows with both normal engine fixture phases")
    return parser


def build_engine_probe_arguments(executable, root, fixture_url, phase, *, include_bitwarden,
                                 onboarding_control, abrupt, saved_tab_capacity,
                                 external_app_consent=False, private_window=False,
                                 private_window_run_id=None):
    arguments = [str(executable), "--probe-data-dir", str(root),
                 "--probe-url", fixture_url, "--probe-phase", phase,
                 "--probe-output", str(root / f"{phase}.json")]
    if include_bitwarden:
        arguments.append("--bitwarden")
    if onboarding_control:
        arguments.append('--bitwarden-onboarding-control')
    if abrupt:
        arguments.append('--probe-await-abrupt-termination' if phase == 'initial'
                         else '--probe-expect-abrupt-recovery')
    if saved_tab_capacity:
        arguments.append('--probe-saved-tab-capacity')
    if external_app_consent:
        arguments.extend(('--probe-external-app-consent', '--ardia-test-external-protocol-no-launch'))
    if private_window:
        if not isinstance(private_window_run_id, str):
            raise RuntimeError('Private window mode requires a run identity')
        arguments.append('--probe-private-window')
        arguments.extend(('--probe-private-window-run-id', private_window_run_id))
    return arguments


def validate_private_window_report(root, phase, report, exit_code):
    path = root / f'{phase}-private-window.json'
    try:
        evidence = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise RuntimeError(f'Malformed private-window report: {path.name}') from error
    if not isinstance(evidence, dict):
        raise RuntimeError(f'Private-window report must be a JSON object: {path.name}')
    checks = evidence.get('checks')
    cleanup = evidence.get('cleanup')
    run_id = evidence.get('runID')
    try:
        canonical_run = isinstance(run_id, str) and str(uuid.UUID(run_id)).upper() == run_id
    except ValueError:
        canonical_run = False
    digest = evidence.get('historyPathDigest')
    workspace_digest = evidence.get('workspaceSHA256')
    screenshot_digest = evidence.get('productScreenshotSHA256')
    renderer_digest = evidence.get('productRendererScreenshotSHA256')
    viewport_audit = evidence.get('productRendererViewportAudit')
    screenshot_path = Path('build/private-window-evidence') / (
        run_id if isinstance(run_id, str) else 'invalid') / f'product-{phase}.png'
    renderer_path = Path('build/private-window-evidence') / (
        run_id if isinstance(run_id, str) else 'invalid') / f'renderer-product-{phase}.png'
    try:
        screenshot_bytes = screenshot_path.read_bytes()
    except OSError:
        screenshot_bytes = b''
    try:
        renderer_bytes = renderer_path.read_bytes()
    except OSError:
        renderer_bytes = b''
    if (exit_code != 0 or not isinstance(report, dict)
            or report.get('phase') != phase or report.get('passed') is not True
            or report.get('error') is not None
            or report.get('probeMode') != PRIVATE_WINDOW_MODE
            or report.get('privateWindowOnly') is not True
            or report.get('privateWindowProbe') is not True
            or report.get('savedTabCapacityOnly') is not False
            or report.get('externalAppConsentOnly') is not False
            or report.get('bitwardenStoreProbe') is not False
            or type(evidence.get('schema')) is not int or evidence['schema'] != 1
            or evidence.get('mode') != PRIVATE_WINDOW_MODE or evidence.get('phase') != phase
            or not canonical_run or evidence.get('passed') is not True
            or type(evidence.get('requiredCheckCount')) is not int
            or evidence['requiredCheckCount'] != len(PRIVATE_WINDOW_CHECKS)
            or type(evidence.get('checkCount')) is not int
            or not isinstance(checks, dict) or set(checks) != set(PRIVATE_WINDOW_CHECKS)
            or evidence['checkCount'] != len(checks)
            or evidence['checkCount'] != evidence['requiredCheckCount']
            or type(evidence.get('historyEntryCount')) is not int
            or evidence['historyEntryCount'] <= 0
            or evidence.get('historyQuerySucceeded') is not True
            or any(type(checks.get(name)) is not bool or checks[name] is not True for name in PRIVATE_WINDOW_CHECKS)
            or not isinstance(digest, str) or len(digest) != 64
            or any(character not in '0123456789abcdef' for character in digest)
            or not isinstance(workspace_digest, str) or len(workspace_digest) != 64
            or any(character not in '0123456789abcdef' for character in workspace_digest)
            or not isinstance(screenshot_digest, str) or len(screenshot_digest) != 64
            or any(character not in '0123456789abcdef' for character in screenshot_digest)
            or not screenshot_bytes.startswith(b'\x89PNG\r\n\x1a\n')
            or hashlib.sha256(screenshot_bytes).hexdigest() != screenshot_digest
            or not isinstance(renderer_digest, str) or len(renderer_digest) != 64
            or any(character not in '0123456789abcdef' for character in renderer_digest)
            or not renderer_bytes.startswith(b'\x89PNG\r\n\x1a\n')
            or hashlib.sha256(renderer_bytes).hexdigest() != renderer_digest
            or evidence.get('productRendererCaptureOutcome') != 'captured'
            or not isinstance(viewport_audit, dict)
            or viewport_audit.get('allWindowsNativeWindowsAlive') is not True
            or type(viewport_audit.get('allTabsAttachedToHostView')) is not bool
            or viewport_audit.get('allWindowsDisplayOwnedWebContents') is not True
            or viewport_audit.get('visibleNativeViewportCount') != 1
            or not isinstance(cleanup, dict) or cleanup.get('windowsRemaining') != 0
            or cleanup.get('contextsRemaining') != 0 or cleanup.get('passed') is not True
            or evidence.get('scope') != PRIVATE_WINDOW_SCOPE
            or report.get('localFixturesPassed') is not True):
        raise RuntimeError(f'{phase} private-window evidence has failed or mismatched checks/cleanup')
    return evidence


def record_private_window_summary(root, *, listener_closed, child_receipts, proof_directory):
    summaries = []
    for phase in ('initial', 'restart'):
        try:
            report = json.loads((root / f'{phase}.json').read_text())
        except (OSError, ValueError):
            report = None
        try:
            evidence = json.loads((root / f'{phase}-private-window.json').read_text())
            if not isinstance(evidence, dict):
                evidence = {}
        except (OSError, ValueError):
            evidence = {}
        try:
            validate_private_window_report(root, phase, report,
                                           report.get('exitCode', 1) if isinstance(report, dict) else 1)
            validation_error = None
        except (RuntimeError, OSError):
            validation_error = 'failed-or-mismatched-private-window-evidence'
        summaries.append(dict(
            phase=phase, passed=validation_error is None,
            runID=evidence.get('runID'),
            checkCount=evidence.get('checkCount'),
            requiredCheckCount=evidence.get('requiredCheckCount'),
            workspaceSHA256=evidence.get('workspaceSHA256'),
            productScreenshotSHA256=evidence.get('productScreenshotSHA256'),
            validationError=validation_error,
            cleanup=evidence.get('cleanup')))
    if summaries[0]['runID'] != summaries[1]['runID']:
        for phase in summaries:
            phase['passed'] = False
            phase['validationError'] = 'private-window-run-identity-mismatch'
    if summaries[0]['workspaceSHA256'] != summaries[1]['workspaceSHA256']:
        for phase in summaries:
            phase['passed'] = False
            phase['validationError'] = 'normal-workspace-changed-between-phases'
    children_closed = (
        len(child_receipts) == 2
        and [item.get('phase') for item in child_receipts] == ['initial', 'restart']
        and all(item.get('childExited') is True and item.get('processGroupAbsent') is True
                for item in child_receipts))
    passed = all(phase['passed'] for phase in summaries) and listener_closed is True and children_closed
    summary = dict(schema=1, mode=PRIVATE_WINDOW_MODE, phases=summaries,
                   childProcesses=child_receipts, listenerClosed=listener_closed,
                   passed=passed, proofDirectory=str(proof_directory), scope=PRIVATE_WINDOW_SCOPE)
    (root / 'private-window-summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    proof_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    for phase in ('initial', 'restart'):
        main_path = root / f'{phase}.json'
        try:
            main = json.loads(main_path.read_text())
        except (OSError, ValueError):
            main = None
        if isinstance(main, dict):
            # Keep authored check descriptions and bounded stage, never raw error text.
            fields = ('phase', 'passed', 'chromiumVersion', 'probeMode', 'savedTabCapacityOnly',
                      'savedTabCapacityProbe', 'bitwardenStoreProbe',
                      'bitwardenOnboardingControl', 'externalAppConsentOnly',
                      'externalAppConsentProbe', 'privateWindowOnly', 'privateWindowProbe',
                      'abruptRecoveryProbe', 'localFixturesPassed',
                      'nativeFavoritesPassed', 'bootstrapStage', 'fixtureStage', 'checkCount',
                      'checks', 'exitCode', 'scope')
            redacted = {key: main[key] for key in fields if key in main}
            error = main.get('error')
            redacted['error'] = (None if error is None else
                                 'timeout' if isinstance(error, str) and 'Engine probe timed out.' in error else
                                 'host-identities-missing' if isinstance(error, str) and 'host-identities.json' in error else
                                 'probe-failed')
            if isinstance(error, str) and 'host-identities.json' in error:
                redacted['hostIdentityError'] = True
            (proof_directory / main_path.name).write_text(json.dumps(redacted, indent=2, sort_keys=True) + '\n')
        private_path = root / f'{phase}-private-window.json'
        if private_path.is_file():
            shutil.copy2(private_path, proof_directory)
        diagnostic = root / f'{phase}-private-quit-diagnostic.json'
        if diagnostic.is_file():
            shutil.copy2(diagnostic, proof_directory)
        run_id = summaries[0]['runID']
        if not isinstance(run_id, str) or not re.fullmatch(r'[0-9A-F-]{36}', run_id):
            continue
        screenshot = Path('build/private-window-evidence') / run_id / f'product-{phase}.png'
        if screenshot.is_file() and screenshot.resolve() != (proof_directory / screenshot.name).resolve():
            shutil.copy2(screenshot, proof_directory)
        renderer = Path('build/private-window-evidence') / summaries[0]['runID'] / f'renderer-product-{phase}.png'
        if renderer.is_file() and renderer.resolve() != (proof_directory / renderer.name).resolve():
            shutil.copy2(renderer, proof_directory)
    shutil.copy2(root / 'private-window-summary.json', proof_directory)
    return summary


def verify_fixture_listener_closed(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(('127.0.0.1', port))
        except OSError:
            return False
    return True


def _reject_external_consent_fields(value):
    if isinstance(value, dict):
        if any(''.join(character for character in key.lower() if character.isalnum())
               in EXTERNAL_APP_CONSENT_FORBIDDEN_KEYS for key in value if isinstance(key, str)):
            raise RuntimeError('External-app consent report contains forbidden raw fields')
        for nested in value.values():
            _reject_external_consent_fields(nested)
    elif isinstance(value, list):
        for nested in value:
            _reject_external_consent_fields(nested)


def validate_external_app_consent_report(root, phase, report, exit_code):
    if not isinstance(report, dict):
        raise RuntimeError(f'{phase} engine report must be a JSON object')
    path = root / f'{phase}-external-app-consent.json'
    try:
        evidence = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise RuntimeError(f'Malformed external-app consent report: {path.name}') from error
    if not isinstance(evidence, dict):
        raise RuntimeError(f'External-app consent report must be a JSON object: {path.name}')
    _reject_external_consent_fields(evidence)
    if set(evidence) != EXTERNAL_APP_CONSENT_REPORT_KEYS:
        raise RuntimeError('External-app consent report has unknown or missing fields')
    if not isinstance(evidence.get('cleanup'), dict) or set(evidence['cleanup']) != EXTERNAL_APP_CONSENT_CLEANUP_KEYS:
        raise RuntimeError('External-app consent cleanup has unknown or missing fields')
    run_id = evidence.get('runID')
    try:
        if not isinstance(run_id, str) or str(uuid.UUID(run_id)).upper() != run_id:
            raise ValueError('noncanonical UUID')
    except ValueError as error:
        raise RuntimeError('External-app consent report has invalid run identity') from error
    checks = evidence.get('checks')
    cleanup = evidence.get('cleanup')
    if (exit_code != 0 or report.get('phase') != phase
            or report.get('probeMode') != EXTERNAL_APP_CONSENT_MODE
            or report.get('externalAppConsentOnly') is not True
            or report.get('externalAppConsentProbe') is not True
            or report.get('externalAppConsentRunID') != run_id
            or report.get('savedTabCapacityOnly') is not False
            or report.get('savedTabCapacityProbe') is not False
            or report.get('bitwardenStoreProbe') is not False
            or report.get('bitwardenOnboardingControl') is not False
            or report.get('abruptRecoveryProbe') is not False
            or report.get('scope') != EXTERNAL_APP_CONSENT_SCOPE
            or report.get('passed') is not True
            or report.get('localFixturesPassed') is not False
            or report.get('error') is not None
            or type(evidence.get('schema')) is not int or evidence['schema'] != 1
            or evidence.get('mode') != EXTERNAL_APP_CONSENT_MODE
            or evidence.get('scope') != EXTERNAL_APP_CONSENT_SCOPE
            or evidence.get('phase') != phase
            or evidence.get('passed') is not True
            or not isinstance(checks, list) or checks != list(EXTERNAL_APP_CONSENT_CHECKS)
            or type(evidence.get('checkCount')) is not int or evidence['checkCount'] != len(checks)
            or any(type(evidence.get(key)) is not bool or evidence[key] is not True
                   for key in EXTERNAL_APP_CONSENT_BOOLEAN_FIELDS)
            or type(evidence.get('approvedRequests')) is not int or evidence['approvedRequests'] != 2
            or type(evidence.get('launchCount')) is not int or evidence['launchCount'] != 2
            or type(evidence.get('deniedRequests')) is not int or evidence['deniedRequests'] < 6
            or not isinstance(cleanup, dict)
            or cleanup.get('mode') != EXTERNAL_APP_CONSENT_MODE
            or cleanup.get('scope') != EXTERNAL_APP_CONSENT_SCOPE
            or cleanup.get('phase') != phase or cleanup.get('runID') != run_id
            or cleanup.get('engineClosed') is not True
            or cleanup.get('primaryWindowClosed') is not True
            or type(cleanup.get('routerClientCount')) is not int or cleanup['routerClientCount'] != 0
            or type(cleanup.get('pendingRequests')) is not int or cleanup['pendingRequests'] != 0
            or cleanup.get('passed') is not True):
        raise RuntimeError(f'{phase} external-app consent evidence has mismatched mode, scope, counts, or cleanup')
    return evidence


def validate_full_fixture_report(report, phase):
    if (not isinstance(report, dict) or report.get('phase') != phase
            or report.get('probeMode') != 'full-fixture'
            or report.get('savedTabCapacityOnly') is not False
            or report.get('savedTabCapacityProbe') is not False
            or report.get('externalAppConsentOnly') is not False
            or report.get('externalAppConsentProbe') is not False):
        raise RuntimeError('Full fixture report has wrong phase or mode')


def validate_saved_tab_capacity_report(root, phase, report, exit_code):
    if not isinstance(report, dict):
        raise RuntimeError(f'{phase} engine report must be a JSON object')
    path = root / f'{phase}-saved-tab-capacity.json'
    try:
        capacity = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise RuntimeError(f'Malformed capacity report: {path.name}') from error
    if not isinstance(capacity, dict):
        raise RuntimeError(f'Capacity report must be a JSON object: {path.name}')
    run_id = capacity.get('runID')
    try:
        if not isinstance(run_id, str) or str(uuid.UUID(run_id)).upper() != run_id:
            raise ValueError('noncanonical UUID')
    except ValueError as error:
        raise RuntimeError('Capacity report has invalid run identity') from error
    cleanup = capacity.get('cleanup')
    checks = capacity.get('checks')
    def canonical_ids(values, count):
        if not isinstance(values, list) or len(values) != count:
            return False
        try:
            return all(isinstance(value, str) and str(uuid.UUID(value)).upper() == value
                       for value in values) and len(set(values)) == count
        except ValueError:
            return False

    profile_ids = capacity.get('profileIDs')
    space_ids = capacity.get('savedSpaceIDs')
    selected_tab_ids = capacity.get('selectedTabIDs')
    native_tab_ids = capacity.get('visitedNativeTabIDs')
    timings = capacity.get('visitTimings')
    native_ids_valid = (isinstance(native_tab_ids, list) and len(native_tab_ids) == 8
                        and all(type(value) is int and value >= 0 for value in native_tab_ids)
                        and len(set(native_tab_ids)) == 8)
    timing_valid = (isinstance(timings, list) and len(timings) == 8
                    and all(isinstance(item, dict)
                            and item.get('spaceID') == space_ids[index]
                            and item.get('profileID') in profile_ids
                            and type(item.get('nativeTabID')) is int
                            and item['nativeTabID'] == native_tab_ids[index]
                            and type(item.get('nativeLiveTabs')) is int
                            and item['nativeLiveTabs'] == index + 1
                            and type(item.get('elapsedMilliseconds')) in (int, float)
                            and math.isfinite(item['elapsedMilliseconds'])
                            and item['elapsedMilliseconds'] >= 0
                            for index, item in enumerate(timings))
                    and {item.get('profileID') for item in timings} == set(profile_ids)) if (
                                canonical_ids(profile_ids, 4) and canonical_ids(space_ids, 12)
                                and canonical_ids(selected_tab_ids, 12)
                                and native_ids_valid) else False
    initial_document_ms = capacity.get('initialDocumentWaitMilliseconds')
    visits_ms = capacity.get('visitDurationMilliseconds')
    if (exit_code != 0 or report.get('phase') != phase or report.get('passed') is not True
            or report.get('probeMode') != SAVED_TAB_CAPACITY_MODE
            or report.get('savedTabCapacityOnly') is not True
            or report.get('savedTabCapacityProbe') is not True
            or report.get('savedTabCapacityRunID') != run_id
            or report.get('scope') != SAVED_TAB_CAPACITY_SCOPE
            or report.get('localFixturesPassed') is not False
            or report.get('bitwardenStoreProbe') is not False
            or report.get('bitwardenOnboardingControl') is not False
            or report.get('abruptRecoveryProbe') is not False
            or report.get('externalAppConsentOnly') is not False
            or report.get('externalAppConsentProbe') is not False
            or report.get('error') is not None
            or type(capacity.get('schema')) is not int or capacity['schema'] != 1
            or capacity.get('phase') != phase or capacity.get('mode') != SAVED_TAB_CAPACITY_MODE
            or capacity.get('scope') != SAVED_TAB_CAPACITY_SCOPE or capacity.get('runID') != run_id
            or capacity.get('passed') is not True or capacity.get('error') is not None
            or capacity.get('workspaceSnapshot') != 'saved-tab-capacity-workspace.json'
            or capacity.get('identityCheckpoint') != 'saved-tab-capacity-identities.json'
            or not isinstance(space_ids, list)
            or capacity.get('selectedSpaceID') not in space_ids
            or any(type(capacity.get(key)) is not int or capacity[key] != expected for key, expected in {
                'profileCount': 4, 'spaceCount': 12, 'savedTabs': 1440, 'visitedSpaces': 8,
                'visitedProfiles': 4, 'initialNativeLiveTabs': 1, 'peakNativeLiveTabs': 8,
                'liveTabsAfterVisits': 8, 'unvisitedTabsMaterialized': 0,
            }.items())
            or not canonical_ids(profile_ids, 4) or not canonical_ids(space_ids, 12)
            or not canonical_ids(selected_tab_ids, 12) or not native_ids_valid
            or capacity.get('initialNativeTabID') != native_tab_ids[0]
            or not timing_valid
            or type(initial_document_ms) not in (int, float)
            or not math.isfinite(initial_document_ms) or initial_document_ms < 0
            or type(visits_ms) not in (int, float) or not math.isfinite(visits_ms) or visits_ms < 0
            or not math.isclose(visits_ms, sum(item['elapsedMilliseconds'] for item in timings),
                                rel_tol=1e-6, abs_tol=0.01)
            or not isinstance(checks, list) or not checks
            or not all(isinstance(check, str) and check for check in checks)
            or not isinstance(cleanup, dict) or cleanup.get('mode') != SAVED_TAB_CAPACITY_MODE
            or cleanup.get('phase') != phase or cleanup.get('runID') != run_id
            or cleanup.get('scope') != SAVED_TAB_CAPACITY_SCOPE
            or cleanup.get('engineClosed') is not True
            or cleanup.get('primaryWindowClosed') is not True
            or type(cleanup.get('routerClientCount')) is not int
            or cleanup['routerClientCount'] != 0 or cleanup.get('passed') is not True):
        raise RuntimeError(f'{phase} capacity evidence has mismatched mode, scope, counts, or cleanup')
    return capacity


def record_saved_tab_capacity_summary(root):
    summary_path = root / 'saved-tab-capacity-summary.json'
    summary_path.unlink(missing_ok=True)
    reports = []
    for phase in ('initial', 'restart'):
        try:
            main_report = json.loads((root / f'{phase}.json').read_text())
        except json.JSONDecodeError as error:
            raise RuntimeError(f'Malformed engine report: {phase}.json') from error
        if (not isinstance(main_report, dict) or main_report.get('phase') != phase
                or main_report.get('probeMode') != SAVED_TAB_CAPACITY_MODE
                or main_report.get('savedTabCapacityOnly') is not True
                or main_report.get('savedTabCapacityProbe') is not True
                or main_report.get('scope') != SAVED_TAB_CAPACITY_SCOPE
                or main_report.get('localFixturesPassed') is not False):
            raise RuntimeError('Capacity summary has mismatched phase or main-report scope')
        capacity = validate_saved_tab_capacity_report(root, phase, main_report, 0)
        reports.append(dict(phase=phase, passed=True, runID=capacity['runID'],
                            savedTabs=capacity['savedTabs'], visitedSpaces=capacity['visitedSpaces'],
                            visitedProfiles=capacity['visitedProfiles'], cleanup=capacity['cleanup']))
    if reports[0]['runID'] != reports[1]['runID']:
        raise RuntimeError('Capacity initial and restart evidence have different run identities')
    summary = dict(schema=1, mode=SAVED_TAB_CAPACITY_MODE, runID=reports[0]['runID'],
                   scope=SAVED_TAB_CAPACITY_SCOPE, phases=reports, passed=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=root,
                                         prefix='.saved-tab-capacity-summary-',
                                         suffix='.tmp', delete=False) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(json.dumps(summary, indent=2, sort_keys=True) + '\n')
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, summary_path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    return summary


def record_external_app_consent_summary(root):
    summary_path = root / 'external-app-consent-summary.json'
    summary_path.unlink(missing_ok=True)
    reports = []
    for phase in ('initial', 'restart'):
        try:
            main_report = json.loads((root / f'{phase}.json').read_text())
        except json.JSONDecodeError as error:
            raise RuntimeError(f'Malformed engine report: {phase}.json') from error
        evidence = validate_external_app_consent_report(root, phase, main_report, 0)
        reports.append(dict(phase=phase, passed=True, runID=evidence['runID'],
                            approvedRequests=evidence['approvedRequests'],
                            deniedRequests=evidence['deniedRequests'],
                            launchCount=evidence['launchCount'], cleanup=evidence['cleanup']))
    if reports[0]['runID'] != reports[1]['runID']:
        raise RuntimeError('External-app consent initial and restart evidence have different run identities')
    summary = dict(schema=1, mode=EXTERNAL_APP_CONSENT_MODE, runID=reports[0]['runID'],
                   scope=EXTERNAL_APP_CONSENT_SCOPE, phases=reports, passed=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=root,
                                         prefix='.external-app-consent-summary-',
                                         suffix='.tmp', delete=False) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(json.dumps(summary, indent=2, sort_keys=True) + '\n')
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, summary_path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    return summary


def main(argv=None):
    options = argument_parser().parse_args(argv)
    include_bitwarden = options.bitwarden or options.bitwarden_onboarding_control
    if options.bitwarden_onboarding_control:
        print('CONTROL ONLY: two-second intro-screen age; clean first-click acceptance is not evaluated', flush=True)
    abrupt = options.abrupt_restart or options.abrupt_control
    if options.saved_tab_capacity:
        print('SAVED TAB CAPACITY ONLY: no account, MV3, or full baseline claims', flush=True)
    if options.external_app_consent:
        print('EXTERNAL APP CONSENT ONLY: owned loopback; native no-launch guard enabled', flush=True)
    if options.private_window:
        print('PRIVATE WINDOW FIXTURE: owned hidden OTR windows; synthetic loopback only', flush=True)
    root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
    (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
    (root / ".arcusis-probe").chmod(0o600)
    private_window_run_id = str(uuid.uuid4()).upper() if options.private_window else None
    shutil.copytree("Tests/Fixtures/ProfileExtension", root / "Extension")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    executable = Path("build/Shaar Verification.app/Contents/MacOS/ShaarVerification").resolve()
    (root / 'Downloads').mkdir(mode=0o700)
    # Any ARDIA_BACKGROUND value keeps Chromium's picture-in-picture overlay transparent and
    # click-through, so the media probe opens no visible window. The engine's other
    # background test hooks require exactly '1' and stay off.
    probe_env = dict(os.environ, ARDIA_DOWNLOADS_DIR=str(root / 'Downloads'),
                     ARDIA_BACKGROUND='picture-in-picture')
    print(f"Probe evidence: {root}", flush=True)
    failures = []
    private_window_children = []
    try:
        for phase in ("initial", "restart"):
            output = root / f"{phase}.json"
            arguments = build_engine_probe_arguments(
                executable, root, f"http://127.0.0.1:{server.server_port}/account", phase,
                include_bitwarden=include_bitwarden,
                onboarding_control=options.bitwarden_onboarding_control,
                abrupt=abrupt, saved_tab_capacity=options.saved_tab_capacity,
                external_app_consent=options.external_app_consent,
                private_window=options.private_window,
                private_window_run_id=private_window_run_id)
            with (root / f"{phase}.log").open("w") as log:
                process = subprocess.Popen(arguments, stdout=log, stderr=log, start_new_session=True, env=probe_env)
                try:
                    if abrupt and phase == 'initial':
                        terminate_at_checkpoint(process, root, timeout=90, settle_seconds=35 if options.abrupt_control else 0)
                        continue
                    timeout = (240 if options.private_window else 180 if options.external_app_consent else 180 if options.saved_tab_capacity
                               else 170 if include_bitwarden else 90)
                    code = wait_for_probe(process, root, phase, timeout=timeout)
                except subprocess.TimeoutExpired:
                    raise RuntimeError(f"{phase} timed out; see {root}/{phase}.log")
                finally:
                    stop_probe(process)
            if options.private_window:
                group_deadline = time.monotonic() + 10
                while process_group_exists(process.pid) and time.monotonic() < group_deadline:
                    time.sleep(0.05)
                private_window_children.append(dict(
                    phase=phase, pid=process.pid, childExited=process.poll() is not None,
                    processGroupAbsent=not process_group_exists(process.pid)))
            if not output.exists():
                if options.private_window:
                    failures.append(f'{phase}: main report missing (exit {code})')
                    continue
                raise RuntimeError(f"{phase} failed ({code}); see {root}/{phase}.log")
            try:
                report = json.loads(output.read_text())
            except (OSError, ValueError):
                if options.private_window:
                    failures.append(f'{phase}: main report malformed')
                    continue
                raise
            if options.private_window and not isinstance(report, dict):
                failures.append(f'{phase}: main report malformed')
                continue
            if options.private_window:
                report['exitCode'] = code
                output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
            if options.saved_tab_capacity:
                validate_saved_tab_capacity_report(root, phase, report, code)
            elif options.external_app_consent:
                validate_external_app_consent_report(root, phase, report, code)
            elif options.private_window:
                try:
                    validate_private_window_report(root, phase, report, code)
                except RuntimeError as error:
                    failure = f"{phase}: {error}"
                    failures.append(failure)
                    print(f"FAILED {failure}", flush=True)
            else:
                validate_full_fixture_report(report, phase)
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
                if options.private_window:
                    continue
                raise RuntimeError(failure)
            print(f"{phase}: {len(report['checks'])} checks passed; Chromium {report['chromiumVersion']}", flush=True)
        if failures and not options.private_window:
            raise RuntimeError("; ".join(failures))
        if options.saved_tab_capacity:
            record_saved_tab_capacity_summary(root)
        if options.external_app_consent:
            record_external_app_consent_summary(root)
    finally:
        server.shutdown()
        server.server_close()
    if options.private_window:
        summary = record_private_window_summary(
            root, listener_closed=verify_fixture_listener_closed(server.server_port),
            child_receipts=private_window_children,
            proof_directory=Path('build/private-window-evidence') / private_window_run_id)
        print(f"Redacted private evidence: {summary['proofDirectory']}", flush=True)
        if not summary['passed']:
            raise RuntimeError('; '.join(failures) or 'Private-window cleanup gate failed')


if __name__ == "__main__":
    main()
