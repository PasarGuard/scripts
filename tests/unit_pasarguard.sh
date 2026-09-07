#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pasarguard-unit-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

# Stub everything that pasarguard.sh tries to set up at source time
# so it doesn't fail or make network calls.
curl() {
    # Suppress all curl calls during sourcing to avoid network dependency
    case "${1:-}" in
        -s|-4|-fsSL) echo "" ;;
        *) echo "" ;;
    esac
    return 0
}
export -f curl

export PASARGUARD_SOURCE_ONLY="true"
# shellcheck source=pasarguard.sh
source "$ROOT_DIR/pasarguard.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_true() {
    local label="$1"; shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

assert_false() {
    local label="$1"; shift
    if ! "$@"; then pass "$label"; else fail "$label"; fi
}

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_pasarguard.sh ==="

# -----------------------------------------------------------------------
# is_valid_proxy_url
# -----------------------------------------------------------------------
assert_true  "is_valid_proxy_url: http://"     is_valid_proxy_url "http://proxy.example.com:8080"
assert_true  "is_valid_proxy_url: https://"    is_valid_proxy_url "https://proxy.example.com:8080"
assert_true  "is_valid_proxy_url: socks5://"   is_valid_proxy_url "socks5://127.0.0.1:1080"
assert_true  "is_valid_proxy_url: socks5h://"  is_valid_proxy_url "socks5h://127.0.0.1:1080"
assert_true  "is_valid_proxy_url: socks4://"   is_valid_proxy_url "socks4://10.0.0.1:1080"
assert_true  "is_valid_proxy_url: socks4a://"  is_valid_proxy_url "socks4a://10.0.0.1:1080"
assert_true  "is_valid_proxy_url: socks://"    is_valid_proxy_url "socks://10.0.0.1:1080"
assert_false "is_valid_proxy_url: ftp://"      is_valid_proxy_url "ftp://proxy.example.com"
assert_false "is_valid_proxy_url: no-scheme"   is_valid_proxy_url "proxy.example.com"
assert_false "is_valid_proxy_url: empty"       is_valid_proxy_url ""
assert_false "is_valid_proxy_url: just text"   is_valid_proxy_url "notaurl"

# -----------------------------------------------------------------------
# is_domain
# -----------------------------------------------------------------------
assert_true  "is_domain: simple"        is_domain "example.com"
assert_true  "is_domain: subdomain"     is_domain "panel.example.com"
assert_true  "is_domain: deep"          is_domain "a.b.c.example.com"
assert_true  "is_domain: hyphen"        is_domain "my-panel.example.com"
assert_true  "is_domain: long tld"      is_domain "example.computer"
assert_false "is_domain: bare label"    is_domain "localhost"
assert_false "is_domain: IP"            is_domain "192.168.1.1"
assert_false "is_domain: empty"         is_domain ""
assert_false "is_domain: with space"    is_domain "exam ple.com"
assert_false "is_domain: with slash"    is_domain "example.com/path"

# -----------------------------------------------------------------------
# is_ipv4
# -----------------------------------------------------------------------
assert_true  "is_ipv4: valid 1"      is_ipv4 "192.168.1.1"
assert_true  "is_ipv4: valid 2"      is_ipv4 "0.0.0.0"
assert_true  "is_ipv4: valid 3"      is_ipv4 "255.255.255.255"
assert_true  "is_ipv4: valid 4"      is_ipv4 "10.0.0.1"
assert_false "is_ipv4: octet > 255"  is_ipv4 "256.0.0.1"
assert_false "is_ipv4: 3 octets"     is_ipv4 "192.168.1"
assert_false "is_ipv4: 5 octets"     is_ipv4 "1.2.3.4.5"
assert_false "is_ipv4: letters"      is_ipv4 "abc.def.ghi.jkl"
assert_false "is_ipv4: empty"        is_ipv4 ""
assert_false "is_ipv4: domain"       is_ipv4 "example.com"

