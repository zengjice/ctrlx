#pragma once
#include "include/cef_server.h"
#include "include/cef_task.h"
#include <functional>
#include <string>

// CEF owns framing/network I/O. All authorization and browser work is posted
// back to its UI RunLoop; never touch browser state on the server thread.
class EngineTask final : public CefTask {
 public:
  explicit EngineTask(std::function<void()> f) : f_(std::move(f)) {}
  void Execute() override { @autoreleasepool { f_(); } }
 private:
  std::function<void()> f_;
  IMPLEMENT_REFCOUNTING(EngineTask);
};
class EngineServer final : public CefServerHandler {
 public:
  std::function<void(CefRefPtr<CefServer>, bool)> created;
  std::function<void()> destroyed;
  std::function<void(int, std::string, bool, CefRefPtr<CefCallback>)> connect;
  std::function<void(int)> disconnected;
  std::function<void(int, std::string)> message;
  void OnServerCreated(CefRefPtr<CefServer> server) override {
    bool running = server->IsRunning();
    CefPostTask(TID_UI, new EngineTask([self=CefRefPtr<EngineServer>(this), server, running] { self->created(server, running); }));
  }
  void OnServerDestroyed(CefRefPtr<CefServer>) override {
    CefPostTask(TID_UI, new EngineTask([self=CefRefPtr<EngineServer>(this)] { self->destroyed(); }));
  }
  void OnClientConnected(CefRefPtr<CefServer>, int) override {}
  void OnClientDisconnected(CefRefPtr<CefServer>, int id) override {
    CefPostTask(TID_UI, new EngineTask([self=CefRefPtr<EngineServer>(this), id] { self->disconnected(id); }));
  }
  void OnHttpRequest(CefRefPtr<CefServer> server, int id, const CefString&, CefRefPtr<CefRequest>) override {
    server->SendHttp404Response(id); // No discovery, health, targets or dashboard.
  }
  void OnWebSocketRequest(CefRefPtr<CefServer>, int id, const CefString& address,
                         CefRefPtr<CefRequest> request, CefRefPtr<CefCallback> callback) override {
    bool safe = address.ToString().starts_with("127.0.0.1:");
    CefRequest::HeaderMap headers; request->GetHeaderMap(headers);
    for (const auto& [key, value] : headers)
      if ([@(key.ToString().c_str()) caseInsensitiveCompare:@"Origin"] == NSOrderedSame) safe = false;
    auto url = request->GetURL().ToString();
    CefPostTask(TID_UI, new EngineTask([self=CefRefPtr<EngineServer>(this), id, url, safe, callback] {
      self->connect(id, url, safe, callback);
    }));
  }
  void OnWebSocketConnected(CefRefPtr<CefServer>, int) override {}
  void OnWebSocketMessage(CefRefPtr<CefServer> server, int id, const void* data, size_t size) override {
    // The pinned upstream accessibility audit injects vendored axe-core.
    // Public commands remain 48 KiB; only authenticated CDP needs this bound.
    if (size > 2 * 1024 * 1024) { server->CloseConnection(id); return; }
    std::string body(static_cast<const char*>(data), size);
    CefPostTask(TID_UI, new EngineTask([self=CefRefPtr<EngineServer>(this), id, body=std::move(body)] {
      self->message(id, body);
    }));
  }
 private:
  IMPLEMENT_REFCOUNTING(EngineServer);
};
