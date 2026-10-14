# Terminal quick actions

## Mac keyboard shortcuts

The File, Edit, View and Window menus show the fixed shortcuts. New-session,
new-terminal, session-search and voice buttons also show them in their help text.
Commands target the active workbench
window. Tab navigation, new terminals and close-tab follow the last focused side
of its split; voice input follows the focused native terminal endpoint.
New terminals use the selected Files directory on the focused side, then the
source terminal's current directory. Local workspaces fall back to the retained
Git directory, then the home directory, without taking the other side's Files path.

| Shortcut | Action |
|---|---|
| Command-N | Open the local New Session picker |
| Command-T | Create a terminal in the current session and focused split |
| Command-P | Search local and paired-Host sessions, then switch with Return |
| Command-1…9 | Select any tab by its visible order within the focused split |
| Command-Option-Left / Right | Select the previous / next tab within that split |
| Command-Option-Up / Down | Select the previous / next session in sidebar order |
| Command-W | Close the focused tab, preserving existing terminal close confirmation |
| Command-Option-M | Start / stop voice input; stop inserts without submitting |
| Command-Option-F | Find in Files |
| Command-Option-S | Toggle the status bar |
| Command-Option-P | Show Sessions from the menu bar menu |
| Command-+ / - / 0 | Increase / decrease / reset terminal font size |

Tab shortcuts include terminals, Git, Files and Browser tabs, follow drag-reordered
positions, and wrap within the focused split. Command-Shift-[ / ] is no longer
bound. Extended actions use the same Command-Option modifiers as navigation.
Rich-text and control-sequence copy remain menu actions without default shortcuts.
Shortcuts are fixed; Settings does not provide a shortcut editor.

Session search follows the sidebar order and matches session names, displayed
titles and Host names. Up/Down choose a result, Return switches, and Escape
cancels. Offline Hosts are shown but cannot be selected. The main workspace owns
session creation/switching; detached workspaces retain their session ownership.
Command-N opens the existing local session picker in a dialog, including when
the sidebar is collapsed. Escape or Command-W closes either session picker
without closing a terminal underneath it.
Voice input is available with a visible status bar and a usable terminal target.
Command-backtick is left to macOS window switching. Standard copy/paste and
Command-comma settings remain, and no application-wide Control or Escape handler
intercepts ordinary terminal input. Escape remains local to open panels.

## Status bar

macOS offers **Commands** (`/`) and **Quick Phrases** as labeled, bordered buttons
on the left side of the terminal's bottom status bar, for both local and Viewer
windows. The buttons keep a 32-point height including native padding;
session details and telemetry sit on the right. In narrow splits, labels collapse
to icons with the same height and accessible names, leaving room for the voice
input button without widening the terminal; details fall back to
the session/window identifier, then hide together with their spacing if the
identifier cannot fit. Local and Viewer windows use the same complete status-bar
component. The status bar keeps the same height across widths
and focus changes. They follow Settings → General →
Show status bar. Both open button-grid popovers above their buttons without
resizing the terminal. Click a bare command or saved phrase to send literal text,
a host-side 200 ms pause, and one Return. Argument-entry commands instead insert
the command and a trailing space without Return; add arguments and explicitly
send from the terminal. Existing terminal input is never cleared automatically.

- The target is the last focused native terminal in this panes scene, including
  a pane in the right-hand workbench split. The popover shows its host, session,
  window name and pane ID. It never infers the target from the left selected tab
  or from a remote tmux client's active pane.
- Only the focused window's status bar shows the controls. Other visible terminal
  windows reserve the same space, preventing focus changes from resizing terminals;
  their hidden controls cannot be clicked or accessed by VoiceOver. Unparseable
  remote layouts retain the same window-level status bar as tiled layouts.
- Commands use the same curated agent catalog as iOS; this is not live capability
  discovery. Unsupported agents have no command catalog. Working agents are not
  disabled just because a turn is running.
- Phrases work in ordinary shells too. **Add Phrase** saves without sending;
  right-click a phrase on Mac or long-press it on iOS for **Edit** and **Delete**.
  Editing reuses the add editor with the saved text prefilled; Save keeps its
  current position without sending, while Cancel leaves it unchanged.
  Drag a phrase onto another tile to move it
  to that tile's position on both Mac and iOS. On iOS, the hovered tile gets an
  accented dashed outline and a **Drop at #N** marker showing the final position.
  The marker is an overlay: hovering never changes layout or saves/syncs an order,
  and leaving the tile or completing a drop clears it. Reordering saves on drop, even
  offline, without sending terminal input or closing the panel. VoiceOver offers
  **Move Earlier** and **Move Later** actions. The library is local-first and shared across
  windows and hosts. Optional, explicitly enabled pairing sync merges libraries
  between Macs and iPhones (see below).
