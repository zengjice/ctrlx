#import <Foundation/Foundation.h>
#include "AgentBrowser.h"
#include "Ownership.h"
#include "PageActions.h"
#include "PageKeys.h"
#include "EngineServer.h"
#include <libproc.h>
#include <sys/proc.h>
#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"

namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t kMaxRequest = 65536;
constexpr size_t kMaxResponse = 8 * 1024 * 1024;
int engineServers = 0; // CEF UI RunLoop only, including shutdown completion.

std::string JSON(id value) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:value
      options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? std::string(static_cast<const char*>(data.bytes), data.length) : "null";
}
id Parse(const void* bytes, size_t size) {
  return [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:size]
      options:NSJSONReadingFragmentsAllowed error:nil];
}
NSString* String(const std::string& value) { return @(value.c_str()); }

class Action final : public CefTask {
 public:
  explicit Action(std::function<void()> run) : run_(std::move(run)) {}
  void Execute() override { @autoreleasepool { run_(); } }
 private:
  std::function<void()> run_;
  IMPLEMENT_REFCOUNTING(Action);
};

class Bridge final : public CefDevToolsMessageObserver {
 public:
  explicit Bridge(NSString* state, BrowserCallbacks callbacks) : state_(state), callbacks_(std::move(callbacks)) {}
  bool Start() {
    CEF_REQUIRE_UI_THREAD();
    char directory[] = "/tmp/ctrlx-browser-XXXXXX";
    if (!mkdtemp(directory)) return false;
    directory_ = directory;
    path_ = directory_ + "/control.sock";
    listener_ = socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path_.c_str(), sizeof(address.sun_path));
    address.sun_len = sizeof(address);
    if (listener_ < 0 || !Configure(listener_) ||
        bind(listener_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) ||
        chmod(path_.c_str(), 0600) || listen(listener_, 8)) {
      Stop();
      return false;
    }

