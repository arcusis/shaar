#!/bin/bash
set -euo pipefail

# Hosted component fixture only. Never initialize Chromium or create UI objects.
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS &&
   "${ARCUSIS_NATIVE_PASSWORD_STARTUP_CI:-}" == 1 ]] || {
  echo "Native password startup fixture requires the explicit hosted CI gate." >&2
  exit 1
}
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
out="$root/build/Verification/native-password-startup"
[[ ! -L "$root/build" && ! -L "$root/build/Verification" && ! -e "$out" && ! -L "$out" ]] || {
  echo "Unsafe or existing fixture output." >&2
  exit 1
}
mkdir -p "$out/evidence" "$out/scratch"
evidence="$out/evidence"
inputs=(
  Sources/ChromiumBridge/ChromiumBridge.mm
  Sources/ChromiumBridge/ChromiumDownloads.mm
  Sources/ChromiumBridge/ChromiumDownloads.h
  Sources/ChromiumBridge/ChromiumEngineServices.mm
  Sources/ChromiumBridge/ChromiumEngineServices.h
  Sources/ChromiumBridge/ChromiumLibrary.mm
  Sources/ChromiumBridge/ChromiumLibrary.h
  Sources/ChromiumBridge/ChromiumProbeTLS.mm
  Sources/ChromiumBridge/include/ChromiumBridge.h
  ThirdParty/ArdiaCore/ArdiaCore.h
  ThirdParty/ArdiaCore/ac_engine.h
  Tests/NativePasswordPolicyStartupTests/NativePasswordPolicyStartupTests.mm
  scripts/test-native-password-startup.sh
  .github/workflows/native-password-startup.yml
)
shasum -a 256 "${inputs[@]}" > "$evidence/inputs-before.sha256"
finish() {
  status=$?
  trap - EXIT
  shasum -a 256 "${inputs[@]}" > "$evidence/inputs-after.sha256" || status=1
  cmp -s "$evidence/inputs-before.sha256" "$evidence/inputs-after.sha256" || status=1
  printf 'exit=%s\n' "$status" > "$evidence/status.txt"
  exit "$status"
}
trap finish EXIT
printf 'sourceRevision=%s\ncomponentOnly=true\nengineRuntime=false\n' "${GITHUB_SHA:?}" > "$evidence/scope.txt"
clang="$(xcrun --find clang++)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
frameworks="${DEVELOPER_DIR:?}/Platforms/MacOSX.platform/Developer/Library/Frameworks"
xctest="$DEVELOPER_DIR/usr/bin/xctest"
[[ -x "$clang" && -x "$xctest" && -d "$frameworks/XCTest.framework" ]] || {
  echo "Required Xcode compiler or XCTest is missing." >&2
  exit 1
}
tests=(
  testSelectionPrecedesOneStartAndBindsOwnerAndLibrary
  testReleaseRejectsMissingAndNonSuccessWithoutRetry
  testDebugAllowsBrowsingButNeverNativeCapabilityOnFailure
  testBuildModeControlsUnavailablePolicy
  testReentrantSelectionCannotStartOrReconfigure
  testConcurrentSelectionCannotStartOrReconfigure
  testTwoWindowsUseSameRuntimeCapability
  testTwoWindowsRemainUnavailableWithoutPolicy
)
for mode in debug release; do
  bundle="$out/scratch/$mode/Startup.xctest"
  executable="$bundle/Contents/MacOS/Startup"
  mkdir -p "$bundle/Contents/MacOS"
  cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Startup</string>
<key>CFBundleIdentifier</key><string>org.arcusis.startup-fixture</string>
<key>CFBundleName</key><string>Startup</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
  flags=()
  if [[ "$mode" == debug ]]; then flags=(-DDEBUG=1 -O0); else flags=(-O2); fi
  compile=(/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)'
    "$clang" -bundle -fobjc-arc -std=c++17 -DARC_NATIVE_PASSWORD_STARTUP_FIXTURE=1 -mmacosx-version-min=26.0 -isysroot "$sdk"
    -F "$frameworks" -framework XCTest -framework AppKit -Wl,-rpath,"$frameworks"
    "${flags[@]}" Tests/NativePasswordPolicyStartupTests/NativePasswordPolicyStartupTests.mm
    Sources/ChromiumBridge/ChromiumDownloads.mm Sources/ChromiumBridge/ChromiumEngineServices.mm
    Sources/ChromiumBridge/ChromiumLibrary.mm Sources/ChromiumBridge/ChromiumProbeTLS.mm -o "$executable")
  printf '%q ' "${compile[@]}" > "$evidence/$mode-compile.argv"
  printf '\n' >> "$evidence/$mode-compile.argv"
  "${compile[@]}" > "$evidence/$mode-compile.log" 2>&1
  shasum -a 256 "$executable" > "$evidence/$mode-binary.sha256"
  for test in "${tests[@]}"; do
    command=(/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)(deny process-fork)'
      "$xctest" -XCTest "NativePasswordPolicyStartupTests/$test" "$bundle")
    printf '%q ' "${command[@]}" > "$evidence/$mode-$test.argv"
    printf '\n' >> "$evidence/$mode-$test.argv"
    "${command[@]}" > "$evidence/$mode-$test.log" 2>&1
    if ! /usr/bin/grep -Fq 'Executed 1 test, with 0 failures' "$evidence/$mode-$test.log"; then
      echo "Named XCTest did not report exactly one passing test: $mode/$test" >&2
      exit 1
    fi
  done
done
printf 'namedTestsPerMode=%s\n' "${#tests[@]}" > "$evidence/count.txt"