# -----------------------------------------------------------------------
# is_ipv6
# -----------------------------------------------------------------------
assert_true  "is_ipv6: full"            is_ipv6 "2001:db8::1"
assert_true  "is_ipv6: loopback"        is_ipv6 "::1"
assert_true  "is_ipv6: double colon"    is_ipv6 "::"
assert_false "is_ipv6: ipv4"            is_ipv6 "192.168.1.1"
assert_false "is_ipv6: plain text"      is_ipv6 "example.com"
assert_false "is_ipv6: empty"           is_ipv6 ""

# -----------------------------------------------------------------------
# has_nonempty_ssl_pair
# -----------------------------------------------------------------------
CERT="$WORK_DIR/cert.pem"
KEY="$WORK_DIR/key.pem"

# Both files empty
: > "$CERT"; : > "$KEY"
assert_false "has_nonempty_ssl_pair: both empty" has_nonempty_ssl_pair "$CERT" "$KEY"

# Cert non-empty, key empty
echo "CERT" > "$CERT"; : > "$KEY"
assert_false "has_nonempty_ssl_pair: key empty" has_nonempty_ssl_pair "$CERT" "$KEY"

# Key non-empty, cert empty
: > "$CERT"; echo "KEY" > "$KEY"
assert_false "has_nonempty_ssl_pair: cert empty" has_nonempty_ssl_pair "$CERT" "$KEY"

# Both non-empty
echo "CERT" > "$CERT"; echo "KEY" > "$KEY"
assert_true  "has_nonempty_ssl_pair: both present" has_nonempty_ssl_pair "$CERT" "$KEY"

# Missing files
assert_false "has_nonempty_ssl_pair: cert missing" has_nonempty_ssl_pair "/no/cert.pem" "$KEY"
assert_false "has_nonempty_ssl_pair: key missing"  has_nonempty_ssl_pair "$CERT" "/no/key.pem"

# -----------------------------------------------------------------------
# get_backup_proxy_url
# -----------------------------------------------------------------------
unset BACKUP_PROXY_URL BACKUP_PROXY BACKUP_PROXY_ENABLED 2>/dev/null || true
assert_false "get_backup_proxy_url: no vars set" get_backup_proxy_url

export BACKUP_PROXY_URL="http://proxy.example.com:8080"
result=$(get_backup_proxy_url)
if [ "$result" = "http://proxy.example.com:8080" ]; then
    pass "get_backup_proxy_url: returns BACKUP_PROXY_URL"
else
    fail "get_backup_proxy_url: returns BACKUP_PROXY_URL (got='$result')"
fi

export BACKUP_PROXY_ENABLED="false"
assert_false "get_backup_proxy_url: BACKUP_PROXY_ENABLED=false suppresses" get_backup_proxy_url

export BACKUP_PROXY_ENABLED="true"
assert_true  "get_backup_proxy_url: BACKUP_PROXY_ENABLED=true allows" get_backup_proxy_url

unset BACKUP_PROXY_URL
export BACKUP_PROXY="socks5://127.0.0.1:1080"
unset BACKUP_PROXY_ENABLED
result2=$(get_backup_proxy_url)
if [ "$result2" = "socks5://127.0.0.1:1080" ]; then
    pass "get_backup_proxy_url: falls back to BACKUP_PROXY"
else
    fail "get_backup_proxy_url: falls back to BACKUP_PROXY (got='$result2')"
fi

