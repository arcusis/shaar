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
    if (message.action === "storage-worker") {
      await chrome.storage.local.set({ [message.key]: message.value });
    }
    if (message.action === "library-read" || message.action === "library-write") {
      const url = new URL(message.url);
      if (url.protocol !== "http:" || url.hostname !== "127.0.0.1" || !url.pathname.startsWith("/library-")) {
        throw new Error("Library fixture origin required");
      }
      if (message.action === "library-write") {
        const [existing] = await chrome.bookmarks.search({ url: url.href });
        if (existing) await chrome.bookmarks.update(existing.id, { title: message.title });
        else await chrome.bookmarks.create({ title: message.title, url: url.href });
      }
      const bookmarks = await chrome.bookmarks.search({ url: url.href });
      const history = await chrome.history.search({ text: url.href, startTime: 0, maxResults: 1000 });
      const { account } = await chrome.storage.local.get("account");
      return { account, serviceWorker: true,
        bookmarks: bookmarks.map(({ title, url }) => ({ title, url })),
        history: history.map(({ title, url, visitCount }) => ({ title, url, visitCount })) };
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
