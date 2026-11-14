from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InspectorStorageSelectionBindingTests(unittest.TestCase):
    def test_selected_trait_is_attached_to_storage_entry_button(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorStorageView.swift").read_text(
            encoding="utf-8"
        )
        entry = source.split("private func entry(", 1)[1].split("private func select(", 1)[0]

        self.assertIn("Button(action: action)", entry)
        self.assertIn(
            ".accessibilityAddTraits(Self.entryAccessibilityTraits(isSelected: selected == id))",
            entry,
        )


if __name__ == "__main__":
    unittest.main()
