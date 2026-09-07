#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DB_TYPE="${1:-}"
ARCHIVE_MODE="${2:-single}"

if [ -z "$DB_TYPE" ]; then
    printf 'Usage: %s <sqlite|mysql|mariadb|postgresql|timescaledb> [single|multipart]\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi

case "$ARCHIVE_MODE" in
single | multipart) ;;
*)
    printf 'Unsupported archive mode: %s\n' "$ARCHIVE_MODE" >&2
    exit 1
    ;;
esac

# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/system.sh
source "$ROOT_DIR/lib/system.sh"
# shellcheck source=lib/docker.sh
source "$ROOT_DIR/lib/docker.sh"
# shellcheck source=lib/env.sh
source "$ROOT_DIR/lib/env.sh"
# shellcheck source=lib/pasarguard-backup.sh
source "$ROOT_DIR/lib/pasarguard-backup.sh"
# shellcheck source=lib/pasarguard-restore.sh
source "$ROOT_DIR/lib/pasarguard-restore.sh"

WORK_DIR="$(mktemp -d)"
APP_NAME="ci-${DB_TYPE}"
APP_DIR="$WORK_DIR/app"
DATA_DIR="$WORK_DIR/data"
ENV_FILE="$APP_DIR/.env"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
BACKUP_DIR="$APP_DIR/backup"
CONTAINER_NAME="${APP_NAME}-${DB_TYPE}"
MYSQL_ROOT_PASSWORD="rootpass"
DB_USER="appuser"
DB_PASSWORD="apppass"
CURRENT_DB_PASSWORD="currentpass"
DB_NAME="appdb"
EXPECTED_DB_VALUE="from_backup"
EXPECTED_SENTINEL_VALUE="sentinel-before-backup"
EXPECTED_ENV_FLAG="before-backup"
EXPECTED_COMPOSE_MARKER="# compose-state: before-backup"
ORIGINAL_ENV_SHA=""
ORIGINAL_COMPOSE_SHA=""
ORIGINAL_SENTINEL_SHA=""
ORIGINAL_PAYLOAD_SHA=""
ORIGINAL_SQLITE_DUMP_SHA=""
CURRENT_COMPOSE_SHA=""
LATEST_BACKUP=""
EXTRACTED_BACKUP_DIR=""
COMBINED_BACKUP_ARCHIVE=""
MULTIPART_SPLIT_SIZE_BYTES=2048
MULTIPART_SPLIT_THRESHOLD_BYTES=3072
SQLITE_HOLDER_PID=""
SQLITE_HOLDER_READY="$WORK_DIR/sqlite-holder.ready"
SQLITE_HOLDER_STOP="$WORK_DIR/sqlite-holder.stop"

stop_sqlite_holder() {
    if [ -n "$SQLITE_HOLDER_PID" ] && kill -0 "$SQLITE_HOLDER_PID" 2>/dev/null; then
        touch "$SQLITE_HOLDER_STOP"
        local waited=0
        while kill -0 "$SQLITE_HOLDER_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do
            sleep 0.2
            waited=$((waited + 1))
        done
        if kill -0 "$SQLITE_HOLDER_PID" 2>/dev/null; then
            kill -TERM "$SQLITE_HOLDER_PID" 2>/dev/null || true
        fi
        wait "$SQLITE_HOLDER_PID" 2>/dev/null || true
    fi
    SQLITE_HOLDER_PID=""
}

cleanup() {
    local exit_code=$?
    stop_sqlite_holder
    if [ "$exit_code" -ne 0 ] && [ -d "$WORK_DIR" ]; then
        while IFS= read -r log_path; do
            [ -n "$log_path" ] || continue
            printf '\n===== %s =====\n' "$log_path" >&2
            sed -n '1,220p' "$log_path" >&2 || true
        done < <(find "$WORK_DIR" -type f -name '*.log' | sort)
    fi
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$EXTRACTED_BACKUP_DIR"
    rm -f "$COMBINED_BACKUP_ARCHIVE"
    rm -rf "$WORK_DIR"
    exit "$exit_code"
}
trap cleanup EXIT

detect_os() { :; }
detect_compose() { COMPOSE="docker compose"; }
install_package() {
    printf 'Unexpected package install request during test: %s\n' "$*" >&2
    return 1
}
is_pasarguard_installed() { return 0; }
is_pasarguard_up() { return 0; }
down_pasarguard() { :; }
up_pasarguard() { :; }
stop_pasarguard_app_services() { :; }
start_pasarguard_app_services() { :; }

