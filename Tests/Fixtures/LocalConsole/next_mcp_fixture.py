# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Loopback-only Next MCP fixture for Shaar Console tests."""

import http.server
import json
import os
import signal
import sys
import tempfile


root = tempfile.TemporaryDirectory(prefix="shaar-next-mcp-")
log_path = os.path.join(root.name, ".next", "logs", "next-development.log")
os.makedirs(os.path.dirname(log_path))
with open(log_path, "w", encoding="utf-8") as log:
    log.write("ready on 3000\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/_next/mcp":
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        name = request.get("params", {}).get("name")
        values = {
            "get_project_metadata": json.dumps({"projectPath": root.name}),
            "get_logs": json.dumps({"logFilePath": log_path}),
            "get_errors": json.dumps([{"message": "Build failed"}]),
        }
        if name not in values:
            self.send_error(404)
            return
        response = json.dumps({
            "jsonrpc": "2.0", "id": request["id"],
            "result": {"content": [{"type": "text", "text": values[name]}]},
        })
        if name == "get_errors":
            response = f"event: message\ndata: {response}\n\n"
            content_type = "text/event-stream"
        else:
            content_type = "application/json"
        response = response.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format, *args):
        pass


signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
try:
    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
finally:
    root.cleanup()
