# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Declare the shipping sidebar pasteboard type for unbundled native test processes."""

from contextlib import contextmanager
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

LSREGISTER = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
SIDEBAR_TYPE = "com.arcusis.browser.sidebar-item"


@contextmanager
def registered_sidebar_type():
    # Register metadata only. The fixture executable is never launched; no windows or
    # focus changes are needed. Always unregister this exact owned bundle afterward.
    with tempfile.TemporaryDirectory(prefix="shaar-sidebar-types-") as directory:
        bundle = Path(directory) / "Sidebar Type Fixture.app"
        contents = bundle / "Contents"
        executable = contents / "MacOS" / "SidebarTypeFixture"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o700)
        metadata = {
            "CFBundleIdentifier": f"com.arcusis.browser.sidebar-test.{uuid.uuid4().hex}",
            "CFBundleName": "Sidebar Type Fixture",
            "CFBundleExecutable": executable.name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "LSBackgroundOnly": True,
            "UTExportedTypeDeclarations": [{
                "UTTypeIdentifier": SIDEBAR_TYPE,
                "UTTypeDescription": "Arcusis Sidebar Item",
                "UTTypeConformsTo": ["public.data"],
            }],
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
        try:
            subprocess.run([str(LSREGISTER), "-f", str(bundle)], check=True, timeout=30)
            yield bundle
        finally:
            subprocess.run([str(LSREGISTER), "-u", str(bundle)], check=True, timeout=30)
