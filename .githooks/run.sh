#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -eu
root=$(git rev-parse --show-toplevel)
stage=$(basename "$0")
cd "$root"
if { [ "$stage" = pre-commit ] || [ "$stage" = pre-push ]; } && [ -f scripts/hook-checks.py ]; then
  if [ ! -x .venv/bin/python ]; then
    echo 'Shaar hooks require the configured .venv Python; see CONTRIBUTING.md.' >&2
    exit 1
  fi
  exec .venv/bin/python scripts/hook-checks.py "$stage" "$@"
fi
# Keep prior guards active when checking out a version predating these hooks.
previous=$(git config --worktree --get shaar.previousHooksPath || true)
if [ "$stage" = pre-commit ] || [ "$stage" = pre-push ]; then
  echo 'Shaar hook runner absent in this checkout; delegating to previous hooks.' >&2
fi
if [ -n "$previous" ] && [ -x "$previous/$stage" ]; then
  exec "$previous/$stage" "$@"
fi
