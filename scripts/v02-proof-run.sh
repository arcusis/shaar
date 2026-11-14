#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -uo pipefail
cd "$(dirname "$0")/.."

usage() { echo 'Usage: scripts/v02-proof-run.sh ENGINE_ARCHIVE' >&2; exit 2; }
[[ $# == 1 ]] || usage
archive=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)/$(basename "$1") || usage
[[ -f "$archive" && ! -L "$archive" ]] || { echo 'Engine archive must be a regular, non-symlink file.' >&2; exit 2; }
dry_run=${SHAAR_V02_PROOF_DRY_RUN:-0}
case "$dry_run" in 0|1) ;; *) echo 'SHAAR_V02_PROOF_DRY_RUN must be 0 or 1.' >&2; exit 2 ;; esac

run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
run_root="$PWD/build/v02-proof/$run_id"
logs="$run_root/logs"
mkdir -p "$logs"
report="$run_root/report.md"
declare -a labels=() results=() details=()
overall=0

crash_dirs=("$HOME/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports/Retired")
crash_snapshot() {
  local dir
  for dir in "${crash_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 1 -type f \( -name 'Shaar*.ips' -o -name 'Shaar*.crash' -o \
      -name 'ArcusisBrowser*.ips' -o -name 'ArcusisBrowser*.crash' -o \
      -name 'Chromium*.ips' -o -name 'Chromium*.crash' \) -print
  done | sort -u
}
crashes_before="$run_root/crashes-before.txt"
crashes_after="$run_root/crashes-after.txt"
crash_snapshot > "$crashes_before"

record() {
  labels+=("$1") results+=("$2") details+=("$3")
  [[ $2 == PASS ]] || overall=1
}
run_step() {
  local label=$1; shift
  local logfile="$logs/${#labels[@]}-${label//[^A-Za-z0-9_.-]/_}.log"
  echo "[v02-proof] $label"
  if "$@" >"$logfile" 2>&1; then
    record "$label" PASS "log: ${logfile#"$PWD"/}"
  else
    local status=$?
    record "$label" FAIL "exit $status; log: ${logfile#"$PWD"/}"
  fi
}
run_engine_fixture() {
  SHAAR_VERIFICATION_APP="$PWD/build/Shaar Verification.app" \
    python3 scripts/engine_fixture.py "$@"
}
run_device_chooser_check() {
  local receipt="$run_root/device-choosers.json"
  python3 scripts/test-device-choosers.py --app "$verification_app" >"$receipt" 2>&1 || true
  cat "$receipt"
  python3 - "$receipt" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text().lstrip()
receipt, _ = json.JSONDecoder().raw_decode(raw)
rows = {row.get("transport"): row for row in receipt.get("rows", [])}
required = ("serial", "bluetooth")
failed = [transport for transport in required
          if transport not in rows or rows[transport].get("passed") is not True]
if failed or receipt.get("newCrashes"):
    print(json.dumps({"failedNoHangRows": failed,
                      "newCrashes": receipt.get("newCrashes", [])}, indent=2))
    raise SystemExit(1)
PY
}
run_platform_parity() {
  local receipt="$run_root/platform-parity.json"
  python3 scripts/test-platform-parity.py --app "$verification_app" --receipt "$receipt" || return
  python3 - "$receipt" <<'PY'
import json
import sys
from pathlib import Path

receipt = json.loads(Path(sys.argv[1]).read_text())
# Bluetooth and Serial are gated by the dedicated no-hang probe below; parity
# also requires a visible chooser, which is not possible without a paired device.
items = {
    "Camera permission", "Microphone permission", "Geolocation permission",
    "Notifications permission", "MIDI permission", "Autofill addresses",
    "Autofill cards", "Autofill passwords", "EME/Widevine",
    "Picture in Picture", "Media Session", "Protocol handlers", "Downloads",
    "Extensions (MV3) basics", "WebAuthn/passkeys",
}
rows = {row.get("item"): row.get("result") for row in receipt.get("rows", [])}
missing = sorted(items - rows.keys())
failed = sorted(item for item in items if rows.get(item) != "pass")
if not receipt.get("completed") or missing or failed:
    print(json.dumps({"missingChecklistRows": missing, "failedChecklistRows": failed}, indent=2))
    raise SystemExit(1)
PY
}

