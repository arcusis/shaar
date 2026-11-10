// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export interface DocumentCandidate {
  url: string;
  isDocument: boolean;
  loaderId: string|null;
  isRedirect: boolean;
}

export interface SettleRequest {
  id: string;
  settles: boolean;
}

// pushState and hash changes rewrite the frame URL and leave the document
// resource stored under the URL it was loaded from.
export function pickDocumentResource<T extends DocumentCandidate>(
    frameURL: string, frameLoaderId: string|null, resources: T[]): T|null {
  const documents = resources.filter(resource => resource.isDocument && !resource.isRedirect);
  const exact = documents.find(resource => resource.url === frameURL);
  if (exact) {
    return exact;
  }
  const hash = frameURL.indexOf('#');
  if (hash >= 0) {
    const withoutHash = frameURL.slice(0, hash);
    const hashed = documents.find(resource => resource.url === withoutHash);
    if (hashed) {
      return hashed;
    }
  }
  if (frameLoaderId === null) {
    return null;
  }
  const sameLoader = documents.filter(resource => resource.loaderId === frameLoaderId);
  if (sameLoader.length === 0) {
    return null;
  }
  return sameLoader[sameLoader.length - 1];
}

export function attachLoadWait(
    listen: (listener: () => void) => void, unlisten: (listener: () => void) => void,
    timeoutMs: number): Promise<boolean> {
  return new Promise(resolve => {
    let settled = false;
    let timer = 0;
    const finish = (loaded: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      unlisten(onLoad);
      resolve(loaded);
    };
    const onLoad = (): void => {
      finish(true);
    };
    timer = setTimeout(() => {
      finish(false);
    }, timeoutMs);
    listen(onLoad);
  });
}

export class RequestSettleTracker {
  #inflight = 0;
  #listeners = new Set<() => void>();
  #seen = new Set<string>();

  inflight(): number {
    return this.#inflight;
  }

  start(request: SettleRequest): void {
    if (!request.settles || this.#seen.has(request.id)) {
      return;
    }
    this.#seen.add(request.id);
    this.#inflight++;
    this.#notify();
  }

  finish(request: SettleRequest): void {
    if (!request.settles || !this.#seen.has(request.id)) {
      return;
    }
    this.#seen.delete(request.id);
    this.#inflight--;
    this.#notify();
  }

  subscribe(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }

  #notify(): void {
    for (const listener of this.#listeners) {
      listener();
    }
  }
}

export function waitForQuiet(
    inflight: () => number, subscribe: (listener: () => void) => () => void, quietMs: number,
    capMs: number): Promise<void> {
  return new Promise(resolve => {
    let finished = false;
    let quietTimer = 0;
    const started = Date.now();
    const unsubscribe = subscribe(arm);
    const capTimer = setTimeout(finish, capMs);

    function finish(): void {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(quietTimer);
      clearTimeout(capTimer);
      unsubscribe();
      resolve();
    }

    function arm(): void {
      if (finished) {
        return;
      }
      clearTimeout(quietTimer);
      if (inflight() > 0) {
        return;
      }
      const remaining = capMs - (Date.now() - started);
      if (remaining <= 0) {
        finish();
        return;
      }
      quietTimer = setTimeout(finish, Math.min(quietMs, remaining));
    }

    arm();
  });
}

// Runs in the page. A root argument keeps unit tests off the DevTools document.
export function pageDomSettle(quietMs: number, capMs: number, root?: Node): Promise<void> {
  const target = root ?? document;
  return new Promise(resolve => {
    let finished = false;
    let timer = 0;
    const started = performance.now();
    const observer = new MutationObserver(arm);
    let resources: PerformanceObserver|null = null;

    function finish(): void {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timer);
      observer.disconnect();
      resources?.disconnect();
      resolve();
    }

    function arm(): void {
      if (finished) {
        return;
      }
      clearTimeout(timer);
      const remaining = capMs - (performance.now() - started);
      if (remaining <= 0) {
        finish();
        return;
      }
      timer = setTimeout(finish, Math.min(quietMs, remaining));
    }

    observer.observe(target, {subtree: true, childList: true, attributes: true, characterData: true});
    if (!root) {
      try {
        resources = new PerformanceObserver(arm);
        resources.observe({type: 'resource', buffered: false});
      } catch {
        resources = null;
      }
    }
    arm();
  });
}
