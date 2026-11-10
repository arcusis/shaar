// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What the app knows about one tab when deciding whether Chromium may discard it.
public struct SleepingTabFacts: Equatable, Sendable {
  public var id: UUID
  public var host: String
  public var isPinned: Bool
  public var keepAlive: Bool
  public var isVisible: Bool
  public var isPrivateActive: Bool
  public var isPlaying: Bool
  public var isCapturing: Bool
  public var formEdited: Bool
  public var hasInspector: Bool
  public var hasDeveloperTools: Bool
  public var profileIsDownloading: Bool
  public var lastActive: Date

  public init(
    id: UUID, host: String, isPinned: Bool, keepAlive: Bool, isVisible: Bool,
    isPrivateActive: Bool, isPlaying: Bool, isCapturing: Bool, formEdited: Bool,
    hasInspector: Bool, hasDeveloperTools: Bool, profileIsDownloading: Bool, lastActive: Date
  ) {
    self.id = id
    self.host = host
    self.isPinned = isPinned
    self.keepAlive = keepAlive
    self.isVisible = isVisible
    self.isPrivateActive = isPrivateActive
    self.isPlaying = isPlaying
    self.isCapturing = isCapturing
    self.formEdited = formEdited
    self.hasInspector = hasInspector
    self.hasDeveloperTools = hasDeveloperTools
    self.profileIsDownloading = profileIsDownloading
    self.lastActive = lastActive
  }
}

/// Idle and memory-pressure discard rules. The engine still decides whether a discard is allowed.
public struct SleepingTabsPolicy: Equatable, Sendable {
  public static let defaultTimeout: TimeInterval = 2 * 60 * 60
  public static let memoryPressureLimit = 4

  public var enabled: Bool
  public var timeout: TimeInterval
  public var neverSleepHosts: Set<String>

  public init(
    enabled: Bool = true, timeout: TimeInterval = SleepingTabsPolicy.defaultTimeout,
    neverSleepHosts: Set<String> = []
  ) {
    self.enabled = enabled
    self.timeout = timeout
    self.neverSleepHosts = neverSleepHosts
  }

  /// A hostname, a pasted address, or a path. Leading www and a port are dropped.
  public static func hostKey(_ value: String) -> String {
    var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if host.hasPrefix("http://") || host.hasPrefix("https://") || host.hasPrefix("//") {
      let absolute = host.hasPrefix("//") ? "https:" + host : host
      if let name = URL(string: absolute)?.host() {
        host = name
      }
    } else if let slash = host.firstIndex(of: "/") {
      host = String(host[..<slash])
    }
    if let at = host.lastIndex(of: "@") {
      host = String(host[host.index(after: at)...])
    }
    if !host.hasPrefix("["), let colon = host.firstIndex(of: ":") {
      host = String(host[..<colon])
    }
    if host.hasPrefix("www.") {
      host.removeFirst(4)
    }
    return host
  }

  /// The site itself and any subdomain. `example.com` covers `mail.example.com`.
  public func neverSleeps(_ host: String) -> Bool {
    let key = Self.hostKey(host)
    guard !key.isEmpty else { return false }
    return neverSleepHosts.contains { rule in
      let entry = Self.hostKey(rule)
      return !entry.isEmpty && (key == entry || key.hasSuffix("." + entry))
    }
  }

  public func isExempt(_ facts: SleepingTabFacts) -> Bool {
    if !enabled { return true }
    if facts.isPinned || facts.keepAlive || facts.isVisible || facts.isPrivateActive {
      return true
    }
    if facts.isPlaying || facts.isCapturing || facts.formEdited { return true }
    if facts.hasInspector || facts.hasDeveloperTools || facts.profileIsDownloading { return true }
    return neverSleeps(facts.host)
  }

  public func isIdle(_ facts: SleepingTabFacts, now: Date) -> Bool {
    if isExempt(facts) { return false }
    return now.timeIntervalSince(facts.lastActive) >= timeout
  }

  public func idleTabs(_ tabs: [SleepingTabFacts], now: Date) -> [UUID] {
    tabs.filter { isIdle($0, now: now) }.map(\.id)
  }

  /// Oldest eligible tabs first. Equal ages keep the order the window listed them.
  /// The caller drops tabs that are already sleeping, then keeps `memoryPressureLimit`.
  public func memoryPressureTabs(_ tabs: [SleepingTabFacts]) -> [UUID] {
    let eligible = tabs.enumerated().filter { !isExempt($0.element) }
    let oldest = eligible.sorted { left, right in
      if left.element.lastActive != right.element.lastActive {
        return left.element.lastActive < right.element.lastActive
      }
      return left.offset < right.offset
    }
    return oldest.map(\.element.id)
  }
}

public enum SleepingTabPreferences {
  public static let enabledKey = "settingsSleepInactiveTabs"
  public static let timeoutMinutesKey = "settingsSleepTimeoutMinutes"
  public static let neverSleepHostsKey = "settingsNeverSleepHosts"
  public static let defaultTimeoutMinutes = 120
  public static let timeoutChoices = [5, 15, 30, 60, 120, 360]

  public static func policy(defaults: UserDefaults = .standard) -> SleepingTabsPolicy {
    let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
    let storedMinutes = defaults.object(forKey: timeoutMinutesKey) as? Int ?? defaultTimeoutMinutes
    let minutes = timeoutChoices.contains(storedMinutes) ? storedMinutes : defaultTimeoutMinutes
    let text = defaults.string(forKey: neverSleepHostsKey) ?? ""
    return SleepingTabsPolicy(
      enabled: enabled, timeout: TimeInterval(minutes * 60), neverSleepHosts: hosts(from: text))
  }

  public static func hosts(from text: String) -> Set<String> {
    let separators = CharacterSet.whitespacesAndNewlines.union(
      CharacterSet(charactersIn: ","))
    var hosts: Set<String> = []
    for part in text.components(separatedBy: separators) {
      let host = SleepingTabsPolicy.hostKey(part)
      if !host.isEmpty { hosts.insert(host) }
    }
    return hosts
  }
}

/// The page's edited-form signal. A missing result stays awake, and so does a
/// page whose iframe cannot be read. Open shadow roots are checked with the page.
public enum SleepingFormSignal {
  public static let script = """
    ({edited:(function(){
      function dirty(root){
        return [...root.querySelectorAll('input,textarea,select,[contenteditable]')].some(e=>{
          if(e.isContentEditable)return true;
          if(e instanceof HTMLInputElement){
            if(e.type==='checkbox'||e.type==='radio')return e.checked!==e.defaultChecked;
            return e.value!==e.defaultValue;
          }
          if(e instanceof HTMLTextAreaElement)return e.value!==e.defaultValue;
          if(e instanceof HTMLSelectElement)return [...e.options].some(o=>o.selected!==o.defaultSelected);
          return true;
        });
      }
      function walk(root){
        if(!root)return true;
        if(dirty(root))return true;
        for(const el of root.querySelectorAll('*')){
          if(el.shadowRoot&&walk(el.shadowRoot))return true;
        }
        for(const frame of root.querySelectorAll('iframe,frame')){
          let doc;
          try{doc=frame.contentDocument;}catch(e){return true;}
          if(walk(doc))return true;
        }
        return false;
      }
      return walk(document);
    })()})
    """

  public static func edited(_ result: String?) -> Bool? {
    guard let result, let data = result.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let value = object["edited"] as? Bool { return value }
    if let number = object["edited"] as? NSNumber { return number.boolValue }
    return nil
  }
}
