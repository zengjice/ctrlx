#import <Foundation/Foundation.h>
#include "AutomationBridge.h"
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
  explicit Bridge(std::function<void()> quit) : quit_(std::move(quit)) {}
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
    fprintf(stderr, "[probe] automation-socket=%s\n", path_.c_str());
    Tick();
    return true;
  }

  void Add(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    const std::string token = NSUUID.UUID.UUIDString.UTF8String;
    tabs_.emplace(token, Tab{browser, browser->GetHost()->AddDevToolsMessageObserver(this)});
  }

  void Remove(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    std::vector<int> lost;
    for (const auto& [id, client] : clients_)
      if (client.browser && client.browser->IsSame(browser)) lost.push_back(id);
    for (int id : lost) Reply(id, nil, @"Tab closed; operation was not retried.");
    std::erase_if(tabs_, [&](const auto& entry) { return entry.second.browser->IsSame(browser); });
  }

  void Stop() {
    CEF_REQUIRE_UI_THREAD();
    if (listener_ >= 0) close(listener_);
    listener_ = -1;
    for (auto& [id, client] : clients_) close(client.fd);
    clients_.clear();
    pending_.clear();
    tabs_.clear();
    // Only paths created by this instance; never remove another instance's socket.
    if (!path_.empty()) unlink(path_.c_str());
    if (!directory_.empty()) rmdir(directory_.c_str());
    path_.clear();
    directory_.clear();
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id,
                             bool success, const void* result, size_t size) override {
    CEF_REQUIRE_UI_THREAD();
    auto it = pending_.find({browser->GetIdentifier(), message_id});
    if (it == pending_.end()) return;
    auto pending = std::move(it->second);
    pending_.erase(it);
    if (!clients_.contains(pending.client)) return;
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

 private:
  struct Tab { CefRefPtr<CefBrowser> browser; CefRefPtr<CefRegistration> registration; };
  struct Client {
    int fd;
    Clock::time_point deadline;
    std::string input, output, tab;
    size_t sent = 0;
    bool busy = false;
    bool quit = false;
    CefRefPtr<CefBrowser> browser;
  };
  struct Pending { int client; std::function<void(NSDictionary*)> done; };
  int listener_ = -1, nextClient_ = 0, nextMessage_ = 0;
  std::string path_, directory_;
  std::map<std::string, Tab> tabs_;
  std::map<int, Client> clients_;
  std::map<std::pair<int, int>, Pending> pending_;
  std::function<void()> quit_;

  static bool Configure(int fd) {
    int yes = 1;
    return fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 &&
        fcntl(fd, F_SETFL, O_NONBLOCK) != -1 &&
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) == 0;
  }

  void Tick() {
    CEF_REQUIRE_UI_THREAD();
    if (listener_ < 0) return;
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
      bool quit = clients_.at(id).quit;
      close(clients_.at(id).fd);
      clients_.erase(id);
      std::erase_if(pending_, [id](const auto& pair) { return pair.second.client == id; });
      if (quit) quit_();
    }
    CefRefPtr<Bridge> self = this;
    CefPostDelayedTask(TID_UI, new Action([self] { self->Tick(); }), 10);
  }

  void Reply(int id, ::id result, NSString* error = nil) {
    auto it = clients_.find(id);
    if (it == clients_.end()) return;
    auto& client = it->second;
    client.busy = false;
    client.output = JSON(error ? @{ @"ok": @NO, @"error": error }
                               : @{ @"ok": @YES, @"result": result ?: @{} }) + "\n";
    client.deadline = Clock::now() + std::chrono::seconds(5);
    std::erase_if(pending_, [id](const auto& pair) { return pair.second.client == id; });
  }

  void Call(int id, const char* method, NSDictionary* params,
            std::function<void(NSDictionary*)> done) {
    auto it = clients_.find(id);
    if (it == clients_.end() || !it->second.busy) return;
    auto browser = it->second.browser;
    const int message = ++nextMessage_;
    auto parsed = CefParseJSON(JSON(params), JSON_PARSER_RFC);
    pending_.emplace(std::pair{browser->GetIdentifier(), message}, Pending{id, std::move(done)});
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

  void Handle(int id) {
    auto& client = clients_.at(id);
    ::id request = Parse(client.input.data(), client.input.size());
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"command"] isKindOfClass:NSString.class]) {
      Reply(id, nil, @"Expected one JSON request object per connection."); return;
    }
    NSString* command = request[@"command"];
    if ([command isEqual:@"tabs"]) {
      NSMutableArray* tabs = [NSMutableArray array];
      for (const auto& [token, tab] : tabs_) {
        [tabs addObject:@{ @"id": String(token), @"url": String(tab.browser->GetMainFrame()->GetURL().ToString()),
                           @"loading": @(tab.browser->IsLoading()), @"runtime": @"alloy" }];
      }
      Reply(id, tabs); return;
    }
    if ([command isEqual:@"quit"]) { client.quit = true; Reply(id, @{}); return; }
    if (![@[@"read", @"click", @"type", @"screenshot"] containsObject:command]) {
      Reply(id, nil, @"Unsupported command; arbitrary CDP/evaluation is not exposed."); return;
    }
    NSString* token = request[@"tab"];
    if (![token isKindOfClass:NSString.class] || !tabs_.contains(token.UTF8String)) {
      Reply(id, nil, @"Unknown tab ID; list tabs again. No default-tab fallback."); return;
    }
    for (auto& [otherID, other] : clients_) {
      if (other.busy && other.tab == token.UTF8String) {
        Reply(id, nil, @"Tab busy; do not submit concurrent actions to the same page."); return;
      }
    }
    client.tab = token.UTF8String;
    client.browser = tabs_.at(client.tab).browser;
    NSString* url = String(client.browser->GetMainFrame()->GetURL().ToString());
    if (![url hasPrefix:@"http://"] && ![url hasPrefix:@"https://"]) {
      Reply(id, nil, @"Only HTTP(S) pages are exposed, not browser-internal or file pages."); return;
    }
    if (client.browser->IsLoading()) { Reply(id, nil, @"Page loading; read again after load completes."); return; }
    client.busy = true;
    if ([command isEqual:@"read"]) {
      Evaluate(id, R"JS((()=>{
        const visible=e=>!!(e.getClientRects().length) && getComputedStyle(e).visibility!=='hidden';
        const selector=e=>{
          if(e.id && document.querySelectorAll('#'+CSS.escape(e.id)).length===1) return '#'+CSS.escape(e.id);
          const path=[];
          for(let n=e;n && n.nodeType===1;n=n.parentElement){
            const siblings=n.parentElement?[...n.parentElement.children].filter(s=>s.tagName===n.tagName):[n];
            path.unshift(n.tagName.toLowerCase()+':nth-of-type('+(siblings.indexOf(n)+1)+')');
          }
          return path.join(' > ');
        };
        const text=document.body?.innerText||'';
        return {title:document.title,url:location.href,text:text.slice(0,20000),truncated:text.length>20000,
          controls:[...document.querySelectorAll('input,textarea,button,a,select,[role="button"]')]
            .filter(visible).slice(0,100).map(e=>({selector:selector(e),tag:e.tagName.toLowerCase(),
              type:e.type||'',text:(e.innerText||e.getAttribute('aria-label')||e.placeholder||'').slice(0,200)}))};
      })())JS", [this, id](::id result) { Reply(id, result); });
      return;
    }
    if ([command isEqual:@"screenshot"]) {
      Call(id, "Page.captureScreenshot", @{ @"format": @"png", @"captureBeyondViewport": @NO },
          [this, id](NSDictionary* result) { Reply(id, result); });
      return;
    }
    NSString* selector = request[@"selector"];
    NSString* text = request[@"text"];
    if (![selector isKindOfClass:NSString.class] || selector.length == 0 || selector.length > 4096 ||
        ([command isEqual:@"type"] && (![text isKindOfClass:NSString.class] || text.length > 16000))) {
      Reply(id, nil, @"A selector is required; type also requires bounded text."); return;
    }
    std::string script = "(()=>{const nodes=document.querySelectorAll(" + JSON(selector) +
        ");if(nodes.length!==1)throw Error('unique target required');const e=nodes[0];"
        "if(!e.getClientRects().length||getComputedStyle(e).visibility==='hidden'||e.disabled)throw Error('not interactive');"
        "e.scrollIntoView({block:'center',inline:'center',behavior:'instant'});";
    if ([command isEqual:@"type"]) {
      script += "if(!(e.matches('textarea')||e.matches('input')&&['text','search','email','url','tel'].includes(e.type))||e.readOnly)throw Error('unsupported input');"
                "e.focus();if(document.activeElement!==e)throw Error('focus failed');return true;})()";
      Evaluate(id, script, [this, id, text](::id) {
        Call(id, "Input.insertText", @{ @"text": text }, [this, id](NSDictionary*) { Reply(id, @{}); });
      });
    } else {
      script += "const r=e.getBoundingClientRect(),x=(Math.max(0,r.left)+Math.min(innerWidth,r.right))/2,"
                "y=(Math.max(0,r.top)+Math.min(innerHeight,r.bottom))/2;"
                "if(!e.contains(document.elementFromPoint(x,y)))throw Error('target obscured');return {x,y};})()";
      Evaluate(id, script, [this, id](::id point) {
        if (![point isKindOfClass:NSDictionary.class] || ![point[@"x"] isKindOfClass:NSNumber.class] ||
            ![point[@"y"] isKindOfClass:NSNumber.class]) { Reply(id, nil, @"Invalid click location."); return; }
        NSDictionary* press = @{ @"type": @"mousePressed", @"x": point[@"x"], @"y": point[@"y"],
                                 @"button": @"left", @"clickCount": @1 };
        Call(id, "Input.dispatchMouseEvent", press, [this, id, press](NSDictionary*) {
          NSMutableDictionary* release = [press mutableCopy];
          release[@"type"] = @"mouseReleased";
          Call(id, "Input.dispatchMouseEvent", release, [this, id](NSDictionary*) { Reply(id, @{}); });
        });
      });
    }
  }
  IMPLEMENT_REFCOUNTING(Bridge);
};
CefRefPtr<Bridge> bridge;
}

bool StartProbeAutomation(std::function<void()> quit) {
  bridge = new Bridge(std::move(quit));
  return bridge->Start();
}
void AddProbeAutomationTab(CefRefPtr<CefBrowser> browser) { if (bridge) bridge->Add(browser); }
void RemoveProbeAutomationTab(CefRefPtr<CefBrowser> browser) { if (bridge) bridge->Remove(browser); }
void StopProbeAutomation() { if (bridge) bridge->Stop(); bridge = nullptr; }
