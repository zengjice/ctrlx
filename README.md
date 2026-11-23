# CtrlX

[简体中文](README_ZH.md) · [Try it on your Mac](#open-your-first-project-on-mac) · [Documentation](docs/README.md)

CtrlX is another AI coding workbench. Take your **context** with you when you switch devices, inspect a file or fork a conversation. For **long-running tasks**, let agents implement, review and revise in turn.

## Context

| Quality | What you can do |
| --- | --- |
| **Completeness** | • **Get the names right.** Dictate a branch name on iPhone and voice correction can check its spelling against your terminal. |
| | • **Show the evidence.** Send the original file with your request, or circle the line that failed in a screenshot. |
| | • **Include your acceptance criteria.** Save “Add a regression test first” as a quick phrase and reuse it with a tap. |
| **Continuity** | • **Pick up on another device.** Start on your Mac and return to the same tab on iPhone or another Mac. |
| | • **Send feedback across tools.** Mark up a file, web page or simulator screen and drop the annotation into the original conversation’s draft. |
| | • **Let another agent try an idea.** Press ⌘F in a Codex or Claude Code tab on Mac. The new agent starts with the conversation so far. Choose a new Git worktree from the Fork menu to isolate its edits. [Fork a conversation](docs/services-reference.md#fork-a-native-agent-conversation-macios) |
| | • **Call up Orbie from other apps.** Use a global Mac shortcut to pick up the discussion, or fork an Orbiter to explore a side question. [Orbie and Orbiters](docs/global-agent-design.md) |
| | • **Work with a teammate’s agent (planned).** Invite it into the same Room so your agents can test an API integration together. |
| **Recoverability** | • **Get your workspace back.** Enable workspace recovery to restore tabs, splits and unsent drafts in the CtrlX editor after your Mac restarts. |
| | • **Reopen the original conversation.** Supported Codex and Claude Code versions can resume a verified conversation automatically. If confirmation is needed, tap **Resume** on iPhone. [Workspace recovery](docs/workspace-recovery-design.md) |

## Long-running tasks

| Stage | What you can do |
| --- | --- |
| **While agents work** | • **Put your phone away.** Agents keep running on the development Mac if your phone disconnects. You can also enable **Keep this Mac awake** to prevent idle sleep. |
| **When agents need you** | • **Go straight to the decision.** Tap a question or approval notification on iPhone to open the tab that needs your answer. |
| **Workflows** | • **Start review when the implementation is ready.** A step can span several turns. Have Codex mark it complete before its final reply goes to Claude Code on the same Mac. |
| | • **Review in parallel, then revise.** Ask one agent to check the implementation and another to check the tests. Pass both reviews to the same revision step. |
| | • **Continue after a restart.** When the Mac restarts, review the results of completed steps and choose **Continue**. [Agent workflows](docs/multi-agent-design.md) |

## Product architecture

We envision a **Room** as a place for agents working on the same task. **Orbie**, your global agent, and **Workflow** both run on your own **Host Mac**. Fork an **Orbiter** from a conversation with Orbie to explore a side question. You can run a workflow directly or let Orbie control it.

![CtrlX product vision. On your Host an arrow shows Orbie controlling Workflow. In the Room the developer agent uses Codex and the test agent uses Claude Code. Lin’s review agent, Mia’s design agent and Sam’s QA agent would join the Room from their own Hosts through the Relay. Paired viewers use the same Relay. Three platform cards show iOS, macOS on another Mac and Android as a planned platform.](docs/assets/ctrlx-architecture.svg)

- **Remote control (solid lines).** Paired iOS and macOS **Viewers** connect to your Host through the **Relay** with end-to-end encryption. An Android viewer is planned.
- **Planned collaboration across Hosts (dashed lines).** Agents in a workflow currently run on the same Host. In the proposed Room, the three teammates’ agents would join through the same Relay and keep running on their owners’ Macs.

## An export button, from request to review

1. **Describe the change on Mac.** Attach a screenshot of the report and dictate “Add an Export PDF button next to the filters and keep the column order.” Check the draft and send it. [Context-aware voice input](docs/terminal-quick-actions.md#context-aware-voice-input)
2. **Try it on iPhone.** Tap the agent’s notification to return to its question and reply “Export all matching records.” In **Browser**, take over the `localhost` page the agent opened. Export the PDF and open it in **Files** from the downloads list. [Browser downloads](docs/agent-browser.md#human-downloads)
3. **Show the agent what needs fixing.** If the last column is cut off, circle it in the PDF. Use **Choose Agent** to select the original conversation, then tap **Add to Input** and send it with “Keep long headings visible.” [File annotations](docs/file-browser.md#in-place-preview-annotation) · [Browser annotations](docs/agent-browser.md#in-place-screenshot-annotation) · [Simulator annotations](docs/agent-simulator-design.md#三端截图标注)
4. **Ask another agent to check the result.** In a workflow, have Claude Code review the export against the filters and column order, then send its findings back to Codex for fixes.

## Everyday actions

- **Save some typing.** Choose `/diff` in **Commands** to inspect changes. Enable sync on both devices to share your **Quick Phrases** library. [Quick commands](docs/terminal-quick-actions.md#curated-command-catalogs) · [Phrase sync](docs/terminal-quick-actions.md#optional-device-sync)
- **Switch models or accounts.** Choose model and reasoning effort shortcuts per tab. **Dashboard** shows quota and reset times when the provider reports them. For official Codex or Claude Code accounts, **Log Out and Log In** signs out the account shared by that CLI configuration on the Host and reopens the conversation for manual sign-in. [Model shortcuts](docs/terminal-quick-actions.md#status-bar) · [Account changes](docs/services-reference.md#exit-and-resume-an-agent-macios)

## Get started

### Open your first project on Mac

Install tmux and CtrlX on an **Apple Silicon Mac running macOS 26 or later**.

```bash
brew install tmux
curl -fsSL https://ctrlx-1256844776.cos.ap-guangzhou.myqcloud.com/macos/mac.sh | bash
```

Open CtrlX to see your existing tmux sessions. An ordinary shell works on its own. To add an agent, install its CLI on that Mac, sign in and configure the integration under **Settings → Agents**. Choose **New Session → Start in Directory…** to open a project, or **+ → New Agent…** to add a tab to an existing session.

For a first request, click the microphone and ask “How do I run this project locally?” Click again to finish, then check the draft and send it.

Codex, Claude Code and Traex have built-in integrations. Plugins are available for OpenCode, pi and omp. Actions such as answering structured questions and forking depend on the agent. Published Mac packages are Developer ID signed and notarized by Apple.

### Connect an iPhone or another Mac

1. Install CtrlX on the second device. iPhone requires **iOS 18 or later** and currently uses a locally signed Xcode build. [iPhone installation](RELEASE.md#local-overwrite-installation)
2. Select the same Relay on both devices. Use `wss://ctrlx.zengjice.com:7001` or host your own. If the service requires an access key, enter it on the Host under **Settings → Relay → This Mac · Relay Traffic → Access Key**, then choose **Save Access Key**.
3. Generate a pairing code on the Host and enter it on the other device. Select the project and tab you just opened and continue typing. Keep the Host awake, online and running CtrlX while you work remotely.

For lock-screen notifications on iPhone, the Relay’s APNs settings must match the installed iOS app. [Push configuration](docs/self-hosting.md#apns)

## Privacy and open source

Both devices connect outbound to the Relay, so the Host needs no open inbound port. Only the paired devices can decrypt workspace content. A self-hosted Relay in its default open mode requires no CtrlX account or subscription. [Architecture and encryption](docs/architecture.md) · [Self-hosting guide](docs/self-hosting.md)

Agents use the AI service you configure. Optional cloud voice correction sends speech candidates and a short excerpt of terminal context directly to your chosen provider. [Voice input and shortcuts](docs/terminal-quick-actions.md)

The Mac app, iOS app and Relay are open source. [Technical documentation](docs/README.md) · [Contributing](CONTRIBUTING.md) · [Build instructions](AGENTS.md)

## License and origin

CtrlX is an independent distribution based on
[Gallager](https://github.com/gpambrozio/Gallager), with baseline commit
`919c7772928531d4d0bb266bdf275691d361901e` dated 2026-08-14. It is maintained
by ZengJice and is not affiliated with or endorsed by the Gallager project.

CtrlX is distributed under [GNU AGPL-3.0](LICENSE). Published binaries and the
hosted Relay identify their corresponding source commit; the Relay exposes
version and source information through `/version` and `/source`. See
[NOTICE.md](NOTICE.md), [MODIFICATIONS.md](MODIFICATIONS.md) and
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
