#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run the hidden DevTools-owned tab route against the locally staged Shaar engine."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from urllib.request import Request, urlopen

from engine_fixture import Fixture

NEXT_DEV_SERVER = (
    Path(__file__).resolve().parents[1] / "Tests/Fixtures/NodeInspector/next-dev-server.js"
)
NODE_TARGET_NAME = "next-dev-server.js"


def drain(stream, lines, lock):
    for line in stream:
        with lock:
            lines.append(line)


def wait_for(lines, lock, pattern, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with lock:
            snapshot = list(lines)
        for line in snapshot:
            match = pattern.search(line)
            if match:
                return match
        time.sleep(0.05)
    return None


def published_node_target(port):
    with urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as response:
        targets = json.load(response)
    for target in targets:
        title = target.get("title", "")
        frontend = target.get("devtoolsFrontendUrl", "")
        if (target.get("type") == "node" and NODE_TARGET_NAME in title
                and "js_app.html" in frontend and "v8only=true" in frontend):
            return target
    raise RuntimeError("Node inspector did not publish the Next.js-style target")


def attach_frontend_url(app_port):
    request = Request(
        f"http://127.0.0.1:{app_port}/__nextjs_attach-nodejs-inspector",
        data=b"", method="POST")
    with urlopen(request, timeout=5) as response:
        return json.load(response)


@contextmanager
def node_inspector():
    if not NEXT_DEV_SERVER.is_file():
        raise RuntimeError(f"Missing committed Next.js fixture: {NEXT_DEV_SERVER}")
    process = subprocess.Popen(
        ["node", "--inspect=127.0.0.1:0", str(NEXT_DEV_SERVER)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    stdout_lines, stderr_lines = [], []
    output_lock = threading.Lock()
    threading.Thread(
        target=drain, args=(process.stdout, stdout_lines, output_lock), daemon=True).start()
    threading.Thread(
        target=drain, args=(process.stderr, stderr_lines, output_lock), daemon=True).start()
    try:
        inspector = wait_for(
            stderr_lines, output_lock, re.compile(r"ws://127\.0\.0\.1:(\d+)/"), 10)
        ready = wait_for(
            stdout_lines, output_lock,
            re.compile(r"ready - started server on 127\.0\.0\.1:(\d+)"), 10)
        if not inspector or not ready:
            with output_lock:
                detail = "".join(stderr_lines + stdout_lines).strip()
            raise RuntimeError(f"Next.js-style inspector did not start: {detail}")
        port = int(inspector.group(1))
        target = published_node_target(port)
        attached = attach_frontend_url(int(ready.group(1)))
        if attached != target["devtoolsFrontendUrl"]:
            raise RuntimeError("Attach route did not return the live DevTools frontend URL")
        yield {"port": port, "target": target}
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()


def verification_app_path(value: str) -> Path:
    app = Path(value)
    executable = app / "Contents/MacOS/ShaarVerification"
    if not app.is_dir() or not executable.is_file():
        raise argparse.ArgumentTypeError(
            f"verification app is missing or incomplete: {app}")
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=verification_app_path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--with-node-inspector", action="store_true")
    options = parser.parse_args()
    app = options.app.resolve()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory(
            prefix="arcusis-engine-probe-", ignore_cleanup_errors=True
        ) as temporary:
            root = Path(temporary)
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            (root / "home").mkdir()
            report = root / "initial.json"
            fixture = f"http://127.0.0.1:{server.server_port}/account"
            executable = app / "Contents/MacOS/ShaarVerification"
            command = [str(executable), "--probe-data-dir", str(root),
                       "--probe-url", fixture, "--probe-phase", "initial",
                       "--probe-output", str(report), "--probe-devtools-route-only"]
            environment = dict(os.environ, HOME=str(root / "home"),
                               CFFIXED_USER_HOME=str(root / "home"),
                               SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root))
            def run_probe():
                try:
                    return subprocess.run(command, env=environment, capture_output=True,
                                          text=True, timeout=180, check=False)
                except subprocess.TimeoutExpired as error:
                    options.receipt.write_text(json.dumps({"timeout": True,
                                                           "stderr": str(error)}) + "\n")
                    raise

            node_target = None
            if options.with_node_inspector:
                with node_inspector() as started:
                    node_target = started["target"]
                    environment["SHAAR_NODE_INSPECTOR_PORT"] = str(started["port"])
                    process = run_probe()
            else:
                process = run_probe()
            evidence = json.loads(report.read_text()) if report.exists() else None
            detail_path = root / "initial-devtools-route.json"
            detail = json.loads(detail_path.read_text()) if detail_path.exists() else None
            receipt = {"exitCode": process.returncode, "report": evidence,
                       "devToolsRoute": detail, "nodeTarget": node_target,
                       "stderrTail": process.stderr[-4000:]}
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps({"exitCode": process.returncode,
                              "passed": evidence.get("passed") if evidence else False,
                              "error": evidence.get("error") if evidence else "missing report"},
                             indent=2))
            if process.returncode or not evidence or not evidence.get("passed"):
                raise SystemExit(1)
        server.shutdown()


if __name__ == "__main__":
    main()
