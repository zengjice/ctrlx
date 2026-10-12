---
name: agent-simulator
description: Inspect and operate iOS apps in a native iPhone Simulator embedded in the calling agent's local CtrlX session. Requires Xcode and an installed iOS runtime.
---

# CtrlX Agent Simulator

Use `ctrlx simulator` in the calling agent's local CtrlX tmux workbench.
This workflow targets Codex. Authority uses the socket caller's nearest supported
agent process, never an environment token or focused tab. Pane-local Codex works
directly. Use `ctrlx simulator run -- codex` to keep tools in the source terminal.
It executes Codex with `--no-daemon` (verified with 0.162.1).
This flag is required; remote endpoints are rejected. Node wrappers may lack
a recognizable agent executable.

```sh
ctrlx simulator inventory
ctrlx simulator open
ctrlx simulator devices
ctrlx simulator status --device <device-id>
ctrlx simulator install --device <id> --app /absolute/path/App.app
ctrlx simulator launch --device <id> --bundle com.example.app
ctrlx simulator snapshot --device <id>
ctrlx simulator tap --device <id> --x 196 --y 210
ctrlx simulator swipe --device <id> --x 196 --y 650 --end-x 196 --end-y 250
ctrlx simulator key --device <id> --usage 40
ctrlx simulator paste --device <id> --text '测试文字 🙂'
ctrlx simulator paste --device <id> --via-menu --identifier login.name --text '测试文字 🙂'
ctrlx simulator button --device <id> --button home
ctrlx simulator screenshot --device <id> --output /tmp/new-simulator.png
ctrlx simulator close --device <id>
```

`open` returns a CtrlX device ID, scoped to this live agent, and its UDID.
Choose installed `--runtime` and `--device-type` identifiers from `inventory`.
CtrlX has a private device set and defaults to two open devices; change the limit
with `config --max-devices 8`. `resources` reports pressure, reclaimable memory,
swap and free disk. Boot requires normal pressure and the configured reserves.
`close`, agent exit or ten hidden idle minutes shuts down the device, keeping data.
`open` reuses a shut-down device of the same runtime/type or creates one.
Reuse preserves apps/data but assigns a new CtrlX ID and live owner.

`show --device <id>` selects an owned tab; add `--split` to place it in the right
pane. Repeating `--split` preserves that placement.

`open --profile balanced` applies a fixed service profile before connecting the
worker. The default is `standard`. Declare required features with `--requires
push,storekit,widgets,siri`; CtrlX keeps their dependencies and verifies service
configuration. Feature checks do not replace actual app tests. `metrics --device
<id>` reports this simulator's process-tree footprint and CPU plus system resources.

Read a fresh snapshot or screenshot before coordinate input. Gestures check
device geometry and reject rotation during input. Coordinates and AX frames use
logical points from the screen's top-left, excluding the letterbox. Re-read after
navigation, rotation or app changes. Node indices apply to one observation.
A partial tree cannot prove absence, uniqueness or secure-field privacy.

For visual inspection, open the saved PNG with your image viewer.
Writing PNG or reading AX does not prove you saw it. Report unavailable image viewing.

`key` uses USB HID: Return 40, Backspace 42, Tab 43, Space 44, arrows 79–82.
`paste` writes the simulator clipboard and sends Command+V. Verify the field:
controls or keyboard settings can block paste. This does not test per-character
typing or IME composition. Snapshots omit secure values.
For `paste --via-menu`, caret movement and iOS 27 secure emoji editing, read operations.
Human keyboard input uses the iOS hardware-keyboard source; iOS Pinyin was verified.
Mac marked-text composition and its candidate window are not integrated.

Human touch or keyboard input takes control immediately and cancels agent input.
If asked to continue, `ctrlx simulator claim --device <id>` explicitly returns
the writer to the agent. Do not automatically claim after a human takeover.

Screenshots require a new path; install requires a simulator `.app`.
`terminate --bundle` stops an app. `open-url --url` returns acceptance only:
iOS may ask to open the target app. Inspect the prompt, confirm the intended app,
then verify delivery; do not resend while confirmation is pending. After opening,
wait for the app's content; AX may be partial during the transition.
`launch --bundle` waits for native Scene activation, up to 30 seconds by default
(`--timeout-ms 1...60000`). Timeout can follow a successful launch: observe before
acting. Timed-out writes are never retried automatically.

Current native transport requires CoreSimulator 1155.4 or newer. Simulator
display/input do not use screen recording, desktop mouse automation or a Relay.
Read [operations](references/operations.md) for targets, gestures and environment commands. Verify effects.
`batch --input actions.json` runs up to 16 actions; see operations.
