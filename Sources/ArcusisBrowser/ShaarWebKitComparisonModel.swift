// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Observation
import WebKit

struct ShaarWebKitComparisonPreview {
  let chromiumPNG: Data
  let webKitHTML: String
  let viewport: CGSize
  let differenceTiles: [CGRect]
  let webKitErrors: [String]
}

@MainActor @Observable
final class ShaarWebKitComparisonModel {
  private(set) var target: SiteControlTarget
  private(set) var isOpen = false
  private(set) var viewport = CGSize(width: 900, height: 600)
  private(set) var chromiumPNG: Data?
  private(set) var differenceTiles: [CGRect] = []
  private(set) var webKitErrors: [String] = []
  private(set) var status: String?
  var syncScroll = true
  @ObservationIgnored private(set) var webView: WKWebView?
  @ObservationIgnored private weak var inspector: InspectorModel?
  @ObservationIgnored private var bridge: ShaarWebKitComparisonBridge?
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var webKitReady = false
  @ObservationIgnored private var lastChromiumScroll = CGPoint(x: -1, y: -1)
  @ObservationIgnored private let preview: ShaarWebKitComparisonPreview?

  init(target: SiteControlTarget, preview: ShaarWebKitComparisonPreview? = nil) {
    self.target = target
    self.preview = preview
  }

  func open(inspector: InspectorModel?) {
    guard !isOpen else { return }
    isOpen = true
    self.inspector = inspector
    if let preview {
      viewport = preview.viewport
      chromiumPNG = preview.chromiumPNG
      differenceTiles = preview.differenceTiles
      webKitErrors = preview.webKitErrors
      let view = makeWebView()
      webView = view
      view.loadHTMLString(preview.webKitHTML, baseURL: target.url)
      return
    }
    guard inspector?.engine != nil else {
      status = ShellL10n.string("Chromium page is unavailable for comparison")
      return
    }
    guard Self.supports(target.url) else {
      status = ShellL10n.string("Only HTTP and HTTPS pages can be compared")
      return
    }
    let view = makeWebView()
    webView = view
    let revision = generation
    Task { [weak self] in
      guard let self else { return }
      await self.updateViewport(revision: revision)
      guard self.isCurrent(revision) else { return }
      view.load(URLRequest(url: self.target.url))
    }
    pollTask = Task { [weak self] in
      while let self, self.isCurrent(revision) {
        await self.syncFromChromium(revision: revision)
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
  }

  private func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let controller = WKUserContentController()
    let bridge = ShaarWebKitComparisonBridge(owner: self)
    controller.add(bridge, name: "shaarComparison")
    controller.addUserScript(
      WKUserScript(
        source: Self.observerScript, injectionTime: .atDocumentStart,
        forMainFrameOnly: true))
    configuration.userContentController = controller
    self.bridge = bridge
    let view = WKWebView(frame: NSRect(origin: .zero, size: viewport), configuration: configuration)
    view.navigationDelegate = bridge
    return view
  }

  func close() {
    generation += 1
    pollTask?.cancel()
    refreshTask?.cancel()
    pollTask = nil
    refreshTask = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.configuration.userContentController.removeScriptMessageHandler(
      forName: "shaarComparison")
    webView = nil
    bridge = nil
    inspector = nil
    webKitReady = false
    chromiumPNG = nil
    differenceTiles = []
    webKitErrors = []
    status = nil
    lastChromiumScroll = CGPoint(x: -1, y: -1)
    isOpen = false
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool) {
    guard self.target != target || committed else { return }
    let inspector = self.inspector
    let wasOpen = isOpen
    close()
    self.target = target
    if wasOpen { open(inspector: inspector) }
  }

  func refresh() {
    guard isOpen, webKitReady else { return }
    let revision = generation
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in await self?.capture(revision: revision) }
  }

