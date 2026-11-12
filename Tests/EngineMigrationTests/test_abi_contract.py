# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import importlib.util
import json
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
              SHAAR_LOAD(run, engine_run);
              dlsym(library, "shaar_optional_call");
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
            manifest.write_text(json.dumps({"schemaVersion": 1, "symbols": {
                "shaar_optional_call": "unspecified"
            }}))
            with self.assertRaises(CONTRACT.ContractError):
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


if __name__ == "__main__":
    unittest.main()
