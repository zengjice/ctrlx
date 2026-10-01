#!/bin/bash

# Shared helpers for the CtrlX release scripts.
# Source this file after computing SCRIPT_DIR and defining CONFIG_FILE (and,
# for generate_changelog, PROJECT_ROOT):
#
#   source "$SCRIPT_DIR/common.sh"
#
# It only defines helpers — it does not set shell options or run anything at
# source time, so it is safe to source early.

# =====================================================
# Colors for output
# =====================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =====================================================
# Logging
# =====================================================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }  # exits

# =====================================================
# Version helpers (require CONFIG_FILE to be set by the caller)
# =====================================================
get_version() {
    grep "^MARKETING_VERSION" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' '
}

get_build_number() {
    grep "^CURRENT_PROJECT_VERSION" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' '
}

get_build_stamp() {
    date -u '+%Y%m%d-%H%M%S'
}

get_source_revision() {
    get_full_source_revision
}

get_full_source_revision() {
    git -C "$PROJECT_ROOT" rev-parse HEAD
}

load_project_environment() {
    local root="${1:-$PROJECT_ROOT}"
    local candidate line key value

    for candidate in .env.local .env.production .env.development .env.test; do
        [ -f "$root/$candidate" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ''|'#'*) continue ;;
            esac
            line="${line#export }"
            key="${line%%=*}"
            value="${line#*=}"
            case "$key" in
                ''|*[!A-Za-z0-9_]*) log_error "Invalid key in $candidate: $key" ;;
            esac
            if [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ]; then
                value="${value#\"}"
                value="${value%\"}"
            elif [ "${value#\'}" != "$value" ] && [ "${value%\'}" != "$value" ]; then
                value="${value#\'}"
                value="${value%\'}"
            fi
            export "$key=$value"
        done < "$root/$candidate"
        CTRLX_ENV_FILE="$root/$candidate"
        export CTRLX_ENV_FILE
        return 0
    done
    return 0
}

write_artifact_metadata() {
    local artifact="$1"
    local checksum manifest full_revision source_url
    [ -f "$artifact" ] || log_error "Artifact not found: $artifact"

    full_revision="$(get_full_source_revision)"
    source_url="https://github.com/jicezeng/CtrlX/tree/$full_revision"
    checksum="$(shasum -a 256 "$artifact" | awk '{print $1}')"
    printf '%s  %s\n' "$checksum" "$(basename "$artifact")" > "$artifact.sha256"

    manifest="$artifact.manifest.json"
    ARTIFACT_NAME="$(basename "$artifact")" \
    ARTIFACT_SHA256="$checksum" \
    CTRLX_VERSION="$(get_version)" \
    CTRLX_BUILD="$(get_build_number)" \
    CTRLX_SOURCE_REVISION="$full_revision" \
    CTRLX_SOURCE_URL="$source_url" \
        python3 - <<'PY' > "$manifest"
import json
import os

print(json.dumps({
    "product": "CtrlX",
    "version": os.environ["CTRLX_VERSION"],
    "build": os.environ["CTRLX_BUILD"],
    "artifact": os.environ["ARTIFACT_NAME"],
    "sha256": os.environ["ARTIFACT_SHA256"],
    "commit": os.environ["CTRLX_SOURCE_REVISION"],
    "source": os.environ["CTRLX_SOURCE_URL"],
    "license": "AGPL-3.0-only",
}, indent=2, sort_keys=True))
PY
}

assert_git_worktree() {
    local git_root project_root
    git_root=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) \
        || log_error 'Packaging requires a Git worktree.'
    project_root=$(cd "$PROJECT_ROOT" && pwd -P)
    git_root=$(cd "$git_root" && pwd -P)

    if [ "$project_root" != "$git_root" ]; then
        log_error "Packaging must run from the Git worktree root: $git_root"
    fi
}

prune_local_artifacts() {
    local arguments=(prune --artifact "$1" --yes)
    if [ "$#" -eq 2 ]; then
        arguments+=(--platform "$2")
    fi
    python3 "$SCRIPT_DIR/clean-build.py" "${arguments[@]}"
}

find_apple_development_identity() {
    local team_id="${1:-}"
    local identity_hash certificate_name subject

    while IFS=$'\t' read -r identity_hash certificate_name; do
        [ -n "$identity_hash" ] || continue
        if [ -z "$team_id" ]; then
            printf '%s\n' "$identity_hash"
            return 0
        fi

        subject=$(
            /usr/bin/security find-certificate -c "$certificate_name" -p 2>/dev/null \
                | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null
        ) || continue
        case ",$subject," in
            *",OU=$team_id,"*)
                printf '%s\n' "$identity_hash"
                return 0
                ;;
        esac
    done < <(
        /usr/bin/security find-identity -v -p codesigning \
            | /usr/bin/awk -F'"' '/Apple Development:/ {
                prefix = $1
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", prefix)
                split(prefix, fields, /[[:space:]]+/)
                print fields[2] "\t" $2
            }'
    )

    return 1
}

