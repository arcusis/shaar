// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import JavaScriptCore

enum AgentCopyScope: String, Equatable {
  case page
  case element
}

struct AgentCopyBuilt: Equatable {
  var markdown: String
  var bytes: Int
  var scope: AgentCopyScope
  var source: String
  var ruleCount: Int
  var errorCount: Int
  var requestCount: Int
  var consoleRecording: Bool
  var stylesOmitted: Bool
  var screenshotBytes: Int
  var png: Data?
}

enum AgentCopySize {
  static func text(for bytes: Int) -> String {
    let count = max(0, bytes)
    if count < 1024 { return "\(count) B" }
    if count < 10 * 1024 {
      let tenths = (count * 10) / 1024
      return "\(tenths / 10).\(tenths % 10) KB"
    }
    let whole = (count + 512) / 1024
    return "\(whole) KB"
  }
}

enum AgentCopyGuard {
  static func accepts(_ markdown: String) -> Bool {
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      if secretHeader(line) && !line.lowercased().contains("[redacted]") { return false }
      if bearerMissingRedaction(line) { return false }
      if tokenMissingRedaction(line) { return false }
    }
    return true
  }

  private static func secretHeader(_ line: Substring) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
    let names = ["cookie:", "authorization:", "set-cookie:", "proxy-authorization:"]
    return names.contains { trimmed.hasPrefix($0) }
  }

  private static func bearerMissingRedaction(_ line: Substring) -> Bool {
    let lower = line.lowercased()
    return lower.contains("bearer ") && !lower.contains("bearer [redacted]")
  }

  private static func tokenMissingRedaction(_ line: Substring) -> Bool {
    let lower = line.lowercased()
    return lower.contains("token=") && !lower.contains("token=[redacted]")
  }
}

enum AgentCopyScript {
  static func source(host: Bundle = .main, fallback: (() -> Bundle)? = nil) throws -> String {
    let bundle = PackagedResourceBundle.resolve(
      named: "ArcusisBrowser_ArcusisBrowser", in: host, fallback: fallback ?? { .module })
    guard
      let bundle,
      let url = bundle.url(
        forResource: "agent-copy", withExtension: "js", subdirectory: "DevToolsOverlay"),
      let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty
    else {
      throw InspectorFailure(ShellL10n.string("The agent packet is unavailable."))
    }
    return value
  }
}

enum AgentCopyEngine {
  @MainActor
  static func build(script: String, input: [String: Any], png: Data?) throws -> AgentCopyBuilt {
    let context = JSContext()
    var thrown: String?
    context?.exceptionHandler = { _, value in
      thrown = value?.toString()
    }
    guard let context else {
      throw InspectorFailure(ShellL10n.string("The agent packet is unavailable."))
    }
    let data = try JSONSerialization.data(withJSONObject: input)
    guard data.count <= 200_000, let text = String(data: data, encoding: .utf8) else {
      throw InspectorFailure(ShellL10n.string("The agent packet is unavailable."))
    }
    context.evaluateScript(script)
    if let thrown { throw InspectorFailure(AgentCopySecrets.scrub(thrown)) }
    context.setObject(text, forKeyedSubscript: "shaarAgentCopyInput" as NSString)
    let result = context.evaluateScript("ShaarAgentCopy.buildJSON(shaarAgentCopyInput)")
    if let thrown { throw InspectorFailure(AgentCopySecrets.scrub(thrown)) }
    guard
      let encoded = result?.toString(), encoded != "undefined",
      let body = encoded.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let markdown = object["markdown"] as? String, !markdown.isEmpty
    else {
      throw InspectorFailure(ShellL10n.string("The agent packet is unavailable."))
    }
    let screenshotBytes = png?.count ?? 0
    let bytes = markdown.utf8.count + screenshotBytes
    return AgentCopyBuilt(
      markdown: markdown,
      bytes: bytes,
      scope: AgentCopyScope(rawValue: object["scope"] as? String ?? "") ?? .page,
      source: object["source"] as? String ?? "",
      ruleCount: count(object["rules"]),
      errorCount: count(object["errors"]),
      requestCount: count(object["requests"]),
      consoleRecording: object["consoleRecording"] as? Bool ?? false,
      stylesOmitted: object["stylesOmitted"] as? Bool ?? false,
      screenshotBytes: screenshotBytes,
      png: png)
  }

  private static func count(_ value: Any?) -> Int {
    (value as? [Any])?.count ?? 0
  }
}

enum AgentCopySecrets {
  static func scrub(_ text: String) -> String {
    var result = text
    for marker in ["wss://", "ws://"] {
      guard let range = result.range(of: marker) else { continue }
      result = String(result[..<range.lowerBound]) + marker + "[redacted]"
    }
    result = scrubRuns(result)
    if result.count <= 240 { return result }
    return String(result.prefix(240))
  }

  private static func scrubRuns(_ text: String) -> String {
    var result = ""
    var run = ""
    func flush() {
      if run.count >= 20 && run.allSatisfy(tokenCharacter) {
        result += "[redacted]"
      } else {
        result += run
      }
      run = ""
    }
    for character in text {
      if tokenCharacter(character) {
        run.append(character)
      } else {
        flush()
        result.append(character)
      }
    }
    flush()
    return result
  }

  private static func tokenCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_"
  }
}

enum AgentCopySelector {
  static func accepted(_ value: String?) -> String? {
    guard let value,
      value.range(of: #"^#[A-Za-z][A-Za-z0-9_-]{0,40}$"#, options: .regularExpression) != nil
    else { return nil }
    return value
  }
}
