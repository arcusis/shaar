// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation

struct PickedElement: Equatable {
  let css: String
  let xpath: String
  let playwright: String
  let frames: [String]
  let tag: String
  let width: Double
  let height: Double
  let framework: String?
  let component: String?
  let source: String?

  init?(_ value: [String: Any]) {
    guard let css = value["css"] as? String, let xpath = value["xpath"] as? String,
      let locator = value["locator"] as? [String: Any], let code = locator["code"] as? String,
      css.utf8.count <= 32768, xpath.utf8.count <= 32768, code.utf8.count <= 65536,
      let width = value["width"] as? Double, let height = value["height"] as? Double,
      width.isFinite, height.isFinite, width >= 0, height >= 0,
      width <= Double(Int32.max), height <= Double(Int32.max)
    else { return nil }
    self.css = css
    self.xpath = xpath
    playwright = code
    frames = Array((value["frames"] as? [String] ?? []).prefix(64))
    tag = String((value["tag"] as? String ?? "element").prefix(128))
    self.width = width
    self.height = height
    let metadata = value["component"] as? [String: Any]
    framework = (metadata?["framework"] as? String).map { String($0.prefix(128)) }
    component = (metadata?["name"] as? String).map { String($0.prefix(512)) }
    source = (metadata?["source"] as? String).map { String($0.prefix(2048)) }
  }
}

extension SiteControlsDeveloperModel {
  func startPicker() async {
    pickerRevision += 1
    let revision = pickerRevision
    pickerEnabled = false
    pickerFailure = nil
    pickedElement = nil
    do {
      _ = try await evaluate(ElementPickerScript.install)
      guard revision == pickerRevision else { return }
      pickerEnabled = true
    } catch {
      if revision == pickerRevision { pickerFailure = error.localizedDescription }
    }
  }

  func stopPicker() {
    pickerRevision += 1
    let revision = pickerRevision
    pickerEnabled = false
    pickedElement = nil
    Task {
      guard revision == pickerRevision && !pickerEnabled else { return }
      _ = try? await evaluate("globalThis.__shaarPickerV1?.stop(); true")
    }
  }

  func refreshPicker() async throws {
    guard pickerEnabled else { return }
    let revision = pickerRevision
    guard let state = try await evaluate("globalThis.__shaarPickerV1?.snapshot()") as? [String: Any]
    else { return }
    guard revision == pickerRevision else { return }
    pickerFailure = nil
    if state["closed"] as? Bool == true {
      pickerEnabled = false
      pickedElement = nil
    } else if let value = state["selection"] as? [String: Any] {
      let next = PickedElement(value)
      if next != pickedElement { pickedElement = next }
    } else {
      pickedElement = nil
    }
  }

  func pollPicker() async {
    while pickerEnabled && !Task.isCancelled {
      do { try await refreshPicker() } catch {
        if !Task.isCancelled { pickerFailure = error.localizedDescription }
      }
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
    }
  }

  func copyPickerValue(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
