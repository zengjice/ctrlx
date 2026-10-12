# Elements, gestures and state waits

Use these operations after installing and launching the app on your owned
CtrlX device. Read current state before selecting a target and verify the
resulting app behavior. An input acknowledgement proves submission only.

## Batches

Write a UTF-8 JSON file containing 1...16 arrays of ordinary simulator arguments
and run `ctrlx simulator batch --input /absolute/path/actions.json`. For example:

```json
[
  ["tap", "--device", "<id>", "--identifier", "login.submit"],
  ["wait", "--device", "<id>", "--identifier", "home.title", "--timeout-ms", "5000"],
  ["snapshot", "--device", "<id>"],
  ["screenshot", "--device", "<id>", "--output", "/tmp/new-result.png"]
]
```

One CLI process sends one socket request. Every entry uses the same validation,
live process ownership and per-device input queue as an individual command.
Use semantic selectors when earlier actions invalidate observation references;
there is no interpolation from previous results. Entries can target different
owned devices and execute in order. This is not an atomic transaction: other
requests or human input may interleave, and human takeover still cancels writes.

The input and prepared request are each limited to 64 KB, the retained response
to 32 MiB. The host stops admitting new actions after 60 seconds; an already
started action keeps its ordinary deadline. The CLI transport limit is 310
seconds. Nested batches, arbitrary shell commands and per-entry `--socket` are
rejected. One screenshot is allowed as the final entry, using a new output path.

The JSON result includes `success`, `planned`, `completed`, ordered `results`
and, on failure, a zero-based `stoppedAt`. Each attempted entry retains its
result or error; later entries do not run after a failure. Failed batches exit
nonzero while still printing these results. Nothing rolls back or automatically
replays. A timeout can leave the last action's effect unknown: observe the app
before continuing. `action-completed-result-omitted` means the action completed
but its result exceeded the size limit; `action-completed-artifact-failed` means
the final screenshot action completed but its local PNG could not be written.

## Display modes

Each new device uses synchronized display. When the user requests it, opt this
device into low latency, which may show brief screen tearing:

```sh
ctrlx simulator display-mode --device <id> --mode low-latency
ctrlx simulator display-mode --device <id> --mode synchronized
```

`status` reports `displayMode`; the same choice is available in the simulator
tab. This changes presentation only, leaves the service profile intact, and
does not promise a particular latency. Agent changes require its active writer;
do not reclaim control automatically after a human takeover.

## Element targets

`snapshot` returns observation-local `ref` strings, logical-point frames,
native `visible` flags and `visiblePoint` coordinates when available, and
the actual frontmost application identity. Prefer an app-provided accessibility
identifier. The following targets are alternatives:

```sh
ctrlx simulator snapshot --device <id> --limit 1000
ctrlx simulator tap --device <id> --ref '@<observation-id>:<node>'
ctrlx simulator tap --device <id> --identifier login.submit
ctrlx simulator tap --device <id> --label 'Continue' --role AXButton
```

Do not combine a reference with semantic selectors, or any element target with
start coordinates. Identifier, label and role selectors match exactly; when
combined, all must match. Label can match the AX label or title. A write requires
exactly one matching element with a finite native interaction point within the current display.
An incomplete AX tree cannot establish uniqueness.
When present, `partialReason` distinguishes `node-limit`, `depth-limit`,
`pending-limit`, `deadline`, and `device-response`. `observationError` gives the
underlying device response error. Inspect a fresh observation before input.

For a partial tree, poll read-only snapshots within a bounded deadline before
asserting uniqueness, absence or secure-field privacy. Missing secure fields
prove nothing. Repeat a rejected write only when its error proves no input was
sent, using a fresh target; never replay a write whose effect is unknown.

Before an element write, CtrlX reads a fresh AX tree. A reference also requires
the same app process identity, geometry and control generation. Identifiers
can survive an element moving or its label changing, but not a switch to
another app, rotation or human takeover. Missing, ambiguous or stale targets
fail before sending input. Take a new snapshot after an action or navigation;
many writes invalidate the previous observation. Node indices alone are not
persistent targets. Avoid repeatedly clicking after a timeout: the first
physical input may already have affected the app.