    NSString* endpoint = [state_ stringByAppendingPathComponent:@"endpoint.json"];
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"socket": String(path_), @"epoch": epoch_, @"mode": @"embedded"}
        options:0 error:nil];
    if (![data writeToFile:endpoint options:NSDataWritingAtomic error:nil] ||
        chmod(endpoint.fileSystemRepresentation, 0600)) { Stop(); return false; }
    fprintf(stderr, "[agent-browser] ready\n");
    StartEngineServer();
    Tick();
    return true;
  }

  void Add(CefRefPtr<CefBrowser> browser, const std::string& owner) {
    CEF_REQUIRE_UI_THREAD();
    const std::string token = NSUUID.UUID.UUIDString.UTF8String;
    tabs_.emplace(token, Tab{0, browser, browser->GetHost()->AddDevToolsMessageObserver(this)});
    ownership_.owners[token] = owner;
    callbacks_.changed();
  }

  void Remove(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    std::vector<int> lost;
    for (const auto& [id, client] : clients_)
      if (client.browser && client.browser->IsSame(browser)) lost.push_back(id);
    for (int id : lost) Reply(id, nil, @"Tab closed; operation was not retried.");
    std::erase_if(tabs_, [&](const auto& entry) {
      if (!entry.second.browser->IsSame(browser)) return false;
      ownership_.owners.erase(entry.first);
      return true;
    });
    callbacks_.changed();
  }

  void Stop() {
    CEF_REQUIRE_UI_THREAD();
    for (const auto& [connection, token] : engineConnections_) EngineDetach(token);
    if (listener_ >= 0) close(listener_);
    listener_ = -1;
    if (engineServer_) engineServer_->Shutdown();
    engineServer_ = nullptr;
    engineConnections_.clear();
    engineGrants_.clear();
    enginePending_.clear();
    engineDownloads_.clear();
    engineDownloadPaths_.clear();
    engineDialogs_.clear();
    for (auto& [id, client] : clients_) close(client.fd);
    clients_.clear();
    pending_.clear();
    tabs_.clear();
    NSString* endpoint = [state_ stringByAppendingPathComponent:@"endpoint.json"];
    NSDictionary* saved = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:endpoint] ?: NSData.data options:0 error:nil];
    if ([saved[@"epoch"] isEqual:epoch_]) unlink(endpoint.fileSystemRepresentation);
    // Only paths created by this instance; never remove another instance's socket.
    if (!path_.empty()) unlink(path_.c_str());
    if (!directory_.empty()) rmdir(directory_.c_str());
    path_.clear();
    directory_.clear();
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id,
                             bool success, const void* result, size_t size) override {
    CEF_REQUIRE_UI_THREAD();
    if (EngineResult(browser, message_id, success, result, size)) return;
    auto it = pending_.find({browser->GetIdentifier(), message_id});
    if (it == pending_.end()) return;
    auto pending = std::move(it->second);
    pending_.erase(it);
    if (!clients_.contains(pending.client)) return;
    if (!Authorized(pending.client)) return;
    // A read-only wait may span navigation. Never accept an old document's
    // result as evidence that the new document satisfies the condition.
    auto& client = clients_.at(pending.client);
    if (client.waiting && Clock::now() >= client.waitUntil) {
      Reply(pending.client, nil, @"Wait condition timed out; no action was performed.");
      return;
    }
    if (client.waiting && pending.generation != client.generation) {
      ScheduleWait(pending.client);
      return;
    }
    if (!success || size > kMaxResponse) {
      Reply(pending.client, nil, @"CDP operation failed or response too large; not retried.");
      return;
    }
    id value = size ? Parse(result, size) : @{};
    if (![value isKindOfClass:NSDictionary.class]) {
      Reply(pending.client, nil, @"Invalid CDP result.");
      return;
    }
    pending.done(value);
  }

  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override {
    std::vector<int> lost;
    for (auto& [id, client] : clients_)
      if (client.busy && client.browser && client.browser->IsSame(browser)) lost.push_back(id);
    for (int id : lost) Reply(id, nil, @"Page renderer detached; read the page again.");
  }

  static bool Alive(const BrowserRun& run) {
    proc_bsdinfo info{};
    return proc_pidinfo(run.pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
        info.pbi_uid == getuid() && info.pbi_status != SZOMB &&
        info.pbi_start_tvsec == run.startSeconds && info.pbi_start_tvusec == run.startMicros;
  }
  static bool ValidURL(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 8192) return false;
    NSURLComponents* url = [NSURLComponents componentsWithString:value];
    return url && [@[@"http", @"https"] containsObject:url.scheme.lowercaseString] &&
        url.host.length && !url.user && !url.password;
  }
  void Reap() {
    ReapEngine();
    bool changed = false;
    for (auto& [id, run] : ownership_.runs) {
      if (run.active && !Alive(run)) { ownership_.Revoke(id); changed = true; }
    }
    if (changed) {
      std::vector<int> cancelled;
      for (auto& [id, client] : clients_)
        if (client.busy && ((!client.opening && !ownership_.Owns(client.run, client.tab)) ||
            !ownership_.runs.at(client.run).active)) cancelled.push_back(id);
      for (int id : cancelled) Reply(id, nil, @"Codex instance ended; control revoked.");
      callbacks_.changed();
    }
  }
  bool Authorized(int id) {
    auto it = clients_.find(id);
    if (it == clients_.end() || !it->second.busy) return false;
    auto& client = it->second;
    auto tab = tabs_.find(client.tab);
    if (!ownership_.Owns(client.run, client.tab) || !Alive(ownership_.runs.at(client.run)) ||
        tab == tabs_.end() || tab->second.generation != client.generation) {
      Reply(id, nil, @"Tab navigated, closed or changed owner; action cancelled, not retried.");
      return false;
    }
    return true;
  }
#include "EngineBridge.inc"
 public:
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method, const void* data, size_t size) override {
    EngineEvent(browser, method, data, size);
#if defined(CTRLX_UPSTREAM_BROWSER_PROBE)
    ProbeDevToolsEvent(browser, method, data, size);
#endif
  }
#if defined(CTRLX_UPSTREAM_BROWSER_PROBE)
  // Isolated compatibility fixture only; never enabled by product builds.
