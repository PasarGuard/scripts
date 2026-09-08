#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="transaction-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

curl() { printf '\n'; }
export -f curl
export PG_NODE_SOURCE_ONLY=true
# shellcheck source=pg-node.sh
source "$ROOT_DIR/pg-node.sh"
original_service_installed_definition=$(declare -f service_installed)
original_uninstall_node_service_script_definition=$(declare -f uninstall_node_service_script)
original_append_node_service_api_port_definition=$(declare -f append_node_service_api_port)

PASS=0
FAIL=0
pass() { printf '✓ %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_true() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
assert_false() { local label="$1"; shift; if ! "$@"; then pass "$label"; else fail "$label"; fi; }
assert_file() {
    local path="$1" expected="$2" label="$3"
    if [ -f "$path" ] && [ "$(cat "$path")" = "$expected" ]; then pass "$label"; else fail "$label"; fi
}
assert_no_backups() {
    local label="$1"
    if find "$CASE_DIR" -type f \( -name '.*.transaction.*' -o -name '.*.transaction-target.*' -o -name '.*.backup.*' \) -print -quit | grep -q .; then
        fail "$label"
    else
        pass "$label"
    fi
}
assert_lock_released() {
    local label="$1"
    if flock -n "$NODE_SERVICE_UPDATE_LOCK_PATH" -c true; then pass "$label"; else fail "$label"; fi
}

setup_case() {
    local name="$1"
    CASE_DIR="$WORK_DIR/$name"
    mkdir -p "$CASE_DIR"
    APP_DIR="$CASE_DIR"
    ENV_FILE="$CASE_DIR/.env"
    SERVICE_NAME="transaction-test-service"
    SERVICE_UNIT="$CASE_DIR/$SERVICE_NAME.service"
    SERVICE_BINARY_PATH="$CASE_DIR/$SERVICE_NAME"
    NODE_SERVICE_UPDATE_LOCK_PATH="$CASE_DIR/update.lock"
    VALID_BINARY="$CASE_DIR/candidate"
    ACTIVATED_MARKER="$CASE_DIR/activated"
    BLOCK_MARKER="$CASE_DIR/blocking"
    TRANSACTION_PID_FILE="$CASE_DIR/transaction-pid"
    RELEASE_MARKER="$CASE_DIR/release"
    RESTART_COUNT="$CASE_DIR/restarts"
    SYSTEMCTL_MUTATION_LOG="$CASE_DIR/systemctl-mutations"
    printf 'old-env\n' > "$ENV_FILE"
    printf 'old-unit\n' > "$SERVICE_UNIT"
    printf '\177ELFold-binary\n' > "$SERVICE_BINARY_PATH"
    printf '\177ELFnew-binary\n' > "$VALID_BINARY"
    printf '0\n' > "$RESTART_COUNT"
    : > "$SYSTEMCTL_MUTATION_LOG"
    NODE_SERVICE_UPDATE_LOCK_HELD=false
    unset STOP_FAILURE DISABLE_FAILURE SERVICE_INACTIVE SERVICE_DISABLED
}

set_service_paths() { :; }
service_installed() { return 0; }
id() { printf '0\n'; }
wait_for_node_service_ready() { return 0; }
systemctl() {
    case "${1:-}" in
    is-active)
        [ "${SERVICE_INACTIVE:-false}" = true ] && return 3
        return 0
        ;;
    is-enabled)
        [ "${SERVICE_DISABLED:-false}" = true ] && return 1
        return 0
        ;;
    stop)
        printf 'stop\n' >> "$SYSTEMCTL_MUTATION_LOG"
        [ "${STOP_FAILURE:-false}" != true ]
        ;;
    disable)
        printf 'disable\n' >> "$SYSTEMCTL_MUTATION_LOG"
        [ "${DISABLE_FAILURE:-false}" != true ]
        ;;
    enable | daemon-reload)
        printf '%s\n' "$1" >> "$SYSTEMCTL_MUTATION_LOG"
        return 0
        ;;
    start)
        printf 'start\n' >> "$SYSTEMCTL_MUTATION_LOG"
        return 0
        ;;
    restart)
        printf 'restart\n' >> "$SYSTEMCTL_MUTATION_LOG"
        local count
        count=$(cat "$RESTART_COUNT")
        count=$((count + 1))
        printf '%s\n' "$count" > "$RESTART_COUNT"
        if [ "${BLOCK_FIRST_RESTART:-false}" = true ] && [ "$count" -eq 1 ]; then
            printf '%s\n' "$BASHPID" > "$TRANSACTION_PID_FILE"
            : > "$BLOCK_MARKER"
            while [ ! -e "$RELEASE_MARKER" ]; do sleep 0.02; done
        fi
        return 0
        ;;
    *) return 0 ;;
    esac
}

