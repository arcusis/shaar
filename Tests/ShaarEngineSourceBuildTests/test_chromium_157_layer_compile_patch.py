# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep pinned Chromium 157 layer API fixes in the replayed patch series."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0152-shaar-chromium-157-layer-compile.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class Chromium157LayerCompilePatchTests(unittest.TestCase):
    def test_patch_is_pinned_and_has_matching_digest(self):
        entries = json.loads(MANIFEST.read_text())["patches"]
        matches = [entry for entry in entries if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(1, len(matches))
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), matches[0]["sha256"])

    def test_pinned_api_corrections_are_replayed(self):
        patch = PATCH.read_text()
        for correction in (
            "+        ldflags += [ \"-Wcrl,installnametool,-change,@executable_path/../Frameworks/$chrome_product_full_name Framework.framework",
            "+    base::MakeRefCounted<ProbeTrustedInput>(",
            "+  struct PendingRules {",
            "+                       base::DictValue payload;",
            "+              url::Origin::Create(contents->GetLastCommittedURL()).Serialize());",
            "+    content::LoginDelegate::LoginAuthRequiredCallback callback) {",
            "+#include \"content/public/browser/render_process_host.h\"",
            "+void Expire(std::string id) { Finish(id, blink::mojom::ShareError::CANCELED); }",
            "+  auto* manager = printing::PrintViewManager::FromWebContents(contents);",
        ):
            with self.subTest(correction=correction):
                self.assertIn(correction, patch)


if __name__ == "__main__":
    unittest.main()
