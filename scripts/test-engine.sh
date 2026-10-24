#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/bundle-app.sh --with-engine
if [[ ! -x .venv/bin/python ]]; then python3 -m venv .venv; fi
exec .venv/bin/python scripts/engine_fixture.py