install_node_service_script() {
    activate_node_serviced_binary "$VALID_BINARY"
    printf 'new-env\n' > "$ENV_FILE"
    printf 'new-unit\n' > "$SERVICE_UNIT"
    : > "$ACTIVATED_MARKER"
}
transaction_test_install_node_service_script_definition=$(declare -f install_node_service_script)

echo "=== test_node_service_transaction_guard.sh ==="

# Secret-bearing environment snapshots remain owner-readable even if a legacy
# installation left the source .env world-readable.
setup_case secure-env-backup
chmod 644 "$ENV_FILE"
acquire_node_serviced_update_lock
begin_node_service_transaction
env_backup="${NODE_SERVICE_TRANSACTION_BACKUPS[0]}"
[ "$(stat -c '%a' "$env_backup")" = "600" ] && pass "backup security: .env snapshot is 0600" || fail "backup security: .env snapshot is 0600"
abort_node_service_transaction
assert_no_backups "backup security: snapshots cleaned"
assert_lock_released "backup security: flock released"

# Deliver a real TERM after binary activation. The public command runs the
# guard in a subshell, so its traps cannot replace the caller's traps.
setup_case signal
BLOCK_FIRST_RESTART=true
caller_traps_before=$(trap -p EXIT INT TERM)
update_service_if_installed >/dev/null 2>&1 &
transaction_pid=$!
for _ in {1..200}; do
    [ -e "$BLOCK_MARKER" ] && break
    sleep 0.01
done
if [ -e "$BLOCK_MARKER" ]; then pass "signal: replacement reached activation"; else fail "signal: replacement reached activation"; fi
guarded_pid=$(cat "$TRANSACTION_PID_FILE")
kill -TERM "$guarded_pid"
set +e
wait "$transaction_pid"
signal_status=$?
set -e
[ "$signal_status" -eq 143 ] && pass "signal: TERM status is preserved" || fail "signal: TERM status is preserved"
assert_file "$ENV_FILE" "old-env" "signal: environment snapshot restored"
assert_file "$SERVICE_UNIT" "old-unit" "signal: unit snapshot restored"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "signal: binary snapshot restored" || fail "signal: binary snapshot restored"
assert_no_backups "signal: candidate backups removed"
assert_lock_released "signal: flock released"
caller_traps_after=$(trap -p EXIT INT TERM)
[ "$caller_traps_after" = "$caller_traps_before" ] && pass "signal: caller traps preserved" || fail "signal: caller traps preserved"
unset BLOCK_FIRST_RESTART

# A checksum/download failure happens before activation and therefore must only
# discard snapshots/temp state. It must not restart, enable, disable, or reload
# a service whose files and runtime state were never changed.
setup_case premutation-download-failure
install_node_service_script() { return 64; }
set +e
update_service_if_installed >/dev/null 2>&1
premutation_status=$?
set -e
[ "$premutation_status" -ne 0 ] && pass "pre-mutation failure: failure propagated" || fail "pre-mutation failure: failure propagated"
[ ! -s "$SYSTEMCTL_MUTATION_LOG" ] && pass "pre-mutation failure: no service mutation" || fail "pre-mutation failure: no service mutation"
assert_file "$ENV_FILE" "old-env" "pre-mutation failure: environment unchanged"
assert_file "$SERVICE_UNIT" "old-unit" "pre-mutation failure: unit unchanged"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "pre-mutation failure: binary unchanged" || fail "pre-mutation failure: binary unchanged"
assert_no_backups "pre-mutation failure: snapshots removed"
assert_lock_released "pre-mutation failure: flock released"
eval "$transaction_test_install_node_service_script_definition"

