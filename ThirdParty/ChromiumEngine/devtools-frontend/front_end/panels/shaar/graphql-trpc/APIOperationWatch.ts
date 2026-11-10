// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as Common from '../../../core/common/common.js';
import * as SDK from '../../../core/sdk/sdk.js';
import * as TextUtils from '../../../core/text_utils/text_utils.js';

import {keepAfterNavigation, parseAPIOperation, type APIOperation} from './APIOperations.js';

export const Events = {
  Changed: 'Changed',
} as const;

export interface EventTypes {
  [Events.Changed]: void;
}

export class APIOperationWatch extends Common.ObjectWrapper.ObjectWrapper<EventTypes> implements
    SDK.TargetManager.SDKModelObserver<SDK.NetworkManager.NetworkManager> {
  static #instance: APIOperationWatch|null = null;
  readonly #rows = new Map<SDK.NetworkRequest.NetworkRequest, APIOperation>();
  readonly #generation = new Map<SDK.NetworkRequest.NetworkRequest, number>();
  readonly #owners = new WeakMap<SDK.NetworkRequest.NetworkRequest, SDK.NetworkManager.NetworkManager>();
  readonly #listeners = new Map<SDK.NetworkManager.NetworkManager, Common.EventTarget.EventDescriptor[]>();
  #installed = false;

  static instance(): APIOperationWatch {
    if (!APIOperationWatch.#instance) {
      APIOperationWatch.#instance = new APIOperationWatch();
    }
    return APIOperationWatch.#instance;
  }

  operations(): ReadonlyMap<SDK.NetworkRequest.NetworkRequest, APIOperation> {
    return this.#rows;
  }

  install(): void {
    if (this.#installed) {
      return;
    }
    this.#installed = true;
    SDK.TargetManager.TargetManager.instance().observeModels(SDK.NetworkManager.NetworkManager, this, {scoped: true});
  }

  modelAdded(manager: SDK.NetworkManager.NetworkManager): void {
    const listeners: Common.EventTarget.EventDescriptor[] = [
      manager.addEventListener(SDK.NetworkManager.Events.RequestStarted, this.#onStarted),
      manager.addEventListener(SDK.NetworkManager.Events.RequestUpdated, this.#onRequest),
      manager.addEventListener(SDK.NetworkManager.Events.RequestFinished, this.#onRequest),
    ];
    const resourceTree = manager.target().model(SDK.ResourceTreeModel.ResourceTreeModel);
    if (resourceTree) {
      listeners.push(resourceTree.addEventListener(
          SDK.ResourceTreeModel.Events.PrimaryPageChanged, this.#onPrimaryPageChanged));
    }
    this.#listeners.set(manager, listeners);
  }

  modelRemoved(manager: SDK.NetworkManager.NetworkManager): void {
    Common.EventTarget.removeEventListeners(this.#listeners.get(manager) || []);
    this.#listeners.delete(manager);
    let changed = false;
    for (const request of [...this.#rows.keys()]) {
      if (this.#owners.get(request) === manager) {
        this.#drop(request);
        changed = true;
      }
    }
    if (changed) {
      this.#emit();
    }
  }

  #onStarted = (event: Common.EventTarget.EventTargetEvent<SDK.NetworkManager.RequestStartedEvent>): void => {
    this.#remember(event.data.request, event.source);
    void this.#refresh(event.data.request);
  };

  #onRequest = (event: Common.EventTarget.EventTargetEvent<SDK.NetworkRequest.NetworkRequest>): void => {
    this.#remember(event.data, event.source);
    void this.#refresh(event.data);
  };

  #onPrimaryPageChanged = (
      event: Common.EventTarget.EventTargetEvent<
          {frame: SDK.ResourceTreeModel.ResourceTreeFrame, type: SDK.ResourceTreeModel.PrimaryPageChangeType}>):
      void => {
        const frame = event.data.frame;
        if (frame.url !== frame.unreachableUrl() && Common.ParsedURL.schemeIs(frame.url, 'chrome-error:')) {
          return;
        }
        const manager = frame.resourceTreeModel().target().model(SDK.NetworkManager.NetworkManager);
        const preserve = SDK.TargetManager.TargetManager.instance()
                             .settings.resolve(SDK.SDKSettings.preserveNetworkLogSettingDescriptor)
                             .get();
        let changed = false;
        for (const request of [...this.#rows.keys()]) {
          if (manager && this.#owners.get(request) !== manager) {
            continue;
          }
          if (!keepAfterNavigation(request.loaderId, frame.loaderId, preserve)) {
            this.#drop(request);
            changed = true;
          }
        }
        if (changed) {
          this.#emit();
        }
      };

  #remember(request: SDK.NetworkRequest.NetworkRequest, source: Object|undefined): void {
    const owner = SDK.NetworkManager.NetworkManager.forRequest(request) ??
        (source instanceof SDK.NetworkManager.NetworkManager ? source : null);
    if (owner) {
      this.#owners.set(request, owner);
    }
  }

  #drop(request: SDK.NetworkRequest.NetworkRequest): void {
    this.#generation.set(request, (this.#generation.get(request) ?? 0) + 1);
    this.#rows.delete(request);
  }

  async #refresh(request: SDK.NetworkRequest.NetworkRequest): Promise<void> {
    if (request.isPreflightRequest()) {
      const removed = this.#rows.delete(request);
      if (removed) {
        this.#emit();
      }
      return;
    }
    const generation = (this.#generation.get(request) ?? 0) + 1;
    this.#generation.set(request, generation);
    let operation: APIOperation|null = null;
    try {
      operation = await operationFromRequest(request);
    } catch {
      operation = null;
    }
    if (this.#generation.get(request) !== generation) {
      return;
    }
    if (!operation) {
      const removed = this.#rows.delete(request);
      if (removed) {
        this.#emit();
      }
      return;
    }
    this.#rows.set(request, operation);
    this.#emit();
  }

  #emit(): void {
    this.dispatchEventToListeners(Events.Changed);
  }
}

export function installAPIOperationWatch(): APIOperationWatch {
  const watch = APIOperationWatch.instance();
  watch.install();
  return watch;
}

async function operationFromRequest(request: SDK.NetworkRequest.NetworkRequest): Promise<APIOperation|null> {
  const body = await postText(request);
  const named = parseAPIOperation(request.requestMethod, request.url(), body, null);
  if (!named || !request.finished) {
    return named;
  }
  // The response is only needed to see JSON errors, and only for a call we already named.
  return parseAPIOperation(request.requestMethod, request.url(), body, await responseText(request));
}

async function postText(request: SDK.NetworkRequest.NetworkRequest): Promise<string|null> {
  try {
    return await request.requestFormData();
  } catch {
    return null;
  }
}

async function responseText(request: SDK.NetworkRequest.NetworkRequest): Promise<string|null> {
  if (!request.finished) {
    return null;
  }
  try {
    const content = await request.requestContentData();
    if (TextUtils.ContentData.ContentData.isError(content) || !content.isTextContent) {
      return null;
    }
    return content.text;
  } catch {
    return null;
  }
}