bundle_env=(env "SHAAR_ENGINE_ARCHIVE_PATH=$archive")
if [[ $dry_run == 1 ]]; then
  bundle_env+=("SHAAR_V02_PROOF_DRY_RUN=1")
fi
run_step 'Shipping bundle build' "$HOME/bin/shaar-heavy" "${bundle_env[@]}" \
  bash scripts/bundle-app.sh --with-engine
run_step 'Verification bundle build' "$HOME/bin/shaar-heavy" "${bundle_env[@]}" \
  bash scripts/bundle-app.sh --with-engine --verification

verification_app="$PWD/build/Shaar Verification.app"
if [[ -x "$verification_app/Contents/MacOS/ShaarVerification" ]]; then
  run_step 'Browsing, dialogs, Basic auth, file upload, downloads, restore' \
    python3 scripts/test-browsing-edge-probe.py --app "$verification_app" \
    --receipt "$run_root/browsing-edge.json"
  run_step 'Browsing QA, dialogs, downloads, session restore' \
    python3 scripts/test-browsing-qa.py --app "$verification_app" \
    --receipt "$run_root/browsing-qa.json" --markdown "$run_root/browsing-qa.md"
  run_step 'Tab/window adoption' python3 scripts/test-tab-adoption-shipping.py \
    --app "$verification_app" --receipt "$run_root/tab-adoption.json"
  run_step 'Bookmarks/history and browser import' run_engine_fixture
  run_step 'Chrome Web Store extension install' run_engine_fixture --bitwarden
  run_step 'Local MV3 extension install' run_engine_fixture --local-extension-install
  run_step 'Bluetooth and Serial chooser no-hang' run_device_chooser_check
  run_step 'Private window isolation' run_engine_fixture --private-window
  run_step 'Private multi-tab isolation' run_engine_fixture --private-multitab
  run_step 'Basic browsing' run_engine_fixture --basic-browsing
  run_step 'Reload and closed-window recovery' run_engine_fixture --reload-window
  run_step 'Session recovery' run_engine_fixture --session-recovery
  run_step 'External protocol handler consent' run_engine_fixture --external-app-consent
  run_step 'Permission and protocol prompts' python3 scripts/test-shaar-permission-prompt.py \
    --app "$verification_app" --evidence "$run_root/permission-prompts"
  run_step 'Save prompts' python3 scripts/test-shaar-save-prompt.py \
    --app "$verification_app" --receipt "$run_root/save-prompts.json"
  run_step 'Platform parity for v0.2 web items' run_platform_parity
  run_step 'Media and picture-in-picture' python3 scripts/test-shaar-media.py \
    --app "$verification_app" --receipt "$run_root/media.json"
else
  for label in 'Browsing, dialogs, Basic auth, file upload, downloads, restore' \
    'Browsing QA, dialogs, downloads, session restore' 'Tab/window adoption' \
    'Bookmarks/history and browser import' 'Chrome Web Store extension install' \
    'Local MV3 extension install' 'Bluetooth and Serial chooser no-hang' \
    'Private window isolation' 'Private multi-tab isolation' 'Basic browsing' \
    'Reload and closed-window recovery' 'Session recovery' 'External protocol handler consent' \
    'Permission and protocol prompts' 'Save prompts' 'Platform parity for v0.2 web items' \
    'Media and picture-in-picture'; do
    record "$label" SKIP 'verification bundle executable unavailable'
  done
fi

crash_snapshot > "$crashes_after"
if diff -u "$crashes_before" "$crashes_after" > "$run_root/crash-delta.diff"; then
  record 'New Shaar crash reports' PASS 'none'
else
  record 'New Shaar crash reports' FAIL "see ${run_root#"$PWD"/}/crash-delta.diff"
fi

{
  if [[ $dry_run == 1 ]]; then
    echo '> **DRY RUN ONLY — receipt validation bypass enabled for pinned .37. This is not release proof.**'
    echo
  fi
  echo "Engine archive: \`$(basename "$archive")\`"
  echo "Run evidence: \`${run_root#"$PWD"/}\`"
  echo
  echo '| Checklist probe | Result | Evidence |'
  echo '|---|---|---|'
  for index in "${!labels[@]}"; do
    echo "| ${labels[$index]} | **${results[$index]}** | ${details[$index]} |"
  done
} | tee "$report"
echo "Report: $report"
exit "$overall"
