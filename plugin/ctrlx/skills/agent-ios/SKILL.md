---
name: agent-ios
description: Default for live iOS Simulator UI, screenshots and bug reproduction via ctrlx ios in local CtrlX Codex/Claude Code sessions. Not physical devices, Mac UI or compile-only tasks.
---

# Default iOS Simulator entry point

For live iOS Simulator UI work in a local CtrlX Codex/Claude Code session, use `ctrlx ios`
first, even when the user does not name this skill. Choose its native observation
and input before Simulator.app desktop automation, raw `simctl`, or another iOS
automation tool. The device appears in the calling agent's CtrlX workbench.

Keep the user's explicitly chosen tool, device or test harness. Physical iPhones,
Mac UI, app compilation/signing and existing automated test suites keep their
own workflows. Source edits or analysis of an attached image alone do not require
starting a simulator. This default does not authorize installing tools or changing
the task's target.

When live Simulator work is needed, read [workflow](references/workflow.md) before
operating a device. Start with `ctrlx ios identity` and `ctrlx ios devices`, then
reuse an owned device or use `open` for an Agent-owned pane default. Requires Xcode and an
installed iOS runtime. Read [capabilities and limits](references/operations.md#capability-coverage)
before choosing controls outside the basic workflow.

If the CLI, runtime or caller identity is unavailable, report the actual blocker;
do not silently switch to another device or borrow another pane's identity.
Codex uses `ctrlx ios run -- codex` for a new session; native Claude Code runs
directly as `claude` in the CtrlX terminal. Never launch a nested agent to repair
the current session. Observe before input, verify visible results, and respect
human takeover as described in the workflow.
