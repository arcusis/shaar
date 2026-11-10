// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Shaar DevTools overlay module. The Chromium frontend loads this file once
// overlay registration from issue 1469 exists. Until then the browser panel
// calls ShaarAgentCopy.buildJSON, and the page collector calls collect.

(function (root) {
  const LIMITS = {
    html: 2048,
    rules: 12,
    declarationsPerRule: 8,
    declarations: 24,
    errors: 8,
    requests: 8,
    headers: 4,
    line: 180,
    markdown: 12000,
  };

  const DROP_TAGS = {
    script: true,
    style: true,
    noscript: true,
    template: true,
    input: true,
    textarea: true,
    select: true,
    option: true,
  };

  const VOID_TAGS = {
    input: true,
  };

  const SECRET_HEADERS = {
    cookie: true,
    authorization: true,
    "set-cookie": true,
    "proxy-authorization": true,
  };

  function clip(value) {
    const text = String(value == null ? "" : value);
    if (text.length <= LIMITS.line) return text;
    return text.slice(0, LIMITS.line);
  }

  function utf8Count(text) {
    let count = 0;
    for (const symbol of text) {
      const code = symbol.codePointAt(0);
      if (code <= 0x7f) count += 1;
      else if (code <= 0x7ff) count += 2;
      else if (code <= 0xffff) count += 3;
      else count += 4;
    }
    return count;
  }

  function redact(value) {
    let text = String(value == null ? "" : value);
    text = text.replace(
      /(^|\n)([ \t]*)(set-cookie|proxy-authorization|authorization|cookie)([ \t]*:[ \t]*)([^\n]*)/gi,
      function (_, lead, indent, name) {
        return lead + indent + name + ": [redacted]";
      }
    );
    text = text.replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, "Bearer [redacted]");
    text = text.replace(
      /([?&])(access_token|id_token|refresh_token|api_key|apikey|api-key|password|passwd|secret|token)=([^&#\s]*)/gi,
      function (_, sep, name) {
        return sep + name + "=[redacted]";
      }
    );
    text = text.replace(/[A-Za-z0-9._%+-]+:[^@\s/]{1,80}@/g, "[redacted]@");
    text = text.replace(
      /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g,
      "[redacted]"
    );
    return text;
  }

  function escapeText(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function escapeAttr(value) {
    return escapeText(value).replace(/"/g, "&quot;");
  }

  function cleanAttributes(raw) {
    let body = String(raw || "").trim();
    if (body.endsWith("/")) body = body.slice(0, -1).trim();
    const space = body.search(/\s/);
    if (space < 0) return body.toLowerCase();
    const name = body.slice(0, space).toLowerCase();
    const rest = body.slice(space);
    const kept = [];
    const pattern = /([A-Za-z_:][\w:.-]*)\s*=\s*"([^"]*)"/g;
    let match = pattern.exec(rest);
    while (match) {
      const key = match[1].toLowerCase();
      const dropped = key.indexOf("on") === 0 || key === "value" || key === "srcset"
        || key === "style" || key === "data-shaar-agent";
      if (!dropped) kept.push(match[1] + '="' + escapeAttr(match[2]) + '"');
      match = pattern.exec(rest);
    }
    if (!kept.length) return name;
    return name + " " + kept.join(" ");
  }

  function tagName(raw) {
    const body = String(raw || "").trim().replace(/^\//, "");
    const space = body.search(/\s/);
    const name = space < 0 ? body : body.slice(0, space);
    return name.toLowerCase();
  }

  function trimHTML(source) {
    const input = String(source || "");
    let index = 0;
    let out = "";
    while (index < input.length && out.length < LIMITS.html) {
      if (input.slice(index, index + 4) === "<!--") {
        const end = input.indexOf("-->", index + 4);
        index = end < 0 ? input.length : end + 3;
        continue;
      }
      if (input[index] !== "<") {
        const next = input.indexOf("<", index);
        const text = input.slice(index, next < 0 ? input.length : next).slice(0, 300);
        out += text;
        index = next < 0 ? input.length : next;
        continue;
      }
      const close = input.indexOf(">", index + 1);
      if (close < 0) break;
      const raw = input.slice(index + 1, close);
      const name = tagName(raw);
      if (name && DROP_TAGS[name]) {
        if (raw.trim().endsWith("/") || VOID_TAGS[name]) {
          index = close + 1;
          continue;
        }
        const lower = input.toLowerCase();
        const endTag = "</" + name;
        const end = lower.indexOf(endTag, close + 1);
        if (end < 0) {
          index = input.length;
          continue;
        }
        const finish = input.indexOf(">", end);
        index = finish < 0 ? input.length : finish + 1;
        continue;
      }
      if (raw.trim().indexOf("/") === 0) {
        out += "</" + name + ">";
      } else {
        out += "<" + cleanAttributes(raw) + ">";
      }
      index = close + 1;
    }
    return redact(out).slice(0, LIMITS.html);
  }

  function selectorText(rule) {
    const selectors = rule && rule.selectorList && rule.selectorList.selectors;
    if (Array.isArray(selectors) && selectors.length) {
      const names = [];
      for (const item of selectors) {
        const text = item && item.text ? String(item.text) : "";
        if (text) names.push(text);
      }
      if (names.length) return names.join(", ");
    }
    if (rule && typeof rule.selector === "string") return rule.selector;
    return "";
  }

  function propertiesOf(style) {
    if (!style) return [];
    if (Array.isArray(style.cssProperties)) return style.cssProperties;
    if (Array.isArray(style)) return style;
    return [];
  }

  function consider(selector, properties, winners, ruleIndex) {
    const local = new Map();
    for (const prop of properties) {
      if (!prop || prop.disabled || prop.implicit) continue;
      const name = String(prop.name || "").trim();
      if (!name) continue;
      local.set(name, {
        selector: selector || "(rule)",
        name: name,
        value: redact(clip(prop.value || "")),
        ruleIndex: ruleIndex,
      });
    }
    for (const item of local.values()) winners.set(item.name, item);
  }

  function winningRules(matched) {
    const source = matched && typeof matched === "object" ? matched : {};
    const winners = new Map();
    let ruleIndex = 0;
    const matches = Array.isArray(source.matchedCSSRules) ? source.matchedCSSRules : [];
    for (const entry of matches) {
      const rule = entry && entry.rule ? entry.rule : entry;
      if (!rule) continue;
      consider(selectorText(rule), propertiesOf(rule.style), winners, ruleIndex);
      ruleIndex += 1;
    }
    const inline = source.inlineStyle || source.inline;
    if (inline) {
      consider("element.style", propertiesOf(inline.style || inline), winners, ruleIndex);
    }
    const grouped = new Map();
    for (const item of winners.values()) {
      if (!grouped.has(item.ruleIndex)) {
        grouped.set(item.ruleIndex, { selector: item.selector, declarations: [] });
      }
      grouped.get(item.ruleIndex).declarations.push({ name: item.name, value: item.value });
    }
    const rules = [];
    let declarations = 0;
    const indexes = Array.from(grouped.keys()).sort(function (left, right) {
      return left - right;
    });
    for (const index of indexes) {
      if (rules.length >= LIMITS.rules || declarations >= LIMITS.declarations) break;
      const bucket = grouped.get(index);
      const kept = [];
      for (const declaration of bucket.declarations) {
        if (kept.length >= LIMITS.declarationsPerRule) break;
        if (declarations >= LIMITS.declarations) break;
        kept.push(declaration);
        declarations += 1;
      }
      if (kept.length) rules.push({ selector: bucket.selector, declarations: kept });
    }
    return rules;
  }

  function headerRows(value) {
    if (!Array.isArray(value)) return [];
    const rows = [];
    for (const item of value) {
      if (rows.length >= LIMITS.headers) break;
      if (!item) continue;
      const name = clip(item.name || "");
      if (!name) continue;
      rows.push({ name: name, value: item.value == null ? "" : String(item.value) });
    }
    return rows;
  }

  function headerLine(row) {
    const name = String(row.name || "");
    if (SECRET_HEADERS[name.toLowerCase()]) return name + ": [redacted]";
    return name + ": " + redact(clip(row.value || ""));
  }

  function normalizeRequest(row) {
    const status = Number(row && (row.status || row.responseStatus)) || 0;
    const failed = status >= 400 || Boolean(row && row.error);
    if (!failed) return null;
    return {
      method: clip(row.method || "GET").slice(0, 16) || "GET",
      url: redact(clip(row.url || row.name || "")),
      status: status,
      requestHeaders: headerRows(row.requestHeaders || row.headers),
      responseHeaders: headerRows(row.responseHeaders),
    };
  }

  function resourceFailures() {
    const performanceAPI = root.performance;
    if (!performanceAPI || typeof performanceAPI.getEntriesByType !== "function") return [];
    const rows = [];
    const entries = performanceAPI.getEntriesByType("resource") || [];
    for (const entry of entries) {
      const row = normalizeRequest({
        method: "GET",
        url: entry && entry.name,
        status: entry && entry.responseStatus,
        requestHeaders: [],
        responseHeaders: [],
      });
      if (!row) continue;
      rows.push(row);
      if (rows.length >= LIMITS.requests) break;
    }
    return rows;
  }

  function snapshotDiagnostics() {
    const api = root.__shaarBugReportV1;
    if (!api || typeof api.snapshot !== "function" || api.stopped) return null;
    try {
      return api.snapshot();
    } catch (error) {
      return null;
    }
  }

  function consoleErrors(snapshot) {
    if (!snapshot) return [];
    const rows = Array.isArray(snapshot.console) ? snapshot.console : [];
    const errors = [];
    for (const row of rows) {
      const level = row && row.level ? String(row.level) : "";
      if (level !== "error" && level !== "unhandledrejection") continue;
      errors.push(redact(clip(row.message || "")));
      if (errors.length >= LIMITS.errors) break;
    }
    return errors;
  }

  function failedRequests(snapshot) {
    if (!snapshot) return resourceFailures();
    const rows = [];
    const seen = new Set();
    const network = Array.isArray(snapshot.network) ? snapshot.network : [];
    for (const row of network) {
      const normalized = normalizeRequest(row);
      if (!normalized || seen.has(normalized.url)) continue;
      seen.add(normalized.url);
      rows.push(normalized);
      if (rows.length >= LIMITS.requests) return rows;
    }
    const resources = Array.isArray(snapshot.resources) ? snapshot.resources : [];
    for (const row of resources) {
      const normalized = normalizeRequest(row);
      if (!normalized || seen.has(normalized.url)) continue;
      seen.add(normalized.url);
      rows.push(normalized);
      if (rows.length >= LIMITS.requests) break;
    }
    return rows;
  }

  function fence(html) {
    const body = String(html || "").split("```").join("'''");
    return "```html\n" + body + "\n```";
  }

  function fit(markdown) {
    let text = markdown;
    const marker = "```html\n";
    const start = text.indexOf(marker);
    const end = start < 0 ? -1 : text.indexOf("\n```", start + marker.length);
    if (start >= 0 && end > start) {
      let body = text.slice(start + marker.length, end);
      while (body.length > 80 && utf8Count(text) > LIMITS.markdown) {
        body = body.slice(0, Math.floor(body.length * 0.75));
        text = text.slice(0, start + marker.length) + body + text.slice(end);
      }
    }
    while (utf8Count(text) > LIMITS.markdown && text.length > 1) {
      text = text.slice(0, text.length - 120);
    }
    if (text[text.length - 1] !== "\n") text += "\n";
    return text;
  }

  function build(input) {
    const source = input && typeof input === "object" ? input : {};
    const page = source.page && typeof source.page === "object" ? source.page : {};
    const scope = page.scope === "element" ? "element" : "page";
    const recording = Boolean(page.consoleRecording);
    const html = trimHTML(page.html || "");
    const located = redact(clip(page.source || ""));
    const rules = source.stylesOmitted ? [] : winningRules(source.matchedStyles);
    const errors = [];
    const listedErrors = Array.isArray(page.consoleErrors) ? page.consoleErrors : [];
    for (const item of listedErrors) {
      if (errors.length >= LIMITS.errors) break;
      errors.push(redact(clip(item)));
    }
    const requests = [];
    const listedRequests = Array.isArray(page.failedRequests) ? page.failedRequests : [];
    for (const item of listedRequests) {
      const normalized = normalizeRequest(item);
      if (!normalized) continue;
      requests.push(normalized);
      if (requests.length >= LIMITS.requests) break;
    }
    const screenshotBytes = Math.max(0, Number(source.screenshotBytes) || 0);
    const lines = ["# Agent packet"];
    lines.push("Scope: " + scope);
    lines.push("Page: " + redact(clip(page.url || "")));
    if (located) {
      lines.push("## Source");
      lines.push(located);
    }
    lines.push("## HTML");
    lines.push(fence(html));
    lines.push("## Winning CSS");
    if (source.stylesOmitted) {
      lines.push("styles omitted");
    } else if (!rules.length) {
      lines.push("None recorded.");
    } else {
      for (const rule of rules) {
        lines.push(rule.selector);
        for (const declaration of rule.declarations) {
          lines.push("  " + declaration.name + ": " + declaration.value);
        }
      }
    }
    lines.push("## Console errors");
    if (!recording) {
      lines.push("none recorded (no buffer was running)");
    } else if (!errors.length) {
      lines.push("None recorded.");
    } else {
      for (const error of errors) lines.push("- " + error);
    }
    lines.push("## Failed requests");
    if (!requests.length) {
      lines.push("None recorded.");
    } else {
      for (const request of requests) {
        lines.push("- " + request.method + " " + request.url + " — " + request.status);
        for (const header of request.requestHeaders) lines.push("  " + headerLine(header));
        for (const header of request.responseHeaders) lines.push("  " + headerLine(header));
      }
    }
    lines.push("## Screenshot");
    if (screenshotBytes > 0) {
      lines.push("PNG attached, " + screenshotBytes + " bytes.");
    } else {
      lines.push("Screenshot: omitted.");
    }
    const markdown = fit(lines.join("\n") + "\n");
    return {
      markdown: markdown,
      bytes: utf8Count(markdown) + screenshotBytes,
      rules: rules,
      errors: errors,
      requests: requests.map(function (request) {
        return { method: request.method, url: request.url, status: request.status };
      }),
      screenshotBytes: screenshotBytes,
      source: located,
      scope: scope,
      consoleRecording: recording,
      stylesOmitted: Boolean(source.stylesOmitted),
    };
  }

  function buildJSON(text) {
    const parsed = JSON.parse(String(text || "{}"));
    return JSON.stringify(build(parsed));
  }

  function validSelector(value) {
    const text = String(value || "");
    if (!/^#[A-Za-z][A-Za-z0-9_-]{0,40}$/.test(text)) return "";
    return text;
  }

  function validToken(value) {
    const text = String(value || "");
    if (!/^[0-9a-f]{32}$/.test(text)) return "";
    return text;
  }

  function isUseful(node) {
    return Boolean(
      node && node.nodeType === 1 && node !== document.body && node !== document.documentElement
    );
  }

  function serialize(node, depth) {
    if (!node || depth > 6) return "";
    if (node.nodeType === 8) return "";
    if (node.nodeType === 3) return escapeText(String(node.nodeValue || "").slice(0, 300));
    if (node.nodeType !== 1) return "";
    const name = String(node.tagName || "").toLowerCase();
    if (!name || DROP_TAGS[name]) return "";
    let html = "<" + name;
    const attributes = node.attributes ? Array.from(node.attributes) : [];
    for (const attribute of attributes) {
      const key = String(attribute.name || "").toLowerCase();
      const dropped = key.indexOf("on") === 0 || key === "value" || key === "srcset"
        || key === "style" || key === "data-shaar-agent";
      if (dropped) continue;
      html += " " + attribute.name + '="' + escapeAttr(String(attribute.value || "").slice(0, 200)) + '"';
    }
    html += ">";
    const children = node.childNodes ? Array.from(node.childNodes) : [];
    let kept = 0;
    for (const child of children) {
      if (kept >= 12) break;
      const piece = serialize(child, depth + 1);
      if (!piece) continue;
      html += piece;
      kept += 1;
    }
    html += "</" + name + ">";
    return html;
  }

  function sourceFile(source) {
    if (!source || !source.fileName) return "";
    const line = source.lineNumber || source.line || "";
    return String(source.fileName) + (line ? ":" + line : "");
  }

  function reactSource(node) {
    const keys = Object.keys(node);
    for (const key of keys) {
      const fiberKey = key.indexOf("__reactFiber") === 0 || key.indexOf("__reactInternalInstance") === 0;
      if (!fiberKey) continue;
      let fiber = node[key];
      for (let depth = 0; fiber && depth < 12; depth += 1) {
        const located = sourceFile(fiber._debugSource) || sourceFile(fiber.__source);
        if (located) return located;
        fiber = fiber.return || fiber._debugOwner;
      }
    }
    return "";
  }

  function findSource(node) {
    let current = node;
    for (let depth = 0; current && depth < 12; depth += 1) {
      if (typeof current.getAttribute === "function") {
        const marked = current.getAttribute("data-source");
        if (marked) return String(marked).slice(0, LIMITS.line);
      }
      const located = reactSource(current);
      if (located) return located.slice(0, LIMITS.line);
      current = current.parentElement;
    }
    return "";
  }

  function rectOf(node, viewport) {
    const ratio = root.devicePixelRatio || 1;
    if (viewport) {
      const width = root.innerWidth || document.documentElement.clientWidth || 0;
      const height = root.innerHeight || document.documentElement.clientHeight || 0;
      return { x: 0, y: 0, width: width, height: height, devicePixelRatio: ratio };
    }
    const box = node.getBoundingClientRect();
    return {
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
      devicePixelRatio: ratio,
    };
  }

  function collect(options) {
    const scope = options && options.scope === "element" ? "element" : "page";
    const token = validToken(options && options.token);
    const selector = validSelector(options && options.selector);
    const rootNode = document.documentElement;
    if (!rootNode) return { ok: false, reason: "unsupported", scope: scope };
    let node = rootNode;
    if (scope === "element") {
      const active = document.activeElement;
      if (isUseful(active)) node = active;
      else if (selector) node = document.querySelector(selector);
      else node = null;
      if (!node) {
        return {
          ok: false,
          reason: "no-selection",
          scope: "element",
          url: String(location.href),
          consoleRecording: Boolean(snapshotDiagnostics()),
        };
      }
    }
    if (token) node.setAttribute("data-shaar-agent", token);
    const snapshot = snapshotDiagnostics();
    const recording = Boolean(snapshot);
    return {
      ok: true,
      scope: scope,
      url: String(location.href),
      title: String(document.title || ""),
      selector: node.id ? "#" + node.id : "",
      html: trimHTML(serialize(node, 0)),
      source: findSource(node),
      rect: rectOf(node, scope === "page"),
      consoleErrors: consoleErrors(snapshot),
      failedRequests: failedRequests(snapshot),
      consoleRecording: recording,
    };
  }

  root.ShaarAgentCopy = {
    LIMITS: LIMITS,
    redact: redact,
    trimHTML: trimHTML,
    build: build,
    buildJSON: buildJSON,
    collect: collect,
  };
})(globalThis);
