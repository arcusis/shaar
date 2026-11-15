# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Do not decide save prompts without being able to verify profile ownership."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptProfileServiceRequiredTests(unittest.TestCase):
    def test_missing_profile_services_fails_before_resolving_or_consuming(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        handler = source[start:end]
        check = handler.index("if (!context->profile_services)")
        not_ready = handler.index("SHAAR_NOT_READY", check)
        tab_lookup = handler.index("FindWebContents(engine, window, tab)")
        profile_check = handler.index(
            "ProfileOwnsContents(context, engine, scope, contents)"
        )
        parse = handler.index("ParseArguments(bytes)")
        take = handler.index("TakeDecision(engine, contents")
        self.assertLess(check, not_ready)
        self.assertLess(not_ready, tab_lookup)
        self.assertLess(tab_lookup, profile_check)
        self.assertLess(profile_check, parse)
        self.assertLess(parse, take)

    def test_profile_ownership_helper_does_not_allow_missing_services(self):
        start = SOURCE.read_text().index("bool ProfileOwnsContents(")
        end = SOURCE.read_text().index("}  // namespace", start)
        helper = SOURCE.read_text()[start:end]
        self.assertIn("!context->profile_services", helper)
        self.assertIn("return false;", helper)
        self.assertNotIn("return true;", helper)


if __name__ == "__main__":
    unittest.main()
