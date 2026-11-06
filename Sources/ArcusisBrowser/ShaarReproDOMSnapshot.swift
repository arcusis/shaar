// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

@MainActor enum ShaarReproDOMSnapshot {
  static let expression = """
    (() => {
      const root = document.body || document.documentElement;
      if (!root) throw new Error('Document unavailable');
      let count = 0;
      let textBytes = 0;
      const visit = (element, depth) => {
        if (++count > 1000 || depth > 32) throw new Error('DOM limit exceeded');
        const tag = element.localName.slice(0, 64);
        if (element.matches('form,input,textarea,select,option,[contenteditable]') ||
            element.isContentEditable) {
          return {tag, text: '[redacted]', attributes: {}, children: []};
        }
        if (element.matches('script,style,noscript,template')) {
          return {tag, text: '', attributes: {}, children: []};
        }
        let text = '';
        for (const child of element.childNodes) {
          if (child.nodeType === Node.TEXT_NODE) text += child.textContent;
        }
        text = text.slice(0, 4096);
        textBytes += new TextEncoder().encode(text).length;
        if (textBytes > 96000) throw new Error('DOM text limit exceeded');
        const children = [];
        for (const child of element.children) {
          if (children.length >= 500) throw new Error('DOM child limit exceeded');
          children.push(visit(child, depth + 1));
        }
        return {tag, text, attributes: {}, children};
      };
      return visit(root, 0);
    })()
    """

  static func capture(_ inspector: InspectorModel, target: SiteControlTarget) async throws
    -> ShaarReproDOMNode
  {
    guard inspector.isOpen, inspector.target == target else { throw CancellationError() }
    let generation = inspector.documentGeneration
    let value = try await inspector.evaluate(expression)
    guard inspector.isOpen, inspector.target == target,
      inspector.documentGeneration == generation, let value,
      JSONSerialization.isValidJSONObject(value)
    else { throw CancellationError() }
    let data = try JSONSerialization.data(withJSONObject: value)
    guard data.count <= 128 * 1024 else { throw ShaarReproDOMError.invalid }
    return try decode(data)
  }

  static func decode(_ data: Data) throws -> ShaarReproDOMNode {
    guard data.count <= 128 * 1024 else { throw ShaarReproDOMError.invalid }
    let root = try JSONDecoder().decode(ShaarReproDOMNode.self, from: data)
    var count = 0
    try validate(root, depth: 0, count: &count)
    return root.redacted()
  }

  private static func validate(_ node: ShaarReproDOMNode, depth: Int, count: inout Int) throws {
    count += 1
    guard count <= 1000, depth <= 32, node.tag.utf8.count <= 64,
      node.text.utf8.count <= 4096, node.attributes.isEmpty,
      node.children.count <= 500
    else { throw ShaarReproDOMError.invalid }
    let tag = node.tag.lowercased()
    if ["form", "input", "textarea", "select", "option"].contains(tag) {
      guard node.text == "[redacted]", node.children.isEmpty
      else { throw ShaarReproDOMError.invalid }
    }
    for child in node.children { try validate(child, depth: depth + 1, count: &count) }
  }
}

private enum ShaarReproDOMError: Error { case invalid }
