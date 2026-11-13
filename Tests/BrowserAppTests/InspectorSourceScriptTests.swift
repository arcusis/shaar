// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import JavaScriptCore
import Testing

@testable import ArcusisBrowser

struct InspectorSourceScriptTests {
  @Test func sourceHintScriptParsesAsJavaScript() throws {
    let context = try #require(JSContext())
    let parses = context.evaluateScript("source => { new Function(source); return true; }")?
      .call(withArguments: [InspectorSourceScript.install])?.toBool()

    #expect(parses == true)
    #expect(context.exception == nil)
  }
}
