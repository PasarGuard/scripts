#!/usr/bin/env bash
# =============================================================================
# unit_backup_dump_flags.sh - SQL dump invocations used by `pasarguard backup`
# must never lock the tables: every $dump_cmd exec carries --single-transaction.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pasarguard-dump-flags-unit"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR"

# A fake docker CLI: records every exec call so the test can assert on the
# arguments the dump was invoked with. Compose lists the mysql service.
FAKE_DOCKER_DIR="$WORK_DIR/fake-docker"
export FAKE_DOCKER_DIR
mkdir -p "$WORK_DIR/bin" "$FAKE_DOCKER_DIR"
: >"$FAKE_DOCKER_DIR/calls.log"
cat >"$WORK_DIR/bin/docker" <<'FAKE'
#!/usr/bin/env bash
d="${FAKE_DOCKER_DIR:?}"
printf '%s\n' "$*" >>"$d/calls.log"
case "$*" in
    compose*" config --services"*) printf 'pasarguard\n' ;;
    compose*" ps -q "*|"compose ps -q "*) printf 'cid\n' ;;
    compose*" ps -a -q "*) printf 'cid-%s\n' "${@: -1}" ;;
    "inspect --format {{.Image}} cid-"*) printf 'sha256:%s\n' "$(printf '1%.0s' {1..64})" ;;
    "image inspect --format"*) printf 'example/%s@sha256:%s\n' "svc" "$(printf '2%.0s' {1..64})" ;;
    ps*) printf 'cid\n' ;;
    exec*) exit 0 ;;
    *) exit 1 ;;
esac
FAKE
chmod 755 "$WORK_DIR/bin/docker"
export PATH="$WORK_DIR/bin:$PATH"

curl() { echo ""; return 0; }
export -f curl

export PASARGUARD_SOURCE_ONLY="true"
# shellcheck source=pasarguard.sh
source "$ROOT_DIR/pasarguard.sh"
set +e
set -uo pipefail
# shellcheck disable=SC2034 # read by the dump helpers under test
COMPOSE="docker compose"

PASS=0
FAIL=0
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
assert_true() { local l="$1"; shift; if "$@"; then pass "$l"; else fail "$l"; fi; }
assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_backup_dump_flags.sh ==="

# -----------------------------------------------------------------------
# Every mysqldump / mariadb-dump exec site carries --single-transaction
# -----------------------------------------------------------------------
# Static check first: the flag appears next to every dump exec ("$dump_cmd"
# and the direct mariadb-dump calls), so a new call site cannot silently
# reintroduce table locks.
dump_sites="$(grep -nE 'docker exec .*("\$dump_cmd"|mariadb-dump) -u' "$ROOT_DIR/lib/pasarguard-backup.sh")"
total_sites="$(printf '%s\n' "$dump_sites" | grep -c .)"
flagged_sites="$(printf '%s\n' "$dump_sites" | grep -c -- '--single-transaction')"
assert_eq "$total_sites" "7" "dump flags: found all 7 mysqldump/mariadb-dump exec sites"
assert_eq "$flagged_sites" "$total_sites" "dump flags: all $total_sites dump exec sites carry --single-transaction"

# Dynamic check: run the MySQL backup path with the fake docker and confirm
# the recorded exec arguments really contain the flag.
stage="$WORK_DIR/run"
mkdir -p "$stage" "$APP_DIR"
printf 'SQLALCHEMY_DATABASE_URL=mysql+pymysql://pasarguard:pw@127.0.0.1:3306/pasarguard\n' >"$APP_DIR/.env"
printf 'MYSQL_ROOT_PASSWORD=rootpw\n' >>"$APP_DIR/.env"
printf 'SQLALCHEMY_DATABASE_URL=mysql+pymysql://pasarguard:pw@127.0.0.1:3306/pasarguard\n' >"$stage/.env"
printf 'MYSQL_ROOT_PASSWORD=rootpw\n' >>"$stage/.env"
: >"$FAKE_DOCKER_DIR/calls.log"
mkdir -p "$APP_DIR"
(backup_command backup "$stage") >"$WORK_DIR/run.out" 2>"$WORK_DIR/run.err"
assert_true "dump flags: recorded exec args contain --single-transaction" grep -q -- '--single-transaction' "$FAKE_DOCKER_DIR/calls.log"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