find_container() {
    case "$1" in
    mysql | mariadb | postgresql | timescaledb)
        printf '%s\n' "$CONTAINER_NAME"
        ;;
    *)
        return 1
        ;;
    esac
}

check_container() {
    local container="$1"
    docker inspect "$container" >/dev/null 2>&1 || return 1
    printf '%s\n' "$container"
}

verify_and_start_container() {
    local container="$1"
    docker start "$container" >/dev/null 2>&1 || true
    printf '%s\n' "$container"
}

assert_file_contains() {
    local path="$1"
    local expected="$2"
    if ! grep -F -q "$expected" "$path"; then
        printf 'Expected to find %s in %s\n' "$expected" "$path" >&2
        exit 1
    fi
}

assert_equals() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    if [ "$actual" != "$expected" ]; then
        printf '%s\nExpected: %s\nActual:   %s\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

sqlite_dump_sha() {
    local db_path="$1"
    sqlite3 "$db_path" ".dump" | sha256sum | awk '{print $1}'
}

assert_sqlite_integrity() {
    local db_path="$1"
    local integrity_result=""

    integrity_result="$(sqlite3 "$db_path" "PRAGMA integrity_check;")"
    assert_equals "$integrity_result" "ok" "SQLite integrity check failed for $db_path."
}

wait_for_command() {
    local attempts="$1"
    shift
    local try=1
    while [ "$try" -le "$attempts" ]; do
        if "$@"; then
            return 0
        fi
        sleep 2
        try=$((try + 1))
    done
    return 1
}

wait_for_mysql_root_query() {
    local client_bin="$1"
    local container="$2"

    wait_for_command 60 docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$container" \
        "$client_bin" -N -s -uroot -e "SELECT 1;"
}

write_common_files() {
    mkdir -p "$APP_DIR" "$DATA_DIR" "$BACKUP_DIR"
    printf '%s\n' "$EXPECTED_SENTINEL_VALUE" >"$DATA_DIR/sentinel.txt"
    if [ "$ARCHIVE_MODE" = "multipart" ]; then
        dd if=/dev/urandom of="$DATA_DIR/payload.bin" bs=1024 count=8 status=none
    else
        dd if=/dev/zero of="$DATA_DIR/payload.bin" bs=1024 count=4 status=none
        printf 'payload-%s\n' "$DB_TYPE" >>"$DATA_DIR/payload.bin"
    fi
}

write_stale_database_artifacts() {
    case "$DB_TYPE" in
    mysql)
        printf '%s\n' \
            '-- MySQL dump 10.13  Distrib 8.0, for Linux (x86_64)' \
            'CREATE TABLE stale_from_previous_restore (id INT);' \
            '-- Dump completed on 2000-01-01 00:00:00' >"$APP_DIR/db_backup.sql"
        ;;
    mariadb)
        printf '%s\n' \
            '-- MariaDB dump 10.19  Distrib 10.11, for debian-linux-gnu (x86_64)' \
            'CREATE TABLE stale_from_previous_restore (id INT);' \
            '-- Dump completed on 2000-01-01 00:00:00' >"$APP_DIR/db_backup.sql"
        ;;
    postgresql | timescaledb)
        mkdir -p "$APP_DIR/pg_dump"
        printf '%s\n' \
            '-- PostgreSQL database cluster dump' \
            '-- PostgreSQL database cluster dump complete' >"$APP_DIR/pg_dump/globals.sql"
        printf '%s\n' \
            '-- PostgreSQL database dump' \
            'CREATE TABLE stale_from_previous_restore (id integer);' \
            '-- PostgreSQL database dump complete' >"$APP_DIR/pg_dump/db-001.sql"
        if [ "$DB_TYPE" = "timescaledb" ]; then
            printf 'appdb\tappuser\t1\tdb-001.sql\t2.27.2\n' >"$APP_DIR/pg_dump/manifest.tsv"
        else
            printf 'appdb\tappuser\t0\tdb-001.sql\t\n' >"$APP_DIR/pg_dump/manifest.tsv"
        fi
        ;;
    esac
}

write_sqlite_env() {
    cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
RESTORE_TEST_FLAG=$EXPECTED_ENV_FLAG
# Keep the legacy five-slash URL here to verify existing installations.
SQLALCHEMY_DATABASE_URL="sqlite:////$DATA_DIR/db.sqlite3"
EOF
}

