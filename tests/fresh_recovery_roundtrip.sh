#!/usr/bin/env bash
# =============================================================================
# fresh_recovery_roundtrip.sh - Real `pasarguard restore --fresh` round trip.
# Back up a source installation, remove it completely, recover it with --fresh,
# then check the data, the installed Compose file and the images that run.
#
# Usage: bash tests/fresh_recovery_roundtrip.sh ENGINE [healthcheck|no-healthcheck|failing-healthcheck]
#   ENGINE: sqlite | mysql | mariadb | postgresql | timescaledb
#   no-healthcheck: the archived database service has no Compose healthcheck.
#   failing-healthcheck: the archived healthcheck always fails, so the first
#   --fresh stops after provisioning; the same command is then run again and
#   must finish the recovery.
#
# Needs root (restore --fresh requires it), Docker with Compose v2, sqlite3, jq,
# rsync, zip and unzip. Everything it creates is its own: the Compose project
# ci-fresh-ENGINE, a mktemp directory under ${TMPDIR:-/tmp} and the image tag
# pasarguard-recovery-fixture/panel:latest. No ports are published.
#
# Optional environment:
#   FRESH_APP_IMAGE      placeholder panel image (default alpine:3.20)
#   FRESH_DB_IMAGE       database image for ENGINE
#   FRESH_PULL_IMAGES    true: also remove the fixture images after the backup,
#                        so recovery must pull the recorded digests (CI only:
#                        it deletes FRESH_APP_IMAGE and FRESH_DB_IMAGE locally)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
engine="${1:-}"
healthcheck="${2:-healthcheck}"
case "$healthcheck" in
    healthcheck | no-healthcheck | failing-healthcheck) ;;
    *) echo "usage: $0 ENGINE [healthcheck|no-healthcheck|failing-healthcheck]" >&2; exit 2 ;;
esac
if [ "${1:-}" = sqlite ] && [ "$healthcheck" = failing-healthcheck ]; then
    echo "failing-healthcheck needs a database service" >&2
    exit 2
fi

app_image="${FRESH_APP_IMAGE:-alpine:3.20}"
panel_ref="pasarguard-recovery-fixture/panel:latest"
db_image="" target="" dbservice=""
case "$engine" in
    sqlite) ;;
    mysql) db_image="${FRESH_DB_IMAGE:-mysql:8.0}"; target=/var/lib/mysql; dbservice=mysql ;;
    mariadb) db_image="${FRESH_DB_IMAGE:-mariadb:11.4}"; target=/var/lib/mysql; dbservice=mariadb ;;
    postgresql) db_image="${FRESH_DB_IMAGE:-postgres:16}"; target=/var/lib/postgresql/data; dbservice=postgresql ;;
    timescaledb) db_image="${FRESH_DB_IMAGE:-timescale/timescaledb:2.27.2-pg17}"; target=/var/lib/postgresql/data; dbservice=timescaledb ;;
    *) echo "usage: $0 ENGINE [healthcheck|no-healthcheck|failing-healthcheck]" >&2; exit 2 ;;
esac

root=$(mktemp -d "${TMPDIR:-/tmp}/pasarguard-fresh-recovery.XXXXXX")
export APP_NAME="ci-fresh-$engine" APP_DIR="$root/app" DATA_DIR="$root/data"
mkdir -p "$APP_DIR" "$DATA_DIR"
export PASARGUARD_SOURCE_ONLY=true
# shellcheck source=pasarguard.sh
source "$ROOT_DIR/pasarguard.sh"
detect_compose

# Run Compose for this test's project.
dc() { $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" "$@"; }
# Remove every container, volume and tag this test created. Best effort: the
# test result is decided before this runs.
cleanup() {
    if [ -f "$COMPOSE_FILE" ]; then dc down -v >/dev/null 2>&1 || true; fi
    docker image rm "$panel_ref" >/dev/null 2>&1 || true
    rm -rf "$root" || true
}
trap cleanup EXIT
# Stop the test with a message.
fail() { echo "FAIL: $*" >&2; exit 1; }

case "$engine" in
    sqlite) url="sqlite+aiosqlite:////${DATA_DIR#/}/db.sqlite3" ;;
    mysql | mariadb) url='mysql+asyncmy://appuser:fixture-password@127.0.0.1:3306/appdb' ;;
    postgresql | timescaledb) url='postgresql+asyncpg://appuser:fixture-password@127.0.0.1:5432/appdb' ;;
