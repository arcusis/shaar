chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message.target !== "offscreen") return false;
  reply({ document: true, origin: location.origin });
  return false;
});