  func safariOnlyErrors(comparedWith chromiumEvents: [ShaarDevToolsEvent]) -> [String] {
    let chromium = Set(
      chromiumEvents.compactMap { event -> String? in
        guard case .console(let entry) = event, entry.level == .error else { return nil }
        return Self.normalized(entry.message)
      })
    return webKitErrors.filter { !chromium.contains(Self.normalized($0)) }
  }

  private static func supports(_ url: URL) -> Bool {
    url.scheme == "http" || url.scheme == "https"
  }

  private static func normalized(_ message: String) -> String {
    message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func isCurrent(_ revision: Int) -> Bool {
    isOpen && generation == revision && !Task.isCancelled
  }

  private func updateViewport(revision: Int) async {
    guard let inspector,
      let value = try? await inspector.evaluate(
        "({width: innerWidth, height: innerHeight})") as? [String: Any],
      isCurrent(revision),
      let width = value["width"] as? Double, let height = value["height"] as? Double,
      width.isFinite, height.isFinite
    else { return }
    viewport = CGSize(width: min(1920, max(320, width)), height: min(1200, max(240, height)))
    webView?.setFrameSize(viewport)
  }

  private func syncFromChromium(revision: Int) async {
    guard let inspector, let webView,
      let value = try? await inspector.evaluate(
        "({x: scrollX, y: scrollY, width: innerWidth, height: innerHeight})") as? [String: Any],
      isCurrent(revision),
      let x = value["x"] as? Double, let y = value["y"] as? Double,
      let width = value["width"] as? Double, let height = value["height"] as? Double,
      x.isFinite, y.isFinite, width.isFinite, height.isFinite
    else { return }
    let size = CGSize(width: min(1920, max(320, width)), height: min(1200, max(240, height)))
    if size != viewport {
      viewport = size
      webView.setFrameSize(size)
      refresh()
    }
    guard syncScroll else { return }
    let position = CGPoint(x: x, y: y)
    guard
      abs(position.x - lastChromiumScroll.x) > 1
        || abs(position.y - lastChromiumScroll.y) > 1
    else { return }
    lastChromiumScroll = position
    _ = try? await webView.evaluateJavaScript("scrollTo(\(x), \(y))")
    refresh()
  }

  func receive(_ message: [String: Any]) {
    guard isOpen, message["kind"] as? String != nil else { return }
    switch message["kind"] as? String {
    case "scroll":
      guard syncScroll, let x = message["x"] as? Double, let y = message["y"] as? Double,
        x.isFinite, y.isFinite, abs(x) < 1_000_000, abs(y) < 1_000_000,
        let inspector
      else { return }
      lastChromiumScroll = CGPoint(x: x, y: y)
      let revision = generation
      Task { [weak self] in
        guard let self, self.isCurrent(revision) else { return }
        _ = try? await inspector.evaluate("scrollTo(\(x), \(y)); true")
        if self.isCurrent(revision) { self.refresh() }
      }
    case "error":
      guard let text = message["message"] as? String, !text.isEmpty else { return }
      webKitErrors.append(String(text.prefix(4096)))
      if webKitErrors.count > 100 { webKitErrors.removeFirst() }
    default: break
    }
  }

  fileprivate func didFinish(_ view: WKWebView) {
    guard isOpen, view === webView else { return }
    webKitReady = true
    status = nil
    refresh()
  }

  fileprivate func didFail(_ error: Error) {
    guard isOpen else { return }
    webKitReady = false
    status = error.localizedDescription
  }

  fileprivate func allowsNavigation(_ action: WKNavigationAction) -> Bool {
    guard action.targetFrame?.isMainFrame == true,
      action.navigationType == .linkActivated || action.navigationType == .formSubmitted,
      let url = action.request.url
    else { return true }
    return url == target.url
  }

  private func capture(revision: Int) async {
    guard let inspector, let webView else { return }
    do {
      let reply = try await inspector.call(
        "Page.captureScreenshot", params: ["format": "png", "captureBeyondViewport": false])
      guard isCurrent(revision), let encoded = reply["data"] as? String,
        encoded.utf8.count <= 44 * 1024 * 1024,
        let chromium = Data(base64Encoded: encoded)
      else { return }
      let webKit = try await webView.takeSnapshot(configuration: nil)
      guard isCurrent(revision), let tiff = webKit.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let webKitPNG = bitmap.representation(using: .png, properties: [:])
      else { return }
      chromiumPNG = chromium
      differenceTiles = ShaarWebKitImageDiff.tiles(
        chromium: chromium, webKit: webKitPNG, viewport: viewport)
      status = nil
    } catch {
      guard isCurrent(revision) else { return }
      status = error.localizedDescription
    }
  }

  private static let observerScript = """
    (() => {
      const send = value => {
        try { window.webkit.messageHandlers.shaarComparison.postMessage(value); } catch (_) {}
      };
      const originalError = console.error;
      console.error = function(...values) {
        send({kind: 'error', message: values.map(String).join(' ')});
        return originalError.apply(this, values);
      };
      addEventListener('error', event => send({kind: 'error', message: event.message || String(event.error)}));
      addEventListener('unhandledrejection', event => send({kind: 'error', message: String(event.reason)}));
      let pending = false;
      addEventListener('scroll', () => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => {
          pending = false;
          send({kind: 'scroll', x: scrollX, y: scrollY});
        });
      }, {passive: true});
    })();
    """
}

@MainActor
private final class ShaarWebKitComparisonBridge: NSObject, WKNavigationDelegate,
  WKScriptMessageHandler
{
  weak var owner: ShaarWebKitComparisonModel?

  init(owner: ShaarWebKitComparisonModel) { self.owner = owner }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any] else { return }
    owner?.receive(body)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    owner?.didFinish(webView)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(owner?.allowsNavigation(navigationAction) == false ? .cancel : .allow)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    owner?.didFail(error)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    owner?.didFail(error)
  }
}

