#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 ]] || { echo 'usage: engine-apply-patches.sh CHROMIUM_SRC' >&2; exit 2; }
python3 scripts/engine_patches.py --apply "$1"
