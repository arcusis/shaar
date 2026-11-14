// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct InspectorSelectionTests {
  @Test func boundsDimensionsAndRejectsNonFiniteValues() {
    #expect(selection(width: 999_999.99).valid)
    for width in [-1.0, 1_000_000, .infinity, .nan] {
      #expect(!selection(width: width).valid)
    }
  }

  @Test func boundsAncestorAndFrameCountsAndText() {
    #expect(selection(
      frames: Array(repeating: "frame", count: 8),
      ancestors: Array(repeating: .init(id: 1, label: String(repeating: "a", count: 100)), count: 32)
    ).valid)
    #expect(!selection(frames: Array(repeating: "frame", count: 9)).valid)
    #expect(!selection(
      ancestors: Array(repeating: .init(id: 1, label: "ancestor"), count: 33)
    ).valid)
    #expect(!selection(ancestors: [.init(id: 1, label: String(repeating: "a", count: 101))]).valid)
  }

  @Test func boundsScriptAndDisplayMetadata() {
    #expect(selection(css: String(repeating: "c", count: 16_384)).valid)
    #expect(!selection(css: String(repeating: "c", count: 16_385)).valid)
    #expect(selection(label: String(repeating: "l", count: 512)).valid)
    #expect(!selection(label: String(repeating: "l", count: 513)).valid)
    #expect(selection(classNames: Array(repeating: String(repeating: "c", count: 128), count: 8)).valid)
    #expect(!selection(classNames: Array(repeating: "class", count: 9)).valid)
  }

  @Test func requiresFourBoxSidesAndBoundedColors() {
    #expect(!selection(margin: ["0", "0", "0"]).valid)
    #expect(!selection(colors: Array(repeating: swatch(), count: 9)).valid)
    #expect(!selection(colors: [swatch(label: String(repeating: "c", count: 65))]).valid)
  }

  private func selection(
    width: Double = 100, label: String = "button", css: String = "button",
    frames: [String] = [], ancestors: [InspectorSelection.Ancestor] = [],
    classNames: [String]? = [], colors: [InspectorSelection.Swatch]? = nil,
    margin: [String] = ["0", "0", "0", "0"]
  ) -> InspectorSelection {
    InspectorSelection(
      id: 1, revision: 0, locked: true, tag: "button", label: label, component: nil,
      css: css, xpath: "//button", playwright: "page.getByRole('button')", jsPath: "document.body",
      frames: frames, ancestors: ancestors,
      box: .init(
        width: width, height: 100, contentWidth: 100, contentHeight: 100,
        margin: margin, border: ["0", "0", "0", "0"], padding: ["0", "0", "0", "0"]),
      typography: .init(
        family: "sans-serif", size: "16px", weight: "400", lineHeight: "normal",
        letterSpacing: "normal", preview: "Sample"),
      colors: colors ?? [swatch()],
      foreground: .init(css: "#000", rgba: [0, 0, 0, 1]),
      backdrop: .init(css: "#fff", rgba: [1, 1, 1, 1]), contrastLimit: nil,
      classNames: classNames)
  }

  private func swatch(label: String = "Text") -> InspectorSelection.Swatch {
    .init(label: label, value: .init(css: "#000", rgba: [0, 0, 0, 1]))
  }
}
