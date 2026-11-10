// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import * as GraphQLTRPC from './graphql-trpc.js';

const API = GraphQLTRPC.APIOperations;
const {APICallType, APIKind, columnText, keepAfterNavigation, moveIndex, operationMatches, parseAPIOperation} = API;

describe('APIOperations', () => {
  it('names a GraphQL post from operationName and ignores variables', () => {
    const body = '{"query":"query GetUser { user { id } }","operationName":"GetUser","variables":{"secret":"do-not-keep"}}';
    const operation = parseAPIOperation('POST', 'https://example.com/graphql', body, null);
    assert.strictEqual(columnText(operation!), 'GetUser · query');
    assert.isFalse(operation!.hasErrors);
    assert.isFalse(JSON.stringify(operation).includes('do-not-keep'));
  });

  it('uses operationName to pick the matching call type', () => {
    const body = '{"operationName":"Update","query":"query GetUser { user { id } } mutation Update { ok }"}';
    const operation = parseAPIOperation('POST', 'https://api.example.com/data', body, null);
    assert.strictEqual(operation!.name, 'Update');
    assert.strictEqual(operation!.callType, APICallType.MUTATION);
  });

  it('names a persisted query without keeping the hash', () => {
    const body = '{"operationName":"GetUser","extensions":{"persistedQuery":{"version":1,"sha256Hash":"abc"}}}';
    const operation = parseAPIOperation('POST', 'https://example.com/api', body, null);
    assert.strictEqual(columnText(operation!), 'GetUser · graphql');
    assert.strictEqual(operation!.callType, APICallType.UNKNOWN);
    assert.isFalse(JSON.stringify(operation).includes('sha256Hash'));
    assert.isFalse(JSON.stringify(operation).includes('abc'));
  });

  it('treats an anonymous shorthand document as a query', () => {
    const operation = parseAPIOperation('POST', 'https://example.com/graphql', '{ hello }', null);
    assert.strictEqual(columnText(operation!), 'anonymous · query');
  });

  it('skips comments, strings, and block strings when it scans a document', () => {
    const commented = '{"query":"# query Hidden\\nquery GetUser { field(arg: \\"query Hidden\\") }"}';
    const block = '{"query":"query GetUser { field(arg: \\"\\"\\"\\nquery Hidden\\n\\"\\"\\") }"}';
    assert.strictEqual(columnText(parseAPIOperation('POST', 'https://example.com/graphql', commented, null)!), 'GetUser · query');
    assert.strictEqual(columnText(parseAPIOperation('POST', 'https://example.com/graphql', block, null)!), 'GetUser · query');
  });

  it('joins a mixed batch and keeps the first call type', () => {
    const body = '[{"query":"query Alpha { a }"},{"query":"mutation Beta { b }"}]';
    const operation = parseAPIOperation('POST', 'https://example.com/graphql', body, null);
    assert.strictEqual(operation!.name, 'Alpha, Beta');
    assert.strictEqual(operation!.callType, APICallType.QUERY);
  });

  it('reads a form body', () => {
    const operation = parseAPIOperation(
        'POST', 'https://example.com/graphql', 'operationName=Ping&query=query+Ping+%7B+__typename+%7D', null);
    assert.strictEqual(columnText(operation!), 'Ping · query');
  });

  it('reads a GraphQL get from the URL', () => {
    const named = parseAPIOperation(
        'GET', 'https://example.com/graphql?operationName=Continents&query=query%20Continents', null, null);
    const shorthand = parseAPIOperation('GET', 'https://example.com/api?query=%7B%20hello%20%7D', null, null);
    assert.strictEqual(columnText(named!), 'Continents · query');
    assert.strictEqual(columnText(shorthand!), 'anonymous · query');
  });

  it('does not treat a GraphQL path or an ordinary JSON post as an operation', () => {
    assert.isNull(parseAPIOperation('POST', 'https://example.com/graphql', null, null));
    assert.isNull(parseAPIOperation('POST', 'https://example.com/api', '{"name":"hello"}', null));
  });

  it('names tRPC procedures from the URL', () => {
    const list = parseAPIOperation('GET', 'https://example.com/api/trpc/post.list?batch=1', null, null);
    const root = parseAPIOperation('POST', 'https://example.com/trpc/proc', null, null);
    const versioned = parseAPIOperation('GET', 'https://example.com/v1/api/trpc/post.list', null, null);
    const batch = parseAPIOperation('POST', 'https://example.com/api/trpc/post.list,post.byId', null, null);
    const cased = parseAPIOperation('PUT', 'https://example.com/API/Trpc/post.list', null, null);
    assert.strictEqual(columnText(list!), 'post.list · query');
    assert.strictEqual(columnText(root!), 'proc · mutation');
    assert.strictEqual(versioned!.name, 'post.list');
    assert.strictEqual(batch!.name, 'post.list, post.byId');
    assert.strictEqual(batch!.callType, APICallType.MUTATION);
    assert.strictEqual(cased!.callType, APICallType.PROCEDURE);
  });

  it('rejects a blog path unless the name or the query looks like tRPC', () => {
    assert.isNull(parseAPIOperation('GET', 'https://example.com/blog/trpc/intro', null, null));
    const procedure = parseAPIOperation('GET', 'https://example.com/blog/trpc/post.list', null, null);
    const batched = parseAPIOperation('GET', 'https://example.com/blog/trpc/intro?batch=1', null, null);
    assert.strictEqual(procedure!.name, 'post.list');
    assert.strictEqual(batched!.name, 'intro');
    assert.strictEqual(batched!.kind, APIKind.TRPC);
  });

  it('marks GraphQL JSON errors and ignores empty errors, data, and broken JSON', () => {
    const body = '{"query":"query GetUser { user { id } }"}';
    const url = 'https://example.com/graphql';
    const failed = parseAPIOperation('POST', url, body, '{"data":null,"errors":[{"message":"no"}]}');
    const empty = parseAPIOperation('POST', url, body, '{"data":{},"errors":[]}');
    const nested = parseAPIOperation('POST', url, body, '{"data":{"error":"nope"}}');
    const broken = parseAPIOperation('POST', url, body, 'not-json');
    assert.isTrue(failed!.hasErrors);
    assert.isFalse(empty!.hasErrors);
    assert.isFalse(nested!.hasErrors);
    assert.isFalse(broken!.hasErrors);
  });

  it('marks a tRPC error object and leaves result data alone', () => {
    const failed = parseAPIOperation(
        'POST', 'https://example.com/api/trpc/post.create', '{}', '{"error":{"json":{"message":"nope"}}}');
    const batch = parseAPIOperation(
        'POST', 'https://example.com/api/trpc/post.create', '{}', '[{"error":{"json":{"message":"nope"}}}]');
    const ok = parseAPIOperation(
        'GET', 'https://example.com/api/trpc/post.list', null, '{"result":{"data":{"ok":true}}}');
    const text = parseAPIOperation('POST', 'https://example.com/api/trpc/post.create', '{}', '{"error":"nope"}');
    assert.isTrue(failed!.hasErrors);
    assert.isTrue(batch!.hasErrors);
    assert.isFalse(ok!.hasErrors);
    assert.isFalse(text!.hasErrors);
  });

  it('bounds a long operation name', () => {
    const name = 'A'.repeat(450);
    const operation = parseAPIOperation('POST', 'https://example.com/graphql', `{"operationName":"${name}","query":"query ${name} { a }"}`, null);
    assert.lengthOf(operation!.name, 400);
  });

  it('filters by kind, errors, and search', () => {
    const query = parseAPIOperation('POST', 'https://example.com/graphql', '{"query":"query GetUser { a }"}', null)!;
    const failed = parseAPIOperation(
        'POST', 'https://example.com/api/trpc/post.create', '{}', '{"error":{"json":{"message":"no"}}}')!;
    assert.isTrue(operationMatches(query, 'graphql', ''));
    assert.isFalse(operationMatches(query, 'trpc', ''));
    assert.isTrue(operationMatches(failed, 'errors', ''));
    assert.isFalse(operationMatches(query, 'errors', ''));
    assert.isTrue(operationMatches(query, 'all', 'getuser'));
    assert.isFalse(operationMatches(query, 'all', 'post.create'));
  });

  it('keeps operations across navigation when the log is preserved', () => {
    assert.isTrue(keepAfterNavigation('loader-a', 'loader-b', true));
    assert.isTrue(keepAfterNavigation('loader-b', 'loader-b', false));
    assert.isFalse(keepAfterNavigation('loader-a', 'loader-b', false));
    assert.isFalse(keepAfterNavigation(null, 'loader-b', false));
  });

  it('moves the keyboard selection and clamps it', () => {
    assert.strictEqual(moveIndex(0, -1, 1), -1);
    assert.strictEqual(moveIndex(4, -1, 1), 0);
    assert.strictEqual(moveIndex(4, -1, -1), 3);
    assert.strictEqual(moveIndex(4, 3, 1), 3);
    assert.strictEqual(moveIndex(4, 0, -8), 0);
  });
});
