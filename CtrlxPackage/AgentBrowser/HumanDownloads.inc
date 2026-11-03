// Included by EmbeddedBrowser.mm. All state lives on CEF's native UI thread.
struct HumanDownload {
  int browserID;
  NSString *source;
  NSString *id;
  CefRefPtr<CefDownloadItemCallback> cancel;
};
static std::map<uint32_t, HumanDownload> humanDownloads;

static bool BeginHumanDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
    const CefString& suggestedName, CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  auto found = downloadActivations.find(browser->GetIdentifier());
  if (found == downloadActivations.end() || !found->second->Consume()) return false;
  auto activation = found->second;
  NSString *sourceID = @(activation->source.c_str());
  auto source = AgentBrowserTarget(sourceID);
  if (!runtime.isReady || !source || !source->IsValid() ||
      AgentBrowserHumanControlToken(source) != activation->control ||
      ![runtime.delegate respondsToSelector:@selector(browserTab:prepareDownload:filename:controlToken:completion:)]) return true;
  const uint32_t itemID = item->GetId();
  NSString *downloadID = NSUUID.UUID.UUIDString;
  humanDownloads.emplace(itemID, HumanDownload{browser->GetIdentifier(), sourceID, downloadID, nullptr});
  [runtime.delegate browserTab:sourceID prepareDownload:downloadID
      filename:@(suggestedName.ToString().c_str())
      controlToken:activation->control.empty() ? nil : @(activation->control.c_str())
      completion:^(NSString *path) {
        CEF_REQUIRE_UI_THREAD();
        auto active = humanDownloads.find(itemID);
        if (active == humanDownloads.end()) return;
        if (!path.length || !runtime.isReady) { humanDownloads.erase(active); return; }
        callback->Continue(path.UTF8String, false);
      }];
  return true;
}

static bool UpdateHumanDownload(CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  auto found = humanDownloads.find(item->GetId());
  if (found == humanDownloads.end()) return false;
  found->second.cancel = callback;
  const auto download = found->second;
  NSString *state = item->IsComplete() ? @"completed" : item->IsCanceled() ? @"cancelled" :
      item->IsInterrupted() ? @"failed" : @"downloading";
  if (![state isEqual:@"downloading"]) humanDownloads.erase(found);
  if ([state isEqual:@"failed"]) callback->Cancel();
  [runtime.delegate browserTab:download.source downloadChanged:download.id state:state
      received:item->GetReceivedBytes() total:item->GetTotalBytes()];
  return true;
}

static void CloseHumanDownloads(int browserID, NSString *source) {
  CEF_REQUIRE_UI_THREAD();
  for (auto it = humanDownloads.begin(); it != humanDownloads.end();) {
    if (it->second.browserID != browserID && ![it->second.source isEqual:source]) { ++it; continue; }
    auto download = it->second;
    it = humanDownloads.erase(it);
    if (download.cancel) download.cancel->Cancel();
    [runtime.delegate browserTab:download.source downloadChanged:download.id state:@"cancelled" received:0 total:0];
  }
}