write_mysql_env() {
    cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
RESTORE_TEST_FLAG=$EXPECTED_ENV_FLAG
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
SQLALCHEMY_DATABASE_URL="mysql://$DB_USER:$DB_PASSWORD@127.0.0.1:3306/$DB_NAME"
EOF
}

write_mariadb_env() {
    cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
RESTORE_TEST_FLAG=$EXPECTED_ENV_FLAG
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
SQLALCHEMY_DATABASE_URL="mariadb://$DB_USER:$DB_PASSWORD@127.0.0.1:3306/$DB_NAME"
EOF
}

write_postgres_env() {
    cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
RESTORE_TEST_FLAG=$EXPECTED_ENV_FLAG
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
SQLALCHEMY_DATABASE_URL="postgresql://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME"
EOF
}

write_sqlite_compose() {
    cat >"$COMPOSE_FILE" <<EOF
$EXPECTED_COMPOSE_MARKER
services:
  pasarguard:
    image: alpine:3.20
EOF
}

write_mysql_compose() {
    cat >"$COMPOSE_FILE" <<EOF
$EXPECTED_COMPOSE_MARKER
services:
  mysql:
    image: mysql:8.0
EOF
}

write_mariadb_compose() {
    cat >"$COMPOSE_FILE" <<EOF
$EXPECTED_COMPOSE_MARKER
services:
  mariadb:
    image: mariadb:lts
EOF
}

write_postgresql_compose() {
    cat >"$COMPOSE_FILE" <<EOF
$EXPECTED_COMPOSE_MARKER
services:
  postgresql:
    image: postgres:16
EOF
}

write_timescaledb_compose() {
    cat >"$COMPOSE_FILE" <<EOF
$EXPECTED_COMPOSE_MARKER
services:
  timescaledb:
    image: ${TIMESCALE_SOURCE_IMAGE:-timescale/timescaledb:latest-pg17}
EOF
}

record_original_file_hashes() {
    ORIGINAL_ENV_SHA="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
    ORIGINAL_COMPOSE_SHA="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
    ORIGINAL_SENTINEL_SHA="$(sha256sum "$DATA_DIR/sentinel.txt" | awk '{print $1}')"
    ORIGINAL_PAYLOAD_SHA="$(sha256sum "$DATA_DIR/payload.bin" | awk '{print $1}')"
    if [ "$DB_TYPE" = "sqlite" ]; then
        ORIGINAL_SQLITE_DUMP_SHA="$(sqlite_dump_sha "$DATA_DIR/db.sqlite3")"
    fi
}

