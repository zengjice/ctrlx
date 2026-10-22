#include "../ExternalApplication.h"
#include <cassert>
#include <memory>

int main() {
  using Clock = ExternalApplicationActivation::Clock;
  const auto now = Clock::now();
  constexpr int parentBrowser = 1, popupBrowser = 2;
  const std::string initialURL = "https://example.com/start", destinationURL = "https://example.com/redirect";
  ExternalApplicationActivation click("page", "viewer", now);
  click.Navigation(parentBrowser, initialURL, false);
  click.Navigation(parentBrowser, destinationURL, true);
  assert(click.Consume(now + std::chrono::seconds(1)));
  assert(!click.Consume(now + std::chrono::seconds(2)));
  ExternalApplicationActivation expired("page", "", now);
  assert(!expired.Consume(now + std::chrono::seconds(5)));
  ExternalApplicationActivation changed("page", "", now);
  changed.Navigation(parentBrowser, initialURL, false);
  changed.Navigation(parentBrowser, initialURL, false);
  assert(!changed.Consume(now));
  ExternalApplicationActivation loaded("page", "", now);
  loaded.Navigation(parentBrowser, initialURL, false);
  loaded.Committed(parentBrowser, "parent-frame", initialURL);
  loaded.Loaded(parentBrowser, "parent-frame");
  assert(!loaded.Consume(now));

  ExternalApplicationActivation priorLoad("page", "", now);
  priorLoad.Committed(parentBrowser, "parent-frame", initialURL);
  priorLoad.Loaded(parentBrowser, "parent-frame");
  assert(priorLoad.Consume(now));

  // The old and new documents can reuse BOTH the browser and frame IDs, and
  // even the same URL. Completion before the new commit must not revoke input.
  for (const auto& url : {initialURL, destinationURL}) {
    ExternalApplicationActivation sameTab("page", "", now);
    sameTab.Navigation(parentBrowser, url, false);
    sameTab.Loaded(parentBrowser, "parent-frame");
    sameTab.Navigation(parentBrowser, destinationURL, true);
    assert(sameTab.Consume(now + std::chrono::seconds(1)));
  }

  ExternalApplicationActivation staleCommit("page", "", now);
  staleCommit.Navigation(parentBrowser, destinationURL, false);
  staleCommit.Committed(parentBrowser, "parent-frame", initialURL);
  staleCommit.Loaded(parentBrowser, "parent-frame");
  assert(staleCommit.Consume(now));

  ExternalApplicationActivation committed("page", "", now);
  committed.Navigation(parentBrowser, initialURL, false);
  committed.Navigation(parentBrowser, destinationURL, true);
  committed.Committed(parentBrowser, "new-frame", destinationURL);
  committed.Loaded(parentBrowser, "old-frame");
  assert(committed.Consume(now));

  ExternalApplicationActivation completed("page", "", now);
  completed.Navigation(parentBrowser, initialURL, false);
  completed.Navigation(parentBrowser, destinationURL, true);
  completed.Committed(parentBrowser, "new-frame", destinationURL);
  completed.Loaded(parentBrowser, "new-frame");
  assert(!completed.Consume(now));

  auto parent = std::make_shared<ExternalApplicationActivation>("page", "", now);
  auto navigatingPopup = parent;
  navigatingPopup->Navigation(popupBrowser, initialURL, false);
  parent->Committed(parentBrowser, "parent-frame", initialURL);
  parent->Loaded(parentBrowser, "parent-frame");
  navigatingPopup->Navigation(popupBrowser, destinationURL, true);
  assert(navigatingPopup->Consume(now + std::chrono::seconds(1)));
  assert(!parent->Consume(now + std::chrono::seconds(1)));

  auto pendingParent = std::make_shared<ExternalApplicationActivation>("page", "", now);
  auto completedPopup = pendingParent;
  completedPopup->Navigation(popupBrowser, initialURL, false);
  completedPopup->Committed(popupBrowser, "popup-frame", initialURL);
  pendingParent->Loaded(parentBrowser, "parent-frame");
  completedPopup->Loaded(popupBrowser, "popup-frame");
  assert(!completedPopup->Consume(now + std::chrono::seconds(1)));

  ExternalApplicationActivation otherNavigation("page", "", now);
  otherNavigation.Navigation(popupBrowser, initialURL, false);
  otherNavigation.Navigation(parentBrowser, initialURL, true);
  assert(!otherNavigation.Consume(now));

  auto source = std::make_shared<ExternalApplicationActivation>("page", "", now);
  auto popup = source;
  popup->Navigation(popupBrowser, initialURL, false);
  source->Cancel();
  assert(!popup->Consume(now));
  @autoreleasepool {
    for (NSString *url in @[@"feishu://open?token=opaque%2Bvalue", @"lark://client/action",
                           @"zoommtg://zoom.us/join", @"mailto:user@example.com", @"tel:+861234"]) assert(ExternalApplicationURL(url));
    for (NSString *url in @[@"", @"https://example.com", @"file:///tmp/a.app", @"javascript:alert(1)",
      @"data:text/html,hello", @"blob:https://example.com/id", @"about:blank", @"chrome://settings",
      @"smb://server/share", @"feishu://user:password@host", @"feishu://host\n"]) assert(!ExternalApplicationURL(url));
    assert(!ExternalApplicationURL([@"feishu:" stringByPaddingToLength:8193 withString:@"a" startingAtIndex:0]));
  }
}
