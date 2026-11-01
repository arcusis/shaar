// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import AppKit
import CoreGraphics
import CoreLocation
import UserNotifications

/// macOS privacy permissions that gate what websites can use in Shaar.
enum MacPermission: String, CaseIterable, Identifiable {
  case camera, microphone, location, notifications, screenRecording

  var id: String { rawValue }

  var title: String {
    switch self {
    case .camera: PanelsL10n.string("Camera")
    case .microphone: PanelsL10n.string("Microphone")
    case .location: PanelsL10n.string("Location")
    case .notifications: PanelsL10n.string("Notifications")
    case .screenRecording: PanelsL10n.string("Screen Recording")
    }
  }

  var symbol: String {
    switch self {
    case .camera: "camera"
    case .microphone: "mic"
    case .location: "location"
    case .notifications: "bell.badge"
    case .screenRecording: "rectangle.dashed.badge.record"
    }
  }

  /// The System Settings pane where the user changes this permission for Shaar.
  var settingsURL: URL? {
    switch self {
    case .camera: Self.privacy("Privacy_Camera")
    case .microphone: Self.privacy("Privacy_Microphone")
    case .location: Self.privacy("Privacy_LocationServices")
    case .screenRecording: Self.privacy("Privacy_ScreenCapture")
    case .notifications:
      URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
          + (Bundle.main.bundleIdentifier ?? ""))
    }
  }

  private static func privacy(_ anchor: String) -> URL? {
    URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
  }
}

enum MacPermissionStatus: Equatable {
  case allowed, denied, notDetermined

  var label: String {
    switch self {
    case .allowed: PanelsL10n.string("Allowed")
    case .denied: PanelsL10n.string("Not allowed")
    case .notDetermined: PanelsL10n.string("Not asked yet")
    }
  }
}

enum MacPermissionStatusReader {
  static func status(of permission: MacPermission) async -> MacPermissionStatus {
    switch permission {
    case .camera: capture(.video)
    case .microphone: capture(.audio)
    case .location: location()
    case .notifications: await notifications()
    // macOS reports only whether access is granted, not whether it was refused.
    case .screenRecording: CGPreflightScreenCaptureAccess() ? .allowed : .denied
    }
  }

  private static func capture(_ type: AVMediaType) -> MacPermissionStatus {
    switch AVCaptureDevice.authorizationStatus(for: type) {
    case .authorized: .allowed
    case .notDetermined: .notDetermined
    default: .denied
    }
  }

  private static func location() -> MacPermissionStatus {
    switch CLLocationManager().authorizationStatus {
    case .authorizedAlways: .allowed
    case .notDetermined: .notDetermined
    default: .denied
    }
  }

  private static func notifications() async -> MacPermissionStatus {
    // The notification center traps outside an .app bundle, such as in test runners.
    guard Bundle.main.bundleURL.pathExtension == "app" else { return .notDetermined }
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .authorized, .provisional, .ephemeral: return .allowed
    case .notDetermined: return .notDetermined
    default: return .denied
    }
  }
}
