# CtrlX release process

CtrlX releases bind each binary to an immutable source commit.

1. Update `Config/Shared-Base.xcconfig`, version docs and `MODIFICATIONS.md`.
2. Run all boundary checks, Swift tests, website build and Mac/iOS build checks.
3. Commit from the primary worktree and create `v<version>` at that exact commit.
4. Copy `.env.example` to the selected root environment file and configure the
   signing identity, notary profile and owned download URL.
5. Run the zero-parameter `./scripts/release.sh`.

The script refuses dirty or untagged source, archives and signs `CtrlX.app`,
submits the app and DMG for notarization, generates `CtrlX-<version>.dmg`, a
Sparkle appcast, SHA-256 file and JSON manifest containing the full source
commit and AGPL license.

Sparkle stays disabled in the application until a CtrlX feed URL and EdDSA
public key are supplied in ignored `Config/Local-macOS.xcconfig`. Gallager's
feed, key and domains are never fallback values.

## Publish only the macOS package

For the existing Qcloud private-distribution channel, follow the sibling
`CTRLX_QCLOUD_RELEASE_RUNBOOK.md` section 5 and use:

```bash
../publish-ctrlx-macos.py --check
../publish-ctrlx-macos.py --yes
```

Prepare a tested, clean, pushed `main` commit and matching `v<version>` tag
first. This path uses `scripts/package-local-macos.sh` (Apple Development
signature, not notarized), verifies the DMG and atomically updates the Qcloud
installer. It does not install locally or redeploy the Relay.

Mac-only packaging does not require a local Docker engine or OrbStack. A change
confined to Apple-only dependencies, such as the SwiftTerm revision, does not
make Linux lock generation a prerequisite for this path. Refresh and validate
the Linux lock before a later Relay build if its manifest hash is stale.

## Publish the hosted Relay and macOS package together

Production Relay and installer hosting run on Qcloud. Their host-specific
automation, topology, and credentials stay outside this public repository. On a
configured maintainer Mac, use the sibling runbook and script:

```bash
../deploy-ctrlx-qcloud.sh --preflight-only
../deploy-ctrlx-qcloud.sh --yes
```

The script requires a clean, pushed `main` commit and a new version. It builds
and smoke-tests the `linux/amd64` Relay locally, snapshots production state,
deploys the Relay, packages the Mac app, uploads and verifies the DMG before
switching the installer, then performs a real upgrade test. Qcloud is the only
writable production Relay; do not publish through the retired home-Mac path.

If these external files are unavailable, stop and obtain the maintainer release
environment instead of reconstructing production commands from this document.

TestFlight/App Store upload is intentionally blocked by `scripts/testflight.sh`
until an AGPL/Apple terms review or copyright-holder exception is documented.
Local signed-device builds remain available through
`scripts/package-local-ios.sh`.
