#pragma once
#import <Foundation/Foundation.h>
#include <functional>
#include "include/cef_browser.h"

struct BrowserCallbacks {
  std::function<void(const std::string&, int, const std::string&, std::function<bool()>, std::function<void(CefRefPtr<CefBrowser>, NSString*)>)> open;
  std::function<void(CefRefPtr<CefBrowser>)> select;
  std::function<void()> changed;
  std::function<NSDictionary*(CefRefPtr<CefBrowser>)> presentation;
};
bool StartAgentBrowser(NSString* stateDirectory, BrowserCallbacks callbacks);
void StopAgentBrowser();
void AddAgentBrowserTab(CefRefPtr<CefBrowser> browser, const std::string& owner);
void RemoveAgentBrowserTab(CefRefPtr<CefBrowser> browser);
void AgentBrowserNavigation(CefRefPtr<CefBrowser> browser);
std::string AgentBrowserOwner(CefRefPtr<CefBrowser> browser);
NSArray* AgentBrowserGroups();
NSArray* AgentBrowserTabs();
CefRefPtr<CefBrowser> AgentBrowserTarget(NSString* tab);
bool AssignAgentBrowserTab(NSString* tab, NSString* run);
bool AgentBrowserTabBusy(CefRefPtr<CefBrowser> browser);