#include "tests/UpstreamProbe.inc"
#endif
 public:
  NSArray* Groups() {
    NSMutableArray* result = [NSMutableArray array];
    for (auto& [id, run] : ownership_.runs)
      [result addObject:@{@"id": String(id), @"label": String(run.label), @"active": @(run.active)}];
    return result;
  }
  NSArray* Tabs() {
    NSMutableArray* result = [NSMutableArray array];
    for (auto& [id, tab] : tabs_) {
      NSMutableDictionary *entry = [@{@"id": String(id), @"owner": String(ownership_.owners.at(id)),
          @"title": String(tab.browser->GetMainFrame()->GetURL().ToString()),
          @"url": String(tab.browser->GetMainFrame()->GetURL().ToString()),
          @"loading": @(tab.browser->IsLoading())} mutableCopy];
      if (callbacks_.presentation) entry[@"presentation"] = callbacks_.presentation(tab.browser);
      [result addObject:entry];
    }
    return result;
  }
  CefRefPtr<CefBrowser> Target(NSString* id) {
    auto it = tabs_.find(id.UTF8String ?: "");
    return it == tabs_.end() ? nullptr : it->second.browser;
  }
  bool Busy(CefRefPtr<CefBrowser> browser) {
    for (const auto& [key, pending] : enginePending_)
      if (key.first == browser->GetIdentifier()) return true;
    for (auto& [id, client] : clients_)
      if (client.busy && client.browser && client.browser->IsSame(browser)) return true;
    return false;
  }
  bool Assign(NSString* tab, NSString* run) {
    Reap();
    auto browser = Target(tab);
    if (!browser || !ownership_.Assign(tab.UTF8String, run.UTF8String, Busy(browser))) return false;
    callbacks_.changed();
    return true;
  }
  std::string Owner(CefRefPtr<CefBrowser> browser) {
    for (const auto& [id, tab] : tabs_)
      if (tab.browser->IsSame(browser)) return ownership_.owners.at(id);
    return "";
  }
  void Navigation(CefRefPtr<CefBrowser> browser) {
    for (auto& [id, tab] : tabs_)
      if (tab.browser->IsSame(browser)) ++tab.generation;
    std::vector<int> cancelled;
    for (auto& [id, client] : clients_) {
      if (!client.busy || !client.browser || !client.browser->IsSame(browser)) continue;
      if (client.waiting) client.generation = tabs_.at(client.tab).generation;
      else cancelled.push_back(id);
    }
    for (int id : cancelled) Reply(id, nil, @"Navigation invalidated the page action; inspect again. Not retried.");
  }
 private:
  struct Tab {
    uint64_t generation = 0;
    CefRefPtr<CefBrowser> browser;
    CefRefPtr<CefRegistration> registration;
  };
  struct Client {
    int fd;
    Clock::time_point deadline;
    std::string input, output, tab, run;
    uint64_t generation = 0;
    size_t sent = 0;
    bool busy = false;
    bool opening = false;
    CefRefPtr<CefBrowser> browser;
    bool waiting = false;
    Clock::time_point waitUntil;
    std::string waitScript;
  };
  struct Pending { int client; uint64_t generation; std::function<void(NSDictionary*)> done; };
  int listener_ = -1, nextClient_ = 0, nextMessage_ = 0;
  std::string path_, directory_;
  std::map<std::string, Tab> tabs_;
  std::map<int, Client> clients_;
  std::map<std::pair<int, int>, Pending> pending_;
  NSString* state_;
  NSString* epoch_ = NSUUID.UUID.UUIDString;
  BrowserCallbacks callbacks_;
  BrowserOwnership ownership_;
  Clock::time_point nextReap_ = Clock::now();

  static bool Configure(int fd) {
    int yes = 1;
    return fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 &&
        fcntl(fd, F_SETFL, O_NONBLOCK) != -1 &&
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) == 0;
  }

  void Tick() {
    CEF_REQUIRE_UI_THREAD();
    if (listener_ < 0) return;
    if (Clock::now() >= nextReap_) {
      Reap();
      nextReap_ = Clock::now() + std::chrono::seconds(1);
    }
    // Nonblocking and bounded per tick: no socket wait on Chromium's UI thread.
    if (clients_.size() < 8) {
      int fd = accept(listener_, nullptr, nullptr);
      if (fd >= 0) {
        uid_t uid; gid_t gid;
        if (getpeereid(fd, &uid, &gid) || uid != getuid() || !Configure(fd)) close(fd);
        else clients_.emplace(++nextClient_, Client{fd, Clock::now() + std::chrono::seconds(10)});
      }
    }
    std::vector<int> closed;
    for (auto& [id, client] : clients_) {
      // Enforce the caller's wait deadline even if the renderer never replies.
      if (client.busy && client.waiting && Clock::now() >= client.waitUntil)
        Reply(id, nil, @"Wait condition timed out; no action was performed.");
      if (Clock::now() > client.deadline) {
        if (client.output.empty()) Reply(id, nil, @"Operation timed out; outcome unknown, not retried.");
        else { closed.push_back(id); continue; }
      }
      if (!client.busy && client.output.empty()) {
        char bytes[8192];
        ssize_t count = recv(client.fd, bytes, sizeof(bytes), 0);
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
          closed.push_back(id); continue;
        }
        if (count > 0) {
          client.input.append(bytes, count);
          if (client.input.size() > kMaxRequest) Reply(id, nil, @"Request too large.");
          else if (client.input.find('\n') != std::string::npos) Handle(id);
        }
      }
      if (!client.output.empty()) {
        ssize_t count = send(client.fd, client.output.data() + client.sent,
            std::min<size_t>(65536, client.output.size() - client.sent), 0);
        if (count > 0) client.sent += count;
        if (client.sent == client.output.size() ||
            (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
          closed.push_back(id);
      }
    }
    for (int id : closed) {
      close(clients_.at(id).fd);
      clients_.erase(id);
      std::erase_if(pending_, [id](const auto& pair) { return pair.second.client == id; });
    }
    CefRefPtr<Bridge> self = this;
    CefPostDelayedTask(TID_UI, new Action([self] { self->Tick(); }), 10);
  }

  void Reply(int id, ::id result, NSString* error = nil) {
    auto it = clients_.find(id);
    if (it == clients_.end()) return;
    auto& client = it->second;
    client.busy = false;
    client.waiting = false;
    client.output = JSON(error ? @{ @"ok": @NO, @"error": error }
                               : @{ @"ok": @YES, @"result": result ?: @{} }) + "\n";
    client.deadline = Clock::now() + std::chrono::seconds(5);
    std::erase_if(pending_, [id](const auto& pair) { return pair.second.client == id; });
  }

  void Call(int id, const char* method, NSDictionary* params,
            std::function<void(NSDictionary*)> done) {
    auto it = clients_.find(id);
    if (it == clients_.end() || !it->second.busy) return;
    if (!Authorized(id)) return;
    auto browser = it->second.browser;
    const int message = ++nextMessage_;
    auto parsed = CefParseJSON(JSON(params), JSON_PARSER_RFC);
    pending_.emplace(std::pair{browser->GetIdentifier(), message}, Pending{id, it->second.generation, std::move(done)});
    if (!browser->GetHost()->ExecuteDevToolsMethod(message, method, parsed->GetDictionary()))
      Reply(id, nil, @"CDP request could not be submitted.");
  }

  void Evaluate(int id, const std::string& expression, std::function<void(::id)> done) {
    Call(id, "Runtime.evaluate", @{ @"expression": String(expression), @"returnByValue": @YES,
        @"timeout": @3000 }, [this, id, done](NSDictionary* response) {
      NSDictionary* remote = response[@"result"];
      if (response[@"exceptionDetails"] || ![remote isKindOfClass:NSDictionary.class] || !remote[@"value"])
        Reply(id, nil, @"Page evaluation failed (missing, ambiguous, hidden or unsupported element).");
      else done(remote[@"value"]);
    });
  }

  void ScheduleWait(int id) {
    CefRefPtr<Bridge> self = this;
    CefPostDelayedTask(TID_UI, new Action([self, id] { self->PollWait(id); }), 100);
  }

  void PollWait(int id) {
    if (!Authorized(id)) return;
    auto& client = clients_.at(id);
    if (Clock::now() >= client.waitUntil) {
      Reply(id, nil, @"Wait condition timed out; no action was performed."); return;
    }
    if (client.browser->IsLoading()) { ScheduleWait(id); return; }
    if (!ValidURL(String(client.browser->GetMainFrame()->GetURL().ToString()))) {
      Reply(id, nil, @"Wait reached an unsupported page; only HTTP(S) is exposed."); return;
    }
    Evaluate(id, client.waitScript, [this, id](::id result) {
      if ([result isKindOfClass:NSDictionary.class] && [result[@"matched"] boolValue]) Reply(id, result);
      else ScheduleWait(id);
    });
  }

  void Press(int id, NSDictionary* down, std::function<void()> done) {
    Call(id, "Input.dispatchKeyEvent", down, [this, id, down, done](NSDictionary*) {
      NSMutableDictionary* up = [down mutableCopy];
      up[@"type"] = @"keyUp";
      [up removeObjectForKey:@"text"];
      [up removeObjectForKey:@"commands"];
      Call(id, "Input.dispatchKeyEvent", up, [done](NSDictionary*) { done(); });
    });
  }

  bool Integer(NSMutableDictionary* params, NSString* key, int fallback, int minimum, int maximum) {
    ::id value = params[key];
    if (!value) { params[key] = @(fallback); return true; }
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [value doubleValue] >= minimum && [value doubleValue] <= maximum && [value doubleValue] == [value intValue];
  }

  void Handle(int id) {
    auto& client = clients_.at(id);
    ::id request = Parse(client.input.data(), client.input.size());
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"command"] isKindOfClass:NSString.class]) {
      Reply(id, nil, @"Expected one JSON request object per connection."); return;
    }
    NSString* command = request[@"command"];
    if ([command isEqual:@"register"]) {
      NSString* runID = request[@"run"], *secret = request[@"secret"], *label = request[@"label"];
      if (![runID isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:runID] ||
          ![secret isKindOfClass:NSString.class] || secret.length != 64 ||
          ![label isKindOfClass:NSString.class] || label.length > 200 ||
          ![request[@"pid"] isKindOfClass:NSNumber.class] ||
          ![request[@"startSeconds"] isKindOfClass:NSNumber.class] ||
          ![request[@"startMicros"] isKindOfClass:NSNumber.class]) {
        Reply(id, nil, @"Invalid instance registration."); return;
      }
      BrowserRun run{runID.UTF8String, secret.UTF8String, label.UTF8String,
          [request[@"pid"] intValue], [request[@"startSeconds"] unsignedLongLongValue],
          [request[@"startMicros"] unsignedLongLongValue]};
      if (!Alive(run) || !ownership_.Register(run)) {
        Reply(id, nil, @"Instance expired or registration conflicts. Launch a new Codex instance."); return;
      }
      callbacks_.changed();
      Reply(id, @{@"epoch": epoch_}); return;
    }
    Reap();
    NSString* run = request[@"run"], *secret = request[@"secret"];
    if (![request[@"epoch"] isEqual:epoch_] ||
        ![run isKindOfClass:NSString.class] || ![secret isKindOfClass:NSString.class] ||
        !ownership_.Authenticate(run.UTF8String, secret.UTF8String)) {
      Reply(id, nil, @"Instance not authorized or browser restarted. Launch a new Codex instance."); return;
    }
    client.run = run.UTF8String;
    if (AttachEngine(id, request)) return;
