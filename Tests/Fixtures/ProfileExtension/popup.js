window.probeState = null;
window.probeReply = null;
window.probeCommand = async (message) => {
  if (message.action === "storage-events") return storageRoundtrip();
  if (message.action === "port") {
    return new Promise((resolve, reject) => {
      const port = chrome.runtime.connect({ name: "arcusis-fixture-state" });
      const timer = setTimeout(() => { port.disconnect(); reject(new Error("Port response timed out")); }, 3000);
      port.onMessage.addListener((reply) => { clearTimeout(timer); port.disconnect(); resolve(reply); });
      port.postMessage({ get: true });
    });
  }
  const state = await chrome.runtime.sendMessage(message);
  window.probeState = state;
  document.querySelector("#account").textContent = `Extension account: ${state.account ?? "none"}`;
  return state;
};
window.probeCommand({ action: "get" }).catch((error) => {
  window.probeState = { error: String(error) };
});

// Exercise the callback + area-local event APIs used by reactive extension state.
// Separate keys keep this check independent of the fixture's account data.
async function storageRoundtrip() {
  const prefix = `arcusis-event-${crypto.randomUUID()}`;
  const ownKey = `${prefix}-popup`;
  const workerKey = `${prefix}-worker`;
  const ownValue = { __json__: true, value: JSON.stringify({ source: "popup" }) };
  const workerValue = { __json__: true, value: JSON.stringify({ source: "worker" }) };
  const result = { areaEvents: {}, globalEvents: {}, callbacks: [], read: null, trace: [] };
  let onArea;
  let onGlobal;
  let timer;
  try {
    return await new Promise((resolve, reject) => {
      const finish = () => {
        if (result.callbacks.includes("set") && result.callbacks.includes("get")
          && result.callbacks.includes("worker")
          && result.areaEvents[ownKey] && result.areaEvents[workerKey]
          && result.globalEvents[ownKey] && result.globalEvents[workerKey]) {
          resolve({
            callbackSet: true, callbackGet: result.read?.[ownKey],
            workerCallback: true, ownValue, workerValue,
            areaOwn: result.areaEvents[ownKey], areaWorker: result.areaEvents[workerKey],
            globalOwn: result.globalEvents[ownKey], globalWorker: result.globalEvents[workerKey],
            trace: result.trace,
          });
        }
      };
      const changed = (target, changes) => {
        for (const key of [ownKey, workerKey]) {
          if (Object.hasOwn(changes, key)) target[key] = changes[key];
        }
        finish();
      };
      onArea = (changes) => {
        result.trace.push("area-event");
        changed(result.areaEvents, changes);
      };
      onGlobal = (changes, area) => {
        if (area === "local") {
          result.trace.push("global-event");
          changed(result.globalEvents, changes);
        }
      };
      chrome.storage.local.onChanged.addListener(onArea);
      chrome.storage.onChanged.addListener(onGlobal);
      timer = setTimeout(() => reject(new Error(`Storage events timed out: ${JSON.stringify(result)}`)), 3000);
      chrome.storage.local.set({ [ownKey]: ownValue }, () => {
        if (chrome.runtime.lastError) { reject(new Error(chrome.runtime.lastError.message)); return; }
        result.callbacks.push("set");
        result.trace.push("set-callback");
        chrome.storage.local.get(ownKey, (value) => {
          if (chrome.runtime.lastError) { reject(new Error(chrome.runtime.lastError.message)); return; }
          result.read = value;
          result.callbacks.push("get");
          result.trace.push("get-callback");
          chrome.runtime.sendMessage({ action: "storage-worker", key: workerKey, value: workerValue }, (reply) => {
            if (chrome.runtime.lastError || reply?.error) {
              reject(new Error(chrome.runtime.lastError?.message ?? reply.error)); return;
            }
            result.callbacks.push("worker");
            result.trace.push("worker-callback");
            finish();
          });
          finish();
        });
        finish();
      });
    });
  } finally {
    clearTimeout(timer);
    if (onArea) chrome.storage.local.onChanged.removeListener(onArea);
    if (onGlobal) chrome.storage.onChanged.removeListener(onGlobal);
    await chrome.storage.local.remove([ownKey, workerKey]);
  }
}
