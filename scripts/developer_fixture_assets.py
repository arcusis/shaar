#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fetch integrity-pinned, test-only React/Vue assets without extracting archive paths."""

import base64
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'Tests/Fixtures/DeveloperPages/frameworks.json'
CACHE = ROOT / 'build/DeveloperFixtureCache'


def ensure_assets(cache=CACHE, manifest=MANIFEST):
    cache.mkdir(parents=True, exist_ok=True)
    for item in json.loads(manifest.read_text()):
        name = item['name']
        if name not in ('react', 'react-dom', 'vue'):
            raise RuntimeError('Unexpected developer fixture package')
        script = cache / (name + '.js')
        notice = cache / (name + '.LICENSE')
        if script.exists() or notice.exists():
            if (not script.is_file() or not notice.is_file()
                    or hashlib.sha256(script.read_bytes()).hexdigest() != item['sha256']
                    or hashlib.sha256(notice.read_bytes()).hexdigest() != item['licenseSHA256']):
                raise RuntimeError(f'Cached developer fixture differs from its pin: {name}')
            continue
        with urllib.request.urlopen(item['url'], timeout=30) as response:
            archive = response.read(8 * 1024 * 1024 + 1)
        integrity = 'sha512-' + base64.b64encode(hashlib.sha512(archive).digest()).decode()
        if len(archive) > 8 * 1024 * 1024 or integrity != item['integrity']:
            raise RuntimeError(f'Developer fixture archive integrity mismatch: {name}')
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as bundle:
            member = bundle.getmember(item['member'])
            license_member = bundle.getmember('package/LICENSE')
            if not member.isfile() or not license_member.isfile():
                raise RuntimeError('Developer fixture members must be regular files')
            body = bundle.extractfile(member).read(4 * 1024 * 1024 + 1)
            license_text = bundle.extractfile(license_member).read(64 * 1024 + 1)
        if (hashlib.sha256(body).hexdigest() != item['sha256']
                or hashlib.sha256(license_text).hexdigest() != item['licenseSHA256']):
            raise RuntimeError(f'Developer fixture payload integrity mismatch: {name}')
        script.write_bytes(body)
        notice.write_bytes(license_text)
    return cache
