// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct InspectorSelection: Decodable, Equatable {
  struct Ancestor: Decodable, Equatable, Identifiable {
    let id: Int
    let label: String
    var tag: String? = nil
    var identifier: String? = nil

    var displayLabel: String {
      let element = tag ?? String(label.prefix { $0 != "." && $0 != "#" })
      guard let identifier, !identifier.isEmpty else { return element }
      return element + "#" + identifier
    }
  }
  struct Box: Decodable, Equatable {
    let width: Double
    let height: Double
    let contentWidth: Double
    let contentHeight: Double
    let margin: [String]
    let border: [String]
    let padding: [String]
  }
  struct Typography: Decodable, Equatable {
    let family: String
    let size: String
    let weight: String
    let lineHeight: String
    let letterSpacing: String
    let preview: String
  }
  struct Swatch: Decodable, Equatable, Identifiable {
    let label: String
    let value: InspectorColor
    var id: String { label }
  }
  let id: Int
  let revision: Int
  let locked: Bool
  let tag: String
  let label: String
  let component: String?
  let css: String
  let xpath: String
  let playwright: String
  let jsPath: String
  let frames: [String]
  let ancestors: [Ancestor]
  let box: Box
  let typography: Typography
  let colors: [Swatch]
  let foreground: InspectorColor
  let backdrop: InspectorColor
  let contrastLimit: String?
  var renderedFonts: [String] = []
  var pageFonts: [String] = []
  var fontsAvailable = false
  var display: String? = nil
  var identifier: String? = nil
  var classNames: [String]? = nil

  enum CodingKeys: String, CodingKey {
    case id, revision, locked, tag, label, component, css, xpath, playwright, jsPath, frames,
      ancestors
    case box, typography, colors, foreground, backdrop, contrastLimit
    case display
    case identifier, classNames
  }
  var valid: Bool {
    id > 0 && revision >= 0 && ancestors.count <= 32 && frames.count <= 8
      && [box.width, box.height, box.contentWidth, box.contentHeight].allSatisfy {
        $0.isFinite && $0 >= 0 && $0 < 1_000_000
      }
      && [box.margin, box.border, box.padding].allSatisfy {
        $0.count == 4 && $0.allSatisfy { $0.count <= 64 }
      }
      && [css, xpath, playwright, jsPath].allSatisfy { $0.count <= 16_384 }
      && ancestors.allSatisfy {
        $0.id > 0 && $0.label.count <= 100 && ($0.tag?.count ?? 0) <= 128
          && ($0.identifier?.count ?? 0) <= 128
      }
      && frames.allSatisfy { $0.count <= 16_384 }
      && colors.count <= 8 && colors.allSatisfy { $0.label.count <= 64 && $0.value.valid }
      && foreground.valid && backdrop.valid && label.count <= 512 && tag.count <= 128
      && (component?.count ?? 0) <= 512 && (contrastLimit?.count ?? 0) <= 512
      && typography.family.count <= 512 && typography.preview.count <= 300
      && (identifier?.count ?? 0) <= 128 && (classNames?.count ?? 0) <= 8
      && (classNames ?? []).allSatisfy { $0.count <= 128 }
      && (display?.count ?? 0) <= 64
      && [typography.size, typography.weight, typography.lineHeight, typography.letterSpacing]
        .allSatisfy { $0.count <= 128 }
  }
  var dimensions: String {
    "\(InspectorColor.number(box.width.rounded())) × \(InspectorColor.number(box.height.rounded()))"
  }
  var contrast: Double? { contrastLimit == nil ? foreground.contrast(on: backdrop) : nil }
  var largeText: Bool {
    let size = Double(typography.size.replacingOccurrences(of: "px", with: "")) ?? 0
    let weight = Double(typography.weight) ?? 400
    return size >= 24 || (size >= 18.6667 && weight >= 700)
  }
  var contrastGrade: String? {
    guard let contrast else { return nil }
    if contrast >= (largeText ? 4.5 : 7) { return "AAA" }
    if contrast >= (largeText ? 3 : 4.5) { return "AA" }
    return "Fail"
  }
}
