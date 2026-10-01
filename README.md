# CtrlX

[简体中文](README_ZH.md)

> **Your tmux, Your Agent, everywhere.**

CtrlX is a tmux-native remote terminal for viewing and controlling the tmux
workspaces on any paired Mac from another Mac or an iPhone. It reuses your
existing tmux sessions instead of replacing them with a proprietary session
model.

<p align="center">
  <img src="docs/assets/ctrlx-architecture.svg" width="100%" alt="CtrlX keeps terminals running inside persistent tmux sessions and connects Mac and iPhone viewers through an end-to-end encrypted relay." />
</p>

## Why CtrlX

- **Native tmux:** Discover and share existing sessions, windows, and panes.
  Tasks keep running when CtrlX closes or the network drops.
- **Multi-host roaming:** Control tmux workspaces on Macs at home, at work, or
  on remote networks from one Mac or iPhone.
- **Session-aware voice input:** iPhone voice input uses the current terminal
  session as context to correct what you say.
- **Agent-aware:** Track working, completed, permission, question, and plan
  states for Claude Code, Codex, and agents added through open sidecar plugins.
- **Secure Relay:** Every device connects outbound; terminal frames remain
  end-to-end encrypted between the Host and Viewer.

Without an agent plugin, CtrlX remains a complete tmux remote terminal.

## Quick start

### Install CtrlX for macOS

CtrlX currently requires Apple Silicon, macOS 15 or later, and tmux:

```bash
brew install tmux
curl -fsSL https://ctrlx.zengjice.com:7001/install/mac.sh | bash
```

The installer verifies the package and replaces only `/Applications/CtrlX.app`;
existing tmux sessions continue running. The current package uses an Apple
Development signature and is not notarized or distributed through the App Store.

### Reuse and share a tmux session

Continue using standard tmux commands:

```bash
tmux new -s coding
tmux attach -t coding
```

Open CtrlX and the session appears under Local. To connect another Mac or an
iPhone:

1. Generate a pairing code on the Host Mac.
2. Connect the Viewer to the same Relay and enter the code.
3. Select the Host, session, window, and pane.

For learning and community use, you can connect to the official Relay at
`wss://ctrlx.zengjice.com:7001`.

The iOS app currently requires a locally signed Xcode build. APNs credentials
matching that build are needed only for background notifications.

## Security and self-hosting

- The Relay routes pairing metadata and ciphertext but cannot decrypt terminal
  frames.
- Hosts need no public IP or inbound tmux, SSH, or application port.
- Self-hosting requires no CtrlX account, subscription, or overlay network.
- When BYOK voice correction is enabled, speech candidates and bounded pane
  context go directly to the selected provider, not through the CtrlX Relay.

See [Self-hosting CtrlX Relay](docs/self-hosting.md) and the
[Relay monitoring runbook](docs/monitoring.md).

## Development

Building requires a recent Xcode, Swift 6.3 or later, and macOS 15 or later.
Open `Ctrlx.xcworkspace` and use scheme `CtrlxServer` for macOS or
`Ctrlx` for iOS. Internal Swift modules use the `Ctrlx*` prefix; product branding
is `CtrlX`.

```bash
swift test --package-path CtrlxPackage

./sbin/auto-env.sh
./sbin/start_server.sh
```

See [AGENTS.md](AGENTS.md) for repository conventions and iOS build, package,
and device-install guidance; see [CONTRIBUTING.md](CONTRIBUTING.md) and
[RELEASE.md](RELEASE.md) for contribution and release workflows.

## License and origin

CtrlX is an independent distribution based on
[Gallager](https://github.com/gpambrozio/Gallager), with baseline commit
`919c7772928531d4d0bb266bdf275691d361901e` dated 2026-08-14. It is maintained
by ZengJice and is not affiliated with or endorsed by the Gallager project.

CtrlX is distributed under [GNU AGPL-3.0](LICENSE). Published binaries and the
hosted Relay identify their corresponding immutable source commit; the Relay
exposes it through `/version` and `/source`. See [NOTICE.md](NOTICE.md),
[MODIFICATIONS.md](MODIFICATIONS.md), and
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
