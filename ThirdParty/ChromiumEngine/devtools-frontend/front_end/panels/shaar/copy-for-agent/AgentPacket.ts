// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export const LIMITS = {
  html: 2048,
  rules: 12,
  declarationsPerRule: 8,
  declarations: 24,
  errors: 8,
  requests: 8,
  headers: 4,
  line: 180,
  markdown: 12000,
} as const;

export const HTML_INPUT_CAP = 200_000;
export const SCREENSHOT_BASE64_CAP = 1_500_000;

const DROP_TAGS: Record<string, true> = {
  script: true,
  style: true,
  noscript: true,
  template: true,
  input: true,
  textarea: true,
  select: true,
  option: true,
};

const VOID_TAGS: Record<string, true> = {
  input: true,
};

const SECRET_HEADERS: Record<string, true> = {
  cookie: true,
  authorization: true,
  'set-cookie': true,
  'proxy-authorization': true,
};

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

export type PacketScope = 'element'|'page';

export interface PageStamp {
  url: string;
  loaderId: string;
}

export interface PacketHeader {
  name?: string;
  value?: string;
}

export interface PacketRequestInput {
  method?: string;
  url?: string;
  name?: string;
  status?: number;
  responseStatus?: number;
  error?: unknown;
  requestHeaders?: PacketHeader[];
  headers?: PacketHeader[];
  responseHeaders?: PacketHeader[];
}

export interface PacketDeclaration {
  name: string;
  value: string;
}

export interface PacketRule {
  selector: string;
  declarations: PacketDeclaration[];
}

export interface PacketRequest {
  method: string;
  url: string;
  status: number;
  requestHeaders: PacketHeader[];
  responseHeaders: PacketHeader[];
}

export interface PacketInput {
  page?: {
    scope?: string,
    url?: string,
    html?: string,
    source?: string,
    consoleRecording?: boolean,
    consoleErrors?: unknown[],
    failedRequests?: PacketRequestInput[],
  };
  matchedStyles?: unknown;
  stylesOmitted?: boolean;
  screenshotBytes?: number;
}

export interface Packet {
  markdown: string;
  bytes: number;
  rules: PacketRule[];
  errors: string[];
  requests: Array<{method: string, url: string, status: number}>;
  screenshotBytes: number;
  source: string;
  scope: PacketScope;
  consoleRecording: boolean;
  stylesOmitted: boolean;
}

interface CssProperty {
  name?: string;
  value?: string;
  disabled?: boolean;
  implicit?: boolean;
}

interface CssRule {
  selectorList?: {selectors?: Array<{text?: string}>};
  selector?: string;
  style?: CssProperty[]|{cssProperties?: CssProperty[]};
}

interface Winner {
  selector: string;
  name: string;
  value: string;
  ruleIndex: number;
}

export function byteSize(bytes: number): string {
  const count = Math.max(0, Math.floor(bytes) || 0);
  if (count < 1024) {
    return `${count} B`;
  }
  if (count < 10 * 1024) {
    const tenths = Math.floor((count * 10) / 1024);
    return `${Math.floor(tenths / 10)}.${tenths % 10} KB`;
  }
  return `${Math.floor((count + 512) / 1024)} KB`;
}

export function samePage(left: PageStamp, right: PageStamp): boolean {
  return left.url === right.url && left.loaderId === right.loaderId;
}

export function packetAccepts(markdown: string): boolean {
  for (const line of String(markdown || '').split('\n')) {
    if (secretHeader(line) && !line.toLowerCase().includes('[redacted]')) {
      return false;
    }
    if (bearerMissing(line) || tokenMissing(line)) {
      return false;
    }
  }
  return true;
}

export function pngBytes(base64: string): number {
  if (!base64 || base64.length > SCREENSHOT_BASE64_CAP) {
    return 0;
  }
  let binary = '';
  try {
    binary = atob(base64);
  } catch {
    return 0;
  }
  if (binary.length < PNG_SIGNATURE.length) {
    return 0;
  }
  for (let index = 0; index < PNG_SIGNATURE.length; index++) {
    if (binary.charCodeAt(index) !== PNG_SIGNATURE[index]) {
      return 0;
    }
  }
  return binary.length;
}

