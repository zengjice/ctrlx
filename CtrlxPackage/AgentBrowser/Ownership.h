#pragma once
#include <cstdint>
#include <map>
#include <string>

// UI-thread confined. Runtime instance identity is not a pane or layout ID.
// All groups deliberately share one profile; groups are control routing only.
struct BrowserRun {
  std::string id, secret, label;
  int pid = 0;
  uint64_t startSeconds = 0, startMicros = 0;
  bool active = true;
};
struct BrowserDelegation {
  BrowserRun process;
  bool canWrite = true;
  uint64_t revision = 0;
};
class BrowserOwnership {
 public:
  std::map<std::string, BrowserRun> runs;
  std::map<std::string, std::string> owners;
  std::map<std::string, BrowserDelegation> grants;
  uint64_t nextGrantRevision = 0;
  static bool SameProcess(const BrowserRun& a, const BrowserRun& b) {
    return a.pid == b.pid && a.startSeconds == b.startSeconds && a.startMicros == b.startMicros;
  }
  bool CanUse(const std::string& run, const std::string& tab) const {
    if (Owns(run, tab)) return true;
    auto grant = grants.find(tab);
    auto instance = runs.find(run);
    return grant != grants.end() && instance != runs.end() && instance->second.active &&
        SameProcess(grant->second.process, instance->second);
  }
  bool CanWrite(const std::string& run, const std::string& tab) const {
    return Owns(run, tab) || (CanUse(run, tab) && grants.at(tab).canWrite);
  }
  uint64_t GrantRevision(const std::string& tab) const {
    auto it = grants.find(tab);
    return it == grants.end() ? 0 : it->second.revision;
  }
  bool Delegate(const std::string& tab, const BrowserRun& process) {
    auto owner = owners.find(tab);
    if (owner == owners.end() || !owner->second.empty() || process.pid <= 1) return false;
    grants[tab] = {process, true, ++nextGrantRevision};
    return true;
  }
  bool Pause(const std::string& tab) {
    auto grant = grants.find(tab);
    if (grant == grants.end() || !grant->second.canWrite) return false;
    grant->second.canWrite = false;
    grant->second.revision = ++nextGrantRevision;
    return true;
  }
  bool Resume(const std::string& tab) {
    auto grant = grants.find(tab);
    if (grant == grants.end()) return false;
    grant->second.canWrite = true;
    grant->second.revision = ++nextGrantRevision;
    return true;
  }
  void RemoveGrant(const std::string& tab) { grants.erase(tab); }
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
    grants.erase(tab);
    owners[tab] = run;
    return true;
  }
  void Revoke(const std::string& run) {
    auto it = runs.find(run);
    if (it != runs.end()) { it->second.active = false; it->second.secret.clear(); }
    // Keep pages for the human; never inherit grants on a subsequent launch.
  }
};
