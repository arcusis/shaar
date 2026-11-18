# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Host-caused tab activations are tagged and matched against the bridge target."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
TABS = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs"
BRIDGE = ROOT / "Sources/ChromiumBridge/ChromiumShaarBackend.mm"
ACTIVATION = ROOT / "Sources/ChromiumBridge/ChromiumShaarActivation.mm"


class HostActivationSourceTests(unittest.TestCase):
    def test_activate_tab_operation_scopes_its_tab_strip_change(self):
        handler = (TABS / "shaar_windows_tabs_handlers.cc").read_text()
        scope = handler.index("ScopedHostActivation host_activation;")
        self.assertLess(scope, handler.index("call->tab_strip_model->ActivateTabAt(index);"))

    def test_activation_event_carries_the_host_source(self):
        lifecycle = (TABS / "shaar_windows_tabs_lifecycle.cc").read_text()
        self.assertIn('if (shaar::windows_tabs::HostActivationInProgress())\n      payload.Set("source", "host");',
                      lifecycle)

    def test_bridge_drops_only_host_activation_for_its_current_target(self):
        bridge = BRIDGE.read_text()
        activated = bridge.index('[kind isEqualToString:@"activated"]')
        target_check = bridge.index("if (ARCShouldIgnoreHostTabActivation(", activated)
        callback = bridge.index("self.onTabActivated(tabID, profileID);", target_check)
        self.assertLess(activated, target_check)
        self.assertLess(target_check, callback)
        self.assertIn('_shaarSelectedTabs[windowID]', bridge[target_check:callback])

        activation = ACTIVATION.read_text()
        self.assertIn(
            '[source isEqual:@"host"] && [tabID isEqualToString:hostTargetTabID]',
            activation,
        )


if __name__ == "__main__":
    unittest.main()
