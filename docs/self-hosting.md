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
| `GET /api/access/status` | Authenticated account allowance in metered mode; mode discovery in open mode |
| `WS /api/ws` | Encrypted relay stream |

WebSocket frames and complete messages are limited to 1 MiB, with at most 1024
fragments per message. The Relay pings every 30 seconds to detect unresponsive
peers. Reconnecting closes the previous socket; a peer that does not acknowledge
a close frame is forcibly disconnected after 5 seconds.

## Optional account authentication and traffic quotas

`RELAY_ACCESS_MODE=open` remains the default. To enable account access keys and
shared monthly allowances, explicitly select `metered` and mount a writable,
persistent `DATA_DIRECTORY`. Metered mode cannot be combined with the existing
Lemon Squeezy licensing configuration. Invalid mode or storage configuration
fails startup; storage failures during service reject traffic.

Create an account using the Relay executable inside that instance's container:

```bash
docker exec <relay-container> ./CtrlxExternalServer relay-admin account create \
  --name alice --monthly-quota 50GiB
```

The command returns the account ID and a newly generated key. Deliver the key
privately; it cannot be read back from the database. In Mac Host settings, open
Remote Access → Relay Traffic and save the key. Pair each Viewer normally.
Pair-specific Host/Viewer credentials are then saved separately in Keychain.
Authenticated network access requires HTTPS/WSS; loopback HTTP is permitted
for local development and SSH tunnels.

Authenticated registration, pairing status and WebSocket attempts are limited
per verified credential; allowance queries are limited per verified account.
Invalid or missing credentials consume separate anonymous buckets. For anonymous
pairing attempts behind a reverse proxy, set `RELAY_TRUSTED_PROXY_IPS` to the
comma-separated **socket peer IPs** of your proxies. The default is empty and
trusts no forwarding headers. A host-local Caddy connecting directly to a native
Relay typically uses `127.0.0.1,::1`; with Docker, configure the proxy/gateway
address actually seen inside the Relay container. Do not list public clients or
an entire private subnet. Unlisted peers cannot change buckets with forged
headers. The Relay walks `X-Forwarded-For` from right to left through only the
listed proxies, stopping at the first untrusted hop. Ensure your edge proxy
overwrites untrusted incoming forwarding headers; see
[Caddy's forwarding-header behavior](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#headers).

Monthly traffic is shared across the account's Hosts and paired Viewers. Months
start at 00:00 in Asia/Shanghai. Each admitted encrypted forwarding counts its
complete application envelope once; both directions and each Viewer count.
APNs delivery counts the encoded notification body. Controlled pairing, status
and heartbeat traffic is free and rate-limited. These bytes exclude TCP/TLS
overhead and do not equal the cloud provider's network bill.

```bash
docker exec <relay-container> ./CtrlxExternalServer relay-admin usage show --account alice
docker exec <relay-container> ./CtrlxExternalServer relay-admin quota add \
  --account alice --month 2026-11 --amount 20GiB \
  --request-id support-20261101-001 --reason 'Temporary allowance'
docker exec <relay-container> ./CtrlxExternalServer relay-admin account set \
  --account alice --monthly-quota 60GiB
docker exec <relay-container> ./CtrlxExternalServer relay-admin account disable --account alice
docker exec <relay-container> ./CtrlxExternalServer relay-admin account enable --account alice
docker exec <relay-container> ./CtrlxExternalServer relay-admin key rotate --account alice
docker exec <relay-container> ./CtrlxExternalServer relay-admin pair revoke --pair <pair-id>
```

Use a unique request ID before each new top-up; retry with the same parameters
and ID to avoid adding twice. New top-ups must target the current billing month; retries of an existing ID
retain the original month. Top-ups expire at month end. Base
allowance changes apply next month. Key rotation normally preserves pair
credentials; `key rotate --revoke-pairs` also revokes them. Administration is
local-only; no public management API is exposed.

The Relay commits each debit before forwarding. A disconnect afterward may
leave admitted bytes charged without delivery. An insufficient allowance
rejects the whole next message, preserves the actual remainder and closes the
affected stream. Clients retain their pairing and show the restriction. Active
clients check for recovery every 30 seconds and on foreground entry; users can
also choose Check and Reconnect. Recovery requests fresh snapshots and never
replays uncertain write operations. Local Host tasks continue.

The authoritative store is `DATA_DIRECTORY/relay-access.sqlite` with SQLite
WAL and FULL synchronization. Back up the stopped isolated instance's complete
data directory, or use SQLite's online backup facilities; copying just the main
file while running can omit committed WAL data. Legacy `pairs.json` remains
untouched and is not granted account authority. Enabling metered mode requires
new authentication and pairing. Deploy compatible clients first, then set an
appropriate `MIN_CLIENT_VERSION` with unknown versions rejected before switching
the service. Returning to open mode restores open admission and is not a quota
recovery procedure. See [design and acceptance status](relay-access-quota-design.md).

## APNs

For push notifications, mount a `.p8` key read-only at `/secrets/AuthKey.p8`
and configure `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` and
`APNS_ENVIRONMENT`. `APNS_BUNDLE_ID` must match the installed CtrlX iOS build;
the current iOS distribution identity is `com.gravtice.ctrlx`. Ad Hoc and
TestFlight/App Store builds use `APNS_ENVIRONMENT=production`; development-signed
builds use the development environment.

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
