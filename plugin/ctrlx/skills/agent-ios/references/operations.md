# Agent iOS operations and capability coverage

Currently supports iOS Simulator only. Operate on your owned CtrlX device.
Observe before input and verify app effects; an acknowledgement proves submission only.
For installed commands, check
`ctrlx ios action --help`.
Requires Xcode, an installed iOS runtime and CoreSimulator 1155.4 or newer.

## Capability coverage

| Area | Supported controls |
|---|---|
| Devices | `devices` lists owned tabs. `open` reuses the pane's default only if owned by the caller; `open --new` adds an independent device. `inventory` lists runtimes/types; `open --udid` selects an exact private guest. `status` inspects; `close` shuts down, keeping data. `storage` lists private guests/bytes; `erase` resets and `delete` removes a specified idle guest. |
| Apps | `install`, `uninstall`, `launch`, `terminate`, `open-url`: install/remove apps, start/stop or deliver URLs. Install needs a simulator `.app`; launch waits for Scene activation, not page content; URLs may need confirmation. |
| Observe | `snapshot`, `wait`, `screenshot`: AX nodes/references, semantic selectors, visible/absent waits and PNG to a new path. |
| Touch | `tap`, `swipe`, `long-press`, `drag`: single-contact input and system edge gestures. `pinch`: simultaneous two-contact scaling. |
| Keys/text | `key`, `button`, `paste`: HID keys/chords; Home, lock, volume buttons; Unicode clipboard/menu paste. |
| Display | `show`, `show --split`, `rotate`, `display-mode`: local tabs/splits, orientation and presentation mode. Paired Mac/iOS Viewers can observe live Host devices and explicitly take control for touch and clipboard operations on supported Hosts. |
| Environment | `location`, `appearance`, `privacy`, `push`: fixed position, light/dark, permissions and simulated notifications. |
| Resources | `config`, `resources`, `metrics`: device limits/reserves, pressure, CPU and process footprint. |
| Diagnostics | `logs`, `crashes`: bounded device/app records. |
| Recording | `record-start`, `record-status`, `record-stop`: opt-in local silent H.264 MP4, up to 60 seconds per recording; one per owned device. |
| Ownership | `identity` checks the caller; `claim` returns control after human takeover; `batch` runs up to 16 actions. Terminal launcher `run -- codex` adds `--no-daemon` to a new Codex; it cannot repair an existing caller's identity. |

`standard` (default) and `balanced` use the same native controls and bundled
simslim for startup service preparation/checks; they are service profiles.
`--requires` retains dependencies, not proof of app behavior: test required features
in the selected profile. Compare both only when evaluating `balanced` or requested.
The default device limit is two; configuring 1...32 with
`config --max-devices` does not validate that device count.

For cleanup scope, disk usage and exact-device reuse, read [device storage](storage.md).

### Not provided

- Arbitrary multi-touch paths, two-finger rotation/pan; `pinch` only scales a horizontal pair.
- Mac marked-text composition/candidate windows: human input uses the iOS hardware-keyboard
  source; iOS Pinyin was verified. Unicode paste does not test composition or typing.
- Remote device closure, audio or video-rate streaming; physical iPhone control.
- Device cloning, runtime download/installation, app compilation/signing. Prepare
  runtimes/builds separately; physical-device `.app` builds are not accepted.

These are CtrlX interface gaps, not Apple's capability limits. Do not invent
CtrlX commands from `simctl` capabilities or claim substitutes provide equivalent coverage.

### Validation boundaries

- Human mouse dragging exists but has not completed real human acceptance; agent
  `drag` and queue tests do not validate it. `show` does not guarantee Mac foreground activation.
- Current acceptance: local Mac, iOS 27, internal 120 Hz, two devices. External 60 Hz,
  mixed 1x/2x displays, four or more devices and other Macs/toolchains/runtimes are
  not qualified. Command success does not certify performance or compatibility.
- Common UIKit/SwiftUI/WKWebView fixtures were checked, not every app/control/dialog.
  Native acceptance covers Codex. Claude Code has entrypoint/caller tests; real
  CLI/device acceptance remains separate, as does public distribution.
  Source/tests do not prove the installed signed App includes the changes.
  Unvalidated does not mean known broken. Operational/native limits follow below.

## Pane reuse and Viewer viewing

