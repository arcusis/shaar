#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run shared gates against exactly the content Git is committing or pushing."""

import argparse
import sys

from ci_support import ROOT
from git_content import run_main
from hook_support import run_hook


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("pre-commit", "pre-push"))
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    data = sys.stdin.buffer.read() if options.stage == "pre-push" else None
    return run_hook(ROOT, options.stage, options.arguments, data)


if __name__ == "__main__":
    raise SystemExit(run_main(main))
