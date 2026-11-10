// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/**
 * Saved network rules. The match and the five actions follow the Fetch lease
 * already used by the SwiftUI drawer: exact method and URL, first match wins.
 * JSON files use the same schemaVersion 1 tokens, so a file from either UI
 * round-trips.
 */

export const SCHEMA_VERSION = 1;
export const MAX_RULES = 100;
export const MAX_ENABLED = 32;
export const MAX_BYTES = 4_194_304;
export const MAX_BODY_BYTES = 1_048_576;
export const MAX_DELAY_MS = 30_000;
export const MAX_HEADERS = 32;
export const MAX_HEADER_NAME = 128;
export const MAX_HEADER_VALUE = 4_096;
export const MAX_URL_BYTES = 4_096;

export const METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'] as const;
export const KINDS = ['mock', 'redirect', 'delay', 'requestHeaders', 'responseHeaders'] as const;

export type RuleMethod = typeof METHODS[number];
export type RuleKind = typeof KINDS[number];
export type RuleError = 'match'|'action'|'headers'|'document'|'limit';

const HEADER_TOKEN = new Set('!#$%&\'*+-.^_`|~'.split('').map(character => character.charCodeAt(0)));
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface HeaderEntry {
  name: string;
  value: string;
}

export interface NetworkRule {
  id: string;
  enabled: boolean;
  method: string;
  url: string;
  kind: RuleKind;
  status: number;
  headers: HeaderEntry[];
  bodyText: string;
  redirectURL: string;
  delayMilliseconds: number;
}

export interface PausedRequest {
  url: string;
  method: string;
  responseStage: boolean;
  statusCode?: number;
  requestHeaders: HeaderEntry[];
  responseHeaders?: HeaderEntry[];
}

export interface ExchangeDocument {
  schemaVersion: number;
  rules: ExchangeRow[];
}

export interface ExchangeRow {
  id: string;
  enabled: boolean;
  method: string;
  url: string;
  kind: string;
  status: number;
  headers: HeaderEntry[];
  bodyText: string;
  redirectURL: string;
  delayMilliseconds: number;
}

export type ExchangeResult = {ok: true, rules: NetworkRule[]}|{ok: false, error: RuleError};

export interface RulePattern {
  urlPattern: string;
  requestStage: 'Request'|'Response';
}

type RuleDecision = {type: 'ignore'}|{type: 'release'}|{type: 'delay', milliseconds: number}|
    {type: 'mock', status: number, bodyText: string, headers: HeaderEntry[]}|
    {type: 'redirect', url: string}|{type: 'requestHeaders', headers: HeaderEntry[]}|
    {type: 'responseHeaders', status: number, headers: HeaderEntry[]};

export interface ContinueRequestCommand {
  method: 'continueRequest';
  params: {requestId: string, url?: string, headers?: HeaderEntry[]};
}

export interface FulfillCommand {
  method: 'fulfillRequest';
  params: {requestId: string, responseCode: number, body: string, responseHeaders: HeaderEntry[]};
}

export interface ContinueResponseCommand {
  method: 'continueResponse';
  params: {requestId: string, responseCode?: number, responseHeaders?: HeaderEntry[]};
}

export type FetchCommand = ContinueRequestCommand|FulfillCommand|ContinueResponseCommand;

export type RuleAction = {kind: 'ignore'}|{kind: 'continue'}|{kind: 'delay', milliseconds: number}|
    {kind: 'rewrite', command: FetchCommand};

export interface FetchAgentLike {
  invoke_continueRequest: (params: ContinueRequestCommand['params']) => unknown;
  invoke_fulfillRequest: (params: FulfillCommand['params']) => unknown;
  invoke_continueResponse: (params: ContinueResponseCommand['params']) => unknown;
}

const stagedCommands = new Map<string, FetchCommand>();
const bridgedAgents = new WeakSet<object>();

export function createRule(id: string): NetworkRule {
  return {
    id,
    enabled: false,
    method: 'GET',
    url: '',
    kind: 'mock',
    status: 200,
    headers: [],
    bodyText: '',
    redirectURL: '',
    delayMilliseconds: 0,
  };
}

export function cloneRule(rule: NetworkRule): NetworkRule {
  return {...rule, headers: rule.headers.map(header => ({name: header.name, value: header.value}))};
}

export function siteOrigin(value: string): string|null {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || !url.host) {
    return null;
  }
  return `${url.protocol}//${url.host}`;
}