export function redact(value: unknown): string {
  let text = value == null ? '' : String(value);
  text = text.replace(
      /(^|\n)([ \t]*)(set-cookie|proxy-authorization|authorization|cookie)([ \t]*:[ \t]*)([^\n]*)/gi,
      (_match, lead: string, indent: string, name: string) => `${lead}${indent}${name}: [redacted]`);
  text = text.replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, 'Bearer [redacted]');
  text = text.replace(
      /([?&])(access_token|id_token|refresh_token|api_key|apikey|api-key|password|passwd|secret|token)=([^&#\s]*)/gi,
      (_match, separator: string, name: string) => `${separator}${name}=[redacted]`);
  text = text.replace(/([a-z][a-z0-9+.-]*:\/\/)[^/\s:@]+:[^/\s@]+@/gi, '$1[redacted]@');
  text = text.replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, '[redacted]');
  return text;
}

export function trimHTML(source: unknown): string {
  const input = String(source || '');
  let index = 0;
  let out = '';
  while (index < input.length && out.length < LIMITS.html) {
    if (input.slice(index, index + 4) === '<!--') {
      const end = input.indexOf('-->', index + 4);
      index = end < 0 ? input.length : end + 3;
      continue;
    }
    if (input[index] !== '<') {
      const next = input.indexOf('<', index);
      const text = input.slice(index, next < 0 ? input.length : next).slice(0, 300);
      out += text;
      index = next < 0 ? input.length : next;
      continue;
    }
    const close = input.indexOf('>', index + 1);
    if (close < 0) {
      break;
    }
    const raw = input.slice(index + 1, close);
    const name = tagName(raw);
    if (name && DROP_TAGS[name]) {
      if (raw.trim().endsWith('/') || VOID_TAGS[name]) {
        index = close + 1;
        continue;
      }
      const lower = input.toLowerCase();
      const end = lower.indexOf('</' + name, close + 1);
      if (end < 0) {
        index = input.length;
        continue;
      }
      const finish = input.indexOf('>', end);
      index = finish < 0 ? input.length : finish + 1;
      continue;
    }
    if (raw.trim().startsWith('/')) {
      out += '</' + name + '>';
    } else {
      out += '<' + cleanAttributes(raw) + '>';
    }
    index = close + 1;
  }
  return redact(out).slice(0, LIMITS.html);
}

export function winningRules(matched: unknown): PacketRule[] {
  const source = matched && typeof matched === 'object' ? matched as {
    matchedCSSRules?: unknown[],
    inlineStyle?: unknown,
    inline?: unknown,
  } : {};
  const winners = new Map<string, Winner>();
  let ruleIndex = 0;
  const matches = Array.isArray(source.matchedCSSRules) ? source.matchedCSSRules : [];
  for (const entry of matches) {
    const rule = ruleOf(entry);
    if (rule) {
      consider(selectorText(rule), propertiesOf(rule.style), winners, ruleIndex);
    }
    ruleIndex++;
  }
  const inline = source.inlineStyle || source.inline;
  if (inline) {
    consider('element.style', propertiesOf(styleOf(inline)), winners, ruleIndex);
  }
  const grouped = new Map<number, {selector: string, declarations: PacketDeclaration[]}>();
  for (const item of winners.values()) {
    let bucket = grouped.get(item.ruleIndex);
    if (!bucket) {
      bucket = {selector: item.selector, declarations: []};
      grouped.set(item.ruleIndex, bucket);
    }
    bucket.declarations.push({name: item.name, value: item.value});
  }
  const rules: PacketRule[] = [];
  let declarations = 0;
  const indexes = Array.from(grouped.keys()).sort((left, right) => left - right);
  for (const index of indexes) {
    if (rules.length >= LIMITS.rules || declarations >= LIMITS.declarations) {
      break;
    }
    const bucket = grouped.get(index);
    if (!bucket) {
      continue;
    }
    const kept: PacketDeclaration[] = [];
    for (const declaration of bucket.declarations) {
      if (kept.length >= LIMITS.declarationsPerRule || declarations >= LIMITS.declarations) {
        break;
      }
      kept.push(declaration);
      declarations++;
    }
    if (kept.length) {
      rules.push({selector: bucket.selector, declarations: kept});
    }
  }
  return rules;
}

