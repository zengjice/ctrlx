// Runs only in ENV-Plugin's real popup inside the disposable probe profile.
// Configure through its UI; never write extension storage or modify its scripts.
const inputEvents = [];
for (const kind of ['input', 'change', 'focusin', 'focusout']) document.addEventListener(kind, event => {
  if (event.target.matches('input')) inputEvents.push({kind, name: event.target.name, value: event.target.value, trusted: event.isTrusted});
}, true);
const waitFor = async (probe, label) => {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    const value = await probe();
    if (value) return value;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const storage = await chrome.storage.local.get(['ENV_PLUGIN_V3_ENV_LIST', 'ENV_PLUGIN_V3_GLOBAL_PAUSED']);
  const rules = await chrome.declarativeNetRequest.getSessionRules();
  throw new Error(`Timed out: ${label}; storage=${JSON.stringify(storage)}; rules=${JSON.stringify(rules)}; inputs=${JSON.stringify(inputEvents)}`);
};
const buttonFor = selector => {
  const icons = document.querySelectorAll(selector);
  if (icons.length !== 1 || !icons[0].closest('button')) throw new Error(`Ambiguous control: ${selector}`);
  return icons[0].closest('button');
};
const clickStableButton = async selector => {
  const button = await waitFor(async () => {
    const icons = document.querySelectorAll(selector);
    const candidate = icons.length === 1 ? icons[0].closest('button') : null;
    if (!candidate || candidate.disabled) return null;
    await new Promise(resolve => setTimeout(resolve, 100));
    return candidate.isConnected && !candidate.disabled && candidate === document.querySelector(selector)?.closest('button') ? candidate : null;
  }, `stable button ${selector}`);
  button.click();
};
const fill = async (name, value) => {
  // Adding a row persists and re-renders the form asynchronously. Wait for its
  // visible input to retain focus before sending the single real input event.
  const input = await waitFor(async () => {
    const candidate = document.querySelector(`input[name="${name}"]`);
    if (!candidate?.getBoundingClientRect().width) return null;
    candidate.focus();
    await new Promise(resolve => setTimeout(resolve, 100));
    return candidate.isConnected && document.activeElement === candidate ? candidate : null;
  }, `stable visible field ${name}`);
  input.select();
  await new Promise(resolve => {
    globalThis.ctrlxProbeInputDone = resolve;
    ctrlxProbeInsertText(value);
  });
  if (input.value !== value) throw new Error(`Input did not reach ${name}: ${input.value}; active=${document.activeElement?.name}`);
  await new Promise(resolve => requestAnimationFrame(resolve));
  input.blur();
  await new Promise(resolve => requestAnimationFrame(resolve));
  await waitFor(async () => {
    const stored = await chrome.storage.local.get('ENV_PLUGIN_V3_ENV_LIST');
    const profiles = JSON.parse(stored.ENV_PLUGIN_V3_ENV_LIST || '[]');
    return profiles.some(profile => name.split('.').reduce((item, key) => item?.[key], profile) === value);
  }, `saved field ${name}`);
};
const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
if (!tab.url.startsWith('http://127.0.0.1:') || !tab.url.endsWith('/env')) throw new Error('Unexpected fixture page');
const echo = async () => (await chrome.scripting.executeScript({target: {tabId: tab.id},
  func: async () => await (await fetch('/echo', {cache: 'no-store'})).json()}))[0].result;
const expectHeader = value => waitFor(async () => {
  const response = await echo();
  return response.extensionHeader === value ? response : null;
}, `request header ${value}`);

const before = await expectHeader(null);
const headerName = globalThis.ctrlxProbeHeaderName || 'x-ctrlx-extension';
const headerValue = globalThis.ctrlxProbeHeaderValue || 'env-active';
buttonFor('.rdsvc-icon-manual-creation-color').click();
await waitFor(() => document.querySelector('input[name="name"]'), 'new environment');
buttonFor('.arco-icon-plus').click();
const menu = await waitFor(() => [...document.querySelectorAll('[role="menuitem"]')]
  .find(item => item.innerText === 'Request headers'), 'request header menu');
menu.click();
await waitFor(() => document.querySelector('input[name="headers.0.name"]'), 'request header fields');
await fill('headers.0.name', headerName);
await fill('headers.0.value', headerValue);
const active = await expectHeader(headerValue);
await clickStableButton('.arco-icon-pause');
const paused = await expectHeader(null);
await waitFor(async () => (await chrome.storage.local.get('ENV_PLUGIN_V3_GLOBAL_PAUSED')).ENV_PLUGIN_V3_GLOBAL_PAUSED === 'true', 'saved pause');
await clickStableButton('.arco-icon-play-arrow');
const resumed = await expectHeader(headerValue);
return {source: tab.url, before, active, paused, resumed, configuredThroughPopup: true};