#if defined(CTRLX_UPSTREAM_BROWSER_PROBE)
    if (HandleUpstreamProbe(id, request)) return;
#endif
    if ([command isEqual:@"tabs"]) {
      NSMutableArray* tabs = [NSMutableArray array];
      for (NSDictionary* tab in Tabs())
        if (ownership_.Owns(client.run, [tab[@"id"] UTF8String])) [tabs addObject:tab];
      Reply(id, tabs); return;
    }
    if ([command isEqual:@"open"]) {
      NSString* url = request[@"url"];
      if (!ValidURL(url)) { Reply(id, nil, @"Only HTTP(S) URLs without embedded credentials are allowed."); return; }
      if (tabs_.size() >= 64) { Reply(id, nil, @"Close unused tabs first (64-tab limit)."); return; }
      // Routing queries tmux asynchronously. Never block the UI/CEF thread on
      // process I/O, and never substitute the currently focused terminal.
      client.busy = true;
      client.opening = true;
      callbacks_.open(client.run, ownership_.runs.at(client.run).pid, url.UTF8String,
          [self = CefRefPtr<Bridge>(this), id] {
        auto it = self->clients_.find(id);
        return self->listener_ >= 0 && it != self->clients_.end() && it->second.busy &&
            it->second.output.empty() && Clock::now() < it->second.deadline &&
            self->ownership_.runs.at(it->second.run).active && Alive(self->ownership_.runs.at(it->second.run));
      },
          [self = CefRefPtr<Bridge>(this), id](auto browser, NSString* error) {
        if (!self->clients_.contains(id) || !self->clients_.at(id).output.empty()) return;
        for (const auto& [token, tab] : self->tabs_) {
          if (browser && tab.browser->IsSame(browser)) {
            self->Reply(id, @{@"id": String(token)}); return;
          }
        }
        self->Reply(id, nil, error ?: @"Could not create an embedded browser tab.");
      });
      return;
    }
    if (![@[@"read", @"click", @"type", @"fill", @"press", @"scroll", @"wait", @"select", @"check",
           @"screenshot", @"navigate", @"close", @"show"] containsObject:command]) {
      Reply(id, nil, @"Unsupported command; arbitrary CDP/evaluation and cross-group control are not exposed."); return;
    }
    NSString* token = request[@"tab"];
    if (![token isKindOfClass:NSString.class] || !tabs_.contains(token.UTF8String)) {
      Reply(id, nil, @"Unknown tab ID; list tabs again. No default-tab fallback."); return;
    }
    if (!ownership_.Owns(client.run, token.UTF8String)) {
      Reply(id, nil, @"Tab belongs to another instance or is manual. Assign it explicitly in the browser UI."); return;
    }
    for (auto& [otherID, other] : clients_) {
      if (other.busy && other.tab == token.UTF8String) {
        Reply(id, nil, @"Tab busy; do not submit concurrent actions to the same page."); return;
      }
    }
    client.tab = token.UTF8String;
    client.browser = tabs_.at(client.tab).browser;
    client.generation = tabs_.at(client.tab).generation;
    if ([command isEqual:@"navigate"]) {
      NSString* destination = request[@"url"];
      if (!ValidURL(destination)) { Reply(id, nil, @"Invalid HTTP(S) URL."); return; }
      client.browser->GetMainFrame()->LoadURL(destination.UTF8String);
      Reply(id, @{}); return;
    }
    if ([command isEqual:@"close"]) {
      client.browser->GetHost()->CloseBrowser(false); Reply(id, @{}); return;
    }
    if ([command isEqual:@"show"]) {
      callbacks_.select(client.browser); Reply(id, @{}); return;
    }
    const bool waiting = [command isEqual:@"wait"];
    NSString* url = String(client.browser->GetMainFrame()->GetURL().ToString());
    if (!waiting && !ValidURL(url)) {
      Reply(id, nil, @"Only HTTP(S) pages are exposed, not browser-internal or file pages."); return;
    }
    if (!waiting && client.browser->IsLoading()) { Reply(id, nil, @"Page loading; use wait before reading or acting."); return; }
    // Runtime credentials are strictly native-only. Never serialize the wire
    // envelope into a page's JavaScript context, even for a fixed operation.
    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    for (NSString* key in @[@"selector", @"text", @"key", @"deltaX", @"deltaY", @"state", @"timeoutMs",
                            @"value", @"checked", @"textOffset", @"textLimit", @"controlOffset", @"controlLimit"])
      if (request[key]) params[key] = request[key];
    NSString* selector = params[@"selector"];
    NSString* text = params[@"text"];
    if ((selector && (![selector isKindOfClass:NSString.class] || selector.length == 0 || selector.length > 4096)) ||
        (text && (![text isKindOfClass:NSString.class] || text.length > 16000))) {
      Reply(id, nil, @"Invalid selector or text (limits: 4096 and 16000 characters)."); return;
    }
    if ([@[@"click", @"type", @"fill", @"select", @"check"] containsObject:command] && !selector) {
      Reply(id, nil, @"This operation requires a unique selector."); return;
    }
    client.busy = true;
    if ([command isEqual:@"read"]) {
      if (!Integer(params, @"textOffset", 0, 0, 10000000) || !Integer(params, @"textLimit", 20000, 1, 20000) ||
          !Integer(params, @"controlOffset", 0, 0, 1000000) || !Integer(params, @"controlLimit", 100, 1, 100)) {
        Reply(id, nil, @"Invalid read pagination (text limit 1...20000, control limit 1...100)."); return;
      }
      Evaluate(id, PageAction("read", JSON(params)), [this, id](::id result) { Reply(id, result); });
      return;
    }
    if (waiting) {
      NSString* state = params[@"state"] ?: (selector ? @"visible" : @"ready");
      if (![@[@"ready", @"attached", @"visible", @"hidden", @"enabled"] containsObject:state] ||
          ([state isEqual:@"ready"] ? (selector || text) : !selector) ||
          ([state isEqual:@"hidden"] && text) || !Integer(params, @"timeoutMs", 5000, 100, 10000)) {
        Reply(id, nil, @"wait needs ready (no selector/text), or attached/visible/hidden/enabled with selector; timeout 100...10000 ms."); return;
      }
      params[@"state"] = state;
      client.waiting = true;
      client.waitUntil = Clock::now() + std::chrono::milliseconds([params[@"timeoutMs"] intValue]);
      client.deadline = client.waitUntil + std::chrono::seconds(2);
      client.waitScript = PageAction("wait", JSON(params));
      PollWait(id); // Probe immediately; polling delay must not consume a short timeout.
      return;
    }
    if ([command isEqual:@"screenshot"]) {
      Call(id, "Page.captureScreenshot", @{ @"format": @"png", @"captureBeyondViewport": @NO },
          [this, id](NSDictionary* result) { Reply(id, result); });
      return;
    }
    // DOM focus alone does not make a hidden native CEF tab an input target.
    // Reveal/focus this already-authorized tab before real CDP input; never
    // route input to whichever tab the human happened to leave selected.
    callbacks_.select(client.browser);
    client.browser->GetHost()->SetFocus(true);
    if ([command isEqual:@"press"]) {
      NSDictionary* down = PageKeyDown(params[@"key"]);
      if (!down) { Reply(id, nil, @"Unsupported page key. Use Enter/Tab/Escape/Space/arrows/Home/End/PageUp/PageDown/Backspace/Delete with modifiers, or Meta+A/Control+A."); return; }
      Evaluate(id, PageAction("press", JSON(params)), [this, id, down](::id) {
        Press(id, down, [this, id] { Reply(id, @{}); });
      });
      return;
    }
    if ([command isEqual:@"scroll"]) {
      if (!Integer(params, @"deltaX", 0, -10000, 10000) || !Integer(params, @"deltaY", 0, -10000, 10000) ||
          (![params[@"deltaX"] intValue] && ![params[@"deltaY"] intValue])) {
        Reply(id, nil, @"scroll needs nonzero deltaX/deltaY in -10000...10000 CSS pixels."); return;
      }
      Evaluate(id, PageAction("scroll", JSON(params)), [this, id](::id result) { Reply(id, result); });
      return;
    }
    if ([command isEqual:@"type"] || [command isEqual:@"fill"]) {
      if (!text) { Reply(id, nil, @"type/fill requires text (empty text clears with fill)."); return; }
      Evaluate(id, PageAction(command.UTF8String, JSON(params)), [this, id, text, command](::id) {
        if ([command isEqual:@"fill"] && text.length == 0) {
          Press(id, PageKeyDown(@"Backspace"), [this, id] { Reply(id, @{}); });
        } else {
          Call(id, "Input.insertText", @{ @"text": text }, [this, id](NSDictionary*) { Reply(id, @{}); });
        }
      });
      return;
    }
    if ([command isEqual:@"select"]) {
      if (![params[@"value"] isKindOfClass:NSString.class] || [params[@"value"] length] > 2000) {
        Reply(id, nil, @"select requires an exact option value (max 2000 characters)."); return;
      }
      Evaluate(id, PageAction("select", JSON(params)), [this, id](::id result) { Reply(id, result); });
      return;
    }
    if ([command isEqual:@"check"] &&
        (!params[@"checked"] || CFGetTypeID((__bridge CFTypeRef)params[@"checked"]) != CFBooleanGetTypeID())) {
      Reply(id, nil, @"check requires checked: true or false."); return;
    }
    Evaluate(id, PageAction(command.UTF8String, JSON(params)), [this, id, command, params](::id point) {
        if ([command isEqual:@"check"] && [point isKindOfClass:NSDictionary.class] && point[@"changed"]) {
          Reply(id, point); return;
        }
        if (![point isKindOfClass:NSDictionary.class] || ![point[@"x"] isKindOfClass:NSNumber.class] ||
            ![point[@"y"] isKindOfClass:NSNumber.class]) { Reply(id, nil, @"Invalid click location."); return; }
        NSDictionary* press = @{ @"type": @"mousePressed", @"x": point[@"x"], @"y": point[@"y"],
                                 @"button": @"left", @"clickCount": @1 };
        Call(id, "Input.dispatchMouseEvent", press, [this, id, press, command, params](NSDictionary*) {
          NSMutableDictionary* release = [press mutableCopy];
          release[@"type"] = @"mouseReleased";
          Call(id, "Input.dispatchMouseEvent", release, [this, id, command, params](NSDictionary*) {
            if ([command isEqual:@"check"]) {
              Evaluate(id, PageAction("verifyCheck", JSON(params)), [this, id](::id result) { Reply(id, result); });
            } else Reply(id, @{});
          });
        });
      });
  }
  IMPLEMENT_REFCOUNTING(Bridge);
};
CefRefPtr<Bridge> bridge;
}

