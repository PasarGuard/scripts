#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$APP_TMP_DIR"

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/env.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

assert_grep() {
    local pattern="$1" file="$2" label="$3"
    if grep -qF "$pattern" "$file"; then pass "$label"; else fail "$label (pattern='$pattern' not in file)"; fi
}

assert_no_grep() {
    local pattern="$1" file="$2" label="$3"
    if ! grep -qF "$pattern" "$file"; then pass "$label"; else fail "$label (pattern='$pattern' should NOT be in file)"; fi
}

ENV_FILE="$WORK_DIR/test.env"

echo "=== unit_lib_env.sh ==="

# -----------------------------------------------------------------------
# replace_or_append_env_var
# -----------------------------------------------------------------------
echo "FOO=old_value" > "$ENV_FILE"

replace_or_append_env_var "FOO" "new_value" false "$ENV_FILE"
assert_grep "FOO=new_value" "$ENV_FILE" "replace_or_append: replaces existing key"
assert_no_grep "FOO=old_value" "$ENV_FILE" "replace_or_append: old value removed"

replace_or_append_env_var "BAR" "bar_val" false "$ENV_FILE"
assert_grep "BAR=bar_val" "$ENV_FILE" "replace_or_append: appends new key"

replace_or_append_env_var "QUOTED" 'my value' true "$ENV_FILE"
assert_grep 'QUOTED="my value"' "$ENV_FILE" "replace_or_append: quotes value when asked"

# -----------------------------------------------------------------------
# set_or_uncomment_env_var
# -----------------------------------------------------------------------
cat > "$ENV_FILE" <<'EOF'
# MYKEY = old_commented
OTHERKEY=unchanged
EOF

set_or_uncomment_env_var "MYKEY" "activated" false "$ENV_FILE"
assert_grep "MYKEY = activated" "$ENV_FILE" "set_or_uncomment: uncomments and sets key"
assert_no_grep "# MYKEY" "$ENV_FILE" "set_or_uncomment: comment line removed"
assert_grep "OTHERKEY=unchanged" "$ENV_FILE" "set_or_uncomment: leaves other keys alone"

# Key that doesn't exist at all — should be appended
set_or_uncomment_env_var "NEWKEY" "newval" false "$ENV_FILE"
assert_grep "NEWKEY = newval" "$ENV_FILE" "set_or_uncomment: appends missing key"

# With quoting
set_or_uncomment_env_var "QKEY" "val with spaces" true "$ENV_FILE"
assert_grep 'QKEY = "val with spaces"' "$ENV_FILE" "set_or_uncomment: quotes value when asked"

# -----------------------------------------------------------------------
# comment_out_env_var
# -----------------------------------------------------------------------
cat > "$ENV_FILE" <<'EOF'
ACTIVE_KEY=active_value
KEEP_KEY=keep_value
EOF

comment_out_env_var "ACTIVE_KEY" "$ENV_FILE"
assert_grep "# ACTIVE_KEY" "$ENV_FILE" "comment_out: key is commented"
assert_no_grep "^ACTIVE_KEY=" "$ENV_FILE" "comment_out: uncommented form removed"
assert_grep "KEEP_KEY=keep_value" "$ENV_FILE" "comment_out: other key untouched"

# Calling on already-commented key should be idempotent (no crash)
comment_out_env_var "ACTIVE_KEY" "$ENV_FILE"
pass "comment_out: idempotent on already-commented key"

# Calling on non-existent file returns without error
comment_out_env_var "NOKEY" "/nonexistent/path.env"
pass "comment_out: no error on missing file"

# -----------------------------------------------------------------------
# delete_env_var
# -----------------------------------------------------------------------
cat > "$ENV_FILE" <<'EOF'
DEL_KEY=to_be_deleted
STAY_KEY=stays
EOF

delete_env_var "DEL_KEY" "$ENV_FILE"
assert_no_grep "DEL_KEY" "$ENV_FILE" "delete_env_var: key is deleted"
assert_grep "STAY_KEY=stays" "$ENV_FILE" "delete_env_var: other key untouched"

# Deleting non-existent key is a no-op
delete_env_var "NOSUCHKEY" "$ENV_FILE"
pass "delete_env_var: no error when key doesn't exist"

# Non-existent file returns without error
delete_env_var "KEY" "/nonexistent/path.env"
pass "delete_env_var: no error on missing file"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
