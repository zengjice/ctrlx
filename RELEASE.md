# CtrlX release process

CtrlX releases bind each binary to an immutable source commit.

1. Update `Config/Shared-Base.xcconfig`, version docs and `MODIFICATIONS.md`.
2. Run all boundary checks, Swift tests, website build and Mac/iOS build checks.
3. Commit from the selected worktree and create `v<version>` at that exact commit.
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

Prepare a tested, clean commit published as remote `main` and matching
`v<version>` tag first. A linked worktree and its local branch are supported;
the exact commit must still match both remote release refs. Select it explicitly:

```bash
python3 /path/to/publish-ctrlx-macos.py --root "$PWD" --check
python3 /path/to/publish-ctrlx-macos.py --root "$PWD" --yes
```

`CTRLX_ROOT` remains supported; without either option, the maintainer's usual
primary checkout remains the default. This path uses
`scripts/package-local-macos.sh` (Apple Development
signature, not notarized), verifies the DMG and atomically updates the Qcloud
installer. It does not install locally or redeploy the Relay.

Mac/iOS local packaging and the formal release script accept any Git worktree
root. Build caches and artifacts stay in that worktree's `.build-local/` and
`dist/`; they never write into another worktree. Provision the selected
worktree's ignored local signing config before building. Local development
packaging keeps its existing uncommitted-build workflow; formal releases and
the Qcloud publisher still require clean, exactly tagged source.

### Local build storage

Mac and iOS packaging delete their temporary App copies on exit, including
failed builds. Installable apps in DerivedData remain available for device
installation. After successful packaging, each platform retains the just-built
package and the most recently modified other package in `dist/`; older packages
and their `.sha256`, `.manifest.json`, and `.previous` files are deleted.
Release and Debug packages are retained independently. This also applies to
formal Mac releases, but never prunes Qcloud or Inbox files.

Command-line packaging disables index generation. After success, local Mac/iOS
packaging removes only that platform's old `Index.noindex` and duplicate DerivedData
`SourcePackages` directory (when the shared dependency directory exists).
By default, build intermediates, compilation/module caches and installable apps
are kept.
Do not run concurrent builds or installs against the same DerivedData directory.

All packaging entrypoints check available disk space before building and warn
below 20 GiB. This is an advisory threshold, not a guarantee or a hard minimum;
packaging still proceeds and never deletes caches to make room before a build.
Formal releases also check their temporary build volume.

For low-storage machines, opt in per invocation:

```bash
./scripts/package-local-macos.sh --save-space
./scripts/package-local-ios.sh --save-space
./scripts/package-local-ios.sh --configuration Debug --save-space
```

Only after packaging and integrity metadata succeed, this mode removes the
selected platform's `Build/Intermediates.noindex`, compilation/module caches,
explicit precompiled SDK modules and SDK stat caches. It keeps `Build/Products`
(including the signed installable App), IPA/DMG files, shared dependencies,
Chromium SDKs/runtime and logs. The next build recompiles and will be slower;
downloads need not repeat. Failed builds do not trigger this cleanup, and other
platforms/worktrees and the separate Swift package test cache are untouched.
`--save-space` does not solve insufficient space for the current build.
Formal releases already remove their temporary DerivedData on exit and remain
zero-parameter.

Use `./scripts/unit-tests.sh` for package tests, passing test filters after `--`.
The script fixes the `swiftbuild` backend and disables indexes, so repeated runs
do not accumulate native and Swift Build outputs. Only after tests succeed, it
removes obsolete native outputs for configurations already switched to
`swiftbuild`, plus old test indexes. `--save-space` also removes Swift Build's
compilation caches, but keeps test products and downloaded dependencies. Failed
tests perform no cleanup. The E2E sidecar build uses the same backend and indexing
policy. Do not build or clean the same package cache concurrently.

For an inactive worktree, prefer this narrower cleanup over `deep`:

```bash
python3 scripts/clean-build.py idle        # Preview only
python3 scripts/clean-build.py idle --yes  # Stop this worktree's builds/installs first
```

It removes package/platform compilation caches, indexes and redundant Xcode
dependency copies. Signed apps in DerivedData, Swift Build products, IPA/DMG
files, dependency downloads, Chromium SDKs and signing configuration remain.
It does not scan other worktrees or automatically decide which ones are idle.
The next build recompiles; the kept dependency caches remain reusable.

Packaging also removes `dist/qcloud-release/<version>/public-CtrlX-<version>.dmg`
copies whose latest publication report records success and whose SHA-256 still
matches. The maintainer's Mac publisher performs the same cleanup immediately
after saving a successful report and releasing its lock. Reports, hashes, logs,
installer backups and actual distribution packages remain; failed, active,
unreported or mismatched downloads are preserved for investigation.
To preview cleanup of these verified copies without building:

```bash
python3 scripts/clean-build.py receipts
```

Incremental build caches, shared downloaded dependencies and Chromium SDKs are kept
to avoid repeated downloads and full rebuilds. For manual deep cleanup:

```bash
python3 scripts/clean-build.py deep        # Preview only
python3 scripts/clean-build.py deep --yes  # Delete worktree-local build caches
```

Stop builds, packaging and device installs in that worktree first. Deep cleanup
also removes built installable apps and legacy `package-ios`/`package-macos`
copies, but preserves `dist/`, signing configuration, installed apps and browser
profiles. It does not touch other worktrees, Xcode's global caches or simulators.
The next build must download dependencies/SDKs and compile again.

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