export function normalized(rule: NetworkRule): NetworkRule {
  const next = cloneRule(rule);
  if (next.kind !== 'mock') {
    next.status = 200;
    next.bodyText = '';
  }
  if (next.kind !== 'redirect') {
    next.redirectURL = '';
  }
  if (next.kind !== 'delay') {
    next.delayMilliseconds = 0;
  }
  if (next.kind === 'redirect' || next.kind === 'delay') {
    next.headers = [];
  }
  return next;
}

export function validate(rule: NetworkRule): RuleError|null {
  if (!isMethod(rule.method) || !webURL(rule.url)) {
    return 'match';
  }
  if (rule.headers.length > MAX_HEADERS || rule.headers.some(header => !validHeader(header))) {
    return 'headers';
  }
  switch (rule.kind) {
    case 'mock':
      if (rule.status < 100 || rule.status > 599 || !Number.isInteger(rule.status) ||
          utf8Size(rule.bodyText) > MAX_BODY_BYTES) {
        return 'action';
      }
      return null;
    case 'redirect':
      return webURL(rule.redirectURL) ? null : 'action';
    case 'delay':
      return rule.delayMilliseconds >= 0 && rule.delayMilliseconds <= MAX_DELAY_MS &&
              Number.isInteger(rule.delayMilliseconds) ?
          null :
          'action';
    case 'requestHeaders':
    case 'responseHeaders':
      return rule.headers.length > 0 ? null : 'headers';
  }
}

export function fetchURLPattern(url: string): string {
  let pattern = '';
  for (const character of url) {
    if (character === '*' || character === '?' || character === '\\') {
      pattern += '\\';
    }
    pattern += character;
  }
  return pattern;
}

