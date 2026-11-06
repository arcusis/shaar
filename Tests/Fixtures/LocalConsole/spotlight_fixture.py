# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Loopback-only Spotlight SSE fixture for Shaar Console tests."""

import http.server
import json
import signal
import sys
import time
import urllib.parse


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if urllib.parse.urlparse(self.path).path != "/stream":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        envelope = [
            {"__spotlight_envelope_id": "fixture-1", "sent_at": "2026-11-06T00:00:00Z"},
            [
                [{"type": "log"}, {"type": "log", "items": [
                    {"body": "worker ready", "severity_number": 9}
                ]}],
                [{"type": "event"}, {"type": "error", "exception": {
                    "values": [{"type": "Error", "value": "Query failed"}]
                }}],
            ],
        ]
        message = (
            "id: fixture-1\n"
            "event: application/x-sentry-envelope\n"
            f"data: {json.dumps(envelope)}\n\n"
        )
        self.wfile.write(message.encode())
        self.wfile.flush()
        time.sleep(30)

    def log_message(self, format, *args):
        pass


signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