bool StartAgentBrowser(NSString* state, BrowserCallbacks callbacks) {
  bridge = new Bridge(state, std::move(callbacks));
  return bridge->Start();
}
void AddAgentBrowserTab(CefRefPtr<CefBrowser> browser, const std::string& owner) { if (bridge) bridge->Add(browser, owner); }
void RemoveAgentBrowserTab(CefRefPtr<CefBrowser> browser) { if (bridge) bridge->Remove(browser); }
void AgentBrowserNavigation(CefRefPtr<CefBrowser> browser) { if (bridge) bridge->Navigation(browser); }
std::string AgentBrowserOwner(CefRefPtr<CefBrowser> browser) { return bridge ? bridge->Owner(browser) : ""; }
NSArray* AgentBrowserGroups() { return bridge ? bridge->Groups() : @[]; }
NSArray* AgentBrowserTabs() { return bridge ? bridge->Tabs() : @[]; }
CefRefPtr<CefBrowser> AgentBrowserTarget(NSString* tab) { return bridge ? bridge->Target(tab) : nullptr; }
bool AssignAgentBrowserTab(NSString* tab, NSString* run) { return bridge && bridge->Assign(tab, run); }
bool AgentBrowserTabBusy(CefRefPtr<CefBrowser> browser) { return bridge && bridge->Busy(browser); }
bool AgentBrowserDownloadBegin(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefBeforeDownloadCallback> callback) {
  return bridge ? bridge->DownloadBegin(browser, item, callback) : true;
}
void AgentBrowserDownloadUpdate(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> callback) {
  if (bridge) bridge->DownloadUpdate(browser, item, callback);
}
bool AgentBrowserDialog(CefRefPtr<CefBrowser> browser, cef_jsdialog_type_t type, const CefString& message,
    const CefString& defaultText, CefRefPtr<CefJSDialogCallback> callback) {
  return bridge && bridge->DialogBegin(browser, type, message, defaultText, callback);
}
void AgentBrowserDialogReset(CefRefPtr<CefBrowser> browser) { if (bridge) bridge->DialogReset(browser); }
void StopAgentBrowser() { if (bridge) bridge->Stop(); bridge = nullptr; }
bool AgentBrowserTransportsStopped() { return engineServers == 0; }
