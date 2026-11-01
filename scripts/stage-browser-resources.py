#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Stage the verified SwiftPM BrowserCore bundle and its PSL notices."""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

BUNDLE = "ArcusisBrowser_BrowserCore.bundle"
DATA_HASH = "4155611645690529d1bbea0cfe653b0c45f63b028e0ba039de29a97edc3204ca"
LICENSE_HASH = "fab3dd6bdab226f1c08630b1dd917e11fcb4ec5e1e020e2c16f83a0a13863e85"


def read_bounded(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ValueError("BrowserCore resource input is not a regular file")
    with path.open("rb") as source:
        data = source.read(2_000_001)
    if len(data) > 2_000_000:
        raise ValueError("BrowserCore resource input exceeds size limit")
    return data


def digest(path: Path) -> str:
    return hashlib.sha256(read_bounded(path)).hexdigest()


def compile_catalog(catalog: Path, output: Path) -> None:
    try:
        subprocess.run(
            ["xcrun", "xcstringstool", "compile", str(catalog), "--output-directory", str(output),
             "--language", "en", "--language", "he"],
            check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        raise ValueError(f"String Catalog compilation failed for {catalog.name}: {error.stderr.strip()}") from error


def stage(
    binary_dir: Path,
    resources: Path,
    pin_dir: Path,
    catalog_dir: Optional[Path] = None,
) -> None:
    root = Path(__file__).resolve().parent.parent
    catalog_dir = catalog_dir or root / "Sources/BrowserCore/Resources"
    source = binary_dir / BUNDLE
    if source.is_symlink() or any(path.is_symlink() for path in source.rglob("*")):
        raise ValueError("BrowserCore resource bundle contains symlink")
    pin = json.loads(read_bounded(pin_dir / "pin.json").decode("utf-8"))
    if pin.get("sha256") != DATA_HASH or pin.get("license_sha256") != LICENSE_HASH:
        raise ValueError("PublicSuffix pin hashes do not match expected hashes")
    contents = source / "Contents"
    if contents.exists():
        if (source / "public_suffix_list.dat").exists() or (source / "Info.plist").exists():
            raise ValueError("BrowserCore resource bundle layout is ambiguous")
        data = contents / "Resources/public_suffix_list.dat"
        if not (contents / "Info.plist").is_file():
            raise ValueError("BrowserCore resource bundle Info.plist missing")
    else:
        # Classic SwiftPM emits a flat resource bundle without Info.plist.
        data = source / "public_suffix_list.dat"
    if digest(data) != DATA_HASH:
        raise ValueError("BrowserCore resource hash mismatch")
    if digest(pin_dir / "LICENSE") != LICENSE_HASH:
        raise ValueError("PublicSuffix license hash mismatch")
    resources.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=resources, prefix=".browser-resources-") as temporary:
        tmp = Path(temporary)
        staged_bundle = tmp / BUNDLE
        shutil.copytree(source, staged_bundle)
        compiled_resources = staged_bundle / "Contents/Resources"
        if not compiled_resources.is_dir():
            compiled_resources = staged_bundle
        for catalog in sorted(catalog_dir.glob("*.xcstrings")):
            compile_catalog(catalog, compiled_resources)
        notices = tmp / "PublicSuffix"
        notices.mkdir()
        shutil.copyfile(pin_dir / "LICENSE", notices / "LICENSE")
        shutil.copyfile(pin_dir / "pin.json", notices / "pin.json")
        localizations = root / "Resources/Localizations"
        for catalog in sorted(localizations.glob("*.xcstrings")):
            compile_catalog(catalog, tmp)
        for name in (BUNDLE, "PublicSuffix"):
            target = resources / name
            if target.is_symlink() or (target.exists() and not target.is_dir()):
                target.unlink()
            elif target.exists():
                shutil.rmtree(target)
            (tmp / name).rename(target)
        for language in ("en", "he"):
            target = resources / f"{language}.lproj"
            if target.is_symlink() or (target.exists() and not target.is_dir()):
                target.unlink()
            elif target.exists():
                shutil.rmtree(target)
            (tmp / f"{language}.lproj").rename(target)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: stage-browser-resources.py BINARY_DIR RESOURCES_DIR")
    root = Path(__file__).resolve().parent.parent
    try:
        stage(Path(sys.argv[1]), Path(sys.argv[2]), root / "ThirdParty/PublicSuffix")
    except (OSError, ValueError) as error:
        raise SystemExit(f"BrowserCore resource staging failed: {error}") from error


if __name__ == "__main__":
    main()
