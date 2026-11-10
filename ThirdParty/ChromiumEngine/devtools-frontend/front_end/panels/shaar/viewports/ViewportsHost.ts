// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export type ViewportOperation = 'open'|'close'|'add'|'remove'|'action'|'frame';

export interface ViewportReply {
  schemaVersion?: number;
  leaseID?: number;
  viewportID?: number;
  url?: string;
  data?: string;
  colorScheme?: number;
  hover?: number;
  typing?: number;
  error?: string;
}

export interface ViewportHost {
  request(operation: ViewportOperation, payload: Record<string, unknown>): Promise<ViewportReply>;
}

const EMBEDDER_METHOD = 'shaarViewports';
const REPLY_TIMEOUT_MS = 4000;

interface DevToolsApi {
  sendMessageToEmbedder(method: string, args: string[], callback: ((result: unknown) => void)|null): void;
}

function devToolsApi(): DevToolsApi|null {
  const host = globalThis as unknown as Record<string, Partial<DevToolsApi>|undefined>;
  const api = host['DevToolsAPI'];
  if (!api || typeof api.sendMessageToEmbedder !== 'function') {
    return null;
  }
  return api as DevToolsApi;
}

function replyFrom(result: unknown): ViewportReply {
  if (typeof result === 'string') {
    const parsed: unknown = JSON.parse(result);
    if (!parsed || typeof parsed !== 'object') {
      throw new Error('unavailable');
    }
    return parsed as ViewportReply;
  }
  if (!result || typeof result !== 'object') {
    throw new Error('unavailable');
  }
  return result as ViewportReply;
}

/**
 * Talks to the browser viewport lease through the DevTools embedder channel.
 * The message is `shaarViewports` with one JSON argument:
 * `{"operation":"open|close|add|remove|action|frame","payload":{...}}`.
 * Payload keys match the existing viewport host operations.
 */
export class EmbedderViewportHost implements ViewportHost {
  request(operation: ViewportOperation, payload: Record<string, unknown>): Promise<ViewportReply> {
    const api = devToolsApi();
    if (!api) {
      return Promise.reject(new Error('unavailable'));
    }
    const body = JSON.stringify({operation, payload});
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('unavailable')), REPLY_TIMEOUT_MS);
      api.sendMessageToEmbedder(EMBEDDER_METHOD, [body], result => {
        clearTimeout(timer);
        try {
          const reply = replyFrom(result);
          if (reply.error) {
            reject(new Error(reply.error));
            return;
          }
          resolve(reply);
        } catch (error) {
          reject(error instanceof Error ? error : new Error('unavailable'));
        }
      });
    });
  }
}
