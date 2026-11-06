// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Suite struct DevelopmentPageTests {
  @Test(arguments: [
    "http://localhost:3000/", "http://api.localhost:5173/", "http://127.0.0.1:4200/",
    "http://127.0.0.1:49152/",
    "http://[::1]:3000/", "http://app.test:8080/", "http://192.168.1.40:5173/",
    "http://10.0.0.5:3000/", "http://172.16.0.3:4200/",
  ])
  func localDevelopmentHosts(_ address: String) {
    #expect(DevelopmentPage.detect(url: URL(string: address)!).isDevelopmentPage)
  }

  @Test(arguments: [
    "https://example.com/", "https://localhost.evil.com:3000/", "https://192.168.1.1/",
    "https://10.0.0.1:443/", "https://8.8.8.8:5173/", "file:///tmp/index.html",
    "http://172.32.0.1:3000/", "http://localhost.example.test.evil:3000/",
  ])
  func ordinaryOrUntrustedHosts(_ address: String) {
    #expect(!DevelopmentPage.detect(url: URL(string: address)!).isDevelopmentPage)
  }

  @Test(arguments: [
    ("/_nuxt/app.js", DevelopmentFramework.nuxt),
    ("/_app/immutable/start.js", DevelopmentFramework.svelteKit),
  ])
  func frameworkResourcePaths(_ path: String, _ expected: DevelopmentFramework) {
    let page = DevelopmentPage.detect(
      url: URL(string: "http://localhost:3000")!, markers: .init(resourcePaths: [path]))
    #expect(page.detectedFramework == expected)
  }

  @Test(arguments: [
    ("__remix", DevelopmentFramework.remix),
    ("astro-island", DevelopmentFramework.astro),
  ])
  func frameworkDocumentMarkers(_ marker: String, _ expected: DevelopmentFramework) {
    let page = DevelopmentPage.detect(
      url: URL(string: "http://localhost:3000")!, markers: .init(documentMarkers: [marker]))
    #expect(page.detectedFramework == expected)
  }

  @Test func frameworkSignalsStayOnLocalPages() {
    let markers = DevelopmentPageMarkers(
      responseHeaders: ["x-powered-by": "Next.js"], resourcePaths: ["/_next/static/chunk.js"],
      documentMarkers: [])
    #expect(
      DevelopmentPage.detect(url: URL(string: "http://localhost:3000")!, markers: markers)
        .detectedFramework == .nextJS)
    #expect(
      DevelopmentPage.detect(url: URL(string: "https://example.com")!, markers: markers)
        .detectedFramework == nil)
    #expect(
      DevelopmentPage.detect(
        url: URL(string: "http://localhost:5173")!, markers: .init(resourcePaths: ["/@vite/client"])
      ).detectedFramework == .vite)
    #expect(
      DevelopmentPage.detect(
        url: URL(string: "http://localhost:4200")!, markers: .init(documentMarkers: ["ng-version"])
      ).detectedFramework == .angular)
  }
}
