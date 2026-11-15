#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -uo pipefail
cd "$(dirname "$0")/.."

usage() { echo 'Usage: scripts/v02-proof-run.sh ENGINE_ARCHIVE [--locale en|he] [--probes 14,15,...]' >&2; exit 2; }
archive_path=
locale=en
probe_filter=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --locale)
      [[ $# -ge 2 ]] || usage
      locale=$2
      shift 2
      ;;
    --probes)
      [[ $# -ge 2 && -n $2 ]] || usage
      probe_filter=$2
      shift 2
      ;;
    -* ) usage ;;
    *)
      [[ -z $archive_path ]] || usage
      archive_path=$1
      shift
      ;;
  esac
done
[[ -n $archive_path && ( $locale == en || $locale == he ) ]] || usage
if [[ -n $probe_filter ]]; then
  IFS=',' read -r -a requested_probes <<< "$probe_filter"
  case ",$probe_filter," in *,,*) usage ;; esac
  for probe in "${requested_probes[@]}"; do
    case "$probe" in 14|15|16|17|19) ;; *) usage ;; esac
  done
fi
probe_selected() { [[ ",$probe_filter," == *",$1,"* ]]; }
archive=$(cd "$(dirname "$archive_path")" 2>/dev/null && pwd -P)/$(basename "$archive_path") || usage
[[ -f "$archive" && ! -L "$archive" ]] || { echo 'Engine archive must be a regular, non-symlink file.' >&2; exit 2; }
dry_run=${SHAAR_V02_PROOF_DRY_RUN:-0}
case "$dry_run" in 0|1) ;; *) echo 'SHAAR_V02_PROOF_DRY_RUN must be 0 or 1.' >&2; exit 2 ;; esac
widevine_default=0
if [[ -n $probe_filter ]] && { probe_selected 17 || probe_selected 19; }; then
  widevine_default=1
fi
widevine=${SHAAR_V02_PROOF_WIDEVINE:-$widevine_default}
case "$widevine" in 0|1) ;; *) echo 'SHAAR_V02_PROOF_WIDEVINE must be 0 or 1.' >&2; exit 2 ;; esac
widevine_only=${SHAAR_V02_PROOF_WIDEVINE_ONLY:-0}
case "$widevine_only" in 0|1) ;; *) echo 'SHAAR_V02_PROOF_WIDEVINE_ONLY must be 0 or 1.' >&2; exit 2 ;; esac
if [[ $widevine_only == 1 && $widevine != 1 ]]; then
  echo 'SHAAR_V02_PROOF_WIDEVINE_ONLY requires SHAAR_V02_PROOF_WIDEVINE=1.' >&2; exit 2