# Public service commands must distinguish a confirmed absent unit (status 1)
# from an inspection failure. A timeout/error cannot fall through to start.
setup_case service-inspection-failure
check_running_as_root() { :; }
require_systemd() { :; }
service_installed() { return 124; }
set +e
service_start_command >/dev/null 2>&1
inspection_status=$?
set -e
[ "$inspection_status" -ne 0 ] && pass "service inspection failure: failure propagated" || fail "service inspection failure: failure propagated"
if grep -qx 'start' "$SYSTEMCTL_MUTATION_LOG"; then fail "service inspection failure: start not attempted"; else pass "service inspection failure: start not attempted"; fi
service_installed() { return 0; }

# Exercise an unanticipated errexit in a subprocess, without an explicit
# `if ! command` failure branch.
setup_case errexit
unexpected_failure() (
    acquire_node_serviced_update_lock
    begin_node_service_transaction
    activate_node_serviced_binary "$VALID_BINARY"
    printf 'new-env\n' > "$ENV_FILE"
    printf 'new-unit\n' > "$SERVICE_UNIT"
    false
    commit_node_service_transaction
)
unexpected_failure >/dev/null 2>&1 &
failure_pid=$!
set +e
wait "$failure_pid"
failure_status=$?
set -e
[ "$failure_status" -ne 0 ] && pass "errexit: failure propagated" || fail "errexit: failure propagated"
assert_file "$ENV_FILE" "old-env" "errexit: environment snapshot restored"
assert_file "$SERVICE_UNIT" "old-unit" "errexit: unit snapshot restored"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "errexit: binary snapshot restored" || fail "errexit: binary snapshot restored"
assert_no_backups "errexit: backups removed"
assert_lock_released "errexit: flock released"

# Uninstall is guarded too: an unexpected failure after binary removal must
# restore both the binary and unit instead of committing a partial uninstall.
setup_case uninstall
uninstall_node_service_script() {
    rm -f "$SERVICE_BINARY_PATH"
    return 42
}
uninstall_service_command >/dev/null 2>&1 &
uninstall_pid=$!
set +e
wait "$uninstall_pid"
uninstall_status=$?
set -e
[ "$uninstall_status" -ne 0 ] && pass "uninstall: failure propagated" || fail "uninstall: failure propagated"
assert_file "$SERVICE_UNIT" "old-unit" "uninstall: unit restored"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "uninstall: binary restored" || fail "uninstall: binary restored"
assert_no_backups "uninstall: backups removed"
assert_lock_released "uninstall: flock released"

# stop/disable are part of the uninstall transaction. A failed request may
# have changed systemd despite its status, so fail closed and roll back without
# deleting either installed artifact.
setup_case uninstall-stop-failure
eval "$original_uninstall_node_service_script_definition"
STOP_FAILURE=true
set +e
uninstall_service_command >/dev/null 2>&1
uninstall_stop_status=$?
set -e
[ "$uninstall_stop_status" -ne 0 ] && pass "uninstall stop failure: failure propagated" || fail "uninstall stop failure: failure propagated"
assert_file "$SERVICE_UNIT" "old-unit" "uninstall stop failure: unit retained"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "uninstall stop failure: binary retained" || fail "uninstall stop failure: binary retained"
assert_no_backups "uninstall stop failure: backups removed"
assert_lock_released "uninstall stop failure: flock released"

setup_case uninstall-disable-failure
eval "$original_uninstall_node_service_script_definition"
DISABLE_FAILURE=true
set +e
uninstall_service_command >/dev/null 2>&1
uninstall_disable_status=$?
set -e
[ "$uninstall_disable_status" -ne 0 ] && pass "uninstall disable failure: failure propagated" || fail "uninstall disable failure: failure propagated"
assert_file "$SERVICE_UNIT" "old-unit" "uninstall disable failure: unit retained"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "uninstall disable failure: binary retained" || fail "uninstall disable failure: binary retained"
assert_no_backups "uninstall disable failure: backups removed"
assert_lock_released "uninstall disable failure: flock released"