setup_sqlite_db() {
    python3 - "$DATA_DIR/db.sqlite3" "$SQLITE_HOLDER_READY" "$SQLITE_HOLDER_STOP" "$EXPECTED_DB_VALUE" <<'PY' &
import sqlite3
import sys
import time
from pathlib import Path

db_path, ready_path, stop_path, expected_value = sys.argv[1:]
connection = sqlite3.connect(db_path)
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("PRAGMA wal_autocheckpoint=0")
connection.execute("CREATE TABLE ci_roundtrip (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
connection.execute("INSERT INTO ci_roundtrip (id, value) VALUES (1, 'old-checkpoint')")
connection.commit()
connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
connection.execute("UPDATE ci_roundtrip SET value = ? WHERE id = 1", (expected_value,))
connection.commit()
Path(ready_path).touch()
while not Path(stop_path).exists():
    time.sleep(0.05)
connection.close()
PY
    SQLITE_HOLDER_PID=$!
    wait_for_command 50 test -f "$SQLITE_HOLDER_READY"

    # A valid SQLite file with the same basename in APP_DIR used to overwrite
    # the authoritative snapshot while app files were copied into staging.
    # Keep this collision valid (not garbage) so integrity checks alone cannot
    # distinguish it from the live DATA_DIR database.
    sqlite3 "$APP_DIR/db.sqlite3" \
        "CREATE TABLE ci_roundtrip (id INTEGER PRIMARY KEY, value TEXT NOT NULL); INSERT INTO ci_roundtrip VALUES (1, 'stale-app-dir-copy');"
}

sqlite_query() {
    sqlite3 "$DATA_DIR/db.sqlite3" "SELECT value FROM ci_roundtrip WHERE id = 1;"
}

mutate_sqlite_db() {
    sqlite3 "$DATA_DIR/db.sqlite3" "UPDATE ci_roundtrip SET value = 'mutated' WHERE id = 1;"
    printf 'stale rollback journal\n' >"$DATA_DIR/db.sqlite3-journal"
}

setup_mysql_container() {
    docker run -d --name "$CONTAINER_NAME" \
        -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
        -e MYSQL_DATABASE="$DB_NAME" \
        -e MYSQL_USER="$DB_USER" \
        -e MYSQL_PASSWORD="$DB_PASSWORD" \
        mysql:8.0 >/dev/null

    wait_for_mysql_root_query mysql "$CONTAINER_NAME"

    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysql -uroot -D "$DB_NAME" \
        -e "CREATE TABLE ci_roundtrip (id INT PRIMARY KEY, value VARCHAR(255) NOT NULL); INSERT INTO ci_roundtrip (id, value) VALUES (1, '$EXPECTED_DB_VALUE');"
}

setup_mariadb_container() {
    docker run -d --name "$CONTAINER_NAME" \
        -e MARIADB_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
        -e MARIADB_DATABASE="$DB_NAME" \
        -e MARIADB_USER="$DB_USER" \
        -e MARIADB_PASSWORD="$DB_PASSWORD" \
        mariadb:lts >/dev/null

    wait_for_mysql_root_query mariadb "$CONTAINER_NAME"

    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mariadb -uroot "$DB_NAME" \
        -e "CREATE TABLE ci_roundtrip (id INT PRIMARY KEY, value VARCHAR(255) NOT NULL); INSERT INTO ci_roundtrip (id, value) VALUES (1, '$EXPECTED_DB_VALUE');"
}

mysql_query() {
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysql -N -s -uroot -D "$DB_NAME" \
        -e "SELECT value FROM ci_roundtrip WHERE id = 1;"
}

mariadb_query() {
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mariadb -N -s -uroot "$DB_NAME" \
        -e "SELECT value FROM ci_roundtrip WHERE id = 1;"
}

mutate_mysql_db() {
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysql -uroot -D "$DB_NAME" \
        -e "UPDATE ci_roundtrip SET value = 'mutated' WHERE id = 1;"
}

mutate_mariadb_db() {
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mariadb -uroot "$DB_NAME" \
        -e "UPDATE ci_roundtrip SET value = 'mutated' WHERE id = 1;"
}

setup_postgresql_container() {
    local image="$1"
    local password="${2:-$DB_PASSWORD}"
    local initial_value="${3:-$EXPECTED_DB_VALUE}"
    docker run -d --name "$CONTAINER_NAME" \
        -e POSTGRES_USER="$DB_USER" \
        -e POSTGRES_PASSWORD="$password" \
        -e POSTGRES_DB="$DB_NAME" \
        -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256" \
        -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
        "$image" >/dev/null

    wait_for_command 30 docker exec -e PGPASSWORD="$password" "$CONTAINER_NAME" \
        pg_isready -U "$DB_USER" -d "$DB_NAME"

    if [ "$DB_TYPE" = "timescaledb" ]; then
        docker exec -e PGPASSWORD="$password" "$CONTAINER_NAME" \
            psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
            -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
    fi

    docker exec -e PGPASSWORD="$password" "$CONTAINER_NAME" \
        psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
        -c "CREATE TABLE ci_roundtrip (id INT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO ci_roundtrip (id, value) VALUES (1, '$initial_value');"
}

postgres_query() {
    docker exec -e PGPASSWORD="$CURRENT_DB_PASSWORD" "$CONTAINER_NAME" \
        psql -h 127.0.0.1 -At -U "$DB_USER" -d "$DB_NAME" \
        -c "SELECT value FROM ci_roundtrip WHERE id = 1;"
}

mutate_postgres_db() {
    docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" \
        psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
        -c "UPDATE ci_roundtrip SET value = 'mutated' WHERE id = 1;"
}

mutate_files_after_backup() {
    if [ "$DB_TYPE" = "sqlite" ]; then
        cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
RESTORE_TEST_FLAG=mutated-after-backup
SQLALCHEMY_DATABASE_URL="sqlite:///mutated"
EOF
    else
        local scheme="$DB_TYPE"
        [ "$DB_TYPE" = "timescaledb" ] && scheme="postgresql"
        cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
RESTORE_TEST_FLAG=mutated-after-backup
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
DB_USER=$DB_USER
DB_PASSWORD=$CURRENT_DB_PASSWORD
DB_NAME=$DB_NAME
SQLALCHEMY_DATABASE_URL="$scheme://$DB_USER:$CURRENT_DB_PASSWORD@127.0.0.1:$([[ "$DB_TYPE" =~ ^(mysql|mariadb)$ ]] && echo 3306 || echo 5432)/$DB_NAME"
EOF
    fi
    sed -i 's/^# compose-state: before-backup$/# compose-state: mutated-after-backup/' "$COMPOSE_FILE"
    if [ "$DB_TYPE" = "timescaledb" ] && [ -n "${TIMESCALE_TARGET_IMAGE:-}" ]; then
        sed -i "s#image: timescale/timescaledb:[^[:space:]]*#image: $TIMESCALE_TARGET_IMAGE#" "$COMPOSE_FILE"
    fi
    CURRENT_COMPOSE_SHA="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
    printf 'mutated-after-backup\n' >"$DATA_DIR/sentinel.txt"
    printf 'mutated-payload-%s\n' "$DB_TYPE" >"$DATA_DIR/payload.bin"
}

rotate_destination_credentials() {
    case "$DB_TYPE" in
    sqlite)
        return 0
        ;;
    mysql)
        docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysql -uroot \
            -e "ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$CURRENT_DB_PASSWORD';"
        ;;
    mariadb)
        docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mariadb -uroot \
            -e "ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$CURRENT_DB_PASSWORD';"
        ;;
    postgresql)
        docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" psql -U "$DB_USER" -d postgres \
            -c "ALTER ROLE \"$DB_USER\" PASSWORD '$CURRENT_DB_PASSWORD';"
        ;;
    timescaledb)
        if [ -n "${TIMESCALE_TARGET_IMAGE:-}" ]; then
            docker rm -f "$CONTAINER_NAME" >/dev/null
            setup_postgresql_container "$TIMESCALE_TARGET_IMAGE" "$CURRENT_DB_PASSWORD" "mutated"
        else
            docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" psql -U "$DB_USER" -d postgres \
                -c "ALTER ROLE \"$DB_USER\" PASSWORD '$CURRENT_DB_PASSWORD';"
        fi
        ;;
    esac
}