- Disconnection, stream bootstrap, external editors and blocking agent forms
  prevent sending, not phrase management. Switching terminal, typing into it or
  destroying its native view invalidates the captured action; it cannot silently
  move to another pane or submit twice.

On iOS, the two first-row buttons open a shared **in-page overlay**, not a system
sheet. The overlay covers terminal content without contributing to its layout:
opening, switching and closing it leave the native first responder, keyboard
intent and second-row shortcut accessory in place. Tap the same toolbar button
again, outside the panel or Close to dismiss; the other button switches panels
directly. Panel toggles remain usable in **Add/Edit Phrase**, while terminal-key
buttons stay disabled. Only entering **Add/Edit Phrase** borrows input focus for its native editor;
returning restores the terminal's existing keyboard intent. Both tiled windows
and standalone terminal views use the same presentation state and target checks.
The overlay uses plain headers and local state for its phrase editor, with no
nested navigation stack, navigation destinations or environment dismiss action.
Closing a panel or cancelling/saving its editor cannot pop the session route.
Both panels share a rounded Liquid Glass surface on iOS 26+, falling back to
ultra-thin material on older systems. Only the overlay moves 24 points and fades
over 0.2 seconds, without an extra shadow layer; it no longer slides its full
height across the live terminal. The animation never wraps the terminal or keyboard rows. Reduce Motion uses a
fade only, and Reduce Transparency uses an opaque, legible surface. The phrase
editor hides its Form background so it does not obscure the shared material.

## Context-aware voice input

The Mac status bar also has a microphone, for both Local and Viewer terminal
panes. One click starts on-device recognition; a second click, or **Stop and
Insert** in the live-preview popover, finishes correction and inserts one literal
text batch **without Return**. Esc, dismissing the preview, switching targets,
typing in the terminal, disconnection or leaving the view cancels that recording.
The Mac preview owns its dismissal: clicking the microphone remains a normal
button action, while outside clicks, Esc and application deactivation cancel.
Finishing keeps the preview visible through correction; closing it after insertion
does not cancel the completed result.
The result is tied to the focused native endpoint and its focus/input revisions;
switching away and back does not revive it. Ordinary shells are supported.
Pending agent forms and external editors disable dictation into the terminal.
There is no global hotkey, clipboard replacement or extra Host/Relay command.

`CtrlxCommon` owns `VoiceInputController`, the SpeechAnalyzer/legacy recognizers,
vocabulary, candidate assembly, correction prompts/policy/provider client and
`VoiceCorrectionSettingsSection`. iOS retains its existing live-input adapter;
Mac previews partial text and inserts only the final result through
`TerminalQuickActionRouter` and the existing keyboard queue. App-wide recording
ownership prevents two windows from racing the microphone, including asynchronous
analyzer cleanup. iOS alone configures `AVAudioSession`; Mac uses its local audio
input and declares microphone/speech usage plus the hardened-runtime audio-input
entitlement.

Both clients snapshot context once at recording start: session/window names,
command, current path and recent text from the focused terminal buffer. The shared
extractor copies at most 512 tail rows, preserves soft wraps and limits the final
context to 12,000 characters. It does not poll, copy full scrollback, request
additional Host history or read the Viewer's filesystem.

The shared vocabulary adds at most eight short, deduplicated terms from the captured
session/window names and the current directory's basename. It never mines arbitrary
terminal output or scans files. Live recognition, the accurate second pass and
correction use the same per-recording vocabulary; switching sessions cannot carry
old project terms into a new recording.

On iOS/macOS 26+, SpeechAnalyzer uses SpeechTranscriber where available, otherwise
DictationTranscriber; older systems retain on-device SFSpeechRecognizer support.
Correction tries the configured provider, then the on-device model when available,
then preserves the recognition result. Terminal insertion flattens newlines and
removes control characters. Speech models may require a first-use asset download.

Correction reserves room for the complete original utterance and its output before
adding optional evidence. The on-device route uses the model's context size and,
on 26.4+, its tokenizer; 26.0–26.3 use a conservative UTF-8 byte budget. It trims
older terminal context first (retaining metadata when possible), then drops optional
phonetic hints. If the original cannot fit, it stays unchanged. Provider output
budgets grow with transcript size up to 8,192 tokens; oversized requests are skipped,
not shortened. Explicitly incomplete/failed provider responses are never inserted.

