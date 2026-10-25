# CtrlX release process

CtrlX releases bind each binary to an immutable source commit.

1. Update `Config/Shared-Base.xcconfig`, version docs and `MODIFICATIONS.md`.
   Increment `CURRENT_PROJECT_VERSION` for each newly distributed build, even
   when `MARKETING_VERSION` changes; do not reset it to 1. Keep the app and
   notification extension on the same build number. iOS uses this build string
   to recognize updates during synchronization; see Apple's
   [version and build guidance](https://help.apple.com/xcode/mac/current/en.lproj/devba7f53ad4.html).
2. Run all boundary checks, Swift tests, website build and Mac/iOS build checks.
3. Commit from the selected worktree and create `v<version>` at that exact commit.
4. Copy `.env.example` to the selected root environment file and configure the
   signing identity, notary profile and owned download URL.
5. Run the zero-parameter `./scripts/release.sh`.

The script refuses dirty or untagged source, archives and signs `CtrlX.app`,
submits the app and DMG for notarization, generates `CtrlX-<version>.dmg`, a
Sparkle appcast, SHA-256 file and JSON manifest containing the full source
commit and AGPL license. The appcast is retained for older clients that still
used Sparkle's in-process updater; current clients use the Qcloud installer
below and do not load Sparkle at runtime.

The EdDSA public key in ignored `Config/Local-macOS.xcconfig` is required for
the in-app Qcloud updater to verify the installer script. Gallager's key and
domains are never fallback values.

The in-app Qcloud updater uses the bundled Sparkle EdDSA public key
(`SUPublicEDKey`). Each published `macos/mac.sh` must have a matching
`macos/mac.sh.sig` containing the base64 detached signature of the exact script
bytes, produced with the corresponding Sparkle private key (`sign_update
mac.sh`, taking the base64 value from `sparkle:edSignature`). Missing or invalid
signatures fail closed; HTTPS alone is not the update trust root. The app does
not check the installer merely because Settings → General opened; startup, the
daily maintenance loop and the explicit **Check Again** action trigger a check.

The simulator build scripts sign both `CtrlxSimulatorHost` and the pinned
`simslim` helper with Hardened Runtime. Validate actual display, input,
accessibility and profile changes in the signed candidate before distribution.
Full App hardening and notarization still require the Agent Browser archive
gates described in `docs/agent-browser.md`.

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
`scripts/package-local-macos.sh` (Apple Development signature, not notarized).
The publishing Mac uploads directly to COS using its exported `COS_SECRET_ID`
and `COS_SECRET_KEY`. Neither publication nor installer/package downloads require
SSH, SCP or the Qcloud host. Publication does not install locally or deploy the Relay.

The sibling maintainer files `publish-ctrlx-macos.py`, `ctrlx-cos.py` and
`install-ctrlx-macos.sh` must be kept together, outside this public repository.
The local installer template is rendered with the release's version, build, source
revision, build stamp and DMG SHA-256. Its stable COS entrypoint is `macos/mac.sh`;
its detached `macos/mac.sh.sig` is published beside it. DMGs and content-addressed
installer backups also live under `macos/`.
The old host's installer is a legacy entrypoint and is not updated by this flow.

`--check-cos` checks local credentials and bucket versioning without requiring
release-ready source. Keys and signed request headers are never put in arguments,
logs or reports. The sibling runbook defines the bucket and CAM permissions.
DMGs use a bounded single PUT with Content-MD5 and `x-cos-forbid-overwrite`;
bucket versioning must never have been enabled. The publisher checks this before
building and again before uploading. Packages over 5 GiB require a separately
validated multipart implementation.

Before switching the installer, the Mac anonymously streams the complete public
COS DMG through SHA-256, checks its size, and compares a bounded 64 KiB HTTP Range
response with the local artifact. `--full-download-verify` instead keeps a complete
local verification copy, removed by successful publication receipt cleanup.
The installer retains its download hash, app signature/source checks, graceful
app exit and installation rollback. Downloads and redirects require HTTPS.
The local template skips installation when the installed App matches the release's
bundle ID, version, build, build stamp and source revision and passes executable
and signature checks. This leaves the running App and its settings alone. Use
`--force` to reinstall that build. Normal output shows download progress on a
terminal and short verification/install/completion messages; `--verbose` also
shows tool output. Detailed logs are kept in `~/Library/Logs/CtrlX/Installer/`;
failures print a bounded log excerpt and its path. Pass flags to the downloaded
script with `bash -s -- --force --verbose`, or through a local `ctrlx-install`
wrapper that forwards `"$@"`. Template changes reach `macos/mac.sh` through the
next normal Mac publication; editing the local template does not update COS.
Updates preserve the installed App's Relay URL and auto-connect preference, even
when those keys are absent. Reinstalls without an App also keep saved Relay
preferences; only a first install with no Relay preferences initializes the
distribution defaults. Installer regressions live alongside the private template
in `test-ctrlx-installer.py` and must pass before publishing its signed bytes.

Installer promotion uses a COS lock object created with overwrite forbidden.
While holding it, the publisher rechecks the previous installer, saves an immutable
backup, replaces `mac.sh` and `mac.sh.sig`, and verifies the anonymous public
responses. Failure restores only this attempt's installer and signature under the
same lock. The stable entrypoint uses `Cache-Control: no-store`. Lock release and
initial-publication rollback need `cos:DeleteObject` only for
`macos/.publish-lock.json`, `macos/mac.sh` and `macos/mac.sh.sig`; release artifacts
are never deleted. A killed publisher may leave a lock: inspect the recorded attempt
and confirm it has stopped before manually clearing that lock; there is no automatic
expiry or lock stealing.

Logs and receipts retain the existing worktree-local `dist/qcloud-release/` path
for cleanup compatibility. First COS publication creates the new installer URL;
repeating an exact release verifies it without replacing the package or installer.

Mac/iOS local packaging and the formal release script accept any Git worktree
root. Build caches and artifacts stay in that worktree's `.build-local/` and
`dist/`; they never write into another worktree. Provision the selected
worktree's ignored local signing config before building. Local development
packaging keeps its existing uncommitted-build workflow; formal releases and
the COS publisher still require clean, exactly tagged source.

### Local overwrite installation

Use one entrypoint for both platforms rather than handwritten copy/install steps:

```bash
python3 scripts/install-local.py macos
xcrun devicectl list devices
python3 scripts/install-local.py ios --device '<CoreDevice UUID>'

# Install a completed signed App without rebuilding (no DMG/IPA required):
python3 scripts/install-local.py macos --skip-build
python3 scripts/install-local.py ios --device '<CoreDevice UUID>' --skip-build

# Optional Debug device build and post-install cache cleanup:
python3 scripts/install-local.py ios --device '<CoreDevice UUID>' --configuration Debug --save-space
```

Default behavior calls `package-local-macos.sh --app-only` /
`package-local-ios.sh --app-only`, reusing their build/sign/verify steps but skipping
the distribution App copy and DMG/IPA compression. Each successful local build
writes `CtrlX.app.build.json` beside (not inside) its signed App. Before rebuilding,
the old record is invalidated; a failed or partially signed build cannot be reused.
Installation verifies the signature and matches the bundle ID, version, source
revision and build stamp against this worktree/configuration-specific record.
`--skip-build` deliberately installs that recorded build, not the current source;
it prints its identity before installing. Builds predating the record need one
fresh build, without `--skip-build`. No automatic choice among phones is made.

Mac replacement targets only `/Applications/CtrlX.app`, without sudo. The current
user needs write permission there. The installer validates a staged new App, asks
the exact installed App to quit normally and waits for its main process to exit.
Same-name test Apps do not block it. A failed quit never leads to a forced kill or
replacement. The old App is saved under this worktree's
`.build-local/mac-install-backup.<suffix>/CtrlX.app`; replacement is by rename, not
merging bundles. A failed replacement/verification restores the previous App.
Launch failure retains the new installation and rollback backup for investigation,
rather than overwriting an App that may already be running.

Mac staging copies are removed on normal/error/interrupted exits. Backups use the
same managed-artifact completion/locking mechanism described below: retain two
completed backups, preserve failed backups. SIGKILL/power loss cannot run cleanup;
any unmarked leftovers require inspection, not a blind global sweep. iOS installs
the signed device App directly with `devicectl`, then launches its bundle ID; it
does not uninstall, clear App data, or create another host-side App copy.

After a successful install/launch, the existing worktree-local pruning runs even
with `--skip-build`. Incremental caches remain by default. `--save-space` defers
compiler-cache removal until install/launch succeeds; failure keeps those caches
and diagnostic backups. The nested App build defers retention to this outer success
boundary, so cleanup runs once, after installation and launch.
Local packaging, formal release, native-browser preparation, package tests,
installation and destructive cleanup share `.build-local/operation.lock`; a
conflicting operation fails before writing or deleting. Nested script calls borrow
the same lock, while separate worktrees remain independent. Installation also locks
its destination (the Mac App or explicit iPhone UUID) across worktrees.
Raw `xcodebuild` / `swift test`, Xcode UI builds and ad hoc scripts are not covered:
stop them before cleanup, or wrap them in
`python3 scripts/local_build.py run -- <command>`. Cleanup previews remain available
during builds. Neither installation command commits,
publishes, deploys the Relay, or changes the external public installer.

### Local build storage

Keep the existing entrypoints: two platform packaging scripts, one local installer,
one cleaner. `local_build.py` and `common.sh` are internal shared helpers, not a
second build/signing implementation. To compile/sign without installing or packaging:

```bash
./scripts/package-local-macos.sh --app-only
./scripts/package-local-ios.sh --app-only
./scripts/package-local-ios.sh --app-only --configuration Debug
```

Without `--app-only`, local scripts create the package and its integrity sidecars
in a temporary worktree directory, validate them, then replace the final files.
Replacement errors restore the previous package and sidecars; a rollback failure
preserves `.package-replace.*` under `dist/` and reports its location. Do not blindly
delete such recovery files after an interruption. Power loss/SIGKILL cannot run
rollback or exit traps. Formal notarized releases retain their separate `.previous`
backup workflow.

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

Successful packaging also prunes **managed, completed** local verification copies
and install backups, keeping the two most recently completed directories per kind.
This retention is independent of `--save-space`: it never evicts incremental build
caches or downloaded dependencies. See the managed-artifact workflow below.

Successful packaging also removes completed historical App backups and diagnostic
directories. Completion is explicit: after the investigation or installation
verification has finished and no process uses the directory, put an empty
`.ctrlx-cleanup-ready` file in the immediate child directory of
`.build-local/app-backups/` or `.build-local/diagnostics/`. Unmarked directories
are preserved, regardless of age; build caches, signing files, recovered browser
profiles, source and other worktrees are never selected by this housekeeping.
Only mark an App backup disposable once the replacement App is verified and a
rollback package remains in `dist/`. Never mark an active diagnostic directory.
To run the same housekeeping without rebuilding:

```bash
python3 scripts/clean-build.py housekeeping        # Preview only
python3 scripts/clean-build.py housekeeping --yes  # Remove explicitly completed artifacts
```

It also uses the existing successful-publication receipt and SHA-256 checks for
public-download copies. Legacy downloads without a valid receipt are preserved;
migrate a receipt only after verifying the historical release evidence and hash.
No age-based sweep or automatic cross-worktree cache deletion is performed.

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

Only after the requested workflow succeeds (verified App, package, or install/launch),
this mode removes the selected platform's `Build/Intermediates.noindex`, compilation/module caches,
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
dependency copies, and applies the same completed-artifact/public-download
retention as packaging. Signed apps in DerivedData, Swift Build products, IPA/DMG
files, dependency downloads, Chromium SDKs and signing configuration remain.
It does not scan other worktrees or automatically decide which ones are idle.
The next build recompiles; the kept dependency caches remain reusable.

### Verification copies and local install backups

Use `use-artifact` for disposable copies in this worktree's `.build-local/`:

```bash
python3 scripts/clean-build.py use-artifact --path "$PROBE_BUILD" -- \
  python3 -u CtrlxPackage/AgentBrowser/tests/upstream_probe.py \
  "$PROBE_BUILD/CtrlX.app" "$PROBE_BUILD/agent-browser" "$PROBE_BUILD/identity"
```

The browser preparation script prints this wrapped command. It holds an exclusive
use lock throughout the command and records completion only on exit code zero.
Reusing a copy must use the wrapper again: it invalidates the old success before
running. A failure, interruption, or missing/malformed completion record preserves
the entire directory for investigation. Keep logs/state that must survive retention
outside the disposable copy. The command must stop its test app and other consumers
before returning; do not wrap a detached launch or an ongoing simulator environment.

Supported direct children of `.build-local/` are deliberately narrow:

- Verification copies: `upstream-browser-proof.<suffix>`.
- Local installation backups, grouped together: `mac-install-backup.<suffix>`,
  `macOS-install-backup.<suffix>`, and `mac-install.<suffix>`.

`install-local.py macos` automatically uses this lifecycle for its rollback backup;
do not wrap it a second time or create another manual backup. Custom authorized
install/verify commands can still use the wrapper, returning success only after
the new installation is verified. A failed install retains its rollback copy.
The cleanup wrapper alone does not install anything or change the public installer.
The wrapper prunes older completed copies after success; Mac/iOS packaging and
`idle` perform the same pruning. Each kind retains two completed, inactive copies;
active and failed directories are extra, never a reason to evict the last known-good
backups. Cleanup holds the use locks through deletion, skips directories referenced
by running process commands, and skips artifact pruning if process inspection fails.

Preview/apply only this policy without clearing build caches:

```bash
python3 scripts/clean-build.py retained
python3 scripts/clean-build.py retained --yes
```

The preview also lists matching legacy directories with no completion record.
Do not bulk mark those as successful: audit them individually before adopting or
removing them. No sweep follows symlinks or reaches another worktree, `/tmp`, global
Xcode caches, simulator devices/profiles, or arbitrary acceptance/evidence folders.
Those need their owning workflow's explicit shutdown and cleanup, not a directory-name
guess. Prefer keeping incremental caches while actively developing, then run `idle`
from that worktree after its builds and installs stop.

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