setup_case uninstall-inactive-disabled
eval "$original_uninstall_node_service_script_definition"
SERVICE_INACTIVE=true
SERVICE_DISABLED=true
set +e
uninstall_service_command >/dev/null 2>&1
uninstall_idempotent_status=$?
set -e
[ "$uninstall_idempotent_status" -eq 0 ] && pass "uninstall inactive/disabled: succeeds" || fail "uninstall inactive/disabled: succeeds"
[ ! -e "$SERVICE_UNIT" ] && pass "uninstall inactive/disabled: unit removed" || fail "uninstall inactive/disabled: unit removed"
[ ! -e "$SERVICE_BINARY_PATH" ] && pass "uninstall inactive/disabled: binary removed" || fail "uninstall inactive/disabled: binary removed"
if grep -Eq '^(stop|disable)$' "$SYSTEMCTL_MUTATION_LOG"; then fail "uninstall inactive/disabled: no redundant stop/disable"; else pass "uninstall inactive/disabled: no redundant stop/disable"; fi
assert_no_backups "uninstall inactive/disabled: backups removed"
assert_lock_released "uninstall inactive/disabled: flock released"

# Dangling artifacts are still installation residue and must be removed.
setup_case uninstall-dangling-symlinks
rm -f "$SERVICE_UNIT" "$SERVICE_BINARY_PATH"
ln -s "$CASE_DIR/missing-unit" "$SERVICE_UNIT"
ln -s "$CASE_DIR/missing-binary" "$SERVICE_BINARY_PATH"
SERVICE_INACTIVE=true
SERVICE_DISABLED=true
uninstall_service_command >/dev/null 2>&1
[ ! -L "$SERVICE_UNIT" ] && pass "uninstall dangling symlink: unit removed" || fail "uninstall dangling symlink: unit removed"
[ ! -L "$SERVICE_BINARY_PATH" ] && pass "uninstall dangling symlink: binary removed" || fail "uninstall dangling symlink: binary removed"
assert_lock_released "uninstall dangling symlink: flock released"

# Reinstall snapshots are armed before env mutation and binary activation. A
# later unit-write failure must restore every artifact through the same guard.
setup_case install
check_running_as_root() { :; }
require_systemd() { :; }
detect_os() { :; }
install_package() { :; }
is_node_installed() { return 0; }
ensure_env_exists() { printf 'generated-env\n' > "$ENV_FILE"; }
sync_env_ssl_paths() { :; }
get_occupied_ports() { OCCUPIED_PORTS=""; }
is_port_occupied() { return 1; }
configure_firewall_for_port() { :; }
write_node_service_unit() {
    printf 'partial-unit\n' > "$SERVICE_UNIT"
    return 1
}
AUTO_CONFIRM=true
INSTALL_API_PORT=62051
install_service_command >/dev/null 2>&1 &
install_pid=$!
set +e
wait "$install_pid"
install_status=$?
set -e
[ "$install_status" -ne 0 ] && pass "install: failure propagated" || fail "install: failure propagated"
assert_file "$ENV_FILE" "old-env" "install: environment restored"
assert_file "$SERVICE_UNIT" "old-unit" "install: unit restored"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "install: binary restored" || fail "install: binary restored"
assert_no_backups "install: backups removed"
assert_lock_released "install: flock released"

# Both the replace and append paths for API_PORT are transactional. A write
# failure must stop before binary activation and restore the original env.
setup_case install-api-port-replace-failure
printf 'API_PORT= 61000\n' > "$ENV_FILE"
ensure_env_exists() { :; }
sed() {
    if [ "${1:-}" = "-i" ]; then return 74; fi
    command sed "$@"
}
rm -f "$ACTIVATED_MARKER"
set +e
install_service_command >/dev/null 2>&1
api_port_replace_status=$?
set -e
unset -f sed
[ "$api_port_replace_status" -ne 0 ] && pass "API_PORT replace failure: failure propagated" || fail "API_PORT replace failure: failure propagated"
assert_file "$ENV_FILE" "API_PORT= 61000" "API_PORT replace failure: environment restored"
[ ! -e "$ACTIVATED_MARKER" ] && pass "API_PORT replace failure: binary activation skipped" || fail "API_PORT replace failure: binary activation skipped"
assert_no_backups "API_PORT replace failure: snapshots removed"
assert_lock_released "API_PORT replace failure: flock released"