enum ShaarWebKitImageDiff {
  static func tiles(chromium: Data, webKit: Data, viewport: CGSize) -> [CGRect] {
    guard let left = NSBitmapImageRep(data: chromium), let right = NSBitmapImageRep(data: webKit),
      left.samplesPerPixel >= 3, right.samplesPerPixel >= 3,
      viewport.width > 0, viewport.height > 0
    else { return [] }
    let width = min(1920, Int(viewport.width))
    let height = min(1200, Int(viewport.height))
    var result: [CGRect] = []
    var leftPixel = [Int](repeating: 0, count: left.samplesPerPixel)
    var rightPixel = [Int](repeating: 0, count: right.samplesPerPixel)
    for y in stride(from: 0, to: height, by: 32) {
      for x in stride(from: 0, to: width, by: 32) {
        var different = 0
        var samples = 0
        for sampleY in stride(from: y, to: min(y + 32, height), by: 4) {
          for sampleX in stride(from: x, to: min(x + 32, width), by: 4) {
            left.getPixel(
              &leftPixel,
              atX: min(left.pixelsWide - 1, sampleX * left.pixelsWide / width),
              y: min(left.pixelsHigh - 1, sampleY * left.pixelsHigh / height))
            right.getPixel(
              &rightPixel,
              atX: min(right.pixelsWide - 1, sampleX * right.pixelsWide / width),
              y: min(right.pixelsHigh - 1, sampleY * right.pixelsHigh / height))
            samples += 1
            if abs(leftPixel[0] - rightPixel[0]) + abs(leftPixel[1] - rightPixel[1])
              + abs(leftPixel[2] - rightPixel[2]) > 107
            {
              different += 1
            }
          }
        }
        if samples > 0 && different * 5 >= samples {
          result.append(
            CGRect(
              x: x, y: y, width: min(32, width - x),
              height: min(32, height - y)))
        }
      }
    }
    return result
  }

}
