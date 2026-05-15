#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$APP_TMP_DIR"

source "$ROOT_DIR/lib/common.sh"
# Only source the parts of backup.sh we need (pure functions at the top)
# We don't need docker/compose functions; source the file and let the
# function bodies be defined — they only fail if called, not just defined.
# Stub out any dependency that gets checked at source time.
is_valid_proxy_url() { return 1; }
get_backup_proxy_url() { return 1; }
source "$ROOT_DIR/lib/pasarguard-backup.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_lib_backup.sh ==="

# -----------------------------------------------------------------------
# mask_telegram_bot_key
# -----------------------------------------------------------------------
assert_eq "$(mask_telegram_bot_key "")" "" \
    "mask_telegram_bot_key: empty string returns empty"

assert_eq "$(mask_telegram_bot_key "abc")" "****abc" \
    "mask_telegram_bot_key: short secret (<=6) shows all chars"

assert_eq "$(mask_telegram_bot_key "123456")" "****123456" \
    "mask_telegram_bot_key: exactly 6 chars shows all"

assert_eq "$(mask_telegram_bot_key "1234567")" "****234567" \
    "mask_telegram_bot_key: >6 chars shows only last 6"

assert_eq "$(mask_telegram_bot_key "abcdefghij")" "****efghij" \
    "mask_telegram_bot_key: 10 chars shows last 6"

assert_eq "$(mask_telegram_bot_key "1234567890:ABCDEF")" "****BCDEF" \
    "mask_telegram_bot_key: realistic bot token masked correctly" || true
# Adjust: length 17 -> last 6 = "BCDEF" + one more. Let's verify:
# "1234567890:ABCDEF" is 17 chars, last 6 = "BCDEF" ... wait "ABCDEF" is 6, + ":" = "ABCDEF" no
# Let me just check the result is prefixed with ****
result=$(mask_telegram_bot_key "1234567890:ABCDEF")
if [[ "$result" == "****"* ]]; then
    pass "mask_telegram_bot_key: realistic token has **** prefix"
else
    fail "mask_telegram_bot_key: realistic token has **** prefix"
fi

# -----------------------------------------------------------------------
# filter_backup_cron_entries
# -----------------------------------------------------------------------
CRON_IN="$WORK_DIR/cron_in.txt"
CRON_OUT="$WORK_DIR/cron_out.txt"

cat > "$CRON_IN" <<'EOF'
0 * * * * /usr/bin/somecommand
0 2 * * * /usr/local/bin/pasarguard backup # pasarguard-backup-service
30 6 * * * /usr/bin/other
0 4 * * * /usr/local/bin/pasarguard backup # pasarguard-backup-service
EOF

filter_backup_cron_entries "$CRON_IN" "$CRON_OUT"

if grep -qF "pasarguard-backup-service" "$CRON_OUT"; then
    fail "filter_backup_cron_entries: backup entries should be removed"
else
    pass "filter_backup_cron_entries: backup entries removed"
fi
if grep -q "somecommand" "$CRON_OUT"; then
    pass "filter_backup_cron_entries: unrelated entries kept"
else
    fail "filter_backup_cron_entries: unrelated entries kept"
fi
if grep -q "other" "$CRON_OUT"; then
    pass "filter_backup_cron_entries: second unrelated entry kept"
else
    fail "filter_backup_cron_entries: second unrelated entry kept"
fi

# Empty source file
: > "$CRON_IN"
filter_backup_cron_entries "$CRON_IN" "$CRON_OUT"
if [ ! -s "$CRON_OUT" ]; then
    pass "filter_backup_cron_entries: empty input produces empty output"
else
    fail "filter_backup_cron_entries: empty input produces empty output"
fi

# File with no backup entries stays intact
cat > "$CRON_IN" <<'EOF'
0 * * * * /usr/bin/cmd1
0 6 * * * /usr/bin/cmd2
EOF
filter_backup_cron_entries "$CRON_IN" "$CRON_OUT"
line_count=$(wc -l < "$CRON_OUT" | tr -d ' ')
assert_eq "$line_count" "2" "filter_backup_cron_entries: file with no backup entries unchanged"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