setup_case install-api-port-append-failure
append_node_service_api_port() { return 75; }
rm -f "$ACTIVATED_MARKER"
set +e
install_service_command >/dev/null 2>&1
api_port_append_status=$?
set -e
eval "$original_append_node_service_api_port_definition"
[ "$api_port_append_status" -ne 0 ] && pass "API_PORT append failure: failure propagated" || fail "API_PORT append failure: failure propagated"
assert_file "$ENV_FILE" "old-env" "API_PORT append failure: environment restored"
[ ! -e "$ACTIVATED_MARKER" ] && pass "API_PORT append failure: binary activation skipped" || fail "API_PORT append failure: binary activation skipped"
assert_no_backups "API_PORT append failure: snapshots removed"
assert_lock_released "API_PORT append failure: flock released"

# Snapshot both the symlink inode and its referent. Rollback must restore the
# exact relative link text as well as referent content changed through the link.
setup_case symlink
mkdir -p "$CASE_DIR/targets"
mv "$ENV_FILE" "$CASE_DIR/targets/env"
mv "$SERVICE_UNIT" "$CASE_DIR/targets/unit"
mv "$SERVICE_BINARY_PATH" "$CASE_DIR/targets/binary"
ln -s targets/env "$ENV_FILE"
ln -s targets/unit "$SERVICE_UNIT"
ln -s targets/binary "$SERVICE_BINARY_PATH"
acquire_node_serviced_update_lock
begin_node_service_transaction
mark_node_service_transaction_mutation_started
printf 'changed-target-env\n' > "$CASE_DIR/targets/env"
printf 'changed-target-unit\n' > "$CASE_DIR/targets/unit"
printf '\177ELFchanged-target-binary\n' > "$CASE_DIR/targets/binary"
rm -f "$ENV_FILE" "$SERVICE_UNIT" "$SERVICE_BINARY_PATH"
printf 'replacement-env\n' > "$ENV_FILE"
printf 'replacement-unit\n' > "$SERVICE_UNIT"
printf '\177ELFreplacement-binary\n' > "$SERVICE_BINARY_PATH"
assert_true "symlink: first rollback succeeds" rollback_node_service_transaction
assert_true "symlink: repeated rollback is idempotent" rollback_node_service_transaction
[ -L "$ENV_FILE" ] && [ "$(readlink "$ENV_FILE")" = targets/env ] && pass "symlink: environment link topology restored" || fail "symlink: environment link topology restored"
[ -L "$SERVICE_UNIT" ] && [ "$(readlink "$SERVICE_UNIT")" = targets/unit ] && pass "symlink: unit link topology restored" || fail "symlink: unit link topology restored"
[ -L "$SERVICE_BINARY_PATH" ] && [ "$(readlink "$SERVICE_BINARY_PATH")" = targets/binary ] && pass "symlink: binary link topology restored" || fail "symlink: binary link topology restored"
assert_file "$CASE_DIR/targets/env" "old-env" "symlink: environment referent restored"
assert_file "$CASE_DIR/targets/unit" "old-unit" "symlink: unit referent restored"
grep -q 'old-binary' "$CASE_DIR/targets/binary" && pass "symlink: binary referent restored" || fail "symlink: binary referent restored"
finish_node_service_transaction
assert_no_backups "symlink: backups removed after successful retry-safe rollback"
assert_lock_released "symlink: flock released"

# A failed restore must retain its backup handle. A second rollback retries only
# unfinished entries and succeeds instead of returning failure permanently.
setup_case retry
acquire_node_serviced_update_lock
begin_node_service_transaction
mark_node_service_transaction_mutation_started
printf 'new-env\n' > "$ENV_FILE"
printf 'new-unit\n' > "$SERVICE_UNIT"
printf '\177ELFnew-binary\n' > "$SERVICE_BINARY_PATH"
MV_FAILURE_MARKER="$CASE_DIR/mv-failed-once"
ENV_BACKUP_TO_FAIL="${NODE_SERVICE_TRANSACTION_BACKUPS[0]}"
cp() {
    if [ "${2:-}" = "$ENV_BACKUP_TO_FAIL" ] && [ ! -e "$MV_FAILURE_MARKER" ]; then
        : > "$MV_FAILURE_MARKER"
        return 1
    fi
    command cp "$@"
}
assert_false "retry: first rollback reports restore failure" rollback_node_service_transaction
env_snapshot_index=0
env_backup_path="${NODE_SERVICE_TRANSACTION_BACKUPS[env_snapshot_index]}"
[ -n "$env_backup_path" ] && [ -e "$env_backup_path" ] && pass "retry: failed restore retains backup handle" || fail "retry: failed restore retains backup handle"
assert_true "retry: second rollback succeeds" rollback_node_service_transaction
assert_file "$ENV_FILE" "old-env" "retry: environment restored on second attempt"
assert_file "$SERVICE_UNIT" "old-unit" "retry: completed unit restore remains intact"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "retry: completed binary restore remains intact" || fail "retry: completed binary restore remains intact"
unset -f cp
finish_node_service_transaction
assert_no_backups "retry: backups removed after successful retry"
assert_lock_released "retry: flock released"

