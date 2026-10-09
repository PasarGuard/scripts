#!/usr/bin/env bash
# =============================================================================
# unit_restore_recovery.sh - Recovery checks of `pasarguard restore` without a
# real Docker daemon: checksum inventory, argument parsing, --check, database
# version guard, database readiness and fresh provisioning.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pasarguard-recovery-unit"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR"

# A fake docker CLI answers from $FAKE_DOCKER_DIR and records every call, so no
# test can reach a real daemon, registry or container.
FAKE_DOCKER_DIR="$WORK_DIR/fake-docker"
export FAKE_DOCKER_DIR
mkdir -p "$WORK_DIR/bin" "$FAKE_DOCKER_DIR/images"
cat >"$WORK_DIR/bin/docker" <<'FAKE'
#!/usr/bin/env bash
d="${FAKE_DOCKER_DIR:?}"
printf '%s\n' "$*" >>"$d/calls.log"
image_key() { printf '%s' "$1" | tr '/:@' '___'; }
case "$1" in
    compose)
        case "$*" in
            *" config --format json"*) cat "$d/config.json" ;;
            *" ps -a -q"*) cat "$d/existing" 2>/dev/null || true ;;
            *" ps -q "*) printf 'cid-%s\n' "${@: -1}" ;;
        esac
        ;;
    image) [ "$2" = inspect ] && [ -e "$d/images/$(image_key "${@: -1}")" ] ;;
    pull)
        grep -qxF "$2" "$d/pullable" 2>/dev/null || exit 1
        : >"$d/images/$(image_key "$2")"
        ;;
    tag) : >"$d/images/$(image_key "$3")" ;;
    inspect) [ "$2" = --format ] && cat "$d/state" ;;
    logs) ;;
    exec)
        case "$*" in
            *pg_isready* | *mysqladmin*)
                code=$(head -n 1 "$d/probe")
                if [ "$(wc -l <"$d/probe")" -gt 1 ]; then sed -i 1d "$d/probe"; fi
                exit "$code"
                ;;
            *" mariadb --version"*) exit "$(cat "$d/has_mariadb")" ;;
            *) cat "$d/target_version" ;;
        esac
        ;;
    *) exit 1 ;;
esac
FAKE
# yq must not be needed by recovery: make any call visible and fail it.
cat >"$WORK_DIR/bin/yq" <<'FAKE'
#!/usr/bin/env bash
printf 'yq %s\n' "$*" >>"${FAKE_DOCKER_DIR:?}/calls.log"
exit 1
FAKE
chmod 755 "$WORK_DIR/bin/docker" "$WORK_DIR/bin/yq"
export PATH="$WORK_DIR/bin:$PATH"

# Stub network access at source time, as unit_pasarguard.sh does.
curl() { echo ""; return 0; }
export -f curl

export PASARGUARD_SOURCE_ONLY="true"
# shellcheck source=pasarguard.sh
source "$ROOT_DIR/pasarguard.sh"
set +e
set -uo pipefail

# Never touch the host system from these tests.
check_running_as_root() { :; }
detect_os() { :; }
install_package() { echo "install_package $*" >>"$FAKE_DOCKER_DIR/calls.log"; return 1; }
try_install_package() { return 1; }
install_yq() { echo "install_yq" >>"$FAKE_DOCKER_DIR/calls.log"; return 1; }
sleep() { :; }
# shellcheck disable=SC2034 # read by the sourced restore functions
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
# Run a command with its output discarded.
quiet() { "$@" >/dev/null 2>&1; }
# Assert equality between actual and expected values.
assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}
# Assert that a file contains a fixed string.
assert_file_has() {
    local file="$1" text="$2" label="$3"
    if grep -qF -- "$text" "$file" 2>/dev/null; then pass "$label"; else fail "$label (missing '$text')"; fi
}
# Assert that a file does not contain a fixed string.
assert_file_lacks() {
    local file="$1" text="$2" label="$3"
    if ! grep -qF -- "$text" "$file" 2>/dev/null; then pass "$label"; else fail "$label (found '$text')"; fi
}

# Run restore_command the way pasarguard.sh does (errexit, no nounset), isolated
# in a subshell because its error paths call exit.
run_restore() { ( set -e +u; restore_command "$@" ) </dev/null; }

