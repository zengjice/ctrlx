#pragma once
#include <chrono>
#include <optional>
#include <string>

// One human activation can open at most one application, including through a
// popup or HTTP redirect. CDP userGesture alone is also available to Agents.
struct ExternalApplicationActivation {
  using Clock = std::chrono::steady_clock;
  std::string source;
  std::string control;
  Clock::time_point deadline;
  bool consumed = false;
  std::optional<int> navigationBrowser;
  std::string navigationURL;
  std::optional<std::string> committedFrame;

  ExternalApplicationActivation(std::string source, std::string control,
                                Clock::time_point now = Clock::now())
      : source(std::move(source)), control(std::move(control)), deadline(now + std::chrono::seconds(5)) {}
  bool Consume(Clock::time_point now = Clock::now()) {
    if (consumed || now >= deadline) return false;
    consumed = true;
    return true;
  }
  void Cancel() { consumed = true; }
  void Navigation(int browser, const std::string& url, bool redirect) {
    if (navigationBrowser && (!redirect || navigationBrowser != browser)) Cancel();
    navigationBrowser = browser;
    navigationURL = url;
    committedFrame.reset();
  }
  // OnLoadEnd can finish the previous document after OnBeforeBrowse, including
  // when reloading the same URL. Only the requested navigation's commit arms it.
  void Committed(int browser, const std::string& frame, const std::string& url) {
    if (navigationBrowser == browser && navigationURL == url) committedFrame = frame;
  }
  void Loaded(int browser, const std::string& frame) {
    if (navigationBrowser == browser && committedFrame == frame) Cancel();
  }
};

#ifdef __OBJC__
#import <Foundation/Foundation.h>
static bool ExternalApplicationURL(NSString *raw) {
  if (!raw.length || [raw lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 8192 ||
      [raw rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return false;
  NSURLComponents *parts = [NSURLComponents componentsWithString:raw];
  NSString *scheme = parts.scheme.lowercaseString;
  if (!scheme.length || !parts.URL || parts.user || parts.password) return false;
  // These belong to the browser or filesystem, never to the app-launch path.
  return ![@[@"http", @"https", @"about", @"chrome", @"chrome-extension", @"chrome-devtools",
    @"devtools", @"javascript", @"data", @"blob", @"file", @"filesystem", @"view-source",
    @"ftp", @"smb", @"afp", @"nfs"] containsObject:scheme];
}
#endif