esac

# The placeholder panel image is only known locally under its Compose name, so
# recovery can only run it if --fresh recreates that name from the record.
docker image inspect "$app_image" >/dev/null 2>&1 || docker pull "$app_image" >/dev/null
docker tag "$app_image" "$panel_ref"

cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
MYSQL_ROOT_PASSWORD=fixture-password
DB_USER=appuser
DB_PASSWORD=fixture-password
DB_NAME=appdb
SQLALCHEMY_DATABASE_URL="$url"
EOF

# Write the Compose file; $1 is the database healthcheck mode (see usage).
write_compose() {
    cat >"$COMPOSE_FILE" <<EOF
services:
  pasarguard:
    image: $panel_ref
    command: ["sleep", "3600"]
    env_file: .env
    volumes:
      - $DATA_DIR:/var/lib/pasarguard
EOF
    [ "$engine" != sqlite ] || return 0
    cat >>"$COMPOSE_FILE" <<EOF
  $dbservice:
    image: $db_image
    environment:
      MYSQL_ROOT_PASSWORD: fixture-password
      MYSQL_DATABASE: appdb
      MYSQL_USER: appuser
      MYSQL_PASSWORD: fixture-password
      POSTGRES_USER: appuser
      POSTGRES_PASSWORD: fixture-password
      POSTGRES_DB: appdb
    volumes:
      - $DATA_DIR/$dbservice:$target
EOF
    case "$1" in
        no-healthcheck) return 0 ;;
        failing-healthcheck)
            printf '    healthcheck:\n      test: ["CMD", "false"]\n      interval: 1s\n      timeout: 1s\n      retries: 1\n' >>"$COMPOSE_FILE"
            return 0
            ;;
    esac
    case "$engine" in
        mysql) printf '    healthcheck:\n      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u root --password=fixture-password"]\n' ;;
        mariadb) printf '    healthcheck:\n      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]\n' ;;
        postgresql | timescaledb) printf '    healthcheck:\n      test: ["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "appuser", "-d", "appdb"]\n' ;;
    esac >>"$COMPOSE_FILE"
    printf '      interval: 3s\n      timeout: 3s\n      retries: 60\n' >>"$COMPOSE_FILE"
}

# Run SQL as the application user; prints the result rows.
run_sql() {
    local cid="$1" sql="$2"
    case "$engine" in
        sqlite) sqlite3 "$DATA_DIR/db.sqlite3" "$sql" ;;
        mysql) docker exec -e MYSQL_PWD=fixture-password "$cid" mysql -u appuser appdb -N -s -e "$sql" ;;
        mariadb) docker exec -e MYSQL_PWD=fixture-password "$cid" mariadb -u appuser appdb -N -s -e "$sql" ;;
        postgresql | timescaledb) docker exec -e PGPASSWORD=fixture-password "$cid" psql -X -U appuser -d appdb -v ON_ERROR_STOP=1 -At -c "$sql" ;;
    esac
}

# Wait up to 120 s until the database answers over TCP inside its container,
# whatever its healthcheck says.
wait_until_database_answers() {
    local cid="$1" port=5432 attempt
    case "$engine" in mysql | mariadb) port=3306 ;; esac
    for ((attempt = 0; attempt < 60; attempt++)); do
        if recovery_database_responds "$cid" "$engine" "$port" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    return 1
}