# Reset the fake docker state between cases.
reset_fake_docker() {
    rm -rf "$FAKE_DOCKER_DIR"
    mkdir -p "$FAKE_DOCKER_DIR/images"
    : >"$FAKE_DOCKER_DIR/calls.log"
    echo healthy >"$FAKE_DOCKER_DIR/state"
    echo 0 >"$FAKE_DOCKER_DIR/probe"
    echo 1 >"$FAKE_DOCKER_DIR/has_mariadb"
    : >"$FAKE_DOCKER_DIR/target_version"
}
# Mark an image reference as present in the fake local image store.
fake_image_present() { : >"$FAKE_DOCKER_DIR/images/$(printf '%s' "$1" | tr '/:@' '___')"; }

echo "=== unit_restore_recovery.sh ==="

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
ID_A="sha256:$(printf 'c%.0s' {1..64})"
ID_B="sha256:$(printf 'd%.0s' {1..64})"

# Write recovery metadata for a stage. $2 is the engine, then "service digest id" triples.
write_runtime() {
    local stage="$1" engine="$2"
    shift 2
    {
        printf 'format\t1\ncreated_utc\t2026-10-01T00:00:00Z\n'
        printf 'database\t%s\nserver_version\tunknown\nschema_revision\tunknown\ndump_tool_version\tunknown\n' "$engine"
        printf 'project\t%s\napp_dir\t%s\ndata_dir\t%s\n' "$APP_NAME" "$APP_DIR" "$DATA_DIR"
        while [ "$#" -ge 3 ]; do
            printf 'image\t%s\t%s\t%s\n' "$1" "$2" "$3"
            shift 3
        done
    } >"$stage/backup-runtime.tsv"
}

# -----------------------------------------------------------------------
# verify_backup_checksums
# -----------------------------------------------------------------------
reset_fake_docker
stage="$WORK_DIR/checksums"
mkdir -p "$stage/pasarguard_data"
printf 'SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/pasarguard/db.sqlite3\n' >"$stage/.env"
printf 'services: {}\n' >"$stage/docker-compose.yml"
printf 'cert\n' >"$stage/pasarguard_data/cert.pem"
write_runtime "$stage" sqlite
write_backup_checksums "$stage"
assert_true "verify_backup_checksums: intact payload accepted" verify_backup_checksums "$stage"

printf 'edited\n' >>"$stage/pasarguard_data/cert.pem"
assert_false "verify_backup_checksums: edited payload rejected" verify_backup_checksums "$stage"

write_backup_checksums "$stage"
printf '%s  ./../escape\n' "$(printf '0%.0s' {1..64})" >>"$stage/backup-files.sha256"
assert_false "verify_backup_checksums: '..' inventory path rejected" verify_backup_checksums "$stage"

rm -f "$stage/backup-files.sha256"
out=$(verify_backup_checksums "$stage" 2>&1)
rc=$?
assert_eq "$rc" 1 "verify_backup_checksums: recovery metadata without inventory rejected"
case "$out" in *backup-files.sha256*) pass "verify_backup_checksums: missing inventory is named" ;; *) fail "verify_backup_checksums: missing inventory is named (got '$out')" ;; esac

rm -f "$stage/backup-runtime.tsv"
out=$(verify_backup_checksums "$stage" 2>&1)
rc=$?
assert_eq "$rc" 0 "verify_backup_checksums: legacy archive without metadata accepted"
case "$out" in *"no checksum inventory"*) pass "verify_backup_checksums: legacy archive warns about the missing inventory" ;; *) fail "verify_backup_checksums: legacy archive warns about the missing inventory (got '$out')" ;; esac

