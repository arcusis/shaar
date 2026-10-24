chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "arcusis-fixture-state") return;
  port.onMessage.addListener(async () => {
    const { account } = await chrome.storage.local.get("account");
    port.postMessage({ account: account ?? null, port: true });
  });
});

chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message.target === "offscreen") return false;
  (async () => {
    if (message.action === "set") {
      await chrome.storage.local.set({ account: message.account });
    }
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (message.action === "fill") {
      if (!tab || !tab.url?.startsWith("http://127.0.0.1:")) throw new Error("Fixture origin required");
      const { account } = await chrome.storage.local.get("account");
      await chrome.scripting.executeScript({
        target: { tabId: tab.id }, args: [account],
        func: (value) => {
          if (document.documentElement.dataset.arcusisFixture !== "v1") throw new Error("Not fixture");
          document.querySelector("#username").value = value;
          document.querySelector("#password").value = "disposable-fixture-password";
        },
      });
    }
    let offscreen = null;
    if (message.action === "offscreen") {
      if (!(await chrome.offscreen.hasDocument())) {
        await chrome.offscreen.createDocument({
          url: "offscreen.html", reasons: ["LOCAL_STORAGE"],
          justification: "Verify disposable MV3 extension context isolation",
        });
      }
      offscreen = await chrome.runtime.sendMessage({ target: "offscreen" });
    }
    const { account } = await chrome.storage.local.get("account");
    const tabs = message.action === "order"
      ? (await chrome.tabs.query({ currentWindow: true })).map(({ id, index, pinned, active }) => ({ id, index, pinned, active }))
      : null;
    return { account: account ?? null, tabID: tab?.id ?? null, tabURL: tab?.url ?? null,
      offscreen, tabs, serviceWorker: true };
  })().then(reply, (error) => reply({ error: String(error) }));
  return true;
});
