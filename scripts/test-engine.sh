#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/bundle-app.sh --with-engine --verification
if [[ ! -x .venv/bin/python ]]; then python3 -m venv .venv; fi
exec .venv/bin/python scripts/engine_fixture.py "$@"