`open` reuses only your own pane default; human-created devices stay human-owned.
`--new` adds a separate owned device.
Conflicting explicit configuration fails without changing the running guest.
Closing the workbench detaches display; owner exit or explicit device close still
shuts down. Mac/iOS Viewers observe the same device through bounded JPEG previews
and can explicitly take control for touch and clipboard operations on supported
Hosts. Read [reuse, lifecycle and preview limits](viewing.md).

## Batches

`ctrlx ios batch --input /absolute/actions.json` reads UTF-8 JSON with
1...16 arrays of ordinary simulator arguments:

```json
[
  ["tap", "--device", "<id>", "--identifier", "login.submit"],
  ["wait", "--device", "<id>", "--identifier", "home.title"],
  ["screenshot", "--device", "<id>", "--output", "/tmp/new-result.png"]
]
```

One CLI process/request; normal validation, live ownership and input ordering
apply. Steps may target different owned devices. Use semantic selectors after
reference-invalidating actions; results are not interpolated. Other requests or
human takeover may interleave; the batch is not atomic.

Limits: input/prepared request each 64 KB, retained response 32 MiB, new steps
admitted for 60 s, started steps keep normal deadlines, CLI transport 310 s.
Nested batches, shell commands and per-step `--socket` are rejected. One screenshot
is allowed as the last step, to a new path.

JSON includes `success`, `planned`, `completed`, `results` and zero-based `stoppedAt`
on failure. Later steps stop; failure exits nonzero but prints JSON. No rollback
or replay; observe unknown write outcomes. `action-completed-result-omitted` means
completed but oversized result; `action-completed-artifact-failed` means completed
screenshot but failed local PNG write.

## Display modes

Devices start synchronized. On request, select low latency, which may briefly tear:

```sh
ctrlx ios display-mode --device <id> --mode low-latency
ctrlx ios display-mode --device <id> --mode synchronized
```

The tab UI and `status.displayMode` expose the same choice. It changes presentation,
not profiles, and guarantees no latency budget. Requires the agent writer; do not reclaim
automatically after human takeover.

## Element targets

`snapshot` returns observation-local `ref`, logical-point frames, native `visible`,
`visiblePoint` when available, and frontmost app identity. Prefer app identifiers:

```sh
ctrlx ios snapshot --device <id> --limit 1000
ctrlx ios tap --device <id> --ref '@<observation-id>:<node>'
ctrlx ios tap --device <id> --identifier login.submit
ctrlx ios tap --device <id> --label 'Continue' --role AXButton
```

References, semantic selectors and start coordinates are alternatives. Identifier,
label/title and role match exactly; combined selectors must all match. Writes
require one unique element with a finite native interaction point inside the
current display. Incomplete AX cannot establish uniqueness.

`partialReason`: `node-limit`, `depth-limit`, `pending-limit`, `deadline` or
`device-response`; `observationError` describes errors. Poll partial trees read-only
within a deadline before asserting absence, uniqueness or secure-field privacy.
Missing secure fields prove nothing. Self-drawn Canvas/game content may omit AX:
inspect screenshots and use fresh coordinates. AX and screenshots are not atomic.

Element writes refresh AX. Only `--ref` also checks the previous app process,
geometry and control generation. An identifier-backed ref can survive movement/label
changes, but not app switches, rotation or takeover. `--identifier`, `--label` and
`--role` query current AX without that prior binding; confirm the current app/page.
All writes require the current writer. Missing/ambiguous targets and stale refs
fail before input. Re-observe after actions/navigation; node indices are not persistent.
Retry only when the error proves no input was sent, with a fresh target; never replay
an unknown write.

## Gestures and recording

See [gestures](gestures.md) for long press, drag, edge swipes and basic `pinch`.
See [recording](recording.md) for MP4 start/stop, readiness, limits and cleanup.

## Keyboard and selection

`key` presses/releases to the focused iOS responder; optional modifiers are held
for that operation, then released in reverse order:

```sh
ctrlx ios key --device <id> --usage 4 --modifiers command
ctrlx ios key --device <id> --usage 80 --modifiers shift
ctrlx ios key --device <id> --usage 42
```

These are A, left arrow, Backspace. `--modifiers`: comma-separated `control`, `shift`,
`alt`, `command`, each once. Modified usage 4...223; unmodified 4...231. Invalid
chords fail before input. Takeover/failure releases held input. Verify text/selection:
shortcuts depend on responder and iOS layout. Use paste for arbitrary Unicode.

