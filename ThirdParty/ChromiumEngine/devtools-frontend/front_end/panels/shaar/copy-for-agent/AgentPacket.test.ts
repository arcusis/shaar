// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import {
  buildPacket,
  byteSize,
  LIMITS,
  packetAccepts,
  pngBytes,
  redact,
  samePage,
  SCREENSHOT_BASE64_CAP,
  trimHTML,
  winningRules,
} from './AgentPacket.js';

describe('AgentPacket', () => {
  it('keeps the packet limits', () => {
    assert.strictEqual(LIMITS.html, 2048);
    assert.strictEqual(LIMITS.rules, 12);
    assert.strictEqual(LIMITS.declarationsPerRule, 8);
    assert.strictEqual(LIMITS.declarations, 24);
    assert.strictEqual(LIMITS.errors, 8);
    assert.strictEqual(LIMITS.requests, 8);
    assert.strictEqual(LIMITS.headers, 4);
    assert.strictEqual(LIMITS.line, 180);
    assert.strictEqual(LIMITS.markdown, 12000);
  });

  it('redacts secrets and keeps an email address', () => {
    const jwt = [
      'eyJhbGciOiJIUzI1NiJ9',
      'eyJzdWIiOiIxMjM0NTY3ODkwIn0',
      'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c',
    ].join('.');
    const text = [
      'cookie: session=abc',
      'Authorization: Bearer abcdefghijklmnop',
      'note Bearer abcdefghijklmnop',
      'Set-Cookie: a=b',
      'Proxy-Authorization: Basic abcdefgh',
      'https://ada@example.com/path?token=abcdef&access_token=zzzzzzzz',
      'https://ada:secret@example.com/stay',
      jwt,
    ].join('\n');
    const redacted = redact(text);
    assert.include(redacted, 'cookie: [redacted]');
    assert.include(redacted, 'Authorization: [redacted]');
    assert.include(redacted, 'note Bearer [redacted]');
    assert.include(redacted, 'Set-Cookie: [redacted]');
    assert.include(redacted, 'Proxy-Authorization: [redacted]');
    assert.include(redacted, 'ada@example.com');
    assert.include(redacted, 'token=[redacted]');
    assert.include(redacted, 'access_token=[redacted]');
    assert.include(redacted, '[redacted]@example.com');
    assert.notInclude(redacted, 'session=abc');
    assert.notInclude(redacted, 'abcdefghijklmnop');
    assert.notInclude(redacted, 'eyJhbGciOiJIUzI1NiJ9');
    assert.notInclude(redacted, 'ada:secret@');
  });

  it('masks secret header names, query secrets, and a mid-line Authorization', () => {
    const headers = redact([
      'X-Api-Key: sk_live_secret',
      'X-Auth-Token: tok_secret',
      'Accept: text/html',
      'boom Authorization: Basic abcdefghijklmnop',
    ].join('\n'));
    assert.include(headers, 'X-Api-Key: [redacted]');
    assert.include(headers, 'X-Auth-Token: [redacted]');
    assert.include(headers, 'Accept: text/html');
    assert.include(headers, 'boom Authorization: [redacted]');
    assert.notInclude(headers, 'sk_live_secret');
    assert.notInclude(headers, 'tok_secret');
    assert.notInclude(headers, 'abcdefghijklmnop');
    assert.isFalse(packetAccepts('X-Api-Key: sk_live_secret\n'));
    assert.isTrue(packetAccepts('X-Api-Key: [redacted]\n'));
    const query = redact(
        'https://example.com/a?key=abcdef&code=zzzzzzzz&session=sess&sig=abc&signature=longer' +
        '&X-Amz-Signature=deadbeef&page=1');
    assert.include(query, 'key=[redacted]');
    assert.include(query, 'code=[redacted]');
    assert.include(query, 'session=[redacted]');
    assert.include(query, 'sig=[redacted]');
    assert.include(query, 'signature=[redacted]');
    assert.include(query, 'X-Amz-Signature=[redacted]');
    assert.include(query, 'page=1');
    assert.notInclude(query, 'deadbeef');
    assert.isFalse(packetAccepts('https://example.com/?key=abcdef\n'));
    assert.isTrue(packetAccepts('https://example.com/?key=[redacted]\n'));
    assert.isFalse(packetAccepts('https://cdn.example/?X-Amz-Credential=AKIAEXAMPLE\n'));
  });

  it('redacts csrf meta content and token data attributes', () => {
    const html = trimHTML(
        '<meta name="csrf-token" content="csrf-secret-value">' +
        '<div data-token="tokensecret" data-session="sess-secret" data-source="/src/Card.tsx:12">ok</div>');
    assert.include(html, 'name="csrf-token"');
    assert.include(html, 'content="[redacted]"');
    assert.include(html, 'data-token="[redacted]"');
    assert.include(html, 'data-session="[redacted]"');
    assert.include(html, 'data-source="/src/Card.tsx:12"');
    assert.notInclude(html, 'csrf-secret-value');
    assert.notInclude(html, 'tokensecret');
    assert.notInclude(html, 'sess-secret');
  });

  it('trims HTML without letting a void input swallow the document', () => {
    const html = trimHTML(
        '<div class="card" onclick="nope()" data-source="/src/Card.tsx:12" data-shaar-agent="abc">' +
        'before<input value="secret">after</div>' +
        '<script>token=abcdef</script><p style="color:red">kept</p><!-- hidden -->');
    assert.include(html, 'data-source="/src/Card.tsx:12"');
    assert.include(html, 'before');
    assert.include(html, 'after');
    assert.include(html, '<p>kept</p>');
    assert.notInclude(html, 'secret');
    assert.notInclude(html, 'onclick');
    assert.notInclude(html, 'data-shaar-agent');
    assert.notInclude(html, 'token=');
    assert.notInclude(html, 'color:red');
    assert.notInclude(html, 'hidden');
    assert.notInclude(html, '<input');
    assert.notInclude(html, '<script');
  });

  it('caps a text run at 300 characters and the document at 2048', () => {
    assert.strictEqual(trimHTML('a'.repeat(300_000)).length, 300);
    const html = trimHTML(('<b>' + 'a'.repeat(300) + '</b>').repeat(20));
    assert.strictEqual(html.length, LIMITS.html);
  });

  it('keeps the last explicit declaration and emits rules in source order', () => {
    const rules = winningRules({
      matchedCSSRules: [
        {
          rule: {
            selectorList: {selectors: [{text: '.card'}, {text: '.tile'}]},
            style: {
              cssProperties: [
                {name: 'color', value: 'red'},
                {name: 'margin', value: '1px'},
                {name: 'display', value: 'block', disabled: true},
              ],
            },
          },
          matchingSelectors: [0],
        },
        {
          selectorList: {selectors: [{text: '.card.live'}]},
          style: {
            cssProperties: [
              {name: 'color', value: 'blue'},
              {name: 'display', value: 'flex', implicit: true},
            ],
          },
        },
      ],
      inlineStyle: {cssProperties: [{name: 'padding', value: '4px'}]},
    });
    assert.deepEqual(rules.map(rule => rule.selector), ['.card, .tile', '.card.live', 'element.style']);
    const color = rules.flatMap(rule => rule.declarations).filter(item => item.name === 'color');
    assert.deepEqual(color, [{name: 'color', value: 'blue'}]);
    assert.notDeepInclude(rules[0].declarations, {name: 'display', value: 'block'});
    assert.include(rules[0].declarations.map(item => item.name), 'margin');
    assert.deepEqual(rules[2].declarations, [{name: 'padding', value: '4px'}]);
  });

  it('caps rules at 12 and declarations at 8 per rule and 24 overall', () => {
    const manyRules = [];
    for (let rule = 0; rule < 13; rule++) {
      manyRules.push({selector: `.r${rule}`, style: [{name: `p${rule}`, value: 'x'}]});
    }
    const cappedRules = winningRules({matchedCSSRules: manyRules});
    assert.strictEqual(cappedRules.length, LIMITS.rules);
    assert.notInclude(cappedRules.map(rule => rule.selector), '.r12');

    const wideRules = [];
    for (let rule = 0; rule < 4; rule++) {
      const cssProperties = [];
      for (let property = 0; property < 9; property++) {
        cssProperties.push({name: `p${rule}-${property}`, value: 'x'});
      }
      wideRules.push({selector: `.w${rule}`, style: cssProperties});
    }
    const cappedDeclarations = winningRules({matchedCSSRules: wideRules});
    assert.strictEqual(cappedDeclarations[0].declarations.length, LIMITS.declarationsPerRule);
    const total = cappedDeclarations.reduce((sum, rule) => sum + rule.declarations.length, 0);
    assert.strictEqual(total, LIMITS.declarations);
    assert.strictEqual(cappedDeclarations.length, 3);
  });

  it('builds a redacted packet and shows its size', () => {
    const packet = buildPacket({
      page: {
        scope: 'element',
        url: 'https://ada:secret@example.com/card?token=abcdef',
        html: '<p class="card" data-source="/src/Card.tsx:12">ada@example.com</p>',
        source: '/src/Card.tsx:12',
        consoleRecording: true,
        consoleErrors: ['Bearer abcdefghijklmnop', 'plain failure'],
        failedRequests: [
          {method: 'GET', url: 'https://example.com/ok', status: 200},
          {
            method: 'POST',
            url: 'https://example.com/api?token=zzzzzzzz',
            status: 500,
            requestHeaders: [
              {name: 'Cookie', value: 'session=secret'},
              {name: 'X-Api-Key', value: 'sk_live_secret'},
              {name: 'Accept', value: 'application/json'},
            ],
            responseHeaders: [{name: 'Set-Cookie', value: 'a=b'}],
          },
        ],
      },
      matchedStyles: {
        matchedCSSRules: [
          {
            rule: {
              selectorList: {selectors: [{text: '.card'}]},
              style: {cssProperties: [{name: 'color', value: 'red'}]},
            },
          },
          {
            rule: {
              selectorList: {selectors: [{text: '.card.live'}]},
              style: {cssProperties: [{name: 'color', value: 'blue'}]},
            },
          },
        ],
      },
      screenshotBytes: 2700,
    });
    assert.strictEqual(packet.scope, 'element');
    assert.include(packet.markdown, '# Agent packet');
    assert.include(packet.markdown, 'Scope: element');
    assert.include(packet.markdown, '## Source');
    assert.include(packet.markdown, '/src/Card.tsx:12');
    assert.include(packet.markdown, 'ada@example.com');
    assert.include(packet.markdown, 'color: blue');
    assert.notInclude(packet.markdown, 'color: red');
    assert.include(packet.markdown, '- plain failure');
    assert.include(packet.markdown, 'Bearer [redacted]');
    assert.include(packet.markdown, 'POST https://example.com/api?token=[redacted] — 500');
    assert.include(packet.markdown, 'Cookie: [redacted]');
    assert.include(packet.markdown, 'X-Api-Key: [redacted]');
    assert.include(packet.markdown, 'Set-Cookie: [redacted]');
    assert.include(packet.markdown, 'Accept: application/json');
    assert.notInclude(packet.markdown, 'sk_live_secret');
    assert.notInclude(packet.markdown, 'https://example.com/ok');
    assert.include(packet.markdown, 'PNG attached, 2700 bytes.');
    assert.notInclude(packet.markdown, 'session=secret');
    assert.notInclude(packet.markdown, 'ada:secret@');
    assert.isTrue(packetAccepts(packet.markdown));
    assert.strictEqual(packet.bytes, new TextEncoder().encode(packet.markdown).length + 2700);
    assert.strictEqual(packet.rules.length, 1);
    assert.strictEqual(packet.errors.length, 2);
    assert.strictEqual(packet.requests.length, 1);
    assert.strictEqual(byteSize(packet.bytes).endsWith('KB') || byteSize(packet.bytes).endsWith('B'), true);
  });

  it('says when the console buffer and the screenshot are missing', () => {
    const quiet = buildPacket({
      page: {scope: 'page', url: 'https://example.com/', consoleRecording: false, consoleErrors: ['hidden']},
      stylesOmitted: true,
      matchedStyles: {matchedCSSRules: [{selector: '.x', style: [{name: 'color', value: 'red'}]}]},
      screenshotBytes: 0,
    });
    assert.include(quiet.markdown, 'none recorded (no buffer was running)');
    assert.include(quiet.markdown, 'styles omitted');
    assert.include(quiet.markdown, 'Screenshot: omitted.');
    assert.notInclude(quiet.markdown, 'color: red');
    assert.notInclude(quiet.markdown, 'hidden');
    assert.strictEqual(quiet.scope, 'page');
    assert.strictEqual(quiet.rules.length, 0);
    assert.isTrue(quiet.markdown.endsWith('\n'));
  });

  it('fits the markdown under the byte cap', () => {
    const long = 'x'.repeat(LIMITS.line);
    const failedRequests = [];
    for (let index = 0; index < LIMITS.requests; index++) {
      failedRequests.push({
        method: 'GET',
        url: `https://example.com/${long}`,
        status: 500,
        requestHeaders: [
          {name: 'A', value: long},
          {name: 'B', value: long},
          {name: 'C', value: long},
          {name: 'D', value: long},
        ],
        responseHeaders: [
          {name: 'E', value: long},
          {name: 'F', value: long},
          {name: 'G', value: long},
          {name: 'H', value: long},
        ],
      });
    }
    const packet = buildPacket({
      page: {
        html: `<p>${'y'.repeat(20_000)}</p>`,
        consoleRecording: true,
        consoleErrors: Array.from({length: LIMITS.errors}, () => long),
        failedRequests,
        url: 'https://example.com/',
      },
    });
    assert.isAtMost(new TextEncoder().encode(packet.markdown).length, LIMITS.markdown);
    assert.isTrue(packet.markdown.endsWith('\n'));
  });

  it('caps errors, requests, headers, and lines', () => {
    const failedRequests = [];
    for (let index = 0; index < 9; index++) {
      failedRequests.push({
        method: 'GET',
        url: `https://example.com/${index}`,
        status: 404,
        requestHeaders: [
          {name: 'A', value: '1'},
          {name: 'B', value: '2'},
          {name: 'C', value: '3'},
          {name: 'D', value: '4'},
          {name: 'E', value: '5'},
        ],
      });
    }
    const packet = buildPacket({
      page: {
        consoleRecording: true,
        consoleErrors: ['0', '1', '2', '3', '4', '5', '6', '7', '8'],
        failedRequests,
        source: 's'.repeat(400),
        url: 'u'.repeat(400),
      },
    });
    assert.strictEqual(packet.errors.length, LIMITS.errors);
    assert.strictEqual(packet.requests.length, LIMITS.requests);
    assert.strictEqual(packet.source.length, LIMITS.line);
    assert.notInclude(packet.markdown, '\n  E:');
    assert.include(packet.markdown, '\n  D:');
  });

  it('formats sizes with integer tenths below 10 KB', () => {
    assert.strictEqual(byteSize(0), '0 B');
    assert.strictEqual(byteSize(1023), '1023 B');
    assert.strictEqual(byteSize(1024), '1.0 KB');
    assert.strictEqual(byteSize(1536), '1.5 KB');
    assert.strictEqual(byteSize(10239), '9.9 KB');
    assert.strictEqual(byteSize(10240), '10 KB');
    assert.strictEqual(byteSize(10752), '11 KB');
  });

  it('refuses a packet that still contains a secret', () => {
    assert.isFalse(packetAccepts('cookie: session=abc\n'));
    assert.isTrue(packetAccepts('cookie: [redacted]\n'));
    assert.isFalse(packetAccepts('Authorization: Bearer abcdefghijklmnop\n'));
    assert.isTrue(packetAccepts('Authorization: Bearer [redacted]\n'));
    assert.isFalse(packetAccepts('https://example.com/?token=abcdef\n'));
    assert.isTrue(packetAccepts('https://example.com/?token=[redacted]\n'));
    assert.isFalse(packetAccepts('X-Api-Key: sk_live_secret\n'));
    assert.isTrue(packetAccepts('X-Auth-Token: [redacted]\n'));
  });

  it('counts a PNG and ignores anything else', () => {
    assert.strictEqual(pngBytes('iVBORw0KGgo='), 8);
    assert.strictEqual(pngBytes('aGVsbG8='), 0);
    assert.strictEqual(pngBytes('****'), 0);
    assert.strictEqual(pngBytes('A'.repeat(SCREENSHOT_BASE64_CAP + 1)), 0);
  });

  it('matches a page by url and loader id', () => {
    const stamp = {url: 'https://example.com/', loaderId: '1'};
    assert.isTrue(samePage(stamp, {url: 'https://example.com/', loaderId: '1'}));
    assert.isFalse(samePage(stamp, {url: 'https://example.com/next', loaderId: '1'}));
    assert.isFalse(samePage(stamp, {url: 'https://example.com/', loaderId: '2'}));
  });
});
