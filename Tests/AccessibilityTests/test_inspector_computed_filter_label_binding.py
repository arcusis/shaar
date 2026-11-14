from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InspectorComputedFilterLabelBindingTests(unittest.TestCase):
    def test_computed_filter_field_keeps_localized_accessibility_label(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorStylesView.swift").read_text(
            encoding="utf-8"
        )

        self.assertRegex(
            source,
            re.compile(
                r'TextField\(InspectorL10n\.string\("Filter properties"\),\s*'
                r'text: \$model\.filter\)[\s\S]{0,180}'
                r'\.accessibilityLabel\(InspectorL10n\.string\("Filter properties"\)\)'
            ),
        )


if __name__ == "__main__":
    unittest.main()
