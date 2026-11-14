#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Stage shipping SwiftPM resource bundles and the Public Suffix notices."""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

BUNDLE = "ArcusisBrowser_BrowserCore.bundle"
AUDIT_BUNDLE = "ArcusisBrowser_ArcusisBrowser.bundle"
AUDIT_FILES = ("InspectorAudit/axe.min.js", "InspectorAudit/runner.js")
STAGED_BUNDLE_NAMES = (BUNDLE, AUDIT_BUNDLE)
DATA_HASH = "4155611645690529d1bbea0cfe653b0c45f63b028e0ba039de29a97edc3204ca"
LICENSE_HASH = "fab3dd6bdab226f1c08630b1dd917e11fcb4ec5e1e020e2c16f83a0a13863e85"
AUDIT_LABEL = "ArcusisBrowser resource input"


def read_bounded(path: Path, label: str = "BrowserCore resource input") -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{label} is not a regular file")
    with path.open("rb") as source:
        data = source.read(2_000_001)
    if len(data) > 2_000_000:
        raise ValueError(f"{label} exceeds size limit")
    return data


def digest(path: Path) -> str:
    return hashlib.sha256(read_bounded(path)).hexdigest()


def shipping_resource_bundles(binary_dir: Path) -> list[Path]:
    bundles = []
    for path in sorted(binary_dir.glob("ArcusisBrowser_*.bundle")):
        if path.is_symlink() or not path.is_dir():
            raise ValueError(f"SwiftPM resource bundle is not a directory: {path.name}")
        bundles.append(path)
    return bundles


def audit_resource_root(source: Path) -> Path:
    contents = source / "Contents"
    if contents.exists():
        if (source / "InspectorAudit").exists() or (source / "Info.plist").exists():
            raise ValueError("ArcusisBrowser resource bundle layout is ambiguous")
        info = contents / "Info.plist"
        if info.is_symlink() or not info.is_file():
            raise ValueError("ArcusisBrowser resource bundle Info.plist missing")
        read_bounded(info, AUDIT_LABEL)
        return contents / "Resources"
    return source


def validate_inspector_audit(source: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise ValueError("ArcusisBrowser resource bundle is missing")
    if any(path.is_symlink() for path in source.rglob("*")):
        raise ValueError("ArcusisBrowser resource bundle contains symlink")
    root = audit_resource_root(source)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("ArcusisBrowser resource bundle resources are missing")
    for relative in AUDIT_FILES:
        data = read_bounded(root.joinpath(*relative.split("/")), AUDIT_LABEL)
        if not data:
            raise ValueError("ArcusisBrowser resource input is empty")
    for path in sorted(root.rglob("*")):
        if path.is_file():
            data = read_bounded(path, AUDIT_LABEL)
            if not data:
                raise ValueError("ArcusisBrowser resource input is empty")
        elif not path.is_dir():
            raise ValueError("ArcusisBrowser resource input is not a regular file")


def require_staged_shipping_bundles(binary_dir: Path, resources: Path) -> None:
    missing = []
    for path in shipping_resource_bundles(binary_dir):
        staged = resources / path.name
        if staged.is_symlink() or not staged.is_dir():
            missing.append(path.name)
    if missing:
        raise ValueError(
            "SwiftPM resource bundle was not staged into the app: " + ", ".join(missing))


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
    if resources.parent.is_symlink():
        raise ValueError(f"resource output parent must not be a symlink: {resources.parent}")
    if resources.is_symlink():
        raise ValueError(f"resource output directory must not be a symlink: {resources}")
    if resources.exists() and not resources.is_dir():
        raise ValueError(f"resource output path is not a directory: {resources}")
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
    validate_inspector_audit(binary_dir / AUDIT_BUNDLE)
    unexpected = [
        path.name
        for path in shipping_resource_bundles(binary_dir)
        if path.name not in STAGED_BUNDLE_NAMES
    ]
    if unexpected:
        raise ValueError(
            "SwiftPM resource bundle was not staged into the app: " + ", ".join(unexpected))
    if resources.is_symlink() or (resources.exists() and not resources.is_dir()):
        raise ValueError("resource staging destination is not a regular directory")
    if any(parent.is_symlink() for parent in resources.parents[:2]):
        raise ValueError("resource staging destination has a symlinked parent")
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
        shutil.copytree(binary_dir / AUDIT_BUNDLE, tmp / AUDIT_BUNDLE)
        notices = tmp / "PublicSuffix"
        notices.mkdir()
        shutil.copyfile(pin_dir / "LICENSE", notices / "LICENSE")
        shutil.copyfile(pin_dir / "pin.json", notices / "pin.json")
        localizations = root / "Resources/Localizations"
        for catalog in sorted(localizations.glob("*.xcstrings")):
            compile_catalog(catalog, tmp)
        for name in (BUNDLE, AUDIT_BUNDLE, "PublicSuffix"):
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
    require_staged_shipping_bundles(binary_dir, resources)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: stage-browser-resources.py BINARY_DIR RESOURCES_DIR")
    root = Path(__file__).resolve().parent.parent
    try:
        stage(Path(sys.argv[1]), Path(sys.argv[2]), root / "ThirdParty/PublicSuffix")
    except (OSError, ValueError) as error:
        raise SystemExit(f"Resource staging failed: {error}") from error


if __name__ == "__main__":
    main()