# -----------------------------------------------------------------------
# restore_command argument parsing
# -----------------------------------------------------------------------
out=$(run_restore --help 2>&1)
rc=$?
assert_eq "$rc" 0 "restore --help: exits 0"
case "$out" in *"Usage: pasarguard restore"*--check*--fresh*--yes*) pass "restore --help: lists --check, --fresh and --yes" ;; *) fail "restore --help: lists --check, --fresh and --yes" ;; esac
out=$(run_restore --bogus 2>&1)
rc=$?
assert_eq "$rc" 1 "restore --bogus: rejected"
case "$out" in *"Unknown restore option"*) pass "restore --bogus: explains the unknown option" ;; *) fail "restore --bogus: explains the unknown option" ;; esac
touch "$WORK_DIR/one.zip" "$WORK_DIR/two.zip"
out=$(run_restore "$WORK_DIR/one.zip" "$WORK_DIR/two.zip" 2>&1)
assert_eq "$?" 1 "restore with two archives: rejected"
out=$(run_restore --file 2>&1)
assert_eq "$?" 1 "restore --file without a path: rejected"
out=$(run_restore "$WORK_DIR/missing.zip" --check 2>&1)
rc=$?
assert_eq "$rc" 1 "restore with a missing archive: rejected"
case "$out" in *"missing or unreadable"*) pass "restore with a missing archive: names the problem" ;; *) fail "restore with a missing archive: names the problem" ;; esac
assert_eq "$(wc -l <"$FAKE_DOCKER_DIR/calls.log")" 0 "restore argument errors: no docker calls"

# -----------------------------------------------------------------------
# restore_command --check on a SQLite archive
# -----------------------------------------------------------------------
if command -v sqlite3 >/dev/null 2>&1 && command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    reset_fake_docker
    # Build one archive payload. $1 is the stage, $2 "keep" or "drop" for the inventory.
    make_sqlite_archive() {
        local name="$1" inventory="$2" stage="$WORK_DIR/build-$1"
        rm -rf "$stage"
        mkdir -p "$stage/pasarguard_data"
        printf 'SQLALCHEMY_DATABASE_URL="sqlite+aiosqlite:////%s/db.sqlite3"\n' "${DATA_DIR#/}" >"$stage/.env"
        printf 'services:\n  pasarguard:\n    image: pasarguard/panel:latest\n' >"$stage/docker-compose.yml"
        sqlite3 "$stage/db.sqlite3" "CREATE TABLE alembic_version (version_num varchar(32)); INSERT INTO alembic_version VALUES ('abc');"
        printf 'cert\n' >"$stage/pasarguard_data/cert.pem"
        write_runtime "$stage" sqlite pasarguard "pasarguard/panel@$DIGEST_A" "$ID_A"
        write_backup_checksums "$stage"
        [ "$inventory" = keep ] || rm -f "$stage/backup-files.sha256"
        mkdir -p "$WORK_DIR/archives"
        rm -f "$WORK_DIR/archives/$name.zip"
        (cd "$stage" && zip -qr "$WORK_DIR/archives/$name.zip" .)
    }
    make_sqlite_archive good keep
    out=$(run_restore "$WORK_DIR/archives/good.zip" --check 2>&1)
    rc=$?
    assert_eq "$rc" 0 "restore --check: valid SQLite archive passes"
    case "$out" in *"Backup validation passed"*) pass "restore --check: reports success" ;; *) fail "restore --check: reports success" ;; esac
    assert_false "restore --check: does not create the application directory" test -e "$APP_DIR"
    assert_false "restore --check: does not create the data directory" test -e "$DATA_DIR"
    assert_eq "$(wc -l <"$FAKE_DOCKER_DIR/calls.log")" 0 "restore --check: no docker calls"
    assert_eq "$(find "$WORK_DIR/archives" -mindepth 1 -maxdepth 1 -type d | wc -l)" 0 "restore --check: staging removed"

    # Edit one payload file inside an otherwise valid zip.
    rm -rf "$WORK_DIR/edit" && mkdir -p "$WORK_DIR/edit"
    (cd "$WORK_DIR/edit" && unzip -q "$WORK_DIR/archives/good.zip" && printf 'edited\n' >>pasarguard_data/cert.pem && zip -qr "$WORK_DIR/archives/edited.zip" .)
    out=$(run_restore "$WORK_DIR/archives/edited.zip" --check 2>&1)
    assert_eq "$?" 1 "restore --check: edited payload rejected"

    make_sqlite_archive noinventory drop
    out=$(run_restore "$WORK_DIR/archives/noinventory.zip" --check 2>&1)
    assert_eq "$?" 1 "restore --check: recovery metadata without inventory rejected"
    rm -rf "$WORK_DIR/archives" "$WORK_DIR/edit" "$APP_DIR" "$DATA_DIR"
else
    echo "(skipped restore --check cases: sqlite3/zip/unzip unavailable)"
fi

