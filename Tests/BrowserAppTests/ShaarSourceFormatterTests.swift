// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Test func sourceFormatterSortsAndPrettyPrintsJSON() {
  #expect(
    ShaarSourceFormatter.format(#"{"z":1,"a":{"y":2,"b":true}}"#, kind: .json)
      == "{\n  \"a\" : {\n    \"b\" : true,\n    \"y\" : 2\n  },\n  \"z\" : 1\n}")
  #expect(ShaarSourceFormatter.format("not json", kind: .json) == "not json")
}

@Test func sourceFormatterPreservesDelimitersInsideLiteralsAndComments() {
  let source = "const pattern=/a;b{2}/g;const text='x;y{z}';// ; { ignored\nrun()"
  let formatted = ShaarSourceFormatter.format(source, kind: .script)

  #expect(formatted.contains("const pattern=/a;b{2}/g;\n"))
  #expect(formatted.contains("const text='x;y{z}';\n"))
  #expect(formatted.contains("// ; { ignored\nrun()"))
}

@Test func sourceFormatterKeepsForLoopSeparatorsInsideParentheses() {
  let formatted = ShaarSourceFormatter.format("for(let i=0;i<2;i++){run(i)}", kind: .script)

  #expect(formatted == "for(let i=0;i<2;i++){\n  run(i)\n}\n")
}

@Test func sourceFormatterLeavesOversizedSourceUntouched() {
  let source = String(repeating: "x", count: ShaarSourceFormatter.maximumBytes + 1)
  #expect(ShaarSourceFormatter.format(source, kind: .style) == source)
}

@Test func sourceFormatterBoundsIndentationForDeeplyNestedInput() {
  let source = String(repeating: "{", count: 10_000)
  let formatted = ShaarSourceFormatter.format(source, kind: .script)
  let maximumIndentation = formatted.components(separatedBy: "\n").map {
    $0.prefix(while: { $0 == " " }).count
  }.max() ?? 0

  #expect(maximumIndentation <= 64)
  #expect(formatted.utf8.count < 1_000_000)
}
