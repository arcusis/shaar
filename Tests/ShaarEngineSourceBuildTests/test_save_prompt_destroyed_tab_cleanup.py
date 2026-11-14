# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Release pending native save callbacks as soon as their tab closes."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROMPTS = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/shaar_save_prompts.cc"
HEADER = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/shaar_save_prompts.h"
LIFECYCLE = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/shaar_windows_tabs_lifecycle.cc"


class SavePromptDestroyedTabCleanupTests(unittest.TestCase):
    def test_tab_destruction_dismisses_pending_prompts_before_unbinding(self):
        source = LIFECYCLE.read_text()
        callback = source[source.index("void WebContentsDestroyed() override {"):]
        dismiss = callback.index("DismissSavePromptsForDestroyedContents(")
        unbind = callback.index("UnbindTab(engine, window, this)")
        self.assertLess(dismiss, unbind)
        prompts = PROMPTS.read_text()
        start = prompts.index("void DismissSavePromptsForDestroyedContents(")
        end = prompts.index("int DecisionCode(", start)
        self.assertIn("SupersedeSavePrompts(contents);", prompts[start:end])
        self.assertIn("Supersede(contents);", prompts[prompts.index("void SupersedeSavePrompts("):start])
        self.assertIn("void DismissSavePromptsForDestroyedContents(content::WebContents* contents);", HEADER.read_text())


if __name__ == "__main__":
    unittest.main()
