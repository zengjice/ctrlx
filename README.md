# CtrlX

[简体中文](README_ZH.md) · [Feature list](#feature-list) · [Try it on your Mac](#open-your-first-project-on-mac) · [Documentation](docs/README.md)

CtrlX is an AI workbench where you can use Codex, Claude Code, Traex and other agents side by side on your Mac. Switch to your iPhone or another Mac and pick up the same session while the work keeps running on the original Mac. Need to look up a term while writing an email? A keyboard shortcut brings up Orbie, your Mac’s global agent. We also plan to let agents on your teammates’ Macs join your projects.

## Already using Codex or Claude Code? Try these four things

- **Have Codex build and Claude Code review.** In the **Develop, review and repair…** workflow template, choose a Codex tab and a Claude Code tab on the same Mac. When Codex marks its step complete, Claude Code reviews the change. Its findings go straight back to the original Codex conversation. [Try the template](docs/multi-agent-design.md#developer--reviewer先开发再评审判断修复)
- **Try another provider on a side task.** Press ⌘F in a Codex or Claude Code tab on Mac. Under **Target Provider**, choose another provider you’ve configured for the same CLI. The new agent can investigate a bug with the conversation so far while you keep working in the original tab.
- **Test the change yourself on iPhone.** Take control of the `localhost` page or iOS simulator the agent opened on your Mac and tap the button it just changed. If the button is in the wrong place, circle it in a screenshot and send it back to the same conversation. [Walk through an example](#add-an-export-button-to-a-report)
- **Check both accounts’ quotas in one place.** The Dashboard shows the remaining quotas and reset times reported by Codex and Claude Code. If your home and office Macs share a quota, it appears only once.

## Context that carries over

| What you can do |
| --- |
| **Dictate with project context.** Even when you mix Chinese and English, CtrlX can use the project name and terminal output to help spell branch names and filenames correctly. |
| **Show the agent what you see.** Circle a problem in a file preview, web page or simulator and send the marked-up image back to the original conversation. |
| **Switch devices mid-task.** Open the same terminal tab from your iPhone or another Mac to type a command or answer the agent. |
| **Fork a side task.** When another feature or a bug needs attention, fork an agent from the current conversation. It starts with the project context you’ve already given it, and you can carry on in the original tab. |
| **Work with a teammate’s agent (planned).** Your development agent and a teammate’s test agent could join the same Room to test an API together, each running on its own Mac. |

## Keep long-running tasks on track

| What you can do |
| --- |
| **Turn a process you trust into a workflow.** Lay out the steps yourself or design them with Orbie. Before you start, you decide which agent owns each step, what it should deliver and when to hand it over. |
| **Hand work over when it’s ready.** For example, once Codex marks development complete, one agent reviews the implementation and another checks the tests. The workflow waits for both reviews before sending the findings back to Codex for fixes. |
| **Let a task run overnight.** Agents keep working on your Mac when your iPhone disconnects. Enable **Keep this Mac awake** for an overnight run. |
| **Respond to questions and approval requests.** When an agent needs your input, tap its iPhone notification to go straight to that tab. |
| **Continue after a restart.** After your Mac restarts, check the results of completed steps and choose **Continue** to resume the workflow. [Agent workflows](docs/multi-agent-design.md) |

## Product architecture

**Orbie**, your global agent, and **Workflow** both run on your own **Host Mac**. Fork an **Orbiter** from a conversation with Orbie to handle a side task, or ask Orbie how a related workflow is going. Today you confirm the assignments and start the run in Workflow. The arrow from Orbie to Workflow shows our plan to let Orbie control workflows directly.

![CtrlX product vision. Orbie and Workflow run on your Host. The arrow between them shows planned direct control by Orbie. In the Room, the development agent uses Codex and the test agent uses Claude Code. Agents on Lin’s, Mia’s and Sam’s Macs would join through the Relay. Paired iPhones and Macs also connect through the Relay. An Android Viewer is planned.](docs/assets/ctrlx-architecture.svg)

- **Remote control.** Paired iOS and macOS **Viewers** connect to your Host through the **Relay** with end-to-end encryption. An Android Viewer is planned.
- **Collaboration across Hosts.** Today the agents in a workflow run on the same Host. The planned **Room** would bring together agents working on the same task. Teammates’ agents could join through the Relay and keep running on their own Macs.

## Add an export button to a report

1. **Describe the change on Mac.** Attach a screenshot of the report and dictate “Add an Export PDF button next to the filters and keep the column order.” Check the draft and send it. [Context-aware voice input](docs/terminal-quick-actions.md#context-aware-voice-input)
2. **Try the export on iPhone.** Tap the agent’s question notification and reply “Export all records that match the filters.” In **Browser**, take over the `localhost` page the agent opened. Export the PDF and open it in **Files** from the downloads list. [Browser downloads](docs/agent-browser.md#human-downloads)
3. **Show the original agent what needs fixing.** The long heading on the last column is cut off. Circle it in the PDF, add the marked-up image to the agent’s draft and send it with “Please show the full column heading.” [File annotations](docs/file-browser.md#in-place-preview-annotation)
4. **Verify the fix.** In a workflow, have Claude Code review the filters and column order, then send its findings back to Codex for fixes. Export the report again on your iPhone. Check that the records match the filters, the full heading is visible and the columns are in the right order.

## Get started

### Open your first project on Mac

Install tmux and CtrlX on an **Apple Silicon Mac running macOS 26 or later**.

```bash
brew install tmux
curl -fsSL https://ctrlx-1256844776.cos.ap-guangzhou.myqcloud.com/macos/mac.sh | bash
```

Open CtrlX to see your existing tmux sessions. You can start with just a terminal. To use an agent, install its CLI on that Mac, sign in and configure the integration under **Settings → Agents**. Choose **New Session → Start in Directory…** to open a project, or **+ → New Agent…** to add a tab to an existing session.

For a first request, click the microphone and ask “How do I run this project locally?” Click again to finish, then check the draft and send it.

Codex, Claude Code and Traex have built-in integrations. Plugins are available for OpenCode, pi and omp. Actions such as answering structured questions and forking depend on the agent. Published Mac packages are Developer ID signed and notarized by Apple.

### Connect an iPhone or another Mac

1. **Install the Viewer.** Install CtrlX on another Mac or on an iPhone running **iOS 18 or later**.
2. **Choose the same Relay.** On both devices, select the hosted Relay at `wss://ctrlx.zengjice.com:7001` or enter the address of your own Relay.
3. **Enter the pairing code.** Generate a code on the Mac running your agents (the Host) and enter it on the Viewer. Open the original session to pick up where you left off.

If you already have a CtrlX IPA signed for your iPhone, connect the phone to your Mac over USB and choose **File → Install IPA on iPhone…** in CtrlX on the Mac. You can also build and sign the app locally with Xcode. [Local installation](RELEASE.md#local-overwrite-installation)

Keep the Host awake, online and running CtrlX while you work remotely. If your Relay requires an access key, save it under **Settings → Relay** on the Host. To send iPhone push notifications through a self-hosted Relay, configure APNs. [Relay access keys](docs/self-hosting.md#optional-account-authentication-and-traffic-quotas) · [Push notifications](docs/self-hosting.md#apns)

## Privacy and open source

Both devices connect outbound to the Relay, so the Host needs no open inbound port. Only the paired devices can decrypt workspace content. A self-hosted Relay in its default open mode requires no CtrlX account or subscription. [Architecture and encryption](docs/architecture.md) · [Self-hosting guide](docs/self-hosting.md)

Agents use the AI service you configure. If you enable cloud dictation correction, CtrlX sends candidate transcriptions and a short excerpt from the current terminal directly to your chosen service. [Voice input and shortcuts](docs/terminal-quick-actions.md)

The Mac app, iOS app and Relay are open source. [Technical documentation](docs/README.md) · [Contributing](CONTRIBUTING.md) · [Build instructions](AGENTS.md)

## License and origin

CtrlX is an independent distribution based on
[Gallager](https://github.com/gpambrozio/Gallager), with baseline commit
`919c7772928531d4d0bb266bdf275691d361901e` dated 2026-08-14. It is maintained
by ZengJice and is not affiliated with or endorsed by the Gallager project.

CtrlX is distributed under [GNU AGPL-3.0](LICENSE). Published binaries and the
hosted Relay identify their corresponding source commit. The Relay exposes
version and source information through `/version` and `/source`. See
[NOTICE.md](NOTICE.md), [MODIFICATIONS.md](MODIFICATIONS.md) and
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Feature list

| Area | Feature | What you can do |
| --- | --- | --- |
| **Workspace** | Project terminals | Open a terminal in your project directory or pick up an existing tmux session on your Mac. |
| | Agent integrations | Use Codex, Claude Code and Traex in the same project, or add OpenCode, pi and omp through plugins. |
| | Tabs and splits | Group an agent with its tool tabs and put the terminal beside the result you’re checking. |
| | Cross-device access | Return to the same tab on iPhone or another Mac while the agent keeps running on the Host between connections. |
| | Workspace recovery | Enable recovery to get your tabs, splits and CtrlX editor drafts back after a Mac restart. |
| | Conversation recovery | Supported Codex and Claude Code versions can resume verified conversations automatically, or you can choose **Resume** in the recovery panel. |
| **Input and feedback** | Context-aware dictation | Let voice correction check branch names and paths against your terminal, then review the draft before sending. |
| | Prompt editor | Press Ctrl-G in Codex or Claude Code to compose a multiline request in your configured editor and return it to the terminal. |
| | Quick commands | Pick a command from the current agent’s menu, such as `/diff` in Codex to inspect changes. |
| | Quick phrases | Insert a saved instruction with a tap, and share your phrase library by enabling sync on both paired devices. |
| | Custom iPhone keys | Put frequently used text or keys such as Tab and Ctrl-C above the terminal keyboard. |
| | iPhone share sheet | Share from another app, then add photos to the chosen agent’s draft or upload files to the current Files folder. |
| | Remote clipboard | Copy text or images from Host files to your device, or paste an image from your clipboard into a Host folder. |
| | Screenshot annotations | Mark a problem in a file preview, web page or simulator and add the image to the agent draft you choose. |
| **Working with agents** | Orbie, your global agent | Enable Orbie on your Mac and set a shortcut in **Settings → General → Orbie** to open the same conversation from any Mac app. |
| | Orbiters | Fork an Orbiter from your conversation with Orbie so it can handle a side task independently with the context you’ve already shared. |
| | Quick Fork | Press ⌘F in a Codex or Claude Code tab on Mac to fork a conversation in the current directory. To keep the two tasks’ code changes separate, create a Git worktree from the Fork menu. |
| | Model and reasoning effort | On supported agent tabs, put your preferred models and effort levels in the status bar and switch between them when the agent is idle. |
| | Account switching | With an official Codex or Claude Code account, sign out of the account shared by that CLI configuration on the Host and reopen the conversation to sign in manually. |
| **Long-running tasks** | Workflows | Save a workflow to use again. Agents on the same Mac follow the roles and handoff conditions you set. |
| | Workflow recovery | After a Host restart, inspect the completed steps and choose **Continue** to pick up the run. |
| | Questions and approvals | Tap an iPhone lock-screen notification to open the agent tab waiting for your answer. |
| | Usage and quotas | Check Host resource usage in the Dashboard alongside account quotas and reset times reported by the provider. |
| | Keep Mac awake | Prevent the Host from falling asleep due to inactivity during a long run. |
| **Inspecting results** | Files | Browse, search and transfer Host files, follow links in Markdown previews, or play a video. |
| | Terminal file links | Open a file link in agent output to preview an image, a Markdown document or a Mermaid diagram. |
| | Git changes | Inspect file diffs in the Mac Git tab and see how many commits each worktree has yet to merge into the local main branch. |
| | Host browser | Use the Host’s Chromium from a paired device to open `localhost`, hear page audio and download files. |
| | iOS Simulator | See and operate the Mac’s simulator from a paired device, or ask an agent to record the steps that reproduce a bug. |
| | Shared tool control | Take over a web page or simulator, then hand control back to the agent when you’re done. |
| | Install on iPhone | Pick a local IPA on your Mac and install it on a USB-connected iPhone. |
| **Connection and privacy** | Encrypted pairing and self-hosting | Connect devices with end-to-end encryption over a hosted or self-hosted Relay without opening inbound ports on the Host. |
| **Planned** | Cross-user Rooms | Invite a teammate’s agent into the same Room while each agent runs on its owner’s Host. |
| | Android Viewer | Connect to an existing Mac workspace from an Android device. |
