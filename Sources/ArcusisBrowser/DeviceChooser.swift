// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import SwiftUI

enum DeviceChooserTransport: String, Equatable, Sendable {
  case usb, serial, bluetooth, hid

  var symbol: String {
    switch self {
    case .usb: "cable.connector"
    case .serial: "arrow.left.arrow.right"
    case .bluetooth: "antenna.radiowaves.left.and.right"
    case .hid: "keyboard"
    }
  }

  var prompt: String {
    switch self {
    case .usb: PanelsL10n.string("This site wants to use a USB device.")
    case .serial: PanelsL10n.string("This site wants to use a serial port.")
    case .bluetooth: PanelsL10n.string("This site wants to use a Bluetooth device.")
    case .hid: PanelsL10n.string("This site wants to use an HID device.")
    }
  }

  var usesBluetooth: Bool {
    switch self {
    case .serial, .bluetooth: true
    case .usb, .hid: false
    }
  }
}

struct DeviceChooserOption: Identifiable, Equatable, Sendable {
  let index: Int
  let title: String
  let detail: String
  var id: Int { index }
}

struct DeviceChooserRequest: Identifiable, Equatable, Sendable {
  let id: String
  let tabID: UUID
  let profileID: UUID
  let pageURL: URL
  let origin: URL
  let revision = UUID()
  let transport: DeviceChooserTransport
  let options: [DeviceChooserOption]
  let bluetoothUnavailable: Bool
  /// Connect follows the engine event. An empty list cannot be granted.
  let canGrant: Bool

  var sheetID: String { "chooser-\(id)" }

  var displayOrigin: String {
    guard let host = origin.host() else { return pageURL.absoluteString }
    let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    let port = origin.port.flatMap { port -> Int? in
      if (origin.scheme == "http" && port == 80) || (origin.scheme == "https" && port == 443) {
        return nil
      }
      return port
    }
    let authority = port.map { "\(formattedHost):\($0)" } ?? formattedHost
    return "\(origin.scheme ?? "https")://\(authority)"
  }

  func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}

struct DeviceChooserSelection {
  private(set) var options: [DeviceChooserOption]
  private(set) var revision: UUID
  private(set) var index: Int?

  init(options: [DeviceChooserOption], revision: UUID, selectedIndex: Int? = nil) {
    self.options = options
    self.revision = revision
    self.index = options.contains { $0.index == selectedIndex } ? selectedIndex : nil
  }

  mutating func select(_ index: Int, from options: [DeviceChooserOption], revision: UUID) {
    self.options = options
    self.revision = revision
    self.index = options.contains { $0.index == index } ? index : nil
  }

  func selectedIndex(for options: [DeviceChooserOption], revision: UUID) -> Int? {
    guard revision == self.revision, options == self.options, let index,
      options.contains(where: { $0.index == index })
    else { return nil }
    return index
  }
}

enum DeviceChooserIntake {
  private static let payloadKeys: Set<String> = [
    "schemaVersion", "kind", "id", "transport", "pageURL", "origin", "options", "canGrant",
    "profileID", "tabID", "windowID",
  ]
  private static let optionKeys: Set<String> = ["index", "name"]
  private static let identifierCharacters = CharacterSet(
    charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-")

  static func isChooserID(_ id: String) -> Bool {
    (1...64).contains(id.count)
      && id.unicodeScalars.allSatisfy { identifierCharacters.contains($0) }
  }

  /// Parses `deviceChooserRequested` or `deviceChooserUpdated` from SHAAR_EVENT_PERMISSION.
  static func request(
    tabID: UUID, profileID: UUID?, pageURL: URL, payload: [String: Any]
  ) -> DeviceChooserRequest? {
    guard let profileID, pageURL.scheme == "http" || pageURL.scheme == "https",
      Set(payload.keys).isSubset(of: payloadKeys),
      integer(payload["schemaVersion"]) == 1,
      let kind = payload["kind"] as? String,
      kind == "deviceChooserRequested" || kind == "deviceChooserUpdated",
      let id = payload["id"] as? String, isChooserID(id),
      let transportName = payload["transport"] as? String,
      let transport = DeviceChooserTransport(rawValue: transportName),
      let pageText = payload["pageURL"] as? String,
      let eventPage = URL(string: pageText), eventPage == pageURL,
      let originText = payload["origin"] as? String,
      let origin = URL(string: originText),
      origin.scheme == "http" || origin.scheme == "https",
      let originHost = origin.host(), !originHost.isEmpty,
      origin.user == nil, origin.password == nil,
      origin.port.map({ (0...65535).contains($0) }) ?? true,
      let rawOptions = payload["options"] as? [[String: Any]], rawOptions.count <= 64,
      let canGrant = payload["canGrant"] as? Bool
    else { return nil }
    var options: [DeviceChooserOption] = []
    var seen: Set<Int> = []
    for raw in rawOptions {
      guard Set(raw.keys).isSubset(of: optionKeys),
        let index = integer(raw["index"]), (0..<64).contains(index), seen.insert(index).inserted,
        let name = raw["name"] as? String, name.utf8.count <= 256
      else { return nil }
      let sanitizedName = displayName(name)
      let title =
        sanitizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? PanelsL10n.string("Unknown device") : sanitizedName
      options.append(DeviceChooserOption(index: index, title: title, detail: ""))
    }
    guard canGrant == !options.isEmpty else { return nil }
    return DeviceChooserRequest(
      id: id, tabID: tabID, profileID: profileID, pageURL: pageURL, origin: origin,
      transport: transport,
      options: options, bluetoothUnavailable: false, canGrant: canGrant)
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let encoding = String(cString: number.objCType)
    guard encoding != "f", encoding != "d" else { return nil }
    return Int(exactly: number.doubleValue)
  }

  private static func displayName(_ value: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
      if scalar.value == 0x200C || scalar.value == 0x200D {
        scalars.append(scalar)
        continue
      }
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator:
        scalars.append("\u{FFFD}")
      default:
        scalars.append(scalar)
      }
    }
    return String(scalars)
  }
}