# On a first install, failing `systemctl disable --now` during rollback means
# the unit can remain loaded/active. Report the orphan risk and retain the
# filesystem snapshots for manual recovery instead of declaring success.
setup_case first-install-disable-failure
rm -f "$SERVICE_UNIT" "$SERVICE_BINARY_PATH"
service_installed() { return 1; }
acquire_node_serviced_update_lock
begin_node_service_transaction
mark_node_service_transaction_mutation_started
printf 'new-env\n' > "$ENV_FILE"
printf 'new-unit\n' > "$SERVICE_UNIT"
printf '\177ELFnew-binary\n' > "$SERVICE_BINARY_PATH"
DISABLE_FAILURE=true
set +e
first_install_rollback_output=$(abort_node_service_transaction 2>&1)
first_install_rollback_status=$?
set -e
[ "$first_install_rollback_status" -ne 0 ] && pass "first-install disable failure: rollback reports failure" || fail "first-install disable failure: rollback reports failure"
assert_file "$ENV_FILE" "old-env" "first-install disable failure: environment restored"
[ ! -e "$SERVICE_UNIT" ] && [ ! -e "$SERVICE_BINARY_PATH" ] && pass "first-install disable failure: new artifacts removed" || fail "first-install disable failure: new artifacts removed"
if [[ "$first_install_rollback_output" == *"may remain loaded or active"* ]]; then pass "first-install disable failure: orphaned unit is reported"; else fail "first-install disable failure: orphaned unit is reported"; fi
if find "$CASE_DIR" -type f -name '.*.transaction.*' -print -quit | grep -q .; then pass "first-install disable failure: snapshots retained"; else fail "first-install disable failure: snapshots retained"; fi
assert_lock_released "first-install disable failure: flock released"
cleanup_node_service_transaction_backups
service_installed() { return 0; }

# Production uses an external systemctl process group. TERM sent to the
# transaction shell must promptly reach the external child and its descendant,
# then rollback and release the lock without waiting for the child timeout.
# Force the compatibility path used by setsid implementations without --wait.
NODE_SERVICE_SETSID_WAIT_SUPPORTED=false
setup_case external-signal
EXTERNAL_BIN="$CASE_DIR/bin"
EXTERNAL_CHILD_PID_FILE="$CASE_DIR/external-child-pid"
mkdir -p "$EXTERNAL_BIN"
cat > "$EXTERNAL_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
is-active|is-enabled|daemon-reload|enable|disable|stop) exit 0 ;;
restart)
    count=$(cat "$RESTART_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$RESTART_COUNT"
    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$PPID" > "$TRANSACTION_PID_FILE"
        (
            trap 'exit 143' TERM INT
            printf '%s\n' "$BASHPID" > "$EXTERNAL_CHILD_PID_FILE"
            : > "$BLOCK_MARKER"
            while :; do sleep 1; done
        ) &
        wait "$!"
    fi
    exit 0
    ;;
*) exit 0 ;;
esac
EOF
chmod +x "$EXTERNAL_BIN/systemctl"
export RESTART_COUNT TRANSACTION_PID_FILE EXTERNAL_CHILD_PID_FILE BLOCK_MARKER
external_started=$(date +%s)
(
    unset -f systemctl
    PATH="$EXTERNAL_BIN:$PATH"
    update_service_if_installed >/dev/null 2>&1 &
    outer_pid=$!
    for _ in {1..200}; do
        [ -e "$BLOCK_MARKER" ] && break
        sleep 0.01
    done
    kill -TERM "$(cat "$TRANSACTION_PID_FILE")"
    set +e
    wait "$outer_pid"
    printf '%s\n' "$?" > "$CASE_DIR/external-status"
    set -e
)
external_elapsed=$(( $(date +%s) - external_started ))
[ "$(cat "$CASE_DIR/external-status")" -eq 143 ] && pass "external signal: TERM status preserved" || fail "external signal: TERM status preserved"
[ "$external_elapsed" -lt 5 ] && pass "external signal: child process group terminated promptly" || fail "external signal: child process group terminated promptly"
if [ ! -s "$EXTERNAL_CHILD_PID_FILE" ]; then
    fail "external signal: descendant recorded its pid"
