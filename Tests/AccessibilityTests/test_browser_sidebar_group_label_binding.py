from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BrowserSidebarGroupLabelBindingTests(unittest.TestCase):
    def test_sidebar_container_uses_its_localized_accessibility_name(self):
        source = (ROOT / "Sources/ArcusisBrowser/BrowserSidebar.swift").read_text(
            encoding="utf-8"
        )

        self.assertRegex(
            source,
            re.compile(
                r"\.accessibilityElement\(children: \.contain\)\s*"
                r"\.accessibilityLabel\(Self\.accessibilityGroupLabel\(\)\)"
            ),
        )


if __name__ == "__main__":
    unittest.main()
