# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import importlib.util
import json
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_engine_abi_contract", ROOT / "scripts/check-engine-abi-contract.py")
CONTRACT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CONTRACT
SPEC.loader.exec_module(CONTRACT)


class EngineABIContractTests(unittest.TestCase):
    def test_collects_macro_and_dlsym_symbols_and_routed_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bridge = root / "Sources/ChromiumBridge"
            bridge.mkdir(parents=True)
            (bridge / "Bridge.mm").write_text('''
              #define SHAAR_LOAD(field, symbol) dlsym(library, "shaar_" #symbol)
              SHAAR_LOAD(run, engine_run);
              dlsym(library, "shaar_optional_call");
              const char *diagnostic = "shaar_not_an_abi_lookup";
              if (event->kind == SHAAR_EVENT_MEDIA) submit(SHAAR_OP_MEDIA_CONTROL);
            ''')
            self.assertEqual(CONTRACT.collect_bridge_symbols(root),
                             {"shaar_engine_run", "shaar_optional_call"})
            self.assertEqual(CONTRACT.collect_routes(root),
                             ({"SHAAR_EVENT_MEDIA"}, {"SHAAR_OP_MEDIA_CONTROL"}))

    def test_parses_event_and_operation_declarations_from_shipped_header(self):
        header = '''
          typedef enum { SHAAR_EVENT_MEDIA = 15 } shaar_event_kind;
          typedef enum { SHAAR_OP_MEDIA_CONTROL = 1200 } shaar_operation;
        '''
        self.assertEqual(CONTRACT.parse_header_enums(header),
                         ({"SHAAR_EVENT_MEDIA"}, {"SHAAR_OP_MEDIA_CONTROL"}))

    def test_optional_symbol_requires_a_minimum_engine_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "ThirdParty/ChromiumEngine"
            folder.mkdir(parents=True)
            manifest = folder / "abi-optional-symbols.json"
            manifest.write_text(json.dumps({"schemaVersion": 1, "symbols": {
                "shaar_optional_call": "engine-157.0.8103.51-shaar.33"
            }}))
            self.assertEqual(CONTRACT.optional_symbols(root)["shaar_optional_call"],
                             "engine-157.0.8103.51-shaar.33")
            for version in ("unspecified", "engine-157..0.8103.51-shaar.33",
                            "engine-157.0.-8103.51-shaar.33", "engine-157.0.8103.51-shaar.0"):
                manifest.write_text(json.dumps({"schemaVersion": 1, "symbols": {
                    "shaar_optional_call": version
                }}))
                with self.subTest(version=version), self.assertRaises(CONTRACT.ContractError):
                    CONTRACT.optional_symbols(root)

    def test_archive_must_match_pin_before_symbol_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pin_dir = root / "ThirdParty/ChromiumEngine"
            pin_dir.mkdir(parents=True)
            archive = root / "pinned.tar.xz"
            archive.write_bytes(b"fixture")
            (pin_dir / "pin.json").write_text(json.dumps({
                "asset": archive.name, "sha256": hashlib.sha256(b"different").hexdigest()
            }))
            with self.assertRaisesRegex(CONTRACT.ContractError, "does not match"):
                CONTRACT.check_contract(root, archive, nm=lambda _: set())

    def test_archive_member_discovery_accepts_framework_header_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "fixture.tar.xz"
            with tarfile.open(archive_path, "w:xz") as archive:
                header_data = b"header"
                header = tarfile.TarInfo("Framework/Versions/A/Headers/shaar_engine.h")
                header.size = len(header_data)
                archive.addfile(header, io.BytesIO(header_data))
                link = tarfile.TarInfo("Framework/Headers/shaar_engine.h")
                link.type = tarfile.SYMTYPE
                link.linkname = "../Versions/A/Headers/shaar_engine.h"
                archive.addfile(link)
                binary_data = b"framework"
                binary = tarfile.TarInfo("Framework/Versions/A/Chromium Framework")
                binary.size = len(binary_data)
                archive.addfile(binary, io.BytesIO(binary_data))
            self.assertEqual(CONTRACT.archive_members(archive_path), (
                {"Framework/Headers/shaar_engine.h", "Framework/Versions/A/Headers/shaar_engine.h"},
                "Framework/Versions/A/Chromium Framework"))

    def test_archive_member_discovery_rejects_ambiguous_framework_binaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "fixture.tar.xz"
            with tarfile.open(archive_path, "w:xz") as archive:
                for name in ("Framework/Chromium Framework", "Other/Chromium Framework"):
                    payload = name.encode()
                    entry = tarfile.TarInfo(name)
                    entry.size = len(payload)
                    archive.addfile(entry, io.BytesIO(payload))

            with self.assertRaisesRegex(CONTRACT.ContractError, "exactly one Chromium Framework binary"):
                CONTRACT.archive_members(archive_path)

    def test_source_build_header_is_digest_checked_and_includes_pinned_patch_declarations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            layer = root / "ThirdParty/ChromiumEngine/layer"
            header_path = layer / CONTRACT.PUBLIC_HEADER
            header_path.parent.mkdir(parents=True)
            header_path.write_text('''
              typedef enum { SHAAR_EVENT_MEDIA = 15 } shaar_event_kind;
              typedef enum { SHAAR_OP_MEDIA_CONTROL = 1200 } shaar_operation;
            ''')
            relative_patch = "ThirdParty/ChromiumEngine/patches/0001-abi.patch"
            patch_path = root / relative_patch
            patch_path.parent.mkdir(parents=True)
            patch = '''--- a/chrome/browser/shaar/public/shaar_engine.h
+++ b/chrome/browser/shaar/public/shaar_engine.h
@@ -2,1 +2,2 @@
 typedef enum { SHAAR_OP_MEDIA_CONTROL = 1200 } shaar_operation;
+  SHAAR_OP_ADDED_BY_PATCH = 1201,
'''
            patch_path.write_text(patch)
            header_relative = "chrome/browser/shaar/public/shaar_engine.h"
            manifest = {
                "chromium": {"version": "157.0.8103.51"},
                "layer": {"path": "ThirdParty/ChromiumEngine/layer", "files": {
                    header_relative: hashlib.sha256(header_path.read_bytes()).hexdigest()
                }},
                "patches": [{"file": relative_patch,
                             "sha256": hashlib.sha256(patch.encode()).hexdigest()}],
            }
            (root / "ThirdParty/ChromiumEngine/source-build.json").write_text(json.dumps(manifest))
            events, operations, origin = CONTRACT.source_build_header(root, {
                "releaseTag": "engine-157.0.8103.51-shaar.32"
            })
            self.assertEqual(events, {"SHAAR_EVENT_MEDIA"})
            self.assertEqual(operations, {"SHAAR_OP_MEDIA_CONTROL", "SHAAR_OP_ADDED_BY_PATCH"})
            self.assertIn("hash-verified source-build header", origin)

    def test_source_build_header_rejects_patch_paths_outside_repository(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            header_path = root / "ThirdParty/ChromiumEngine/layer" / CONTRACT.PUBLIC_HEADER
            header_path.parent.mkdir(parents=True)
            header_path.write_text('''
              typedef enum { SHAAR_EVENT_MEDIA = 15 } shaar_event_kind;
              typedef enum { SHAAR_OP_MEDIA_CONTROL = 1200 } shaar_operation;
            ''')
            outside = root.parent / "outside-abi.patch"
            outside.write_text("not an ABI patch")
            relative_header = CONTRACT.PUBLIC_HEADER
            manifest = {
                "chromium": {"version": "157.0.8103.51"},
                "layer": {"path": "ThirdParty/ChromiumEngine/layer", "files": {
                    relative_header: hashlib.sha256(header_path.read_bytes()).hexdigest()
                }},
                "patches": [{"file": "../outside-abi.patch",
                             "sha256": hashlib.sha256(outside.read_bytes()).hexdigest()}],
            }
            (root / "ThirdParty/ChromiumEngine/source-build.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(CONTRACT.ContractError, "escapes the repository"):
                CONTRACT.source_build_header(root, {"releaseTag": "engine-157.0.8103.51-shaar.32"})

    def test_source_build_header_rejects_patch_symlink_loops(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            header_path = root / "ThirdParty/ChromiumEngine/layer" / CONTRACT.PUBLIC_HEADER
            header_path.parent.mkdir(parents=True)
            header_path.write_text('''
              typedef enum { SHAAR_EVENT_MEDIA = 15 } shaar_event_kind;
              typedef enum { SHAAR_OP_MEDIA_CONTROL = 1200 } shaar_operation;
            ''')
            patch_path = root / "ThirdParty/ChromiumEngine/patches/loop.patch"
            patch_path.parent.mkdir(parents=True)
            patch_path.symlink_to("loop.patch")
            relative_header = CONTRACT.PUBLIC_HEADER
            manifest = {
                "chromium": {"version": "157.0.8103.51"},
                "layer": {"path": "ThirdParty/ChromiumEngine/layer", "files": {
                    relative_header: hashlib.sha256(header_path.read_bytes()).hexdigest()
                }},
                "patches": [{"file": "ThirdParty/ChromiumEngine/patches/loop.patch", "sha256": "unused"}],
            }
            (root / "ThirdParty/ChromiumEngine/source-build.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(CONTRACT.ContractError, "escapes the repository"):
                CONTRACT.source_build_header(root, {"releaseTag": "engine-157.0.8103.51-shaar.32"})


if __name__ == "__main__":
    unittest.main()
