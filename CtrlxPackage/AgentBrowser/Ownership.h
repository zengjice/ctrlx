#pragma once
#include <cstdint>
#include <map>
#include <optional>
#include <string>

// UI-thread confined. Runtime instance identity is not a pane or layout ID.
// All groups deliberately share one profile; groups are control routing only.
struct BrowserRun {
  std::string id, secret, label;
  int pid = 0;
  uint64_t startSeconds = 0, startMicros = 0;
  bool active = true;
};
class BrowserOwnership {
 public:
  std::map<std::string, BrowserRun> runs;
  std::map<std::string, std::string> owners;
  bool Register(const BrowserRun& run) {
    if (run.id.empty() || run.secret.size() < 32 || run.pid <= 1) return false;
    auto it = runs.find(run.id);
    if (it == runs.end()) { runs.emplace(run.id, run); return true; }
    const auto& old = it->second;
    return old.active && old.secret == run.secret && old.pid == run.pid &&
        old.startSeconds == run.startSeconds && old.startMicros == run.startMicros;
  }
  bool Authenticate(const std::string& run, const std::string& secret) const {
    auto it = runs.find(run);
    return it != runs.end() && it->second.active && it->second.secret == secret;
  }
  bool Owns(const std::string& run, const std::string& tab) const {
    auto it = owners.find(tab);
    auto instance = runs.find(run);
    return !run.empty() && instance != runs.end() && instance->second.active &&
        it != owners.end() && it->second == run;
  }
  bool Assign(const std::string& tab, const std::string& run, bool busy) {
    if (busy || !owners.contains(tab)) return false;
    if (!run.empty() && (!runs.contains(run) || !runs.at(run).active)) return false;
    owners[tab] = run;
    return true;
  }
  void Revoke(const std::string& run) {
    auto it = runs.find(run);
    if (it != runs.end()) { it->second.active = false; it->second.secret.clear(); }
    // Keep pages for the human; never inherit grants on a subsequent launch.
  }
};

// A default slot is pane-bound. A new process may create its own page, never inherit a grant.
class BrowserPrimaryTabs {
 public:
  std::optional<int> Find(const std::string& pane, const std::string& owner) const {
    auto it = pages_.find(pane);
    if (it == pages_.end() || owner.empty() || it->second.first != owner) return std::nullopt;
    return it->second.second;
  }
  void Set(const std::string& pane, const std::string& owner, int browser) { pages_[pane] = {owner, browser}; }
  void Remove(int browser) { std::erase_if(pages_, [browser](const auto& entry) { return entry.second.second == browser; }); }
 private:
  std::map<std::string, std::pair<std::string, int>> pages_;
};
