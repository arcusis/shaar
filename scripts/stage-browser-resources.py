#!/usr/bin/env python3
"""Stage the verified SwiftPM BrowserCore bundle and its PSL notices."""
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

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


def stage(binary_dir: Path, resources: Path, pin_dir: Path) -> None:
    source = binary_dir / BUNDLE
    if source.is_symlink() or any(path.is_symlink() for path in source.rglob("*")):
        raise ValueError("BrowserCore resource bundle contains symlink")
    pin = json.loads(read_bounded(pin_dir / "pin.json").decode("utf-8"))
    if pin.get("sha256") != DATA_HASH or pin.get("license_sha256") != LICENSE_HASH:
        raise ValueError("PublicSuffix pin hashes do not match expected hashes")
    if digest(source / "Contents/Resources/public_suffix_list.dat") != DATA_HASH:
        raise ValueError("BrowserCore resource hash mismatch")
    if digest(pin_dir / "LICENSE") != LICENSE_HASH:
        raise ValueError("PublicSuffix license hash mismatch")
    if not (source / "Contents/Info.plist").is_file():
        raise ValueError("BrowserCore resource bundle Info.plist missing")
    resources.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=resources, prefix=".browser-resources-") as temporary:
        tmp = Path(temporary)
        shutil.copytree(source, tmp / BUNDLE)
        notices = tmp / "PublicSuffix"
        notices.mkdir()
        shutil.copyfile(pin_dir / "LICENSE", notices / "LICENSE")
        shutil.copyfile(pin_dir / "pin.json", notices / "pin.json")
        for name in (BUNDLE, "PublicSuffix"):
            target = resources / name
            if target.is_symlink() or (target.exists() and not target.is_dir()):
                target.unlink()
            elif target.exists():
                shutil.rmtree(target)
            (tmp / name).rename(target)


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
