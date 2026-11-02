#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject sensitive/large files and escaping symlinks in the Git index."""

import argparse
import sys

from ci_support import ROOT
from git_content import run_main
from sensitive_files import policy_errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision")
    options = parser.parse_args()
    errors = policy_errors(ROOT, options.revision)
    for error in errors:
        print(error, file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(run_main(main))
