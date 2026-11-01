# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Owned loopback server for the headless picker contract suite."""

from pathlib import Path
import http.server
import json
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from engine_fixture import Fixture
import developer_fixture_assets

developer_fixture_assets.ensure_assets()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
print(json.dumps({'url': f'http://developer.localhost:{server.server_port}'}), flush=True)
server.serve_forever()
