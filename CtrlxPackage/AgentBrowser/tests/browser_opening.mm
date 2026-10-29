#import <Foundation/Foundation.h>
#include "../Ownership.h"
#include <cassert>
#include <functional>
#include <iostream>
#include <memory>
#include <queue>

@interface OpeningHost : NSObject
@property(copy) void (^routeReply)(NSDictionary*, NSString*);
@property(copy) void (^identityReply)(NSDictionary*);
- (void)resolveBrowserProcess:(int)pid completion:(void (^)(NSDictionary*, NSString*))completion;
- (void)resolveBrowserAgentIdentity:(int)pid completion:(void (^)(NSDictionary*))completion;
@end
@implementation OpeningHost
- (void)resolveBrowserProcess:(int)pid completion:(void (^)(NSDictionary*, NSString*))completion { self.routeReply = completion; }
- (void)resolveBrowserAgentIdentity:(int)pid completion:(void (^)(NSDictionary*))completion { self.identityReply = completion; }
@end

@interface OpeningRuntime : NSObject
@property(strong) OpeningHost* delegate;
@property(getter=isReady) BOOL ready;
@end
@implementation OpeningRuntime
@end

static OpeningRuntime* runtime;
struct CefBrowser {};
template<typename T> using CefRefPtr = std::shared_ptr<T>;
constexpr int TID_UI = 0;
struct BrowserUITask {
  std::function<void()> run;
  explicit BrowserUITask(std::function<void()> run) : run(std::move(run)) {}
};
static std::queue<std::unique_ptr<BrowserUITask>> queue;
static bool CefPostTask(int, BrowserUITask* task) { queue.emplace(task); return true; }
static void Drain() {
  while (!queue.empty()) {
    auto task = std::move(queue.front()); queue.pop(); task->run();
  }
}

static BrowserOwnership ownership;
static int created;
// Replace only the platform creation boundary, retaining the production ownership store.
static void CreateRoutedTab(const std::string& owner, const std::string& conversation, NSDictionary*, const std::string&,
    std::function<void(CefRefPtr<CefBrowser>, NSString*)> done) {
  ++created;
  ownership.Add("created", owner, conversation);
  done(std::make_shared<CefBrowser>(), nil);
}
#include "../BrowserOpening.inc"

static void Check(const std::string& scenario) {
  ownership = BrowserOwnership();
  created = 0;
  runtime = [OpeningRuntime new];
  runtime.delegate = [OpeningHost new]; runtime.ready = YES;
  BrowserRun run{"run", std::string(64, 'a'), "fixture", 42, 1, 1};
  assert(ownership.Register(run));
  std::vector<std::string> changed;
  const std::string original = scenario == "unverified" || scenario == "identity-discovered" ? "" : "conversation-a";
  assert(ownership.BindConversation(run.id, original, changed));
  bool active = true, completed = false, succeeded = false;
  OpenTab(run.id, run.pid, "https://example.test", original, [&] {
    return active && ownership.runs.at(run.id).active && ownership.runs.at(run.id).conversation == original;
  }, [&](auto browser, NSString* error) {
    assert(!completed); completed = true; succeeded = browser != nullptr;
    assert(succeeded ? error == nil : error.length > 0);
  });
  assert(!completed && created == 0 && runtime.delegate.routeReply && !runtime.delegate.identityReply);
  if (scenario == "changed-cache") assert(ownership.BindConversation(run.id, "conversation-b", changed));
  if (scenario == "lost-cache") assert(ownership.BindConversation(run.id, "", changed));
  if (scenario == "owner-ended") ownership.Revoke(run.id);
  auto routeReply = runtime.delegate.routeReply; runtime.delegate.routeReply = nil;
  routeReply(@{@"pane": @"%1"}, nil);
  assert(!completed); // The Swift completion must not enter CEF inline.
  Drain();
  if (!completed) {
    assert(runtime.delegate.identityReply && created == 0);
    NSDictionary* verified = original.empty() ? nil : @{@"key": @"conversation-a"};
    if (scenario == "changed-native" || scenario == "identity-discovered") verified = @{@"key": @"conversation-b"};
    if (scenario == "lost-native") verified = nil;
    if (scenario == "expired") active = false;
    auto identityReply = runtime.delegate.identityReply; runtime.delegate.identityReply = nil;
    identityReply(verified);
    assert(!completed);
    if (scenario == "changed-before-create") assert(ownership.BindConversation(run.id, "conversation-b", changed));
    Drain();
  }
  bool expected = scenario == "unchanged" || scenario == "unverified";
  assert(completed && succeeded == expected && created == (expected ? 1 : 0));
  if (expected) assert(ownership.conversations.at("created") == original);
  else assert(ownership.owners.empty());
  runtime = nil;
}

int main() {
  @autoreleasepool {
    for (const char* scenario : {"unchanged", "unverified", "changed-cache", "lost-cache", "changed-native",
         "lost-native", "identity-discovered", "expired", "owner-ended", "changed-before-create"}) Check(scenario);
    std::cout << "browser opening: 10 cases PASS\n";
  }
}
