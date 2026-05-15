#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/lib/common.sh"
# Source restore.sh - we only need the redaction function
# We might need to stub out dependencies if sourcing fails
source "$ROOT_DIR/lib/pasarguard-restore.sh" || true

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_lib_restore.sh ==="

# -----------------------------------------------------------------------
# redact_database_url
# -----------------------------------------------------------------------
assert_eq "$(redact_database_url "postgresql://user:pass@localhost:5432/db")" "postgresql://REDACTED@localhost:5432/db" \
    "redact_database_url: redacts postgres URL"

assert_eq "$(redact_database_url "mysql://root:secret@127.0.0.1/mydb")" "mysql://REDACTED@127.0.0.1/mydb" \
    "redact_database_url: redacts mysql URL"

assert_eq "$(redact_database_url "sqlite:////path/to/db")" "sqlite:////path/to/db" \
    "redact_database_url: leaves sqlite alone (no user/pass)"

assert_eq "$(redact_database_url "")" "not set" \
    "redact_database_url: handles empty string"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
