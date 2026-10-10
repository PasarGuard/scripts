#!/usr/bin/env bash
# =============================================================================
# unit_backup_metadata.sh - Recovery metadata written by `pasarguard backup`:
# the checksum inventory and backup-runtime.tsv, without a real Docker daemon.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pasarguard-metadata-unit"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR"

# A fake docker CLI: Compose lists the services in $FAKE_DOCKER_DIR/services,
# every service has container cid-<service> running image sha256:<64 x 1>,
# whose registry digest is example/svc@sha256:<64 x 2>.
FAKE_DOCKER_DIR="$WORK_DIR/fake-docker"
export FAKE_DOCKER_DIR
mkdir -p "$WORK_DIR/bin" "$FAKE_DOCKER_DIR"
cat >"$WORK_DIR/bin/docker" <<'FAKE'
#!/usr/bin/env bash
d="${FAKE_DOCKER_DIR:?}"
printf '%s\n' "$*" >>"$d/calls.log"
case "$*" in
    compose*" config --services"*) cat "$d/services" ;;
    compose*" ps -a -q "*) printf 'cid-%s\n' "${@: -1}" ;;
    "inspect --format {{.Image}} cid-"*) printf 'sha256:%s\n' "$(printf '1%.0s' {1..64})" ;;
    "image inspect --format"*) printf 'example/%s@sha256:%s\n' "svc" "$(printf '2%.0s' {1..64})" ;;
    *) exit 1 ;;
esac
FAKE
chmod 755 "$WORK_DIR/bin/docker"
export PATH="$WORK_DIR/bin:$PATH"

# Stub network access at source time, as unit_pasarguard.sh does.
curl() { echo ""; return 0; }
export -f curl

export PASARGUARD_SOURCE_ONLY="true"
# shellcheck source=pasarguard.sh
source "$ROOT_DIR/pasarguard.sh"
set +e
set -uo pipefail
# shellcheck disable=SC2034 # read by write_backup_runtime
COMPOSE="docker compose"

PASS=0
FAIL=0
# Record and print a passed test assertion.
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
# Record and print a failed test assertion.
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
# Assert that the given command evaluates to true (zero exit status).
assert_true() { local l="$1"; shift; if "$@"; then pass "$l"; else fail "$l"; fi; }
# Assert that the given command evaluates to false (nonzero exit status).
assert_false() { local l="$1"; shift; if ! "$@"; then pass "$l"; else fail "$l"; fi; }
# Assert equality between actual and expected values.
assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}
# Print one value from a backup-runtime.tsv.
runtime_value() { awk -F '\t' -v key="$2" '$1 == key {print $2; exit}' "$1/backup-runtime.tsv"; }

echo "=== unit_backup_metadata.sh ==="

# -----------------------------------------------------------------------
# write_backup_checksums: unusual file names never fail the backup
# -----------------------------------------------------------------------
stage="$WORK_DIR/checksums"
mkdir -p "$stage/pasarguard_data"
printf 'SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/pasarguard/db.sqlite3\n' >"$stage/.env"
printf 'cert\n' >"$stage/pasarguard_data/cert.pem"
printf 'odd\n' >"$stage/pasarguard_data/back\\slash.txt"
printf 'odd\n' >"$stage/pasarguard_data/new"$'\n'"line.txt"
printf 'odd\n' >"$stage/pasarguard_data/carriage"$'\r'".txt"
write_backup_checksums "$stage" 2>"$WORK_DIR/checksums.err"
assert_eq "$?" 0 "checksums: unusual file names do not fail the backup"
assert_true "checksums: regular names are listed" grep -qF './pasarguard_data/cert.pem' "$stage/backup-files.sha256"
assert_eq "$(grep -c 'slash\|line\.txt\|carriage' "$stage/backup-files.sha256")" 0 "checksums: names the inventory cannot hold are left out"
assert_eq "$(grep -c 'not in the checksum inventory' "$WORK_DIR/checksums.err")" 3 "checksums: each left-out file is reported"
assert_true "checksums: the inventory verifies with sha256sum" bash -c "cd '$stage' && sha256sum --check --status --strict backup-files.sha256"
printf 'format\t1\n' >"$stage/backup-runtime.tsv"
write_backup_checksums "$stage" 2>/dev/null
assert_true "checksums: restore accepts the inventory" verify_backup_checksums "$stage"

