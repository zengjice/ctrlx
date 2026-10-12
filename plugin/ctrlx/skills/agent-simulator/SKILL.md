---
name: agent-simulator
description: Inspect and operate iOS apps in a native iPhone Simulator embedded in the calling agent's local CtrlX session. Requires Xcode and an installed iOS runtime.
---

# CtrlX Agent Simulator

Use `ctrlx simulator` in the calling Codex's local CtrlX tmux workbench.
Authority follows the socket caller's nearest supported agent process, never an
environment token or focused tab. To start a new session from that terminal, use
`ctrlx simulator run -- codex`; it adds the required `--no-daemon` (verified with
0.162.1). It launches a new Codex, not a repair for an existing session's identity.
If caller identification or pane routing fails, report the error and provide this
terminal launch command; do not launch nested Codex or borrow another pane's identity.
Remote endpoints are rejected; Node wrappers may lack a recognizable agent executable.

Read [capabilities and limits](references/operations.md#capability-coverage) when assessing
unsupported tasks, native limitations or validation scope.

Start with `ctrlx simulator identity` and `ctrlx simulator devices`; reuse a suitable
owned device. Only when another is needed, use `inventory` to choose installed
`--runtime` / `--device-type` identifiers, then `open`. Use its CtrlX device ID below:

```sh
ctrlx simulator status --device <id>
ctrlx simulator install --device <id> --app /absolute/path/App.app
ctrlx simulator launch --device <id> --bundle com.example.app
ctrlx simulator snapshot --device <id>
ctrlx simulator tap --device <id> --x 196 --y 210
ctrlx simulator paste --device <id> --text '测试文字 🙂'
ctrlx simulator screenshot --device <id> --output /tmp/new-simulator.png
ctrlx simulator close --device <id>
```

`open` returns a CtrlX device ID, scoped to this live agent, and its UDID.
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
configuration. Test required app features in the selected profile. `metrics --device
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
