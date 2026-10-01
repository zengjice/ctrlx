# Self-hosting CtrlX Relay

CtrlX Relay pairs Mac and iOS clients, routes end-to-end encrypted WebSocket
frames, and optionally sends APNs notifications. It does not decrypt terminal
content. The community configuration has no account, payment, or license
requirement.

## Requirements

- Docker with Compose v2
- A domain with TLS termination for public WSS access
- Approximately 1 CPU and 1 GB RAM for a small deployment
- Optional Apple APNs key for background iOS notifications

## Local development

```bash
git clone https://github.com/jicezeng/CtrlX.git
cd CtrlX
./sbin/auto-env.sh
./sbin/start_server.sh
```

`auto-env.sh` creates `CtrlxPackage/.env.local` and assigns a deterministic
worktree-specific port. Stop the Relay with `./sbin/stop_server.sh`.

Configuration is zero-parameter and follows one priority list:

```text
.env.local > .env.production > .env.development > .env.test
```

Only the first existing file is loaded. Lower-priority files are not merged.
Copy one of the committed `CtrlxPackage/.env.*.example` templates to the
matching active filename. Active files and APNs private keys are Git-ignored.

## Production

1. Copy `.env.production.example` to `.env.production` on the server.
2. Set `CTRLX_VERSION` and `CTRLX_SOURCE_REVISION` to the exact released tag and
   full Git commit. `/version` and `/source` expose this mapping for AGPL users.
3. Generate a metrics token of at least 32 random characters, or leave it empty
   to disable `/metrics`.
4. Leave all APNs credentials empty unless push notifications are required.
5. Start through a shell that exports the selected file, or use the repository
   deployment script from a clean primary worktree.

The generic Caddy configuration is `CtrlxPackage/caddy/ctrlx.caddy`. It
expects `CTRLX_RELAY_HOST` in Caddy's own service environment and proxies to
`127.0.0.1:8080`. No public domain is hard-coded in the source tree.

The zero-parameter deployment script reads the repository root environment file:

```bash
cp .env.example .env.production
# edit .env.production, then:
./scripts/deploy.sh
```

It refuses a dirty worktree, verifies that the remote `.env.production` reports
the same version and commit, starts the container, then validates `/health` and
`/source`.

## Endpoints

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | Process health |
| `GET /ready` | Relay readiness |
| `GET /version` | Product, version, protocol, commit, source and license |
| `GET /source` | Corresponding source and AGPL license |
| `GET /metrics` | Authenticated Prometheus metrics; disabled without token |
| `POST /api/pairing/register` | Register a Mac pairing code |
| `POST /api/pairing/complete` | Complete pairing from a viewer |
| `WS /api/ws` | Encrypted relay stream |

WebSocket frames and complete messages are limited to 1 MiB, with at most 1024
fragments per message. The Relay pings every 30 seconds to detect unresponsive
peers. Reconnecting closes the previous socket; a peer that does not acknowledge
a close frame is forcibly disconnected after 5 seconds.

## APNs

For push notifications, mount a `.p8` key read-only at `/secrets/AuthKey.p8`
and configure `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` and
`APNS_ENVIRONMENT`. `APNS_BUNDLE_ID` must match the installed CtrlX iOS build;
the official distribution identity is `com.jicezeng.ctrlx`.

If APNs values are absent, the Relay continues to provide pairing and live WSS
transport without background push.

## Security notes

- Expose only the TLS reverse proxy; the Compose port binds to loopback.
- Back up the Relay data directory and test restoration.
- Treat pairing records, IP addresses, device metadata and APNs tokens as
  personal data even though terminal content is encrypted.
- Rotate APNs and monitoring credentials without committing them.
- Set `MIN_CLIENT_VERSION=3.0.0` and reject unknown versions for a CtrlX-only
  production Relay; CtrlX 3 intentionally does not share Gallager 2.x identity.
