#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_doctor.sh ==="

# -----------------------------------------------------------------------
# Test pasarguard.sh doctor command
# -----------------------------------------------------------------------
export PASARGUARD_SOURCE_ONLY="true"
# shellcheck source=pasarguard.sh
source "$ROOT_DIR/pasarguard.sh"

# Verify doctor_command and mirror_command functions exist
if declare -F doctor_command >/dev/null; then
    pass "pasarguard: doctor_command function is defined"
else
    fail "pasarguard: doctor_command function is defined"
fi

if declare -F mirror_command >/dev/null; then
    pass "pasarguard: mirror_command function is defined"
else
    fail "pasarguard: mirror_command function is defined"
fi

# Run pasarguard doctor with mocked healthy environment
APP_DIR="$WORK_DIR/opt/pasarguard"
DATA_DIR="$WORK_DIR/var/lib/pasarguard"
ENV_FILE="$APP_DIR/.env"
mkdir -p "$APP_DIR" "$DATA_DIR"
cat << 'EOF' > "$ENV_FILE"
APP_NAME=pasarguard
UVICORN_PORT=8000
EOF

docker() {
    if [ "${1:-}" = "info" ]; then return 0; fi
    if [ "${1:-}" = "--version" ]; then echo "Docker version 26.0.0, build 2ae087a"; return 0; fi
    if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then echo "Docker Compose version v2.27.0"; return 0; fi
    return 0
}
export -f docker

id() { echo "0"; }
export -f id

doctor_out=$(doctor_command 2>&1)
if echo "$doctor_out" | grep -q "Operating System: Linux"; then
    pass "pasarguard doctor: checks operating system"
else
    fail "pasarguard doctor: checks operating system"
fi

if echo "$doctor_out" | grep -q "Docker Engine is active"; then
    pass "pasarguard doctor: detects active Docker Engine"
else
    fail "pasarguard doctor: detects active Docker Engine"
fi

if echo "$doctor_out" | grep -q "App directory writable"; then
    pass "pasarguard doctor: verifies app directory write permission"
else
    fail "pasarguard doctor: verifies app directory write permission"
fi

if echo "$doctor_out" | grep -q "Environment file exists"; then
    pass "pasarguard doctor: verifies environment file presence"
else
    fail "pasarguard doctor: verifies environment file presence"
fi

# -----------------------------------------------------------------------
# Test pg-node.sh doctor command
# -----------------------------------------------------------------------
export PG_NODE_SOURCE_ONLY="true"
# shellcheck source=pg-node.sh
source "$ROOT_DIR/pg-node.sh"

if declare -F doctor_command >/dev/null; then
    pass "pg-node: doctor_command function is defined"
else
    fail "pg-node: doctor_command function is defined"
fi

if declare -F mirror_command >/dev/null; then
    pass "pg-node: mirror_command function is defined"
else
    fail "pg-node: mirror_command function is defined"
fi

NODE_APP_DIR="$WORK_DIR/opt/pg-node"
NODE_DATA_DIR="$WORK_DIR/var/lib/pg-node"
mkdir -p "$NODE_APP_DIR" "$NODE_DATA_DIR/certs"
cat << 'EOF' > "$NODE_APP_DIR/.env"
SERVICE_PORT=62050
API_PORT=62051
API_KEY=test-secret-key-1234
EOF

APP_DIR="$NODE_APP_DIR"
DATA_DIR="$NODE_DATA_DIR"
node_doctor_out=$(doctor_command 2>&1)

if echo "$node_doctor_out" | grep -q "API_KEY is configured"; then
    pass "pg-node doctor: verifies API_KEY configured"
else
    fail "pg-node doctor: verifies API_KEY configured"
fi

if echo "$node_doctor_out" | grep -q "Node app directory writable"; then
    pass "pg-node doctor: verifies node app directory writable"
else
    fail "pg-node doctor: verifies node app directory writable"
fi

unset -f docker
unset -f id

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