Shared validation rejects altered literal numbers, versions, addresses, prefixed
paths, flags, assignments and backtick-delimited code. Prompts additionally require
preserving all clauses, negations and conditions. These are conservative checks,
not a semantic guarantee: natural-language homophone correction remains model-based.

Mac **Settings → Voice Input** and the existing iOS settings use the same component
for provider credentials, model choices and bundled-sample model tests. Existing
iOS preference keys (`voiceCorrectionProvider`, `voiceCorrectionModelID`,
`voiceCorrectionTestedModelIDsByProvider`) and Keychain accounts are unchanged.
Settings and credentials stay device-local; no credential sync is added. If a
provider is configured, transcript candidates and bounded terminal context are
sent directly to it for correction; microphone audio is not uploaded.

Bundled model tests include already-correct input, negation/conditions, literals,
irrelevant or instruction-like context and long utterances. Scores penalize differences
from complete reference transcripts, not just missing/incorrect keywords; unchanged
and intent-sensitive fixtures require a full match apart from punctuation, spacing
and letter case. Scores are fixture checks, not a general measure of semantic accuracy.
They evaluate the model's actual output: a rejected correction does not earn credit
for the production pipeline's safe fallback to the original draft.

Regression coverage lives in `CtrlxCommonTests/Voice*`,
`CtrlxServerFeatureTests/TerminalVoiceInputRequestTests.swift`,
`CtrlxServerFeatureTests/MacVoiceInputPopoverTests.swift` and the existing iOS
phase/input tests. `python3 scripts/tests/test_mac_voice_input_popover.py` exercises
native mouse dispatch in an isolated AppKit process with fake recognition (no
microphone, credentials or terminal input). Real microphone, permission prompts
and recognition quality remain Mac/iPhone device acceptance checks.

## iOS custom input buttons

The first input row's horizontal scroll area ends with `$`, device-local custom
buttons, then **Add Button** (`＋`). Send remains pinned outside the scroll area.
Add Button opens the same in-page overlay, without a settings page. Choose a name
and either single-line literal text or one special key (Tab, Home, End, Ctrl+C,
etc.). The text action's **Auto Send** switch defaults on for new buttons:
it queues literal text, the existing host-side 200 ms pause and one Return.
Turning it off enters only the text, allowing further editing before tapping
Send. Each button persists its own choice; existing buttons retain their saved
behavior. Special keys send only the selected key and have no Auto Send switch.
No action clears an existing terminal draft. Text cannot contain newlines or
terminal controls. Saving a button never executes it.

Tap a custom button to execute; long-press it to delete directly, without sending
on release. Horizontal scrolling cancels the long press, and built-in buttons are
not deletable. VoiceOver also offers Delete. Creation/deletion remain available
offline, while execution uses the active pane's existing keyboard FIFO and the
same connection, readiness, input-revision and blocking-form checks as phrases.
The add editor suspends terminal input and returns the existing keyboard intent
when closed, cancelled or saved. It has no nested navigation stack.

The library is shared by all iOS windows, including ordinary shells, and persists
under `terminalCustomButtons.v1`. It is independent of Quick Phrase Sync; this
first version has no editing, reordering or synchronization, and requires no new
Host or Relay command.

## Implementation boundaries

### Agent identity and command-panel availability

The Mac and iOS `/` buttons always open their panels. If the current pane has no supported
agent identity, the panel explains why no catalog is available; it never guesses
Codex from a window title or reuses another pane's agent. Host metadata arriving
while that explanation is open restores the matching catalog only for the same
host, pane and local input revision. Connection/readiness/editor/blocking-form
checks still apply when sending; opening the panel grants no send permission.
Changing targets or editing terminal input invalidates the captured panel.

Opening an unidentified **local Mac** command panel also requests one fresh,
manifest-driven process snapshot, bypassing the one-second snapshot cache. This
reuses the Host's reconciliation and viewer updates; it does not send terminal
input, guess an agent from the command line or window title, or add a polling
loop. Remote panels wait for Host metadata as before. The ten-second background
scan remains a fallback for manual launches and resumes whose hooks are absent,
disabled, or late. Detection includes an agent that replaces the pane's shell
with `exec`.

Session-end suppression is tied to the observed old agent process IDs, not the
pane ID alone. A different process in the same pane can be identified without
waiting for a scan to observe an empty shell. If no process was observed before
the end event, the Host does not create a blanket suppression for unknown future
processes. Failed probes leave both identity and suppression unchanged. Hook
states remain authoritative; opening a panel grants no send permission.

