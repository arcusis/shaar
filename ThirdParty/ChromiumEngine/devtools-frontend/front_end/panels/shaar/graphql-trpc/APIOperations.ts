// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Same naming rules as ShaarAPIOperation in the app. The DevTools network
// request already carries the body, so nothing here stores that body.

export const APIKind = {
  GRAPHQL: 'graphql',
  TRPC: 'trpc',
} as const;

export type APIKind = (typeof APIKind)[keyof typeof APIKind];

export const APICallType = {
  QUERY: 'query',
  MUTATION: 'mutation',
  SUBSCRIPTION: 'subscription',
  PROCEDURE: 'procedure',
  UNKNOWN: 'unknown',
} as const;

export type APICallType = (typeof APICallType)[keyof typeof APICallType];

export interface APIOperation {
  kind: APIKind;
  name: string;
  callType: APICallType;
  hasErrors: boolean;
}

export type APIFilter = 'all'|'graphql'|'trpc'|'errors';

const NAME_LIMIT = 400;
const KEYWORDS: APICallType[] = [APICallType.QUERY, APICallType.MUTATION, APICallType.SUBSCRIPTION];

export function columnText(operation: APIOperation): string {
  if (operation.callType === APICallType.UNKNOWN) {
    return `${operation.name} · ${operation.kind}`;
  }
  return `${operation.name} · ${operation.callType}`;
}

export function callLabel(operation: APIOperation): string {
  return operation.callType === APICallType.UNKNOWN ? operation.kind : operation.callType;
}

export function parseAPIOperation(
    method: string, url: string, body: string|null, responseBody: string|null): APIOperation|null {
  const graphql = parseGraphQL(url, body);
  if (graphql) {
    return withErrors(graphql, responseBody);
  }
  const trpc = parseTRPC(method, url);
  if (trpc) {
    return withErrors(trpc, responseBody);
  }
  return null;
}

export function operationMatches(operation: APIOperation, filter: APIFilter, search: string): boolean {
  if (filter === 'graphql' && operation.kind !== APIKind.GRAPHQL) {
    return false;
  }
  if (filter === 'trpc' && operation.kind !== APIKind.TRPC) {
    return false;
  }
  if (filter === 'errors' && !operation.hasErrors) {
    return false;
  }
  const query = search.trim().toLowerCase();
  if (!query) {
    return true;
  }
  return columnText(operation).toLowerCase().includes(query);
}

export function keepAfterNavigation(
    requestLoaderId: string|null, frameLoaderId: string, preserveLog: boolean): boolean {
  return preserveLog || requestLoaderId === frameLoaderId;
}

export function moveIndex(count: number, index: number, delta: number): number {
  if (count <= 0) {
    return -1;
  }
  if (index < 0) {
    return delta < 0 ? count - 1 : 0;
  }
  return Math.max(0, Math.min(count - 1, index + delta));
}

function withErrors(operation: APIOperation, responseBody: string|null): APIOperation {
  if (!responseHasErrors(operation.kind, responseBody)) {
    return operation;
  }
  return {...operation, hasErrors: true};
}

function parseGraphQL(url: string, body: string|null): APIOperation|null {
  if (body) {
    const fromBody = graphqlBody(body, url);
    if (fromBody) {
      return fromBody;
    }
  }
  return graphqlURL(url);
}

function graphqlBody(body: string, url: string): APIOperation|null {
  const value = jsonValue(body);
  if (value !== undefined) {
    if (isRecord(value)) {
      const named = graphqlFields(value, url);
      return named ? make(APIKind.GRAPHQL, named.name, named.callType) : null;
    }
    if (Array.isArray(value)) {
      return graphqlBatch(value, url);
    }
    return null;
  }
  const fields = formFields(body);
  if (fields) {
    const named = graphqlFields(fields, url);
    return named ? make(APIKind.GRAPHQL, named.name, named.callType) : null;
  }
  if (!looksLikeGraphQLDocument(body)) {
    return null;
  }
  const named = namedOperation(body, null);
  return named ? make(APIKind.GRAPHQL, named.name, named.callType) : null;
}

function graphqlBatch(items: unknown[], url: string): APIOperation|null {
  const parts: Array<{name: string, callType: APICallType}> = [];
  for (const item of items) {
    if (!isRecord(item)) {
      continue;
    }
    const named = graphqlFields(item, url);
    if (named) {
      parts.push(named);
    }
  }
  if (parts.length === 0) {
    return null;
  }
  return make(APIKind.GRAPHQL, parts.map(part => part.name).join(', '), parts[0].callType);
}