export function interceptionPatterns(rules: readonly NetworkRule[]): RulePattern[] {
  const patterns: RulePattern[] = [];
  const seen = new Set<string>();
  for (const rule of rules) {
    if (!rule.enabled) {
      continue;
    }
    const requestStage = rule.kind === 'responseHeaders' ? 'Response' : 'Request';
    const key = `${rule.url}\n${requestStage}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    patterns.push({urlPattern: fetchURLPattern(rule.url), requestStage});
  }
  return patterns;
}

export function headerEntries(headers: Record<string, string>|undefined): HeaderEntry[] {
  if (!headers) {
    return [];
  }
  const entries: HeaderEntry[] = [];
  for (const [name, value] of Object.entries(headers)) {
    if (typeof value === 'string') {
      entries.push({name, value});
    }
  }
  return entries;
}

export function mergeHeaders(existing: readonly HeaderEntry[], changes: readonly HeaderEntry[]): HeaderEntry[] {
  const merged: HeaderEntry[] = [];
  for (const header of existing) {
    const replaced = changes.some(change => change.name.toLowerCase() === header.name.toLowerCase());
    if (!replaced) {
      merged.push({name: header.name, value: header.value});
    }
  }
  for (const change of changes) {
    merged.push({name: change.name, value: change.value});
  }
  return merged;
}

export function actionFor(requestId: string, rules: readonly NetworkRule[], paused: PausedRequest): RuleAction {
  const decision = decide(rules, paused);
  if (decision.type === 'delay') {
    return {kind: 'delay', milliseconds: decision.milliseconds};
  }
  if (decision.type === 'release') {
    return {
      kind: 'rewrite',
      command: {method: 'continueResponse', params: {requestId}},
    };
  }
  if (decision.type !== 'ignore') {
    return {kind: 'rewrite', command: commandFor(requestId, decision)};
  }
  if (!ownsPause(rules, paused)) {
    return {kind: 'ignore'};
  }
  if (paused.responseStage) {
    return {kind: 'rewrite', command: {method: 'continueResponse', params: {requestId}}};
  }
  return {kind: 'continue'};
}

export function stageCommand(requestId: string, command: FetchCommand): void {
  stagedCommands.set(requestId, command);
}

export function takeCommand(requestId: string): FetchCommand|undefined {
  const command = stagedCommands.get(requestId);
  if (command) {
    stagedCommands.delete(requestId);
  }
  return command;
}

export function clearStagedCommands(): void {
  stagedCommands.clear();
}

/**
 * InterceptedRequest can only continue with a request id or fulfill with
 * status 200. A staged command rewrites that continue into the Fetch call
 * the rule actually needs: redirect URL, request headers, a mock status, or
 * continueResponse. Unstaged calls pass through.
 */
export function installFetchRewrite(agent: FetchAgentLike, take: (requestId: string) => FetchCommand|undefined): void {
  if (bridgedAgents.has(agent)) {
    return;
  }
  bridgedAgents.add(agent);
  const continueRequest = agent.invoke_continueRequest.bind(agent);
  const fulfillRequest = agent.invoke_fulfillRequest.bind(agent);
  const continueResponse = agent.invoke_continueResponse.bind(agent);
  agent.invoke_continueRequest = params => {
    const command = take(params.requestId);
    if (!command || command.method === 'continueRequest') {
      return continueRequest(command ? command.params : params);
    }
    if (command.method === 'fulfillRequest') {
      return fulfillRequest(command.params);
    }
    return continueResponse(command.params);
  };
}

export function exchangeDocument(rules: readonly NetworkRule[]): {ok: true, document: ExchangeDocument}|
    {ok: false, error: RuleError} {
  if (rules.length > MAX_RULES) {
    return {ok: false, error: 'action'};
  }
  const rows: ExchangeRow[] = [];
  const seen = new Set<string>();
  for (const rule of rules) {
    const cleaned = normalized(rule);
    const error = validate(cleaned);
    if (error) {
      return {ok: false, error};
    }
    if (seen.has(cleaned.id)) {
      return {ok: false, error: 'document'};
    }
    seen.add(cleaned.id);
    rows.push(rowFromRule(cleaned));
  }
  return {ok: true, document: {schemaVersion: SCHEMA_VERSION, rules: rows}};
}

export function exchangeText(rules: readonly NetworkRule[]): {ok: true, text: string}|{ok: false, error: RuleError} {
  const document = exchangeDocument(rules);
  if (!document.ok) {
    return document;
  }
  const text = JSON.stringify(document.document, null, 2);
  if (utf8Size(text) > MAX_BYTES) {
    return {ok: false, error: 'document'};
  }
  return {ok: true, text};
}

export function parseExchange(text: string): ExchangeResult {
  if (utf8Size(text) > MAX_BYTES) {
    return {ok: false, error: 'document'};
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return {ok: false, error: 'document'};
  }
  return parseExchangeValue(value);
}

/** A shared file is not installed. The user turns a rule on after import. */
export function importRules(text: string): ExchangeResult {
  const parsed = parseExchange(text);
  if (!parsed.ok) {
    return parsed;
  }
  return {ok: true, rules: parsed.rules.map(rule => ({...rule, enabled: false}))};
}

export function parseExchangeValue(value: unknown): ExchangeResult {
  if (!isRecord(value) || value.schemaVersion !== SCHEMA_VERSION || !Array.isArray(value.rules)) {
    return {ok: false, error: 'document'};
  }
  if (value.rules.length > MAX_RULES) {
    return {ok: false, error: 'document'};
  }
  const rules: NetworkRule[] = [];
  const seen = new Set<string>();
  for (const item of value.rules) {
    const parsed = ruleFromRow(item);
    if (!parsed.ok) {
      return parsed;
    }
    if (seen.has(parsed.rule.id)) {
      return {ok: false, error: 'document'};
    }
    seen.add(parsed.rule.id);
    rules.push(parsed.rule);
  }
  if (rules.filter(rule => rule.enabled).length > MAX_ENABLED) {
    return {ok: false, error: 'limit'};
  }
  return {ok: true, rules};
}

export function utf8Base64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  const chunk = 0x2000;
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
  }
  return btoa(binary);
}

function decide(rules: readonly NetworkRule[], paused: PausedRequest): RuleDecision {
  for (const rule of rules) {
    if (!rule.enabled || rule.url !== paused.url || rule.method !== paused.method) {
      continue;
    }
    if ((rule.kind === 'responseHeaders') !== paused.responseStage) {
      continue;
    }
    switch (rule.kind) {
      case 'delay':
        return {type: 'delay', milliseconds: rule.delayMilliseconds};
      case 'mock':
        return {type: 'mock', status: rule.status, bodyText: rule.bodyText, headers: rule.headers};
      case 'redirect':
        return {type: 'redirect', url: rule.redirectURL};
      case 'requestHeaders':
        return {type: 'requestHeaders', headers: mergeHeaders(paused.requestHeaders, rule.headers)};
      case 'responseHeaders':
        if (paused.statusCode === undefined || !paused.responseHeaders) {
          return {type: 'release'};
        }
        return {
          type: 'responseHeaders',
          status: paused.statusCode,
          headers: mergeHeaders(paused.responseHeaders, rule.headers),
        };
    }
  }
  return {type: 'ignore'};
}

function commandFor(requestId: string, decision: Exclude<RuleDecision, {type: 'ignore'|'release'|'delay'}>): FetchCommand {
  switch (decision.type) {
    case 'mock':
      return {
        method: 'fulfillRequest',
        params: {
          requestId,
          responseCode: decision.status,
          body: utf8Base64(decision.bodyText),
          responseHeaders: decision.headers.map(header => ({name: header.name, value: header.value})),
        },
      };
    case 'redirect':
      return {method: 'continueRequest', params: {requestId, url: decision.url}};
    case 'requestHeaders':
      return {method: 'continueRequest', params: {requestId, headers: decision.headers}};
    case 'responseHeaders':
      return {
        method: 'continueResponse',
        params: {requestId, responseCode: decision.status, responseHeaders: decision.headers},
      };
  }
}

function ownsPause(rules: readonly NetworkRule[], paused: PausedRequest): boolean {
  return rules.some(
      rule => rule.enabled && rule.url === paused.url && (rule.kind === 'responseHeaders') === paused.responseStage);
}

function rowFromRule(rule: NetworkRule): ExchangeRow {
  return {
    id: rule.id,
    enabled: rule.enabled,
    method: rule.method,
    url: rule.url,
    kind: rule.kind,
    status: rule.status,
    headers: rule.headers.map(header => ({name: header.name, value: header.value})),
    bodyText: rule.bodyText,
    redirectURL: rule.redirectURL,
    delayMilliseconds: rule.delayMilliseconds,
  };
}

function ruleFromRow(value: unknown): {ok: true, rule: NetworkRule}|{ok: false, error: RuleError} {
  if (!isRecord(value) || typeof value.id !== 'string' || !UUID_PATTERN.test(value.id) ||
      typeof value.enabled !== 'boolean' || typeof value.method !== 'string' || typeof value.url !== 'string' ||
      typeof value.kind !== 'string' || !isKind(value.kind) || !isInteger(value.status) || !Array.isArray(value.headers) ||
      typeof value.bodyText !== 'string' || typeof value.redirectURL !== 'string' ||
      !isInteger(value.delayMilliseconds)) {
    return {ok: false, error: 'document'};
  }
  const headers: HeaderEntry[] = [];
  for (const item of value.headers) {
    if (!isRecord(item) || typeof item.name !== 'string' || typeof item.value !== 'string') {
      return {ok: false, error: 'document'};
    }
    headers.push({name: item.name, value: item.value});
  }
  const rule = normalized({
    id: value.id,
    enabled: value.enabled,
    method: value.method,
    url: value.url,
    kind: value.kind,
    status: value.status,
    headers,
    bodyText: value.bodyText,
    redirectURL: value.redirectURL,
    delayMilliseconds: value.delayMilliseconds,
  });
  const error = validate(rule);
  if (error) {
    return {ok: false, error};
  }
  return {ok: true, rule};
}

function webURL(value: string): boolean {
  if (utf8Size(value) > MAX_URL_BYTES) {
    return false;
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || !url.hostname || url.username || url.password ||
      url.hash) {
    return false;
  }
  if (!url.port) {
    return true;
  }
  const port = Number(url.port);
  return Number.isInteger(port) && port >= 1 && port <= 65535;
}

function validHeader(header: HeaderEntry): boolean {
  const name = new TextEncoder().encode(header.name);
  if (name.length === 0 || name.length > MAX_HEADER_NAME || utf8Size(header.value) > MAX_HEADER_VALUE) {
    return false;
  }
  const value = new TextEncoder().encode(header.value);
  for (const byte of value) {
    if (byte === 0 || byte === 10 || byte === 13) {
      return false;
    }
  }
  for (const byte of name) {
    const digit = byte >= 48 && byte <= 57;
    const upper = byte >= 65 && byte <= 90;
    const lower = byte >= 97 && byte <= 122;
    if (!digit && !upper && !lower && !HEADER_TOKEN.has(byte)) {
      return false;
    }
  }
  return true;
}

function isMethod(value: string): value is RuleMethod {
  return (METHODS as readonly string[]).includes(value);
}

function isKind(value: string): value is RuleKind {
  return (KINDS as readonly string[]).includes(value);
}

function isInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function utf8Size(value: string): number {
  return new TextEncoder().encode(value).length;
}
