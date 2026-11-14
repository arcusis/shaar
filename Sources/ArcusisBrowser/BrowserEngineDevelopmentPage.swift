// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

extension BrowserEngine {
  /// Current local-page state for the selected tab. Framework tools and the agent bridge can
  /// consume this without coupling to toolbar presentation.
  var selectedDevelopmentPage: DevelopmentPage? {
    guard DevelopmentModePreference.isEnabled, let target = siteControlTarget else { return nil }
    let page =
      developmentPageURLs[target.tabID] == target.url
      ? developmentPages[target.tabID] ?? DevelopmentPage.detect(url: target.url)
      : DevelopmentPage.detect(url: target.url)
    return page.isDevelopmentPage ? page : nil
  }

  var isDevelopmentPage: Bool { selectedDevelopmentPage?.isDevelopmentPage == true }
  var detectedFramework: DevelopmentFramework? { selectedDevelopmentPage?.detectedFramework }

  func updateDevelopmentPage(tabID: UUID, url: URL, loading: Bool) {
    let page = DevelopmentPage.detect(url: url)
    let previousURL = developmentPageURLs[tabID]
    if loading || previousURL != url { developmentProbeRequests[tabID] = UUID() }
    if loading || developmentProbedURLs[tabID] != url { developmentPages[tabID] = page }
    developmentPageURLs[tabID] = url
    if loading { developmentProbedURLs[tabID] = nil }
    guard !loading, page.isDevelopmentPage,
      developmentProbedURLs[tabID] != url,
      let profileID = store?.session.profileID(forTabID: tabID)
    else { return }
    developmentProbedURLs[tabID] = url
    let request = developmentProbeRequests[tabID] ?? UUID()
    developmentProbeRequests[tabID] = request
    Task { [weak self] in
      guard let self else { return }
      // The navigation callback may arrive before the document exposes its framework markers.
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled,
        self.developmentProbeRequests[tabID] == request,
        self.store?.session.page(forTabID: tabID)?.tab.url == url,
        let model = self.developerModels[tabID], model.target.url == url
      else { return }
      do {
        let value = try await model.evaluate(Self.frameworkMarkerScript)
        guard let text = value as? String, let data = text.data(using: .utf8),
          let markers = try? JSONDecoder().decode(PageMarkerSnapshot.self, from: data),
          self.developmentProbeRequests[tabID] == request,
          self.store?.session.profileID(forTabID: tabID) == profileID,
          self.store?.session.page(forTabID: tabID)?.tab.url == url
        else { return }
        self.developmentPages[tabID] = DevelopmentPage.detect(
          url: url,
          markers: DevelopmentPageMarkers(
            resourcePaths: markers.resourcePaths, documentMarkers: markers.documentMarkers))
      } catch {
        // The local page can navigate while the probe runs; URL eligibility remains valid.
      }
    }
  }

  private static let frameworkMarkerScript = """
    JSON.stringify({
      resourcePaths: performance.getEntriesByType('resource').slice(0, 200).map(x => {
        try { return new URL(x.name).pathname; } catch { return ''; }
      }),
      documentMarkers: [
        document.querySelector('#__next') ? '__next' : '',
        document.querySelector('[ng-version]') ? 'ng-version' : '',
        document.querySelector('#__nuxt') ? '__nuxt' : '',
        document.querySelector('astro-island') ? 'astro-island' : '',
        typeof window.__remixContext !== 'undefined' ? '__remix' : '',
        document.querySelector('[data-sveltekit-preload-data]') ? 'sveltekit' : ''
      ].filter(Boolean)
    })
    """
}

private struct PageMarkerSnapshot: Decodable {
  let resourcePaths: [String]
  let documentMarkers: [String]
}

enum DevelopmentModePreference {
  static let key = "developmentModeEnabled"
  static var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