fi

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
  [[ $2 == PASS || $2 == SKIP ]] || overall=1
}
run_step() {
  local label=$1; shift
  local probe_id=
  case "$label" in
    'External protocol handler consent') probe_id=14 ;;
    'Permission and protocol prompts') probe_id=15 ;;
    'Save prompts') probe_id=16 ;;
    'Platform parity for v0.2 web items') probe_id=17 ;;
    'Widevine EME, ClearKey, Shaka playback') probe_id=19 ;;
  esac
  if [[ -n $probe_filter && -n $probe_id ]] && ! probe_selected "$probe_id"; then
    record "$label" SKIP 'not selected by --probes'
    return 0
  fi
  if [[ -n $probe_filter && -n $probe_id ]] && probe_selected "$probe_id"; then
    :
  elif [[ -n $probe_filter && -z $probe_id &&
         $label != 'Shipping bundle build' && $label != 'Verification bundle build' ]]; then
    record "$label" SKIP 'not selected by --probes'
    return 0
  fi
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
run_he_engine_fixture() {
  local mode=${1:-}
  mode=${mode#--}
  [[ -n $mode ]] || mode=downloads
  SHAAR_V02_PROOF_LOCALE=he \
    SHAAR_V02_PROOF_SCREENSHOT_DIR="$run_root/hebrew/screenshots/$mode" \
    run_engine_fixture "$@"
}
record_screenshot_evidence() {
  local label=$1 directory=$2 count
  count=$(find "$directory" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')
  if [[ $count -gt 0 ]]; then
    record "$label screenshot" PASS "$count PNG(s): ${directory#"$PWD"/}/"
  else
    record "$label screenshot" FAIL "no PNG in ${directory#"$PWD"/}/"
  fi
}
record_named_screenshot() {
  local label=$1 path=$2
  if [[ -s $path ]]; then
    record "$label screenshot" PASS "${path#"$PWD"/}"
  else
    record "$label screenshot" FAIL "missing ${path#"$PWD"/}"
  fi
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
build_bundle() {
  local args=(--with-engine)
  [[ $widevine == 1 ]] && args+=(--with-widevine-cdm)
  [[ ${1:-} == verification ]] && args+=(--verification)
  "$HOME/bin/shaar-heavy" "${bundle_env[@]}" bash scripts/bundle-app.sh "${args[@]}"
}
run_step 'Shipping bundle build' build_bundle shipping
run_step 'Verification bundle build' build_bundle verification

verification_app="$PWD/build/Shaar Verification.app"
if [[ ${results[0]} == PASS && ${results[1]} == PASS &&
      -x "$verification_app/Contents/MacOS/ShaarVerification" ]]; then
  if [[ $widevine_only == 1 ]]; then
    run_step 'Widevine EME, ClearKey, Shaka playback' \
      python3 scripts/test-platform-parity.py --widevine-only --app "$verification_app" \
      --receipt "$run_root/widevine-drm.json"
  else
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
  run_step 'Basic browsing and page-initiated unsafe scheme navigation' \
    run_engine_fixture --basic-browsing
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
  if [[ $locale == he ]]; then
    he_root="$run_root/hebrew"
    mkdir -p "$he_root/screenshots"
    run_step 'Hebrew dialogs and Basic auth' env SHAAR_V02_PROOF_LOCALE=he \
      python3 scripts/test-browsing-edge-probe.py --app "$verification_app" \
      --receipt "$he_root/dialogs-basic-auth.json" --screenshot-dir "$he_root/screenshots"
    run_step 'Hebrew browsing dialogs and downloads' env SHAAR_V02_PROOF_LOCALE=he \
      python3 scripts/test-browsing-qa.py --app "$verification_app" \
      --receipt "$he_root/browsing-qa.json" --markdown "$he_root/browsing-qa.md" \
      --screenshot-dir "$he_root/screenshots"
    run_step 'Hebrew permission prompts' env SHAAR_V02_PROOF_LOCALE=he \
      python3 scripts/test-shaar-permission-prompt.py --app "$verification_app" \
      --evidence "$he_root/permission-prompts"
    run_step 'Hebrew save prompts' env SHAAR_V02_PROOF_LOCALE=he \
      python3 scripts/test-shaar-save-prompt.py --app "$verification_app" \
      --receipt "$he_root/save-prompts.json"
    run_step 'Hebrew downloads and Chrome Web Store extension' run_he_engine_fixture --bitwarden
    run_step 'Hebrew local MV3 extensions' run_he_engine_fixture --local-extension-install
    run_step 'Hebrew protocol handler' run_he_engine_fixture --external-app-consent
    run_step 'Hebrew device pickers' env SHAAR_V02_PROOF_LOCALE=he \
      python3 scripts/test-device-choosers.py --app "$verification_app" \
      --screenshot-dir "$he_root/screenshots/device-pickers"
    run_he_engine_fixture
    cp "$he_root"/browsing-*.png "$he_root/screenshots/" 2>/dev/null || true
    cp "$he_root"/save-prompt-*.png "$he_root/screenshots/" 2>/dev/null || true
    cp "$he_root"/permission-prompts/*.png "$he_root/screenshots/" 2>/dev/null || true
    record_named_screenshot 'Dialogs' "$he_root/screenshots/browsing-dialogs.png"
    record_named_screenshot 'Basic auth' "$he_root/screenshots/browsing-edge.png"
    record_screenshot_evidence 'Permission prompts' "$he_root/permission-prompts"
    record_named_screenshot 'Password save prompt' "$he_root/screenshots/save-prompt-password.png"
    record_named_screenshot 'Card save prompt' "$he_root/screenshots/save-prompt-card.png"
    record_named_screenshot 'Address save prompt' "$he_root/screenshots/save-prompt-address.png"
    record_screenshot_evidence 'Downloads' "$he_root/screenshots/downloads"
    record_screenshot_evidence 'Chrome Web Store extension' "$he_root/screenshots/bitwarden"
    record_screenshot_evidence 'Local MV3 extension' "$he_root/screenshots/local-extension-install"
    record_screenshot_evidence 'Protocol handler' "$he_root/screenshots/external-app-consent"
    record_screenshot_evidence 'Device pickers' "$he_root/screenshots/device-pickers"
  fi
  if [[ $widevine == 1 ]] || { [[ -n $probe_filter ]] && probe_selected 19; }; then
    run_step 'Widevine EME, ClearKey, Shaka playback' \
      python3 scripts/test-platform-parity.py --widevine-only --app "$verification_app" \
      --receipt "$run_root/widevine-drm.json"
  fi
  fi
else
  if [[ $widevine_only != 1 ]]; then
  for label in 'Browsing, dialogs, Basic auth, file upload, downloads, restore' \
    'Browsing QA, dialogs, downloads, session restore' 'Tab/window adoption' \
    'Bookmarks/history and browser import' 'Chrome Web Store extension install' \
    'Local MV3 extension install' 'Bluetooth and Serial chooser no-hang' \
    'Private window isolation' 'Private multi-tab isolation' \
    'Basic browsing and page-initiated unsafe scheme navigation' \
    'Reload and closed-window recovery' 'Session recovery' 'External protocol handler consent' \
    'Permission and protocol prompts' 'Save prompts' 'Platform parity for v0.2 web items' \
    'Media and picture-in-picture'; do
    record "$label" SKIP 'shipping or verification bundle build did not pass'
  done
  fi
  if [[ $widevine == 1 ]] || { [[ -n $probe_filter ]] && probe_selected 19; }; then
    record 'Widevine EME, ClearKey, Shaka playback' SKIP 'shipping or verification bundle build did not pass'
  fi
  [[ $locale == he ]] && record 'Hebrew UI locale pass' SKIP 'shipping or verification bundle build did not pass'
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
