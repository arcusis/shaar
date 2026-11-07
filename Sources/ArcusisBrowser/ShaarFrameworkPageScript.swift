// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ShaarFrameworkPageScript {
  /// Reads React, Vue, or Angular debug surfaces already on the page.
  /// The caller evaluates this only after the localhost gate allows it.
  static let inspect = library + "\nshaarInspectFramework(globalThis)"

  static func highlightExpression(id: String?, epoch: Int) -> String? {
    guard epoch > 0, epoch < 1_000_000_000 else { return nil }
    let token = highlightToken(id)
    guard let token else { return nil }
    return "globalThis.__shaarHighlightFrameworkComponent?.(\(token),\(epoch))"
  }

  static func propsExpression(id: String) -> String? {
    guard isComponentID(id) else { return nil }
    return "globalThis.__shaarFrameworkProps?.[\"\(id)\"]"
  }

  static func isComponentID(_ id: String) -> Bool {
    guard (1...4).contains(id.utf16.count) else { return false }
    return id.unicodeScalars.allSatisfy { ("0"..."9").contains(Character($0)) }
  }

  private static func highlightToken(_ id: String?) -> String? {
    guard let id else { return "null" }
    guard isComponentID(id) else { return nil }
    return "\"\(id)\""
  }

  private static let library = #"""
    function shaarInspectFramework(scope) {
      const window = scope.window || scope;
      const document = scope.document;
      if (!window || !document) return { schema: 1, framework: null, nodes: [] };
      const nodes = [];
      const hosts = {};
      const propsObjects = {};
      function clip(value, limit) {
        const text = String(value);
        if (text.length <= limit) return text;
        return text.slice(0, limit - 1) + "…";
      }
      function primitive(value) {
        if (value == null) return value === null ? "null" : null;
        const kind = typeof value;
        if (kind === "string" || kind === "number" || kind === "boolean") return clip(value, 120);
        return null;
      }
      function ownProperty(object, key) {
        try { return Object.getOwnPropertyDescriptor(object, key); }
        catch (error) { return null; }
      }
      function ownValue(object, key) {
        const descriptor = ownProperty(object, key);
        return descriptor && Object.prototype.hasOwnProperty.call(descriptor, "value")
          ? descriptor.value : undefined;
      }
      function isAccessor(descriptor) {
        return descriptor && !Object.prototype.hasOwnProperty.call(descriptor, "value");
      }
      function objectSummary(value) {
        const summary = {};
        const keys = Object.keys(value);
        for (let index = 0; index < keys.length && index < 8; index += 1) {
          const key = keys[index];
          const descriptor = ownProperty(value, key);
          if (!descriptor) continue;
          if (isAccessor(descriptor)) {
            summary[key] = "(...)";
          } else if (primitive(descriptor.value) != null) {
            summary[key] = descriptor.value;
          }
        }
        try { return JSON.stringify(summary); } catch (error) { return "{…}"; }
      }
      function fieldValue(value) {
        const text = primitive(value);
        if (text != null) return text;
        if (value == null || typeof value !== "object" || ownValue(value, "nodeType")) return null;
        if (Array.isArray(value)) {
          const parts = [];
          for (let index = 0; index < value.length && parts.length < 8; index += 1) {
            const descriptor = ownProperty(value, String(index));
            const item = isAccessor(descriptor)
              ? "(...)" : primitive(descriptor && descriptor.value);
            if (item != null) parts.push(item);
          }
          return clip("[" + parts.join(", ") + "]", 120);
        }
        return clip(objectSummary(value), 120);
      }
      function accessorNames(value) {
        if (!value || typeof value !== "object") return [];
        const result = [];
        for (const key of Object.keys(value).slice(0, 8)) {
          if (isAccessor(ownProperty(value, key))) result.push(key);
        }
        return result;
      }
      function fieldsOf(object) {
        if (!object || typeof object !== "object" || ownValue(object, "nodeType")) return [];
        const skipped = { children: true, child: true, sibling: true, return: true, ref: true, key: true };
        const result = [];
        const keys = Object.keys(object);
        for (let index = 0; index < keys.length && result.length < 12; index += 1) {
          const name = keys[index];
          if (skipped[name] || name.charAt(0) === "_") continue;
          const descriptor = ownProperty(object, name);
          if (!descriptor) continue;
          const accessor = isAccessor(descriptor);
          const text = accessor ? "(...)" : fieldValue(descriptor.value);
          if (text == null) continue;
          result.push({
            name: clip(name, 40), value: text,
            accessors: accessor ? [""] : accessorNames(descriptor.value),
          });
        }
        return result;
      }
      function keyText(key) {
        if (key == null || key === "") return null;
        if (typeof key !== "string" && typeof key !== "number") return null;
        return clip(key, 40);
      }
      function addNode(entry) {
        if (nodes.length >= 80) return null;
        const name = clip(entry.name || "Anonymous", 80);
        if (!name) return null;
        const id = String(nodes.length + 1);
        nodes.push({
          id: id,
          parentID: entry.parentID || null,
          name: name,
          key: keyText(entry.key),
          props: entry.props || [],
          state: entry.state || [],
        });
        if (entry.propsObject) propsObjects[id] = entry.propsObject;
        return id;
      }
      function remember(id, element) {
        if (element && element.nodeType === 1) hosts[id] = element;
      }
      function isEffectRecord(value) {
        if (!value || typeof value !== "object" || Array.isArray(value)) return false;
        const hasDeps = Object.prototype.hasOwnProperty.call(value, "deps");
        const hasEffect = Object.prototype.hasOwnProperty.call(value, "create")
          || Object.prototype.hasOwnProperty.call(value, "destroy")
          || Object.prototype.hasOwnProperty.call(value, "tag");
        return hasDeps && hasEffect;
      }
      function hookFields(hook) {
        const result = [];
        let current = hook;
        let guard = 0;
        while (current && result.length < 12 && guard < 40) {
          guard += 1;
          if (!isEffectRecord(current.memoizedState)) {
            const text = fieldValue(current.memoizedState);
            if (text != null) result.push({ name: "state " + (result.length + 1), value: text });
          }
          current = current.next;
        }
        return result;
      }
      function reactName(type) {
        if (typeof type === "function") return type.displayName || type.name || "Anonymous";
        if (type && typeof type === "object") return type.displayName || type.name || null;
        return null;
      }
      function reactElement(fiber) {
        let current = fiber;
        let guard = 0;
        while (current && guard < 30) {
          guard += 1;
          if (current.stateNode && current.stateNode.nodeType === 1) return current.stateNode;
          current = current.child;
        }
        return null;
      }
      function climbFiber(fiber) {
        let current = fiber;
        let guard = 0;
        while (current && current.return && guard < 100) {
          guard += 1;
          current = current.return;
        }
        return current;
      }
      function fiberFromRoot(root) {
        if (!root || typeof root !== "object") return null;
        if (root.current) return root.current;
        return root;
      }
      function reactHookRoots() {
        const hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
        const roots = [];
        if (!hook || typeof hook.getFiberRoots !== "function" || !hook.renderers
          || typeof hook.renderers.forEach !== "function") return roots;
        hook.renderers.forEach(function (_renderer, id) {
          let set = null;
          try { set = hook.getFiberRoots(id); } catch (error) { set = null; }
          if (!set || typeof set.forEach !== "function") return;
          set.forEach(function (root) {
            const fiber = fiberFromRoot(root);
            if (fiber) roots.push(fiber);
          });
        });
        return roots;
      }
      function reactDOMRoots() {
        const roots = [];
        const seen = new Set();
        const elements = document.getElementsByTagName
          ? document.getElementsByTagName("*") : document.querySelectorAll("*");
        const cap = Math.min(elements.length, 2000);
        for (let index = 0; index < cap && roots.length < 8; index += 1) {
          const element = elements[index];
          try {
            for (const key in element) {
              if (!Object.prototype.hasOwnProperty.call(element, key)) continue;
              const isContainer = key.indexOf("__reactContainer$") === 0;
              const isFiber = key.indexOf("__reactFiber$") === 0
                || key.indexOf("__reactInternalInstance$") === 0;
              if (!isContainer && !isFiber) continue;
              const root = climbFiber(fiberFromRoot(element[key]));
              if (root && !seen.has(root)) {
                seen.add(root);
                roots.push(root);
              }
            }
          } catch (error) { continue; }
        }
        return roots;
      }
      function walkFiber(fiber, parentID, depth, seen, steps) {
        if (!fiber || seen.has(fiber) || nodes.length >= 80 || steps > 500) return;
        seen.add(fiber);
        const name = reactName(fiber.type);
        let nextParent = parentID;
        let nextDepth = depth;
        if (name && depth <= 12) {
          const props = ownValue(fiber, "memoizedProps");
          const id = addNode({
            parentID: parentID,
            name: name,
            key: fiber.key,
            props: fieldsOf(props),
            propsObject: props,
            state: hookFields(fiber.memoizedState),
          });
          if (id) {
            remember(id, reactElement(fiber));
            nextParent = id;
            nextDepth = depth + 1;
          }
        }
        walkFiber(fiber.child, nextParent, nextDepth, seen, steps + 1);
        walkFiber(fiber.sibling, parentID, depth, seen, steps + 1);
      }
      function readReact() {
        const hookRoots = reactHookRoots();
        const roots = hookRoots.length ? hookRoots : reactDOMRoots();
        if (!roots.length) return false;
        const seen = new Set();
        const before = nodes.length;
        for (let index = 0; index < roots.length; index += 1) {
          walkFiber(roots[index], null, 0, seen, 0);
        }
        return nodes.length > before;
      }
      function vueElement(instance) {
        const candidates = [
          instance.subTree && instance.subTree.el,
          instance.vnode && instance.vnode.el,
        ];
        for (let index = 0; index < candidates.length; index += 1) {
          if (candidates[index] && candidates[index].nodeType === 1) return candidates[index];
        }
        return null;
      }
      function vueState(instance) {
        const setup = fieldsOf(instance.setupState);
        if (setup.length) return setup;
        return fieldsOf(instance.data);
      }
      function collectVue(vnode, found, seen) {
        if (!vnode || typeof vnode !== "object" || seen.has(vnode) || found.length >= 80) return;
        seen.add(vnode);
        if (vnode.component) {
          found.push(vnode.component);
          return;
        }
        const children = vnode.children;
        if (Array.isArray(children)) {
          for (let index = 0; index < children.length; index += 1) collectVue(children[index], found, seen);
        } else if (children && typeof children === "object") collectVue(children, found, seen);
      }
      function walkVue(instance, parentID, depth, seen) {
        if (!instance || seen.has(instance) || nodes.length >= 80 || depth > 12) return;
        seen.add(instance);
        const type = instance.type || {};
        const name = type.name || type.__name || "Anonymous";
        const props = ownValue(instance, "props");
        const id = addNode({
          parentID: parentID,
          name: name,
          props: fieldsOf(props),
          propsObject: props,
          state: vueState(instance),
        });
        if (!id) return;
        remember(id, vueElement(instance));
        const children = [];
        collectVue(instance.subTree, children, new Set());
        for (let index = 0; index < children.length; index += 1) {
          walkVue(children[index], id, depth + 1, seen);
        }
      }
      function vueRoots() {
        const instances = [];
        const hook = window.__VUE_DEVTOOLS_GLOBAL_HOOK__;
        if (hook && Array.isArray(hook.apps)) {
          for (let index = 0; index < hook.apps.length && instances.length < 8; index += 1) {
            const record = hook.apps[index];
            const app = record && (record.app || record);
            if (app && app._instance) instances.push(app._instance);
          }
        }
        if (instances.length) return instances;
        const elements = document.getElementsByTagName
          ? document.getElementsByTagName("*") : document.querySelectorAll("*");
        const cap = Math.min(elements.length, 2000);
        for (let index = 0; index < cap && instances.length < 8; index += 1) {
          const app = elements[index].__vue_app__;
          if (app && app._instance) instances.push(app._instance);
        }
        return instances;
      }
      function readVue() {
        const roots = vueRoots();
        if (!roots.length) return false;
        const seen = new Set();
        const before = nodes.length;
        for (let index = 0; index < roots.length; index += 1) walkVue(roots[index], null, 0, seen);
        return nodes.length > before;
      }
      function angularName(component, element) {
        const constructorName = component.constructor && component.constructor.name;
        if (constructorName && constructorName !== "Object" && constructorName !== "Function") {
          return constructorName;
        }
        if (element.localName) return element.localName;
        return "Anonymous";
      }
      function angularProps(component) {
        const inputs = ownValue(component, "inputs");
        if (inputs && typeof inputs === "object") return fieldsOf(inputs);
        return fieldsOf(component);
      }
      function angularState(component) {
        const state = ownValue(component, "state");
        if (state && typeof state === "object") return fieldsOf(state);
        return [];
      }
      function angularRoots() {
        if (typeof window.getAllAngularRootElements === "function") {
          const roots = window.getAllAngularRootElements();
          if (roots && typeof roots.length === "number") return Array.prototype.slice.call(roots, 0, 8);
        }
        const marked = document.querySelectorAll("[ng-version]");
        return Array.prototype.slice.call(marked, 0, 8);
      }
      function walkAngular(element, parentID, depth, seen) {
        if (!element || element.nodeType !== 1 || depth > 12 || nodes.length >= 80) return;
        const component = window.ng.getComponent(element);
        let nextParent = parentID;
        let nextDepth = depth;
        if (component && typeof component === "object" && !seen.has(component)) {
          seen.add(component);
          const inputs = ownValue(component, "inputs");
          const id = addNode({
            parentID: parentID,
            name: angularName(component, element),
            props: angularProps(component),
            propsObject: inputs && typeof inputs === "object" ? inputs : component,
            state: angularState(component),
          });
          if (!id) return;
          remember(id, element);
          nextParent = id;
          nextDepth = depth + 1;
        }
        const children = element.children || [];
        for (let index = 0; index < children.length; index += 1) {
          walkAngular(children[index], nextParent, nextDepth, seen);
        }
      }
      function readAngular() {
        if (!window.ng || typeof window.ng.getComponent !== "function") return false;
        const roots = angularRoots();
        if (!roots.length) return false;
        const seen = new Set();
        const before = nodes.length;
        for (let index = 0; index < roots.length; index += 1) walkAngular(roots[index], null, 0, seen);
        return nodes.length > before;
      }
      let framework = null;
      if (readReact()) framework = "react";
      else if (readVue()) framework = "vue";
      else if (readAngular()) framework = "angular";
      window.__shaarFrameworkHosts = hosts;
      window.__shaarFrameworkProps = propsObjects;
      let highlightEpoch = window.__shaarFrameworkHighlightEpoch || 0;
      window.__shaarHighlightFrameworkComponent = function (id, epoch) {
        if (typeof epoch === "number" && epoch < highlightEpoch) return false;
        if (typeof epoch === "number") {
          highlightEpoch = epoch;
          window.__shaarFrameworkHighlightEpoch = epoch;
        }
        const existing = document.getElementById("shaar-framework-highlight");
        if (existing && existing.remove) existing.remove();
        if (id == null) return true;
        const element = hosts[String(id)];
        if (!element || typeof element.getBoundingClientRect !== "function") return false;
        const rect = element.getBoundingClientRect();
        const box = document.createElement("div");
        box.id = "shaar-framework-highlight";
        box.setAttribute("data-shaar-highlight", String(id));
        const width = Math.max(rect.width, 1);
        const height = Math.max(rect.height, 1);
        box.style.cssText = "position:fixed;left:" + rect.left + "px;top:" + rect.top
          + "px;width:" + width + "px;height:" + height
          + "px;box-sizing:border-box;border:2px solid #1d4ed8;background:rgba(37,99,235,0.18);pointer-events:none;z-index:2147483646;";
        const parent = document.documentElement || document.body;
        if (!parent || !parent.appendChild) return false;
        parent.appendChild(box);
        return true;
      };
      return { schema: 1, framework: framework, nodes: nodes };
    }
    """#
}