# -----------------------------------------------------------------------
# backup_cron_from_interval_minutes
# -----------------------------------------------------------------------
assert_eq "$(backup_cron_from_interval_minutes 5)"    "*/5 * * * *"  "cron_from_minutes: 5 -> */5"
assert_eq "$(backup_cron_from_interval_minutes 15)"   "*/15 * * * *" "cron_from_minutes: 15 -> */15"
assert_eq "$(backup_cron_from_interval_minutes 30)"   "*/30 * * * *" "cron_from_minutes: 30 -> */30"
assert_eq "$(backup_cron_from_interval_minutes 60)"   "0 */1 * * *"  "cron_from_minutes: 60 -> hourly"
assert_eq "$(backup_cron_from_interval_minutes 120)"  "0 */2 * * *"  "cron_from_minutes: 120 -> every 2h"
assert_eq "$(backup_cron_from_interval_minutes 360)"  "0 */6 * * *"  "cron_from_minutes: 360 -> every 6h"
assert_eq "$(backup_cron_from_interval_minutes 1440)" "0 0 * * *"    "cron_from_minutes: 1440 -> daily"
assert_false "cron_from_minutes: 7 invalid"    backup_cron_from_interval_minutes 7
assert_false "cron_from_minutes: 90 invalid"   backup_cron_from_interval_minutes 90
assert_false "cron_from_minutes: 1441 invalid" backup_cron_from_interval_minutes 1441
assert_false "cron_from_minutes: 0 invalid"    backup_cron_from_interval_minutes 0
assert_false "cron_from_minutes: abc invalid"  backup_cron_from_interval_minutes abc

# -----------------------------------------------------------------------
# backup_interval_minutes_from_cron
# -----------------------------------------------------------------------
assert_eq "$(backup_interval_minutes_from_cron "0 0 * * *")"   "1440" "minutes_from_cron: daily -> 1440"
assert_eq "$(backup_interval_minutes_from_cron "0 */6 * * *")" "360"  "minutes_from_cron: every 6h -> 360"
assert_eq "$(backup_interval_minutes_from_cron "0 */1 * * *")" "60"   "minutes_from_cron: every 1h -> 60"
assert_eq "$(backup_interval_minutes_from_cron "0 * * * *")"   "60"   "minutes_from_cron: hourly form -> 60"
assert_eq "$(backup_interval_minutes_from_cron "*/15 * * * *")" "15"  "minutes_from_cron: every 15m -> 15"
assert_eq "$(backup_interval_minutes_from_cron "*/30 * * * *")" "30"  "minutes_from_cron: every 30m -> 30"
assert_eq "$(backup_interval_minutes_from_cron "15 */6 * * *")" ""    "minutes_from_cron: unsupported -> empty"

# -----------------------------------------------------------------------
# format_backup_interval
# -----------------------------------------------------------------------
assert_eq "$(format_backup_interval 1440)" "Daily at midnight (every 24 hours)" "format: 1440"
assert_eq "$(format_backup_interval 120)"  "Every 2 hours"                       "format: 120"
assert_eq "$(format_backup_interval 360)"  "Every 6 hours"                       "format: 360"
assert_eq "$(format_backup_interval 60)"   "Every hour"                          "format: 60"
assert_eq "$(format_backup_interval 30)"   "Every 30 minutes"                    "format: 30"
assert_eq "$(format_backup_interval 5)"    "Every 5 minutes"                     "format: 5"
assert_eq "$(format_backup_interval "" "0 7 * * *")" "0 7 * * *"                 "format: empty -> raw cron fallback"
assert_eq "$(format_backup_interval "")"   "Unknown"                             "format: empty -> Unknown default"

# -----------------------------------------------------------------------
# pg_dump_index_filename
# -----------------------------------------------------------------------
assert_eq "$(pg_dump_index_filename 1)"   "db-001.sql" "index_filename: 1"
assert_eq "$(pg_dump_index_filename 42)"  "db-042.sql" "index_filename: 42"
assert_eq "$(pg_dump_index_filename 100)" "db-100.sql" "index_filename: 100"

# -----------------------------------------------------------------------
# pg_manifest_encode  (round-trip via IFS=$'\t' read)
# -----------------------------------------------------------------------
_mline=$(pg_manifest_encode "mydb" "appuser" "0" "db-001.sql")
IFS=$'\t' read -r _m_db _m_owner _m_ts _m_file <<<"$_mline"
assert_eq "$_m_db"    "mydb"       "manifest: dbname field"
assert_eq "$_m_owner" "appuser"    "manifest: owner field"
assert_eq "$_m_ts"    "0"          "manifest: has_ts field"
assert_eq "$_m_file"  "db-001.sql" "manifest: filename field"

