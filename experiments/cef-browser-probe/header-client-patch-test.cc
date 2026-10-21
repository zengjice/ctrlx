// Small stand-ins let the actual patched continuations run without Chromium.
// The separate syntax-only pass uses CEF's real OnceCallback/BindOnce types.
#include <cassert>
#include <functional>
#include <iostream>
#include <map>
#include <optional>
#include <string>
#include <utility>

#ifdef CTRLX_NATIVE_BIND_CHECK
#include "include/base/cef_bind.h"
#include "include/base/cef_callback.h"
#else
namespace base {
template <typename Signature>
struct OnceCallback;
template <typename... Args>
struct OnceCallback<void(Args...)> {
  std::function<void(Args...)> callback;
  void Run(Args... args) { callback(std::forward<Args>(args)...); }
};
}  // namespace base
#endif

namespace base {
struct DictValue {
  int marker;
};
}  // namespace base
namespace net {
inline constexpr int OK = 0;
using HttpRequestHeaders = std::map<std::string, std::string>;
}  // namespace net
struct GURL {
  std::string value;
  bool is_empty() const { return value.empty(); }
  bool operator==(const GURL&) const = default;
};
// Match TrustedHeaderClient in Chromium 152.0.7977.134 network_context.mojom.
using OnBeforeSendHeadersCallback = base::OnceCallback<void(
    int, const std::optional<net::HttpRequestHeaders>&,
    std::optional<base::DictValue>)>;
using OnHeadersReceivedCallback = base::OnceCallback<void(
    int, const std::optional<std::string>&, const std::optional<GURL>&)>;

class InterceptedRequest {
 public:
#include "declarations.inc"
  struct Request {
    net::HttpRequestHeaders headers;
  } request_;
  struct Receiver {
    bool bound = true;
    int resumes = 0;
    bool is_bound() const { return bound; }
    void Resume() { ++resumes; }
  } proxied_client_receiver_;
  GURL header_client_redirect_url_;
};

#ifdef CTRLX_NATIVE_BIND_CHECK
void AcceptRequest(OnBeforeSendHeadersCallback);
void AcceptResponse(OnHeadersReceivedCallback);
void CheckBindings(InterceptedRequest* request) {
  AcceptRequest(base::BindOnce(
      &InterceptedRequest::ContinueBeforeSendHeaders, base::Unretained(request),
      net::HttpRequestHeaders(), OnBeforeSendHeadersCallback()));
  AcceptResponse(base::BindOnce(
      &InterceptedRequest::ContinueHeadersReceived, base::Unretained(request),
      std::string(), OnHeadersReceivedCallback()));
  AcceptResponse(base::BindOnce(
      &InterceptedRequest::FinishHeadersReceived, base::Unretained(request),
      std::optional<std::string>(), std::optional<GURL>(),
      OnHeadersReceivedCallback()));
}
#else
#include "continuations.inc"

void CheckRequestHeaders() {
  InterceptedRequest request;
  const net::HttpRequestHeaders original{{"content-type", "application/json"}};
  auto modified = original;
  modified["x-maas-env"] = "ark-chat-dev";
  bool delivered = false;
  request.ContinueBeforeSendHeaders(
      original, {[&](int error, const auto& headers, auto events) {
        assert(error == net::OK && headers == modified);
        assert(events && events->marker == 42);
        delivered = true;
      }}, net::OK, modified, base::DictValue{42});
  assert(delivered && request.proxied_client_receiver_.resumes == 1);
  assert(request.request_.headers == original);

  // Rebuilding successive redirects must not promote trusted extension edits
  // to page headers. Each destination can still receive a new extension value.
  for (const auto* value : {"hop-two", "hop-three"}) {
    const auto next_request = request.request_.headers;
    modified = next_request;
    modified["x-maas-env"] = value;
    request.ContinueBeforeSendHeaders(
        next_request, {[&](int, const auto& headers, auto) {
          assert(headers == modified);
        }}, net::OK, modified, std::nullopt);
    assert(request.request_.headers == original);
  }

  // A same-named page header must remain in the restarted CORS-checked request,
  // even if the extension replaces or removes it on the wire.
  auto page_headers = original;
  page_headers["x-maas-env"] = "page-added";
  request.ContinueBeforeSendHeaders(
      page_headers, {[](int, const auto&, auto) {}}, net::OK,
      original, std::nullopt);
  assert(request.request_.headers == page_headers);
  request.ContinueBeforeSendHeaders(
      original, {[](int error, const auto&, auto) { assert(error == -3); }},
      -3, modified, std::nullopt);
  assert(request.request_.headers == page_headers);
  request.ContinueBeforeSendHeaders(
      original, {[](int error, const auto& headers, auto events) {
        assert(error == net::OK && !headers && !events);
      }}, net::OK, std::nullopt, std::nullopt);
  assert(request.request_.headers == original);
}

void CheckResponseHeaders() {
  InterceptedRequest request;
  const GURL extension_url{"https://extension.test/#keep"};
  const GURL cef_url{"https://cef.test/#keep"};
  auto check = [&](std::optional<std::string> extension_headers,
                   std::optional<GURL> extension_redirect,
                   std::optional<std::string> cef_headers,
                   std::optional<GURL> cef_redirect,
                   std::optional<std::string> expected_headers,
                   std::optional<GURL> expected_redirect) {
    bool delivered = false;
    request.FinishHeadersReceived(
        extension_headers, extension_redirect,
        {[&](int error, const auto& headers, const auto& redirect) {
          assert(error == net::OK && headers == expected_headers);
          assert(redirect == expected_redirect);
          delivered = true;
        }}, net::OK, cef_headers, cef_redirect);
    assert(delivered);
    assert(request.header_client_redirect_url_ == expected_redirect.value_or(GURL()));
  };
  check(std::nullopt, std::nullopt, std::nullopt, std::nullopt,
        std::nullopt, std::nullopt);
  check("extension", extension_url, std::nullopt, std::nullopt,
        "extension", extension_url);
  // The existing CEF no-op path passes an empty GURL through optional conversion.
  check("extension", extension_url, std::nullopt, GURL(),
        "extension", extension_url);
  check(std::nullopt, std::nullopt, std::nullopt, GURL(),
        std::nullopt, std::nullopt);
  check("extension", extension_url, "cef", cef_url, "cef", cef_url);
  check("extension", std::nullopt, "cef", std::nullopt, "cef", std::nullopt);
}

int main() {
  CheckRequestHeaders();
  CheckResponseHeaders();
  std::cout << "Request/redirect isolation and optional response checks passed.\n";
}
#endif