## Long press and drag

```sh
ctrlx simulator long-press --device <id> --identifier message.row --duration-ms 700
ctrlx simulator drag --device <id> --identifier draggable.item \
  --end-x 260 --end-y 500 --hold-ms 500 --duration-ms 300
ctrlx simulator swipe --device <id> --x 196 --y 650 \
  --end-x 196 --end-y 250 --duration-ms 350
```

Tap holds down for 20 ms by default. Long press holds down at the target for 650 ms by default. Drag holds for
500 ms, then moves over 300 ms by default. `--duration-ms` accepts 20...5000;
`--hold-ms` accepts 0...5000. Drag end coordinates and all coordinate targets
use logical points from the device's top-left, excluding the letterbox.
Swipe uses coordinate targets. Human input cancels an agent gesture and revokes
its writer; reclaim only when the user asks you to continue.

For a system edge gesture, explicitly add `--edge top|left|bottom|right` to
`swipe`. The edge names the gesture's origin on the current displayed screen;
start one logical point inside that edge and move inward. For example, on a
393 × 852 point display:

```sh
ctrlx simulator swipe --device <id> --edge bottom --x 196.5 --y 851 \
  --end-x 196.5 --end-y 383.4 --duration-ms 300
```

Read the current geometry before choosing coordinates. Rotation transforms both
the contacts and their origin edge. Verify navigation from a fresh snapshot;
the app and iOS decide how to handle the gesture.

## Keyboard and selection

`key` sends one complete press and release to the focused iOS responder. Optional
modifiers are held within that operation and released in reverse order:

```sh
ctrlx simulator key --device <id> --usage 4 --modifiers command
ctrlx simulator key --device <id> --usage 80 --modifiers shift
ctrlx simulator key --device <id> --usage 42
```

These usages are A, left arrow and backspace. `--modifiers` accepts a comma-separated
list of `control`, `shift`, `alt`, `command`, each at most once. A modified key uses
usage 4...223; an unmodified key retains 4...231. Invalid chords fail before input.
Human takeover or a failed operation releases held input using the existing cancel
path. Shortcut behavior depends on the focused app and iOS keyboard layout; verify
the resulting text and selection. Key acknowledgement does not prove that an app
handled the shortcut. Use explicit paste for arbitrary Unicode text.

iOS paste permission can appear before its buttons. Observe until the actual
button is actionable, select it once from a fresh, unique target, then verify
the original pending paste. Do not resend paste while waiting. Native controls
may adjust spaces automatically; verify the app's editing policy and selection.

On the tested iOS 27 runtime, Backspace after pasting emoji into a secure field
can leave half a UTF-16 surrogate pair, even with native deletion. To edit a known
whole value, focus the field, send Command+A (usage 4), then paste the replacement
once. To clear it, delete the full selection. Verify through app behavior or test
instrumentation; snapshots omit secure values.

## Targeted menu paste

```sh
ctrlx simulator paste --device <id> --via-menu --identifier login.name --text '测试文字 🙂'
ctrlx simulator paste --device <id> --via-menu --ref '@<observation-id>:<node>' --text 'text'
ctrlx simulator paste --device <id> --via-menu --x 196 --y 414 --text 'Web text'
```

This operation focuses the explicit target, writes the simulator clipboard once,
long-presses the current target and taps a unique Paste item from a fresh, complete
AX tree. It uses device touch input. Long press may move the caret or change the
selection. Semantic targets must have AXTextField or AXTextArea roles; other roles
are rejected before focus and clipboard input. Use coordinates when AX omits the
editable field. A menu observation failure reports that no Paste tap was sent.
This is not a promise to preserve an existing insertion point.
An acknowledgement reports submission; verify the resulting text and app behavior,
and handle any iOS paste permission prompt from a fresh observation. A missing or
ambiguous menu fails without keyboard fallback or input replay.

## Rotation

```sh
ctrlx simulator rotate --device <id> --orientation landscape-left
ctrlx simulator rotate --device <id> --orientation portrait
```

