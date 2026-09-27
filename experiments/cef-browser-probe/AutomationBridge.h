#pragma once

#include <functional>
#include "include/cef_browser.h"

// Explicit opt-in, experimental local automation. No TCP/CDP debugging server.
bool StartProbeAutomation(std::function<void()> quit);
void AddProbeAutomationTab(CefRefPtr<CefBrowser> browser);
void RemoveProbeAutomationTab(CefRefPtr<CefBrowser> browser);
void StopProbeAutomation();
