// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct ShaarElementsShortcutTests {
  private let tenth = Decimal(string: "0.1", locale: Locale(identifier: "en_US_POSIX"))!

  @Test func commandFFocusesDOMSearch() {
    for context in [
      ShaarElementsShortcutContext.tree, .searchField, .lengthField,
    ] {
      #expect(action("f", [.command], context) == .focusSearch)
      #expect(action("F", [.command], context) == .focusSearch)
    }
    #expect(action("f", [], .tree) == nil)
    #expect(action("f", [.command, .shift], .tree) == nil)
    #expect(action("f", [.command, .option], .tree) == nil)
  }

  @Test func hTogglesVisibilityOnlyOnTheTree() {
    #expect(action("h", [], .tree) == .toggleVisibility)
    #expect(action("H", [.shift], .tree) == .toggleVisibility)
    #expect(action("h", [], .searchField) == nil)
    #expect(action("h", [], .lengthField) == nil)
    #expect(action("h", [.command], .tree) == nil)
    #expect(action("h", [.option], .tree) == nil)
    #expect(action("h", [.control], .tree) == nil)
  }

  @Test func enterOpensEditAsHTMLOnlyOnASelectedTreeRow() {
    #expect(action(.return, [], .tree) == .editAsHTML)
    #expect(action(.return, [.shift], .tree) == nil)
    #expect(action(.return, [], .searchField) == nil)
    #expect(action(.return, [], .lengthField) == nil)
  }

  @Test func arrowsNudgeAFocusedLengthByOneShiftTenAndOptionTenth() {
    #expect(action(.up, [], .lengthField) == .nudgeLength(1))
    #expect(action(.down, [], .lengthField) == .nudgeLength(-1))
    #expect(action(.up, [.shift], .lengthField) == .nudgeLength(10))
    #expect(action(.down, [.shift], .lengthField) == .nudgeLength(-10))
    #expect(action(.up, [.option], .lengthField) == .nudgeLength(tenth))
    #expect(action(.down, [.option], .lengthField) == .nudgeLength(-tenth))
    #expect(action(.up, [.option, .shift], .lengthField) == .nudgeLength(tenth))
    #expect(action(.up, [.command], .lengthField) == nil)
    #expect(action(.down, [.control], .lengthField) == nil)
    #expect(action(.up, [], .tree) == nil)
    #expect(action(.down, [.shift], .searchField) == nil)
  }

  @Test func existingShellKeysStayUntouched() {
    #expect(action("z", [.command], .tree) == nil)
    #expect(action(.delete, [], .tree) == nil)
    #expect(action(.escape, [], .tree) == nil)
    #expect(action(.escape, [], .searchField) == nil)
    #expect(action(.f12, [], .tree) == nil)
    #expect(action("i", [.command, .option], .tree) == nil)
  }

  @Test func lengthNudgeKeepsTheUnitAndTheNumberUnderTheCaret() {
    #expect(ShaarCSSLength.nudged("10px", caret: 2, by: 1) == "11px")
    #expect(ShaarCSSLength.nudged("10px", caret: 2, by: 10) == "20px")
    #expect(ShaarCSSLength.nudged("10px", caret: 2, by: tenth) == "10.1px")
    #expect(ShaarCSSLength.nudged("10px", caret: 2, by: -1) == "9px")
    #expect(ShaarCSSLength.nudged("1.5em", caret: 3, by: tenth) == "1.6em")
    #expect(ShaarCSSLength.nudged("10.25rem", caret: 5, by: 1) == "11.25rem")
    #expect(ShaarCSSLength.nudged("0", caret: 1, by: -tenth) == "-0.1")
    #expect(ShaarCSSLength.nudged("-2px", caret: 2, by: 1) == "-1px")
    #expect(ShaarCSSLength.nudged("10px 20px", caret: 9, by: 1) == "10px 21px")
    #expect(ShaarCSSLength.nudged("10px 20px", caret: 0, by: 1) == "11px 20px")
    #expect(ShaarCSSLength.nudged("padding: 12px", caret: 11, by: 1) == "padding: 13px")
    #expect(ShaarCSSLength.nudged("#112233", caret: 3, by: 1) == nil)
    #expect(ShaarCSSLength.nudged("10s", caret: 2, by: 1) == nil)
    #expect(ShaarCSSLength.nudged("auto", caret: 1, by: 1) == nil)
    #expect(ShaarCSSLength.nudged("", caret: 0, by: 1) == nil)
  }

  @Test func visibilityToggleRewritesOnlyTheVisibilityDeclaration() {
    #expect(!ShaarElementVisibility.isHidden("color: red"))
    #expect(ShaarElementVisibility.isHidden("visibility: hidden"))
    #expect(ShaarElementVisibility.isHidden("VISIBILITY: Hidden !important"))
    #expect(!ShaarElementVisibility.isHidden("visibility: visible"))
    #expect(
      ShaarElementVisibility.isHidden("background: url(\"visibility: hidden\"); visibility: hidden")
    )
    #expect(ShaarElementVisibility.toggledStyle("") == "visibility: hidden")
    #expect(ShaarElementVisibility.toggledStyle("color: red") == "color: red; visibility: hidden")
    #expect(ShaarElementVisibility.toggledStyle("color: red; visibility: hidden") == "color: red")
    #expect(ShaarElementVisibility.toggledStyle("visibility: hidden") == "")
    #expect(ShaarElementVisibility.toggledStyle("visibility: visible") == "visibility: hidden")
    #expect(
      ShaarElementVisibility.toggledStyle("background: url(\"a;b\"); color: red")
        == "background: url(\"a;b\"); color: red; visibility: hidden")
  }

  private func action(
    _ character: Character, _ modifiers: Set<ShaarElementsModifier>,
    _ context: ShaarElementsShortcutContext
  ) -> ShaarElementsShortcut? {
    ShaarElementsShortcuts.action(
      for: ShaarElementsKeyPress(key: .character(character), modifiers: modifiers), context: context
    )
  }

  private func action(
    _ key: ShaarElementsKey, _ modifiers: Set<ShaarElementsModifier>,
    _ context: ShaarElementsShortcutContext
  ) -> ShaarElementsShortcut? {
    ShaarElementsShortcuts.action(
      for: ShaarElementsKeyPress(key: key, modifiers: modifiers), context: context)
  }
}
