#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/system.sh"
source "$ROOT_DIR/lib/env.sh"
# shellcheck source=lib/pasarguard-backup.sh
source "$ROOT_DIR/lib/pasarguard-backup.sh"

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

echo "=== unit_backup_config.sh ==="

# -----------------------------------------------------------------------
# Schedule conversion
# -----------------------------------------------------------------------
assert_eq "$(backup_cron_from_interval_minutes 5)" "*/5 * * * *" "cron_from_minutes: 5 -> */5"
assert_eq "$(backup_cron_from_interval_minutes 15)" "*/15 * * * *" "cron_from_minutes: 15 -> */15"
assert_eq "$(backup_cron_from_interval_minutes 120)" "0 */2 * * *" "cron_from_minutes: 120 -> 0 */2"
assert_eq "$(backup_cron_from_interval_minutes 1440)" "0 0 * * *" "cron_from_minutes: 1440 -> 0 0"
assert_exit 1 "cron_from_minutes: invalid interval 7 rejects" backup_cron_from_interval_minutes 7
assert_exit 1 "cron_from_minutes: non-numeric rejects" backup_cron_from_interval_minutes "abc"

assert_eq "$(backup_interval_minutes_from_cron "0 0 * * *")" "1440" "minutes_from_cron: 0 0 * * * -> 1440"
assert_eq "$(backup_interval_minutes_from_cron "0 * * * *")" "60" "minutes_from_cron: 0 * * * * -> 60"
assert_eq "$(backup_interval_minutes_from_cron "0 */2 * * *")" "120" "minutes_from_cron: 0 */2 * * * -> 120"
assert_eq "$(backup_interval_minutes_from_cron "*/15 * * * *")" "15" "minutes_from_cron: */15 * * * * -> 15"
assert_eq "$(backup_interval_minutes_from_cron "unrecognized")" "" "minutes_from_cron: unrecognized -> empty"

# -----------------------------------------------------------------------
# Interval formatting
# -----------------------------------------------------------------------
assert_eq "$(format_backup_interval 1440)" "Daily at midnight (every 24 hours)" "format_backup_interval: 1440"
assert_eq "$(format_backup_interval 120)" "Every 2 hours" "format_backup_interval: 120"
assert_eq "$(format_backup_interval 60)" "Every hour" "format_backup_interval: 60"
assert_eq "$(format_backup_interval 15)" "Every 15 minutes" "format_backup_interval: 15"
assert_eq "$(format_backup_interval invalid Fallback)" "Fallback" "format_backup_interval: fallback on invalid"

# -----------------------------------------------------------------------
# Token masking
# -----------------------------------------------------------------------
assert_eq "$(mask_telegram_bot_key "123456789:ABCdefGHIjklMNO")" "****jklMNO" "mask_telegram_bot_key: masks token"
assert_eq "$(mask_telegram_bot_key "")" "" "mask_telegram_bot_key: empty string returns empty"

# -----------------------------------------------------------------------
# Dual-alias Telegram environment variable fallback
# -----------------------------------------------------------------------
ENV_FILE="$WORK_DIR/.env"

# Case 1: Canonical BACKUP_TELEGRAM_BOT_KEY and BACKUP_TELEGRAM_CHAT_ID
cat << 'EOF' > "$ENV_FILE"
BACKUP_SERVICE_ENABLED=true
BACKUP_TELEGRAM_BOT_KEY=canonical_key_123
BACKUP_TELEGRAM_CHAT_ID=-100111111
EOF

bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
[ -z "$bot_key" ] && bot_key=$(awk -F'=' '/^TELEGRAM_TOKEN=/ {print $2}' "$ENV_FILE")
chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
[ -z "$chat_id" ] && chat_id=$(awk -F'=' '/^TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")

assert_eq "$bot_key" "canonical_key_123" "telegram env: reads canonical bot key"
assert_eq "$chat_id" "-100111111" "telegram env: reads canonical chat id"

# Case 2: Legacy fallback TELEGRAM_TOKEN and TELEGRAM_CHAT_ID
cat << 'EOF' > "$ENV_FILE"
BACKUP_SERVICE_ENABLED=true
TELEGRAM_TOKEN=legacy_token_456
TELEGRAM_CHAT_ID=-100222222
EOF

bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
[ -z "$bot_key" ] && bot_key=$(awk -F'=' '/^TELEGRAM_TOKEN=/ {print $2}' "$ENV_FILE")
chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
[ -z "$chat_id" ] && chat_id=$(awk -F'=' '/^TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")

assert_eq "$bot_key" "legacy_token_456" "telegram env: falls back to TELEGRAM_TOKEN"
assert_eq "$chat_id" "-100222222" "telegram env: falls back to TELEGRAM_CHAT_ID"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