struct DeviceChooserConsent: View {
  static let headingTraits: AccessibilityTraits = .isHeader

  let store: BrowserStore
  let request: DeviceChooserRequest
  @Environment(\.dismiss) private var dismiss
  @State private var selection: DeviceChooserSelection

  static func optionAccessibilityTraits(isSelected: Bool) -> AccessibilityTraits {
    isSelected ? [.isSelected] : []
  }

  static func isOptionSelected(
    _ optionIndex: Int, options: [DeviceChooserOption], selection: DeviceChooserSelection,
    revision: UUID
  ) -> Bool {
    selection.selectedIndex(for: options, revision: revision) == optionIndex
  }

  init(store: BrowserStore, request: DeviceChooserRequest, initialSelection: Int? = nil) {
    self.store = store
    self.request = request
    _selection = State(
      initialValue: DeviceChooserSelection(
        options: request.options, revision: request.revision, selectedIndex: initialSelection))
  }

  private var liveRequest: DeviceChooserRequest {
    if case .deviceChooser(let current) = store.sheet, current.id == request.id { return current }
    return store.deviceChooserRequests.first { $0.id == request.id } ?? request
  }

  var body: some View {
    let presented = liveRequest
    VStack(alignment: .leading, spacing: 16) {
      Label(PanelsL10n.string("Choose a device"), systemImage: presented.transport.symbol)
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(Self.headingTraits)
      Text(presented.displayOrigin)
        .font(.headline)
        .textSelection(.enabled)
        .environment(\.layoutDirection, .leftToRight)
      Text(presented.transport.prompt)
      status(presented)
      HStack {
        Button(PanelsL10n.string("Not now"), role: .cancel) { resolve(index: nil) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(PanelsL10n.string("Connect")) {
          resolve(
            index: selection.selectedIndex(
              for: presented.options, revision: presented.revision))
        }
        .disabled(!canConnect(presented))
      }
    }
    .padding(28)
    .frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
  }

  private func canConnect(_ presented: DeviceChooserRequest) -> Bool {
    guard presented.canGrant, presented.matches(store.session) else { return false }
    return selection.selectedIndex(for: presented.options, revision: presented.revision) != nil
  }

  @ViewBuilder private func status(_ presented: DeviceChooserRequest) -> some View {
    if presented.bluetoothUnavailable {
      Text(PanelsL10n.string("Bluetooth access isn't available."))
      Text(PanelsL10n.string("Shaar cannot use Bluetooth until macOS allows it for this app."))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if presented.options.isEmpty {
      Text(PanelsL10n.string("No devices found."))
        .foregroundStyle(.secondary)
    } else {
      ForEach(presented.options) { option in
        Button {
          selection.select(option.index, from: presented.options, revision: presented.revision)
        } label: {
          optionLabel(option, options: presented.options)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
          Self.optionAccessibilityTraits(
            isSelected: Self.isOptionSelected(
              option.index, options: presented.options, selection: selection,
              revision: presented.revision)))
      }
    }
  }

  private func optionLabel(_ option: DeviceChooserOption, options: [DeviceChooserOption])
    -> some View
  {
    VStack(alignment: .leading, spacing: 2) {
      Text(option.title)
      if !option.detail.isEmpty {
        Text(option.detail).font(.callout).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(
      selection.selectedIndex(for: options, revision: liveRequest.revision) == option.index
        ? Color.accentColor.opacity(0.15) : Color.clear
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func resolve(index: Int?) {
    store.resolveDeviceChooser(request.id, optionIndex: index)
    dismiss()
  }
}