Paste permission can precede its buttons: wait for a fresh, unique, actionable
button, select once and verify the pending paste; do not resend it. Native editing
may adjust spaces/selection.

On tested iOS 27, emoji Backspace in secure fields can leave half a UTF-16 surrogate
pair even with native deletion. For a known whole value: focus, Command+A (usage 4),
paste its replacement once; clear by deleting the full selection. Verify app effects
or test instrumentation; AX omits secure values.

## Targeted menu paste

```sh
ctrlx ios paste --device <id> --via-menu --identifier login.name --text '测试文字 🙂'
```

Alternatively use `--ref '@<observation-id>:<node>'` or `--x 196 --y 414`.
This focuses the target, writes the simulator clipboard once, long-presses, then
touches a unique Paste item from fresh, complete AX. Long press may change caret/
selection; insertion-point preservation is not guaranteed. Semantic targets need
AXTextField/AXTextArea; others fail before focus/clipboard input. Use coordinates
if AX omits the field. Menu observation failure reports no Paste tap sent, without
keyboard fallback or replay. Verify app/text effects and handle iOS paste permission
from a fresh observation.

## Rotation

```sh
ctrlx ios rotate --device <id> --orientation landscape-left
ctrlx ios rotate --device <id> --orientation portrait
```

Also accepts `portrait-upside-down` and `landscape-right`. Waits for geometry change;
app orientation locks can reject the result. Refresh observations/dimensions after
rotation: previous refs and coordinate assumptions are stale.

## State waits

```sh
ctrlx ios wait --device <id> --identifier loading.indicator \
  --state absent --timeout-ms 10000
ctrlx ios wait --device <id> --label 'Welcome' --state visible --timeout-ms 5000
```

Use semantic selectors, not refs. Defaults: `visible`, 5000 ms; timeout 1...60000 ms.
Wait polls fresh AX without input. `visible` needs native visibility and a frame
intersecting the display; missing metadata proves nothing. Visibility does not
prove enabled/actionable or actually drawn custom content. `absent` needs a
complete tree with no match; partial/failed reads cannot prove absence. Use
screenshots for content omitted from AX.

## Simulator environment

```sh
ctrlx ios location --device <id> --latitude 37.3349 --longitude -122.009
ctrlx ios location --device <id> --clear
ctrlx ios appearance --device <id> --style dark
ctrlx ios appearance --device <id>
ctrlx ios privacy --device <id> --action grant --service location --bundle com.example.app
ctrlx ios push --device <id> --bundle com.example.app --payload /absolute/payload.json
```

Location is fixed; `--clear` stops simulation but the app may retain its last
position: check subsequent callbacks. Appearance accepts light/dark and returns
observed style. Close does not restore location, style or permissions; restore
explicitly when required.

Privacy accepts grant/revoke/reset and requires one app bundle even for service
`all`. Some changes terminate apps; relaunch and verify. Services: calendar,
contacts/contacts-limited, location/location-always, photos/photos-add, media-library,
microphone, motion, reminders, siri, all; availability depends on installed Xcode.
Push accepts UTF-8 JSON with an `aps` object, at most 4096 bytes. Explicit bundle
overrides payload targeting. Success means simulator submission, not delivery
or real APNs: inspect effects. Writes need the current writer; takeover requires
explicit `claim` before further writes. Timeouts never trigger write retries.

## App diagnostics

```sh
ctrlx ios logs --device <id> --bundle com.example.app --last-seconds 30 --max-bytes 65536
ctrlx ios crashes --device <id> --bundle com.example.app --last-seconds 3600 --limit 5
```

Logs match installed Mach-O image UUID within this device's paths, including
info/debug. Original container spelling preserves matches to logging's old paths
after reinstall; different builds are excluded. Only complete matching JSON records
return. Range 1...300 s; per-stream tail 1...262144 bytes (default 65536); deadline
15 s, no continuous stream. `truncated` marks incomplete results; tiny caps may
omit every record.

Crashes inspect device IPS and Mac DiagnosticReports with matching bundle metadata;
host reports also need simulator platform and exact device coalition, even with
redacted paths. Range 1...86400 s, 1...10 reports (default 5); text shares the byte
cap. Inspect at most 128 newest headers, with a separate 1 MiB host inspection cap.
Unverifiable reports are skipped and mark truncation. Empty/truncated results do
not prove no crash. Both queries are read-only, owner-scoped and do not claim control.
