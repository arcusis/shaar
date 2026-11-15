# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep the agent bridge bound to the pinned Chromium DevTools APIs."""

from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0016-shaar-agent-bridge.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class AgentBridgePatchTests(unittest.TestCase):
    def test_remote_bridge_rejects_ungranted_http_and_websocket_traffic(self):
        patch = PATCH.read_text()
        self.assertNotIn("ardia", patch.lower())
        for guard in (
            'request.path != browser_guid_',
            'request.headers.count("origin")',
            'g_shaar_agent_bridge_accepts(',
            'shaar_agent_mode_ ? 65536 : kReceiveBufferSizeForDevTools',
            'if (shaar_agent_mode_ && data.size() > 65536)',
            'if (shaar_agent_mode_ ||',
            'shaar_agent_client_->FilterCommand(command, &reply)',
            'shaar_agent_client_->FilterEvent(text)',
            'g_shaar_agent_bridge_may_attach(',
            'g_shaar_agent_bridge_may_input(',
        ):
            self.assertIn(guard, patch)

    def test_patch_digest_is_pinned(self):
        self.assertTrue(PATCH.read_text().startswith(
            '--- /dev/null\n+++ b/content/public/browser/shaar_agent_bridge.h\n'
        ))
        patches = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
