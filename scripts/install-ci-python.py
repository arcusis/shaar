#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Install a pinned uv-managed Python, retrying transient release failures."""

import argparse
import re
import subprocess
import sys
import time
from typing import Callable


INSTALL_ATTEMPTS = 3
INSTALL_TIMEOUT_SECONDS = 180
BACKOFF_SECONDS = (5, 15)
RETRYABLE_MESSAGES = (
    "http status client error (408",
    "http status client error (429",
    "http status server error (500",
    "http status server error (502",
    "http status server error (503",
    "http status server error (504",
    "client error (connect)",
    "operation timed out",
    "connection timed out",
    "connection reset",
    "temporarily unavailable",
    "unexpected eof",
    "dns error",
)
PYTHON_VERSION = re.compile(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?\Z")


def parse_python_version(value: str) -> str:
    if not PYTHON_VERSION.fullmatch(value):
        raise argparse.ArgumentTypeError("expected a pinned Python version like 3.13 or 3.13.2")
    return value


def failure_text(result) -> str:
    return "\n".join(part for part in (result.stdout, result.stderr) if part).lower()


def is_retryable_failure(result) -> bool:
    output = failure_text(result)
    return any(message in output for message in RETRYABLE_MESSAGES)


def write_output(result) -> None:
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)


def install_python(
    version: str,
    run: Callable = subprocess.run,
    sleep: Callable[[int], None] = time.sleep,
) -> int:
    command = ["uv", "python", "install", version]
    for attempt in range(1, INSTALL_ATTEMPTS + 1):
        try:
            result = run(command, capture_output=True, text=True, check=False,
                         timeout=INSTALL_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or ""
            stderr = error.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", errors="replace")
            message = f"uv Python install operation timed out after {INSTALL_TIMEOUT_SECONDS}s"
            result = subprocess.CompletedProcess(
                command, 124, stdout, "\n".join(part for part in (stderr, message) if part))
        if result.returncode == 0:
            write_output(result)
            return 0

        if not is_retryable_failure(result) or attempt == INSTALL_ATTEMPTS:
            write_output(result)
            return result.returncode

        delay = BACKOFF_SECONDS[attempt - 1]
        print(
            f"Transient uv Python install failure; retrying in {delay}s "
            f"(attempt {attempt + 1}/{INSTALL_ATTEMPTS}).",
            file=sys.stderr,
        )
        sleep(delay)
    return 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", type=parse_python_version, help="Pinned Python version passed to uv")
    options = parser.parse_args()
    raise SystemExit(install_python(options.version))


if __name__ == "__main__":
    main()