run_restore() {
    printf '1\nyes\n' | restore_command
}

assert_zip_contains_exact_files() {
    local archive="$1"
    local expected_list="$2"
    local actual_list=""

    actual_list="$(zipinfo -1 "$archive" | LC_ALL=C sort)"
    assert_equals "$actual_list" "$expected_list" "Backup archive file list did not match the expected manifest."
}

assert_zip_contains_required_files() {
    local archive="$1"
    local required_list="$2"
    local file_path=""

    while IFS= read -r file_path; do
        [ -n "$file_path" ] || continue
        if ! zipinfo -1 "$archive" | grep -F -x -q "$file_path"; then
            printf 'Expected required backup entry %s was not found in %s\n' "$file_path" "$archive" >&2
            exit 1
        fi
    done <<<"$required_list"
}

combine_split_backup_parts() {
    local combined_archive="$1"
    local part_file=""

    : >"$combined_archive"
    while IFS= read -r part_file; do
        [ -n "$part_file" ] || continue
        cat "$part_file" >>"$combined_archive"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.part[0-9][0-9].zip' | sort)
}

verify_backup_archive_contents() {
    local archive_to_verify="$1"
    local expected_files=""

    if [ -n "$EXTRACTED_BACKUP_DIR" ]; then
        rm -rf "$EXTRACTED_BACKUP_DIR"
    fi
    EXTRACTED_BACKUP_DIR="$(mktemp -d "$WORK_DIR/backup_extract.XXXXXX")"

    unzip -q "$archive_to_verify" -d "$EXTRACTED_BACKUP_DIR"

    local sqlite_basename=""
    if [ "$DB_TYPE" = "sqlite" ]; then
        sqlite_basename="db.sqlite3"
    fi

    if [ "$DB_TYPE" = "sqlite" ]; then
        expected_files=$'.env\n'"$sqlite_basename"$'\ndocker-compose.yml\npasarguard_data/\npasarguard_data/payload.bin\npasarguard_data/sentinel.txt'
    elif [ "$DB_TYPE" = "postgresql" ] || [ "$DB_TYPE" = "timescaledb" ]; then
        # PostgreSQL/TimescaleDB back up every user database under pg_dump/
        # (globals + one db-NNN.sql per database + a manifest). The CI fixture
        # has exactly one user database (appdb), so it lands in db-001.sql.
        expected_files=$'.env\ndocker-compose.yml\npasarguard_data/\npasarguard_data/payload.bin\npasarguard_data/sentinel.txt\npg_dump/\npg_dump/db-001.sql\npg_dump/globals.sql\npg_dump/manifest.tsv'
    else
        expected_files=$'.env\ndb_backup.sql\ndocker-compose.yml\npasarguard_data/\npasarguard_data/payload.bin\npasarguard_data/sentinel.txt'
    fi

    assert_zip_contains_exact_files "$archive_to_verify" "$expected_files"
    assert_equals "$(sha256sum "$EXTRACTED_BACKUP_DIR/.env" | awk '{print $1}')" "$ORIGINAL_ENV_SHA" "Backed up .env contents changed."
    assert_equals "$(sha256sum "$EXTRACTED_BACKUP_DIR/docker-compose.yml" | awk '{print $1}')" "$ORIGINAL_COMPOSE_SHA" "Backed up docker-compose.yml contents changed."
    assert_equals "$(sha256sum "$EXTRACTED_BACKUP_DIR/pasarguard_data/sentinel.txt" | awk '{print $1}')" "$ORIGINAL_SENTINEL_SHA" "Backed up sentinel.txt contents changed."
    assert_equals "$(sha256sum "$EXTRACTED_BACKUP_DIR/pasarguard_data/payload.bin" | awk '{print $1}')" "$ORIGINAL_PAYLOAD_SHA" "Backed up payload.bin contents changed."

    if [ "$DB_TYPE" = "sqlite" ]; then
        assert_sqlite_integrity "$EXTRACTED_BACKUP_DIR/$sqlite_basename"
        assert_equals "$(sqlite_dump_sha "$EXTRACTED_BACKUP_DIR/$sqlite_basename")" "$ORIGINAL_SQLITE_DUMP_SHA" "Backed up SQLite database logical contents changed."
        if [ -e "$EXTRACTED_BACKUP_DIR/pasarguard_data/$sqlite_basename" ] || \
            [ -e "$EXTRACTED_BACKUP_DIR/pasarguard_data/${sqlite_basename}-wal" ] || \
            [ -e "$EXTRACTED_BACKUP_DIR/pasarguard_data/${sqlite_basename}-shm" ] || \
            [ -e "$EXTRACTED_BACKUP_DIR/pasarguard_data/${sqlite_basename}-journal" ]; then
            printf 'SQLite database or WAL/SHM/journal leaked into the raw data-directory copy.\n' >&2
            exit 1
        fi
    elif [ "$DB_TYPE" = "postgresql" ] || [ "$DB_TYPE" = "timescaledb" ]; then
        assert_file_contains "$EXTRACTED_BACKUP_DIR/pg_dump/db-001.sql" "ci_roundtrip"
    else
        assert_file_contains "$EXTRACTED_BACKUP_DIR/db_backup.sql" "ci_roundtrip"
    fi
}

