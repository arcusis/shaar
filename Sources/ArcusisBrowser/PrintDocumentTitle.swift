// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

enum PrintDocumentTitle {
  static func make(pageTitle: String?, productName: String = ProductIdentity.name) -> String {
    let title = (pageTitle ?? "")
      .components(separatedBy: .controlCharacters)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? productName : String(title.prefix(120))
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