elif kill -0 "$(cat "$EXTERNAL_CHILD_PID_FILE")" >/dev/null 2>&1; then
    fail "external signal: descendant terminated"
else
    pass "external signal: descendant terminated"
fi
assert_file "$ENV_FILE" "old-env" "external signal: environment restored"
assert_file "$SERVICE_UNIT" "old-unit" "external signal: unit restored"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "external signal: binary restored" || fail "external signal: binary restored"
assert_no_backups "external signal: backups removed"
assert_lock_released "external signal: flock released"
unset NODE_SERVICE_SETSID_WAIT_SUPPORTED

# A hung external mutation is bounded even without an incoming signal. The
# watchdog terminates its process group, then the failure path rolls back.
setup_case external-timeout
EXTERNAL_BIN="$CASE_DIR/bin"
TIMEOUT_ONCE_MARKER="$CASE_DIR/timed-out-once"
mkdir -p "$EXTERNAL_BIN"
cat > "$EXTERNAL_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
is-active|is-enabled|enable|disable|stop|restart) exit 0 ;;
daemon-reload)
    if [ -e "$ACTIVATED_MARKER" ] && [ ! -e "$TIMEOUT_ONCE_MARKER" ]; then
        : > "$TIMEOUT_ONCE_MARKER"
        (while :; do sleep 1; done) &
        wait "$!"
    fi
    exit 0
    ;;
*) exit 0 ;;
esac
EOF
chmod +x "$EXTERNAL_BIN/systemctl"
export ACTIVATED_MARKER TIMEOUT_ONCE_MARKER
timeout_started=$(date +%s)
set +e
(
    unset -f systemctl
    PATH="$EXTERNAL_BIN:$PATH"
    NODE_SERVICE_SYSTEMCTL_TIMEOUT_SECONDS=1
    NODE_SERVICE_EXTERNAL_KILL_AFTER_SECONDS=0.2
    update_service_if_installed >/dev/null 2>&1
)
timeout_status=$?
set -e
timeout_elapsed=$(( $(date +%s) - timeout_started ))
[ "$timeout_status" -ne 0 ] && pass "external timeout: failure propagated" || fail "external timeout: failure propagated"
[ "$timeout_elapsed" -lt 5 ] && pass "external timeout: bounded policy enforced" || fail "external timeout: bounded policy enforced"
assert_file "$ENV_FILE" "old-env" "external timeout: environment restored"
assert_file "$SERVICE_UNIT" "old-unit" "external timeout: unit restored"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "external timeout: binary restored" || fail "external timeout: binary restored"
assert_no_backups "external timeout: backups removed"
assert_lock_released "external timeout: flock released"

# Service discovery itself is an external systemctl call. The mutation lock
# and transaction traps must already be armed when it wedges, so a real TERM
# cannot strand the lock, snapshots, temporary output, or the process group.
setup_case service-query-signal
QUERY_BIN="$CASE_DIR/bin"
QUERY_BLOCK_MARKER="$CASE_DIR/query-blocking"
QUERY_DESCENDANT_PID_FILE="$CASE_DIR/query-descendant-pid"
mkdir -p "$QUERY_BIN"
cat > "$QUERY_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
list-unit-files)
    printf '%s\n' "$PPID" > "$TRANSACTION_PID_FILE"
    trap '' TERM INT
    (
        trap '' TERM INT
        printf '%s\n' "$BASHPID" > "$QUERY_DESCENDANT_PID_FILE"
        : > "$QUERY_BLOCK_MARKER"
        while :; do sleep 1; done
    ) &
    wait "$!"
    ;;
