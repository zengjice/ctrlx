#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>

// UI-thread confined. Runtime instance identity is not a pane or layout ID.
// All groups deliberately share one profile; groups are control routing only.
struct BrowserRun {
  std::string id, secret, label;
  int pid = 0;
  uint64_t startSeconds = 0, startMicros = 0;
  bool active = true;
  std::string conversation = {};
  std::string session = {};
};
struct BrowserDelegation {
  BrowserRun process;
  bool canWrite = true;
  uint64_t revision = 0;
  bool active = true;
};
class BrowserOwnership {
 public:
  std::map<std::string, BrowserRun> runs;
  std::map<std::string, std::string> owners;
  std::map<std::string, std::string> conversations;
  std::map<std::string, BrowserDelegation> grants;
  uint64_t nextGrantRevision = 0;
  void Add(const std::string& tab, const std::string& run, const std::string& conversation) {
    owners[tab] = run;
    conversations[tab] = conversation;
  }
  static bool SameProcess(const BrowserRun& a, const BrowserRun& b) {
    return a.pid == b.pid && a.startSeconds == b.startSeconds && a.startMicros == b.startMicros;
  }
  bool CanUse(const std::string& run, const std::string& tab) const {
    if (Owns(run, tab)) return true;
    auto grant = grants.find(tab);
    auto instance = runs.find(run);
    return grant != grants.end() && grant->second.active && instance != runs.end() && instance->second.active &&
        (grant->second.process.conversation.empty() || grant->second.process.conversation == instance->second.conversation) &&
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
  void SuspendGrant(const std::string& tab) {
    auto it = grants.find(tab);
    if (it == grants.end()) return;
    if (it->second.process.conversation.empty()) { grants.erase(it); return; }
    it->second.active = false;
    it->second.revision = ++nextGrantRevision;
  }
  // Only the trusted Host supplies this key after verifying the live process
  // and native conversation. Never accept it from an Agent's JSON request.
  bool BindConversation(const std::string& run, const std::string& key, std::vector<std::string>& changed, const std::string& session = "") {
    auto instance = runs.find(run);
    if (instance == runs.end() || !instance->second.active) return false;
    for (const auto& [id, other] : runs)
      if (id != run && other.active && !key.empty() && other.conversation == key) return false;
    const auto previous = instance->second.conversation;
    instance->second.conversation = key;
    instance->second.session = session;
    for (auto& [tab, owner] : owners) {
      if (owner == run) {
        if (conversations[tab].empty()) conversations[tab] = key;
        if (previous != key) changed.push_back(tab);
      } else if (!key.empty() && conversations[tab] == key && runs.contains(owner) && !runs.at(owner).active) {
        owner = run;
        changed.push_back(tab);
      }
    }
    std::vector<std::string> revoked;
    for (auto& [tab, grant] : grants) {
      if (SameProcess(grant.process, instance->second)) {
        if (grant.process.conversation.empty()) grant.process.conversation = key;
        if (!grant.process.conversation.empty() && grant.process.conversation != key && grant.active) {
          grant.active = false;
          grant.revision = ++nextGrantRevision;
          changed.push_back(tab);
        }
      }
      if (!key.empty() && grant.process.conversation == key && grant.process.session != session) {
        revoked.push_back(tab);
        changed.push_back(tab);
        continue;
      }
      if (!key.empty() && grant.process.conversation == key && !grant.active) {
        grant.process = instance->second;
        grant.active = true;
        grant.revision = ++nextGrantRevision;
        changed.push_back(tab);
      }
    }
    for (const auto& tab : revoked) grants.erase(tab);
    return true;
  }
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
        it != owners.end() && it->second == run &&
        (!conversations.contains(tab) || conversations.at(tab).empty() || conversations.at(tab) == instance->second.conversation);
  }
  bool Assign(const std::string& tab, const std::string& run, bool busy) {
    if (busy || !owners.contains(tab)) return false;
    if (!run.empty() && (!runs.contains(run) || !runs.at(run).active)) return false;
    grants.erase(tab);
    owners[tab] = run;
    conversations[tab] = run.empty() ? "" : runs.at(run).conversation;
    return true;
  }
  void Revoke(const std::string& run) {
    auto it = runs.find(run);
    if (it != runs.end()) { it->second.active = false; it->second.secret.clear(); }
    // Keep pages for the human; only a fresh Host-verified identity may rebind.
  }
};
