#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Hidden web-platform parity probe for the Shaar verification harness.

Serves loopback HTTP on 127.0.0.1. Cross-site iframes use localhost on that
same port. A second port serves an untrusted HTTPS certificate. The browser
maps trackertest.org to 127.0.0.1 only when the engine is launched with
testing enabled (--host-resolver-rules=MAP trackertest.org 127.0.0.1).
No external accounts or public sites. Launch through shaar-heavy.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import signal
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import urllib.parse
import zlib


ROOT = Path(__file__).resolve().parents[1]
CRASHES = Path.home() / "Library/Logs/DiagnosticReports"

BUTTON = (
    '<button id="parity-action" style="position:fixed;left:8px;top:8px;'
    'width:180px;height:48px">Run</button>'
)
SCRIPT_HEAD = """
function finish(result) { window.parityResult = result; }
function fail(error) {
  finish({
    outcome: 'rejected',
    name: error && error.name ? error.name : 'Error',
    message: error && error.message ? String(error.message) : String(error)
  });
}
"""


def page(title, body, script):
    return (
        "<!doctype html><meta charset=utf-8>"
        f"<title>{title}</title>{body}<script>{SCRIPT_HEAD}{script}</script>"
    )


def png(size, color):
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    raw = b"".join(b"\x00" + bytes(color) * size for _ in range(size))
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def wav():
    samples = bytes([128]) * 1600
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(samples), b"WAVE", b"fmt ", 16, 1, 1, 8000, 8000, 1, 8, b"data", len(samples),
    )
    return header + samples