export function buildPacket(input: PacketInput|null|undefined): Packet {
  const source = input && typeof input === 'object' ? input : {};
  const page = source.page && typeof source.page === 'object' ? source.page : {};
  const scope: PacketScope = page.scope === 'element' ? 'element' : 'page';
  const recording = Boolean(page.consoleRecording);
  const rawHTML = String(page.html || '');
  const html = trimHTML(rawHTML.length > HTML_INPUT_CAP ? rawHTML.slice(0, HTML_INPUT_CAP) : rawHTML);
  const located = redact(clip(page.source || ''));
  const rules = source.stylesOmitted ? [] : winningRules(source.matchedStyles);
  const errors: string[] = [];
  const listedErrors = Array.isArray(page.consoleErrors) ? page.consoleErrors : [];
  for (const item of listedErrors) {
    if (errors.length >= LIMITS.errors) {
      break;
    }
    errors.push(redact(clip(item)));
  }
  const requests: PacketRequest[] = [];
  const listedRequests = Array.isArray(page.failedRequests) ? page.failedRequests : [];
  for (const item of listedRequests) {
    const normalized = normalizeRequest(item);
    if (!normalized) {
      continue;
    }
    requests.push(normalized);
    if (requests.length >= LIMITS.requests) {
      break;
    }
  }
  const screenshotBytes = Math.max(0, Number(source.screenshotBytes) || 0);
  const lines = ['# Agent packet'];
  lines.push('Scope: ' + scope);
  lines.push('Page: ' + redact(clip(page.url || '')));
  if (located) {
    lines.push('## Source');
    lines.push(located);
  }
  lines.push('## HTML');
  lines.push(fence(html));
  lines.push('## Winning CSS');
  if (source.stylesOmitted) {
    lines.push('styles omitted');
  } else if (!rules.length) {
    lines.push('None recorded.');
  } else {
    for (const rule of rules) {
      lines.push(rule.selector);
      for (const declaration of rule.declarations) {
        lines.push('  ' + declaration.name + ': ' + declaration.value);
      }
    }
  }
  lines.push('## Console errors');
  if (!recording) {
    lines.push('none recorded (no buffer was running)');
  } else if (!errors.length) {
    lines.push('None recorded.');
  } else {
    for (const error of errors) {
      lines.push('- ' + error);
    }
  }
  lines.push('## Failed requests');
  if (!requests.length) {
    lines.push('None recorded.');
  } else {
    for (const request of requests) {
      lines.push('- ' + request.method + ' ' + request.url + ' — ' + request.status);
      for (const header of request.requestHeaders) {
        lines.push('  ' + headerLine(header));
      }
      for (const header of request.responseHeaders) {
        lines.push('  ' + headerLine(header));
      }
    }
  }
  lines.push('## Screenshot');
  if (screenshotBytes > 0) {
    lines.push('PNG attached, ' + screenshotBytes + ' bytes.');
  } else {
    lines.push('Screenshot: omitted.');
  }
  const markdown = fit(lines.join('\n') + '\n');
  return {
    markdown,
    bytes: utf8Count(markdown) + screenshotBytes,
    rules,
    errors,
    requests: requests.map(request => ({method: request.method, url: request.url, status: request.status})),
    screenshotBytes,
    source: located,
    scope,
    consoleRecording: recording,
    stylesOmitted: Boolean(source.stylesOmitted),
  };
}

function secretHeader(line: string): boolean {
  const trimmed = line.trim().toLowerCase();
  return trimmed.startsWith('cookie:') || trimmed.startsWith('authorization:') ||
      trimmed.startsWith('set-cookie:') || trimmed.startsWith('proxy-authorization:');
}

function bearerMissing(line: string): boolean {
  const lower = line.toLowerCase();
  return lower.includes('bearer ') && !lower.includes('bearer [redacted]');
}

function tokenMissing(line: string): boolean {
  const lower = line.toLowerCase();
  return lower.includes('token=') && !lower.includes('token=[redacted]');
}

function clip(value: unknown): string {
  const text = value == null ? '' : String(value);
  return text.length <= LIMITS.line ? text : text.slice(0, LIMITS.line);
}

function utf8Count(text: string): number {
  let count = 0;
  for (let index = 0; index < text.length;) {
    const code = text.codePointAt(index) ?? 0;
    if (code <= 0x7f) {
      count += 1;
    } else if (code <= 0x7ff) {
      count += 2;
    } else if (code <= 0xffff) {
      count += 3;
    } else {
      count += 4;
    }
    index += code > 0xffff ? 2 : 1;
  }
  return count;
}

