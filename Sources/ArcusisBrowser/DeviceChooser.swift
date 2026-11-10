// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
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
  let signalID: String
  let tabID: UUID
  let profileID: UUID
  let pageURL: URL
  let transport: DeviceChooserTransport
  let options: [DeviceChooserOption]
  let bluetoothUnavailable: Bool
  /// The current engine has no ChooserController, so a row cannot be granted.
  let canGrant: Bool

  var sheetID: String { "chooser-\(id)" }

  func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}

enum DeviceChooserSignal {
  static let prefix = "\u{2060}shaar-chooser:"

  struct Payload: Equatable {
    let id: String
    let transport: DeviceChooserTransport
    let previousTitle: String
  }

  static func parse(title: String) -> Payload? {
    guard title.hasPrefix(prefix) else { return nil }
    let body = title.dropFirst(prefix.count)
    guard let data = body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = object["id"] as? String,
      isSignalID(id),
      let kind = object["kind"] as? String,
      let transport = DeviceChooserTransport(rawValue: kind),
      let previous = object["previous"] as? String,
      previous.count <= 2048
    else { return nil }
    return Payload(id: id, transport: transport, previousTitle: previous)
  }

  static func isSignalID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isNumber || $0 == "-" }
  }
}

enum DeviceChooserIntake {
  static func request(
    tabID: UUID, profileID: UUID?, pageURL: URL, title: String, bluetoothBlocked: Bool
  ) -> DeviceChooserRequest? {
    guard let profileID, let signal = DeviceChooserSignal.parse(title: title),
      pageURL.scheme == "http" || pageURL.scheme == "https"
    else { return nil }
    let blocked = signal.transport.usesBluetooth && bluetoothBlocked
    return DeviceChooserRequest(
      id: "\(tabID.uuidString)-\(signal.id)",
      signalID: signal.id,
      tabID: tabID,
      profileID: profileID,
      pageURL: pageURL,
      transport: signal.transport,
      options: [],
      bluetoothUnavailable: blocked,
      canGrant: false)
  }
}

enum DeviceChooserScript {
  static func install(bluetoothBlocked: Bool) -> String {
    let blocked = bluetoothBlocked ? "true" : "false"
    return """
      (() => {
        if (window.__shaarChooserInstalled) return {installed: true, blocked: \(blocked)};
        const blocked = \(blocked);
        const pending = new Map();
        window.__shaarChooserSettle = (id, action) => {
          const entry = pending.get(String(id));
          if (!entry) return false;
          pending.delete(String(id));
          if (typeof entry.previous === "string") document.title = entry.previous;
          if (action === "use-native") entry.useNative();
          else entry.reject(new DOMException("No device selected.", "NotFoundError"));
          return true;
        };
        const wrap = (target, method, kind, callNative) => {
          if (!target || typeof target[method] !== "function") return;
          const original = target[method].bind(target);
          target[method] = function(options) {
            const id = String(pending.size + 1) + "-" + String(Date.now());
            let nativeState = "idle";
            let nativeValue;
            const entry = {
              previous: document.title,
              reject: null,
              resolve: null,
              useNative() {
                if (nativeState === "ok") this.resolve(nativeValue);
                else if (nativeState === "err") this.reject(nativeValue);
                else nativeState = "forward";
              }
            };
            const promise = new Promise((resolve, reject) => {
              entry.resolve = resolve;
              entry.reject = reject;
            });
            pending.set(id, entry);
            document.title = "\\u2060shaar-chooser:" + JSON.stringify({
              id: id, kind: kind, previous: entry.previous
            });
            if (callNative) {
              Promise.resolve(original(options)).then((value) => {
                nativeValue = value;
                if (nativeState === "forward") {
                  pending.delete(id);
                  entry.resolve(value);
                } else nativeState = "ok";
              }, (error) => {
                nativeValue = error;
                if (nativeState === "forward") {
                  pending.delete(id);
                  entry.reject(error);
                } else nativeState = "err";
              });
            }
            return promise;
          };
        };
        wrap(navigator.usb, "requestDevice", "usb", true);
        wrap(navigator.serial, "requestPort", "serial", !blocked);
        wrap(navigator.bluetooth, "requestDevice", "bluetooth", !blocked);
        wrap(navigator.hid, "requestDevice", "hid", true);
        window.__shaarChooserInstalled = true;
        return {installed: true, blocked: blocked};
      })()
      """
  }

  static func settle(signalID: String, action: String) -> String {
    let id = jsonLiteral(signalID)
    let decision = jsonLiteral(action)
    return "(() => { const settled = !!(window.__shaarChooserSettle && window.__shaarChooserSettle(\(id), \(decision))); return {settled: settled}; })()"
  }

  private static func jsonLiteral(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
      let encoded = String(data: data, encoding: .utf8),
      encoded.count >= 2
    else { return "\"\"" }
    return String(encoded.dropFirst().dropLast())
  }
}

struct DeviceChooserConsent: View {
  let store: BrowserStore
  let request: DeviceChooserRequest
  @Environment(\.dismiss) private var dismiss
  @State private var selection: Int?

  init(store: BrowserStore, request: DeviceChooserRequest, initialSelection: Int? = nil) {
    self.store = store
    self.request = request
    _selection = State(initialValue: initialSelection)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(PanelsL10n.string("Choose a device"), systemImage: request.transport.symbol)
        .font(.title2.weight(.semibold))
      Text(request.pageURL.host() ?? request.pageURL.absoluteString)
        .font(.headline)
        .textSelection(.enabled)
        .environment(\.layoutDirection, .leftToRight)
      Text(request.transport.prompt)
      status
      HStack {
        Button(PanelsL10n.string("Not now"), role: .cancel) { resolve(index: nil) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(PanelsL10n.string("Connect")) { resolve(index: selection) }
          .disabled(!canConnect)
      }
    }
    .padding(28)
    .frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
  }

  private var canConnect: Bool {
    guard request.canGrant, request.matches(store.session), let selection else { return false }
    return request.options.contains { $0.index == selection }
  }

  @ViewBuilder private var status: some View {
    if request.bluetoothUnavailable {
      Text(PanelsL10n.string("Bluetooth access isn't available."))
      Text(PanelsL10n.string("Shaar cannot use Bluetooth until macOS allows it for this app."))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if request.options.isEmpty {
      Text(PanelsL10n.string("No devices found."))
        .foregroundStyle(.secondary)
    } else {
      ForEach(request.options) { option in
        Button { selection = option.index } label: {
          optionLabel(option)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func optionLabel(_ option: DeviceChooserOption) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(option.title)
      if !option.detail.isEmpty {
        Text(option.detail).font(.callout).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(selection == option.index ? Color.accentColor.opacity(0.15) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func resolve(index: Int?) {
    store.resolveDeviceChooser(request.id, optionIndex: index)
    dismiss()
  }
}
