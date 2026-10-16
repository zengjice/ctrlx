window.addEventListener("message", async (event) => {
  if (event.source !== window || event.data?.kind !== "ctrlx-extension-probe") return;
  try {
    const result = await chrome.runtime.sendMessage({kind: "probe", url: location.href});
    window.postMessage({kind: "ctrlx-extension-result", result}, location.origin);
  } catch (error) {
    window.postMessage({kind: "ctrlx-extension-result", error: String(error)}, location.origin);
  }
});
document.documentElement.dataset.ctrlxExtension = chrome.runtime.id;
