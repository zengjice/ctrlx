// Observe the same private profile after a clean CEF shutdown and process restart.
// No installation or configuration writes are allowed in this phase.
const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
if (!tab.url.startsWith('http://127.0.0.1:') || !tab.url.endsWith('/env')) throw new Error('Unexpected restored fixture page');
const stored = await chrome.storage.local.get(['ENV_PLUGIN_V3_ENV_LIST', 'ENV_PLUGIN_V3_GLOBAL_PAUSED']);
const profiles = JSON.parse(stored.ENV_PLUGIN_V3_ENV_LIST || '[]');
if (stored.ENV_PLUGIN_V3_GLOBAL_PAUSED !== 'false' || !profiles.some(profile => profile.enabled &&
    profile.headers.some(header => header.name === 'x-ctrlx-extension' && header.value === 'env-active' && header.enabled))) {
  throw new Error('ENV configuration was not preserved across restart');
}
const deadline = Date.now() + 8000;
while (Date.now() < deadline) {
  const response = (await chrome.scripting.executeScript({target: {tabId: tab.id},
    func: async () => await (await fetch('/echo', {cache: 'no-store'})).json()}))[0].result;
  if (response.extensionHeader === 'env-active') return {source: tab.url, restored: response, configurationPreserved: true};
  await new Promise(resolve => setTimeout(resolve, 100));
}
throw new Error('ENV request rule did not resume after restart');
