#include "../Ownership.h"
#include <cassert>
#include <iostream>
int main() {
  BrowserOwnership state;
  BrowserRun a{"a", std::string(64, 'a'), "same pane", 100, 1, 1};
  BrowserRun b{"b", std::string(64, 'b'), "same pane", 200, 1, 2};
  assert(state.Register(a) && state.Register(b) && state.Register(a));
  auto conflict = a; conflict.secret = b.secret;
  assert(!state.Register(conflict));
  conflict = a; ++conflict.startMicros;
  assert(!state.Register(conflict));
  state.owners = {{"tab-a", "a"}, {"tab-b", "b"}, {"manual", ""}};
  assert(state.Owns("a", "tab-a"));
  assert(!state.Owns("a", "tab-b") && !state.Owns("b", "tab-a"));
  assert(!state.Owns("a", "manual") && !state.Owns("", "manual"));
  assert(!state.Assign("tab-a", "b", true));
  assert(state.Owns("a", "tab-a"));
  assert(state.Assign("tab-a", "b", false));
  assert(!state.Owns("a", "tab-a") && state.Owns("b", "tab-a"));
  assert(!state.Assign("missing", "a", false));
  assert(!state.Assign("manual", "missing", false));
  assert(!state.Authenticate("a", b.secret));
  state.Revoke("b");
  assert(!state.Authenticate("b", b.secret) && !state.Owns("b", "tab-b"));
  assert(state.owners.at("tab-b") == "b"); // keep the human's pages
  assert(!state.Register(b)); // cannot resurrect revoked identity
  assert(!state.Assign("manual", "b", false));
  assert(state.Assign("tab-b", "", false));
  assert(!state.Owns("b", "tab-b"));
  assert(!state.CanUse("a", "manual"));
  assert(state.Delegate("manual", a));
  assert(state.CanUse("a", "manual") && state.CanWrite("a", "manual"));
  assert(!state.Owns("a", "manual") && state.owners.at("manual").empty());
  assert(!state.CanUse("b", "manual"));
  assert(!state.Delegate("tab-a", a));
  auto revision = state.GrantRevision("manual");
  assert(state.Pause("manual"));
  assert(state.CanUse("a", "manual") && !state.CanWrite("a", "manual"));
  assert(state.GrantRevision("manual") != revision);
  assert(state.Resume("manual") && state.CanWrite("a", "manual"));
  auto reused = a; reused.id = "later"; ++reused.startMicros;
  assert(state.Register(reused));
  assert(!state.CanUse("later", "manual"));
  auto child = a; child.id = "child"; ++child.pid;
  assert(state.Register(child) && !state.CanUse("child", "manual"));
  state.RemoveGrant("manual");
  assert(!state.CanUse("a", "manual"));
  assert(state.Delegate("manual", a));
  state.Revoke("a");
  assert(!state.CanUse("a", "manual"));
  BrowserOwnership restarted;
  assert(!restarted.Authenticate("a", a.secret));
  BrowserOwnership resumed;
  std::vector<std::string> changed;
  assert(resumed.Register(a));
  assert(resumed.BindConversation("a", "host/pane/codex/conversation", changed));
  resumed.owners = {{"owned", "a"}, {"manual", ""}, {"revoked", ""}};
  resumed.conversations["owned"] = resumed.runs.at("a").conversation;
  assert(resumed.Delegate("manual", resumed.runs.at("a")));
  assert(resumed.Delegate("revoked", resumed.runs.at("a")));
  resumed.RemoveGrant("revoked");
  assert(resumed.Pause("manual"));
  assert(resumed.Register(b));
  assert(!resumed.BindConversation("b", "host/pane/codex/conversation", changed)); // old process still live
  resumed.Revoke("a");
  resumed.SuspendGrant("manual");
  assert(!resumed.CanUse("b", "owned") && !resumed.CanUse("a", "manual"));
  assert(resumed.BindConversation("b", "host/pane/codex/fork", changed));
  assert(!resumed.CanUse("b", "owned") && !resumed.CanUse("b", "manual"));
  assert(resumed.BindConversation("b", "host/other-pane/codex/conversation", changed));
  assert(!resumed.CanUse("b", "owned"));
  assert(resumed.BindConversation("b", "host/pane/codex/conversation", changed));
  assert(resumed.Owns("b", "owned") && resumed.CanUse("b", "manual"));
  assert(!resumed.CanWrite("b", "manual") && !resumed.CanUse("b", "revoked"));
  assert(!resumed.Authenticate("a", a.secret) && !resumed.Register(a));
  // A new conversation inside the same live process also loses old resources.
  assert(resumed.BindConversation("b", "host/pane/codex/new", changed));
  assert(!resumed.Owns("b", "owned") && !resumed.CanUse("b", "manual"));
  assert(resumed.BindConversation("b", "host/pane/codex/conversation", changed));
  assert(resumed.Owns("b", "owned") && !resumed.CanWrite("b", "manual"));
  BrowserOwnership scoped;
  assert(scoped.Register(a));
  assert(scoped.BindConversation("a", "conversation", changed, "session-a"));
  scoped.owners = {{"owned", "a"}, {"writable", ""}, {"paused", ""}};
  scoped.conversations["owned"] = "conversation";
  assert(scoped.Delegate("writable", scoped.runs.at("a")));
  assert(scoped.Delegate("paused", scoped.runs.at("a")));
  scoped.Pause("paused");
  scoped.Revoke("a");
  scoped.SuspendGrant("writable");
  scoped.SuspendGrant("paused");
  assert(scoped.Register(b));
  assert(scoped.BindConversation("b", "conversation", changed, "session-a"));
  assert(scoped.CanWrite("b", "writable") && !scoped.CanWrite("b", "paused"));
  assert(scoped.BindConversation("b", "conversation", changed, "session-b"));
  assert(scoped.Owns("b", "owned")); // owned resources follow the pane
  assert(!scoped.CanUse("b", "writable") && !scoped.CanUse("b", "paused"));
  assert(scoped.grants.empty()); // human authorization cannot leave its session
  BrowserOwnership popups;
  assert(popups.Register(a));
  assert(popups.BindConversation("a", "conversation-a", changed));
  popups.Add("parent", "a", popups.runs.at("a").conversation);
  auto inherited = popups.conversations.at("parent");
  assert(popups.BindConversation("a", "conversation-b", changed));
  popups.Add("child", "a", inherited);
  assert(!popups.Owns("a", "parent") && !popups.Owns("a", "child"));
  assert(popups.BindConversation("a", "", changed)); // native identity temporarily unavailable
  popups.Add("late-child", "a", inherited);
  assert(!popups.Owns("a", "late-child"));
  assert(popups.BindConversation("a", "conversation-a", changed));
  assert(popups.Owns("a", "parent") && popups.Owns("a", "child") && popups.Owns("a", "late-child"));
  popups.Add("manual-child", "", std::string());
  assert(!popups.CanUse("a", "manual-child"));
  std::cout << "ownership: PASS\n";
}
