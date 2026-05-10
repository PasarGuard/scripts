#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DB_TYPE="${1:-}"

if [ -z "$DB_TYPE" ]; then
    printf 'Usage: %s <sqlite|mysql|mariadb|postgresql|timescaledb>\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi

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
DB_NAME="appdb"
POSTGRES_SUPERUSER="postgres"
POSTGRES_SUPERPASS="postgrespass"
EXPECTED_DB_VALUE="from_backup"
EXPECTED_SENTINEL_VALUE="sentinel-before-backup"
EXPECTED_ENV_FLAG="before-backup"
EXPECTED_COMPOSE_MARKER="# compose-state: before-backup"
ORIGINAL_ENV_SHA=""
ORIGINAL_COMPOSE_SHA=""
ORIGINAL_SENTINEL_SHA=""
ORIGINAL_PAYLOAD_SHA=""
ORIGINAL_SQLITE_DUMP_SHA=""
LATEST_BACKUP=""
EXTRACTED_BACKUP_DIR=""

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$EXTRACTED_BACKUP_DIR"
    rm -rf "$WORK_DIR"
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
    dd if=/dev/zero of="$DATA_DIR/payload.bin" bs=1024 count=4 status=none
    printf 'payload-%s\n' "$DB_TYPE" >>"$DATA_DIR/payload.bin"
}

