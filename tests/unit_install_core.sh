#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

export INSTALL_CORE_SOURCE_ONLY="true"
# shellcheck source=install_core.sh
source "$ROOT_DIR/install_core.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

assert_exit() {
    local expected_code="$1" label="$2"; shift 2
    local actual_code=0
    ( "$@" ) >/dev/null 2>&1 || actual_code=$?
    if [ "$actual_code" -eq "$expected_code" ]; then pass "$label"; else fail "$label (expected=$expected_code, got=$actual_code)"; fi
}

echo "=== unit_install_core.sh ==="

# -----------------------------------------------------------------------
# Architecture detection in install_core.sh
# -----------------------------------------------------------------------
TARGET_OS=""
TARGET_ARCH=""

uname() {
    case "${1:-}" in
        "") echo "Linux" ;;
        -m) echo "x86_64" ;;
    esac
}
export -f uname
identify_the_operating_system_and_architecture
assert_eq "$ARCH" "64" "identify_the_operating_system_and_architecture: x86_64 -> 64"

uname() {
    case "${1:-}" in
        "") echo "Linux" ;;
        -m) echo "aarch64" ;;
    esac
}
export -f uname
identify_the_operating_system_and_architecture
assert_eq "$ARCH" "arm64-v8a" "identify_the_operating_system_and_architecture: aarch64 -> arm64-v8a"

uname() {
    case "${1:-}" in
        "") echo "Linux" ;;
        -m) echo "i686" ;;
    esac
}
export -f uname
identify_the_operating_system_and_architecture
assert_eq "$ARCH" "32" "identify_the_operating_system_and_architecture: i686 -> 32"

# Explicit TARGET_ARCH takes precedence
TARGET_ARCH="mips32le"
identify_the_operating_system_and_architecture
assert_eq "$ARCH" "mips32le" "identify_the_operating_system_and_architecture: honors TARGET_ARCH"
TARGET_ARCH=""

# Non-linux OS rejected
uname() {
    case "${1:-}" in
        "") echo "Darwin" ;;
    esac
}
export -f uname
assert_exit 1 "identify_the_operating_system_and_architecture: fails on non-Linux" identify_the_operating_system_and_architecture
unset -f uname

# -----------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------
RELEASE_TAG="latest"
TARGET_OS=""
TARGET_ARCH=""
parse_args --tag v1.8.24 --os linux --arch arm64-v8a
assert_eq "$RELEASE_TAG" "v1.8.24" "parse_args: --tag parsed"
assert_eq "$TARGET_OS" "linux" "parse_args: --os parsed"
assert_eq "$TARGET_ARCH" "arm64-v8a" "parse_args: --arch parsed"

assert_exit 0 "parse_args: --help exits 0" parse_args --help
assert_exit 1 "parse_args: invalid option exits 1" parse_args --invalid-flag

# -----------------------------------------------------------------------
# Commit SHA resolution
# -----------------------------------------------------------------------
export PASARGUARD_SCRIPT_COMMIT="abcdef123456"
assert_eq "$(get_script_commit_sha)" "abcdef123456" "get_script_commit_sha: honors PASARGUARD_SCRIPT_COMMIT"
unset PASARGUARD_SCRIPT_COMMIT

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