# -----------------------------------------------------------------------
# check_restore_database_version (docker mocked)
# -----------------------------------------------------------------------
reset_fake_docker
stage="$WORK_DIR/version"
mkdir -p "$stage"
# Credentials read by check_restore_database_version from its caller's scope.
# shellcheck disable=SC2034
{
    current_mysql_root_password="root-pass"
    current_db_user="app"
    current_db_password="app-pass"
    db_user="app"
    db_password="app-pass"
}
# Run the version guard: $1 recorded source version, $2 destination answer, $3 engine.
version_guard() {
    printf 'format\t1\nserver_version\t%s\n' "$1" >"$stage/backup-runtime.tsv"
    printf '%s\n' "$2" >"$FAKE_DOCKER_DIR/target_version"
    check_restore_database_version "$stage" "$3" cid-db "$WORK_DIR/version.log" >/dev/null 2>&1
}
assert_false "version guard: PostgreSQL 17 backup into 16 rejected" version_guard "17.2 (Debian 17.2-1.pgdg120+1)" "16.4" postgresql
assert_true "version guard: PostgreSQL 16 backup into 17 allowed" version_guard "16.4" "17.2" postgresql
assert_true "version guard: same TimescaleDB server version allowed" version_guard "17.5" "17.5" timescaledb
assert_false "version guard: MySQL 8.4 backup into 8.0 rejected" version_guard "8.4.3" "8.0.39" mysql
assert_true "version guard: MySQL 8.0 backup into 8.4 allowed" version_guard "8.0.39" "8.4.3" mysql
assert_false "version guard: MySQL backup into MariaDB rejected" version_guard "8.4.3" "11.4.2-MariaDB-ubu2404" mysql
echo 0 >"$FAKE_DOCKER_DIR/has_mariadb"
assert_false "version guard: MariaDB backup into MySQL rejected" version_guard "11.4.2-MariaDB" "8.4.3" mariadb
assert_true "version guard: MariaDB 11.4 backup into 11.8 allowed" version_guard "11.4.2-MariaDB" "11.8.1-MariaDB" mariadb
printf 'format\t1\nserver_version\tunknown\n' >"$stage/backup-runtime.tsv"
: >"$FAKE_DOCKER_DIR/calls.log"
assert_true "version guard: unknown source version is not guessed" check_restore_database_version "$stage" postgresql cid-db "$WORK_DIR/version.log"
assert_eq "$(wc -l <"$FAKE_DOCKER_DIR/calls.log")" 0 "version guard: unknown source version makes no docker calls"
printf 'format\t1\nserver_version\tunknown\n' >"$stage/backup-runtime.tsv"
printf -- '-- Dumped from database version 17.2\n' >"$stage/db_backup.sql"
assert_false "version guard: dump header version used when metadata is unknown" version_guard unknown "16.4" postgresql
rm -f "$stage/db_backup.sql"

# -----------------------------------------------------------------------
# wait_for_recovery_database (docker and sleep mocked)
# -----------------------------------------------------------------------
reset_fake_docker
log="$WORK_DIR/wait.log"
echo healthy >"$FAKE_DOCKER_DIR/state"
assert_true "database wait: healthy healthcheck accepted" wait_for_recovery_database cid-db postgresql 5432 "$log"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "pg_isready" "database wait: healthcheck result used without probing"

reset_fake_docker
echo running >"$FAKE_DOCKER_DIR/state"
printf '2\n2\n0\n' >"$FAKE_DOCKER_DIR/probe"
assert_true "database wait: running PostgreSQL without healthcheck accepted once it answers" wait_for_recovery_database cid-db postgresql 5432 "$log"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "pg_isready -q -h 127.0.0.1 -p 5432" "database wait: PostgreSQL probed over TCP"

reset_fake_docker
echo running >"$FAKE_DOCKER_DIR/state"
printf '1\n0\n' >"$FAKE_DOCKER_DIR/probe"
assert_true "database wait: running MySQL without healthcheck accepted once it answers" wait_for_recovery_database cid-db mysql 3306 "$log"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "mysqladmin ping --silent -h 127.0.0.1" "database wait: MySQL probed over TCP"

reset_fake_docker
echo running >"$FAKE_DOCKER_DIR/state"
printf '1\n0\n' >"$FAKE_DOCKER_DIR/probe"
assert_true "database wait: probe falls back to the default port" wait_for_recovery_database cid-db postgresql 6543 "$log"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "pg_isready -q -h 127.0.0.1 -p 6543" "database wait: connection URL port tried first"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "pg_isready -q -h 127.0.0.1 -p 5432" "database wait: default port tried next"

