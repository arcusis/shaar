function showAccount(value) {
  document.documentElement.dataset.extensionAccount = value ?? "none";
}
chrome.storage.local.get("account").then(({ account }) => showAccount(account));
function showActivation(value) {
  if (value && typeof value.token === "string" && Number.isInteger(value.windowID)
    && Number.isInteger(value.tabID)) {
    document.documentElement.dataset.arcusisActivation = JSON.stringify(value);
  }
}
chrome.storage.local.get("activationProbe").then(({ activationProbe }) => showActivation(activationProbe));
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.account) showAccount(changes.account.newValue);
  if (area === "local" && changes.activationProbe) showActivation(changes.activationProbe.newValue);
});
