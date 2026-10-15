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

Mac content areas also support two-finger trackpad swipes: swipe left for the next
tab and right for the previous tab. Each completed horizontal gesture switches
at most one tab, using the same visible order and wraparound as the keyboard.
In a split, it targets the side where the gesture began. Local, remote Viewer
and detached workspaces share this behavior. Vertical scrolling and the tab
strip's own overflow scrolling remain unchanged. Hold Option while scrolling
to use the content's existing horizontal scrolling or browser navigation instead.
Short or cancelled swipes and momentum do not switch tabs.

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
windows. Commands, Quick Phrases and the wider voice input button share a
32-point height including native padding, with their icons centered vertically;
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

On iOS, the first-row **+ / Attachments** menu owns image input (Photo Library,
image files, Camera and Paste Image); there is no duplicate image button at the
top right. In Bottom Bar mode, a single tap in an empty terminal input surface
shows/hides the keyboard; with draft text, it places the cursor and opens the
keyboard (or keeps it open), so editing can resume after hiding it. Native
Codex placeholder text is recognized as empty without adding a CtrlX placeholder.
Double-tap copy/paste remains unchanged. The legacy Top Right keyboard layout
is still selectable and keeps its explicit keyboard button.

The Quick Phrases and Commands buttons open a shared **in-page overlay**, not a system
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

Mac (Local/Viewer) and iOS use the same preview-then-insert contract. One click
starts on-device recognition; a second click on the microphone finishes
correction and inserts one literal text batch **without Return**. Partial results
stay in the local preview: they never insert or backspace text in the terminal.
Esc, cancelling the preview, switching targets, editing in the terminal,
disconnection or leaving the view cancels that recording.

Mac Local and Viewer also support **hold to talk**: hold the microphone or a
blank cell beside the current terminal prompt for 350 ms, then release to finish
and insert without Return. Shaded blank padding belonging to the prompt also
works. Native placeholder text is not replaced or covered; instructions are in
the microphone's tooltip. Ordinary clicks, double-clicks and selection drags
keep their normal behavior. Unknown prompt layouts, scrollback, marked text and
existing selections do not arm a terminal hold; the microphone remains available.
Releasing during permission preparation cancels the pending recording. iOS keeps
its existing tap-to-start/tap-to-stop interaction.

Both clients show the same compact inline strip: a stage label, at most two lines
of live text (keeping the latest end visible), and a close button. There is no
title, destination description, instruction paragraph or separate stop button.
The Mac strip overlays the terminal just above its status bar; it creates no
popover/window and does not acquire first responder. The iOS strip overlays the
terminal above its input controls; native reply fields show it below their editor.
Neither terminal overlay changes the terminal's size. The strip remains visible
during correction; cancelling it discards the recording without inserting text.
If neither corrector can run, the recognized text is still inserted once without
Return. Only after the input surface accepts it, the same strip shows
**Transcription Only**, explaining that context-aware correction was unavailable
and pointing to Voice Input settings. A rejected correction similarly identifies
that the original transcription was kept. An accepted unchanged response is not
a failure. The notice does not reopen recording, steal focus or intercept terminal
Escape; dismiss it with its close button, or start another recording to clear it.
Empty recordings (including whitespace or control-only results) skip correction
without a failure notice; native reply fields do not change the draft or report
a successful insertion. Cancelled recordings and failed insertions never claim
that uncorrected text was inserted.
Mac Escape interception is active only during recording/finalization and scoped
to the recording's native window; inactive controls and other windows keep their
normal Escape behavior. App deactivation or switching native windows cancels it.
System permission prompts during preparation are not treated as cancellation.
iOS toolbar/hardware Escape cancels active dictation before forwarding terminal
input, including when the preview belongs to the parent multi-pane view.
The result is bound to the captured Host/pane and local input revision; Mac also
checks its native endpoint/focus revision. Switching away and back does not revive
it. Delivery consumes the result before enqueueing, so duplicate completion
observers or a failed enqueue cannot retry it. Ordinary shells are supported.
Pending agent forms and external editors disable dictation into the terminal.
There is no global hotkey, clipboard replacement or extra Host/Relay command.

`CtrlxCommon` owns `VoiceInputController`, `TerminalVoiceInputSession`, the preview,
typed context snapshot, SpeechAnalyzer/legacy recognizers, vocabulary, candidate
assembly, correction prompts/policy/provider client and settings component.
Platform adapters only capture their context and enqueue the finalized text
through the existing input route. The old iOS voice shadow-document diff/rewrite
adapter is removed; the UIKit keyboard's caret synchronizer is unchanged. App-wide recording
ownership prevents two windows from racing the microphone, including asynchronous
analyzer cleanup. iOS alone configures `AVAudioSession`; Mac uses its local audio
input and declares microphone/speech usage plus the hardened-runtime audio-input
entitlement.

Both clients create a fresh `VoiceInputContextSnapshot` once at recording start:

- Pane metadata: session/window names, command and current path, from pane state.
- Terminal background: recent text from the focused buffer. The shared extractor
  copies at most 512 tail rows and preserves soft wraps. Output, history and unsent
  text can be mixed here; this is **not** an authoritative Agent draft.
- Existing input draft: supplied only by native reply fields that own the actual
  bound text. It is read-only context, never repeated or rewritten in the result.

The combined context is limited to 12,000 characters, prioritizing an actual native
draft, then metadata and recent output. This is not 12,000 characters per source.
There is no polling, full-scrollback copy, extra Host history, filesystem scan or
cache of previous dictation. A second recording may see previous unsent text in
terminal background, but CtrlX does not claim to know the remote Agent's full
current draft or changes made from another client. Local revision checks prevent
local stale insertion, not cross-device draft conflicts.

