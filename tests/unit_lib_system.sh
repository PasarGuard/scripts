#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/system.sh"

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

echo "=== unit_lib_system.sh ==="

# -----------------------------------------------------------------------
# check_running_as_root
# -----------------------------------------------------------------------
id() { echo "1000"; }
export -f id
assert_exit 1 "check_running_as_root: fails when not root" check_running_as_root

id() { echo "0"; }
export -f id
assert_exit 0 "check_running_as_root: passes when root" check_running_as_root
unset -f id

# -----------------------------------------------------------------------
# detect_os
# -----------------------------------------------------------------------
OS_RELEASE="$WORK_DIR/os-release"
mkdir -p "$(dirname "$OS_RELEASE")"
# Note: detect_os in system.sh uses /etc/os-release hardcoded.
# To test it, we'd need to mock 'cat' or 'awk' if it reads from there,
# or better, refactor the function to accept a path.
# Since we can't change the function easily without risk, let's mock awk.
awk() {
    if [[ "$*" == *"NAME"* && "$*" == *"/etc/os-release"* ]]; then
        echo "Ubuntu"
        return 0
    fi
    command awk "$@"
}
export -f awk
detect_os
assert_eq "$OS" "Ubuntu" "detect_os: identifies Ubuntu from mocked awk"
unset -f awk

# -----------------------------------------------------------------------
# identify_the_operating_system_and_architecture
# -----------------------------------------------------------------------
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
        "") echo "Darwin" ;;
    esac
}
export -f uname
assert_exit 1 "identify_the_operating_system_and_architecture: fails on non-Linux" identify_the_operating_system_and_architecture
unset -f uname

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
