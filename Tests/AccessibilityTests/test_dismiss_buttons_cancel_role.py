from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DismissButtonCancelRoleTests(unittest.TestCase):
    def test_done_controls_keep_native_cancel_semantics(self):
        sources = (
            "Sources/ArcusisBrowser/DownloadsPanel.swift",
            "Sources/ArcusisBrowser/RecentlyClosedPanel.swift",
            "Sources/ArcusisBrowser/LibraryPanel.swift",
            "Sources/ArcusisBrowser/PageFindBar.swift",
        )
        for relative_path in sources:
            with self.subTest(source=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                self.assertIn(
                    'Button(PanelsL10n.string("Done"), role: .cancel)', source
                )


if __name__ == "__main__":
    unittest.main()