def pdf():
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        None,
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    stream = b"BT /F1 24 Tf 36 120 Td (Parity PDF) Tj ET"
    objects[3] = b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream"
    parts = [b"%PDF-1.4\n"]
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(sum(len(part) for part in parts))
        parts.append(f"{index} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = sum(len(part) for part in parts)
    rows = ["xref\n0 6\n", "0000000000 65535 f \n"]
    rows.extend(f"{offset:010d} 00000 n \n" for offset in offsets)
    parts.append("".join(rows).encode())
    parts.append(f"trailer<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return b"".join(parts)


class Handler(BaseHTTPRequestHandler):
    seen = []
    seen_lock = threading.Lock()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 0:
            self.rfile.read(min(length, 65536))
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        route = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        port = self.server.server_address[1]
        other = f"http://localhost:{port}"
        self.peer = self.client_address[0]
        with Handler.seen_lock:
            Handler.seen.append({
                "peer": self.peer,
                "host": self.headers.get("Host", ""),
                "path": route,
            })
        body, content_type, extra = self.route(route, query, other)
        if body is None:
            self.send_error(404)
            return
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        return

    def route(self, route, query, other):
        html = "text/html; charset=utf-8"
        script = "text/javascript; charset=utf-8"
        if route == "/ready":
            return page("ready", "", "finish({outcome:'ready'});"), html, []
        if route == "/media":
            return page("media", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                navigator.mediaDevices.getUserMedia({audio:true, video:true}).then(stream => {
                  const audio = stream.getAudioTracks().length;
                  const video = stream.getVideoTracks().length;
                  stream.getTracks().forEach(track => track.stop());
                  finish({outcome:'resolved', audio, video});
                }).catch(fail);
              };
            """), html, []
        if route == "/geolocation":
            return page("geolocation", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                navigator.geolocation.getCurrentPosition(
                  position => finish({outcome:'resolved', latitude:position.coords.latitude}),
                  error => finish({outcome:'rejected', code:error.code, message:error.message}),
                  {timeout:4000, maximumAge:0});
              };
            """), html, []
        if route == "/notifications":
            return page("notifications", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                Notification.requestPermission().then(state => finish({outcome:'resolved', state})).catch(fail);
              };
            """), html, []
        if route == "/clipboard":
            return page("clipboard", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                navigator.clipboard.writeText('parity').then(() => navigator.clipboard.readText())
                  .then(text => finish({outcome:'resolved', text})).catch(fail);
              };
            """), html, []
        if route == "/midi":
            return page("midi", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                if (!navigator.requestMIDIAccess) { finish({outcome:'missing'}); return; }
                navigator.requestMIDIAccess({sysex:false})
                  .then(access => finish({outcome:'resolved', inputs:access.inputs.size})).catch(fail);
              };
            """), html, []
        if route == "/storage-access":
            frame = f"{other}/storage-frame"
            return page("storage", f'<iframe id="parity-action" src="{frame}" style="position:fixed;left:0;top:0;width:220px;height:80px;border:0"></iframe>', """
              window.addEventListener('message', event => {
                if (event.data && event.data.storageReady) window.parityReady = true;
                if (event.data && event.data.storageAccess) finish(event.data.storageAccess);
              });
            """), html, []
        if route == "/storage-frame":
            return page("storage-frame", '<button id="go" style="width:220px;height:80px">Access</button>', """
              parent.postMessage({storageReady: true}, '*');
              document.getElementById('go').onclick = () => {
                const report = result => parent.postMessage({storageAccess: result}, '*');
                if (!document.requestStorageAccess) { report({outcome:'missing'}); return; }
                document.requestStorageAccess().then(() => report({outcome:'resolved'})).catch(error => {
                  report({outcome:'rejected', name:error.name, message:error.message});
                });
              };
            """), html, []
        if route == "/webauthn":
            return page("webauthn", BUTTON, """
              document.getElementById('parity-action').onclick = async () => {
                if (!window.PublicKeyCredential) { finish({outcome:'missing'}); return; }
                let available = false;
                try { available = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(); }
                catch (error) { fail(error); return; }
                if (available) { finish({outcome:'available', create:'skipped'}); return; }
                try {
                  const challenge = new Uint8Array(16);
                  await navigator.credentials.create({publicKey:{
                    challenge, rp:{name:'Parity'},
                    user:{id:challenge, name:'parity', displayName:'Parity'},
                    pubKeyCredParams:[{type:'public-key', alg:-7}], timeout:800,
                    authenticatorSelection:{userVerification:'discouraged'}
                  }});
                  finish({outcome:'created', available:false});
                } catch (error) {
                  finish({outcome:'rejected', name:error.name, message:error.message, available:false});
                }
              };
            """), html, []
        if route == "/file-picker":
            return page("file", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                if (typeof showOpenFilePicker !== 'function') { finish({outcome:'missing'}); return; }
                showOpenFilePicker().then(handles => finish({outcome:'resolved', count:handles.length})).catch(fail);
              };
            """), html, []
        if route == "/share":
            return page("share", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                if (!navigator.share) { finish({outcome:'missing'}); return; }
                navigator.share({title:'Parity', text:'probe', url:location.href})
                  .then(() => finish({outcome:'resolved'})).catch(fail);
              };
            """), html, []
        if route == "/bluetooth":
            return page("bluetooth", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                if (!navigator.bluetooth) { finish({outcome:'missing'}); return; }
                navigator.bluetooth.requestDevice({acceptAllDevices:true})
                  .then(device => finish({outcome:'resolved', device:device.name || ''})).catch(fail);
              };
            """), html, []
        if route == "/usb":
            return page("usb", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                if (!navigator.usb) { finish({outcome:'missing'}); return; }
                navigator.usb.requestDevice({filters:[]})
                  .then(device => finish({outcome:'resolved'})).catch(fail);
              };
            """), html, []
        if route == "/hid":
            return page("hid", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                if (!navigator.hid) { finish({outcome:'missing'}); return; }
                navigator.hid.requestDevice({filters:[]}).then(() => finish({outcome:'resolved'})).catch(fail);
              };
            """), html, []
        if route == "/serial":
            return page("serial", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                if (!navigator.serial) { finish({outcome:'missing'}); return; }
                navigator.serial.requestPort().then(() => finish({outcome:'resolved'})).catch(fail);
              };
            """), html, []
        if route == "/screen":
            return page("screen", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                let settled = false;
                navigator.mediaDevices.getDisplayMedia({video:true}).then(stream => {
                  settled = true;
                  const tracks = stream.getVideoTracks().length;
                  stream.getTracks().forEach(track => track.stop());
                  finish({outcome:'resolved', tracks});
                }).catch(error => { settled = true; fail(error); });
                setTimeout(() => {
                  if (!settled) finish({outcome:'pending'});
                }, 3000);
              };
            """), html, []
        if route == "/payment":
            return page("payment", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                if (!window.PaymentRequest) { finish({outcome:'missing'}); return; }
                const request = new PaymentRequest(
                  [{supportedMethods:'basic-card'}],
                  {total:{label:'Total', amount:{currency:'USD', value:'0.01'}}});
                request.show().then(() => finish({outcome:'resolved'})).catch(fail);
              };
            """), html, []
        if route == "/protocol":
            return page("protocol", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                try {
                  navigator.registerProtocolHandler('web+shaarparity', location.origin + '/handled?u=%s');
                  finish({outcome:'registered'});
                } catch (error) { fail(error); }
              };
            """), html, []
        if route == "/handled":
            return page("handled", "", "finish({outcome:'handled', href:location.href});"), html, []
        if route == "/address":
            return page("address", """
              <form action="/saved" method="post">
                <input name="name" autocomplete="name" value="Parity Probe">
                <input name="street-address" autocomplete="street-address" value="1 Loopback Road">
                <input name="address-level2" autocomplete="address-level2" value="Local">
                <input name="postal-code" autocomplete="postal-code" value="00000">
                <input name="email" autocomplete="email" value="parity@localhost">
                <button id="parity-action" type="submit" style="position:fixed;left:8px;top:8px;width:180px;height:48px">Save address</button>
              </form>
            """, ""), html, []
        if route == "/card":
            return page("card", """
              <form action="/saved" method="post">
                <input name="cc-name" autocomplete="cc-name" value="Parity Probe">
                <input name="cc-number" autocomplete="cc-number" value="4111111111111111">
                <input name="cc-exp" autocomplete="cc-exp" value="12/30">
                <button id="parity-action" type="submit" style="position:fixed;left:8px;top:8px;width:180px;height:48px">Pay</button>
              </form>
            """, ""), html, []
        if route == "/password":
            return page("password", """
              <form action="/saved" method="post">
                <input name="username" autocomplete="username" value="parity-user">
                <input name="password" type="password" autocomplete="current-password" value="parity-secret">
                <button id="parity-action" type="submit" style="position:fixed;left:8px;top:8px;width:180px;height:48px">Sign in</button>
              </form>
            """, ""), html, []
        if route == "/saved":
            return page("saved", "", "finish({outcome:'submitted'});"), html, []
        if route == "/webgpu":
            return page("webgpu", "", """
              if (!navigator.gpu) { finish({outcome:'missing'}); }
              else navigator.gpu.requestAdapter()
                .then(adapter => finish({outcome: adapter ? 'resolved' : 'no-adapter'}))
                .catch(fail);
            """), html, []
        if route == "/webgl":
            return page("webgl", "", """
              const canvas = document.createElement('canvas');
              const gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
              finish(gl
                ? {outcome:'resolved', version:String(gl.getParameter(gl.VERSION)), userAgent:navigator.userAgent}
                : {outcome:'missing', userAgent:navigator.userAgent});
            """), html, []
        if route == "/eme":
            return page("eme", "", """
              async function access(keySystem) {
                if (!navigator.requestMediaKeySystemAccess) return 'missing';
                try {
                  await navigator.requestMediaKeySystemAccess(keySystem, [{
                    initDataTypes:['cenc'],
                    videoCapabilities:[{contentType:'video/mp4; codecs="avc1.42E01E"'}]
                  }]);
                  return 'resolved';
                } catch (error) { return error.name || 'Error'; }
              }
              Promise.all([access('com.widevine.alpha'), access('org.w3.clearkey')])
                .then(([widevine, clearkey]) => finish({outcome:'checked', widevine, clearkey}));
            """), html, []
        if route == "/pip":
            return page("pip", BUTTON, """
              document.getElementById('parity-action').onclick = async () => {
                try {
                  const canvas = Object.assign(document.createElement('canvas'), {width:64, height:64});
                  canvas.getContext('2d').fillRect(0, 0, 64, 64);
                  const video = document.createElement('video');
                  video.playsInline = true;
                  video.srcObject = canvas.captureStream(10);
                  document.body.appendChild(video);
                  await video.play();
                  await video.requestPictureInPicture();
                  finish({outcome:'resolved'});
                } catch (error) { fail(error); }
              };
            """), html, []
        if route == "/media-session":
            return page("media-session", BUTTON, """
              document.getElementById('parity-action').onclick = async () => {
                try {
                  const audio = new Audio('/tone.wav');
                  await audio.play();
                  navigator.mediaSession.metadata = new MediaMetadata({title:'Parity Title', artist:'Probe'});
                  navigator.mediaSession.setActionHandler('play', () => {});
                  navigator.mediaSession.setActionHandler('pause', () => {});
                  finish({outcome:'resolved', title:'Parity Title'});
                } catch (error) { fail(error); }
              };
            """), html, []
        if route == "/popup":
            return page("popup", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                const opened = window.open(location.origin + '/landed', '_blank');
                finish({outcome: opened ? 'opened' : 'blocked'});
              };
            """), html, []
        if route == "/landed":
            return page("landed", '<main id="destination">Opened</main>', "finish({outcome:'landed'});"), html, []
        if route == "/download":
            return page("download", BUTTON, """
              document.getElementById('parity-action').onclick = () => { location.href = '/file.txt'; };
            """), html, []
        if route == "/file.txt":
            return b"parity-note\n", "text/plain; charset=utf-8", [
                ("Content-Disposition", "attachment; filename=parity-note.txt")]
        if route == "/print":
            return page("print", BUTTON, """
              document.getElementById('parity-action').onclick = () => {
                let before = false;
                window.addEventListener('beforeprint', () => { before = true; });
                window.addEventListener('afterprint', () => finish({outcome:'afterprint', before:true}));
                window.print();
                setTimeout(() => {
                  if (!window.parityResult) finish({outcome:'called', before});
                }, 1200);
              };
            """), html, []
        if route == "/page.pdf":
            return pdf(), "application/pdf", []
        if route == "/extensions-page":
            return page("extensions", "", """
              const runtime = typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.id;
              finish({outcome:'observed', extensionRuntime: !!runtime});
            """), html, []
        if route in {"/pwa", "/pwa/"}:
            return page("pwa", '<link rel="manifest" href="/pwa/manifest.webmanifest">' + BUTTON, """
              let fired = false;
              window.addEventListener('beforeinstallprompt', event => {
                fired = true;
                event.preventDefault();
                finish({outcome:'prompt'});
              });
              navigator.serviceWorker.register('/pwa/sw.js').catch(error => { window.parityWorkerError = error.name; });
              document.getElementById('parity-action').onclick = () => {
                setTimeout(() => {
                  if (!fired) finish({outcome:'no-prompt', workerError: window.parityWorkerError || ''});
                }, 5000);
              };
            """), html, []
        if route == "/pwa/sw.js":
            return (
                "self.addEventListener('install', event => { self.skipWaiting(); });"
                "self.addEventListener('activate', event => { event.waitUntil(self.clients.claim()); });"
            ), script, []
        if route == "/pwa/manifest.webmanifest":
            manifest = {
                "name": "Parity Probe", "short_name": "Parity", "start_url": "/pwa/",
                "display": "standalone", "background_color": "#ffffff", "theme_color": "#14599e",
                "icons": [
                    {"src": "/pwa/icon.png", "sizes": "192x192", "type": "image/png"},
                    {"src": "/pwa/icon-512.png", "sizes": "512x512", "type": "image/png"},
                ],
            }
            return json.dumps(manifest), "application/manifest+json", []
        if route == "/pwa/icon.png":
            return png(192, (20, 90, 160)), "image/png", []
        if route == "/pwa/icon-512.png":
            return png(512, (20, 90, 160)), "image/png", []
        if route == "/tone.wav":
            return wav(), "audio/wav", []
        if route == "/partition-a":
            return partition_page(f"{other}/party?mode=write"), html, []
        if route == "/partition-b":
            return partition_page(f"{other}/party?mode=read"), html, []
        if route == "/party":
            mode = (query.get("mode") or ["read"])[0]
            return page("party", "", f"""
              const mode = {json.dumps(mode)};
              let stored = '';
              let storageError = '';
              try {{
                if (mode === 'write') localStorage.setItem('parity-token', 'alpha');
                stored = localStorage.getItem('parity-token') || '';
              }} catch (error) {{ storageError = error.name || 'Error'; }}
              if (mode === 'write') {{
                document.cookie = 'legacy=1; SameSite=None; Secure';
                document.cookie = 'part=1; SameSite=None; Secure; Partitioned';
              }}
              parent.postMessage({{
                parityFrame: {{mode, stored, storageError, cookie: document.cookie}}
              }}, '*');
            """), html, []
        if route == "/loopback":
            peer = json.dumps(getattr(self, "peer", ""))
            return page("loopback", "", f"finish({{outcome:'loopback', peer:{peer}}});"), html, []
        if route == "/plain":
            return page("plain", "plain http", "finish({outcome:'loaded', href:location.href, protocol:location.protocol});"), html, []
        if route == "/bad-cert":
            return page("bad-cert", "bad cert page loaded", "finish({outcome:'loaded', href:location.href});"), html, []
        return None, html, []


def partition_page(frame):
    return page("partition", f'<iframe src="{frame}"></iframe>', """
      window.addEventListener('message', event => {
        if (event.data && event.data.parityFrame) finish(event.data.parityFrame);
      });
    """)


def crash_matches_pids(text, pids):
    """Match a crash report's pid field without treating 12 as 123."""
    return any(
        re.search(rf'"pid"\s*:\s*{int(pid)}\b', text)
        for pid in pids if pid
    )


