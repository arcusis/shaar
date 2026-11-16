#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Capture real public pages with the hidden engine harness, then optimize website PNGs.

Build: bash scripts/bundle-app.sh --with-engine --verification
Run: .venv/bin/python scripts/capture-marketing-screenshots.py
Dependencies: .venv/bin/python -m pip install Pillow==13.0.0 imagequant==1.1.5
No desktop capture or window activation is used.
"""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import imagequant
from PIL import Image, ImageChops, ImageStat

from engine_fixture import require_verification_bundle_identity


def main():
    repo = Path(__file__).resolve().parent.parent
    os.chdir(repo)
    app = repo / 'build/Shaar Verification.app'
    require_verification_bundle_identity(app)
    output = repo / 'website/screens'
    # mkdtemp creates an owned mode-0700 root. Never accept a caller-supplied profile.
    with tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-marketing-') as temporary:
        root = Path(temporary)
        (root / '.arcusis-probe').write_text('arcusis-engine-probe-v1\n')
        (root / '.arcusis-probe').chmod(0o600)
        with (root / 'capture.log').open('w') as log:
            process = subprocess.Popen([
                str(app / 'Contents/MacOS/ShaarVerification'),
                '--marketing-screenshots', '--probe-data-dir', str(root),
            ], stdout=log, stderr=subprocess.STDOUT)
            print(f'Owned offscreen verification PID: {process.pid}', flush=True)
            try:
                status = process.wait(timeout=650)
            except subprocess.TimeoutExpired:
                print(f'Terminating owned PID: {process.pid}', flush=True)
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    print(f'Killing owned PID: {process.pid}', flush=True)
                    process.kill()
                    process.wait()
                raise RuntimeError('Offscreen capture timed out') from None
        print((root / 'capture.log').read_text())
        if status != 0:
            debug = repo / 'build/marketing-capture-failed'
            debug.mkdir(parents=True, exist_ok=True)
            for source in root.glob('*.png'):
                shutil.copyfile(source, debug / source.name)
            shutil.copyfile(root / 'capture.log', debug / 'capture.log')
            raise RuntimeError(f'Offscreen capture failed: exit {status}')
        import_rtl_capture(app, root)
        import_https_capture(app, root)
        import_save_prompt_captures(repo, app, root)
        publish(root, output)


def import_rtl_capture(app, root):
    """Launch a fresh hidden host with Hebrew selected before AppKit starts."""
    with tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-marketing-he-') as temporary:
        rtl_root = Path(temporary)
        (rtl_root / '.arcusis-probe').write_text('arcusis-engine-probe-v1\n')
        (rtl_root / '.arcusis-probe').chmod(0o600)
        command = [str(app / 'Contents/MacOS/ShaarVerification'),
                   '-BrowserLanguage.selection', 'he',
                   '--marketing-screenshots', '--marketing-rtl',
                   '--probe-data-dir', str(rtl_root)]
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=180, check=False)
        if result.returncode:
            raise RuntimeError('Hidden Hebrew capture failed: '
                               + result.stdout[-2000:] + result.stderr[-2000:])
        rtl = json.loads((rtl_root / 'manifest.json').read_text())
        entries = rtl['images']
        if len(entries) != 1 or entries[0]['file'] != 'hebrew-window.png':
            raise RuntimeError('Hebrew capture did not produce one RTL window')
        shutil.copyfile(rtl_root / 'hebrew-window.png', root / 'hebrew-window.png')
        manifest_path = root / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        if rtl['engineVersion'] != manifest['engineVersion']:
            raise RuntimeError('Hebrew capture used a different engine version')
        manifest['images'].extend(entries)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')


def import_https_capture(app, root):
    """Capture the production HTTPS-first interstitial over a local plain HTTP fixture."""
    class Fixture(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<title>Plain HTTP</title><body>plain-http-loaded</body>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    with ThreadingHTTPServer(('127.0.0.1', 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-marketing-https-') as temporary:
                https_root = Path(temporary)
                (https_root / '.arcusis-probe').write_text('arcusis-engine-probe-v1\n')
                (https_root / '.arcusis-probe').chmod(0o600)
                url = f'http://trackertest.org:{server.server_port}/plain'
                command = [str(app / 'Contents/MacOS/ShaarVerification'),
                           '--marketing-screenshots', '--marketing-https-url', url,
                           '--probe-data-dir', str(https_root)]
                result = subprocess.run(command, capture_output=True, text=True,
                                        timeout=180, check=False)
                if result.returncode:
                    raise RuntimeError('Hidden HTTPS warning capture failed: '
                                       + result.stdout[-2000:] + result.stderr[-2000:])
                extra = json.loads((https_root / 'manifest.json').read_text())
                if len(extra['images']) != 1 or extra['images'][0]['file'] != 'https-first-warning.png':
                    raise RuntimeError('HTTPS warning capture did not produce one image')
                shutil.copyfile(https_root / 'https-first-warning.png', root / 'https-first-warning.png')
                manifest_path = root / 'manifest.json'
                manifest = json.loads(manifest_path.read_text())
                if extra['engineVersion'] != manifest['engineVersion']:
                    raise RuntimeError('HTTPS warning capture used a different engine version')
                manifest['images'].extend(extra['images'])
                manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        finally:
            server.shutdown()


def import_save_prompt_captures(repo, app, root):
    """Use the live hidden save-prompt probe for password, card and address."""
    receipt = repo / 'build/marketing-save-prompts/receipt.json'
    command = [str(Path.home() / 'bin/shaar-heavy'), sys.executable,
               str(repo / 'scripts/test-shaar-save-prompt.py'),
               '--app', str(app), '--receipt', str(receipt), '--locale', 'en']
    result = subprocess.run(command, cwd=repo, capture_output=True, text=True,
                            timeout=240, check=False)
    if result.returncode != 0:
        raise RuntimeError('Hidden save-prompt probe failed: ' + result.stdout[-2000:]
                           + result.stderr[-2000:])
    proof = json.loads(receipt.read_text())
    if proof.get('passed') is not True or proof.get('crashReports'):
        raise RuntimeError('Hidden save-prompt probe did not pass')
    manifest_path = root / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    for kind in ('password', 'card', 'address'):
        source = receipt.parent / 'screenshots/en' / f'save-prompt-{kind}-save.png'
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f'Missing live {kind} save-prompt screenshot')
        filename = f'save-{kind}.png'
        with Image.open(source) as image:
            width, height = image.size
            if width % 2 or height % 2 or width < 200 or height < 100:
                raise RuntimeError(f'Invalid 2x live {kind} save-prompt dimensions')
        shutil.copyfile(source, root / filename)
        manifest['images'].append({
            'file': filename, 'description': f'Live {kind} save prompt in the hidden production host.',
            'windowSize': {'width': width // 2, 'height': height // 2, 'unit': 'points'},
            'pixelSize': {'width': width, 'height': height}, 'scale': 2,
            'appearance': 'light', 'engineVersion': manifest['engineVersion'],
            'captureMethod': 'live save-prompt probe in an offscreen 2x AppKit panel',
        })
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')


def encode_png(image):
    buffer = io.BytesIO()
    image.save(buffer, format='PNG', optimize=True)
    return buffer.getvalue()


def optimize_png(image):
    data = encode_png(image)
    if len(data) <= 900_000:
        return data, 'Pillow lossless PNG optimization', 0
    original = image.convert('RGBA')
    # Perceptual palette selection preserves dark gradients better than RGB rounding.
    # Every candidate must stay below 3/255 RMS error in every channel, without resizing.
    for colors in (256, 128, 96, 80, 64):
        candidate = imagequant.quantize_pil_image(
            original, dithering_level=0, max_colors=colors)
        error = max(ImageStat.Stat(
            ImageChops.difference(original, candidate.convert('RGBA'))).rms)
        if error <= 3:
            data = encode_png(candidate)
            if len(data) <= 900_000:
                return data, f'libimagequant {colors}-color palette, no resizing', error
    raise RuntimeError('PNG exceeds 900 KB within the near-lossless error budget')


def optimize_webp(image):
    """Keep a smaller, lossless delivery copy at the original pixel dimensions."""
    buffer = io.BytesIO()
    image.save(buffer, format='WEBP', lossless=True, method=6)
    return buffer.getvalue()


def publish(root, output):
    required = {
        'hero.png', 'spaces.png', 'command-t.png', 'site-controls.png', 'profiles.png',
        'extensions.png', 'page-arcusis.png', 'page-hasbara.png', 'page-freightfte.png',
        'page-github.png', 'web-store-bitwarden-consent.png',
        'downloads-light.png', 'downloads-dark.png',
        'private-window-light.png', 'private-window-dark.png',
        'javascript-dialog.png', 'basic-auth.png',
        'permission-camera-mic-location.png', 'protocol-handler.png',
        'device-chooser-bluetooth.png', 'device-chooser-serial.png',
        'media-controls-light.png', 'media-controls-dark.png',
        'picture-in-picture.png', 'sleeping-tabs-settings.png',
        'save-password.png', 'save-card.png', 'save-address.png',
        'hebrew-window.png',
        'https-first-warning.png', 'stop-loading.png',
    }
    manifest = json.loads((root / 'manifest.json').read_text())
    manifest['skipped'].append({
        'file': 'developer-tools-f12.png',
        'reason': ('The pinned engine exposes the hidden F12 dock as a remote Chromium surface; '
                   'AppKit bitmap capture does not paint its panels and shaar.48 has no '
                   'DevTools-frontend capture probe.'),
    })
    pin = json.loads((output.parents[1] / 'ThirdParty/ChromiumEngine/pin.json').read_text())
    release = pin['releaseTag']
    if not release.startswith(f"engine-{manifest['engineVersion']}-shaar."):
        raise RuntimeError('Bundled Chromium version does not match the production engine pin')
    manifest['engineReleaseTag'] = release
    manifest['engineArchiveSHA256'] = pin['sha256']
    files = {entry['file'] for entry in manifest['images']}
    if files != required:
        raise RuntimeError(f'Missing or unexpected capture files: {files}')
    optimized = {}
    for entry in manifest['images']:
        entry['engineReleaseTag'] = release
        filename = entry['file']
        with Image.open(root / filename) as image:
            expected = (entry['pixelSize']['width'], entry['pixelSize']['height'])
            if image.size != expected or entry['scale'] != 2:
                raise RuntimeError(f'Invalid Retina dimensions: {filename}')
            if filename in ('extensions.png', 'stop-loading.png') \
                    and ImageStat.Stat(image.convert('L')).mean[0] < 100:
                raise RuntimeError(f'{filename} has an unpainted page viewport')
            if filename == 'private-window-dark.png':
                width, height = image.size
                body = image.convert('RGB').crop((int(.32 * width), int(.17 * height),
                                                   int(.85 * width), int(.85 * height)))
                ink = sum(1 for r, g, b in body.get_flattened_data()
                          if min(r, g, b) < 180) / (body.width * body.height)
                if ink < 0.01:
                    raise RuntimeError('Dark private window has an unpainted start page')
            if filename.startswith('page-') and (image.size != (2880, 1800)
                    or entry['document']['width'] != 1440
                    or entry['document']['height'] != 900):
                raise RuntimeError(f'Invalid page-only viewport: {filename}')
            data, optimization, error = optimize_png(image)
            entry['optimization'] = optimization
            entry['maxChannelRMSE'] = round(error, 4)
            entry['bytes'] = len(data)
            entry['sha256'] = hashlib.sha256(data).hexdigest()
            optimized[filename] = data
            with Image.open(io.BytesIO(data)) as optimized_image:
                webp = optimize_webp(optimized_image)
            webp_name = Path(filename).with_suffix('.webp').name
            entry['webp'] = {
                'file': webp_name, 'bytes': len(webp),
                'sha256': hashlib.sha256(webp).hexdigest(),
                'optimization': 'Pillow lossless WebP, method 6, no resizing',
                'pixelSize': entry['pixelSize'],
            }
            optimized[webp_name] = webp
    # Publish only after every mandatory capture passes.
    output.mkdir(parents=True, exist_ok=True)
    for filename, data in optimized.items():
        (output / filename).write_bytes(data)
        print(f'{filename}: {len(data):,} bytes')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    for skipped in manifest['skipped']:
        print(f"Skipped {skipped['file']}: {skipped['reason']}")


if __name__ == '__main__':
    main()
