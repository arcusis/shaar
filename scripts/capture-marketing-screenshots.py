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
import subprocess
import tempfile

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
            raise RuntimeError(f'Offscreen capture failed: exit {status}')
        publish(root, output)


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


def publish(root, output):
    required = {
        'hero.png', 'spaces.png', 'command-t.png', 'site-controls.png', 'profiles.png',
        'extensions.png', 'page-arcusis.png', 'page-hasbara.png', 'page-freightfte.png',
        'page-github.png',
    }
    manifest = json.loads((root / 'manifest.json').read_text())
    files = {entry['file'] for entry in manifest['images']}
    if files != required:
        raise RuntimeError(f'Missing or unexpected capture files: {files}')
    optimized = {}
    for entry in manifest['images']:
        filename = entry['file']
        with Image.open(root / filename) as image:
            expected = (entry['pixelSize']['width'], entry['pixelSize']['height'])
            if image.size != expected or entry['scale'] != 2:
                raise RuntimeError(f'Invalid Retina dimensions: {filename}')
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