verify_restored_files() {
    local restored_env_sha
    local restored_compose_sha
    restored_env_sha="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
    restored_compose_sha="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"

    if [ "$DB_TYPE" = "sqlite" ]; then
        assert_equals "$restored_env_sha" "$ORIGINAL_ENV_SHA" ".env was not restored from backup."
        assert_equals "$restored_compose_sha" "$ORIGINAL_COMPOSE_SHA" "docker-compose.yml was not restored from backup."
    else
        assert_file_contains "$ENV_FILE" "RESTORE_TEST_FLAG=$EXPECTED_ENV_FLAG"
        assert_file_contains "$ENV_FILE" "DB_USER=$DB_USER"
        assert_file_contains "$ENV_FILE" "DB_PASSWORD=$CURRENT_DB_PASSWORD"
        assert_file_contains "$ENV_FILE" "DB_NAME=$DB_NAME"
        assert_file_contains "$ENV_FILE" "$DB_USER:$CURRENT_DB_PASSWORD@127.0.0.1"
        assert_equals "$restored_compose_sha" "$CURRENT_COMPOSE_SHA" "Destination docker-compose.yml was replaced by the backup."
    fi
    assert_equals "$(sha256sum "$DATA_DIR/sentinel.txt" | awk '{print $1}')" "$ORIGINAL_SENTINEL_SHA" "sentinel.txt was not restored from backup."
    assert_equals "$(sha256sum "$DATA_DIR/payload.bin" | awk '{print $1}')" "$ORIGINAL_PAYLOAD_SHA" "payload.bin was not restored from backup."
    if [ "$DB_TYPE" = "sqlite" ]; then
        assert_sqlite_integrity "$DATA_DIR/db.sqlite3"
        assert_equals "$(sqlite_dump_sha "$DATA_DIR/db.sqlite3")" "$ORIGINAL_SQLITE_DUMP_SHA" "SQLite database logical contents were not restored from backup."
        if [ -e "$DATA_DIR/db.sqlite3-journal" ]; then
            printf 'A stale SQLite rollback journal survived the restore.\n' >&2
            exit 1
        fi

        local sqlite_safety_backup=""
        sqlite_safety_backup=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'sqlite_before_restore_*_db.sqlite3' | sort | tail -n 1)
        if [ -z "$sqlite_safety_backup" ]; then
            printf 'The pre-restore SQLite safety snapshot did not survive the data-directory restore.\n' >&2
            exit 1
        fi
        assert_sqlite_integrity "$sqlite_safety_backup"
        assert_equals "$(sqlite3 "$sqlite_safety_backup" 'SELECT value FROM ci_roundtrip WHERE id = 1;')" \
            "mutated" "Pre-restore SQLite safety snapshot did not preserve the replaced database."
    fi
}