Allowed orientations are `portrait`, `portrait-upside-down`, `landscape-left`
and `landscape-right`. The operation waits for reported geometry to change;
an app that locks orientation can reject the requested result. Read a fresh
snapshot after rotation and use the new dimensions. Previous references and
coordinate assumptions are stale.

## State waits

```sh
ctrlx simulator wait --device <id> --identifier loading.indicator \
  --state absent --timeout-ms 10000
ctrlx simulator wait --device <id> --label 'Welcome' \
  --state visible --timeout-ms 5000
```

Wait uses semantic selectors, not references. The default state is `visible`
and the default timeout is 5000 ms, with a supported range of 1...60000 ms.
It polls fresh AX observations without physical writes. `visible` requires a
matching element whose native AX visibility is true and whose frame intersects
the display. Missing native visibility metadata cannot prove visibility.
This AX state does not prove that the element is enabled, has a usable interaction
point, or is actually drawn by a custom renderer. `absent` requires a complete tree with no matching element;
partial trees and failed observations never prove absence. Use screenshots
for content the app does not expose to accessibility.

Performance budgets and untested toolchain versions must not be inferred from
command success. Test the project's required features with both service profiles.
## Simulator environment

```sh
ctrlx simulator location --device <id> --latitude 37.3349 --longitude -122.009
ctrlx simulator location --device <id> --clear
ctrlx simulator appearance --device <id> --style dark
ctrlx simulator appearance --device <id>
ctrlx simulator privacy --device <id> --action grant --service location --bundle com.example.app
ctrlx simulator privacy --device <id> --action reset --service location --bundle com.example.app
ctrlx simulator push --device <id> --bundle com.example.app --payload /absolute/payload.json
```

Coordinates set a fixed simulated location; `--clear` stops location simulation.
Appearance accepts light/dark and returns the observed style. CtrlX does not
restore environment settings on close; clear location and restore appearance
and permissions explicitly. A last-known coordinate can remain in the app after
clear, so verify subsequent location callbacks rather than an unchanged label.
Privacy accepts grant/revoke/reset and always requires one app bundle, including
`--service all`. Some permission changes terminate the app; launch it explicitly
afterward and verify the result. Supported services are those exposed by the
installed Xcode: calendar, contacts/contacts-limited, location/location-always,
photos/photos-add, media-library, microphone, motion, reminders, siri and all.
Push reads a UTF-8 JSON object containing an `aps` object, at most 4096 bytes.
The explicit bundle overrides any payload target. A successful reply confirms
simulator submission; verify delivery in the app. It does not test real APNs.
All environment commands use the device's existing writer ownership. A human
takeover requires explicit `claim` before another agent write. Timeouts never
trigger automatic write retries.

## App diagnostics

```sh
ctrlx simulator logs --device <id> --bundle com.example.app --last-seconds 30 --max-bytes 65536
ctrlx simulator crashes --device <id> --bundle com.example.app --last-seconds 3600 --limit 5
```

Logs query the installed app's Mach-O image identity within this device's paths,
including info and debug messages. This survives unified logging retaining an old
container path after reinstall. Logs from a different executable build are not
included. The query preserves the container's original path spelling; complete
JSON records are checked against its image UUID before messages are returned.
The time window is 1...300 seconds; each output stream retains the most recent
at most 1...262144 bytes (default 65536). The query has a 15-second deadline and
does not start a continuous stream. `truncated` means the result is incomplete.
An incomplete JSON record is omitted, so a very small byte cap may return no messages.
Crashes read this device's IPS reports and the Mac's DiagnosticReports directory.
Both require matching bundle metadata; host reports also require simulator
platform metadata and this device's exact coalition name, even if paths are redacted.
They accept 1...86400 seconds and 1...10 reports; all report text shares the byte
budget. The newest 128 report headers are inspected. Host scope inspection shares
a separate 1 MiB budget; reports that cannot be fully checked within it are skipped
and mark the result truncated. Empty results do not prove
that the app never crashed; a truncated result cannot prove report absence.
Both operations are read-only, remain owner-scoped and do not claim human control.
