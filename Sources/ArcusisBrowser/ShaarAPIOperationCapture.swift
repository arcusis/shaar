// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation

/// Watches GraphQL and tRPC calls while DevTools is open.
/// The network event leaves out post data, so this reads the request the page is
/// sending and keeps only the operation name, its type, and whether the JSON has errors.
enum ShaarAPIOperationScript {
  static let snapshot =
    "(globalThis.__shaarAPIOperations&&globalThis.__shaarAPIOperations.snapshot())||\"[]\""
  static let dispose =
    "(globalThis.__shaarAPIOperations&&globalThis.__shaarAPIOperations.dispose())||true"

  static let source = #"""
      (() => {
        const key = "__shaarAPIOperations";
        if (globalThis[key] && globalThis[key].installed) return true;
        const originalFetch = globalThis.fetch ? globalThis.fetch.bind(globalThis) : null;
        const xhrOpen = XMLHttpRequest.prototype.open;
        const xhrSend = XMLHttpRequest.prototype.send;
        const log = [];
        let seq = 0;
        const install = Math.random().toString(36).slice(2);

        function resolveURL(value) {
          try { return new URL(String(value), location.href).href; }
          catch (error) { return String(value || ""); }
        }

        function looksLikeURL(url) {
          const lower = String(url || "").toLowerCase();
          if (lower.indexOf("graphql") !== -1) return true;
          try {
            const parts = new URL(url).pathname.split("/");
            const folded = parts.map(part => part.toLowerCase());
            const index = folded.lastIndexOf("trpc");
            if (index < 0 || index + 1 >= parts.length) return false;
            const prefix = parts.slice(0, index).filter(Boolean);
            if (!prefix.length) return true;
            return prefix[prefix.length - 1].toLowerCase() === "api";
          } catch (error) { return false; }
        }

        function keywordStart(text) {
          const words = ["query", "mutation", "subscription"];
          for (let index = 0; index < words.length; index += 1) {
            const word = words[index];
            if (text.indexOf(word) !== 0) continue;
            const next = text.charAt(word.length);
            if (!next || next === " " || next === "\n" || next === "\t" || next === "(" || next === "{") {
              return true;
            }
          }
          return false;
        }

        function looksLikeDocument(text) {
          const trimmed = String(text || "").trim();
          if (!trimmed) return false;
          if (trimmed.charAt(0) === "{") return trimmed.indexOf(":") === -1;
          return keywordStart(trimmed);
        }

        function stripValue(value) {
          if (Array.isArray(value)) {
            const items = [];
            for (let index = 0; index < value.length; index += 1) {
              const next = stripValue(value[index]);
              if (next) items.push(next);
            }
            return items.length ? items : null;
          }
          if (!value || typeof value !== "object") return null;
          const out = {};
          if (typeof value.query === "string") out.query = value.query.slice(0, 4000);
          if (typeof value.operationName === "string") out.operationName = value.operationName.slice(0, 200);
          const persisted = value.extensions && value.extensions.persistedQuery;
          if (persisted && typeof persisted === "object") out.extensions = { persistedQuery: {} };
          if (!out.query && !out.operationName && !out.extensions) return null;
          return out;
        }

        function trimBody(body) {
          if (typeof body !== "string" || !body) return null;
          const sliced = body.slice(0, 16000);
          try {
            const cleaned = stripValue(JSON.parse(sliced));
            if (!cleaned) return null;
            return JSON.stringify(cleaned).slice(0, 8000);
          } catch (error) {
            if (sliced.indexOf("query=") !== -1 || sliced.indexOf("operationName=") !== -1) {
              return sliced.slice(0, 8000);
            }
            if (looksLikeDocument(sliced)) return sliced.slice(0, 8000);
            return null;
          }
        }

        function jsonHasErrors(value) {
          if (Array.isArray(value)) {
            for (let index = 0; index < value.length; index += 1) {
              if (jsonHasErrors(value[index])) return true;
            }
            return false;
          }
          if (!value || typeof value !== "object") return false;
          if (Array.isArray(value.errors) && value.errors.length > 0) return true;
          if (value.error && typeof value.error === "object") return true;
          return false;
        }

        function responseHasErrors(text) {
          try { return jsonHasErrors(JSON.parse(String(text || "").slice(0, 8000))); }
          catch (error) { return false; }
        }

        function remember(method, url, body) {
          const trimmed = trimBody(body);
          if (!trimmed && !looksLikeURL(url)) return null;
          if (log.length >= 100) log.shift();
          const entry = {
            install: install,
            id: ++seq,
            method: String(method || "GET").toUpperCase(),
            url: url,
            postData: trimmed,
            responseHasErrors: false
          };
          log.push(entry);
          return entry;
        }

        function noteResponse(entry, text) {
          if (!entry) return;
          try { entry.responseHasErrors = responseHasErrors(text); }
          catch (error) {}
        }

        function readBody(body) {
          if (typeof body === "string") return body;
          if (typeof FormData !== "undefined" && body instanceof FormData) {
            const operations = body.get("operations");
            if (typeof operations === "string") return operations;
          }
          return null;
        }

        if (originalFetch) {
          globalThis.fetch = function (input, init) {
            let url = "";
            let method = "GET";
            try {
              if (typeof input === "string" || input instanceof URL) {
                url = resolveURL(input);
                method = String((init && init.method) || "GET").toUpperCase();
              } else if (input && typeof input.url === "string") {
                url = resolveURL(input.url);
                method = String((init && init.method) || input.method || "GET").toUpperCase();
              }
            } catch (error) {}
            const initBody = init && Object.prototype.hasOwnProperty.call(init, "body") ? init.body : null;
            const entry = remember(method, url, readBody(initBody));
            const promise = originalFetch.apply(this, arguments);
            if (entry && promise && typeof promise.then === "function") {
              promise.then(function (response) {
                try {
                  response.clone().text().then(function (text) {
                    noteResponse(entry, text);
                  }).catch(function () {});
                } catch (error) {}
              }).catch(function () {});
            }
            return promise;
          };
        }

        XMLHttpRequest.prototype.open = function (method, url) {
          try {
            this.__shaarAPIMeta = {
              method: String(method || "GET").toUpperCase(),
              url: resolveURL(url)
            };
          } catch (error) {}
          return xhrOpen.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function (body) {
          const meta = this.__shaarAPIMeta;
          const entry = meta ? remember(meta.method, meta.url, readBody(body)) : null;
          if (entry) {
            this.addEventListener("load", function () {
              try { noteResponse(entry, this.responseText); }
              catch (error) {}
            });
          }
          return xhrSend.apply(this, arguments);
        };

        globalThis[key] = {
          installed: true,
          snapshot: function () { return JSON.stringify(log); },
          dispose: function () {
            if (originalFetch) globalThis.fetch = originalFetch;
            XMLHttpRequest.prototype.open = xhrOpen;
            XMLHttpRequest.prototype.send = xhrSend;
            try { delete globalThis[key]; }
            catch (error) { globalThis[key] = undefined; }
            return true;
          }
        };
        return true;
      })()
    """#
}

@MainActor enum ShaarAPIOperationCapture {
  static func install(
    runtime: ARCShaarRuntime, target: SiteControlTarget, windowID: String
  ) async -> String? {
    let added = await call(
      runtime, method: "Page.addScriptToEvaluateOnNewDocument",
      params: ["source": ShaarAPIOperationScript.source], target: target, windowID: windowID)
    let identifier = added?["identifier"] as? String
    let evaluated = await evaluate(runtime: runtime, target: target, windowID: windowID)
    if identifier == nil && !evaluated { return nil }
    return identifier ?? ""
  }

  static func evaluate(
    runtime: ARCShaarRuntime, target: SiteControlTarget, windowID: String
  ) async -> Bool {
    let result = await call(
      runtime, method: "Runtime.evaluate",
      params: ["expression": ShaarAPIOperationScript.source, "returnByValue": true],
      target: target, windowID: windowID)
    return flag(result)
  }

  static func snapshot(
    runtime: ARCShaarRuntime, target: SiteControlTarget, windowID: String
  ) async -> String? {
    let result = await call(
      runtime, method: "Runtime.evaluate",
      params: [
        "expression": ShaarAPIOperationScript.snapshot,
        "returnByValue": true,
      ],
      target: target, windowID: windowID)
    return (result?["result"] as? [String: Any])?["value"] as? String
  }

  static func remove(
    runtime: ARCShaarRuntime, target: SiteControlTarget, windowID: String,
    identifier: String?, disposeScript: Bool
  ) async {
    if let identifier, !identifier.isEmpty {
      _ = await call(
        runtime, method: "Page.removeScriptToEvaluateOnNewDocument",
        params: ["identifier": identifier], target: target, windowID: windowID)
    }
    guard disposeScript else { return }
    _ = await call(
      runtime, method: "Runtime.evaluate",
      params: ["expression": ShaarAPIOperationScript.dispose, "returnByValue": true],
      target: target, windowID: windowID)
  }

  private static func flag(_ result: [String: Any]?) -> Bool {
    guard let result, result["exceptionDetails"] == nil else { return false }
    let value = (result["result"] as? [String: Any])?["value"]
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.boolValue }
    return false
  }

  private static func call(
    _ runtime: ARCShaarRuntime, method: String, params: [String: Any],
    target: SiteControlTarget, windowID: String
  ) async -> [String: Any]? {
    do {
      return try await runtime.developerCall(
        method, params: params, tabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: windowID)
    } catch {
      return nil
    }
  }
}
