#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Regenerate the checked-in Finder layout with ds_store 1.3.1 and mac_alias 2.2.2."""

import datetime
import pathlib

from ds_store import DSStore
from mac_alias import (
    ALIAS_EJECTABLE_DISK,
    ALIAS_HFS_VOLUME_SIGNATURE,
    ALIAS_KIND_FILE,
    ALIAS_NO_CNID,
    Alias,
    TargetInfo,
    VolumeInfo,
)


def background_alias():
    date = datetime.datetime(2000, 5, 7, 21, 10, tzinfo=datetime.timezone.utc)
    volume = VolumeInfo(
        name="Shaar", creation_date=date, fs_type=ALIAS_HFS_VOLUME_SIGNATURE,
        disk_type=ALIAS_EJECTABLE_DISK, attribute_flags=0, fs_id=b"\0\0",
        posix_path="/Volumes/Shaar",
    )
    target = TargetInfo(
        kind=ALIAS_KIND_FILE, filename="background.png", folder_cnid=ALIAS_NO_CNID,
        cnid=ALIAS_NO_CNID, creation_date=date, creator_code=b"\0" * 4,
        type_code=b"\0" * 4, folder_name=None,
        posix_path="/.background/background.png",
        carbon_path="Shaar:.background:background.png",
    )
    return Alias(volume=volume, target=target).to_bytes()


def main(output=None):
    output = pathlib.Path(output) if output is not None else (
        pathlib.Path(__file__).resolve().parent.parent / "Resources/Installer/.DS_Store"
    )
    if output.is_symlink():
        raise ValueError(f"DMG layout output must not be a symlink: {output}")
    if output.exists() and not output.is_file():
        raise ValueError(f"DMG layout output is not a regular file: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with DSStore.open(str(output), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["icvl"] = (b"type", b"icnv")
        store["."]["bwsp"] = {
            "ShowStatusBar": False, "WindowBounds": "{{180, 140}, {660, 420}}",
            "ContainerShowSidebar": False, "PreviewPaneVisibility": False,
            "SidebarWidth": 180, "ShowTabView": False, "ShowToolbar": False,
            "ShowPathbar": False, "ShowSidebar": False,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1, "backgroundType": 2,
            "backgroundImageAlias": background_alias(),
            "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
            "arrangeBy": "none", "showIconPreview": True, "showItemInfo": False,
            "labelOnBottom": True, "textSize": 13.0, "iconSize": 112.0,
            "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
        }
        store["Shaar.app"]["Iloc"] = (172, 184)
        store["Applications"]["Iloc"] = (490, 184)


if __name__ == "__main__":
    main()
