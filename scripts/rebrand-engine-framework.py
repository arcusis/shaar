#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Set Shaar bundle identifiers on the copied, SHA-checked Chromium framework."""

import plistlib
import shutil
import sys
from pathlib import Path


FRAMEWORK_ID = "com.arcusis.shaar.framework"
SHAAR_ICON = Path(__file__).resolve().parents[1] / "Resources/Branding/Shaar.icns"
COCOA_NOTICES = Path(__file__).resolve().parents[1] / "ThirdParty/ChromiumEngine/notices"
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


def set_identity(path: Path, identifier: str, display_name: str) -> None:
    info = plistlib.loads(path.read_bytes())
    if not isinstance(info, dict) or not isinstance(info.get("CFBundleIdentifier"), str):
        raise ValueError(f"Missing bundle identifier: {path}")
    info["CFBundleIdentifier"] = identifier
    info["CFBundleDisplayName"] = display_name
    info["CFBundleName"] = display_name
    path.write_bytes(plistlib.dumps(info))


def rebrand(framework: Path) -> None:
    versioned = framework / "Versions/Current"
    helpers = versioned / "Helpers"
    actual = {path.name for path in helpers.glob("*.app")}
    if actual != set(HELPER_IDS):
        raise ValueError("Unexpected Chromium helper set")
    if any((helpers / name).is_symlink() or not (helpers / name).is_dir() for name in HELPER_IDS):
        raise ValueError("Chromium helper bundles must be real directories")
    set_identity(versioned / "Resources/Info.plist", FRAMEWORK_ID, "Shaar Engine")
    notices = versioned / "Resources/ThirdPartyNotices"
    notices.mkdir(exist_ok=True)
    for name in ("cocoa-display-LICENSE", "cocoa-display-NOTICE"):
        shutil.copyfile(COCOA_NOTICES / name, notices / name)
    for name, identifier in HELPER_IDS.items():
        helper = helpers / name / "Contents"
        display_name = name.removesuffix(".app").replace("Chromium", "Shaar", 1)
        info_path = helper / "Info.plist"
        set_identity(info_path, identifier, display_name)
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIconFile"] = "Shaar.icns"
        info.pop("CFBundleIconName", None)
        info_path.write_bytes(plistlib.dumps(info))
        resources = helper / "Resources"
        resources.mkdir(exist_ok=True)
        for localized in resources.glob("*.lproj/InfoPlist.strings"):
            values = plistlib.loads(localized.read_bytes())
            for key in ("CFBundleDisplayName", "CFBundleName"):
                if key in values:
                    values[key] = display_name
            localized.write_bytes(plistlib.dumps(values))
        shutil.copyfile(SHAAR_ICON, resources / "Shaar.icns")
        (resources / "Assets.car").unlink(missing_ok=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: rebrand-engine-framework.py FRAMEWORK")
    rebrand(Path(sys.argv[1]))