read_xcconfig_value() {
    local file="$1"
    local key="$2"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" \
        | tail -1 \
        | sed 's/[[:space:]]*\/\/.*$//' \
        | xargs
}

# =====================================================
# Offer to edit generated notes in $VISUAL / $EDITOR
# Sets the edited (or original) text in EDITED_NOTES.
# =====================================================
EDITED_NOTES=""
offer_to_edit_notes() {
    local notes="$1"
    local label="$2"
    local filename="$3"

    EDITED_NOTES="$notes"

    read -p "Do you want to edit the $label before continuing? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi

    local editor="${VISUAL:-${EDITOR:-vi}}"

    local tmp_dir
    tmp_dir=$(mktemp -d) || {
        log_warning "Could not create a temp directory — skipping edit"
        return
    }
    local tmp_file="$tmp_dir/$filename"

    printf '%s\n' "$notes" > "$tmp_file"

    # Open the editor and wait for it to close, then read the result back.
    if ! $editor "$tmp_file"; then
        log_warning "Editor exited with a non-zero status — using the saved file contents"
    fi

    EDITED_NOTES=$(cat "$tmp_file")
    rm -rf "$tmp_dir"

    log_success "Using edited $label"
}

# =====================================================
# Generate TestFlight "What to Test" notes with Claude.
# Requires PROJECT_ROOT to be set by the caller.
#
# Args:
#   $1 version   - marketing version to reference in the notes
#                  (defaults to get_version)
#   $2 prev_tag  - previous release tag to diff against. If empty, the most
#                  recent tag that is NOT $version is used. Pass this
#                  explicitly when generating notes BEFORE the release tag
#                  exists (e.g. release.sh gathers them up front).
#
# Prints the notes to stdout; all logging goes to stderr.
# =====================================================
generate_changelog() {
    local version="${1:-$(get_version)}"
    local prev_tag="$2"

    if [ -z "$prev_tag" ]; then
        prev_tag=$(git -C "$PROJECT_ROOT" tag --sort=-v:refname \
            | grep -Ev "^v?${version}$" \
            | head -1)
    fi

    local commit_range
    if [ -z "$prev_tag" ]; then
        log_warning "No previous tag found, using last 20 commits" >&2
        commit_range="HEAD~20..HEAD"
    else
        log_info "Generating changelog since $prev_tag" >&2
        commit_range="${prev_tag}..HEAD"
    fi

    local commits
    commits=$(git -C "$PROJECT_ROOT" log "$commit_range" --pretty=format:"- %s (%h)" --no-merges 2>/dev/null || echo "Initial release")

    if ! command -v claude &> /dev/null; then
        log_warning "Claude CLI not found, using raw commit list" >&2
        echo "$commits"
        return
    fi

    log_info "Generating What to Test notes with Claude..." >&2

    local prompt="You are a technical writer creating TestFlight 'What to Test' notes for testers.

Generate concise, tester-friendly notes for version $version of CtrlX, an iOS app for remotely monitoring coding-agent terminal sessions.

IMPORTANT: CtrlX is an independent AGPL-3.0 distribution based on Gallager. It is not affiliated with or endorsed by Gallager or any coding-agent provider.

Here are the commits since the last release:
$commits

Requirements:
- ONLY include changes that directly affect the user experience on iOS (new features, behavior changes, bug fixes users would notice, performance improvements)
- ONLY include changes from shared layers (networking, encryption, server relay) if they have a visible effect on the iOS app
- SKIP anything that does not affect users: CI/CD changes, build scripts, internal refactoring, code cleanup, dependency updates, tests, docs, tooling, release scripts, macOS-only changes, server infrastructure changes invisible to users
- If a commit is ambiguous, err on the side of omitting it
- Group changes by category (New Features, Improvements, Bug Fixes) if applicable
- Explain what each change means for testers — what to look for, what might break
- Keep it concise but informative — this is TestFlight, not a press release
- Use plain text, no markdown (TestFlight renders plain text only)
- Do NOT wrap output in code fences, backticks, or any formatting wrappers
- Do NOT include ANY preamble, commentary, thinking, or meta-text — start directly with the content
- Do NOT add URLs, links, or 'for more information' sections
- Output ONLY the What to Test content itself
- If no user-facing iOS changes exist, output: No user-facing changes in this build."

    local notes
    notes=$(claude -p "$prompt" 2>/dev/null) || {
        log_warning "Claude failed to generate notes, using raw commit list" >&2
        echo "$commits"
        return
    }

    # Strip code fences in case Claude ignored the instruction to omit them
    notes=$(echo "$notes" | sed '/^```/d')

    echo "$notes"
}
