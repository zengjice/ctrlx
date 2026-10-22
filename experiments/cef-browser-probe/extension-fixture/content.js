window.addEventListener("message", async (event) => {
  if (event.source !== window || event.data?.kind !== "ctrlx-extension-probe") return;
  try {
    let result;
    let lastError;
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      try {
        result = await chrome.runtime.sendMessage({kind: "probe", url: location.href});
        break;
      } catch (error) {
        lastError = error;
        if (!String(error).includes("Receiving end does not exist")) throw error;
        await new Promise(resolve => setTimeout(resolve, 100));
      }
    }
    if (!result) throw lastError;
    window.postMessage({kind: "ctrlx-extension-result", result}, location.origin);
  } catch (error) {
    window.postMessage({kind: "ctrlx-extension-result", error: String(error)}, location.origin);
  }
});
document.documentElement.dataset.ctrlxExtension = chrome.runtime.id;
