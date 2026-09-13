#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/system.sh"
source "$ROOT_DIR/lib/docker.sh"

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

echo "=== unit_lib_docker.sh ==="

# -----------------------------------------------------------------------
# detect_compose
# -----------------------------------------------------------------------
docker() {
    if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
        echo "Docker Compose version v2.27.0"
        return 0
    fi
    command docker "$@" 2>/dev/null || return 1
}
export -f docker

COMPOSE=""
detect_compose
assert_eq "$COMPOSE" "docker compose" "detect_compose: sets COMPOSE to 'docker compose' when v2 available"

# When compose version fails
docker() {
    if [ "${1:-}" = "compose" ]; then
        return 1
    fi
}
export -f docker

assert_exit 1 "detect_compose: dies with error when compose v2 missing" detect_compose
unset -f docker

# -----------------------------------------------------------------------
# compose commands invocation
# -----------------------------------------------------------------------
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

mock_compose() {
    echo "$@" >> "$LOG_FILE"
}

COMPOSE="mock_compose"
export COMPOSE_FILE="/tmp/test-compose.yml"
export APP_NAME="testapp"

# compose_down
compose_down
assert_eq "$(cat "$LOG_FILE")" "-f /tmp/test-compose.yml -p testapp down" "compose_down: invokes compose down correctly"
: > "$LOG_FILE"

# compose_logs
compose_logs
assert_eq "$(cat "$LOG_FILE")" "-f /tmp/test-compose.yml -p testapp logs" "compose_logs: invokes compose logs correctly"
: > "$LOG_FILE"

# compose_logs_follow
compose_logs_follow
assert_eq "$(cat "$LOG_FILE")" "-f /tmp/test-compose.yml -p testapp logs -f" "compose_logs_follow: invokes compose logs -f correctly"
: > "$LOG_FILE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
