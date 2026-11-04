#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Set Shaar bundle identifiers on the copied, SHA-checked Chromium framework."""

import plistlib
import sys
from pathlib import Path


FRAMEWORK_ID = "com.arcusis.shaar.framework"
HELPER_IDS = {
    "Chromium Helper.app": "com.arcusis.shaar.helper",
    "Chromium Helper (GPU).app": "com.arcusis.shaar.helper",
    "Chromium Helper (Renderer).app": "com.arcusis.shaar.helper.renderer",
    "Chromium Helper (Alerts).app": "com.arcusis.shaar.framework.AlertNotificationService",
    "Chromium Helper (Aperitif).app": "com.arcusis.shaar.helper",
    "Chromium Helper (Aperitif GPU).app": "com.arcusis.shaar.helper",
    "Chromium Helper (Aperitif Renderer).app": "com.arcusis.shaar.helper.renderer",
    "Chromium Helper (Aperitif Alerts).app": "com.arcusis.shaar.framework.AlertNotificationService",
}


def set_identifier(path: Path, identifier: str) -> None:
    info = plistlib.loads(path.read_bytes())
    if not isinstance(info, dict) or not isinstance(info.get("CFBundleIdentifier"), str):
        raise ValueError(f"Missing bundle identifier: {path}")
    info["CFBundleIdentifier"] = identifier
    path.write_bytes(plistlib.dumps(info))


def rebrand(framework: Path) -> None:
    versioned = framework / "Versions/Current"
    helpers = versioned / "Helpers"
    actual = {path.name for path in helpers.glob("*.app")}
    if actual != set(HELPER_IDS):
        raise ValueError("Unexpected Chromium helper set")
    set_identifier(versioned / "Resources/Info.plist", FRAMEWORK_ID)
    for name, identifier in HELPER_IDS.items():
        set_identifier(helpers / name / "Contents/Info.plist", identifier)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: rebrand-engine-framework.py FRAMEWORK")
    rebrand(Path(sys.argv[1]))
