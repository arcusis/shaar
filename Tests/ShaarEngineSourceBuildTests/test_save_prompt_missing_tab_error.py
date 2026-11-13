# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of this file was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Return a missing-tab error before profile or payload access."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptMissingTabErrorTests(unittest.TestCase):
    def test_unregistered_tab_returns_not_found_before_profile_lookup(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        lookup = complete.index("FindWebContents(engine, window, tab)")
        null_check = complete.index("if (!contents)", lookup)
        not_found = complete.index("SHAAR_NOT_FOUND", null_check)
        profile = complete.index("ProfileOwnsContents(", null_check)
        parse = complete.index("ParseArguments(bytes)", null_check)
        self.assertLess(lookup, null_check)
        self.assertLess(null_check, not_found)
        self.assertLess(not_found, profile)
        self.assertLess(profile, parse)


if __name__ == "__main__":
    unittest.main()