verify_backup_created() {
    local backup_count
    backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'backup_*.zip' -o -name 'backup_*.z[0-9][0-9]' -o -name 'backup_*.part[0-9][0-9].zip' \) | wc -l | awk '{print $1}')
    if [ "$backup_count" -lt 1 ]; then
        printf 'No backup archive was created in %s\n' "$BACKUP_DIR" >&2
        exit 1
    fi

    if [ "$ARCHIVE_MODE" = "multipart" ]; then
        local part_count
        local base_zip_count
        local total_parts_size
        local combined_size
        local largest_part_size

        part_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.part[0-9][0-9].zip' | wc -l | awk '{print $1}')
        if [ "$part_count" -lt 2 ]; then
            printf 'Expected a multipart backup in %s but found only %s part(s)\n' "$BACKUP_DIR" "$part_count" >&2
            exit 1
        fi

        base_zip_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.zip' ! -name 'backup_*.part*.zip' | wc -l | awk '{print $1}')
        if [ "$base_zip_count" -ne 0 ]; then
            printf 'Expected multipart backup to remove the base zip, but found %s base zip file(s)\n' "$base_zip_count" >&2
            exit 1
        fi

        LATEST_BACKUP="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.part[0-9][0-9].zip' | sort | head -n 1)"
        COMBINED_BACKUP_ARCHIVE="$WORK_DIR/combined-backup.zip"
        combine_split_backup_parts "$COMBINED_BACKUP_ARCHIVE"

        total_parts_size=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.part[0-9][0-9].zip' -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')
        combined_size=$(stat -c%s "$COMBINED_BACKUP_ARCHIVE" 2>/dev/null || wc -c <"$COMBINED_BACKUP_ARCHIVE")
        assert_equals "$combined_size" "$total_parts_size" "Combined multipart archive size did not match the sum of its parts."
        if [ "$combined_size" -le "$MULTIPART_SPLIT_THRESHOLD_BYTES" ]; then
            printf 'Expected multipart archive to exceed %s bytes, got %s bytes\n' "$MULTIPART_SPLIT_THRESHOLD_BYTES" "$combined_size" >&2
            exit 1
        fi

        largest_part_size=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.part[0-9][0-9].zip' -printf '%s\n' | sort -nr | head -n 1)
        if [ -z "$largest_part_size" ] || [ "$largest_part_size" -gt "$MULTIPART_SPLIT_SIZE_BYTES" ]; then
            printf 'Multipart backup part exceeded %s bytes (largest part: %s)\n' "$MULTIPART_SPLIT_SIZE_BYTES" "${largest_part_size:-missing}" >&2
            exit 1
        fi

        verify_backup_archive_contents "$COMBINED_BACKUP_ARCHIVE"
    else
        LATEST_BACKUP="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.zip' ! -name 'backup_*.part*.zip' | sort | tail -n 1)"
        if [ -z "$LATEST_BACKUP" ] || [ ! -f "$LATEST_BACKUP" ]; then
            printf 'Expected a single zip archive in %s but did not find one\n' "$BACKUP_DIR" >&2
            exit 1
        fi

        verify_backup_archive_contents "$LATEST_BACKUP"
    fi
}