*) printf '%s\n' "$1" >> "$SYSTEMCTL_MUTATION_LOG"; exit 0 ;;
esac
EOF
chmod +x "$QUERY_BIN/systemctl"
rm -f "$SERVICE_UNIT"
export TRANSACTION_PID_FILE QUERY_BLOCK_MARKER QUERY_DESCENDANT_PID_FILE SYSTEMCTL_MUTATION_LOG
query_started=$(date +%s)
(
    unset -f service_installed systemctl
    eval "$original_service_installed_definition"
    PATH="$QUERY_BIN:$PATH"
    NODE_SERVICE_SYSTEMCTL_TIMEOUT_SECONDS=30
    NODE_SERVICE_EXTERNAL_KILL_AFTER_SECONDS=0.2
    update_service_if_installed >/dev/null 2>&1 &
    outer_pid=$!
    for _ in {1..200}; do
        [ -e "$QUERY_BLOCK_MARKER" ] && break
        sleep 0.01
    done
    kill -TERM "$(cat "$TRANSACTION_PID_FILE")"
    set +e
    wait "$outer_pid"
    printf '%s\n' "$?" > "$CASE_DIR/query-status"
    set -e
)
query_elapsed=$(( $(date +%s) - query_started ))
[ "$(cat "$CASE_DIR/query-status")" -eq 143 ] && pass "service query signal: TERM status preserved" || fail "service query signal: TERM status preserved"
[ "$query_elapsed" -lt 5 ] && pass "service query signal: TERM-ignoring process group terminated promptly" || fail "service query signal: TERM-ignoring process group terminated promptly"
if [ ! -s "$QUERY_DESCENDANT_PID_FILE" ]; then
    fail "service query signal: descendant recorded its pid"
elif kill -0 "$(cat "$QUERY_DESCENDANT_PID_FILE")" >/dev/null 2>&1; then
    fail "service query signal: descendant terminated"
else
    pass "service query signal: descendant terminated"
fi
assert_file "$ENV_FILE" "old-env" "service query signal: environment snapshot restored"
grep -q 'old-binary' "$SERVICE_BINARY_PATH" && pass "service query signal: binary snapshot restored" || fail "service query signal: binary snapshot restored"
[ ! -e "$SERVICE_UNIT" ] && pass "service query signal: absent unit remains absent" || fail "service query signal: absent unit remains absent"
[ ! -s "$SYSTEMCTL_MUTATION_LOG" ] && pass "service query signal: no service mutation with unknown state" || fail "service query signal: no service mutation with unknown state"
assert_no_backups "service query signal: backups removed"
if find "$APP_TMP_DIR" -type f -name 'node-service-unit-list-*' -print -quit | grep -q .; then fail "service query signal: temporary query output removed"; else pass "service query signal: temporary query output removed"; fi
assert_lock_released "service query signal: flock released"

# Once committed, a later non-zero exit only finalizes cleanup and must not
# restore the old snapshot over the committed installation.
setup_case commit
committed_then_failed() (
    acquire_node_serviced_update_lock
    begin_node_service_transaction
    mark_node_service_transaction_mutation_started
    printf 'committed-env\n' > "$ENV_FILE"
    printf 'committed-unit\n' > "$SERVICE_UNIT"
    install -m 755 "$VALID_BINARY" "$SERVICE_BINARY_PATH"
    commit_node_service_transaction
    return 77
)
committed_then_failed >/dev/null 2>&1 &
commit_pid=$!
set +e
wait "$commit_pid"
commit_status=$?
set -e
[ "$commit_status" -eq 77 ] && pass "commit: later failure propagated" || fail "commit: later failure propagated"
assert_file "$ENV_FILE" "committed-env" "commit: environment not rolled back"
assert_file "$SERVICE_UNIT" "committed-unit" "commit: unit not rolled back"
grep -q 'new-binary' "$SERVICE_BINARY_PATH" && pass "commit: binary not rolled back" || fail "commit: binary not rolled back"
assert_no_backups "commit: backups removed"
assert_lock_released "commit: flock released"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
