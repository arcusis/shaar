# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Guard the removal of Google feedback links from Shaar DevTools."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
THEME = ROOT / "ThirdParty/ChromiumEngine/patches/0064-shaar-devtools-theme-157.patch"


def patch_section(path: str) -> str:
    patch = THEME.read_text()
    section = patch.split(f"--- a/{path}\n", 1)[1]
    return section.split("\n--- a/", 1)[0]


class DevToolsFeedbackEntryTests(unittest.TestCase):
    def test_settings_experiment_feedback_is_hidden_for_shaar(self):
        source = patch_section(
            "third_party/devtools-frontend/src/front_end/panels/settings/SettingsScreen.ts")
        self.assertIn(
            "experiment.feedbackLink && !Root.Runtime.hostConfig.isShaarEmbedder", source)
        self.assertIn('class="feedback-link"', source)

    def test_autofill_feedback_is_hidden_for_shaar(self):
        source = patch_section(
            "third_party/devtools-frontend/src/front_end/panels/autofill/AutofillView.ts")
        function = source.split("function renderAutofillFeedback()", 1)[1].split("\n+}", 1)[0]
        self.assertIn("Root.Runtime.hostConfig.isShaarEmbedder", function)
        self.assertIn("return Lit.nothing;", function)

    def test_recorder_feedback_is_hidden_for_shaar(self):
        source = patch_section(
            "third_party/devtools-frontend/src/front_end/panels/recorder/RecorderPanel.ts")
        function = source.split("function renderRecorderFeedback()", 1)[1].split("\n+}", 1)[0]
        self.assertIn("Root.Runtime.hostConfig.isShaarEmbedder", function)
        self.assertIn("return nothing;", function)


if __name__ == "__main__":
    unittest.main()
