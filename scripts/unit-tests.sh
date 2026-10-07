#!/bin/bash

# Unit Test Script for Ctrlx
# Runs all unit tests in the CtrlxPackage via swift test

set -eo pipefail

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PACKAGE_DIR="$PROJECT_ROOT/CtrlxPackage"
SAVE_SPACE=false

# =====================================================
# PARSE ARGUMENTS
# =====================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--save-space] [-- SWIFT_TEST_ARGS...]"
            echo ""
            echo "Runs unit tests with swiftbuild and indexing disabled."
            echo "After success, removes obsolete backend caches and indexes."
            echo "--save-space also removes test compilation caches; keeps products and downloads."
            echo ""
            echo "Any arguments after -- are passed through to swift test."
            echo ""
            echo "Examples:"
            echo "  $0                              Run all tests"
            echo "  $0 -- --filter Networking        Run only Networking tests"
            echo "  $0 -- --filter TerminalCopyTests  Run a specific test suite"
            exit 0
            ;;
        --save-space)
            SAVE_SPACE=true
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1 (use -- to pass args to swift test)"
            exit 1
            ;;
    esac
done

for argument in "$@"; do
    case "$argument" in
        --build-system|--build-system=*|--scratch-path|--scratch-path=*|--package-path|--package-path=*|--enable-index-store|--auto-index-store)
            echo "Option $argument is managed by this script; use swift test directly for custom builds." >&2
            exit 1
            ;;
    esac
done

# =====================================================
# HELPERS
# =====================================================

# Terminal colors (disabled when NO_COLOR is set or stdout is not a tty)
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    _BOLD=$'\033[1m'
    _RED=$'\033[31m'
    _GREEN=$'\033[32m'
    _CYAN=$'\033[36m'
    _RESET=$'\033[0m'
else
    _BOLD="" _RED="" _GREEN="" _CYAN="" _RESET=""
fi

# =====================================================
# RUN TESTS
# =====================================================
echo ""
echo "${_CYAN}${_BOLD}>>> Running unit tests${_RESET}"
echo ""

cd "$PACKAGE_DIR"
# Override the deployment target used by swiftc when building the SPM
# test bundle. Without this, SPM links the test bundle with macOS 11.0 as its
# minimum deployment target (the swiftc default for the host), which produces
# linker warnings against swift-testing and XCTestSwiftSupport built for 14.0+.
HOST_ARCH="$(uname -m)"
EXIT_CODE=0
swift test --parallel --build-system swiftbuild --disable-index-store \
    -Xswiftc -target -Xswiftc "${HOST_ARCH}-apple-macos15.0" \
    "$@" || EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "${_GREEN}${_BOLD}All unit tests passed.${_RESET}"
    CLEANUP_ARGS=(tests --yes)
    if [ "$SAVE_SPACE" = true ]; then
        CLEANUP_ARGS+=(--save-space)
    fi
    python3 "$SCRIPT_DIR/clean-build.py" "${CLEANUP_ARGS[@]}"
else
    echo "${_RED}${_BOLD}Unit tests failed (exit code: $EXIT_CODE).${_RESET}"
fi

exit $EXIT_CODE