_mline2=$(pg_manifest_encode "my db" "own er" "1" "db-002.sql")
IFS=$'\t' read -r _n_db _n_owner _n_ts _n_file <<<"$_mline2"
assert_eq "$_n_db"  "my db" "manifest: dbname with space"
assert_eq "$_n_owner" "own er" "manifest: owner with space"
assert_eq "$_n_ts"  "1"     "manifest: has_ts=1"
assert_eq "$_n_file" "db-002.sql" "manifest: filename with spaced fields"

assert_false "manifest: rejects tab in dbname" pg_manifest_encode "$(printf 'a\tb')" "o" "0" "f.sql"
assert_false "manifest: rejects tab in owner" pg_manifest_encode "db" "$(printf 'a\tb')" "0" "f.sql"
assert_false "manifest: rejects tab in filename" pg_manifest_encode "db" "owner" "0" "$(printf 'a\tb')"
assert_false "manifest: rejects newline in dbname" pg_manifest_encode "$(printf 'a\nb')" "owner" "0" "f.sql"
assert_false "manifest: rejects newline in owner"    pg_manifest_encode "db" "$(printf 'a\nb')" "0" "f.sql"
assert_false "manifest: rejects newline in filename" pg_manifest_encode "db" "owner" "0" "$(printf 'a\nb')"
assert_eq "$(pg_manifest_encode "$(printf 'a\tb')" "owner" "0" "f.sql")" "" "manifest: rejection emits nothing"

# ts_version (5th field)
_tsline=$(pg_manifest_encode "tsdb" "owner" "1" "db-003.sql" "2.27.2")
IFS=$'\t' read -r _t_db _t_owner _t_ts _t_file _t_ver <<<"$_tsline"
assert_eq "$_t_db"   "tsdb"        "manifest: ts dbname"
assert_eq "$_t_ts"   "1"           "manifest: ts has_ts"
assert_eq "$_t_file" "db-003.sql"  "manifest: ts filename"
assert_eq "$_t_ver"  "2.27.2"      "manifest: ts_version field round-trips"

_ntline=$(pg_manifest_encode "plain" "owner" "0" "db-004.sql" "")
IFS=$'\t' read -r _p_db _p_owner _p_ts _p_file _p_ver <<<"$_ntline"
assert_eq "$_p_ver" "" "manifest: empty ts_version for non-timescale db"

# legacy 4-field line read back with 5 vars -> ts_version empty, has_ts preserved
IFS=$'\t' read -r _l_db _l_owner _l_ts _l_file _l_ver <<<"$(printf 'olddb\towner\t1\tdb-001.sql')"
assert_eq "$_l_ver" ""  "manifest: legacy 4-field line -> empty ts_version"
assert_eq "$_l_ts"  "1" "manifest: legacy has_ts preserved"

assert_false "manifest: rejects tab in ts_version"     pg_manifest_encode "db" "o" "1" "f.sql" "$(printf '2\t7')"
assert_false "manifest: rejects newline in ts_version" pg_manifest_encode "db" "o" "1" "f.sql" "$(printf '2\n7')"

# -----------------------------------------------------------------------
# database backup completeness validation
# -----------------------------------------------------------------------
DB_VALIDATION_DIR="$WORK_DIR/db-validation"
mkdir -p "$DB_VALIDATION_DIR"

printf '%s\n' \
    '-- MySQL dump 10.13  Distrib 8.0.43' \
    'CREATE TABLE users (id int);' \
    '-- Dump completed on 2026-08-01 12:00:00' >"$DB_VALIDATION_DIR/db_backup.sql"