reset_fake_docker
echo running >"$FAKE_DOCKER_DIR/state"
echo 2 >"$FAKE_DOCKER_DIR/probe"
assert_false "database wait: database that never answers rejected" quiet wait_for_recovery_database cid-db postgresql 5432 "$log"

reset_fake_docker
echo exited >"$FAKE_DOCKER_DIR/state"
assert_false "database wait: exited container rejected" quiet wait_for_recovery_database cid-db postgresql 5432 "$log"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "pg_isready" "database wait: exited container is not probed"

reset_fake_docker
echo unhealthy >"$FAKE_DOCKER_DIR/state"
assert_false "database wait: unhealthy healthcheck rejected" quiet wait_for_recovery_database cid-db postgresql 5432 "$log"

# -----------------------------------------------------------------------
# prepare_fresh_restore (docker mocked): images keep their Compose names
# -----------------------------------------------------------------------
# Build a fresh-recovery stage. $1 panel digest record, $2 panel image id,
# $3 compose image for the panel.
make_fresh_stage() {
    rm -rf "$APP_DIR" "$DATA_DIR" "$WORK_DIR/fresh"
    stage="$WORK_DIR/fresh"
    mkdir -p "$stage"
    printf 'DB_USER=app\nDB_PASSWORD=app-pass\nDB_NAME=appdb\nSQLALCHEMY_DATABASE_URL="postgresql+asyncpg://app:app-pass@127.0.0.1:5432/appdb"\n' >"$stage/.env"
    printf 'services:\n  pasarguard:\n    image: %s\n  postgresql:\n    image: postgres:16\n' "$3" >"$stage/docker-compose.yml"
    cp "$stage/docker-compose.yml" "$WORK_DIR/archived-compose.yml"
    write_runtime "$stage" postgresql pasarguard "$1" "$2" postgresql "postgres@$DIGEST_B" "$ID_B"
    jq -n --arg panel "$3" --arg data "$DATA_DIR" \
        '{services: {pasarguard: {image: $panel, volumes: [{type: "bind", source: $data, target: "/var/lib/pasarguard"}]},
                     postgresql: {image: "postgres:16"}}, volumes: {}}' >"$FAKE_DOCKER_DIR/config.json"
}

reset_fake_docker
make_fresh_stage "pasarguard/panel@$DIGEST_A" "$ID_A" "pasarguard/panel:latest"
fake_image_present "pasarguard/panel@$DIGEST_A"
printf 'postgres@%s\n' "$DIGEST_B" >"$FAKE_DOCKER_DIR/pullable"
fresh_db_container=""
prepare_fresh_restore "$stage" postgresql "$WORK_DIR/fresh.log" 5432 fresh_db_container >"$WORK_DIR/fresh.out" 2>&1
rc=$?
assert_eq "$rc" 0 "fresh: provisioning succeeds"
assert_true "fresh: installed Compose file equals the archived one" cmp -s "$COMPOSE_FILE" "$WORK_DIR/archived-compose.yml"
assert_true "fresh: staged Compose file is left unchanged" cmp -s "$stage/docker-compose.yml" "$WORK_DIR/archived-compose.yml"
assert_file_lacks "$COMPOSE_FILE" "@sha256:" "fresh: no digest pins written into the Compose file"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "tag pasarguard/panel@$DIGEST_A pasarguard/panel:latest" "fresh: local recorded panel image tagged with its Compose name"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "pull postgres@$DIGEST_B" "fresh: missing recorded database image pulled by digest"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "tag postgres@$DIGEST_B postgres:16" "fresh: pulled database image tagged with its Compose name"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "pull pasarguard/panel" "fresh: present recorded image not pulled again"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "yq" "fresh: yq not used"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "install_yq" "fresh: yq not installed"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "up -d --no-deps postgresql" "fresh: only the database started"
assert_eq "$fresh_db_container" "cid-postgresql" "fresh: database container from Compose returned to the caller"
assert_eq "$(stat -c %a "$ENV_FILE")" 600 "fresh: .env installed 0600"

