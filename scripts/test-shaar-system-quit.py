#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Assert embedded Chromium exits after a system Quit, including after DevTools."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urlsplit


def run_case(app: Path, fixture_url: str | None, inspector: bool) -> dict:
    with tempfile.TemporaryDirectory(prefix="shaar-system-quit-") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        data = root / "arcusis-engine-probe-system-quit"
        data.mkdir()
        data.chmod(0o700)
        marker = data / ".arcusis-probe"
        marker.write_text("arcusis-engine-probe-v1\n")
        marker.chmod(0o600)
        report = root / "report.json"
        framework = app / "Contents/Frameworks/Chromium Framework.framework"
        command = [
            str(app / "Contents/MacOS/ShaarVerification"),
            "--probe-shaar-first-tab",
            "--probe-system-quit",
            "--probe-framework", str(framework),
            "--probe-output", str(report),
            "--probe-data-dir", str(data),
        ]
        if inspector:
            command.extend([
                "--probe-shaar-inspector", "--probe-shaar-devtools-dock",
                "--probe-inspector-url", fixture_url,
            ])
        environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                           SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root))
        try:
            process = subprocess.run(command, env=environment, capture_output=True,
                                     text=True, timeout=65, check=False)
        except subprocess.TimeoutExpired as error:
            raise AssertionError("Shaar did not exit after system Quit") from error
        if process.returncode != 0 or not report.exists():
            raise AssertionError(
                f"system Quit exit={process.returncode}; output={process.stdout[-1000:]}"
                f"{process.stderr[-2500:]} report={report.read_text() if report.exists() else 'missing'}")
        result = json.loads(report.read_text())
        assert result["passed"] and result["systemQuitRequested"]
        assert result["allWindowsHidden"]
        if inspector:
            checks = result["inspectorChecks"]
            assert "normalDock.closeRestoresFullPage" in checks
            assert "privateDock.closeRestoresFullPage" in checks
        return {"inspector": inspector, "exitCode": process.returncode,
                "passed": result["passed"], "checks": result["inspectorChecks"]}


def verification_app(value: str) -> Path:
    app = Path(value)
    if not app.is_dir():
        raise argparse.ArgumentTypeError(f"verification app directory does not exist: {app}")
    return app


def loopback_fixture_url(value: str) -> str:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "fixture URL must use http://127.0.0.1:<port>") from error
    if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not port
            or parsed.username is not None or parsed.password is not None):
        raise argparse.ArgumentTypeError("fixture URL must use http://127.0.0.1:<port>")
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=verification_app, required=True)
    parser.add_argument("--fixture-url", type=loopback_fixture_url, required=True)
    options = parser.parse_args()
    results = [run_case(options.app, options.fixture_url, False),
               run_case(options.app, options.fixture_url, True)]
    print(json.dumps({"cases": results, "passed": len(results)}, indent=2))


if __name__ == "__main__":
    main()
