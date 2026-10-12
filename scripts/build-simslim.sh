#!/bin/bash
set -euo pipefail
SIM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM_OUTPUT="${1:-$SIM_ROOT/.build-local/agent-simulator}"
SIM_CACHE="$SIM_ROOT/.build-local/simslim-source"
SIM_COMMIT='e752a72898ca69f703c74dc79b7b047a4f2093a3'
SIM_SHA='d5f239e1bce073e6a59e472239eb9127074ad48e830e5d37fa779ac786e1acc4'
SIM_ARCHIVE="$SIM_CACHE/$SIM_COMMIT.tar.gz"
SIM_SOURCE="$SIM_CACHE/simslim-$SIM_COMMIT"
SIM_GO="$(command -v go || true)"
if [[ -z "$SIM_GO" && -x "$HOME/.local/bin/go" ]]; then SIM_GO="$HOME/.local/bin/go"; fi
[[ -n "$SIM_GO" ]] || { echo 'Go is required to build the pinned simslim helper.' >&2; exit 1; }
mkdir -p "$SIM_CACHE" "$SIM_OUTPUT"
if [[ ! -f "$SIM_ARCHIVE" ]]; then
  curl --fail --location --retry 2 --connect-timeout 15 --max-time 120 \
    -o "$SIM_ARCHIVE.part" "https://codeload.github.com/MobAI-App/simslim/tar.gz/$SIM_COMMIT"
  [[ "$(shasum -a 256 "$SIM_ARCHIVE.part" | awk '{print $1}')" == "$SIM_SHA" ]] || exit 1
  mv "$SIM_ARCHIVE.part" "$SIM_ARCHIVE"
fi
[[ "$(shasum -a 256 "$SIM_ARCHIVE" | awk '{print $1}')" == "$SIM_SHA" ]] || { echo 'Simslim source checksum mismatch.' >&2; exit 1; }
if [[ ! -f "$SIM_SOURCE/go.mod" ]]; then tar -xzf "$SIM_ARCHIVE" -C "$SIM_CACHE"; fi
SIM_BINARIES=()
for SIM_ARCH in ${ARCHS:-$(uname -m)}; do
  case "$SIM_ARCH" in
    arm64) SIM_GO_ARCH=arm64 ;;
    x86_64) SIM_GO_ARCH=amd64 ;;
    *) echo "Unsupported simslim architecture: $SIM_ARCH" >&2; exit 1 ;;
  esac
  (cd "$SIM_SOURCE"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$SIM_GO_ARCH" GOTOOLCHAIN=local GOCACHE="$SIM_CACHE/go-cache" \
      "$SIM_GO" build -mod=readonly -trimpath -ldflags "-s -w -X main.version=$SIM_COMMIT" \
      -o "$SIM_OUTPUT/simslim-$SIM_ARCH" ./cmd/simslim)
  SIM_BINARIES+=("$SIM_OUTPUT/simslim-$SIM_ARCH")
done
xcrun lipo -create "${SIM_BINARIES[@]}" -output "$SIM_OUTPUT/simslim"
ditto "$SIM_SOURCE/LICENSE" "$SIM_OUTPUT/simslim-LICENSE"
codesign --force --options runtime --sign "${CTRLX_SIMULATOR_SIGN_IDENTITY:--}" "$SIM_OUTPUT/simslim"
GOTOOLCHAIN=local GOCACHE="$SIM_CACHE/go-cache" python3 "$SIM_ROOT/scripts/collect-simslim-licenses.py" \
  "$SIM_GO" "$SIM_SOURCE" "$SIM_OUTPUT" "$SIM_COMMIT" "$SIM_SHA"
printf '%s\n' "$SIM_OUTPUT/simslim"