write_sqlite_env() {
    cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
RESTORE_TEST_FLAG=$EXPECTED_ENV_FLAG
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
    image: timescale/timescaledb:latest-pg17
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
    sqlite3 "$DATA_DIR/db.sqlite3" <<EOF
CREATE TABLE ci_roundtrip (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO ci_roundtrip (id, value) VALUES (1, '$EXPECTED_DB_VALUE');
EOF
}

sqlite_query() {
    sqlite3 "$DATA_DIR/db.sqlite3" "SELECT value FROM ci_roundtrip WHERE id = 1;"
}

mutate_sqlite_db() {
    sqlite3 "$DATA_DIR/db.sqlite3" "UPDATE ci_roundtrip SET value = 'mutated' WHERE id = 1;"
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
    docker run -d --name "$CONTAINER_NAME" \
        -e POSTGRES_USER="$POSTGRES_SUPERUSER" \
        -e POSTGRES_PASSWORD="$POSTGRES_SUPERPASS" \
        -e POSTGRES_DB=postgres \
        "$image" >/dev/null

    wait_for_command 30 docker exec -e PGPASSWORD="$POSTGRES_SUPERPASS" "$CONTAINER_NAME" \
        pg_isready -U "$POSTGRES_SUPERUSER" -d postgres

    docker exec -e PGPASSWORD="$POSTGRES_SUPERPASS" "$CONTAINER_NAME" \
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d postgres \
        -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"

    docker exec -e PGPASSWORD="$POSTGRES_SUPERPASS" "$CONTAINER_NAME" \
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d postgres \
        -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

    if [ "$DB_TYPE" = "timescaledb" ]; then
        docker exec -e PGPASSWORD="$POSTGRES_SUPERPASS" "$CONTAINER_NAME" \
            psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$DB_NAME" \
            -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
    fi

    docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" \
        psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
        -c "CREATE TABLE ci_roundtrip (id INT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO ci_roundtrip (id, value) VALUES (1, '$EXPECTED_DB_VALUE');"
}

postgres_query() {
    docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" \
        psql -At -U "$DB_USER" -d "$DB_NAME" \
        -c "SELECT value FROM ci_roundtrip WHERE id = 1;"
}

mutate_postgres_db() {
    docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" \
        psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
        -c "UPDATE ci_roundtrip SET value = 'mutated' WHERE id = 1;"
}

mutate_files_after_backup() {
    cat >"$ENV_FILE" <<EOF
BACKUP_SERVICE_ENABLED=false
RESTORE_TEST_FLAG=mutated-after-backup
SQLALCHEMY_DATABASE_URL="sqlite:///mutated"
EOF
    printf '# compose-state: mutated-after-backup\n' >"$COMPOSE_FILE"
    printf 'mutated-after-backup\n' >"$DATA_DIR/sentinel.txt"
    printf 'mutated-payload-%s\n' "$DB_TYPE" >"$DATA_DIR/payload.bin"
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

verify_backup_archive_contents() {
    local expected_files=""

    if [ -n "$EXTRACTED_BACKUP_DIR" ]; then
        rm -rf "$EXTRACTED_BACKUP_DIR"
    fi
    EXTRACTED_BACKUP_DIR="$(mktemp -d "$WORK_DIR/backup_extract.XXXXXX")"

    unzip -q "$LATEST_BACKUP" -d "$EXTRACTED_BACKUP_DIR"

    if [ "$DB_TYPE" = "sqlite" ]; then
        expected_files=$'.env\ndb_backup.sqlite\ndocker-compose.yml\npasarguard_data/\npasarguard_data/payload.bin\npasarguard_data/sentinel.txt'
    else
        expected_files=$'.env\ndb_backup.sql\ndocker-compose.yml\npasarguard_data/\npasarguard_data/payload.bin\npasarguard_data/sentinel.txt'
    fi

    if [ "$DB_TYPE" = "sqlite" ]; then
        assert_zip_contains_required_files "$LATEST_BACKUP" "$expected_files"
    else
        assert_zip_contains_exact_files "$LATEST_BACKUP" "$expected_files"
    fi
    assert_equals "$(sha256sum "$EXTRACTED_BACKUP_DIR/.env" | awk '{print $1}')" "$ORIGINAL_ENV_SHA" "Backed up .env contents changed."
    assert_equals "$(sha256sum "$EXTRACTED_BACKUP_DIR/docker-compose.yml" | awk '{print $1}')" "$ORIGINAL_COMPOSE_SHA" "Backed up docker-compose.yml contents changed."
    assert_equals "$(sha256sum "$EXTRACTED_BACKUP_DIR/pasarguard_data/sentinel.txt" | awk '{print $1}')" "$ORIGINAL_SENTINEL_SHA" "Backed up sentinel.txt contents changed."
    assert_equals "$(sha256sum "$EXTRACTED_BACKUP_DIR/pasarguard_data/payload.bin" | awk '{print $1}')" "$ORIGINAL_PAYLOAD_SHA" "Backed up payload.bin contents changed."

    if [ "$DB_TYPE" = "sqlite" ]; then
        assert_sqlite_integrity "$EXTRACTED_BACKUP_DIR/db_backup.sqlite"
        assert_equals "$(sqlite_dump_sha "$EXTRACTED_BACKUP_DIR/db_backup.sqlite")" "$ORIGINAL_SQLITE_DUMP_SHA" "Backed up SQLite database logical contents changed."
        if [ -f "$EXTRACTED_BACKUP_DIR/pasarguard_data/db.sqlite3" ]; then
            assert_sqlite_integrity "$EXTRACTED_BACKUP_DIR/pasarguard_data/db.sqlite3"
            assert_equals "$(sqlite_dump_sha "$EXTRACTED_BACKUP_DIR/pasarguard_data/db.sqlite3")" "$ORIGINAL_SQLITE_DUMP_SHA" "Archived SQLite data-dir database logical contents changed."
        fi
    else
        assert_file_contains "$EXTRACTED_BACKUP_DIR/db_backup.sql" "ci_roundtrip"
    fi
}

verify_restored_files() {
    local restored_env_sha
    local restored_compose_sha
    restored_env_sha="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
    restored_compose_sha="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"

    assert_equals "$restored_env_sha" "$ORIGINAL_ENV_SHA" ".env was not restored from backup."
    assert_equals "$restored_compose_sha" "$ORIGINAL_COMPOSE_SHA" "docker-compose.yml was not restored from backup."
    assert_equals "$(sha256sum "$DATA_DIR/sentinel.txt" | awk '{print $1}')" "$ORIGINAL_SENTINEL_SHA" "sentinel.txt was not restored from backup."
    assert_equals "$(sha256sum "$DATA_DIR/payload.bin" | awk '{print $1}')" "$ORIGINAL_PAYLOAD_SHA" "payload.bin was not restored from backup."
    if [ "$DB_TYPE" = "sqlite" ]; then
        assert_sqlite_integrity "$DATA_DIR/db.sqlite3"
        assert_equals "$(sqlite_dump_sha "$DATA_DIR/db.sqlite3")" "$ORIGINAL_SQLITE_DUMP_SHA" "SQLite database logical contents were not restored from backup."
    fi
}

verify_backup_created() {
    local backup_count
    backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'backup_*.zip' -o -name 'backup_*.z[0-9][0-9]' \) | wc -l | awk '{print $1}')
    if [ "$backup_count" -lt 1 ]; then
        printf 'No backup archive was created in %s\n' "$BACKUP_DIR" >&2
        exit 1
    fi

    LATEST_BACKUP="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.zip' ! -name 'backup_*.part*.zip' | sort | tail -n 1)"
    if [ -z "$LATEST_BACKUP" ] || [ ! -f "$LATEST_BACKUP" ]; then
        printf 'Expected a single zip archive in %s but did not find one\n' "$BACKUP_DIR" >&2
        exit 1
    fi

    verify_backup_archive_contents
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
        setup_postgresql_container timescale/timescaledb:latest-pg17
        ;;
    *)
        printf 'Unsupported database type: %s\n' "$DB_TYPE" >&2
        exit 1
        ;;
    esac

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
    prepare_case
    backup_command
    verify_backup_created
    mutate_database_after_backup
    mutate_files_after_backup
    run_restore
    verify_restored_files
    verify_restored_database
    printf 'Backup/restore round-trip passed for %s\n' "$DB_TYPE"
}

main