assert_true "backup validation: complete MySQL dump accepted" \
    database_backup_looks_restorable mysql "$DB_VALIDATION_DIR" appdb ""
sed -i '$d' "$DB_VALIDATION_DIR/db_backup.sql"
assert_false "backup validation: truncated MySQL dump rejected" \
    database_backup_looks_restorable mysql "$DB_VALIDATION_DIR" appdb ""

printf '%s\n' \
    '-- PostgreSQL database dump' \
    'CREATE TABLE public.users (id integer);' \
    '-- PostgreSQL database dump complete' >"$DB_VALIDATION_DIR/db_backup.sql"
assert_true "backup validation: complete PostgreSQL single dump accepted" \
    database_backup_looks_restorable postgresql "$DB_VALIDATION_DIR" appdb ""
sed -i '$d' "$DB_VALIDATION_DIR/db_backup.sql"
assert_false "backup validation: truncated PostgreSQL single dump rejected" \
    database_backup_looks_restorable timescaledb "$DB_VALIDATION_DIR" appdb ""

rm -f "$DB_VALIDATION_DIR/db_backup.sql"
mkdir -p "$DB_VALIDATION_DIR/pg_dump"
printf '%s\n' \
    '-- PostgreSQL database cluster dump' \
    'CREATE ROLE appuser;' \
    '-- PostgreSQL database cluster dump complete' >"$DB_VALIDATION_DIR/pg_dump/globals.sql"
printf '%s\n' \
    '-- PostgreSQL database dump' \
    'CREATE TABLE public.users (id integer);' \
    '-- PostgreSQL database dump complete' >"$DB_VALIDATION_DIR/pg_dump/db-001.sql"
printf '%s\n' "$(pg_manifest_encode appdb appuser 1 db-001.sql 2.27.2)" >"$DB_VALIDATION_DIR/pg_dump/manifest.tsv"
assert_true "backup validation: complete TimescaleDB multi dump accepted" \
    database_backup_looks_restorable timescaledb "$DB_VALIDATION_DIR" appdb ""
assert_false "backup validation: configured PostgreSQL database must be present" \
    database_backup_looks_restorable postgresql "$DB_VALIDATION_DIR" missingdb ""
printf '%s\n' "$(pg_manifest_encode appdb appuser 0 db-001.sql '')" >"$DB_VALIDATION_DIR/pg_dump/manifest.tsv"
assert_true "backup validation: PostgreSQL manifest with empty ts_version accepted" \
    database_backup_looks_restorable postgresql "$DB_VALIDATION_DIR" appdb ""

SQLITE_VALIDATION_DIR="$WORK_DIR/sqlite-validation"
mkdir -p "$SQLITE_VALIDATION_DIR"
printf 'sqlite fixture\n' >"$SQLITE_VALIDATION_DIR/app.sqlite3"
sqlite3() {
    [ "$2" = "PRAGMA quick_check;" ] || return 1
    printf 'ok\n'
}
assert_true "backup validation: SQLite quick_check success accepted" \
    database_backup_looks_restorable sqlite "$SQLITE_VALIDATION_DIR" "" /source/app.sqlite3
sqlite3() { printf 'database disk image is malformed\n'; }
assert_false "backup validation: corrupt SQLite snapshot rejected" \
    database_backup_looks_restorable sqlite "$SQLITE_VALIDATION_DIR" "" /source/app.sqlite3
unset -f sqlite3

# A multi-database PostgreSQL/TimescaleDB backup must be atomic. Previously the
# helper returned success as long as any one database dumped successfully.
MOCK_PG_FAIL_DB=""
docker() {
    local joined="$*"
    case "$joined" in
        *" pg_dumpall "*)
            printf '%s\n' '-- PostgreSQL database cluster dump' '-- PostgreSQL database cluster dump complete'
            ;;
        *"SELECT datname FROM pg_database"*)
            printf '%s\n' appdb analytics
            ;;
        *"pg_get_userbyid"*)
            printf 'appuser\n'
            ;;
        *"SELECT extversion FROM pg_extension"*)
            return 0
            ;;
        *" pg_dump "*)
            if [ -n "$MOCK_PG_FAIL_DB" ] && [[ "$joined" == *" -d $MOCK_PG_FAIL_DB "* ]]; then
                return 1
            fi
            printf '%s\n' \
                '-- PostgreSQL database dump' \
                'CREATE TABLE public.events (id integer);' \
                '-- PostgreSQL database dump complete'
            ;;
        *)
            return 1
            ;;
    esac
}