def crashes_for_pids(before, pids):
    """Crash reports for the probe and any helper PID this run owned."""
    owned = [pid for pid in pids if pid]
    if not owned:
        return []
    deadline = time.monotonic() + 30
    while True:
        found = []
        for name in sorted(crash_names() - before):
            for directory in (CRASHES, CRASHES / "Retired"):
                path = directory / name
                if not path.is_file():
                    continue
                text = path.read_text(errors="replace")[:12000]
                if crash_matches_pids(text, owned):
                    found.append(name)
                    break
        if found or time.monotonic() >= deadline:
            return found
        time.sleep(0.5)


def crash_names():
    names = set()
    for directory in (CRASHES, CRASHES / "Retired"):
        if directory.is_dir():
            names.update(
                path.name for path in directory.iterdir()
                if path.suffix in {".ips", ".crash"}
                and path.name.startswith(("Shaar", "ArcusisBrowser", "Chromium"))
            )
    return names


def serve(address):
    server = ThreadingHTTPServer(address, Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def https_server(cert, key):
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def markdown_table(rows):
    lines = ["| Item | Result | Delegate | Evidence |", "| --- | --- | --- | --- |"]
    for row in rows:
        evidence = str(row.get("evidence", "")).replace("|", "/").replace("\n", " ")
        lines.append(
            f"| {row.get('item', '')} | {row.get('result', '')} | {row.get('delegate', '')} | {evidence} |"
        )
    return "\n".join(lines)


def in_progress_is_stale(path, seconds=90):
    report = read_report(path)
    rows = report.get("rows") or []
    if not any(row.get("result") == "in progress" for row in rows):
        return False
    return time.time() - path.stat().st_mtime > seconds


def parse_group_pids(text, pgid):
    """PIDs whose process-group column is exactly pgid."""
    found = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        pid = int(parts[0])
        if pid <= 1 or int(parts[1]) != pgid or pid in found:
            continue
        found.append(pid)
    return found


def pids_in_group(pgid):
    result = subprocess.run(
        ["ps", "-axo", "pid=,pgid="], capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        return []
    return parse_group_pids(result.stdout, pgid)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def process_group(pid):
    try:
        return os.getpgid(pid)
    except OSError:
        return None


def remember_owned_pids(process, owned):
    """Record the probe PID and helpers while that process still owns the group."""
    if process is None or process.poll() is not None:
        return
    if process_group(process.pid) != process.pid:
        return
    found = []
    for pid in [process.pid, *descendant_pids(process.pid), *pids_in_group(process.pid)]:
        if pid > 1 and pid not in found:
            found.append(pid)
    owned[:] = found


def pids_to_signal(recorded, probe_pid):
    """Exact PIDs that are still the probe or still in its process group.

    A recycled PID has a different group and is left alone. The group id is
    never signaled.
    """
    chosen = []
    for pid in recorded:
        if pid <= 1 or not pid_alive(pid):
            continue
        group = process_group(pid)
        if group is None:
            continue
        if pid == probe_pid or group == probe_pid:
            chosen.append(pid)
    return chosen


def signal_exact_pids(pids):
    """SIGTERM, then SIGKILL, each recorded PID. Returns the PIDs that were signaled."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        pending = [pid for pid in pids if pid_alive(pid)]
        if not pending:
            break
        for pid in pending:
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        time.sleep(0.2 if sig == signal.SIGTERM else 0)
    return pids


def stop_process_group(process, owned):
    """Stop the probe and the helper PIDs recorded for its process group.

    The group is read again here. Helpers can start after the last remember,
    and remember itself does nothing once the leader has already exited.
    """
    if process is None:
        return []
    remember_owned_pids(process, owned)
    for pid in pids_in_group(process.pid):
        if pid > 1 and pid not in owned:
            owned.append(pid)
    victims = pids_to_signal(owned, process.pid)
    if process.poll() is None and process.pid not in victims and pid_alive(process.pid):
        victims.insert(0, process.pid)
    signal_exact_pids(victims)
    if process.poll() is None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.kill(process.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
    return victims


def descendant_pids(pid):
    seen = []
    pending = [pid]
    while pending:
        parent = pending.pop()
        result = subprocess.run(
            ["pgrep", "-P", str(parent)], capture_output=True, text=True)
        for line in result.stdout.split():
            if not line.isdigit():
                continue
            child = int(line)
            if child in seen or child == pid:
                continue
            seen.append(child)
            pending.append(child)
    return seen


def is_trackertest_host(value):
    """True when a Host header names trackertest.org, with or without a port."""
    parsed = urllib.parse.urlparse("//" + str(value or "").strip())
    hostname = (parsed.hostname or "").rstrip(".")
    return hostname == "trackertest.org"


def trackertest_connections():
    with Handler.seen_lock:
        return [
            dict(item) for item in Handler.seen
            if is_trackertest_host(item.get("host", ""))
        ]


def checks_ran(rows):
    """True when a checklist row finished. Setup and Safe Browsing do not count."""
    for row in rows or []:
        item = str(row.get("item", ""))
        if item in {"", "Setup", "Safe Browsing state"}:
            continue
        if row.get("result") == "in progress":
            continue
        return True
    return False


def run_completed(report, crashes, exit_code=0):
    """A setup failure can write rows and still leave the checklist unrun.

    A timed-out or crashed process is not a finished run, even when rows exist.
    """
    return (
        report.get("completed") is True
        and report.get("allWindowsHidden") is True
        and not crashes
        and checks_ran(report.get("rows"))
        and exit_code == 0
    )


def read_report(path):
    if not path.is_file():
        return {}
    raw = path.read_text()
    try:
        loaded = json.loads(raw)
    except json.JSONDecodeError:
        return {"completed": False, "rows": [], "parseError": raw[:500]}
    return loaded if isinstance(loaded, dict) else {}


def tail(value):
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    return str(value or "")[-4000:]


def check_fixtures(http_base, https_base):
    import urllib.request

    def fetch(url):
        return urllib.request.urlopen(url, timeout=5)

    ready = fetch(http_base + "/ready").read()
    if b"outcome:'ready'" not in ready:
        raise SystemExit("ready fixture missing")
    document = fetch(http_base + "/page.pdf").read()
    if b"Parity PDF" not in document or not document.startswith(b"%PDF-"):
        raise SystemExit("pdf fixture missing text")
    tone = fetch(http_base + "/tone.wav").read()
    if not tone.startswith(b"RIFF"):
        raise SystemExit("wav fixture missing")
    icon = fetch(http_base + "/pwa/icon.png").read()
    large = fetch(http_base + "/pwa/icon-512.png").read()
    if not icon.startswith(b"\x89PNG") or not large.startswith(b"\x89PNG"):
        raise SystemExit("png fixture missing")
    pwa = fetch(http_base + "/pwa/").read()
    if b"/pwa/sw.js" not in pwa:
        raise SystemExit("pwa fixture missing worker")
    if b"submitted" not in fetch(http_base + "/saved").read():
        raise SystemExit("saved fixture missing")
    partition = fetch(http_base + "/partition-a").read()
    if b"http://localhost:" not in partition:
        raise SystemExit("partition fixture missing iframe")
    party = fetch(http_base.replace("127.0.0.1", "localhost") + "/party?mode=write").read()
    if b"parity-token" not in party:
        raise SystemExit("partition fixture missing")
    insecure = ssl._create_unverified_context()
    bad = urllib.request.urlopen(https_base + "/bad-cert", timeout=5, context=insecure).read()
    if b"bad cert page loaded" not in bad:
        raise SystemExit("https fixture missing")
    loopback = fetch(http_base + "/loopback").read()
    if b"127.0.0.1" not in loopback:
        raise SystemExit("loopback fixture missing peer")
    print(f"fixtures ok {http_base} {https_base}")


def receipt_output_path(value: str) -> Path:
    path = Path(value)
    if path.is_symlink():
        raise argparse.ArgumentTypeError(f"receipt output must not be a symlink: {path}")
    if path.parent.is_symlink():
        raise argparse.ArgumentTypeError(f"receipt output parent must not be a symlink: {path.parent}")
    return path


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    parser.add_argument("--receipt", type=receipt_output_path,
                        default=ROOT / "build/platform-parity/receipt.json")
    parser.add_argument("--fixtures-only", action="store_true")
    return parser


def main():
    options = argument_parser().parse_args()
    executable = options.app / "Contents/MacOS/ShaarVerification"
    if not options.fixtures_only and not executable.is_file():
        parser.error(f"Missing verification app: {executable}")
    before = crash_names()
    root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
    report_path = root / "report.json"
    report = {}
    stderr = ""
    exit_code = 1
    probe_pid = None
    process = None
    owned_pids = []
    http = https = None
    with Handler.seen_lock:
        Handler.seen.clear()
    try:
        try:
            cert = root / "cert.pem"
            key = root / "key.pem"
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
                 "-out", str(cert), "-days", "1", "-subj", "/CN=untrusted.invalid"],
                check=True, capture_output=True)
            http = serve(("127.0.0.1", 0))
            port = http.server_address[1]
            https = https_server(cert, key)
            http_base = f"http://127.0.0.1:{port}"
            https_base = f"https://127.0.0.1:{https.server_address[1]}"
            if options.fixtures_only:
                check_fixtures(http_base, https_base)
                return
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            home = root / "home"
            home.mkdir()
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            environment["SHAAR_ENGINE_TESTING"] = "1"
            environment["SHAAR_MOCK_KEYCHAIN"] = "1"
            err_path = root / "stderr.txt"
            err_file = err_path.open("w")
            process = subprocess.Popen(
                [str(executable), "--platform-parity-probe", str(report_path), http_base, https_base],
                env=environment, stdout=subprocess.DEVNULL, stderr=err_file, start_new_session=True)
            probe_pid = process.pid
            deadline = time.monotonic() + 600
            while process.poll() is None:
                remember_owned_pids(process, owned_pids)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    exit_code = 124
                    break
                try:
                    exit_code = process.wait(timeout=min(15, remaining))
                    break
                except subprocess.TimeoutExpired:
                    if report_path.is_file() and in_progress_is_stale(report_path):
                        exit_code = 124
                        break
            stop_process_group(process, owned_pids)
            err_file.close()
            stderr = tail(err_path.read_text(errors="replace")) if err_path.is_file() else ""
            report = read_report(report_path)
        except Exception as error:
            stderr = tail(f"{stderr}\n{error}")
            report = read_report(report_path)
    finally:
        stop_process_group(process, owned_pids)
        for server in (http, https):
            if server is not None:
                server.shutdown()
        shutil.rmtree(root, ignore_errors=True)
    watched = list(owned_pids)
    if probe_pid and probe_pid not in watched:
        watched.append(probe_pid)
    crashes = crashes_for_pids(before, watched)
    pin_path = options.app / "Contents/Resources/ChromiumEngine/pin.json"
    pin = json.loads(pin_path.read_text()) if pin_path.is_file() else {}
    rows = list(report.get("rows", []))
    completed = run_completed(report, crashes, exit_code)
    receipt = {
        "verificationExecutable": str(executable),
        "engineRelease": pin.get("releaseTag", ""),
        "exitCode": exit_code,
        "allWindowsHidden": report.get("allWindowsHidden"),
        "completed": completed,
        "userAgent": report.get("userAgent", ""),
        "preferences": report.get("preferences", {}),
        "guard": report.get("guard", []),
        "trackertestConnections": trackertest_connections(),
        "rows": rows,
        "crashReports": crashes,
        "stderr": stderr if not completed else "",
    }
    options.receipt.parent.mkdir(parents=True, exist_ok=True)
    options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(markdown_table(rows))
    print(json.dumps({key: receipt[key] for key in (
        "engineRelease", "exitCode", "allWindowsHidden", "completed", "userAgent",
        "preferences", "crashReports")}, indent=2))
    if not completed:
        if stderr:
            print(stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
