function showAccount(value) {
  document.documentElement.dataset.extensionAccount = value ?? "none";
}
chrome.storage.local.get("account").then(({ account }) => showAccount(account));
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.account) showAccount(changes.account.newValue);
});
