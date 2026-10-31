# shellcheck shell=bash
# Sourced by bundle-app.sh and release.sh so both sign the Chromium framework in one order.
# sign_engine_framework <framework> <command> runs `<command> <path>` for each library, then
# each helper app or executable, then the framework itself: inside out.
sign_engine_framework() {
  local framework="$1" sign="$2" item
  for item in "$framework"/Versions/Current/Libraries/*.dylib; do
    "$sign" "$item"
  done
  for item in "$framework"/Versions/Current/Helpers/*; do
    if [[ -d "$item" && "$item" == *.app ]] || [[ -f "$item" && -x "$item" ]]; then
      "$sign" "$item"
    fi
  done
  "$sign" "$framework"
}