function graphqlFields(object: Record<string, unknown>, url: string): {name: string, callType: APICallType}|null {
  const operationName = stringField(object.operationName);
  const query = stringField(object.query);
  if (query) {
    return namedOperation(query, operationName);
  }
  if (hasPersistedQuery(object) && operationName) {
    return {name: operationName, callType: APICallType.UNKNOWN};
  }
  if (operationName && urlLooksLikeGraphQL(url)) {
    return {name: operationName, callType: APICallType.UNKNOWN};
  }
  return null;
}

function graphqlURL(url: string): APIOperation|null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const operationName = parsed.searchParams.get('operationName');
  const query = parsed.searchParams.get('query');
  const document = query && looksLikeGraphQLDocument(query) ? query : null;
  if (!document && !urlLooksLikeGraphQL(url)) {
    return null;
  }
  const named = namedOperation(document, operationName);
  if (!named || !named.name) {
    return null;
  }
  if (!document && !operationName) {
    return null;
  }
  return make(APIKind.GRAPHQL, named.name, named.callType);
}

function parseTRPC(method: string, url: string): APIOperation|null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const parts = parsed.pathname.split('/').filter(part => part.length > 0);
  let index = -1;
  for (let cursor = 0; cursor < parts.length; cursor++) {
    if (parts[cursor].toLowerCase() === 'trpc') {
      index = cursor;
    }
  }
  if (index < 0 || index + 1 >= parts.length) {
    return null;
  }
  const names = parts[index + 1].split(',').map(name => name.trim()).filter(isProcedureName);
  if (names.length === 0) {
    return null;
  }
  if (!trpcPrefixAllowed(parts, index) && !trpcExtraSignal(names, parsed)) {
    return null;
  }
  return make(APIKind.TRPC, names.join(', '), trpcCallType(method));
}

function trpcPrefixAllowed(parts: string[], index: number): boolean {
  if (index === 0) {
    return true;
  }
  return parts[index - 1].toLowerCase() === 'api';
}

function trpcExtraSignal(names: string[], url: URL): boolean {
  if (names.some(name => name.includes('.'))) {
    return true;
  }
  return url.searchParams.has('batch') || url.searchParams.has('input');
}

function trpcCallType(method: string): APICallType {
  switch (method.toUpperCase()) {
    case 'GET':
      return APICallType.QUERY;
    case 'POST':
      return APICallType.MUTATION;
    default:
      return APICallType.PROCEDURE;
  }
}

function namedOperation(document: string|null, operationName: string|null): {name: string, callType: APICallType}|
    null {
  const scanned = document ? scanOperations(document) : [];
  const explicit = operationName ? operationName : null;
  if (scanned.length === 0) {
    if (document && isShorthandQuery(document)) {
      return {name: explicit ?? 'anonymous', callType: APICallType.QUERY};
    }
    if (explicit) {
      return {name: explicit, callType: APICallType.UNKNOWN};
    }
    return null;
  }
  if (explicit) {
    const match = scanned.find(operation => operation.name === explicit);
    if (match) {
      return {name: explicit, callType: match.callType};
    }
    return {name: explicit, callType: scanned[0].callType};
  }
  return {name: scanned[0].name ?? 'anonymous', callType: scanned[0].callType};
}

interface ScannedOperation {
  name: string|null;
  callType: APICallType;
}

function scanOperations(document: string): ScannedOperation[] {
  const found: ScannedOperation[] = [];
  let index = 0;
  while (index < document.length) {
    const char = document[index];
    if (char === '#') {
      index = skipLine(document, index);
      continue;
    }
    if (char === '"') {
      index = skipQuoted(document, index);
      continue;
    }
    const keyword = keywordAt(document, index);
    if (keyword) {
      const after = index + keyword.length;
      found.push({name: readName(document, after), callType: keyword});
      index = after;
      continue;
    }
    index++;
  }
  return found;
}

function keywordAt(document: string, index: number): APICallType|null {
  if (!isBoundary(document, index)) {
    return null;
  }
  for (const word of KEYWORDS) {
    if (!document.startsWith(word, index)) {
      continue;
    }
    const after = index + word.length;
    if (after < document.length && isNameChar(document[after])) {
      continue;
    }
    return word;
  }
  return null;
}

