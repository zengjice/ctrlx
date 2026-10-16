(async () => {
  const tab = ({id, windowId, url, active}) => ({id, windowId, url, active});
  const queries = {
    all: (await chrome.tabs.query({})).map(tab),
    activeCurrentWindow: (await chrome.tabs.query({active: true, currentWindow: true})).map(tab),
    activeLastFocusedWindow: (await chrome.tabs.query({active: true, lastFocusedWindow: true})).map(tab)
  };
  const result = await chrome.runtime.sendMessage({kind: "popup", queries});
  document.querySelector("#result").textContent = JSON.stringify(result, null, 2);
})().catch(error => { document.querySelector("#result").textContent = String(error); });
