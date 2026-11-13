# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fail closed when save-prompt profile ownership cannot be established."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptProfileFailClosedTests(unittest.TestCase):
    def test_missing_ownership_services_never_grant_scope(self):
        source = SOURCE.read_text()
        start = source.index("bool ProfileOwnsContents(")
        end = source.index("}  // namespace", start)
        ownership = source[start:end]

        guard = ownership.index("if (!context || !context->profile_services")
        reject = ownership.index("return false;", guard)
        resolution = ownership.index("ResolveProfile(engine, scope.profile)", reject)
        self.assertLess(guard, reject)
        self.assertLess(reject, resolution)
        self.assertNotIn("return true;", ownership)
        for required in ("!scope.profile", "!contents"):
            with self.subTest(required=required):
                self.assertIn(required, ownership[guard:reject])


if __name__ == "__main__":
    unittest.main()