PG_ATOMIC_DIR="$WORK_DIR/pg-atomic-success"
mkdir -p "$PG_ATOMIC_DIR"
assert_true "pg multi backup: every database plus configured database succeeds" \
    pg_dump_all_user_databases pg appuser pass "$PG_ATOMIC_DIR" "$WORK_DIR/pg-success.log" appdb
assert_true "pg multi backup: completed artifact passes final validation" \
    postgres_backup_looks_restorable "$PG_ATOMIC_DIR" appdb

PG_PARTIAL_DIR="$WORK_DIR/pg-atomic-partial"
mkdir -p "$PG_PARTIAL_DIR"
MOCK_PG_FAIL_DB="analytics"
assert_false "pg multi backup: one failed database fails the whole operation" \
    pg_dump_all_user_databases pg appuser pass "$PG_PARTIAL_DIR" "$WORK_DIR/pg-partial.log" appdb
assert_false "pg multi backup: partial dump directory is removed" test -d "$PG_PARTIAL_DIR/pg_dump"

PG_MISSING_DIR="$WORK_DIR/pg-atomic-missing-app"
mkdir -p "$PG_MISSING_DIR"
MOCK_PG_FAIL_DB=""
assert_false "pg multi backup: missing configured database fails the operation" \
    pg_dump_all_user_databases pg appuser pass "$PG_MISSING_DIR" "$WORK_DIR/pg-missing.log" missingdb
assert_false "pg multi backup: missing-app dump directory is removed" test -d "$PG_MISSING_DIR/pg_dump"
unset -f docker

# -----------------------------------------------------------------------
# get_acme_sh_binary
# -----------------------------------------------------------------------
MOCK_HOME="$WORK_DIR/mock_home"
mkdir -p "$MOCK_HOME/.acme.sh"
touch "$MOCK_HOME/.acme.sh/acme.sh"
chmod +x "$MOCK_HOME/.acme.sh/acme.sh"

# Mock HOME for this test
ORIG_HOME="$HOME"
export HOME="$MOCK_HOME"

assert_eq "$(get_acme_sh_binary)" "$MOCK_HOME/.acme.sh/acme.sh" \
    "get_acme_sh_binary: finds acme.sh in HOME/.acme.sh"

rm -rf "$MOCK_HOME/.acme.sh"
# Should check /root/.acme.sh (but we can't easily mock that if not root)
# Let's mock 'command -v acme.sh'
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "acme.sh" ]]; then
        echo "/usr/bin/acme.sh"
        return 0
    fi
    builtin command "$@"
}
export -f command
assert_eq "$(get_acme_sh_binary)" "/usr/bin/acme.sh" \
    "get_acme_sh_binary: finds acme.sh in PATH"
unset -f command

export HOME="$ORIG_HOME"

# -----------------------------------------------------------------------
# compose_service_exists & detect_pasarguard_backend_service
# -----------------------------------------------------------------------
# Mock COMPOSE to return specific services
COMPOSE_MOCK_FILE="$WORK_DIR/compose_mock.sh"
cat > "$COMPOSE_MOCK_FILE" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--services"* ]]; then
    echo "panel"
    echo "postgres"
    echo "redis"
elif [[ "$*" == *"config"* ]]; then
    cat <<'EOM'
services:
  panel:
    image: pasarguard/panel
    labels:
      ROLE: backend
  postgres:
    image: postgres
