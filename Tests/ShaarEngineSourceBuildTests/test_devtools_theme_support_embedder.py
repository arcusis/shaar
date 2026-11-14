# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Guard Shaar theme propagation to DevTools-owned documents."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
THEME = ROOT / "ThirdParty/ChromiumEngine/patches/0064-shaar-devtools-theme-157.patch"
THEME_SUPPORT = (
    "third_party/devtools-frontend/src/front_end/ui/legacy/theme_support/ThemeSupport.ts"
)


def theme_support_patch() -> str:
    patch = THEME.read_text()
    section = patch.split(f"--- a/{THEME_SUPPORT}\n", 1)[1]
    return section.split("\n--- a/", 1)[0]


class DevToolsThemeSupportEmbedderTests(unittest.TestCase):
    def test_shaar_theme_is_applied_to_every_registered_document(self):
        source = theme_support_patch()
        method = source.split("addDocumentToTheme(document: Document): void {", 1)[1]
        method = method.split("\n   }", 1)[0]
        self.assertIn("if (Root.Runtime.hostConfig.isShaarEmbedder)", method)
        self.assertIn("document.documentElement.classList.add('shaar-theme');", method)
        self.assertLess(
            method.index("classList.add('shaar-theme')"),
            method.index("this.#documentsToTheme.add(document)"),
        )
        self.assertIn("this.#fetchColorsAndApplyHostTheme(document)", method)


if __name__ == "__main__":
    unittest.main()
