// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import CoreFoundation
import Darwin
import Foundation

@testable import ArcusisBrowser

/// Hidden verification exercise for everyday browsing. The Python driver owns memory samples.
@MainActor enum ShaarBrowsingQA {
  static func run(arguments: [String]) -> Int32 {
    guard let index = arguments.firstIndex(of: "--browsing-qa"),
      arguments.indices.contains(index + 3),
      let frameworks = Bundle.main.privateFrameworksURL
    else { return 2 }
    let framework = frameworks.appending(path: "Chromium Framework.framework")
    let output = URL(fileURLWithPath: arguments[index + 1])
    let page = URL(string: arguments[index + 2])
    return run(
      frameworkURL: framework, outputURL: output, pageURL: page, scenario: arguments[index + 3])
  }

  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?, scenario: String) -> Int32 {
    guard let pageURL, pageURL.scheme == "http", pageURL.host == "127.0.0.1" else {
      write(["passed": false, "error": "Loopback http base URL is required."], to: outputURL)
      return 2
    }
    guard scenarios.contains(scenario) else {
      write(["passed": false, "error": "Unknown scenario \(scenario)."], to: outputURL)
      return 2
    }
    let root = outputURL.deletingLastPathComponent()
    do {
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "profile/workspace.json"),
          legacySessionURL: root.appending(path: "profile/session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe)
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task {
          await exercise(
            host: host, runtime: runtime, pageURL: pageURL, outputURL: outputURL,
            scenario: scenario)
        }
      }
      return withExtendedLifetime(host) {
        let code = runtime.run(
          withDataDirectory: root.appending(path: "Chromium"), testing: true)
        host.detach()
        return code
      }
    } catch {
      write(
        ["passed": false, "scenario": scenario, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static let scenarios: Set<String> = [
    "overload-50", "overload-100", "overload-200", "churn", "windows", "splits", "heavy",
    "dialogs", "downloads", "renderer", "restore-seed", "restore-check",
  ]

  private static func exercise(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, pageURL: URL, outputURL: URL,
    scenario: String
  ) async {
    var rows: [[String: Any]] = []
    defer {
      let hidden = windowsHidden()
      let failed = rows.contains { $0["status"] as? String == "fail" }
      write(
        [
          "passed": !failed && hidden, "scenario": scenario, "rows": rows,
          "allWindowsHidden": hidden,
        ], to: outputURL)
      host.events.quit()
    }
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      rows = try await run(
        scenario, host: host, context: context, runtime: runtime, base: pageURL,
        root: outputURL.deletingLastPathComponent())
    } catch {
      rows.append(row("setup", "fail", error.localizedDescription))
    }
  }

  private static func run(
    _ scenario: String, host: NativeBrowserHost, context: NativeBrowserContext,
    runtime: ARCShaarRuntime, base: URL, root: URL
  ) async throws -> [[String: Any]] {
    switch scenario {
    case "overload-50": return await overload(50, context: context, base: base)
    case "overload-100": return await overload(100, context: context, base: base)
    case "overload-200": return await overload(200, context: context, base: base)
    case "churn": return await churn(context: context, runtime: runtime, base: base)
    case "windows": return await windows(host: host, context: context, base: base, root: root)
    case "splits": return await splits(context: context, base: base)
    case "heavy": return await heavy(context: context, runtime: runtime, base: base)
    case "dialogs": return await dialogs(context: context, runtime: runtime, base: base)
    case "downloads": return await downloads(host: host, context: context, base: base, root: root)
    case "renderer": return await renderer(context: context, base: base)
    case "restore-seed": return await restoreSeed(host: host, context: context, base: base)
    case "restore-check": return await restoreCheck(context: context)
    default: throw Failure("Unknown scenario \(scenario).")
    }
  }

  private static func overload(
    _ count: Int, context: NativeBrowserContext, base: URL
  ) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    let space = context.store.session.selectedSpaceID
    let started = Date()
    context.store.perform(.open(url(base, path: "/light", query: "n=0")))
    let first = await until(attempts: 300, condition: { settled(context, path: "/light") })
    guard keepHidden(&rows, "overload-first"), first else {
      rows.append(row("overload-open", "fail", "The first tab did not finish loading."))
      return rows
    }
    for index in 1..<count {
      context.store.perform(.open(url(base, path: "/light", query: "n=\(index)")))
      if index.isMultiple(of: 5) { await Task.yield() }
    }
    let openMilliseconds = milliseconds(since: started)
    let settledCount = await until(
      attempts: min(count * 8, 1_200),
      condition: {
        liveCount(context) == count && tabCount(context, space: space) == count
          && settled(context, path: "/light")
      })
    let saved = tabCount(context, space: space)
    let live = liveCount(context)
    rows.append(
      row(
        "overload-open", settledCount && saved == count ? "pass" : "fail",
        "Saved \(saved) tabs, \(live) live, opened in \(openMilliseconds) ms.",
        ["saved": saved, "live": live, "elapsedMs": milliseconds(since: started)]))
    guard keepHidden(&rows, "overload-open") else { return rows }

    let extraStarted = Date()
    context.store.perform(.open(url(base, path: "/light", query: "n=extra")))
    let extraReady = await until(attempts: 150, condition: { settled(context, path: "/light") })
    rows.append(
      row(
        "overload-next-tab", extraReady ? "pass" : "fail",
        "One more tab after the burst took \(milliseconds(since: extraStarted)) ms.",
        ["elapsedMs": milliseconds(since: extraStarted)]))

    let closeStarted = Date()
    context.store.clearTodayTabs(in: space)
    let closed = await until(
      attempts: min(count * 4, 400), condition: { tabCount(context, space: space) == 0 })
    let retained = context.store.session.recentlyClosedTabs(in: space).count
    rows.append(
      row(
        "overload-close", closed ? "pass" : "fail",
        "Bulk close left \(tabCount(context, space: space)) tabs and remembered \(retained).",
        ["elapsedMs": milliseconds(since: closeStarted), "remembered": retained]))
    let reopened = context.store.reopenLastClosedTab()
    let reopenedURL = context.store.session.selectedSpace.selectedTab?.url.path ?? ""
    rows.append(
      row(
        "overload-reopen", reopened && reopenedURL == "/light" ? "pass" : "fail",
        reopened ? "Reopened \(reopenedURL)." : "Reopen did nothing."))
    guard let selected = context.store.session.selectedSpace.selectedTabID else { return rows }
    context.store.togglePin(selected)
    let pinned = context.store.session.selectedSpace.tabs.first { $0.id == selected }?.isPinned
    context.store.togglePin(selected)
    let unpinned = context.store.session.selectedSpace.tabs.first { $0.id == selected }?.isPinned
    rows.append(
      row(
        "overload-pin", pinned == true && unpinned == false ? "pass" : "fail",
        "Pin then unpin left pinned=\(pinned == true), then unpinned=\(unpinned == false)."))
    rows.append(
      row(
        "duplicate-tab", "blocked",
        "The tab menu can pin, move, and close. It has no Duplicate command."))
    _ = keepHidden(&rows, "overload-done")
    return rows
  }

  private static func churn(
    context: NativeBrowserContext, runtime: ARCShaarRuntime, base: URL
  ) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    let space = context.store.session.selectedSpaceID
    context.store.perform(.open(url(base, path: "/nav/0")))
    guard await until(attempts: 150, condition: { settled(context, path: "/nav/0") }) else {
      rows.append(row("churn-setup", "fail", "The history page did not load."))
      return rows
    }
    var created: [UUID] = []
    for index in 0..<20 {
      let before = Set(context.store.session.selectedSpace.tabs.map(\.id))
      context.store.perform(.open(url(base, path: "/light", query: "n=\(index)")))
      if let id = context.store.session.selectedSpace.selectedTabID, !before.contains(id) {
        created.append(id)
        context.store.closeTab(id)
      }
      await Task.yield()
    }
    let drained = await until(
      attempts: 200,
      condition: {
        let ids = Set(context.store.session.selectedSpace.tabs.map(\.id))
        return created.allSatisfy { !ids.contains($0) }
      })
    rows.append(
      row(
        "churn-open-close", drained ? "pass" : "fail",
        drained ? "Twenty open/close pairs finished." : "Some churn tabs stayed open."))

    guard let current = context.store.session.selectedSpace.selectedTabID else { return rows }
    let steps = ["/nav/1", "/nav/2"]
    var historyReady = true
    for path in steps {
      guard context.engine.navigateCurrentPage(to: url(base, path: path)),
        await until(attempts: 150, condition: { settled(context, path: path) })
      else {
        historyReady = false
        break
      }
    }
    rows.append(
      row(
        "churn-navigate", historyReady ? "pass" : "fail",
        historyReady ? "Forward navigations committed." : "A navigation did not commit."))
    guard historyReady, keepHidden(&rows, "churn-navigate") else { return rows }
    runtime.goBack(inTabID: current.uuidString)
    let backOne = await until(attempts: 100, condition: { settled(context, path: "/nav/1") })
    runtime.goBack(inTabID: current.uuidString)
    let backTwo = await until(attempts: 100, condition: { settled(context, path: "/nav/0") })
    runtime.goForward(inTabID: current.uuidString)
    let forward = await until(attempts: 100, condition: { settled(context, path: "/nav/1") })
    rows.append(
      row(
        "churn-history", backOne && backTwo && forward ? "pass" : "fail",
        "Back/forward landed on \(context.store.session.selectedPage?.tab.url.path ?? "nothing")."
      ))

    let slowStarted = Date()
    let reloadPath = "/slow-reload/\(UUID().uuidString)"
    guard context.engine.navigateCurrentPage(to: url(base, path: reloadPath)) else {
      rows.append(row("churn-reload-during-load", "fail", "The slow navigation was rejected."))
      return rows
    }
    let inFlight = await until(attempts: 40, condition: { pageIsLoading(context) })
    let stillLoading = pageIsLoading(context)
    let reloaded = inFlight && stillLoading && context.store.reloadCurrentPage()
    let settledSlow = await until(
      attempts: 200, condition: { settled(context, path: reloadPath) })
    let reloadRequests = await evaluate(
      runtime, tab: current,
      script: "document.documentElement.dataset.reloadRequest || ''")
    let repeatedRequest = reloadDuringNavigationWasFetched(reloadRequests)
    let landed = context.store.session.selectedPage?.tab.url.path ?? "nothing"
    rows.append(
      row(
        "churn-reload-during-load",
        reloaded && settledSlow && repeatedRequest ? "pass" : "fail",
        "Reload during load inFlight=\(stillLoading), reload=\(reloaded), requests=\(reloadRequests ?? "missing"), finished in \(milliseconds(since: slowStarted)) ms at \(landed).",
        ["elapsedMs": milliseconds(since: slowStarted)]))
    let failures = context.store.rendererFailures.count
    rows.append(
      row(
        "churn-stable", failures == 0 && tabCount(context, space: space) > 0 ? "pass" : "fail",
        "Renderer failures after churn: \(failures)."))
    _ = keepHidden(&rows, "churn-done")
    return rows
  }

  private static func windows(
    host: NativeBrowserHost, context: NativeBrowserContext, base: URL, root: URL
  ) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    let originSpace = context.store.session.selectedSpaceID
    context.store.perform(.open(url(base, path: "/light", query: "n=window")))
    guard await until(attempts: 150, condition: { settled(context, path: "/light") }) else {
      rows.append(row("windows-setup", "fail", "The first window page did not load."))
      return rows
    }
    let movedTab = context.store.session.selectedSpace.selectedTabID
    do {
      _ = try host.newWindow()
      _ = try host.newWindow()
    } catch {
      rows.append(row("windows-create", "fail", error.localizedDescription))
      return rows
    }
    let windowCount = host.contexts.count
    for browser in host.contexts.values where browser.id != context.id {
      browser.store.perform(.open(url(base, path: "/nav/1")))
    }
    let othersReady = await until(
      attempts: 200,
      condition: {
        host.contexts.values.filter { $0.id != context.id }.allSatisfy {
          settled($0, path: "/nav/1")
        }
      })
    rows.append(
      row(
        "windows-create", windowCount == 3 && othersReady ? "pass" : "fail",
        "Created \(windowCount) normal windows."))
    guard keepHidden(&rows, "windows-create") else { return rows }

    if let movedTab, let destination = host.contexts.values.first(where: { $0.id != context.id }) {
      let payload = SidebarTransfer.tab(
        sessionID: context.store.dragSessionID, sourceSpaceID: originSpace, tabID: movedTab)
      let accepted = destination.store.acceptSidebarDrop(
        payload, into: destination.store.session.selectedSpaceID)
      let stayed = context.store.session.spaces.flatMap(\.tabs).contains { $0.id == movedTab }
      let engineMoved = await until(attempts: 100) {
        destination.engine.liveTabs.contains(movedTab)
          && destination.engine.runtime.windowID(forTabID: movedTab.uuidString)
            == destination.engine.windowID
      }
      let destinationHasTab = destination.store.session.page(forTabID: movedTab) != nil
      let destinationSelectedTab =
        destination.store.session.selectedSpace.selectedTabID?.uuidString ?? "none"
      let destinationEngineAttached = destination.store.engine === destination.engine
      rows.append(
        row(
          "windows-drag", accepted && !stayed && engineMoved ? "pass" : "fail",
          accepted && !stayed && engineMoved
            ? "The tab moved into the other window and its live engine owner followed."
            : "Drop accepted=\(accepted), stayed in source=\(stayed), destination has tab=\(destinationHasTab), selected=\(destinationSelectedTab), engine attached=\(destinationEngineAttached), engine closed=\(destination.engine.isClosed), live=\(destination.engine.liveTabs.contains(movedTab)), owner=\(destination.engine.runtime.windowID(forTabID: movedTab.uuidString) ?? "none"), destination=\(destination.engine.windowID), notice=\(destination.engine.notice ?? "none")."
        ))
    } else {
      rows.append(
        row("windows-drag", "fail", "There was no tab or destination window to drop."))
    }

    context.store.perform(.open(url(base, path: "/nav/2")))
    guard await until(attempts: 100, condition: { settled(context, path: "/nav/2") }),
      let spaceTab = context.store.session.selectedSpace.selectedTabID
    else {
      rows.append(row("windows-space", "fail", "Could not open a tab to move between Spaces."))
      return rows
    }
    let origin = context.store.session.selectedSpaceID
    let created = context.store.createSpace(
      name: "QA Space", sharingProfile: context.store.session.selectedSpace.profileID,
      tint: .forest)
    let destinationSpace = context.store.session.selectedSpaceID
    let moved = created && context.store.moveTab(spaceTab, from: origin, to: destinationSpace)
    let arrived =
      context.store.session.spaces.first { $0.id == destinationSpace }?
      .tabs.contains { $0.id == spaceTab } == true
    rows.append(
      row(
        "windows-space-move", moved && arrived ? "pass" : "fail",
        arrived ? "The tab moved to another Space in the same window." : "The Space move failed."))

    guard host.canPerform(.newPrivateWindow) else {
      rows.append(row("windows-private", "fail", "New Private Window was disabled."))
      return rows
    }
    host.perform(.newPrivateWindow)
    let privateReady = await until(attempts: 150, condition: { !host.privateWindowOwners.isEmpty })
    guard privateReady, let owner = host.privateWindowOwners.first else {
      rows.append(row("windows-private", "fail", "The private window did not appear."))
      return rows
    }
    owner.store.perform(.open(url(base, path: "/light", query: "n=private")))
    let prompted = await until(
      attempts: 150, condition: { owner.store.privatePage?.pendingHTTP != nil })
    if prompted { owner.store.confirmHTTP(useHTTPS: false) }
    guard keepHidden(&rows, "windows-private") else { return rows }
    let privateLoaded = await until(
      attempts: 150,
      condition: {
        owner.store.session.selectedPage?.tab.url.path == "/light"
          && owner.page.pages[owner.store.session.selectedPage?.tab.id ?? UUID()]?.loading == false
      })
    let workspaceFile = root.appending(path: "profile/workspace.json")
    var flushed = false
    var absent = false
    if privateLoaded {
      do {
        try host.workspace.flushSaves()
        flushed = true
      } catch {
        flushed = false
      }
      if flushed, let saved = try? String(contentsOf: workspaceFile, encoding: .utf8) {
        absent = !saved.contains("n=private")
      }
    }
    let privateHidden = !owner.window.isVisible
    rows.append(
      row(
        "windows-private",
        privateLoaded && privateHidden && flushed && absent ? "pass" : "fail",
        "Private HTTP prompt=\(prompted), loaded=\(privateLoaded), visible=\(owner.window.isVisible), flushed=\(flushed), absentFromWorkspace=\(absent)."
      ))

    let personal = context.store.session.selectedSpaceID
    let currentProfile = context.store.session.selectedSpace.profileID
    guard
      let otherProfile = context.store.session.spaces.first(where: {
        $0.profileID != currentProfile
      })?
      .profileID
    else {
      rows.append(row("windows-profile", "fail", "There is no second profile."))
      return rows
    }
    context.store.perform(.space(personal))
    guard context.engine.navigateCurrentPage(to: url(base, path: "/slow")) else {
      rows.append(row("windows-profile", "fail", "The slow navigation did not start."))
      return rows
    }
    let inFlight = await until(attempts: 40, condition: { pageIsLoading(context) })
    let stillLoading = pageIsLoading(context)
    guard inFlight && stillLoading else {
      rows.append(
        row(
          "windows-profile", "fail",
          "The profile switch did not happen during the load."))
      return rows
    }
    let switched = context.store.setSpaceProfile(personal, to: otherProfile)
    let switchedPage = await until(
      attempts: 200,
      condition: {
        guard
          context.store.session.spaces.first(where: { $0.id == personal })?.profileID
            == otherProfile,
          let id = context.store.session.selectedPage?.tab.id
        else { return false }
        return context.engine.pages[id]?.loading == false && context.engine.liveTabs.contains(id)
      })
    let finalPath = context.store.session.selectedPage?.tab.url.path ?? ""
    let profileNow = context.store.session.spaces.first { $0.id == personal }?.profileID
    rows.append(
      row(
        "windows-profile",
        switched && switchedPage && profileNow == otherProfile
          && context.store.rendererFailures.isEmpty ? "pass" : "fail",
        "Mid-load profile switch accepted=\(switched), settled=\(switchedPage), failures=\(context.store.rendererFailures.count), ended on \(finalPath)."
      ))
    _ = keepHidden(&rows, "windows-done")
    return rows
  }

  private static func splits(context: NativeBrowserContext, base: URL) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    context.store.perform(.open(url(base, path: "/favicon")))
    context.store.perform(.open(url(base, path: "/nav/1")))
    guard await until(attempts: 150, condition: { settled(context, path: "/nav/1") }) else {
      rows.append(row("splits-setup", "fail", "Split pages did not load."))
      return rows
    }
    context.store.splitSelectedTab()
    let split = context.store.selectedSplit
    let bothLive = split?.tabIDs.allSatisfy { context.engine.liveTabs.contains($0) } == true
    rows.append(
      row(
        "splits-pair", split?.tabIDs.count == 2 && bothLive ? "pass" : "fail",
        "Split holds \(split?.tabIDs.count ?? 0) live panes."))
    guard let pinnedID = context.store.session.selectedSpace.tabs.first?.id else { return rows }
    context.store.togglePin(pinnedID)
    let pinned = context.store.session.selectedSpace.tabs.first { $0.id == pinnedID }?.isPinned
    rows.append(
      row(
        "splits-pin", pinned == true ? "pass" : "fail", "Pinned the first tab: \(pinned == true)."))
    let favored = context.store.addCurrentPageAsFavorite()
    let favoriteURL = context.store.session.selectedFavorite?.originalURL.path ?? ""
    rows.append(
      row(
        "splits-favorite", favored && favoriteURL == "/nav/1" ? "pass" : "fail",
        "Favorite URL path is \(favoriteURL)."))
    let icon = await until(
      attempts: 80,
      condition: {
        context.store.session.selectedSpace.tabs.contains {
          context.store.favicon(forPage: $0.id) != nil
        }
          || context.store.session.favoritePages.contains {
            context.store.favicon(forPage: $0.tab.id) != nil
          }
      })
    rows.append(
      row(
        "splits-favicon", icon ? "pass" : "fail",
        icon ? "A fixture icon was stored for a page." : "No favicon was stored."))
    rows.append(
      row(
        "duplicate-tab", "blocked",
        "The tab menu can pin, move, and close. It has no Duplicate command."))
    _ = keepHidden(&rows, "splits-done")
    return rows
  }

  private static func heavy(
    context: NativeBrowserContext, runtime: ARCShaarRuntime, base: URL
  ) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    let started = Date()
    context.store.perform(.open(url(base, path: "/heavy")))
    guard await until(attempts: 300, condition: { settled(context, path: "/heavy") }),
      let heavyID = context.store.session.selectedPage?.tab.id
    else {
      rows.append(row("heavy-dom", "fail", "The large page did not finish loading."))
      return rows
    }
    let count = await evaluate(
      runtime, tab: heavyID, script: "document.getElementById('heavy').children.length")
    rows.append(
      row(
        "heavy-dom", count == "20000" ? "pass" : "fail",
        "Large page reported \(count ?? "nothing") nodes in \(milliseconds(since: started)) ms.",
        ["elapsedMs": milliseconds(since: started)]))

    context.store.perform(.open(url(base, path: "/scroll")))
    guard await until(attempts: 100, condition: { settled(context, path: "/scroll") }),
      let scrollID = context.store.session.selectedPage?.tab.id
    else {
      rows.append(row("heavy-scroll", "fail", "The scroll page did not load."))
      return rows
    }
    let primed = wholeNumber(
      await evaluate(
        runtime, tab: scrollID,
        script:
          "(()=>{const feed=document.getElementById('feed');if(!feed)return 0;const before=feed.children.length;feed.scrollTop=feed.scrollHeight;return before;})()"
      ))
    let before = primed ?? 0
    var after = before
    let grew = await untilReady(attempts: 40) {
      after =
        wholeNumber(
          await evaluate(
            runtime, tab: scrollID,
            script:
              "(()=>{const feed=document.getElementById('feed');return feed?feed.children.length:0})()"
          )) ?? 0
      return before == 100 && after > before
    }
    rows.append(
      row(
        "heavy-scroll", grew ? "pass" : "fail",
        "Scroll grew from \(before) to \(after) nodes."))

    context.store.perform(.open(url(base, path: "/webgl")))
    guard await until(attempts: 100, condition: { settled(context, path: "/webgl") }),
      let webglID = context.store.session.selectedPage?.tab.id
    else {
      rows.append(row("heavy-webgl", "fail", "The WebGL page did not load."))
      return rows
    }
    let webgl = await evaluate(
      runtime, tab: webglID, script: "document.documentElement.dataset.webgl==='1'?1:0")
    rows.append(
      row("heavy-webgl", webgl == "1" ? "pass" : "fail", "WebGL dataset is \(webgl ?? "empty")."))

    context.store.perform(.open(url(base, path: "/video")))
    guard await until(attempts: 100, condition: { settled(context, path: "/video") }),
      let videoID = context.store.session.selectedPage?.tab.id
    else {
      rows.append(row("heavy-video", "fail", "The video page did not load."))
      return rows
    }
    let clipReady = await evaluate(
      runtime, tab: videoID, script: "document.documentElement.dataset.clip==='0'?0:1")
    if clipReady == "0" {
      rows.append(
        row(
          "heavy-video", "blocked",
          "ffmpeg did not produce a clip, so playback was not measured."))
    } else {
      let clicked = await click(runtime, tab: videoID, element: "popup")
      var playback: String?
      _ = await untilReady(attempts: 50) {
        playback = await evaluate(
          runtime, tab: videoID,
          script:
            "(()=>{const v=document.getElementById('clip'),b=document.getElementById('popup'),r=b?.getBoundingClientRect();if(!v)return {paused:true,width:0,error:1};return {paused:v.paused,width:v.videoWidth,error:v.error?v.error.code:0,click:document.documentElement.dataset.playClick||'none',playResult:document.documentElement.dataset.playResult||'pending',userActive:navigator.userActivation?.isActive||false,hasBeenActive:navigator.userActivation?.hasBeenActive||false,button:r?{x:r.x,y:r.y,width:r.width,height:r.height}:null,hit:r?document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)?.id||document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)?.tagName:null,events:Object.fromEntries(['pointerdown','mousedown','mouseup','click'].map(name=>[name,document.documentElement.dataset['probe'+name]||'none']))};})()"
        )
        return playbackSettled(playback)
      }
      rows.append(
        row(
          "heavy-video", clicked && playbackStarted(playback) ? "pass" : "fail",
          "Play click=\(clicked), state \(playback ?? "nothing")."))
    }
    rows.append(
      row(
        "picture-in-picture", "blocked",
        "Picture in Picture opens a visible system panel, so this hidden run does not enter it."))
    _ = keepHidden(&rows, "heavy-done")
    return rows
  }

  private static func dialogs(
    context: NativeBrowserContext, runtime: ARCShaarRuntime, base: URL
  ) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    context.store.perform(.open(url(base, path: "/popup")))
    guard await until(attempts: 150, condition: { settled(context, path: "/popup") }),
      let source = context.store.session.selectedPage?.tab.id
    else {
      rows.append(row("dialogs-popup", "fail", "The popup page did not load."))
      return rows
    }
    for (name, element, opener) in [
      ("dialogs-blank", "blank", "target=_blank"), ("dialogs-window-open", "popup", "window.open"),
    ] {
      context.store.selectPage(source)
      let showing = await until(
        attempts: 40,
        condition: {
          context.store.session.selectedPage?.tab.id == source && settled(context, path: "/popup")
        })
      let prior = Set(allTabs(context).map(\.id))
      let clicked = await clickWhenReady(showing, runtime: runtime, tab: source, element: element)
      let adopted = await until(
        attempts: 80,
        condition: {
          allTabs(context).contains { !prior.contains($0.id) && $0.url.path == "/dest" }
        })
      rows.append(
        row(
          name, clicked && adopted ? "pass" : "fail",
          "\(opener) click=\(clicked), adopted=\(adopted)."))
      guard keepHidden(&rows, name) else { return rows }
    }

    for (path, expected) in [("/missing", 404), ("/error", 500)] {
      guard context.engine.navigateCurrentPage(to: url(base, path: path)),
        await until(attempts: 80, condition: { settled(context, path: path) }),
        let id = context.store.session.selectedPage?.tab.id
      else {
        rows.append(row("dialogs\(path)", "fail", "\(path) did not finish."))
        continue
      }
      let status = await navigationStatus(runtime, tab: id)
      rows.append(
        row(
          "dialogs\(path)", status == expected ? "pass" : "fail",
          "HTTP status \(status.map(String.init) ?? "missing"), expected \(expected)."))
    }

    let offlineStarted = Date()
    let offlineURL = URL(string: "http://127.0.0.1:1/offline")!
    let startedOffline = context.engine.navigateCurrentPage(to: offlineURL)
    let offlineDone = await until(
      attempts: 80,
      condition: {
        context.engine.pages[context.store.session.selectedPage?.tab.id ?? UUID()]?.loading == false
      })
    rows.append(
      row(
        "dialogs-offline",
        startedOffline && offlineDone && context.store.rendererFailures.isEmpty ? "pass" : "fail",
        "Closed-port navigation ended on \(context.store.session.selectedPage?.tab.url.absoluteString ?? "nothing") in \(milliseconds(since: offlineStarted)) ms.",
        ["elapsedMs": milliseconds(since: offlineStarted)]))

    guard context.engine.navigateCurrentPage(to: url(base, path: "/unload")),
      await until(attempts: 80, condition: { settled(context, path: "/unload") }),
      let unloadID = context.store.session.selectedPage?.tab.id
    else {
      rows.append(row("dialogs-beforeunload", "fail", "The beforeunload page did not load."))
      return rows
    }
    let armed = await click(runtime, tab: unloadID, element: "popup")
    let armedState = await evaluate(
      runtime, tab: unloadID, script: "document.documentElement.dataset.armed==='1'?1:0")
    context.store.closeTab(unloadID)
    let decision = await beforeUnloadDecision(context, runtime: runtime, tab: unloadID)
    if context.store.session.page(forTabID: unloadID) != nil {
      _ = await evaluate(runtime, tab: unloadID, script: "window.onbeforeunload=null")
      orderOutVisibleWindows()
      context.store.closeTab(unloadID)
    }
    let dismissed = await until(
      attempts: 40,
      condition: {
        context.store.session.page(forTabID: unloadID) == nil && windowsHidden()
      })
    let status = beforeUnloadStatus(
      armed: armed, armedState: armedState, prompted: decision.prompted,
      cancelled: decision.cancelled, sawVisibleDialog: decision.sawVisibleDialog,
      dismissed: dismissed)
    rows.append(
      row(
        "dialogs-beforeunload", status,
        "Armed=\(armedState ?? "nil"), prompted=\(decision.prompted), cancelled=\(decision.cancelled), sawVisibleDialog=\(decision.sawVisibleDialog), dismissed=\(dismissed)."
      ))
    return rows
  }

  private static func downloads(
    host: NativeBrowserHost, context: NativeBrowserContext, base: URL, root: URL
  ) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    guard let settings = host.settingsController else {
      rows.append(row("downloads", "fail", "Settings are unavailable."))
      return rows
    }
    let directoryA = root.appending(path: "downloads-a")
    let directoryB = root.appending(path: "downloads-b")
    do {
      try FileManager.default.createDirectory(at: directoryA, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: directoryB, withIntermediateDirectories: true)
    } catch {
      rows.append(row("downloads", "fail", error.localizedDescription))
      return rows
    }
    context.store.perform(.open(url(base, path: "/light", query: "n=download")))
    guard await until(attempts: 150, condition: { settled(context, path: "/light") }) else {
      rows.append(row("downloads-a", "fail", "The first profile page did not load."))
      return rows
    }
    let profileA = context.store.session.selectedSpace.profileID
    let appliedA = await settings.state.applyDownloadDirectory(directoryA, for: profileA)
    guard context.engine.navigateCurrentPage(to: url(base, path: "/file-a.txt")) else {
      rows.append(row("downloads-a", "fail", "The download navigation was rejected."))
      return rows
    }
    let finishedA = await until(
      attempts: 300,
      condition: {
        downloadFinished(context, profile: profileA, directory: directoryA)
      })
    rows.append(
      row(
        "downloads-a", appliedA && finishedA ? "pass" : "fail",
        "Profile A folder accepted=\(appliedA), file arrived=\(finishedA)."))

    guard let profileB = settings.createProfile(name: "QA Downloads") else {
      rows.append(row("downloads-b", "fail", "The second profile was not created."))
      return rows
    }
    guard
      context.store.createSpace(
        name: "Downloads", sharingProfile: profileB, tint: .rose)
    else {
      rows.append(row("downloads-b", "fail", "The second profile has no Space."))
      return rows
    }
    context.store.perform(.open(url(base, path: "/light", query: "n=download-b")))
    guard await until(attempts: 150, condition: { settled(context, path: "/light") }) else {
      rows.append(row("downloads-b", "fail", "The second profile page did not load."))
      return rows
    }
    let appliedB = await settings.state.applyDownloadDirectory(directoryB, for: profileB)
    guard context.engine.navigateCurrentPage(to: url(base, path: "/file-b.txt")) else {
      rows.append(row("downloads-b", "fail", "The second download navigation was rejected."))
      return rows
    }
    let finishedB = await until(
      attempts: 300,
      condition: {
        downloadFinished(context, profile: profileB, directory: directoryB)
      })
    let separated = finishedA && finishedB && directoryA.path != directoryB.path
    rows.append(
      row(
        "downloads-b", appliedB && separated ? "pass" : "fail",
        "Profile B folder accepted=\(appliedB), separate file arrived=\(finishedB)."))
    _ = keepHidden(&rows, "downloads-done")
    return rows
  }

  private static func renderer(context: NativeBrowserContext, base: URL) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    let before = Set(rendererPIDs())
    context.store.perform(.open(url(base, path: "/light", query: "n=renderer")))
    guard await until(attempts: 150, condition: { settled(context, path: "/light") }),
      let tab = context.store.session.selectedPage?.tab.id
    else {
      rows.append(row("renderer-setup", "fail", "The renderer page did not load."))
      return rows
    }
    let ranked = rendererPIDs()
    let appeared = ranked.filter { !before.contains($0) }
    let targets = appeared.isEmpty ? Array(ranked.prefix(1)) : appeared
    guard !targets.isEmpty else {
      rows.append(row("renderer-kill", "blocked", "No descendant renderer process was found."))
      return rows
    }
    let signaled = targets.filter { kill($0, SIGKILL) == 0 }
    let stamp = rendererKillStamp(signaled)
    let failed = await until(
      attempts: 100, condition: { context.store.rendererFailures[tab] != nil })
    guard !signaled.isEmpty, failed, let failure = context.store.rendererFailures[tab] else {
      rows.append(
        row(
          "renderer-kill", "fail",
          "Signaled \(signaled), sad tab \(failed), recorded \(context.store.rendererFailures.count), new \(appeared).",
          stamp))
      return rows
    }
    rows.append(
      row(
        "renderer-kill", "pass",
        "Signaled \(signaled) and the tab ended with \(failure.status) exit \(failure.exitCode).",
        stamp))
    let reloaded = context.store.reloadFailedPage(failure.id)
    let recovered = await until(
      attempts: 150,
      condition: {
        context.store.rendererFailures[tab] == nil && settled(context, path: "/light")
      })
    rows.append(
      row(
        "renderer-recover", reloaded && recovered ? "pass" : "fail",
        "Reload accepted=\(reloaded), page returned=\(recovered)."))
    _ = keepHidden(&rows, "renderer-done")
    return rows
  }

  private static func restoreSeed(
    host: NativeBrowserHost, context: NativeBrowserContext, base: URL
  ) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    context.store.perform(.open(url(base, path: "/restore/pinned")))
    guard await until(attempts: 150, condition: { settled(context, path: "/restore/pinned") }),
      let pinned = context.store.session.selectedSpace.selectedTabID
    else {
      rows.append(row("restore-seed", "fail", "The pinned page did not load."))
      return rows
    }
    context.store.togglePin(pinned)
    context.store.perform(.open(url(base, path: "/restore/open")))
    guard await until(attempts: 100, condition: { settled(context, path: "/restore/open") }) else {
      rows.append(row("restore-seed", "fail", "The ordinary page did not load."))
      return rows
    }
    context.store.perform(.open(url(base, path: "/restore/favorite")))
    guard await until(attempts: 100, condition: { settled(context, path: "/restore/favorite") })
    else {
      rows.append(row("restore-seed", "fail", "The favorite page did not load."))
      return rows
    }
    let favored = context.store.addCurrentPageAsFavorite()
    let saved = host.workspace.persistSnapshot()
    do { try host.workspace.flushSaves() } catch {
      rows.append(row("restore-seed", "fail", error.localizedDescription))
      return rows
    }
    let pinnedKept = context.store.session.spaces.flatMap(\.tabs).contains {
      $0.isPinned && $0.url.path == "/restore/pinned"
    }
    rows.append(
      row(
        "restore-seed", saved && favored && pinnedKept ? "pass" : "fail",
        "Saved pinned=\(pinnedKept), favorite=\(favored), snapshot=\(saved)."))
    _ = keepHidden(&rows, "restore-seed")
    return rows
  }

  private static func restoreCheck(context: NativeBrowserContext) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    let tabs = context.store.session.spaces.flatMap(\.tabs)
    let pinned = tabs.contains { $0.isPinned && $0.url.path == "/restore/pinned" }
    let open = tabs.contains { $0.url.path == "/restore/open" }
    let favorite = context.store.session.favorites.contains {
      $0.originalURL.path == "/restore/favorite"
    }
    let restoredPaths: Set<String> = ["/restore/pinned", "/restore/open", "/restore/favorite"]
    let loaded = await until(
      attempts: 150,
      condition: {
        guard let id = context.store.session.selectedPage?.tab.id else { return false }
        return context.engine.pages[id]?.loading == false
          && restoredPaths.contains(context.store.session.selectedPage?.tab.url.path ?? "")
      })
    let document = context.store.session.selectedPage?.tab.url.path ?? ""
    rows.append(
      row(
        "restore-check",
        pinned && open && favorite && loaded ? "pass" : "fail",
        "Pinned=\(pinned), open=\(open), favorite=\(favorite), selected=\(document)."))
    _ = keepHidden(&rows, "restore-check")
    return rows
  }

  private static func downloadFinished(
    _ context: NativeBrowserContext, profile: UUID, directory: URL
  ) -> Bool {
    let prefix = directory.standardizedFileURL.resolvingSymlinksInPath().path
    return context.engine.downloads.items(in: profile).contains { item in
      guard item.state == .finished, let file = item.fileURL else { return false }
      let path = file.standardizedFileURL.resolvingSymlinksInPath().path
      return path == prefix || path.hasPrefix(prefix + "/")
    }
  }

  private static func pageIsLoading(_ context: NativeBrowserContext) -> Bool {
    guard let id = context.store.session.selectedPage?.tab.id else { return false }
    return context.engine.pages[id]?.loading == true
  }

  private static func settled(_ context: NativeBrowserContext, path: String) -> Bool {
    guard let id = context.store.session.selectedPage?.tab.id,
      context.store.session.selectedPage?.tab.url.path == path
    else { return false }
    return context.engine.pages[id]?.loading == false && context.engine.liveTabs.contains(id)
  }

  private static func tabCount(_ context: NativeBrowserContext, space: UUID) -> Int {
    context.store.session.spaces.first { $0.id == space }?.tabs.count ?? 0
  }

  private static func liveCount(_ context: NativeBrowserContext) -> Int {
    context.engine.liveTabs.count
  }

  private static func allTabs(_ context: NativeBrowserContext) -> [BrowserTab] {
    context.store.session.spaces.flatMap(\.tabs) + context.store.session.favoritePages.map(\.tab)
  }

  private static func windowsHidden() -> Bool {
    NSApp.modalWindow == nil && NSApp.windows.allSatisfy { !$0.isVisible }
  }

  private static func orderOutVisibleWindows() {
    NSApp.modalWindow?.orderOut(nil)
    for window in NSApp.windows where window.isVisible {
      window.orderOut(nil)
    }
  }

  @discardableResult
  private static func keepHidden(_ rows: inout [[String: Any]], _ name: String) -> Bool {
    let visible = NSApp.windows.filter(\.isVisible)
    guard !visible.isEmpty || NSApp.modalWindow != nil else { return true }
    let count = visible.count
    orderOutVisibleWindows()
    rows.append(
      row(
        name, "fail",
        "A window became visible (\(count)) and was ordered back out."))
    return false
  }

  static func wholeNumber(_ value: String?) -> Int? {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    return Int(text)
  }

  static func reloadDuringNavigationWasFetched(_ value: String?) -> Bool {
    guard let requestCount = wholeNumber(value) else { return false }
    return requestCount >= 2
  }

  static func playbackStarted(_ value: String?) -> Bool {
    guard let evidence = playbackEvidence(value),
      let paused = evidence["paused"] as? Bool,
      let width = integer(evidence["width"]),
      let error = integer(evidence["error"])
    else { return false }
    return !paused && width > 0 && error == 0
  }

  private static func evaluate(
    _ runtime: ARCShaarRuntime, tab: UUID, script: String
  ) async -> String? {
    await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
  }

  private static func click(
    _ runtime: ARCShaarRuntime, tab: UUID, element: String
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.submitTrustedProbeClick(inTabID: tab.uuidString, elementID: element) {
        continuation.resume(returning: $0)
      }
    }
  }

  private static func clickWhenReady(
    _ ready: Bool, runtime: ARCShaarRuntime, tab: UUID, element: String
  ) async -> Bool {
    guard ready else { return false }
    return await click(runtime, tab: tab, element: element)
  }

  private static let processListingTimeout: TimeInterval = 5

  /// The host process list is larger than a pipe, so `ps` writes a file. A full pipe stalls
  /// `ps` and an untimed wait never returns.
  private static func rendererPIDs() -> [Int32] {
    let listing = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arcusis-renderer-ps-\(getpid()).txt")
    FileManager.default.createFile(atPath: listing.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: listing) }
    guard let output = try? FileHandle(forWritingTo: listing) else { return [] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,rss=,command="]
    process.standardOutput = output
    guard processFinished(process, within: processListingTimeout) else {
      try? output.close()
      return []
    }
    try? output.close()
    guard let text = try? String(contentsOf: listing, encoding: .utf8) else { return [] }
    var parents: [Int32: Int32] = [:]
    var rss: [Int32: Int] = [:]
    var commands: [Int32: String] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(
        maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
      guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else {
        continue
      }
      parents[pid] = ppid
      rss[pid] = Int(parts[2]) ?? 0
      commands[pid] = String(parts[3])
    }
    let root = getpid()
    var descendants: Set<Int32> = []
    var changed = true
    while changed {
      changed = false
      for (pid, ppid) in parents where ppid == root || descendants.contains(ppid) {
        if descendants.insert(pid).inserted { changed = true }
      }
    }
    return descendants.filter { commands[$0]?.contains("--type=renderer") == true }
      .sorted { (rss[$0] ?? 0) > (rss[$1] ?? 0) }
  }

  private static func processFinished(_ process: Process, within seconds: TimeInterval) -> Bool {
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      return false
    }
    if finished.wait(timeout: .now() + seconds) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 1) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 1)
      }
      return false
    }
    return process.terminationStatus == 0
  }

  private static func rendererKillStamp(_ signaled: [Int32]) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return [
      "signaledPIDs": signaled.map { Int($0) },
      "signaledAt": formatter.string(from: Date()),
    ]
  }

  private static func url(_ base: URL, path: String, query: String? = nil) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    components?.path = path
    components?.query = query
    components?.fragment = nil
    return components?.url ?? base
  }

  private static func milliseconds(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
  }

  private static func until(attempts: Int, condition: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  private static func untilReady(attempts: Int, condition: () async -> Bool) async -> Bool {
    for _ in 0..<attempts {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
  }

  private static func navigationStatus(_ runtime: ARCShaarRuntime, tab: UUID) async -> Int? {
    wholeNumber(
      await evaluate(
        runtime, tab: tab,
        script:
          "(()=>{const e=performance.getEntriesByType('navigation')[0];return e?e.responseStatus:0})()"
      ))
  }

  private static func beforeUnloadDecision(
    _ context: NativeBrowserContext, runtime: ARCShaarRuntime, tab: UUID
  ) async -> (prompted: Bool, cancelled: Bool, sawVisibleDialog: Bool) {
    var prompted = false
    for _ in 0..<40 {
      if !windowsHidden() { return (prompted, false, true) }
      if context.store.session.page(forTabID: tab) == nil { return (prompted, false, false) }
      if prompted { return (true, true, false) }
      let flag = await evaluate(
        runtime, tab: tab, script: "document.documentElement.dataset.prompted==='1'?1:0")
      if flag == "1" { prompted = true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    if !windowsHidden() { return (prompted, false, true) }
    if prompted, context.store.session.page(forTabID: tab) != nil { return (true, true, false) }
    return (prompted, false, false)
  }

  static func beforeUnloadStatus(
    armed: Bool, armedState: String?, prompted: Bool, cancelled: Bool, sawVisibleDialog: Bool,
    dismissed: Bool
  ) -> String {
    if sawVisibleDialog { return "blocked" }
    if armed && armedState == "1" && prompted && cancelled && dismissed { return "pass" }
    return "fail"
  }

  static func playbackSettled(_ value: String?) -> Bool {
    guard let evidence = playbackEvidence(value) else { return false }
    let error: Int?
    if let rawError = evidence["error"] {
      guard let parsedError = integer(rawError) else { return false }
      error = parsedError
    } else {
      error = nil
    }
    if let error, error != 0 { return true }
    guard let paused = evidence["paused"] as? Bool,
      let width = integer(evidence["width"])
    else { return false }
    return !paused && width > 0
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    return number as? Int
  }

  private static func playbackEvidence(_ value: String?) -> [String: Any]? {
    guard let value, let data = value.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func row(
    _ name: String, _ status: String, _ detail: String, _ extra: [String: Any] = [:]
  ) -> [String: Any] {
    var value: [String: Any] = ["name": name, "status": status, "detail": detail]
    for (key, item) in extra { value[key] = item }
    return value
  }

  private static func write(_ value: [String: Any], to url: URL) {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
