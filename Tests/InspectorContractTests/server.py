# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import http.server
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.engine_fixture import Fixture

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
print(json.dumps({'url': f'http://inspector.localhost:{server.server_port}/inspector'}), flush=True)
server.serve_forever()
