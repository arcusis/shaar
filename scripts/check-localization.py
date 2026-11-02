#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Validate localization catalogs and keep the reviewed string inventory reproducible."""

import argparse
import csv
import importlib.util
import io
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "Notebook/Hebrew_String_Inventory.csv"
SOURCE_SUFFIXES = {".swift", ".mm", ".m", ".h"}


def load_validator():
    spec = importlib.util.spec_from_file_location(
        "compile_localizations", ROOT / "scripts/compile-localizations.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def forms(value, source):
    if not isinstance(value, dict):
        return {"other": source}
    if "stringUnit" in value:
        string_unit = value["stringUnit"]
        return {"other": string_unit.get("value", source) if isinstance(string_unit, dict) else source}
    plural = value.get("variations", {}).get("plural", {})
    if not isinstance(plural, dict):
        return {}
    return {
        category: item.get("stringUnit", {}).get("value", "")
        for category, item in sorted(plural.items())
        if isinstance(item, dict) and isinstance(item.get("stringUnit"), dict)
    }


def locate_references(key):
    locations = []
    needle = json.dumps(key, ensure_ascii=False)
    for path in sorted(ROOT.joinpath("Sources").rglob("*")):
        if path.suffix not in SOURCE_SUFFIXES or not path.is_file():
            continue
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if needle in line:
                locations.append((path.relative_to(ROOT).as_posix(), line_number))
    return locations


def source_line(relative_path, token):
    path = ROOT / relative_path
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if token in line:
            return str(line_number)
    raise ValueError(f"inventory disposition source marker missing: {relative_path} {token!r}")


def inventory_rows():
    rows = []
    catalogs = sorted(ROOT.joinpath("Sources").rglob("*.xcstrings")) + sorted(
        ROOT.joinpath("Resources/Localizations").glob("*.xcstrings")
    )
    for catalog in catalogs:
        data = json.loads(catalog.read_text(encoding="utf-8"))
        table = catalog.stem
        for key, entry in sorted(data.get("strings", {}).items()):
            localizations = entry.get("localizations", {}) if isinstance(entry, dict) else {}
            english = forms(localizations.get("en"), key)
            hebrew = forms(localizations.get("he"), key)
            english_text = json.dumps(english, ensure_ascii=False, sort_keys=True)
            hebrew_text = json.dumps(hebrew, ensure_ascii=False, sort_keys=True)
            locations = locate_references(key)
            if not locations:
                catalog_lines = catalog.read_text(encoding="utf-8").splitlines()
                marker = json.dumps(key, ensure_ascii=False)
                line = next((i for i, text in enumerate(catalog_lines, 1) if marker in text), 1)
                locations = [(catalog.relative_to(ROOT).as_posix(), line)]
            for path, line in locations:
                rows.append({
                    "source_file": path,
                    "source_line": str(line),
                    "table": table,
                    "key": key,
                    "english": english_text,
                    "hebrew": hebrew_text,
                    "disposition": "catalog-authoritative translation; source line is lexical occurrence, not proof of table binding",
                })
    rows.extend([
        {"source_file": "Sources/BrowserCore/ProductIdentity.swift", "source_line": source_line("Sources/BrowserCore/ProductIdentity.swift", 'static let name = "Shaar"'),
         "table": "Disposition", "key": "Product name", "english": "Shaar", "hebrew": "Shaar",
         "disposition": "retained product brand"},
        {"source_file": "Sources/BrowserCore/ProductIdentity.swift", "source_line": source_line("Sources/BrowserCore/ProductIdentity.swift", 'static let dataFolderName = "Arcusis Browser"'),
         "table": "Disposition", "key": "Application data folder", "english": "Arcusis Browser",
         "hebrew": "Arcusis Browser", "disposition": "retained for persisted user data compatibility"},
        {"source_file": "Sources/BrowserCore/BrowserSession.swift", "source_line": source_line("Sources/BrowserCore/BrowserSession.swift", 'name = try values.decode(String.self, forKey: .name)'),
         "table": "Disposition", "key": "Existing profile and Space names", "english": "user-owned persisted names",
         "hebrew": "unchanged", "disposition": "never rewritten during locale change"},
        {"source_file": "Resources/ExtensionManager/manager.html", "source_line": source_line("Resources/ExtensionManager/manager.html", "<title>"),
         "table": "Disposition", "key": "Shaar Extension Manager document title", "english": "Shaar Extension Manager",
         "hebrew": "retained", "disposition": "internal extension view is never a browser tab or session entry; ChromiumExtensions.mm opens it as popup service view"},
        {"source_file": "Resources/ExtensionManager/manifest.json", "source_line": source_line("Resources/ExtensionManager/manifest.json", '"name":'),
         "table": "Disposition", "key": "Extension Manager component name and description", "english": "Shaar Extension Manager; built-in management API component",
         "hebrew": "retained", "disposition": "internal component metadata, not displayed browser UI"},
        {"source_file": "Sources/ChromiumBridge/ChromiumExtensions.mm", "source_line": source_line("Sources/ChromiumBridge/ChromiumExtensions.mm", "openExtensionView:url profile:profile kind:@\"popup\""),
         "table": "Disposition", "key": "Extension Manager visibility boundary", "english": "internal extension popup service view",
         "hebrew": "not translated", "disposition": "source confirms component view is not a tab or persisted session page"},
    ])
    return sorted(rows, key=lambda row: (row["source_file"], int(row["source_line"]), row["table"], row["key"]))


def render_inventory(rows):
    stream = io.StringIO(newline="")
    writer = csv.DictWriter(
        stream,
        fieldnames=["source_file", "source_line", "table", "key", "english", "hebrew", "disposition"],
        lineterminator="\n",
    )
    writer.writeheader()
    writer.writerows(rows)
    return stream.getvalue()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-inventory", action="store_true")
    options = parser.parse_args()
    validator = load_validator()
    try:
        catalogs = sorted(ROOT.joinpath("Sources").rglob("*.xcstrings")) + sorted(
            ROOT.joinpath("Resources/Localizations").glob("*.xcstrings")
        )
        if not catalogs:
            raise ValueError("no String Catalogs found")
        for catalog in catalogs:
            validator.validate_catalog(catalog)
        validator.validate_source_references(ROOT, catalogs, include_app=True)
        rows = inventory_rows()
        expected = render_inventory(rows)
        if options.write_inventory:
            INVENTORY.write_text(expected, encoding="utf-8")
        elif not INVENTORY.exists() or INVENTORY.read_text(encoding="utf-8") != expected:
            raise ValueError("Hebrew_String_Inventory.csv is missing or stale; regenerate with --write-inventory")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Localization check failed: {error}", file=sys.stderr)
        return 1
    print(f"Localization check passed: {len(catalogs)} catalogs, {len(rows)} inventory rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
