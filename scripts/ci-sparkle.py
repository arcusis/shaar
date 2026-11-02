#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Perform real isolated Sparkle installations on hosted macOS only."""

from ci_support import ROOT
from sparkle_fixture import run_simulation


if __name__ == "__main__":
    run_simulation(ROOT / "build/ci/shipping")
