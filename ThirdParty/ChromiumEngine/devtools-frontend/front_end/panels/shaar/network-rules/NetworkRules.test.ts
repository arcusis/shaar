// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import * as NetworkRules from './network-rules.js';

const Rules = NetworkRules.NetworkRules;
const ID = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';

describe('NetworkRules', () => {
  afterEach(() => {
    Rules.clearStagedCommands();
  });

  it('round-trips the schema used by the Swift rules file', () => {
    const rule = Rules.normalized({
      ...Rules.createRule(ID),
      enabled: true,
      method: 'GET',
      url: 'https://example.test/api?q=1',
      kind: 'mock',
      status: 201,
      bodyText: 'ok',
      headers: [{name: 'X-Test', value: 'yes'}],
      redirectURL: 'https://ignored.example/',
      delayMilliseconds: 50,
    });
    const text = Rules.exchangeText([rule]);
    assert.isTrue(text.ok);
    if (!text.ok) {
      return;
    }
    const parsed = Rules.parseExchange(text.text.replaceAll('/', '\\/'));
    assert.deepEqual(parsed, {ok: true, rules: [rule]});
  });

  it('rejects unsafe and malformed rule files', () => {
    assert.deepEqual(Rules.parseExchange('[]'), {ok: false, error: 'document'});
    assert.deepEqual(Rules.parseExchange('{"schemaVersion":1,"rules":[]}'), {ok: true, rules: []});
    assert.deepEqual(Rules.parseExchange(JSON.stringify({schemaVersion: 2, rules: []})), {ok: false, error: 'document'});
    const duplicate = document([row(), row()]);
    assert.deepEqual(Rules.parseExchange(duplicate).ok ? null : Rules.parseExchange(duplicate), {ok: false, error: 'document'});
    const script = document([{...row(), kind: 'redirect', redirectURL: 'javascript:alert(1)'}]);
    assert.deepEqual(Rules.parseExchange(script), {ok: false, error: 'action'});
    const unknown = document([{...row(), kind: 'evaluate'}]);
    assert.deepEqual(Rules.parseExchange(unknown), {ok: false, error: 'document'});
    const brokenHeader = document([{...row(), kind: 'requestHeaders', headers: [{name: 'X-Test', value: 'bad\r\nheader'}]}]);
    assert.deepEqual(Rules.parseExchange(brokenHeader), {ok: false, error: 'headers'});
    const enabled = Array.from({length: 33}, (_, index) => ({...row(index), enabled: true}));
    assert.deepEqual(Rules.parseExchange(document(enabled)), {ok: false, error: 'limit'});
  });

  it('matches the Fetch lease actions', () => {
    const mock = enabled({kind: 'mock', status: 201, bodyText: 'ok', headers: [{name: 'X-Test', value: 'yes'}]});
    const redirect = enabled({id: OTHER, kind: 'redirect', redirectURL: 'https://example.test/next'});
    const delay = enabled({kind: 'delay', delayMilliseconds: 400, url: 'https://example.test/slow'});
    const requestHeaders = enabled({
      kind: 'requestHeaders',
      url: 'https://example.test/headers',
      headers: [{name: 'a', value: '3'}],
    });
    const responseHeaders = enabled({
      kind: 'responseHeaders',
      url: 'https://example.test/headers',
      headers: [{name: 'X-Test', value: 'yes'}],
    });

    const mocked = Rules.actionFor('r1', [mock, redirect], paused());
    assert.deepEqual(mocked, {
      kind: 'rewrite',
      command: {
        method: 'fulfillRequest',
        params: {requestId: 'r1', responseCode: 201, body: 'b2s=', responseHeaders: [{name: 'X-Test', value: 'yes'}]},
      },
    });

    const redirected = Rules.actionFor('r2', [redirect], paused());
    assert.deepEqual(redirected, {
      kind: 'rewrite',
      command: {method: 'continueRequest', params: {requestId: 'r2', url: 'https://example.test/next'}},
    });

    assert.deepEqual(Rules.actionFor('r3', [delay], paused({url: 'https://example.test/slow'})), {
      kind: 'delay',
      milliseconds: 400,
    });

    const request = Rules.actionFor('r4', [requestHeaders], paused({
      url: 'https://example.test/headers',
      requestHeaders: [{name: 'A', value: '1'}, {name: 'B', value: '2'}],
    }));
    assert.deepEqual(request, {
      kind: 'rewrite',
      command: {
        method: 'continueRequest',
        params: {requestId: 'r4', headers: [{name: 'B', value: '2'}, {name: 'a', value: '3'}]},
      },
    });

    const response = Rules.actionFor('r5', [responseHeaders], paused({
      url: 'https://example.test/headers',
      responseStage: true,
      statusCode: 204,
      responseHeaders: [{name: 'X-Test', value: 'old'}, {name: 'Keep', value: '1'}],
    }));
    assert.deepEqual(response, {
      kind: 'rewrite',
      command: {
        method: 'continueResponse',
        params: {
          requestId: 'r5',
          responseCode: 204,
          responseHeaders: [{name: 'Keep', value: '1'}, {name: 'X-Test', value: 'yes'}],
        },
      },
    });

    assert.deepEqual(Rules.actionFor('r6', [mock], paused({method: 'POST'})), {kind: 'continue'});
    assert.deepEqual(Rules.actionFor('r7', [mock], paused({url: 'https://other.test/'})), {kind: 'ignore'});
    assert.deepEqual(
        Rules.actionFor('r8', [responseHeaders], paused({url: 'https://example.test/headers', responseStage: true})), {
          kind: 'rewrite',
          command: {method: 'continueResponse', params: {requestId: 'r8'}},
        });
    assert.strictEqual(Rules.actionFor('r9', [mock, enabled({kind: 'mock', status: 500, bodyText: 'later'})], paused()).kind, 'rewrite');
    if (mocked.kind === 'rewrite' && mocked.command.method === 'fulfillRequest') {
      assert.strictEqual(mocked.command.params.responseCode, 201);
    }
  });

  it('escapes Fetch urlPattern metacharacters and splits response stage', () => {
    const rules = [
      enabled({url: 'https://example.test/a*b?c\\d'}),
      enabled({url: 'https://example.test/a*b?c\\d', kind: 'responseHeaders', headers: [{name: 'X', value: '1'}]}),
    ];
    assert.deepEqual(Rules.interceptionPatterns(rules), [
      {urlPattern: 'https://example.test/a\\*b\\?c\\\\d', requestStage: 'Request'},
      {urlPattern: 'https://example.test/a\\*b\\?c\\\\d', requestStage: 'Response'},
    ]);
  });

  it('rewrites only the staged Fetch continue', () => {
    const calls: string[] = [];
    const agent: NetworkRules.NetworkRules.FetchAgentLike = {
      invoke_continueRequest(params) {
        calls.push(`continue:${params.requestId}:${params.url ?? ''}`);
      },
      invoke_fulfillRequest(params) {
        calls.push(`fulfill:${params.requestId}:${params.responseCode}`);
      },
      invoke_continueResponse(params) {
        calls.push(`response:${params.requestId}`);
      },
    };
    Rules.installFetchRewrite(agent, Rules.takeCommand);
    Rules.installFetchRewrite(agent, Rules.takeCommand);
    Rules.stageCommand('1', {
      method: 'fulfillRequest',
      params: {requestId: '1', responseCode: 201, body: 'b2s=', responseHeaders: []},
    });
    agent.invoke_continueRequest({requestId: '1'});
    agent.invoke_continueRequest({requestId: '2'});
    Rules.stageCommand('3', {method: 'continueRequest', params: {requestId: '3', url: 'https://example.test/next'}});
    agent.invoke_continueRequest({requestId: '3'});
    Rules.stageCommand('4', {method: 'continueResponse', params: {requestId: '4', responseCode: 204}});
    agent.invoke_continueRequest({requestId: '4'});
    assert.deepEqual(calls, [
      'fulfill:1:201',
      'continue:2:',
      'continue:3:https://example.test/next',
      'response:4',
    ]);
  });

  it('keeps site keys as scheme, host, and a non-default port', () => {
    assert.strictEqual(Rules.siteOrigin('https://example.test/path?q=1'), 'https://example.test');
    assert.strictEqual(Rules.siteOrigin('http://localhost:8080/app'), 'http://localhost:8080');
    assert.strictEqual(Rules.siteOrigin('https://example.test:443/'), 'https://example.test');
    assert.isNull(Rules.siteOrigin('file:///tmp/a'));
    assert.strictEqual(Rules.validate({...Rules.createRule(ID), url: 'https://user:pass@example.test/'}), 'match');
  });
});

function row(index = 0): Record<string, unknown> {
  const id = index === 0 ? ID : `33333333-3333-4333-8333-${String(index).padStart(12, '0')}`;
  return {
    id,
    enabled: false,
    method: 'GET',
    url: `https://example.test/${index}`,
    kind: 'mock',
    status: 200,
    headers: [],
    bodyText: '',
    redirectURL: '',
    delayMilliseconds: 0,
  };
}

function document(rules: unknown[]): string {
  return JSON.stringify({schemaVersion: 1, rules});
}

function enabled(fields: Partial<NetworkRules.NetworkRules.NetworkRule>): NetworkRules.NetworkRules.NetworkRule {
  return Rules.normalized({
    ...Rules.createRule(fields.id ?? ID),
    enabled: true,
    url: 'https://example.test/api?q=1',
    ...fields,
  });
}

function paused(fields: Partial<NetworkRules.NetworkRules.PausedRequest> = {}): NetworkRules.NetworkRules.PausedRequest {
  return {
    url: 'https://example.test/api?q=1',
    method: 'GET',
    responseStage: false,
    requestHeaders: [],
    ...fields,
  };
}