On the Mac Host, Codex's session-end monitor uses
`PluginHost.agentPanesIfAvailable()`. A failed, cancelled or unsupported process
probe is `nil`, not an empty list: it preserves identity, correlation and the
previous live baseline until a successful probe. Only a confirmed absence can
end a session. This prevents a temporary probe failure from clearing the agent
on all viewers (or requesting pane closure). The legacy sidecar listing API is
unchanged. This fix requires updating the Host Mac for identity stability and
iOS for the always-openable explanation; no Relay deployment is needed.

### Curated command catalogs

Both clients use `AgentQuickCommand.commands(for:)` as the display order and
send allowlist. Keep the agents' lists independent: matching command names do
not guarantee matching behavior. The current catalog was checked against Codex
CLI 0.162.1 and Claude Code 2.1.276 plus their official command references:
[Codex](https://learn.chatgpt.com/docs/developer-commands?surface=cli) and
[Claude Code](https://code.claude.com/docs/en/commands).

- **Codex (46):** `/model`, `/status`, `/usage`, `/fast`, `/personality`, `/plan`,
  `/goal`, `/compact`, `/resume`, `/fork`, `/rename`, `/agent`, `/diff`, `/review`,
  `/ps`, `/permissions`, `/skills`, `/mcp`, `/plugins`, `/theme`, `/keymap`,
  `/statusline`, `/experimental`, `/debug-config`, `/ide`, `/vim`, `/apps`,
  `/hooks`, `/memories`, `/copy`, `/import`, `/feedback`, `/init`, `/app`, `/side`,
  `/raw`, `/title`, `/pets`; **Session Actions:** `/new`, `/clear`, `/archive`,
  `/delete`, `/approve`, `/stop`, `/logout`, `/exit`.
- **Claude Code (75):** `/model`, `/status`, `/usage`, `/effort`, `/fast`, `/plan`, `/goal`,
  `/compact`, `/autocompact`, `/context`, `/resume`, `/branch`, `/fork`, `/rename`, `/diff`,
  `/review`, `/permissions`, `/skills`, `/mcp`, `/plugin`, `/reload-skills`,
  `/reload-plugins`, `/config`, `/theme`, `/output-style`, `/memory`, `/hooks`,
  `/tasks`, `/help`, `/advisor`, `/artifacts`, `/copy`, `/export`, `/import`,
  `/feedback`, `/bug`, `/ide`, `/chrome`, `/color`, `/desktop`, `/mobile`, `/passes`,
  `/powerup`, `/privacy-settings`, `/radio`, `/rate-limit-options`, `/recap`,
  `/release-notes`, `/remote-control`, `/remote-env`, `/sandbox`, `/scroll-speed`,
  `/skill-doctor`, `/teleport`, `/tui`, `/focus`, `/upgrade`, `/usage-credits`,
  `/voice`, `/web-setup`, `/workflows`, `/statusline`, `/doctor`, `/debug`, `/init`,
  `/insights`, `/security-review`, `/simplify`; **Session Actions:** `/background`,
  `/rewind`, `/clear`, `/stop`, `/login`, `/logout`, `/exit`.

`AgentCommandSection` partitions the same send allowlist for both clients,
preserving order with nonempty sections and stable section/command IDs.
Session/account actions are separated at the bottom by a **Session Actions**
heading and red-tinted buttons. They still send immediately on a single click;
CtrlX does not add a confirmation or suppress the agent's own dialogs.
These actions can reset a conversation, remove a transcript, stop work, exit or
change host credentials. They retain the same target/input/availability checks
as ordinary commands; `/approve` cannot bypass an open blocking form.

`AgentQuickCommand.submission(for:)` owns the per-agent input policy and
`AgentCommandRequest.keys` binds it to the captured agent. Mac Local, Mac Viewer
and iOS all send those keys through their existing ordered queues. In both
catalogs, **`/goal` inserts `/goal ` without Return**, allowing an objective or
subcommand to be entered. This is a deliberate button policy: a manually entered
bare `/goal` still inspects the goal in either agent. All other existing entries
retain their useful bare invocation (picker, toggle, inspection or action);
optional inline arguments alone do not force insert-only behavior. No new
commands are added by this change. Mac hover help and both clients' accessibility
hints describe the action. Closing the panel retains the terminal's input target
and focus; pending-form, connection and stale-input guards still apply.

Codex `/fast` changes the service
tier and can increase usage. Model, account, version and feature flags may still
limit commands on the actual host; the panel does not discover capabilities or
promise that every command can execute during a running turn.

Claude's `/plugin` remains singular, not Codex's `/plugins`. In the checked
baseline, bare `/effort`, `/autocompact` and `/output-style` open configuration
choices; `/rename` auto-generates a session name; `/branch` switches to a copy
of the conversation while preserving the original. `/diff` inspects changes,
and `/review` starts a review without adding `--fix` or `--comment`.
`/reload-skills` and `/reload-plugins` pick up pending changes without restarting;
CtrlX never appends `--force` to bypass Claude's plugin-reload warning.

Claude's `/fork` starts a background copy rather than switching into a normal
branch; `/fast` has additional cost and account restrictions. Setup/repair
workflows such as `/statusline`, `/doctor` and `/init`, plus code-editing
`/simplify`, are now explicit user-invoked buttons, not automatic tasks.
`/remote-control`, `/chrome`, `/desktop` and other integrations retain Claude's
own semantics; CtrlX does not replace them with its Relay or Agent Browser.

Removed Claude entries (`/agents`, `/vim`, `/pr-comments`, `/ultraplan`), duplicate
aliases, required-inline-argument entries (`/mention`, `/add-dir`, `/batch`,
`/deep-research`, `/subtask`), Codex's Windows-only sandbox setup and hidden
credential-bearing `/heapdump` stay out. Claude's provider-specific setup and
other-terminal configuration commands are not generic CtrlX shortcuts. This is
a curated built-in catalog, not enumeration of every bundled/custom skill.

The Claude expansion was checked against the installed 2.1.276 command
definitions as well as the reference above. Updating Claude on a viewer Mac
does not update the agent on its remote hosts; those hosts need a compatible
Claude version too. Updating these built-in lists requires the Mac/iOS client
update, not a Relay deployment or phrase-library synchronization.

The Mac command grid scrolls within a capped height; its header and target label
stay visible. iOS retains its existing scrollable overlay and keyboard behavior.
Catalog tests cover both agents independently, including commands accepted by
one agent but rejected by the other, stable section order and complete coverage,
direct Return submission and stale-target guards. Tests construct requests and
inspect key sequences; they never execute logout/reset/delete/exit against a
real agent or change account credentials.

### Shared models and routing

`CtrlxCommon/Models` owns `AgentCommandMenu`, `QuickPhraseStore` and
`TerminalPhraseContext` for both platforms. `QuickPhraseStore` migrates the existing
`terminalQuickPhrases.v1` array into `terminalQuickPhrases.v2`, preserving IDs and
order and leaving v1 intact as a backup. The same authoritative key loads existing
v2 libraries and writes schema v3 on the next change, adding per-record edit versions.
Older apps reject v3 instead of stripping edit metadata on downgrade. Unreadable
authoritative data fails closed instead of falling back to an obsolete v1 library.

`TerminalQuickActionRouter` is scene-local and tracks native first-responder
events. Each mounted coordinator provides an endpoint backed by its **existing**
`KeystrokeCoalescer`; the local path retains its serial task chain and the remote
path retains its `KeystrokeDebouncer`. No additional queue, tmux resize, rendering
change or SwiftTerm fork change is involved.

## Optional device sync

On **both Mac and iOS**, open **Settings → Quick Phrase Sync**. Each paired device
has **one local switch**, covering every connection to it, regardless of terminal
Host/Viewer roles. Remote Access, Remote Hosts and Manage Hosts contain no phrase
sync controls. Both devices must allow sync; there is no master or role priority.
For reciprocal Office/Home pairings this means two switches total, not four.

Devices are grouped by the SHA-256 fingerprint of their paired Curve25519 public
key, never by device name or pair ID. The short fingerprint shown with each row distinguishes
same-name devices. Missing/malformed keys remain isolated per pairing. Renaming
does not change consent. Another pairing to the same key inherits that device's
choice; a new key does not inherit the replaced pairing's permission. Removing one
route keeps the other routes' consent; removing the last route clears the choice.

New devices default off. For upgrades, both pairing lists are loaded **before**
migrating old per-pair choices. Unanimous choices carry forward. Mixed choices show
**Needs confirmation → Review…**, preserving each old connection's behavior until
the user explicitly enables or disables all routes. They are never merged with OR,
which could turn two mismatched legacy gates into a new sharing path. Choices are
local permissions, not synchronized phrase records. Older peers may still require
their original per-pair switches; the wire protocol is unchanged.

Rows distinguish local off, confirmation needed, not connected, waiting for the
other device, unsupported peer, and connected/both sides enabled. These reflect
the actual version/consent handshake, **not a delivery acknowledgement**. A usable
route wins over an offline reverse route; individual errors remain visible. Status
clears on disconnect and ignores a superseded connection's late reset.

The setting applies to the **whole phrase library**, not the currently visible
session. Merged phrases also propagate through other opted-in devices. Turning a
device off stops direct sharing, but does not erase downloaded phrases or block
indirect propagation through other devices. Only enable sharing within a trusted
group. Built-in agent commands have no separate sync switch.

Both app clients need this implementation. `PeerHelloMessage.quickPhraseSync` is
an optional versioned capability/consent offer. Older clients ignore it and
continue working locally; no new message types are sent to them. The existing
Qcloud relay forwards the opaque encrypted envelope, so **no relay redeployment
is required**. Neither the relay nor a new cloud service stores the phrase library.

`QuickPhraseSyncSession` sends a separate, end-to-end-encrypted `quickPhraseSync`
message only after the version handshake. Until both sides opt in, frames contain
consent only, no phrases. Connection epochs bind messages to the current handshake;
disconnect clears peer consent and cancels pending work. Plaintext sync messages
are rejected by both clients. Notification-only connections don't opt into sync.
Sync offer v2 requires versioned-edit support on both devices. Legacy v1 and
unknown peers receive no frames and show an update hint; local phrase management
and ordinary terminal access remain available.

Changes are saved immediately offline. On connection, both peers exchange and merge
their records; additions/edits/deletions while connected are pushed without polling.
An iPhone in the background/offline catches up when its connection resumes; this
does not claim background/iCloud synchronization. Sync never dispatches terminal
commands or changes terminal size, rendering, scroll position, or input queues.

Records have stable UUIDs and immutable original ordering, with versioned text.
Deletion is a permanent tombstone for the observed IDs (not an array removal),
so stale snapshots cannot resurrect them. Identical text saved independently is
displayed once; deletion marks all currently known aliases. Explicitly saving
the same text again creates a new addition. This is an observed-remove merge,
not wall-clock last-writer-wins, and requires no device clock synchronization.

An edit atomically updates all known text aliases, keeping their IDs and visible
slots. A logical revision increments beyond the accepted edits; a random UUID
deterministically breaks concurrent ties. Offline edits of the same phrase
converge to **one version**, regardless of arrival order or device clocks. There
is no per-edit history growth, and stale snapshots cannot restore older text.
Deletion wins against even an unseen offline edit of that same ID. An unchanged
save is a no-op; invalid/duplicate text or capacity failure leaves the old phrase
intact. A stale editor whose captured text changed reports an error instead of
silently overwriting a remote edit. Explicitly re-adding a deleted phrase still
creates a new ID.

User-defined order is a separate optional snapshot, not a mutation of an
record's original `order`. It is stored in the same library and encrypted
sync frame. Higher logical revisions win; a UUID deterministically breaks ties
between concurrent offline reorders. The next local reorder increments the
accepted revision. New, unranked phrases append; known duplicate-text aliases
move together, and tombstones still prevent resurrection. A stale or record-only
snapshot never resets an accepted order. Reordering neither changes consent nor
needs a Relay deployment.

Snapshots are atomic and bounded: at most 4,096 records including tombstones and
512 KB of encoded library JSON including ordering, leaving room for encryption/base64 within the relay's
1 MB limit. Unsupported/corrupt or over-limit data reports an error instead of
overwriting local data. Tombstones are not automatically pruned (offline peers
may still carry the deleted addition). At capacity, save/merge fails visibly.

Regression coverage: `AgentCommandMenuTests`, `QuickPhraseTests`, `QuickPhraseEditingTests`, `QuickPhraseReorderingTests`, `QuickPhraseDeviceSyncTests`,
`QuickPhraseDeviceSettingsTests` (real Mac settings load/pair/unpair), `QuickPhraseSyncTests`
(including all 16 reciprocal legacy combinations and a four-device cycle),
`QuickPhraseSyncTransportTests` (real local WebSockets with both production clients/E2EE),
`TerminalQuickActionRouterTests`, `LocalKeystrokeInputTests`, and
`KeystrokeDebouncerTests`. When manually checking the UI, cover local and remote
split panes, focus changes while a popover is open, adding/editing/deleting phrases while
offline, typing after closing the editor, and sending with an existing draft.