EOM
fi
EOF
chmod +x "$COMPOSE_MOCK_FILE"
COMPOSE="$COMPOSE_MOCK_FILE"

assert_true  "compose_service_exists: panel exists"  compose_service_exists "panel"
assert_false "compose_service_exists: missing service" compose_service_exists "missing"

assert_eq "$(detect_pasarguard_backend_service)" "panel" \
    "detect_pasarguard_backend_service: identifies panel as backend"

# Test fallback logic in detect_pasarguard_backend_service
cat > "$COMPOSE_MOCK_FILE" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--services"* ]]; then
    echo "pasarguard"
elif [[ "$*" == *"config"* ]]; then
    echo "services: { pasarguard: { labels: { ROLE: backend } } }"
fi
EOF
assert_eq "$(detect_pasarguard_backend_service)" "pasarguard" \
    "detect_pasarguard_backend_service: identifies pasarguard as fallback"

# -----------------------------------------------------------------------
# is_port_in_use
# -----------------------------------------------------------------------
# Mock port monitoring commands
ss() {
    if [[ "${1:-}" == "-ltn" ]]; then
        echo "LISTEN 0 128 *:55555 *:* "
        echo "LISTEN 0 128 *:443 *:* "
        return 0
    fi
    return 1
}
netstat() {
    if [[ "${1:-}" == "-lnt" ]]; then
        echo "tcp 0 0 0.0.0.0:55555 0.0.0.0:* LISTEN"
        echo "tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN"
        return 0
    fi
    return 1
}
export -f ss netstat
assert_true  "is_port_in_use: detects port 55555" is_port_in_use 55555
assert_false "is_port_in_use: port 9000 free"  is_port_in_use 9000
unset -f ss netstat

# -----------------------------------------------------------------------
# build_pasarguard_ssl_reload_command
# -----------------------------------------------------------------------
# With panel detected
cat > "$COMPOSE_MOCK_FILE" <<'EOF'
#!/usr/bin/env bash
echo "panel"
EOF
cmd=$(build_pasarguard_ssl_reload_command)
if [[ "$cmd" == *"restart panel"* ]]; then
    pass "build_pasarguard_ssl_reload_command: restarts specific service"
else
    fail "build_pasarguard_ssl_reload_command: restarts specific service (got: $cmd)"
fi

# With no service detected
cat > "$COMPOSE_MOCK_FILE" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cmd2=$(build_pasarguard_ssl_reload_command)
if [[ "$cmd2" == *"restart"* && ! "$cmd2" == *"restart panel"* ]]; then
    pass "build_pasarguard_ssl_reload_command: restarts entire stack as fallback"
else
    fail "build_pasarguard_ssl_reload_command: restarts entire stack as fallback"
fi

# -----------------------------------------------------------------------
# is_pasarguard_installed  (APP_DIR is a temp dir we created)
# -----------------------------------------------------------------------
assert_true  "is_pasarguard_installed: APP_DIR exists"    is_pasarguard_installed
rm -rf "$APP_DIR"
assert_false "is_pasarguard_installed: APP_DIR removed"   is_pasarguard_installed
mkdir -p "$APP_DIR"

# -----------------------------------------------------------------------
# pg_backup_layout
# -----------------------------------------------------------------------
PGL_DIR="$WORK_DIR/pglayout"
mkdir -p "$PGL_DIR"
assert_eq "$(pg_backup_layout "$PGL_DIR")" "none"   "layout: empty -> none"
touch "$PGL_DIR/db_backup.sql"
assert_eq "$(pg_backup_layout "$PGL_DIR")" "single" "layout: db_backup.sql -> single"
mkdir -p "$PGL_DIR/pg_dump"
touch "$PGL_DIR/pg_dump/manifest.tsv"
assert_eq "$(pg_backup_layout "$PGL_DIR")" "multi"  "layout: manifest present -> multi (precedence)"

