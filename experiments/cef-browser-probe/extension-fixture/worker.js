async function tabQueries() {
  const tab = ({id, windowId, url, active}) => ({id, windowId, url, active});
  return {
    all: (await chrome.tabs.query({})).map(tab),
    activeCurrentWindow: (await chrome.tabs.query({active: true, currentWindow: true})).map(tab),
    activeLastFocusedWindow: (await chrome.tabs.query({active: true, lastFocusedWindow: true})).map(tab)
  };
}

async function probe(message, sender) {
  if (message.kind === "popup") {
    const {lastSource} = await chrome.storage.local.get("lastSource");
    const result = {kind: "popup", source: lastSource, queries: message.queries};
    await fetch(new URL("/popup-report", lastSource), {
      method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(result)
    });
    return result;
  }
  if (message.kind !== "probe" || !sender.tab || !message.url.startsWith("http://127.0.0.1:")) {
    throw new Error("Expected a message from the isolated local fixture page");
  }
  await chrome.storage.local.set({lastSource: message.url});
  await chrome.declarativeNetRequest.updateSessionRules({removeRuleIds: [1, 2], addRules: [{
    id: 1,
    priority: 1,
    action: {type: "modifyHeaders", requestHeaders: [{header: "x-ctrlx-extension", operation: "set", value: "active"}]},
    condition: {urlFilter: "127.0.0.1", resourceTypes: ["xmlhttprequest"]}
  }, {
    id: 2,
    priority: 1,
    action: {type: "modifyHeaders",
      requestHeaders: [{header: "x-maas-env", operation: "set", value: "ark-chat-dev"}],
      responseHeaders: [{header: "x-ctrlx-response", operation: "set", value: "response-active"}]},
    condition: {urlFilter: "/cors/", resourceTypes: ["xmlhttprequest", "script"]}
  }]});
  const result = {id: chrome.runtime.id, source: message.url, sender: sender.tab, queries: await tabQueries()};
  try { result.senderLookup = await chrome.tabs.get(sender.tab.id); }
  catch (error) { result.senderLookupError = String(error); }
  try {
    await chrome.action.openPopup();
    result.openPopup = "opened";
  } catch (error) { result.openPopupError = String(error); }
  return result;
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  probe(message, sender).then(respond, error => respond({error: String(error)}));
  return true;
});
