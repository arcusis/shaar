# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Validate the versioned save-prompt decision envelope before use."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptEnvelopeVersionTests(unittest.TestCase):
    def test_only_schema_version_one_reaches_decision_fields(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        version_guard = complete.index('args->FindInt("schemaVersion") != 1')
        invalid_envelope = complete.index('"invalid save prompt envelope"', version_guard)
        id_field = complete.index('args->FindString("id")', version_guard)
        self.assertLess(version_guard, invalid_envelope)
        self.assertLess(invalid_envelope, id_field)


if __name__ == "__main__":
    unittest.main()