# -----------------------------------------------------------------------
# pg_filter_timescaledb_extension_lines
# -----------------------------------------------------------------------
_ts_out=$(printf '%s\n' \
    "CREATE EXTENSION IF NOT EXISTS timescaledb;" \
    "CREATE TABLE foo (id int);" \
    "DROP EXTENSION timescaledb;" \
    "INSERT INTO foo VALUES (1);" | pg_filter_timescaledb_extension_lines)
_ts_expected=$(printf '%s\n' "CREATE TABLE foo (id int);" "INSERT INTO foo VALUES (1);")
assert_eq "$_ts_out" "$_ts_expected" "ts_filter: removes timescaledb extension lines, keeps rest"

# -----------------------------------------------------------------------
# timescaledb_version_matches
# -----------------------------------------------------------------------
assert_true  "ts_match: equal"           timescaledb_version_matches "2.27.2" "2.27.2"
assert_false "ts_match: differ"          timescaledb_version_matches "2.27.2" "2.15.0"
assert_false "ts_match: source vs empty" timescaledb_version_matches "2.27.2" ""

# -----------------------------------------------------------------------
# format_timescaledb_mismatch_help
# -----------------------------------------------------------------------
contains() { [[ "$1" == *"$2"* ]]; }
_help=$(format_timescaledb_mismatch_help "pasarguard" "2.27.2" "2.15.0" "17" "pasarguard")
assert_true "help: shows source version"  contains "$_help" "timescaledb 2.27.2"
assert_true "help: shows target version"  contains "$_help" "timescaledb 2.15.0"
assert_true "help: exact image tag"       contains "$_help" "timescale/timescaledb:2.27.2-pg17"
assert_true "help: data untouched"        contains "$_help" "untouched"
assert_true "help: this-server warning"   contains "$_help" "do NOT run this on your main server"
assert_true "help: uses edit subcommand"  contains "$_help" "pasarguard edit"
assert_true "help: uses restart subcmd"   contains "$_help" "pasarguard restart"

_help2=$(format_timescaledb_mismatch_help "db" "2.27.2" "" "" "pasarguard")
assert_true "help: target not installed"  contains "$_help2" "not installed"
assert_true "help: pgNN placeholder"      contains "$_help2" "pgNN"

# -----------------------------------------------------------------------
# get_cron_package_name
# -----------------------------------------------------------------------
_saved_os="${OS:-}"
OS="Ubuntu";               assert_eq "$(get_cron_package_name)" "cron"   "cron_pkg: Ubuntu -> cron"
OS="Debian GNU/Linux";     assert_eq "$(get_cron_package_name)" "cron"   "cron_pkg: Debian -> cron"
OS="CentOS Linux";         assert_eq "$(get_cron_package_name)" "cronie" "cron_pkg: CentOS -> cronie"
OS="Rocky Linux";          assert_eq "$(get_cron_package_name)" "cronie" "cron_pkg: Rocky -> cronie"
OS="Fedora Linux";         assert_eq "$(get_cron_package_name)" "cronie" "cron_pkg: Fedora -> cronie"
OS="Arch Linux";           assert_eq "$(get_cron_package_name)" "cronie" "cron_pkg: Arch -> cronie"
OS="openSUSE Tumbleweed";  assert_eq "$(get_cron_package_name)" "cronie" "cron_pkg: openSUSE -> cronie"
OS="Plan 9";               assert_false "cron_pkg: unknown OS -> non-zero" get_cron_package_name
OS="$_saved_os"

# -----------------------------------------------------------------------
# version-script CLI command & completion
# -----------------------------------------------------------------------
ver_out=$(pasarguard_main version-script)
assert_true "version-script: output contains '# Executing pasarguard script, commit:'" contains "$ver_out" "# Executing pasarguard script, commit:"

comp_out=$(generate_completion)
assert_true "completion: contains version-script" contains "$comp_out" "version-script"
assert_true "completion: contains script-version" contains "$comp_out" "script-version"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