# The source always starts with a healthcheck so the fixture data can be written
# once the database is ready; the archived Compose file decides what --fresh sees.
write_compose healthcheck
dc up -d --wait --wait-timeout 240
cid=""
if [ "$engine" != sqlite ]; then cid=$(dc ps -q "$dbservice"); fi
if [ "$engine" = timescaledb ]; then run_sql "$cid" 'CREATE EXTENSION IF NOT EXISTS timescaledb;' >/dev/null; fi
run_sql "$cid" "CREATE TABLE ci_recovery (value integer); INSERT INTO ci_recovery VALUES (42); CREATE TABLE alembic_version (version_num varchar(32)); INSERT INTO alembic_version VALUES ('fixture_revision');" >/dev/null
printf 'original-state\n' >"$DATA_DIR/sentinel.txt"
write_compose "$healthcheck"

backup_command
archive=$(find "$APP_DIR/backup" -maxdepth 1 -name '*.zip' | head -n 1)
[ -n "$archive" ] || fail "backup produced no archive"
cp "$archive" "$root/recovery.zip"
unzip -p "$root/recovery.zip" docker-compose.yml >"$root/archived-compose.yml"
unzip -p "$root/recovery.zip" backup-runtime.tsv >"$root/runtime.tsv"
cat "$root/runtime.tsv"
awk -F '\t' '$1 == "image" && $3 != "unavailable"' "$root/runtime.tsv" | grep -q . || fail "no image digest recorded"

# Emulate complete server loss: no containers, files or local image names left.
dc down -v
mv "$APP_DIR" "$root/lost-app"
mv "$DATA_DIR" "$root/lost-data"
docker image rm "$panel_ref" >/dev/null
if [ "${FRESH_PULL_IMAGES:-false}" = true ]; then
    docker image rm "$app_image" ${db_image:+"$db_image"} >/dev/null
fi

(restore_command "$root/recovery.zip" --check)
[ ! -e "$APP_DIR" ] || fail "--check created the application directory"

started=$(date +%s)
if [ "$healthcheck" = failing-healthcheck ]; then
    if (restore_command "$root/recovery.zip" --fresh --yes); then
        fail "--fresh succeeded although the database never became healthy"
    fi
    [ -f "$APP_DIR/.pasarguard-fresh-restore" ] || fail "no retry marker after the failed --fresh"
    # As an administrator would after reading the log: let the database finish
    # starting, then run the same command again.
    wait_until_database_answers "$(dc ps -q "$dbservice")" || fail "database did not answer after the failed --fresh"
    echo "first --fresh stopped as expected; running the same command again"
fi
(restore_command "$root/recovery.zip" --fresh --yes)
[ ! -e "$APP_DIR/.pasarguard-fresh-restore" ] || fail "retry marker left after a successful restore"
echo "fresh recovery took $(($(date +%s) - started))s"

[ "$(cat "$DATA_DIR/sentinel.txt")" = original-state ] || fail "data file not restored"
cmp -s "$root/archived-compose.yml" "$COMPOSE_FILE" || fail "installed docker-compose.yml differs from the archived one"
[ ! -f "$APP_DIR/backup-runtime.tsv" ] || fail "recovery metadata left in the application directory"
[ ! -f "$APP_DIR/backup-files.sha256" ] || fail "checksum inventory left in the application directory"

# Every service runs exactly the image recorded at backup time.
while IFS=$'\t' read -r kind service _digest image_id; do
    [ "$kind" = image ] || continue
    running=$(docker inspect --format '{{.Image}}' "$(dc ps -q "$service")")
    [ "$running" = "$image_id" ] || fail "$service runs $running, backup recorded $image_id"
done <"$root/runtime.tsv"

if [ "$engine" != sqlite ]; then
    dc restart "$dbservice"
    [ "$healthcheck" = failing-healthcheck ] || dc up -d --wait --wait-timeout 180 "$dbservice"
    cid=$(dc ps -q "$dbservice")
    if [ "$healthcheck" != healthcheck ]; then
        wait_until_database_answers "$cid" || fail "database did not answer after restart"
    fi
fi
[ "$(run_sql "$cid" 'SELECT value FROM ci_recovery;')" = 42 ] || fail "database row not restored"

echo "PASS: $engine fresh recovery ($healthcheck): data restored, Compose file unchanged, recorded images running"