# -----------------------------------------------------------------------
# write_backup_runtime
# -----------------------------------------------------------------------
# Build a stage with an optional SQL dump header; $1 is the stage name.
new_stage() {
    stage="$WORK_DIR/runtime-$1"
    rm -rf "$stage"
    mkdir -p "$stage"
}
printf 'pasarguard\nmysql\n' >"$FAKE_DOCKER_DIR/services"

# Dump tool versions come from the dump header of each supported client.
dump_tool_case() {
    local label="$1" header="$2" expected="$3"
    new_stage "$label"
    printf '%s\n-- Server version\t8.0.43\nCREATE TABLE t (id int);\n-- Dump completed on 2026-10-01 00:00:00\n' "$header" >"$stage/db_backup.sql"
    (write_backup_runtime "$stage" mysql "" "$WORK_DIR/runtime.log" "" "" "" "") >/dev/null 2>&1
    assert_eq "$(runtime_value "$stage" dump_tool_version)" "$expected" "runtime: dump tool version from a $label header"
}
dump_tool_case "MySQL 8" '-- MySQL dump 10.13  Distrib 8.0.43, for Linux (x86_64)' "8.0.43"
dump_tool_case "MariaDB 11" '-- MariaDB dump 10.19  Distrib 10.11.6-MariaDB, for debian-linux-gnu (x86_64)' "10.11.6-MariaDB"
dump_tool_case "MariaDB 12" '-- MariaDB dump 10.19-12.3.2-MariaDB, for debian-linux-gnu (x86_64)' "12.3.2-MariaDB"

new_stage pg
mkdir -p "$stage/pg_dump"
printf -- '-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)\n-- Dumped by pg_dump version 16.14 (Debian 16.14-1.pgdg13+1)\n' >"$stage/pg_dump/db-001.sql"
(write_backup_runtime "$stage" postgresql "" "$WORK_DIR/runtime.log" "" "" "" "") >/dev/null 2>&1
assert_eq "$(runtime_value "$stage" server_version)" "16.14 (Debian 16.14-1.pgdg13+1)" "runtime: PostgreSQL server version from the dump"
assert_eq "$(runtime_value "$stage" dump_tool_version)" "16.14 (Debian 16.14-1.pgdg13+1)" "runtime: pg_dump version from the dump"

# SQLite: the panel's SQLite library version is unknown here; the snapshot tool is recorded.
if command -v sqlite3 >/dev/null 2>&1; then
    new_stage sqlite
    sqlite3 "$stage/db.sqlite3" "CREATE TABLE alembic_version (version_num varchar(32)); INSERT INTO alembic_version VALUES ('rev1');"
    (write_backup_runtime "$stage" sqlite "" "$WORK_DIR/runtime.log" "$DATA_DIR/db.sqlite3" "" "" "") >/dev/null 2>&1
    assert_eq "$(runtime_value "$stage" server_version)" "unknown" "runtime: SQLite server version is not guessed from the host CLI"
    assert_eq "$(runtime_value "$stage" dump_tool_version)" "sqlite3 $(sqlite3 --version | awk '{print $1}')" "runtime: SQLite snapshot tool recorded"
    assert_eq "$(runtime_value "$stage" schema_revision)" "rev1" "runtime: SQLite schema revision read from the snapshot"
else
    echo "(skipped SQLite runtime cases: sqlite3 unavailable)"
fi

# Compose allows service names that start with "_", "." or "-"; they must not fail the backup.
new_stage names
printf 'pasarguard\n_worker\n.hidden\n-dash\n' >"$FAKE_DOCKER_DIR/services"
: >"$FAKE_DOCKER_DIR/calls.log"
(write_backup_runtime "$stage" sqlite "" "$WORK_DIR/runtime.log" "" "" "" "") >/dev/null 2>&1
assert_eq "$?" 0 "runtime: Compose service names with a leading _, . or - accepted"
assert_eq "$(awk -F '\t' '$1 == "image" {print $2}' "$stage/backup-runtime.tsv" | paste -sd ' ')" "pasarguard _worker .hidden -dash" "runtime: every service recorded"
assert_true "runtime: a service name starting with - is not read as an option" grep -q 'ps -a -q -- -dash' "$FAKE_DOCKER_DIR/calls.log"
printf 'pasarguard\nbad\tname\n' >"$FAKE_DOCKER_DIR/services"
(write_backup_runtime "$stage" sqlite "" "$WORK_DIR/runtime.log" "" "" "" "") >/dev/null 2>&1
assert_eq "$?" 1 "runtime: a service name with a tab is still refused"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
