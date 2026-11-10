// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ShaarA11yOverlayScript {
  static let collect = """
    (() => {
      const maxStops = 30;
      const maxTexts = 30;
      const selector = 'a[href], button, input, select, textarea, summary, [tabindex], [contenteditable="true"]';
      const blocked = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'OPTION', 'SVG']);

      function install() {
        if (globalThis.__shaarA11yOverlay) return;
        const host = document.createElement('div');
        host.id = 'shaar-a11y-overlay';
        host.setAttribute('data-shaar-a11y-host', '1');
        host.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483646;';
        const shadow = host.attachShadow({mode: 'open'});
        const style = document.createElement('style');
        style.textContent = [
          ':host { all: initial; }',
          '.badge { position: fixed; z-index: 2147483646; pointer-events: none;',
          '  font: 600 11px/18px -apple-system, BlinkMacSystemFont, sans-serif; color: #fff; }',
          '.focus { min-width: 18px; height: 18px; padding: 0 4px; box-sizing: border-box;',
          '  border-radius: 9px; background: #013C3C; box-shadow: 0 0 0 2px #C8F736;',
          '  display: flex; align-items: center; justify-content: center; }',
          '.contrast { height: 18px; padding: 0 5px; border-radius: 4px; background: #9f1239; }'
        ].join('');
        const layer = document.createElement('div');
        shadow.append(style, layer);
        document.documentElement.append(host);
        const place = (badge, item) => {
          const contrast = item.group === 'contrast' || item.kind === 'contrast';
          const group = contrast ? 'data-shaar-contrast' : 'data-shaar-focus';
          const node = document.querySelector('[' + group + '="' + item.marker + '"]');
          const rect = node ? node.getBoundingClientRect() : null;
          const x = rect ? rect.left : item.x;
          const y = rect ? rect.top : item.y;
          if (contrast) {
            let right = x;
            if (node) {
              const range = document.createRange();
              range.selectNodeContents(node);
              const textRect = range.getBoundingClientRect();
              if (textRect.width >= 1) right = textRect.right;
            }
            badge.style.left = Math.max(0, right + 6) + 'px';
            badge.style.top = Math.max(0, y) + 'px';
            return;
          }
          badge.style.left = Math.max(0, x) + 'px';
          badge.style.top = Math.max(0, y - 20) + 'px';
        };
        const reposition = () => {
          for (const badge of layer.children) place(badge, badge.__shaarItem || {});
        };
        window.addEventListener('scroll', reposition, true);
        window.addEventListener('resize', reposition);
        globalThis.__shaarA11yOverlay = {
          paint(payload) {
            layer.replaceChildren();
            const badges = payload && payload.badges ? payload.badges : [];
            for (const item of badges) {
              if (!Number.isFinite(item.x) || !Number.isFinite(item.y)) continue;
              const badge = document.createElement('div');
              badge.className = 'badge ' + (item.kind === 'contrast' ? 'contrast' : 'focus');
              badge.dataset.kind = item.kind === 'contrast' ? 'contrast' : 'focus';
              badge.dataset.snippet = item.snippet || '';
              badge.textContent = String(item.label || '');
              badge.__shaarItem = item;
              place(badge, item);
              layer.append(badge);
            }
            return true;
          },
          clear() {
            window.removeEventListener('scroll', reposition, true);
            window.removeEventListener('resize', reposition);
            host.remove();
            document.querySelectorAll('[data-shaar-focus]').forEach((node) => {
              node.removeAttribute('data-shaar-focus');
            });
            document.querySelectorAll('[data-shaar-contrast]').forEach((node) => {
              node.removeAttribute('data-shaar-contrast');
            });
            delete globalThis.__shaarA11yOverlay;
            return true;
          },
          read() {
            const focus = [];
            const contrast = [];
            for (const badge of layer.children) {
              if (badge.dataset.kind === 'contrast') {
                contrast.push({label: badge.textContent || '', snippet: badge.dataset.snippet || ''});
              } else {
                focus.push(badge.textContent || '');
              }
            }
            return {focus, contrast};
          }
        };
      }

      function skipped(node) {
        return !node || node.closest('#shaar-a11y-overlay') || node.closest('[data-shaar-inspector]');
      }

      function shown(node) {
        if (skipped(node) || node.closest('[inert]')) return false;
        for (let current = node; current && current.nodeType === 1; current = current.parentElement) {
          const style = getComputedStyle(current);
          if (style.display === 'none' || style.visibility === 'hidden') return false;
        }
        const rect = node.getBoundingClientRect();
        return rect.width >= 1 || rect.height >= 1;
      }

      function label(node) {
        const text = node.getAttribute('aria-label') || node.innerText || node.textContent || '';
        return text.replace(/\\s+/g, ' ').trim().slice(0, 80);
      }

      function ownText(node) {
        let text = '';
        for (const child of node.childNodes) {
          if (child.nodeType === 3) text += child.textContent || '';
        }
        return text.replace(/\\s+/g, ' ').trim().slice(0, 80);
      }

      install();
      document.querySelectorAll('[data-shaar-focus]').forEach((node) => {
        node.removeAttribute('data-shaar-focus');
      });
      document.querySelectorAll('[data-shaar-contrast]').forEach((node) => {
        node.removeAttribute('data-shaar-contrast');
      });

      const stops = [];
      let truncated = false;
      let order = 0;
      for (const node of document.querySelectorAll(selector)) {
        if (stops.length >= maxStops) { truncated = true; break; }
        if (skipped(node) || !shown(node) || node.matches(':disabled')) continue;
        if (node.tagName === 'INPUT' && node.type === 'hidden') continue;
        if (node.tabIndex < 0) continue;
        const rect = node.getBoundingClientRect();
        node.setAttribute('data-shaar-focus', String(stops.length + 1));
        stops.push({
          id: stops.length + 1,
          tabIndex: node.tabIndex,
          documentOrder: order,
          name: label(node),
          x: rect.left,
          y: rect.top
        });
        order += 1;
      }

      const texts = [];
      function visit(node) {
        if (texts.length >= maxTexts) { truncated = true; return; }
        if (!node || skipped(node) || blocked.has(node.tagName)) return;
        const snippet = ownText(node);
        if (snippet && shown(node)) {
          const rect = node.getBoundingClientRect();
          node.setAttribute('data-shaar-contrast', String(texts.length + 1));
          texts.push({id: texts.length + 1, snippet, x: rect.left, y: rect.top});
        }
        for (const child of node.children) visit(child);
      }
      if (document.body) visit(document.body);
      return {
        scrollX: window.scrollX,
        scrollY: window.scrollY,
        stops,
        texts,
        truncated
      };
    })()
    """

  static let read = """
    (globalThis.__shaarA11yOverlay
      ? globalThis.__shaarA11yOverlay.read()
      : {focus: [], contrast: []})
    """

  static let clear = """
    (globalThis.__shaarA11yOverlay ? globalThis.__shaarA11yOverlay.clear() : true)
    """

  static func paint(_ badges: [[String: Any]]) -> String? {
    guard JSONSerialization.isValidJSONObject(["badges": badges]),
      let data = try? JSONSerialization.data(withJSONObject: ["badges": badges]),
      let json = String(data: data, encoding: .utf8)
    else { return nil }
    return "globalThis.__shaarA11yOverlay && globalThis.__shaarA11yOverlay.paint(\(json))"
  }
}
