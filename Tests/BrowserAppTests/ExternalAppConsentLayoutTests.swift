import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ExternalAppConsentLayoutTests: XCTestCase {
  func testNormalConsentFitsNativeSheetBounds() throws {
    let (store, request) = try fixture(name: "Calendar", host: "example.com")
    let host = layout(
      ExternalAppConsent(store: store, request: request), size: NSSize(width: 440, height: 520))
    XCTAssertLessThanOrEqual(host.fittingSize.width, 440)
    XCTAssertGreaterThan(host.fittingSize.height, 0)
    XCTAssertLessThanOrEqual(host.fittingSize.height, 520)
    XCTAssertNotNil(scrollView(in: host))
  }

  func testLongAppNameAndOriginRemainInsideScrollableSheetBounds() throws {
    let longName = String(repeating: "Installed Application ", count: 10).prefix(250).description
    let longHost = String(repeating: "readable-origin-", count: 12) + "example.com"
    let (store, request) = try fixture(name: longName, host: longHost)
    let host = layout(
      ExternalAppConsent(store: store, request: request), size: NSSize(width: 440, height: 320))
    XCTAssertLessThanOrEqual(host.fittingSize.width, 440)
    XCTAssertGreaterThan(host.fittingSize.height, 0)
    XCTAssertLessThanOrEqual(host.fittingSize.height, 620)
    let scrollView = try XCTUnwrap(scrollView(in: host))
    scrollView.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(scrollView.contentView.bounds.height, 0)
    XCTAssertLessThanOrEqual(scrollView.frame.height, 320)
    XCTAssertTrue(scrollView.hasVerticalScroller)
  }

  private func fixture(name: String, host: String) throws -> (BrowserStore, ExternalAppRequest) {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/private/path?token=hidden")!))
    let tab = try XCTUnwrap(store.session.selectedSpace.selectedTab)
    let origin = try XCTUnwrap(URL(string: "https://\(host)"))
    let request = try XCTUnwrap(
      ExternalAppRequest(
        id: "x1", profileID: store.session.selectedSpace.profileID, tabID: tab.id,
        pageURL: tab.url, scheme: "sample", requestingOrigin: origin,
        applicationName: name, windowID: "window"))
    XCTAssertTrue(store.requestExternalApp(request))
    return (store, request)
  }

  private func layout<V: View>(_ view: V, size: NSSize) -> NSHostingView<V> {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    return host
  }

  private func scrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    for child in view.subviews {
      if let scrollView = scrollView(in: child) { return scrollView }
    }
    return nil
  }
}