function escapeText(value: unknown): string {
  return String(value == null ? '' : value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escapeAttr(value: unknown): string {
  return escapeText(value).replace(/"/g, '&quot;');
}

function cleanAttributes(raw: string): string {
  let body = String(raw || '').trim();
  if (body.endsWith('/')) {
    body = body.slice(0, -1).trim();
  }
  const space = body.search(/\s/);
  if (space < 0) {
    return body.toLowerCase();
  }
  const name = body.slice(0, space).toLowerCase();
  const rest = body.slice(space);
  const kept: string[] = [];
  const pattern = /([A-Za-z_:][\w:.-]*)\s*=\s*"([^"]*)"/g;
  let match = pattern.exec(rest);
  while (match) {
    const key = match[1].toLowerCase();
    const dropped = key.startsWith('on') || key === 'value' || key === 'srcset' || key === 'style' ||
        key === 'data-shaar-agent';
    if (!dropped) {
      kept.push(match[1] + '="' + escapeAttr(match[2]) + '"');
    }
    match = pattern.exec(rest);
  }
  return kept.length ? name + ' ' + kept.join(' ') : name;
}

function tagName(raw: string): string {
  const body = String(raw || '').trim().replace(/^\//, '');
  const space = body.search(/\s/);
  const name = space < 0 ? body : body.slice(0, space);
  return name.toLowerCase();
}

function selectorText(rule: CssRule): string {
  const selectors = rule.selectorList?.selectors;
  if (Array.isArray(selectors) && selectors.length) {
    const names: string[] = [];
    for (const item of selectors) {
      const text = item?.text ? String(item.text) : '';
      if (text) {
        names.push(text);
      }
    }
    if (names.length) {
      return names.join(', ');
    }
  }
  return typeof rule.selector === 'string' ? rule.selector : '';
}

function styleOf(value: unknown): CssRule['style'] {
  if (Array.isArray(value)) {
    return value as CssProperty[];
  }
  if (!value || typeof value !== 'object') {
    return undefined;
  }
  const record = value as {style?: unknown, cssProperties?: unknown};
  if (record.style) {
    return styleOf(record.style);
  }
  if (Array.isArray(record.cssProperties)) {
    return {cssProperties: record.cssProperties as CssProperty[]};
  }
  return undefined;
}

function propertiesOf(style: CssRule['style']|CssProperty[]|undefined): CssProperty[] {
  if (!style) {
    return [];
  }
  if (Array.isArray(style)) {
    return style;
  }
  return Array.isArray(style.cssProperties) ? style.cssProperties : [];
}

function ruleOf(entry: unknown): CssRule|null {
  if (!entry || typeof entry !== 'object') {
    return null;
  }
  const record = entry as {rule?: CssRule};
  return record.rule ? record.rule : entry as CssRule;
}

function consider(selector: string, properties: CssProperty[], winners: Map<string, Winner>, ruleIndex: number): void {
  const local = new Map<string, Winner>();
  for (const prop of properties) {
    if (!prop || prop.disabled || prop.implicit) {
      continue;
    }
    const name = String(prop.name || '').trim();
    if (!name) {
      continue;
    }
    local.set(name, {
      selector: selector || '(rule)',
      name,
      value: redact(clip(prop.value || '')),
      ruleIndex,
    });
  }
  for (const item of local.values()) {
    winners.set(item.name, item);
  }
}

function headerRows(value: PacketHeader[]|undefined): PacketHeader[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const rows: PacketHeader[] = [];
  for (const item of value) {
    if (rows.length >= LIMITS.headers) {
      break;
    }
    if (!item) {
      continue;
    }
    const name = clip(item.name || '');
    if (!name) {
      continue;
    }
    rows.push({name, value: item.value == null ? '' : String(item.value)});
  }
  return rows;
}

function headerLine(row: PacketHeader): string {
  const name = String(row.name || '');
  if (SECRET_HEADERS[name.toLowerCase()]) {
    return name + ': [redacted]';
  }
  return name + ': ' + redact(clip(row.value || ''));
}

function normalizeRequest(row: PacketRequestInput|null|undefined): PacketRequest|null {
  const status = Number(row && (row.status || row.responseStatus)) || 0;
  const failed = status >= 400 || Boolean(row && row.error);
  if (!failed || !row) {
    return null;
  }
  return {
    method: clip(row.method || 'GET').slice(0, 16) || 'GET',
    url: redact(clip(row.url || row.name || '')),
    status,
    requestHeaders: headerRows(row.requestHeaders || row.headers),
    responseHeaders: headerRows(row.responseHeaders),
  };
}

function fence(html: string): string {
  const body = String(html || '').split('```').join('\'\'\'');
  return '```html\n' + body + '\n```';
}

function fit(markdown: string): string {
  let text = markdown;
  const marker = '```html\n';
  const start = text.indexOf(marker);
  const end = start < 0 ? -1 : text.indexOf('\n```', start + marker.length);
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
  if (text[text.length - 1] !== '\n') {
    text += '\n';
  }
  return text;
}