# Offline: no registry digest was recorded, the original image ID is loaded.
reset_fake_docker
make_fresh_stage unavailable "$ID_A" "pasarguard/panel:latest"
fake_image_present "$ID_A"
fake_image_present "postgres@$DIGEST_B"
fresh_db_container=""
prepare_fresh_restore "$stage" postgresql "$WORK_DIR/fresh.log" 5432 fresh_db_container >"$WORK_DIR/fresh.out" 2>&1
assert_eq "$?" 0 "fresh offline: loaded image ID accepted"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "tag $ID_A pasarguard/panel:latest" "fresh offline: loaded image ID tagged with its Compose name"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "pull" "fresh offline: nothing pulled"

# A digest that is not local is preferred over pulling when the image ID is local.
reset_fake_docker
make_fresh_stage "pasarguard/panel@$DIGEST_A" "$ID_A" "pasarguard/panel:latest"
fake_image_present "$ID_A"
fake_image_present "postgres@$DIGEST_B"
prepare_fresh_restore "$stage" postgresql "$WORK_DIR/fresh.log" 5432 fresh_db_container >"$WORK_DIR/fresh.out" 2>&1
assert_eq "$?" 0 "fresh: local image ID used when the digest is not local"
assert_file_has "$FAKE_DOCKER_DIR/calls.log" "tag $ID_A pasarguard/panel:latest" "fresh: local image ID tagged instead of pulling"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "pull" "fresh: no pull when the image ID is local"

# No digest and no local image: refuse before provisioning anything.
reset_fake_docker
make_fresh_stage unavailable "$ID_A" "pasarguard/panel:latest"
fake_image_present "postgres@$DIGEST_B"
prepare_fresh_restore "$stage" postgresql "$WORK_DIR/fresh.log" 5432 fresh_db_container >"$WORK_DIR/fresh.out" 2>&1
assert_eq "$?" 1 "fresh: unreproducible image refused"
assert_file_has "$WORK_DIR/fresh.out" "No reproducible image for service 'pasarguard'" "fresh: refusal names the service"
assert_false "fresh: refusal installs no .env" test -e "$ENV_FILE"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "tag " "fresh: refusal tags nothing"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" " up " "fresh: refusal starts nothing"

# A Compose image already pinned to the recorded digest is used as is.
reset_fake_docker
make_fresh_stage "pasarguard/panel@$DIGEST_A" "$ID_A" "pasarguard/panel@$DIGEST_A"
fake_image_present "pasarguard/panel@$DIGEST_A"
fake_image_present "postgres@$DIGEST_B"
prepare_fresh_restore "$stage" postgresql "$WORK_DIR/fresh.log" 5432 fresh_db_container >"$WORK_DIR/fresh.out" 2>&1
assert_eq "$?" 0 "fresh: Compose digest pin equal to the recorded digest accepted"
assert_file_lacks "$FAKE_DOCKER_DIR/calls.log" "tag pasarguard/panel@$DIGEST_A" "fresh: digest-pinned Compose image not retagged"

# A Compose image pinned to another digest cannot be satisfied by tagging.
reset_fake_docker
make_fresh_stage "pasarguard/panel@$DIGEST_A" "$ID_A" "pasarguard/panel@$DIGEST_B"
fake_image_present "pasarguard/panel@$DIGEST_A"
fake_image_present "postgres@$DIGEST_B"
prepare_fresh_restore "$stage" postgresql "$WORK_DIR/fresh.log" 5432 fresh_db_container >"$WORK_DIR/fresh.out" 2>&1
assert_eq "$?" 1 "fresh: Compose digest pin different from the recorded digest refused"
assert_false "fresh: digest mismatch installs no .env" test -e "$ENV_FILE"

# A database without a healthcheck is accepted once it answers.
reset_fake_docker
make_fresh_stage "pasarguard/panel@$DIGEST_A" "$ID_A" "pasarguard/panel:latest"
fake_image_present "pasarguard/panel@$DIGEST_A"
fake_image_present "postgres@$DIGEST_B"
echo running >"$FAKE_DOCKER_DIR/state"
printf '2\n0\n' >"$FAKE_DOCKER_DIR/probe"
fresh_db_container=""
prepare_fresh_restore "$stage" postgresql "$WORK_DIR/fresh.log" 5432 fresh_db_container >"$WORK_DIR/fresh.out" 2>&1
assert_eq "$?" 0 "fresh: database without healthcheck accepted once it answers"
assert_eq "$fresh_db_container" "cid-postgresql" "fresh: probed database container returned to the caller"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
