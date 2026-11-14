# Agent identity

`AgentID(hostID, paneID)` identifies one persistent pane in a Host state root.
`paneID` is the existing recovery UUID, not a tmux `%pane` string. Session/window
placement, tmux server, plugin, PID and native conversation are not part of this
product identity. No second registry or UUID allocation is introduced.

## Resolution and operation evidence

`AgentID.resolve` requires a unique match in the supplied current snapshot.
Missing and ambiguous targets never fall back to a name, directory or raw pane.
Viewers also validate the authenticated pairing and the catalog's Host UUID.
The current location supplies the session/window and raw pane used by the UI.

`WorkspacePaneIdentity.isSamePane` deliberately retains the tmux server check.
It guards operations in one running server, including input and close commands;
it is not the long-term product association rule. `AgentProcessBinding` adds the
plugin and kernel process incarnation. Native conversation, request, invocation
and resource lease remain separate evidence.

| Consumer | Long-term association | Operation or historical check |
| --- | --- | --- |
| Orbie / Orbiter | AgentID extracted from existing target/binding | Current plugin capability and input readiness; invocation evidence remains frozen |
| Workflow | Participant IDs stay stable; participant targets resolve by AgentID | Delivery/turn evidence and process binding; occupancy includes unfinished calls to the same AgentID |
| Notification navigation | AgentID plus authenticated pairing | Current catalog; missing/old targets open the session list |
| Notification answer | AgentID locates the current pane | Original plugin, native conversation, process incarnation and request must all match |
| Files / Browser / Simulator grouping | Persistent source pane within the Host | Resource IDs preserve the actual page/device; lookup does not authorize input |
| Browser / Simulator owner | AgentID + plugin + native conversation | Existing run token, process, grant, Viewer lease and human takeover checks |
| Model reads | Current pane and plugin | Runtime/conversation rechecked after awaits and before writes; display cache replaces old generations |
| Model shortcuts | Existing Host/window scope | Provider defaults and shared preference revisions keep their previous meaning |
| Resume / Fork | Verified native conversation evidence | Current runtime for live use; recovery descriptor and journal for restart |

`matchesProcess`, `matchesBinding`, `matchesConversation` and tmux server
comparisons remain at those operation/history boundaries. They must not become
alternative product identity resolvers. In particular, finding a task after a
restart does not resend its input or continue a paused workflow.

Resource requests recheck the requesting Codex process's current writer. A
process-detected conversation cache is refreshed on that path, so switching away
and back in one process can recover the original resources. Ordinary background
reconciliation still uses the native cache; hook-owned state needs its native
conversation event and is not overwritten by resource discovery.

## Event ingress

The existing socket FIFO serializes `handleIngress` and dispatch; no parallel
consumer is added. Kernel-captured `PluginIngressPeer`
travels with each queued frame through translation. Current-state sinks run under
a Host-created `AgentEventContext` and recheck it after actor hops. Native results
can independently match their original invocation without changing current state.

Only native start/submit semantics can introduce a changed conversation. An older
kernel-observed hook cannot rewind a newer conversation; a retired conversation
requires independent native ownership evidence, a newly started authenticated
hook, or a newer native start from a sequenced resident bridge. pi/omp/OpenCode
bridges serialize sends and retain a monotonic `sourceSequence` across extension
reloads in the same process. The Host scopes the counter to the kernel sender;
missing/replayed counters cannot replace previously observed order. Ordinary
events still cannot switch conversations. OpenCode first binds its synthetic
pane placeholder to a real root conversation; delayed completion and child
activity cannot select a different root. Codex checks its unique open rollout on conversation
changes; a conflicting verified writer rejects even a fresh SessionStart. Shared
code does not require UUID-shaped IDs for other plugins.

Confirmed successor processes clear old state, forms, telemetry and native cache
ownership before establishing the new runtime. Failed process discovery is not
an empty snapshot. Synthetic exits use non-Codable Host observations, including
the prior process incarnation; `peer == nil` is not an authorization bypass.
Sidecars should return translated lifecycle events from `handleIngress`, retaining
the original socket peer. Unsolicited state events without Host evidence are not
accepted as current Agent state.

## Persistence and protocol

Existing Orbie/Orbiter records already contain the Host and pane UUIDs. They are
decoded without rewriting those files or allocating new identities. Window/session
fields remain location metadata. Workflow schema/wire version 8 keeps participant
IDs independent of changing process snapshot IDs. Older mutation commands fail
the version gate. Before converting an older workflow archive, the store validates
the full input and preserves a `.schema-N.backup` beside it.

New workflow participants receive independent references and retain their targets
even before a step uses them. Rebinding preserves the participant reference;
adding the original Agent again creates a separate participant. Refresh and save
retain configured targets, while execution reserves only Agents used by steps.
Start-conflict checks use the same participant resolver: an existing target takes
precedence over a legacy instance ID, including after rebinding. Only participants
without a target retain the legacy instance-ID lookup.

The native conversation cache uses schema 2 with records and invalidated pane
UUIDs. The previous dictionary is backed up as `.schema-1.backup`. Invalidation
is ordered after any pending save; fresh verified evidence can replace a valid
invalidated entry. Corrupt or future-format files are preserved and fail closed.
Recovery checks invalidation while keeping its existing in-progress launch
journal. A history file's existence alone never revalidates an obsolete record.

`supportsStableAgentNotifications` in Peer Hello gates precise notification
targets and actions. New Hosts remove both raw pane targets and answer actions for
old Viewers. New Viewers open only the Host list for old notifications. Stable IDs
and answer evidence stay inside encrypted content; Relay still forwards ciphertext.
Authenticated capabilities survive Viewer/Relay disconnections for offline APNs.
A subsequent authenticated Hello replaces them; changing the paired public key
or removing the pairing clears them. An unadvertised peer remains unsupported.
The action context, including identity evidence, retains the 1,200-byte budget.

Rollback requires preserving new records and restoring the corresponding schema
backup; replacing the App alone does not promise backward readability.

Implementation and acceptance status live in
[the staged plan](v3.1.0/agent-identity/IMPLEMENTATION_PLAN.md). Compilation,
isolated fixtures and actual cross-device acceptance are recorded separately.
