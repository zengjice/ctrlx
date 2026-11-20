<p align="center">
  <img src="Brand/CtrlX-AppIcon.png" width="80" alt="CtrlX app icon" />
</p>

# CtrlX

[简体中文](README_ZH.md) · [Get started](#get-started) · [Documentation](docs/README.md)

> **Your AI works on your Mac. You can keep going from your phone.**

CtrlX lets you work with Codex, Claude Code and other coding agents from your Mac
or iPhone: explain what you need, answer questions, check the result and send
feedback. Your project and agents stay on the original Mac. Switching devices
brings you back to the same conversation and the same work.

If you juggle several projects or step away while AI is working, CtrlX helps you
see who is busy, who needs you and which conversation to return to.

[Install for Mac](#get-started) · [iPhone installation](RELEASE.md#local-overwrite-installation)

## Explain the task, then get on with your day

Give an Agent a request, attach a screenshot or speak your idea. Voice input can
use terminal context to correct technical terms and mixed-language speech. Check
the text before sending it, and save frequent instructions as quick phrases.

Once work starts, you can leave your desk. CtrlX notifies you when an Agent
finishes, asks a question or needs permission. Open the notification on your
iPhone, return to that conversation and provide what it needs to continue. Photos
you take and files shared from other apps can come back into the project too.

The full terminal is always available when you want to inspect the process,
add instructions or take over.

## When it says “done,” try the result yourself

Checking a result often means opening it. You can do that from your phone while
the project is still running on your Mac:

- **Building a website?** Open the Mac's local development page, click buttons,
  fill in forms and play audio. The page keeps its Mac environment and login
  state; your development server does not need a public address.
- **Building an iOS app?** View and interact with the Mac's Simulator to walk
  through a user flow. The Simulator continues running on the Mac.
- **Writing documents or producing files?** Follow the Agent's file links to
  read Markdown, view images and PDFs, play videos or download a file to your
  device. Back on your Mac, inspect code diffs beside the terminal.

Spot something to change? Mark up a screenshot with a box or an arrow, add a
sentence and give it back to the Agent. Agents can also use CtrlX's Browser and
Simulator tools to check their own work. You can watch and take control when needed.

## Follow several pieces of work at once

Have one Agent develop, another review and an ordinary terminal ready alongside
them. See their status and usage together, organize conversations by project and
choose a model for each job. On Mac, use split views or separate windows when you
need to compare work.

**Fork a conversation** when you want to explore another direction. The new Agent
starts with the existing context, while the original discussion stays available.
When changes need their own working copies, start the work in separate Git worktrees.

For repeated development, review and repair, save the handoffs as a **Workflow**.
Send a developer's result to a reviewer, then pass the feedback into a repair
step. You can also have reviewers work in parallel and combine their findings.
You choose who does each step and can pause, continue or stop from your computer
or phone. Agents in a workflow currently run on the same Mac.

[Arrange Agent collaboration](docs/multi-agent-design.md)

## Pick up where you left off

Connect to your office Mac and your home Mac from one place. Return to an existing
session when switching devices; your project and development environment stay on
the Mac. Closing a viewing window or briefly losing the connection leaves its
terminal processes running.

With workspace recovery enabled, a Mac restart can restore saved layouts and
supported Agent conversations. Remote clients also offer recovery controls when
you need to intervene.

For an ongoing conversation you can summon with a global shortcut on Mac, try
**Orbie**. Continue your conversation, find related work and return to its Agent
tab. Create an **Orbiter** for a focused job, or fork from Orbie to carry its
conversation context into a separate Agent. Orbie is currently an early-stage
feature on the local Mac.

## Get started

Start with one conversation on your Mac, then connect another device.

### Try it on your Mac

You need an Apple Silicon Mac running **macOS 26 or later**, with an Agent CLI
installed and signed in. CtrlX includes Codex and Claude Code integrations;
OpenCode, pi and omp are available through plugins. Interactive features depend
on the Agent.

Install tmux and CtrlX:

```bash
brew install tmux
curl -fsSL https://ctrlx-1256844776.cos.ap-guangzhou.myqcloud.com/macos/mac.sh | bash
```

Open CtrlX and configure the integration in **Settings → Agents**. Choose
**New Session → Start in Directory…**, pick your project and Agent, and start a
conversation. Try a small request such as “Read this project's README and tell me
where to start. Don't change any code yet.”

Existing tmux sessions appear automatically. Inside a session, use
**+ → New Agent…** to add another Agent, or open an ordinary terminal.

Published Mac packages are signed with the publisher's Developer ID Application
identity and notarized by Apple. Agents use the AI accounts or API services you
configure for them.

### Continue on your phone or another Mac

1. Install CtrlX on the other device. iPhone requires **iOS 18 or later** and
   currently uses [locally signed builds](RELEASE.md#local-overwrite-installation);
   there is no App Store download yet.
2. Use the same Relay—the service connecting your devices—on both ends. Enter
   `wss://ctrlx.zengjice.com:7001` or [host your own](docs/self-hosting.md).
   If the service requires an access key, enter it on the Mac running your project
   under **Settings → Relay → This Mac · Relay Traffic → Access Key**, then choose
   **Save Access Key**.
3. Generate a pairing code on the Mac running your project and enter it on the
   other device. Open your conversation and continue with the next message.

For remote use, the Mac running your project must stay awake, online and running
CtrlX. Background iPhone alerts also require matching APNs configuration on the
Relay; see [push setup](docs/push-notifications-plan.md). Viewing an iOS Simulator
requires Xcode and an installed Simulator runtime on that Mac.

## Where your work lives

Your project, development environment and the Agent's native conversation history
stay on your Mac. Workspace traffic between devices is end-to-end encrypted. The
Relay handles connection metadata but cannot read terminal content. You can host
it yourself; its default open mode needs no CtrlX account or subscription, and
you do not need to open an inbound SSH port on your Mac.

Optional cloud voice correction sends speech candidates and a limited amount of
terminal context directly to your chosen provider. See
[connections and encryption](docs/architecture.md) and the
[self-hosting guide](docs/self-hosting.md).

## Documentation and open source

[Files and sharing](docs/file-browser.md) · [Browsing websites](docs/agent-browser.md) ·
[Testing iOS apps](docs/agent-simulator-design.md) · [Voice and shortcuts](docs/terminal-quick-actions.md) ·
[Orbie](docs/global-agent-design.md)

The Mac app, iOS app and Relay are open source. See the
[release notes](MODIFICATIONS.md), [technical documentation](docs/README.md),
[contribution guide](CONTRIBUTING.md) and [build instructions](AGENTS.md).

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