The shared vocabulary includes common Git terms such as `main`, `master`, `develop`,
`diff` and `rebase`, and adds at most eight short, deduplicated terms from the captured
session/window names and the current directory's basename. It never mines arbitrary
terminal output or scans files. Live recognition, the accurate second pass and
correction use the same per-recording vocabulary; switching sessions cannot carry
old project terms into a new recording.

Correction explicitly covers Chinese/English code-switching: for example, in a
branch-merge request, `将本地妹分支合入` can become `将本地 main 分支合入` when
pronunciation and sentence meaning agree. Vocabulary is evidence, not a replacement
dictionary: ordinary Chinese (`我妹妹`, `还没合入`), Chinese terminology (`主分支`)
and explicitly named branches must not be rewritten just because context mentions
`main`. Both provider and on-device correction use these shared instructions.
The recognizer choice is unchanged; supplying vocabulary does not guarantee speech
biasing. Apple documents `AnalysisContext.contextualStrings` for
[`DictationTranscriber`](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings).
Compare recognizers on the same recorded speech before changing their priority.

On iOS/macOS 26+, SpeechAnalyzer uses SpeechTranscriber where available, otherwise
DictationTranscriber; older systems retain on-device SFSpeechRecognizer support.
Correction tries the configured provider (if any); only an unavailable/failed
attempt falls back to the on-device model. An accepted unchanged response is still
a success. A response rejected by validation preserves the recognition result
without asking another model to rewrite it. Cancellation never starts a fallback
or delivers a late result. Terminal insertion flattens newlines and removes control
characters. Speech models may require a first-use asset download.

Correction reserves room for the complete original utterance and its output before
adding optional evidence. The on-device route uses the model's context size and,
on 26.4+, its tokenizer; 26.0–26.3 use a conservative UTF-8 byte budget. It trims
older terminal context first (retaining explicit draft/metadata when possible), then
drops optional phonetic hints. If the original cannot fit, it stays unchanged. Provider output
budgets grow with transcript size up to 8,192 tokens; oversized requests are skipped,
not shortened. Explicitly incomplete/failed provider responses are never inserted.
Legacy-budget regressions include the bundled 145-character utterance with production
vocabulary, both without context and with long terminal output; prompt changes must
leave room for the complete utterance and its response reserve.

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
The settings section separately reports provider credential readiness and
on-device correction availability, including unsupported devices, disabled Apple
Intelligence, missing models and unsupported languages. A saved key is labelled
configured, not verified; selecting a model alone does not configure correction.
These checks run on opening settings and returning to the app, without a provider
request. Runtime notices follow the actual correction outcome, not the settings
snapshot. Missing/unreadable credentials remain distinct from model availability.

Bundled model tests include mixed-language Git terms and ordinary-Chinese/branch-name
counterexamples (even with Git context), already-correct input, negation/conditions, literals,
irrelevant or instruction-like context and long utterances. Scores penalize differences
from complete reference transcripts, not just missing/incorrect keywords; unchanged
and intent-sensitive fixtures require a full match apart from punctuation, spacing
and letter case. Scores are fixture checks, not a general measure of semantic accuracy.
They evaluate the model's actual output: a rejected correction does not earn credit
for the production pipeline's safe fallback to the original draft.

The shared preview distinguishes preparation, recording, recognition finalization,
accurate on-device transcription, provider correction and on-device correction.
`VoiceInput` diagnostics record monotonic elapsed time per stage and whether final
input was enqueued, with one recording ID. Accepted corrections log whether text
changed; rejected corrections log a reason, distinct from unavailable/error cases.
New stage/outcome logs contain no audio or transcript. Enqueued means accepted by
the local FIFO, not acknowledgement that a remote Agent received the text.

Regression coverage lives in `CtrlxCommonTests/Voice*` (including injected
recognition/correction through the production controller),
`CtrlxServerFeatureTests/TerminalVoiceInputRequestTests.swift`,
`CtrlxServerFeatureTests/MacVoiceInputCancellationTests.swift` and the existing iOS
phase/input tests. `MacVoiceInputPressTests` covers prompt hit areas and preserved
mouse/selection routing. `python3 scripts/tests/test_mac_voice_input_inline.py` exercises
the production microphone/preview views and native mouse dispatch in an isolated
AppKit process with fake recognition: stable viewport/focus, no popup window,
microphone stop, narrow-layout cancel and Escape (no microphone, credentials or
real terminal input). Real microphone, permission prompts
and recognition quality remain Mac/iPhone device acceptance checks.

For device acceptance, use an isolated test session, not an active task. Test a
short utterance, a long mixed Chinese/English utterance, project names, literal
paths/ports and negation (e.g. “只检查，不要提交，除非测试通过”). Check a second
recording before sending the first, then manual edits/IME composition, target
switching, cancellation and disconnection during correction. Expect no terminal
bytes during preview and one final text insertion without Return. Compare actual
speech with the live, accurate and corrected text; bundled text-only model scores
do not measure recognition accuracy. Capture stage timings separately for cold
asset preparation, recording finalization and correction before changing timeouts.

## iOS custom input buttons

The first input row's horizontal scroll area ends with `$`, device-local custom
buttons, then **Add Button** (`＋`). Send remains pinned outside the scroll area.
All built-in first-row buttons, including Voice and Send, share a 44-point width
at the default text size and scale together with Dynamic Type. Custom buttons
keep content-sized widths; recording and loading states do not widen the row controls.
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