function readName(document: string, index: number): string|null {
  let current = index;
  while (current < document.length && isWhitespace(document[current])) {
    current++;
  }
  if (current >= document.length || !isNameStart(document[current])) {
    return null;
  }
  let end = current + 1;
  while (end < document.length && isNameChar(document[end])) {
    end++;
  }
  const name = document.slice(current, end);
  return name || null;
}

function isBoundary(document: string, index: number): boolean {
  if (index === 0) {
    return true;
  }
  return !isNameChar(document[index - 1]);
}

function isNameStart(char: string): boolean {
  return char === '_' || (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z');
}

function isNameChar(char: string): boolean {
  return isNameStart(char) || (char >= '0' && char <= '9');
}

function isWhitespace(char: string): boolean {
  return char === ' ' || char === '\n' || char === '\r' || char === '\t' || char === '\f';
}

function skipLine(document: string, index: number): number {
  const newline = document.indexOf('\n', index);
  return newline === -1 ? document.length : newline + 1;
}

function skipQuoted(document: string, index: number): number {
  if (document.startsWith('"""', index)) {
    const close = document.indexOf('"""', index + 3);
    return close === -1 ? document.length : close + 3;
  }
  let current = index + 1;
  while (current < document.length) {
    if (document[current] === '\\') {
      current = Math.min(document.length, current + 2);
      continue;
    }
    if (document[current] === '"') {
      return current + 1;
    }
    current++;
  }
  return document.length;
}

function isShorthandQuery(document: string): boolean {
  return document.trim().startsWith('{');
}

function looksLikeGraphQLDocument(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.startsWith('{')) {
    return true;
  }
  for (const word of KEYWORDS) {
    if (!trimmed.startsWith(word)) {
      continue;
    }
    const rest = trimmed.slice(word.length);
    if (!rest) {
      return true;
    }
    const next = rest[0];
    if (isWhitespace(next) || next === '(' || next === '{') {
      return true;
    }
  }
  return false;
}

function urlLooksLikeGraphQL(url: string): boolean {
  return url.toLowerCase().includes('graphql');
}

function hasPersistedQuery(object: Record<string, unknown>): boolean {
  if (!isRecord(object.extensions)) {
    return false;
  }
  return object.extensions.persistedQuery !== undefined && object.extensions.persistedQuery !== null;
}

function formFields(body: string): Record<string, unknown>|null {
  const trimmed = body.trim();
  if (!trimmed.includes('=') || trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return null;
  }
  const fields: Record<string, unknown> = {};
  let found = false;
  for (const part of trimmed.split('&')) {
    const eq = part.indexOf('=');
    if (eq === -1) {
      continue;
    }
    fields[decodeForm(part.slice(0, eq))] = decodeForm(part.slice(eq + 1));
    found = true;
  }
  if (!found || (fields.query === undefined && fields.operationName === undefined)) {
    return null;
  }
  return fields;
}

function decodeForm(value: string): string {
  const spaced = value.replaceAll('+', ' ');
  try {
    return decodeURIComponent(spaced);
  } catch {
    return spaced;
  }
}

function stringField(value: unknown): string|null {
  return typeof value === 'string' && value ? value : null;
}

function isProcedureName(name: string): boolean {
  if (!name || !isNameStart(name[0])) {
    return false;
  }
  for (const char of name) {
    if (!isNameChar(char) && char !== '$' && char !== '.') {
      return false;
    }
  }
  return true;
}

function graphqlErrors(value: unknown): boolean {
  if (Array.isArray(value)) {
    return value.some(item => graphqlErrors(item));
  }
  if (!isRecord(value) || !Array.isArray(value.errors)) {
    return false;
  }
  return value.errors.length > 0;
}

function trpcErrors(value: unknown): boolean {
  if (Array.isArray(value)) {
    return value.some(item => trpcErrors(item));
  }
  return isRecord(value) && isRecord(value.error);
}

function responseHasErrors(kind: APIKind, body: string|null): boolean {
  const value = jsonValue(body);
  if (value === undefined) {
    return false;
  }
  return kind === APIKind.GRAPHQL ? graphqlErrors(value) : trpcErrors(value);
}

function jsonValue(body: string|null): unknown {
  if (!body) {
    return undefined;
  }
  try {
    return JSON.parse(body);
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function make(kind: APIKind, name: string, callType: APICallType): APIOperation|null {
  const bounded = name.slice(0, NAME_LIMIT);
  if (!bounded) {
    return null;
  }
  return {kind, name: bounded, callType, hasErrors: false};
}