prepare_case() {
    write_common_files

    case "$DB_TYPE" in
    sqlite)
        write_sqlite_env
        write_sqlite_compose
        setup_sqlite_db
        ;;
    mysql)
        write_mysql_env
        write_mysql_compose
        setup_mysql_container
        ;;
    mariadb)
        write_mariadb_env
        write_mariadb_compose
        setup_mariadb_container
        ;;
    postgresql)
        write_postgres_env
        write_postgresql_compose
        setup_postgresql_container postgres:16
        ;;
    timescaledb)
        write_postgres_env
        write_timescaledb_compose
        setup_postgresql_container "${TIMESCALE_SOURCE_IMAGE:-timescale/timescaledb:latest-pg17}"
        ;;
    *)
        printf 'Unsupported database type: %s\n' "$DB_TYPE" >&2
        exit 1
        ;;
    esac

    write_stale_database_artifacts
    record_original_file_hashes
}

verify_restored_database() {
    local restored_value=""

    case "$DB_TYPE" in
    sqlite)
        restored_value="$(sqlite_query)"
        ;;
    mysql)
        restored_value="$(mysql_query)"
        ;;
    mariadb)
        restored_value="$(mariadb_query)"
        ;;
    postgresql | timescaledb)
        restored_value="$(postgres_query)"
        ;;
    esac

    assert_equals "$restored_value" "$EXPECTED_DB_VALUE" "Database value was not restored from backup."

    case "$DB_TYPE" in
    mysql)
        docker exec -e MYSQL_PWD="$CURRENT_DB_PASSWORD" "$CONTAINER_NAME" mysql -h 127.0.0.1 -u "$DB_USER" "$DB_NAME" -e "SELECT 1;" >/dev/null
        if docker exec -e MYSQL_PWD="$DB_PASSWORD" "$CONTAINER_NAME" mysql -h 127.0.0.1 -u "$DB_USER" "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
            printf 'Archived MySQL password still authenticates after restore.\n' >&2
            exit 1
        fi
        ;;
    mariadb)
        docker exec -e MYSQL_PWD="$CURRENT_DB_PASSWORD" "$CONTAINER_NAME" mariadb -h 127.0.0.1 -u "$DB_USER" "$DB_NAME" -e "SELECT 1;" >/dev/null
        if docker exec -e MYSQL_PWD="$DB_PASSWORD" "$CONTAINER_NAME" mariadb -h 127.0.0.1 -u "$DB_USER" "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
            printf 'Archived MariaDB password still authenticates after restore.\n' >&2
            exit 1
        fi
        ;;
    postgresql | timescaledb)
        docker exec -e PGPASSWORD="$CURRENT_DB_PASSWORD" "$CONTAINER_NAME" \
            psql -h 127.0.0.1 -At -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null
        if docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" \
            psql -h 127.0.0.1 -At -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
            printf 'Archived PostgreSQL password still authenticates after restore.\n' >&2
            exit 1
        fi
        ;;
    esac
}

mutate_database_after_backup() {
    case "$DB_TYPE" in
    sqlite)
        mutate_sqlite_db
        ;;
    mysql)
        mutate_mysql_db
        ;;
    mariadb)
        mutate_mariadb_db
        ;;
    postgresql | timescaledb)
        mutate_postgres_db
        ;;
    esac
}

main() {
    if [ "$ARCHIVE_MODE" = "multipart" ]; then
        export BACKUP_SPLIT_SIZE_BYTES="$MULTIPART_SPLIT_SIZE_BYTES"
        export BACKUP_SPLIT_THRESHOLD_BYTES="$MULTIPART_SPLIT_THRESHOLD_BYTES"
    fi

    printf 'Running backup/restore round-trip for %s with archive mode: %s\n' "$DB_TYPE" "$ARCHIVE_MODE"

    prepare_case
    backup_command
    verify_backup_created
    stop_sqlite_holder
    mutate_database_after_backup
    rotate_destination_credentials
    mutate_files_after_backup
    run_restore
    verify_restored_files
    verify_restored_database
    printf 'Backup/restore round-trip passed for %s (%s)\n' "$DB_TYPE" "$ARCHIVE_MODE"
}

main
