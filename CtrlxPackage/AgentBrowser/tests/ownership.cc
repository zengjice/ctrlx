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
  std::cout << "ownership: PASS\n";
}
