window.probeState = null;
window.probeReply = null;
window.probeCommand = async (message) => {
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
