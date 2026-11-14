// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

enum PrintDocumentTitle {
  static func make(pageTitle: String?, productName: String = ProductIdentity.name) -> String {
    let scalars = (pageTitle ?? "").unicodeScalars.map { scalar -> Unicode.Scalar in
      if CharacterSet.controlCharacters.contains(scalar) && !isJoiner(scalar) && !isEmojiTag(scalar)
        || isBidirectionalControl(scalar)
        || scalar.properties.generalCategory == .lineSeparator
        || scalar.properties.generalCategory == .paragraphSeparator || scalar == "/"
      {
        return " "
      }
      return scalar
    }
    let title = String(String.UnicodeScalarView(scalars))
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return title.isEmpty ? productName : String(title.prefix(120))
  }

  private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value == 0x200C || scalar.value == 0x200D
  }

  private static func isEmojiTag(_ scalar: Unicode.Scalar) -> Bool {
    (0xE0000...0xE007F).contains(scalar.value)
  }

  private static func isBidirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    return value == 0x061C || value == 0x200E || value == 0x200F
      || (0x202A...0x202E).contains(value) || (0x2066...0x206F).contains(value)
  }
}

struct PrintDocumentTitleWindowBridge: NSViewRepresentable {
  let pageTitle: String?

  func makeNSView(context: Context) -> PrintDocumentTitleView {
    PrintDocumentTitleView(pageTitle: pageTitle)
  }

  func updateNSView(_ view: PrintDocumentTitleView, context: Context) {
    view.setPageTitle(pageTitle)
  }
}

final class PrintDocumentTitleView: NSView {
  private var pageTitle: String?

  init(pageTitle: String?) {
    self.pageTitle = pageTitle
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func setPageTitle(_ pageTitle: String?) {
    self.pageTitle = pageTitle
    updateWindowTitle()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateWindowTitle()
  }

  private func updateWindowTitle() {
    window?.title = PrintDocumentTitle.make(pageTitle: pageTitle)
  }
}
