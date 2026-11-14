#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run offscreen Hebrew localization captures in isolated English/Hebrew test children."""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUITES = {"HebrewLocalizationVisualTests": 7, "InspectorLocalizationVisualTests": 1,
          "InspectorDockWidthTests": 2}


def child_environment():
    allowed = ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS")
    environment = {key: os.environ[key] for key in allowed if key in os.environ}
    environment["SHAAR_LOCALIZATION_CHILD"] = "1"
    return environment


def redact(text):
    # Child environment has no provider credentials; redact common accidental token-shaped output.
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]", text)
    return re.sub(r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,})\b", "[REDACTED]", text)


def test_runtime():
    environment = child_environment()
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "--jobs", "1", "--show-bin-path"],
        cwd=ROOT, env=environment, text=True,
    ).strip())
    # Swift Build emits per-target bundles; classic SwiftPM emits one package bundle.
    bundles = [binary_dir / name for name in (
        "BrowserAppTests.xctest", "ArcusisBrowserPackageTests.xctest",
    )]
    bundle = next((candidate for candidate in bundles if candidate.is_dir()), None)
    if bundle is None:
        raise RuntimeError("App or package XCTest bundle missing; build test targets first")
    developer = Path(subprocess.check_output(
        ["xcode-select", "-p"], env=environment, text=True,
    ).strip())
    environment["DYLD_FRAMEWORK_PATH"] = os.pathsep.join((
        str(binary_dir), str(developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"),
    ))
    environment["DYLD_LIBRARY_PATH"] = str(developer / "usr/lib")
    xctest = subprocess.check_output(
        ["xcrun", "--find", "xctest"], env=environment, text=True,
    ).strip()
    return xctest, bundle, environment


def expected_captures():
    names = {"space-pager-selected.png", "space-pager-drag.png",
             "language-restart-light.png", "language-restart-dark.png",
             "sidebar-toggle-windowed.png", "sidebar-toggle-fullscreen.png",
             "private-chrome-light.png", "private-chrome-dark.png",
             "v02-tabs-windows.png", "v02-session-restore.png", "v02-downloads.png",
             "v02-bookmarks.png", "v02-history.png", "v02-import.png",
             "v02-file-upload-menu.png", "v02-javascript-alert.png",
             "v02-file-upload-panel-copy.png",
             "v02-javascript-confirm.png", "v02-javascript-prompt.png", "v02-basic-auth.png",
             "v02-permission-prompts.png", "v02-protocol-registration.png",
             "v02-save-password.png", "v02-save-card.png", "v02-save-address.png",
             "v02-extensions.png", "v02-extension-consent.png",
             "v02-protocol-handler.png", "v02-device-picker.png",
             "v02-device-picker-bluetooth.png", "v02-device-picker-serial.png"}
    for scheme in ("light", "dark"):
        for panel in ("design", "css", "component", "accessibility", "assets", "notes", "overview",
                      "vitals", "network", "console", "storage", "simulations", "report"):
            names.add(f"inspector-{panel}-{scheme}.png")
        names.add(f"command-t-mixed-{scheme}.png")
        for width, state in ((760, "shown"), (1200, "shown"), (760, "hidden")):
            for screen in ("sidebar", "command-t"):
                names.add(f"{screen}-{width}-{state}-{scheme}.png")
        names.add(f"settings-{scheme}.png")
        for section in ("appearance", "privacy", "profiles", "shortcuts", "about"):
            names.add(f"settings-{section}-{scheme}.png")
        for step in ("name", "icon", "color", "account", "done"):
            names.add(f"onboarding-{step}-{scheme}.png")
        for screen in ("site-control-center", "mini-player", "picture-in-picture"):
            names.add(f"{screen}-{scheme}.png")
    for scheme in ("light", "dark"):
        for width in (320, 420):
            for panel in ("design", "code"):
                names.add(f"after-{panel}-{width}-{scheme}.png")
            for panel in ("design", "code", "notes", "copy-menu"):
                names.add(f"inspector-redesign-{panel}-{width}-{scheme}.png")
    return names


def run(language, xctest, bundle, environment):
    # Coverage-instrumented local bundles must keep LLVM output out of the checkout root.
    profiles = ROOT / "build/Verification/localization-profiles"
    if profiles.is_symlink():
        raise RuntimeError("Localization profile path must not be a symlink")
    profiles.mkdir(parents=True, exist_ok=True)
    environment = dict(environment, LLVM_PROFILE_FILE=str(profiles / f"{language}-%m-%p.profraw"))
    for suite, minimum_tests in SUITES.items():
        # xctest interprets its last argument as the bundle: keep language flags before it.
        command = [
            xctest, "-XCTest", f"BrowserAppTests.{suite}",
            "-BrowserLanguage.selection", language, str(bundle),
        ]
        result = subprocess.run(
            command, cwd=ROOT, env=environment, capture_output=True, text=True, timeout=300,
        )
        output = redact((result.stdout or "") + (result.stderr or ""))
        print(f"Localization child {language}/{suite}: exit {result.returncode}")
        print(output, end="" if output.endswith("\n") or not output else "\n")
        if result.returncode:
            return result.returncode
        counts = re.findall(r"Executed (\d+) tests?,", output)
        if (not counts or not all(int(count) >= minimum_tests for count in counts)
                or re.search(r"\b[1-9]\d* tests? skipped\b", output)):
            print(f"Localization child {language}/{suite}: incomplete or skipped suite", file=sys.stderr)
            return 1
        if suite not in output:
            print(f"Localization child {language}: test runner output missing {suite}", file=sys.stderr)
            return 1
    directory = ROOT / f"build/Verification/localization-visuals/{language}"
    screenshots = {path.name for path in directory.glob("*.png") if path.stat().st_size > 0}
    missing = expected_captures() - screenshots
    if missing:
        print(
            f"Localization child {language}: missing captures {sorted(missing)}",
            file=sys.stderr,
        )
        return 1
    print(f"Localization child {language}: all {len(expected_captures())} required captures present")
    return 0


def main():
    output = ROOT / "build/Verification/localization-visuals"
    if output.is_symlink():
        print("Localization screenshot path must not be a symlink", file=sys.stderr)
        return 1
    shutil.rmtree(output, ignore_errors=True)
    xctest, bundle, environment = test_runtime()
    for language in ("en", "he"):
        status = run(language, xctest, bundle, environment)
        if status:
            return status
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
