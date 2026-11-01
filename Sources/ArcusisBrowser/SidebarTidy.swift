// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import FoundationModels

struct SidebarTidyGroup: Equatable {
  let topic: String
  let tabIDs: [UUID]
}

protocol SidebarTidyGrouping {
  func groups(for tabs: [BrowserTab]) async -> [SidebarTidyGroup]
}

struct SidebarSiteGrouping: SidebarTidyGrouping {
  func groups(for tabs: [BrowserTab]) async -> [SidebarTidyGroup] {
    var groups: [String: [UUID]] = [:]
    for tab in tabs {
      let host = tab.url.host()?.lowercased() ?? ShellL10n.string("Other")
      groups[host, default: []].append(tab.id)
    }
    return groups.keys.sorted().map { SidebarTidyGroup(topic: $0, tabIDs: groups[$0]!) }
  }
}

struct SidebarTopicGrouping: SidebarTidyGrouping {
  func groups(for tabs: [BrowserTab]) async -> [SidebarTidyGroup] {
    let fallback = SidebarSiteGrouping()
    guard case .available = SystemLanguageModel.default.availability, !tabs.isEmpty else {
      return await fallback.groups(for: tabs)
    }
    let input = tabs.enumerated().map {
      "\($0.offset): \($0.element.title) (\($0.element.url.host() ?? ""))"
    }.joined(separator: "\n")
    let prompt = """
      Group these browser tabs by topic. Return only a JSON array of objects with keys \
      "topic" (short string) and "indices" (array of integers). Include every index exactly once.
      \(input)
      """
    do {
      let response = try await LanguageModelSession().respond(to: prompt)
      let data = Data(response.content.utf8)
      let proposed = try JSONDecoder().decode([Proposal].self, from: data)
      let indices = proposed.flatMap(\.indices)
      guard indices.count == tabs.count, Set(indices) == Set(tabs.indices),
        proposed.allSatisfy({
          !$0.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.indices.isEmpty
        })
      else { return await fallback.groups(for: tabs) }
      return proposed.sorted { $0.topic.localizedStandardCompare($1.topic) == .orderedAscending }
        .map { SidebarTidyGroup(topic: $0.topic, tabIDs: $0.indices.map { tabs[$0].id }) }
    } catch {
      return await fallback.groups(for: tabs)
    }
  }

  private struct Proposal: Decodable {
    let topic: String
    let indices: [Int]
  }
}
