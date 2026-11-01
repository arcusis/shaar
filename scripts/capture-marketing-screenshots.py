#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Capture real public pages with the hidden engine harness, then optimize website PNGs.

Build: bash scripts/bundle-app.sh --with-engine --verification
Run: .venv/bin/python scripts/capture-marketing-screenshots.py
Requires Pillow in the local .venv. No desktop capture or window activation is used.
"""

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image

from engine_fixture import require_verification_bundle_identity


def main():
    repo = Path(__file__).resolve().parent.parent
    os.chdir(repo)
    app = repo / 'build/Shaar Verification.app'
    require_verification_bundle_identity(app)
    output = repo / 'website/public-screens'
    required = {'hero.png', 'spaces.png', 'command-t.png', 'site-controls.png', 'profiles.png'}
    allowed = required | {'extensions.png', 'mini-player.png'}
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
        manifest = json.loads((root / 'manifest.json').read_text())
        files = {entry['file'] for entry in manifest['images']}
        if not required <= files or not files <= allowed:
            raise RuntimeError(f'Missing or unexpected capture files: {files}')
        optimized = {}
        for entry in manifest['images']:
            filename = entry['file']
            with Image.open(root / filename) as image:
                expected = (entry['pixelSize']['width'], entry['pixelSize']['height'])
                if image.size != expected or entry['scale'] != 2:
                    raise RuntimeError(f'Invalid Retina dimensions: {filename}')
                # Preserve all pixels unless the lossless encode exceeds the website budget.
                buffer = io.BytesIO()
                image.save(buffer, format='PNG', optimize=True)
                data = buffer.getvalue()
                entry['optimization'] = 'Pillow lossless PNG optimization'
                if len(data) > 900_000:
                    buffer = io.BytesIO()
                    image.convert('RGB').quantize(colors=256, dither=Image.Dither.NONE).save(
                        buffer, format='PNG', optimize=True)
                    data = buffer.getvalue()
                    entry['optimization'] = 'Pillow 256-color quantization, no resizing'
                if len(data) > 900_000:
                    raise RuntimeError(f'{filename} exceeds 900 KB after optimization')
                entry['bytes'] = len(data)
                entry['sha256'] = hashlib.sha256(data).hexdigest()
                optimized[filename] = data
        # Publish only after every mandatory capture passes; remove stale optional images.
        output.mkdir(parents=True, exist_ok=True)
        for filename in allowed - files:
            (output / filename).unlink(missing_ok=True)
        for filename, data in optimized.items():
            (output / filename).write_bytes(data)
            print(f'{filename}: {len(data):,} bytes')
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        for skipped in manifest['skipped']:
            print(f"Skipped {skipped['file']}: {skipped['reason']}")


if __name__ == '__main__':
    main()
