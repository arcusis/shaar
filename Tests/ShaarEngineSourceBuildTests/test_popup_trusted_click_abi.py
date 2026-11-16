# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PUBLIC_ABI = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"
BRIDGE = ROOT / "Sources/ChromiumBridgeVerification/ChromiumBridgeVerification.mm"


class PopupTrustedClickABIContractTests(unittest.TestCase):
    def test_verification_popup_click_uses_public_engine_operation(self):
        abi = PUBLIC_ABI.read_text()
        bridge = BRIDGE.read_text()
        self.assertRegex(abi, r"\bSHAAR_OP_PROBE_POPUP_TRUSTED_CLICK\s*=\s*1098\b")
        self.assertTrue(
            re.search(
                r"\bkProbePopupTrustedClickOperation\s*=\s*"
                r"SHAAR_OP_PROBE_POPUP_TRUSTED_CLICK\s*;",
                bridge,
            ),
            "verification popup click must bind the public popup-click operation",
        )
        click_method = bridge[
            bridge.rindex("- (void)clickProbePopupID:(NSString *)popupID buttonTitle:"):
        ].split("- (void)clickProbeElementInTabID", 1)[0]
        self.assertIn("shaarDevToolsSubmit:kProbePopupTrustedClickOperation", click_method)


if __name__ == "__main__":
    unittest.main()
