"""Keep both JavaScript dialog hooks in the ordered engine patch."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0085-shaar-javascript-dialogs.patch"


class JavaScriptDialogsPatchTests(unittest.TestCase):
    def test_message_and_beforeunload_use_embedder_manager(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        entry = next(item for item in manifest["patches"] if item["file"] == str(PATCH.relative_to(ROOT)))
        patch = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(patch).hexdigest(), entry["sha256"])
        source = patch.decode()
        self.assertIn("JavaScriptDialogManager* GetManager() __attribute__((weak_import));", source)
        self.assertEqual(source.count('HasSwitch("shaar-embedder")'), 2)
        self.assertEqual(source.count("dialog_manager = shaar::javascript_dialogs::GetManager();"), 2)
        self.assertIn("// While a JS message dialog is showing", source)
        self.assertIn("// While a JS beforeunload dialog is showing", source)


if __name__ == "__main__":
    unittest.main()
