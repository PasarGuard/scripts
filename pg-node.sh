#!/usr/bin/env bash
set -e

SCRIPT_COMMIT_SHA="${SCRIPT_COMMIT_SHA:-__SCRIPT_COMMIT_SHA__}"
SCRIPT_DIR="${PG_NODE_SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
SHARED_LIB_DIR="${SCRIPT_DIR}/lib"
REQUIRED_SHARED_LIBS="common.sh system.sh docker.sh github.sh"
# Running from a local checkout/bundle (libs sit next to this script) vs. an
# installed copy (libs live under /usr/local/lib). Only the installed copy is
# auto-refreshed below; a checkout's libs are used as-is.
running_from_checkout=true
if [ ! -f "$SHARED_LIB_DIR/common.sh" ]; then
    SHARED_LIB_DIR="/usr/local/lib/pasarguard-scripts/lib"
    running_from_checkout=false
fi

# Refresh every shared library from the repo into the install dir. All files are
# downloaded to a staging dir first and only swapped in if EVERY download
# succeeds, so a partial/failed refresh never leaves a half-updated set and any
# existing copy is preserved on failure.
bootstrap_pg_node_shared_libs() {
    local fetch_repo="PasarGuard/scripts"
    local bootstrap_dir="/usr/local/lib/pasarguard-scripts/lib"
    local tmp_dir=""
    local shared_lib=""

    tmp_dir=$(mktemp -d) || return 1

    for shared_lib in $REQUIRED_SHARED_LIBS; do
        if ! curl -fsSL --connect-timeout 5 "https://github.com/${fetch_repo}/raw/main/lib/${shared_lib}" -o "$tmp_dir/$shared_lib"; then
            rm -rf "$tmp_dir"
            return 1
        fi
    done

    mkdir -p "$bootstrap_dir" || {
        rm -rf "$tmp_dir"
        return 1
    }
    for shared_lib in $REQUIRED_SHARED_LIBS; do
        if ! install -m 644 "$tmp_dir/$shared_lib" "$bootstrap_dir/$shared_lib"; then
            rm -rf "$tmp_dir"
            return 1
        fi
    done

    rm -rf "$tmp_dir"
    SHARED_LIB_DIR="$bootstrap_dir"
    return 0
}

# For an installed copy, always refresh the shared libraries from the repo so an
# outdated copy can never be sourced (the files are small). Best-effort: if the
# refresh fails (e.g. no network) any existing copy is kept and the presence
# check below still guards against a genuinely missing library.
if [ "$running_from_checkout" = false ]; then
    bootstrap_pg_node_shared_libs || true
fi

for shared_lib in $REQUIRED_SHARED_LIBS; do
    if [ ! -f "$SHARED_LIB_DIR/$shared_lib" ]; then
        printf 'Missing shared library: %s\n' "$SHARED_LIB_DIR/$shared_lib" >&2
        exit 1
    fi
done

# shellcheck source=lib/common.sh
source "$SHARED_LIB_DIR/common.sh"
# shellcheck source=lib/system.sh
source "$SHARED_LIB_DIR/system.sh"
# shellcheck source=lib/docker.sh
source "$SHARED_LIB_DIR/docker.sh"
# shellcheck source=lib/github.sh
source "$SHARED_LIB_DIR/github.sh"

# Validate a user-supplied instance name (--name). The value flows into
# filesystem paths, the systemd unit (body + filename), sed/yq programs and
# the network service's command word, so it must be restricted to a safe
# character set to prevent path traversal and command/directive injection.
validate_app_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]]
}

# Handle global options
AUTO_CONFIRM=false
APP_NAME=""
CUSTOM_NAME_SET=false
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    -y | --yes)
        AUTO_CONFIRM=true
        shift
        ;;
    --name)
        if [[ -z "${2:-}" ]]; then
            echo "Error: --name requires a value." >&2
            exit 1
        fi
        if ! validate_app_name "$2"; then
            echo "Error: invalid --name '$2'. Use 1-63 chars: letters, digits, '_' or '-', starting with a letter or digit." >&2
            exit 1
        fi
        APP_NAME="$2"
        CUSTOM_NAME_SET=true
        shift 2
        ;;
    --name=*)
        APP_NAME="${1#*=}"
        if [[ -z "$APP_NAME" ]]; then
            echo "Error: --name requires a value." >&2
            exit 1
        fi
        if ! validate_app_name "$APP_NAME"; then
            echo "Error: invalid --name '$APP_NAME'. Use 1-63 chars: letters, digits, '_' or '-', starting with a letter or digit." >&2
            exit 1
        fi
        CUSTOM_NAME_SET=true
        shift
        ;;
    *)
        ARGS+=("$1")
        shift
        ;;
    esac
done
set -- "${ARGS[@]}"
COMMAND="${1:-}"
# Fetch IP address from ifconfig.io API
NODE_IP_V4=$(curl -s -4 --fail --max-time 5 ifconfig.io 2>/dev/null || echo "")
NODE_IP_V6=$(curl -s -6 --fail --max-time 5 ifconfig.io 2>/dev/null || echo "")
NODE_IP="${NODE_IP_V4:-}"
if [ -z "$NODE_IP" ]; then
    NODE_IP="${NODE_IP_V6:-}"
fi
if [ -z "$NODE_IP" ]; then
    NODE_IP="127.0.0.1"
fi
if [[ "${1:-}" == "install" || "${1:-}" == "install-script" ]] && [ -z "${APP_NAME:-}" ]; then
    APP_NAME="pg-node"
fi
# Set script name if APP_NAME is not set
if [ -z "${APP_NAME:-}" ]; then
    SCRIPT_NAME=$(basename "$0")
    APP_NAME="${SCRIPT_NAME%.*}"
fi
if [[ "$CUSTOM_NAME_SET" == true && "$COMMAND" =~ ^(install|install-script)$ ]]; then
    if command -v "$APP_NAME" >/dev/null 2>&1; then
        echo "Error: '$APP_NAME' is an existing Linux command. Please choose a different --name." >&2
        exit 1
    fi
fi
INSTALL_DIR="/opt"
if [ -z "${APP_DIR:-}" ]; then
    if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
        APP_DIR="$INSTALL_DIR/$APP_NAME"
    else
        APP_DIR="$INSTALL_DIR/$APP_NAME"
    fi
fi
DATA_DIR="${DATA_DIR:-/var/lib/$APP_NAME}"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
SSL_CERT_FILE="$DATA_DIR/certs/ssl_cert.pem"
SSL_KEY_FILE="$DATA_DIR/certs/ssl_key.pem"
LAST_XRAY_CORES=5
FETCH_REPO="PasarGuard/scripts"
NODE_SERVICE_REPO="PasarGuard/node-serviced"
NODE_SERVICE_RELEASE_API="https://api.github.com/repos/${NODE_SERVICE_REPO}/releases/latest"
NODE_SERVICE_BINARY_NAME="node-serviced"
NODE_SERVICE_BACKUP_PATH=""
NODE_SERVICE_HAD_PREVIOUS=false
NODE_SERVICE_STAGED_PATH=""
NODE_SERVICE_DOWNLOAD_TMP_DIR=""
NODE_SERVICE_UPDATE_LOCK_HELD=false
NODE_SERVICE_TRANSACTION_ACTIVE=false
NODE_SERVICE_TRANSACTION_COMMITTED=false
NODE_SERVICE_TRANSACTION_STATE_CAPTURED=false
NODE_SERVICE_TRANSACTION_MUTATION_STARTED=false
NODE_SERVICE_TRANSACTION_HAD_SERVICE=false
NODE_SERVICE_TRANSACTION_WAS_ACTIVE=false
NODE_SERVICE_TRANSACTION_WAS_ENABLED=false
NODE_SERVICE_EXTERNAL_CHILD_PID=""
NODE_SERVICE_EXTERNAL_CHILD_PGID=""
NODE_SERVICE_EXTERNAL_WATCHDOG_PID=""
NODE_SERVICE_UNIT_LIST_TMP=""
NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT=""
declare -a NODE_SERVICE_TRANSACTION_PATHS=()
declare -a NODE_SERVICE_TRANSACTION_HAD_PATH=()
declare -a NODE_SERVICE_TRANSACTION_BACKUPS=()
declare -a NODE_SERVICE_TRANSACTION_LINK_TARGETS=()
declare -a NODE_SERVICE_TRANSACTION_HAD_LINK_TARGET=()
declare -a NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS=()
declare -a NODE_SERVICE_TRANSACTION_RESTORED=()
set_service_paths() {
    SERVICE_NAME="${APP_NAME}-service"
    SERVICE_BINARY_PATH="/usr/local/bin/${SERVICE_NAME}"
    SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
}
require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        colorized_echo red "systemd is required to manage the service (systemctl not found)."
        exit 1
    fi
}
service_installed() {
    local query_status=0

    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    fi
    set_service_paths
    if [ -f "$SERVICE_UNIT" ]; then
        return 0
    fi
    NODE_SERVICE_UNIT_LIST_TMP=$(create_temp_file "node-service-unit-list" ".txt") || return 2
    if run_node_service_systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend --no-pager \
        >"$NODE_SERVICE_UNIT_LIST_TMP" 2>/dev/null; then
        query_status=0
    else
        query_status=$?
        rm -f "$NODE_SERVICE_UNIT_LIST_TMP"
        NODE_SERVICE_UNIT_LIST_TMP=""
        return "$query_status"
    fi
    if grep -q "^${SERVICE_NAME}.service[[:space:]]" "$NODE_SERVICE_UNIT_LIST_TMP"; then
        query_status=0
    else
        query_status=1
    fi
    rm -f "$NODE_SERVICE_UNIT_LIST_TMP"
    NODE_SERVICE_UNIT_LIST_TMP=""
    return "$query_status"
}
restart_service_if_installed() {
    local service_query_status=0

    if service_installed; then
        :
    else
        service_query_status=$?
        if [ "$service_query_status" -eq 1 ]; then
            return 0
        fi
        colorized_echo red "Failed to inspect $SERVICE_NAME before restarting it."
        return "$service_query_status"
    fi
    if [ "$(id -u)" != "0" ]; then
        colorized_echo yellow "$SERVICE_NAME is installed; run as root to restart it."
        return
    fi
    systemctl restart "$SERVICE_NAME"
    colorized_echo blue "$SERVICE_NAME service restarted."
}

require_node_service_installed() {
    local service_query_status=0

    if service_installed; then
        return 0
    else
        service_query_status=$?
    fi
    if [ "$service_query_status" -eq 1 ]; then
        colorized_echo red "Service not installed. Run service-install first."
    else
        colorized_echo red "Failed to inspect $SERVICE_NAME installation state."
    fi
    return "$service_query_status"
}
update_service_if_installed() (
    local report_missing="${1:-false}"

    set_service_paths
    if [ "$(id -u)" != "0" ]; then
        colorized_echo yellow "$SERVICE_NAME is installed; run as root to update/restart it."
        return
    fi
    if ! acquire_node_serviced_update_lock; then
        return 1
    fi
    # Arm the guard before querying systemd. A wedged systemctl must not hold
    # the mutation lock without bounded cleanup and rollback protection.
    if ! begin_node_service_transaction; then
        colorized_echo red "Failed to snapshot or inspect $SERVICE_NAME before updating it."
        return 1
    fi
    if [ "$NODE_SERVICE_TRANSACTION_HAD_SERVICE" != true ]; then
        commit_node_service_transaction
        if [ "$report_missing" = true ]; then
            colorized_echo red "Service not installed. Run service-install first."
            return 1
        fi
        return
    fi
    if ! install_node_service_script false; then
        abort_node_service_transaction
        return 1
    fi
    if ! run_node_service_systemctl daemon-reload || ! run_node_service_systemctl restart "$SERVICE_NAME" || ! wait_for_node_service_ready; then
        colorized_echo red "$SERVICE_NAME failed to become ready after update; restoring the previous binary."
        if ! abort_node_service_transaction; then
            colorized_echo red "Failed to restore the previous $SERVICE_NAME installation."
        fi
        return 1
    fi
    commit_node_service_transaction
    colorized_echo blue "$SERVICE_NAME service updated and restarted."
)

acquire_node_serviced_update_lock() {
    local target_dir target_name lock_path

    if [ "$NODE_SERVICE_UPDATE_LOCK_HELD" = true ]; then
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        colorized_echo red "flock is required to update $SERVICE_NAME safely."
        return 1
    fi
    target_dir=$(dirname "$SERVICE_BINARY_PATH")
    target_name=$(basename "$SERVICE_BINARY_PATH")
    lock_path="${NODE_SERVICE_UPDATE_LOCK_PATH:-${target_dir}/.${target_name}.update.lock}"
    if ! exec 9>"$lock_path"; then
        colorized_echo red "Failed to open the $SERVICE_NAME update lock at $lock_path."
        return 1
    fi
    if ! flock -n 9; then
        exec 9>&-
        colorized_echo yellow "Another $SERVICE_NAME update is already in progress."
        return 1
    fi
    NODE_SERVICE_UPDATE_LOCK_HELD=true
}

release_node_serviced_update_lock() {
    if [ "$NODE_SERVICE_UPDATE_LOCK_HELD" != true ]; then
        return 0
    fi
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&-
    NODE_SERVICE_UPDATE_LOCK_HELD=false
}

cleanup_node_service_transaction_backups() {
    local backup

    for backup in "${NODE_SERVICE_TRANSACTION_BACKUPS[@]}" "${NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS[@]}"; do
        [ -z "$backup" ] || rm -f "$backup"
    done
    NODE_SERVICE_TRANSACTION_PATHS=()
    NODE_SERVICE_TRANSACTION_HAD_PATH=()
    NODE_SERVICE_TRANSACTION_BACKUPS=()
    NODE_SERVICE_TRANSACTION_LINK_TARGETS=()
    NODE_SERVICE_TRANSACTION_HAD_LINK_TARGET=()
    NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS=()
    NODE_SERVICE_TRANSACTION_RESTORED=()
}

cleanup_node_serviced_temporary_files() {
    [ -z "$NODE_SERVICE_STAGED_PATH" ] || rm -f "$NODE_SERVICE_STAGED_PATH"
    [ -z "$NODE_SERVICE_DOWNLOAD_TMP_DIR" ] || rm -rf "$NODE_SERVICE_DOWNLOAD_TMP_DIR"
    [ -z "$NODE_SERVICE_UNIT_LIST_TMP" ] || rm -f "$NODE_SERVICE_UNIT_LIST_TMP"
    NODE_SERVICE_STAGED_PATH=""
    NODE_SERVICE_DOWNLOAD_TMP_DIR=""
    NODE_SERVICE_UNIT_LIST_TMP=""
}

signal_node_service_process() {
    local signal="$1"
    local child_pid="$2"
    local child_pgid="$3"

    if [ -n "$child_pgid" ]; then
        kill -"$signal" -- "-$child_pgid" >/dev/null 2>&1 || true
    elif [ -n "$child_pid" ]; then
        kill -"$signal" "$child_pid" >/dev/null 2>&1 || true
    fi
}

terminate_node_service_external_child() {
    local child_pid="$NODE_SERVICE_EXTERNAL_CHILD_PID"
    local child_pgid="$NODE_SERVICE_EXTERNAL_CHILD_PGID"
    local watchdog_pid="$NODE_SERVICE_EXTERNAL_WATCHDOG_PID"
    local attempt=0

    NODE_SERVICE_EXTERNAL_CHILD_PID=""
    NODE_SERVICE_EXTERNAL_CHILD_PGID=""
    NODE_SERVICE_EXTERNAL_WATCHDOG_PID=""
    [ -z "$watchdog_pid" ] || kill -KILL "$watchdog_pid" >/dev/null 2>&1 || true
    if [ -n "$child_pid" ] && kill -0 "$child_pid" >/dev/null 2>&1; then
        signal_node_service_process TERM "$child_pid" "$child_pgid"
        while kill -0 "$child_pid" >/dev/null 2>&1 && [ "$attempt" -lt 20 ]; do
            sleep 0.05
            attempt=$((attempt + 1))
        done
        if kill -0 "$child_pid" >/dev/null 2>&1; then
            signal_node_service_process KILL "$child_pid" "$child_pgid"
        fi
        wait "$child_pid" >/dev/null 2>&1 || true
    fi
    [ -z "$watchdog_pid" ] || wait "$watchdog_pid" >/dev/null 2>&1 || true
}

run_node_service_external() {
    local timeout_seconds="$1"
    shift
    local child_pid child_pgid="" watchdog_pid status

    # Unit tests replace external programs with shell functions. Keep those
    # synchronous; production commands use a separate process group below.
    if declare -F "${1:-}" >/dev/null 2>&1; then
        local function_status=0
        "$@" || function_status=$?
        return "$function_status"
    fi
    if ! [[ "$timeout_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        colorized_echo red "Invalid node service external-command timeout: $timeout_seconds"
        return 1
    fi
    if ! command -v setsid >/dev/null 2>&1; then
        colorized_echo red "setsid is required to supervise $1 safely."
        return 1
    fi
    setsid --wait bash -c 'trap - INT TERM; exec "$@"' bash "$@" &
    child_pid=$!
    child_pgid="$child_pid"
    NODE_SERVICE_EXTERNAL_CHILD_PID="$child_pid"
    NODE_SERVICE_EXTERNAL_CHILD_PGID="$child_pgid"
    (
        trap - INT TERM
        sleep "$timeout_seconds"
        if kill -0 "$child_pid" >/dev/null 2>&1; then
            signal_node_service_process TERM "$child_pid" "$child_pgid"
            sleep "${NODE_SERVICE_EXTERNAL_KILL_AFTER_SECONDS:-2}"
            if kill -0 "$child_pid" >/dev/null 2>&1; then
                signal_node_service_process KILL "$child_pid" "$child_pgid"
            fi
        fi
    ) &
    watchdog_pid=$!
    NODE_SERVICE_EXTERNAL_WATCHDOG_PID="$watchdog_pid"
    if wait "$child_pid"; then
        status=0
    else
        status=$?
    fi
    NODE_SERVICE_EXTERNAL_CHILD_PID=""
    NODE_SERVICE_EXTERNAL_CHILD_PGID=""
    NODE_SERVICE_EXTERNAL_WATCHDOG_PID=""
    kill -KILL "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
    return "$status"
}

run_node_service_systemctl() {
    run_node_service_external "${NODE_SERVICE_SYSTEMCTL_TIMEOUT_SECONDS:-30}" systemctl "$@"
}

snapshot_node_service_path() {
    local source_path="$1"
    local index="${#NODE_SERVICE_TRANSACTION_PATHS[@]}"
    local source_dir source_name backup_path link_target="" link_target_backup=""
    local had_path=false had_link_target=false

    source_dir=$(dirname "$source_path")
    source_name=$(basename "$source_path")
    backup_path="${source_dir}/.${source_name}.transaction.$$.$RANDOM"
    if [ -e "$source_path" ] || [ -L "$source_path" ]; then
        had_path=true
        NODE_SERVICE_TRANSACTION_PATHS[index]="$source_path"
        NODE_SERVICE_TRANSACTION_HAD_PATH[index]="$had_path"
        NODE_SERVICE_TRANSACTION_BACKUPS[index]="$backup_path"
        NODE_SERVICE_TRANSACTION_LINK_TARGETS[index]=""
        NODE_SERVICE_TRANSACTION_HAD_LINK_TARGET[index]=false
        NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS[index]=""
        NODE_SERVICE_TRANSACTION_RESTORED[index]=false
        cp -a "$source_path" "$backup_path" || return 1
        if [ -L "$source_path" ]; then
            link_target=$(readlink -f "$source_path" 2>/dev/null || true)
            if [ -n "$link_target" ] && { [ -e "$link_target" ] || [ -L "$link_target" ]; }; then
                had_link_target=true
                link_target_backup="$(dirname "$link_target")/.$(basename "$link_target").transaction-target.$$.$RANDOM"
                NODE_SERVICE_TRANSACTION_LINK_TARGETS[index]="$link_target"
                NODE_SERVICE_TRANSACTION_HAD_LINK_TARGET[index]="$had_link_target"
                NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS[index]="$link_target_backup"
                cp -a "$link_target" "$link_target_backup" || return 1
            fi
        fi
    else
        backup_path=""
        NODE_SERVICE_TRANSACTION_PATHS[index]="$source_path"
        NODE_SERVICE_TRANSACTION_HAD_PATH[index]="$had_path"
        NODE_SERVICE_TRANSACTION_BACKUPS[index]=""
        NODE_SERVICE_TRANSACTION_LINK_TARGETS[index]=""
        NODE_SERVICE_TRANSACTION_HAD_LINK_TARGET[index]=false
        NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS[index]=""
        NODE_SERVICE_TRANSACTION_RESTORED[index]=false
    fi
}

restore_node_service_backup_copy() {
    local backup="$1"
    local destination="$2"
    local destination_dir destination_name restore_path

    destination_dir=$(dirname "$destination")
    destination_name=$(basename "$destination")
    restore_path=$(create_temp_file_in_dir "$destination_dir" ".${destination_name}.restore" "") || return 1
    rm -f "$restore_path" || return 1
    if ! cp -a "$backup" "$restore_path" || ! mv -f "$restore_path" "$destination"; then
        rm -f "$restore_path"
        return 1
    fi
}

restore_node_service_snapshot_entry() {
    local index="$1"
    local path="${NODE_SERVICE_TRANSACTION_PATHS[index]}"
    local backup="${NODE_SERVICE_TRANSACTION_BACKUPS[index]}"
    local link_target="${NODE_SERVICE_TRANSACTION_LINK_TARGETS[index]}"
    local link_target_backup="${NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS[index]}"

    [ "${NODE_SERVICE_TRANSACTION_RESTORED[index]}" != true ] || return 0
    if [ "${NODE_SERVICE_TRANSACTION_HAD_LINK_TARGET[index]}" = true ] && [ -n "$link_target_backup" ]; then
        # Keep the snapshot until the complete rollback, including restoration
        # of systemd state, has succeeded. A later systemctl failure otherwise
        # leaves an orphaned first-install unit with no recovery copy.
        if ! restore_node_service_backup_copy "$link_target_backup" "$link_target"; then
            return 1
        fi
    fi
    if [ "${NODE_SERVICE_TRANSACTION_HAD_PATH[index]}" = true ]; then
        if [ -z "$backup" ] || ! restore_node_service_backup_copy "$backup" "$path"; then
            return 1
        fi
    elif ! rm -f "$path"; then
        return 1
    fi
    NODE_SERVICE_TRANSACTION_RESTORED[index]=true
}

rollback_node_service_transaction() {
    local restore_failed=false index

    if [ "$NODE_SERVICE_TRANSACTION_MUTATION_STARTED" != true ]; then
        return 0
    fi
    for ((index = ${#NODE_SERVICE_TRANSACTION_PATHS[@]} - 1; index >= 0; index--)); do
        restore_node_service_snapshot_entry "$index" || restore_failed=true
    done
    discard_node_serviced_backup

    if ! run_node_service_systemctl daemon-reload; then
        restore_failed=true
    fi
    if [ "$NODE_SERVICE_TRANSACTION_HAD_SERVICE" = true ]; then
        if [ "$NODE_SERVICE_TRANSACTION_WAS_ENABLED" = true ]; then
            run_node_service_systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || restore_failed=true
        else
            run_node_service_systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || restore_failed=true
        fi
        if [ "$NODE_SERVICE_TRANSACTION_WAS_ACTIVE" = true ]; then
            if ! run_node_service_systemctl restart "$SERVICE_NAME" || ! wait_for_node_service_ready; then
                restore_failed=true
            fi
        else
            run_node_service_systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || restore_failed=true
        fi
    else
        if ! run_node_service_systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1; then
            colorized_echo red "Failed to disable the newly created $SERVICE_NAME unit; it may remain loaded or active."
            restore_failed=true
        fi
    fi
    [ "$restore_failed" = false ]
}

finish_node_service_transaction() {
    local preserve_backups="${1:-false}"

    trap - EXIT
    trap '' INT TERM
    if [ "$preserve_backups" != true ]; then
        cleanup_node_service_transaction_backups
    fi
    cleanup_node_serviced_temporary_files
    discard_node_serviced_backup
    NODE_SERVICE_TRANSACTION_ACTIVE=false
    NODE_SERVICE_TRANSACTION_COMMITTED=false
    if [ "$preserve_backups" != true ]; then
        NODE_SERVICE_TRANSACTION_MUTATION_STARTED=false
    fi
    release_node_serviced_update_lock
    trap - INT TERM
}

report_retained_node_service_backups() {
    local backup

    for backup in "${NODE_SERVICE_TRANSACTION_BACKUPS[@]}" "${NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS[@]}"; do
        [ -z "$backup" ] || colorized_echo red "Retained transaction backup: $backup"
    done
}

node_service_transaction_guard() {
    local event="$1"
    local status="$2"
    local signal_status=0

    local rollback_failed=false

    trap - EXIT
    trap '' INT TERM
    terminate_node_service_external_child
    if [ "$NODE_SERVICE_TRANSACTION_ACTIVE" = true ] && [ "$NODE_SERVICE_TRANSACTION_COMMITTED" != true ]; then
        rollback_node_service_transaction || {
            rollback_failed=true
            colorized_echo red "Failed to fully restore the interrupted $SERVICE_NAME transaction."
        }
    fi
    if [ "$rollback_failed" != true ]; then
        cleanup_node_service_transaction_backups
    else
        colorized_echo red "Transaction backups were retained for manual recovery."
        report_retained_node_service_backups
    fi
    cleanup_node_serviced_temporary_files
    discard_node_serviced_backup
    NODE_SERVICE_TRANSACTION_ACTIVE=false
    if [ "$rollback_failed" != true ]; then
        NODE_SERVICE_TRANSACTION_MUTATION_STARTED=false
    fi
    release_node_serviced_update_lock

    case "$event" in
    INT) signal_status=130 ;;
    TERM) signal_status=143 ;;
    EXIT) return "$status" ;;
    esac
    exit "$signal_status"
}

begin_node_service_transaction() {
    local service_query_status=0 state_query_status=0

    NODE_SERVICE_TRANSACTION_ACTIVE=true
    NODE_SERVICE_TRANSACTION_COMMITTED=false
    NODE_SERVICE_TRANSACTION_STATE_CAPTURED=false
    NODE_SERVICE_TRANSACTION_MUTATION_STARTED=false
    NODE_SERVICE_TRANSACTION_HAD_SERVICE=false
    NODE_SERVICE_TRANSACTION_WAS_ACTIVE=false
    NODE_SERVICE_TRANSACTION_WAS_ENABLED=false
    NODE_SERVICE_TRANSACTION_PATHS=()
    NODE_SERVICE_TRANSACTION_HAD_PATH=()
    NODE_SERVICE_TRANSACTION_BACKUPS=()
    NODE_SERVICE_TRANSACTION_LINK_TARGETS=()
    NODE_SERVICE_TRANSACTION_HAD_LINK_TARGET=()
    NODE_SERVICE_TRANSACTION_LINK_TARGET_BACKUPS=()
    NODE_SERVICE_TRANSACTION_RESTORED=()
    trap 'node_service_transaction_guard EXIT "$?"' EXIT
    trap 'node_service_transaction_guard INT "$?"' INT
    trap 'node_service_transaction_guard TERM "$?"' TERM

    snapshot_node_service_path "$ENV_FILE" || return 1
    snapshot_node_service_path "$SERVICE_UNIT" || return 1
    snapshot_node_service_path "$SERVICE_BINARY_PATH" || return 1
    if service_installed; then
        NODE_SERVICE_TRANSACTION_HAD_SERVICE=true
    else
        service_query_status=$?
        [ "$service_query_status" -eq 1 ] || return "$service_query_status"
    fi
    if [ "$NODE_SERVICE_TRANSACTION_HAD_SERVICE" = true ]; then
        if run_node_service_systemctl is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1; then
            NODE_SERVICE_TRANSACTION_WAS_ACTIVE=true
        else
            state_query_status=$?
            # systemctl documents 3 as the normal inactive result. Any other
            # status is an unknown/failed query and must not arm rollback.
            [ "$state_query_status" -eq 3 ] || return "$state_query_status"
        fi
        if run_node_service_systemctl is-enabled --quiet "$SERVICE_NAME" >/dev/null 2>&1; then
            NODE_SERVICE_TRANSACTION_WAS_ENABLED=true
        else
            state_query_status=$?
            # A known disabled unit returns 1. Timeouts, signals, and other
            # inspection failures remain fatal before any mutation starts.
            [ "$state_query_status" -eq 1 ] || return "$state_query_status"
        fi
    fi
    NODE_SERVICE_TRANSACTION_STATE_CAPTURED=true
}

mark_node_service_transaction_mutation_started() {
    if [ "$NODE_SERVICE_TRANSACTION_ACTIVE" != true ]; then
        return 0
    fi
    [ "$NODE_SERVICE_TRANSACTION_STATE_CAPTURED" = true ] || return 1
    NODE_SERVICE_TRANSACTION_MUTATION_STARTED=true
}

abort_node_service_transaction() {
    local status=0

    trap - EXIT
    trap '' INT TERM
    rollback_node_service_transaction || status=1
    if [ "$status" -ne 0 ]; then
        colorized_echo red "Transaction backups were retained for retry or manual recovery."
        report_retained_node_service_backups
        finish_node_service_transaction true
    else
        finish_node_service_transaction false
    fi
    return "$status"
}

commit_node_service_transaction() {
    NODE_SERVICE_TRANSACTION_COMMITTED=true
    finish_node_service_transaction
}

wait_for_node_service_ready() {
    local max_attempts="${NODE_SERVICE_READINESS_ATTEMPTS:-10}"
    local stable_required="${NODE_SERVICE_READINESS_STABLE_CHECKS:-3}"
    local delay_seconds="${NODE_SERVICE_READINESS_DELAY_SECONDS:-1}"
    local attempt=0 stable=0

    while [ "$attempt" -lt "$max_attempts" ]; do
        if run_node_service_systemctl is-active --quiet "$SERVICE_NAME" && node_service_api_ready; then
            stable=$((stable + 1))
            if [ "$stable" -ge "$stable_required" ]; then
                return 0
            fi
        else
            stable=0
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep "$delay_seconds"
        fi
    done
    return 1
}

read_node_service_env_value() {
    local key="$1"

    [ -r "$ENV_FILE" ] || return 1
    # node-serviced uses godotenv.Overload. Parse only data (never source/eval)
    # while matching the relevant godotenv rules: export, last duplicate wins,
    # comments, single/double quotes, double-quote escapes and prior-key
    # expansion. This keeps readiness pointed at the configuration the daemon
    # actually loaded.
    awk -v wanted="$key" '
        function ltrim(value) { sub(/^[ \t\v\f\r]+/, "", value); return value }
        function rtrim(value) { sub(/[ \t\v\f\r]+$/, "", value); return value }
        function expand_vars(value,    out, i, j, c, name, braced) {
            out = ""
            for (i = 1; i <= length(value); i++) {
                c = substr(value, i, 1)
                if (c == "\\" && substr(value, i + 1, 1) == "$") {
                    out = out "$"
                    i++
                    continue
                }
                if (c != "$") {
                    out = out c
                    continue
                }
                j = i + 1
                braced = substr(value, j, 1) == "{"
                if (braced) j++
                name = ""
                while (j <= length(value) && substr(value, j, 1) ~ /[A-Z0-9_]/) {
                    name = name substr(value, j, 1)
                    j++
                }
                if (name == "") {
                    out = out c
                    continue
                }
                if (braced && substr(value, j, 1) == "}") j++
                out = out vars[name]
                i = j - 1
            }
            return out
        }
        function decode_double(value,    out, i, c, nextc) {
            out = ""
            for (i = 1; i <= length(value); i++) {
                c = substr(value, i, 1)
                if (c != "\\" || i == length(value)) {
                    out = out c
                    continue
                }
                nextc = substr(value, i + 1, 1)
                if (nextc == "n") out = out "\n"
                else if (nextc == "r") out = out "\r"
                else if (nextc == "$") out = out "\\$"
                else out = out nextc
                i++
            }
            return expand_vars(out)
        }
        {
            line = $0
            sub(/\r$/, "", line)
            line = ltrim(line)
            if (line == "" || substr(line, 1, 1) == "#") next
            if (line ~ /^export[ \t\v\f\r]/) {
                sub(/^export[ \t\v\f\r]+/, "", line)
            }
            delimiter = match(line, /[=:]/)
            if (!delimiter) { parse_error = 1; next }
            name = rtrim(substr(line, 1, delimiter - 1))
            if (name !~ /^[A-Za-z0-9_.]+$/) { parse_error = 1; next }
            value = ltrim(substr(line, delimiter + 1))
            quote = substr(value, 1, 1)
            if (quote == "\"" || quote == "\047") {
                closing = 0
                for (i = 2; i <= length(value); i++) {
                    if (substr(value, i, 1) == quote && substr(value, i - 1, 1) != "\\") {
                        closing = i
                        break
                    }
                }
                if (!closing) { parse_error = 1; next }
                remainder = ltrim(substr(value, closing + 1))
                if (remainder != "" && substr(remainder, 1, 1) != "#") {
                    parse_error = 1
                    next
                }
                value = substr(value, 2, closing - 2)
                if (quote == "\"") value = decode_double(value)
            } else {
                comment = 0
                for (i = 2; i <= length(value); i++) {
                    if (substr(value, i, 1) == "#" && substr(value, i - 1, 1) ~ /[ \t\v\f\r]/) {
                        comment = i
                        break
                    }
                }
                if (comment) value = substr(value, 1, comment - 1)
                value = expand_vars(rtrim(value))
            }
            vars[name] = value
        }
        END {
            if (parse_error || !(wanted in vars)) exit 1
            printf "%s", vars[wanted]
        }
    ' "$ENV_FILE"
}

node_service_certificate_identity() {
    local ssl_cert="$1"
    local cert_output cn_output="" token dns_identity="" wildcard_identity="" ip_identity="" san_present=false
    local wildcard_suffix subject

    NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT=""
    cert_output=$(create_temp_file "node-service-cert" ".txt") || return 1
    if ! run_node_service_external "${NODE_SERVICE_OPENSSL_TIMEOUT_SECONDS:-5}" \
        openssl x509 -in "$ssl_cert" -noout -ext subjectAltName >"$cert_output" 2>/dev/null; then
        rm -f "$cert_output"
        return 1
    fi
    while IFS= read -r token; do
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        case "$token" in
        *"Subject Alternative Name:"*)
            san_present=true
            ;;
        DNS:*)
            token="${token#DNS:}"
            if [ -z "$dns_identity" ] && [[ "$token" != *'*'* ]] &&
                [[ "$token" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
                dns_identity="$token"
            elif [ -z "$wildcard_identity" ] && [[ "$token" == \*.* ]]; then
                wildcard_suffix="${token#*.}"
                if [[ "$wildcard_suffix" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
                    # A fixed single label is covered by a left-most wildcard
                    # and avoids DNS while retaining valid SNI/Host identity.
                    wildcard_identity="node-serviced-health.${wildcard_suffix}"
                fi
            fi
            ;;
        "IP Address:"*)
            token="${token#IP Address:}"
            if [ -z "$ip_identity" ] && is_ip_address "$token"; then
                ip_identity="$token"
            fi
            ;;
        esac
    done < <(tr ',' '\n' <"$cert_output")
    rm -f "$cert_output"
    if [ -n "$dns_identity" ]; then
        NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT="$dns_identity"
    elif [ -n "$wildcard_identity" ]; then
        NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT="$wildcard_identity"
    elif [ -n "$ip_identity" ]; then
        NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT="$ip_identity"
    elif [ "$san_present" = true ]; then
        return 1
    else
        # Preserve compatibility with legacy SAN-less certificates. CN is
        # considered only when the SAN extension is absent, matching TLS name
        # verification precedence.
        cn_output=$(create_temp_file "node-service-cert-cn" ".txt") || return 1
        if ! run_node_service_external "${NODE_SERVICE_OPENSSL_TIMEOUT_SECONDS:-5}" \
            openssl x509 -in "$ssl_cert" -noout -subject -nameopt RFC2253 >"$cn_output" 2>/dev/null; then
            rm -f "$cn_output"
            return 1
        fi
        subject=$(<"$cn_output")
        rm -f "$cn_output"
        subject="${subject#subject=}"
        subject="${subject#subject =}"
        while IFS= read -r token; do
            token="${token#CN=}"
            if [[ "$token" == \*.* ]]; then
                wildcard_suffix="${token#*.}"
                if [[ "$wildcard_suffix" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
                    NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT="node-serviced-health.${wildcard_suffix}"
                    return 0
                fi
            elif [[ "$token" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
                NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT="$token"
                return 0
            fi
        done < <(printf '%s\n' "$subject" | tr ',' '\n' | grep '^CN=')
        return 1
    fi
}

node_service_api_ready() {
    local api_port api_key ssl_cert tls_identity url_host curl_config curl_status

    api_port=$(read_node_service_env_value API_PORT)
    api_key=$(read_node_service_env_value API_KEY)
    ssl_cert=$(read_node_service_env_value SSL_CERT_FILE)
    # Match node-serviced's own default when an older environment omits
    # API_PORT. New installations still write the script-selected port.
    api_port="${api_port:-3000}"
    ssl_cert="${ssl_cert:-$SSL_CERT_FILE}"

    if ! [[ "$api_port" =~ ^[0-9]+$ && "$api_port" -ge 1 && "$api_port" -le 65535 ]] ||
        [ -z "$api_key" ] || [[ "$api_key" == *$'\n'* || "$api_key" == *$'\r'* ]] ||
        [ ! -r "$ssl_cert" ]; then
        colorized_echo red "$SERVICE_NAME readiness configuration is incomplete in $ENV_FILE."
        return 1
    fi
    if ! node_service_certificate_identity "$ssl_cert"; then
        colorized_echo red "$SERVICE_NAME certificate has no usable DNS/IP certificate identity."
        return 1
    fi
    tls_identity="$NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT"
    url_host="$tls_identity"
    if [[ "$url_host" == *:* ]]; then
        url_host="[$url_host]"
    fi

    # Keep the API key out of the process argument list. The temporary curl
    # configuration is owner-readable only and is removed after the probe.
    curl_config=$(create_temp_file "node-service-readiness" ".curl") || return 1
    harden_secret_file "$curl_config" || {
        rm -f "$curl_config"
        return 1
    }
    if ! {
        printf 'silent\nshow-error\nfail\n'
        printf 'noproxy = "*"\n'
        printf 'max-time = "%s"\n' "${NODE_SERVICE_READINESS_TIMEOUT_SECONDS:-5}"
        printf 'connect-timeout = "%s"\n' "${NODE_SERVICE_READINESS_CONNECT_TIMEOUT_SECONDS:-2}"
        printf 'cacert = "%s"\n' "$(printf '%s' "$ssl_cert" | sed 's/[\\"]/\\&/g')"
        printf 'header = "x-api-key: %s"\n' "$(printf '%s' "$api_key" | sed 's/[\\"]/\\&/g')"
        # Preserve the certificate identity for TLS SNI and the HTTP Host
        # header while forcing the TCP connection to the local service. Unlike
        # DNS resolution, connect-to is deterministic during recovery.
        # This curl invocation has exactly one URL, so wildcard source fields
        # avoid IPv6 host-matching ambiguity while still changing only the TCP
        # destination. TLS verification and HTTP Host continue to use the URL.
        printf 'connect-to = "::127.0.0.1:%s"\n' "$api_port"
        printf 'url = "https://%s:%s/"\n' "$url_host" "$api_port"
    } >"$curl_config"; then
        rm -f "$curl_config"
        return 1
    fi
    run_node_service_external "${NODE_SERVICE_READINESS_TIMEOUT_SECONDS:-5}" curl --config "$curl_config" >/dev/null
    curl_status=$?
    rm -f "$curl_config"
    return "$curl_status"
}
detect_node_serviced_platform() {
    local arch os platform
    os=$(uname -s 2>/dev/null || echo "")
    if [ "$os" != "Linux" ]; then
        colorized_echo red "Unsupported OS for node-serviced: $os"
        exit 1
    fi
    arch=$(uname -m 2>/dev/null || echo "")
    case "$arch" in
    x86_64 | amd64)
        platform="Linux_x86_64"
        ;;
    aarch64 | arm64 | armv8* )
        platform="Linux_arm64"
        ;;
    armv7l | armv7)
        platform="Linux_armv7"
        ;;
    armv6l | armv6)
        platform="Linux_armv6"
        ;;
    *)
        colorized_echo red "Unsupported architecture for node-serviced: $arch"
        exit 1
        ;;
    esac
    echo "$platform"
}
configure_firewall_for_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local hint="If a firewall is enabled (e.g., UFW or firewalld), allow ${port}/${proto}."
    colorized_echo yellow "$hint"
}
install_node_script() {
    print_script_execution_header "pg-node" "$SCRIPT_COMMIT_SHA" "install"
    colorized_echo blue "Installing node script"
    TARGET_PATH="/usr/local/bin/$APP_NAME"
    TEMP_FILE=$(create_temp_file "pg-node-script" ".sh")
    
    # Download script to temp file first
    colorized_echo cyan "  Downloading script from GitHub..."
    if ! github_download_file "$(github_raw_url "$FETCH_REPO" "pg-node.sh")" "$TEMP_FILE"; then
        colorized_echo red "✗ Failed to download script from $(github_raw_url "$FETCH_REPO" "pg-node.sh")"
        rm -f "$TEMP_FILE"
        exit 1
    fi
    
    # Replace APP_NAME in the script - the script has APP_NAME="" on line 5
    # We need to set it to the current APP_NAME value
    if grep -q "^APP_NAME=" "$TEMP_FILE"; then
        sed -i "s|^APP_NAME=.*|APP_NAME=\"$APP_NAME\"|" "$TEMP_FILE"
    fi

    install_shared_libs_from_repo "$FETCH_REPO" common.sh system.sh docker.sh github.sh
    
    # Remove old file if it exists
    if [ -f "$TARGET_PATH" ]; then
        colorized_echo cyan "  Replacing existing script at $TARGET_PATH..."
        rm -f "$TARGET_PATH"
    fi
    
    # Move temp file to target location
    mv "$TEMP_FILE" "$TARGET_PATH"
    chmod 755 "$TARGET_PATH"
    
    # Verify the installation
    if [ -f "$TARGET_PATH" ] && [ -x "$TARGET_PATH" ]; then
        colorized_echo green "✓ node script installed successfully at $TARGET_PATH"
    else
        colorized_echo red "✗ Failed to install script - file may not be executable"
        exit 1
    fi
}
verify_node_serviced_binary() {
    local binary_path="$1"
    local magic=""

    if [ -L "$binary_path" ] || [ ! -f "$binary_path" ] || [ ! -s "$binary_path" ]; then
        return 1
    fi
    chmod 755 "$binary_path" || return 1
    [ -x "$binary_path" ] || return 1

    # node-serviced releases are Linux ELF executables. Checking the magic
    # catches HTML/error bodies and truncated/otherwise invalid extracted files
    # even when their executable bit is set.
    magic=$(LC_ALL=C od -An -tx1 -N4 "$binary_path" 2>/dev/null | tr -d ' \n')
    [ "$magic" = "7f454c46" ]
}

verify_node_serviced_checksum() {
    local checksum_url="$1"
    local asset_name="$2"
    local archive_path="$3"
    local tmp_dir="$4"
    local checksum_path expected actual

    if [ -z "$checksum_url" ] || [ "$checksum_url" = "null" ]; then
        case "${NODE_SERVICE_REQUIRE_CHECKSUM:-true}" in
        false | 0 | no)
            colorized_echo yellow "No checksums.txt asset is available; continuing because checksum verification was explicitly disabled."
            return 0
            ;;
        *)
            colorized_echo red "No checksums.txt asset is available and checksum verification is required."
            return 1
            ;;
        esac
    fi

    checksum_path="${tmp_dir}/checksums.txt"
    if ! run_node_service_external "${NODE_SERVICE_DOWNLOAD_TIMEOUT_SECONDS:-120}" \
        curl -fL --connect-timeout 10 --max-time 90 --retry 3 --retry-delay 1 "$checksum_url" -o "$checksum_path"; then
        colorized_echo red "Failed to download node-serviced checksums from $checksum_url"
        return 1
    fi
    expected=$(awk -v name="$asset_name" '$2 == name || $2 == "*" name { print $1; exit }' "$checksum_path")
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        colorized_echo red "No valid SHA-256 checksum found for $asset_name"
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$archive_path" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$archive_path" | awk '{print $1}')
    else
        colorized_echo red "SHA-256 verification is required, but sha256sum/shasum is unavailable."
        return 1
    fi
    if [ "${actual,,}" != "${expected,,}" ]; then
        colorized_echo red "SHA-256 checksum mismatch for $asset_name"
        return 1
    fi
}

activate_node_serviced_binary() {
    local candidate_path="$1"
    local keep_backup="${2:-false}"
    local target_dir target_name staged_path backup_path

    target_dir=$(dirname "$SERVICE_BINARY_PATH")
    target_name=$(basename "$SERVICE_BINARY_PATH")
    staged_path=$(create_temp_file_in_dir "$target_dir" ".${target_name}.new" "")
    NODE_SERVICE_STAGED_PATH="$staged_path"
    backup_path="${target_dir}/.${target_name}.backup.$$.$RANDOM"
    NODE_SERVICE_BACKUP_PATH=""
    NODE_SERVICE_HAD_PREVIOUS=false

    if ! install -m 755 "$candidate_path" "$staged_path" || ! verify_node_serviced_binary "$staged_path"; then
        rm -f "$staged_path"
        NODE_SERVICE_STAGED_PATH=""
        return 1
    fi
    if [ -e "$SERVICE_BINARY_PATH" ] || [ -L "$SERVICE_BINARY_PATH" ]; then
        if ! cp -a "$SERVICE_BINARY_PATH" "$backup_path"; then
            rm -f "$staged_path"
            NODE_SERVICE_STAGED_PATH=""
            return 1
        fi
        NODE_SERVICE_BACKUP_PATH="$backup_path"
        NODE_SERVICE_HAD_PREVIOUS=true
    fi
    if ! mark_node_service_transaction_mutation_started; then
        rm -f "$NODE_SERVICE_BACKUP_PATH" "$staged_path"
        NODE_SERVICE_BACKUP_PATH=""
        NODE_SERVICE_HAD_PREVIOUS=false
        NODE_SERVICE_STAGED_PATH=""
        return 1
    fi
    if ! mv "$staged_path" "$SERVICE_BINARY_PATH"; then
        rm -f "$NODE_SERVICE_BACKUP_PATH"
        NODE_SERVICE_BACKUP_PATH=""
        NODE_SERVICE_HAD_PREVIOUS=false
        rm -f "$staged_path"
        NODE_SERVICE_STAGED_PATH=""
        return 1
    fi
    NODE_SERVICE_STAGED_PATH=""
    if [ "$keep_backup" != true ]; then
        discard_node_serviced_backup
    fi
}

rollback_node_serviced_binary() {
    local service_label="${SERVICE_NAME:-node-serviced}"

    if [ "$NODE_SERVICE_HAD_PREVIOUS" = true ] && [ -n "$NODE_SERVICE_BACKUP_PATH" ]; then
        # Both files are in the target directory, so this restores the backup
        # with one atomic rename over the failed replacement.
        mv -f "$NODE_SERVICE_BACKUP_PATH" "$SERVICE_BINARY_PATH" || return 1
    else
        colorized_echo yellow "No previous $service_label binary is available; removing the failed replacement."
        rm -f "$SERVICE_BINARY_PATH" || return 1
    fi
    NODE_SERVICE_BACKUP_PATH=""
    NODE_SERVICE_HAD_PREVIOUS=false
}

discard_node_serviced_backup() {
    if [ -n "$NODE_SERVICE_BACKUP_PATH" ]; then
        rm -f "$NODE_SERVICE_BACKUP_PATH"
    fi
    NODE_SERVICE_BACKUP_PATH=""
    NODE_SERVICE_HAD_PREVIOUS=false
}

install_node_service_script() {
    local keep_backup="${1:-false}"
    set_service_paths
    local platform release_json release_json_path latest_tag latest_version asset_name asset_url checksum_url tmp_dir archive_path binary_path
    tmp_dir=$(create_temp_dir "node-serviced") || {
        colorized_echo red "Failed to create a temporary directory for the node-serviced release."
        return 1
    }
    NODE_SERVICE_DOWNLOAD_TMP_DIR="$tmp_dir"
    if ! command -v jq >/dev/null 2>&1; then
        detect_os
        install_package jq
    fi
    colorized_echo blue "Installing node-serviced binary"
    platform=$(detect_node_serviced_platform)
    release_json_path="${tmp_dir}/release.json"
    if ! run_node_service_external "${NODE_SERVICE_DOWNLOAD_TIMEOUT_SECONDS:-120}" \
        curl -fsSL --connect-timeout 10 --max-time 90 --retry 3 --retry-delay 1 \
        "$NODE_SERVICE_RELEASE_API" -o "$release_json_path"; then
        colorized_echo red "Failed to query latest node-serviced release from $NODE_SERVICE_RELEASE_API"
        return 1
    fi
    release_json=$(<"$release_json_path")
    latest_tag=$(echo "$release_json" | jq -r '.tag_name // empty')
    latest_version="${latest_tag#v}"
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        colorized_echo red "Failed to resolve latest node-serviced version from $NODE_SERVICE_RELEASE_API"
        return 1
    fi
    asset_name="${NODE_SERVICE_BINARY_NAME}_${latest_version}_${platform}.tar.gz"
    asset_url=$(echo "$release_json" | jq -r --arg name "$asset_name" '.assets[]? | select(.name==$name) | .browser_download_url' | head -n 1)
    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        colorized_echo red "node-serviced asset not found for platform $platform (expected $asset_name)"
        return 1
    fi
    checksum_url=$(echo "$release_json" | jq -r '.assets[]? | select(.name=="checksums.txt") | .browser_download_url' | head -n 1)
    archive_path="${tmp_dir}/${asset_name}"
    colorized_echo cyan "  Downloading ${asset_name}..."
    if ! run_node_service_external "${NODE_SERVICE_DOWNLOAD_TIMEOUT_SECONDS:-120}" \
        curl -fL --connect-timeout 10 --max-time 90 --retry 3 --retry-delay 1 "$asset_url" -o "$archive_path"; then
        colorized_echo red "Failed to download node-serviced from $asset_url"
        rm -rf "$tmp_dir"
        return 1
    fi
    if [ ! -f "$archive_path" ] || [ ! -s "$archive_path" ]; then
        colorized_echo red "Downloaded node-serviced archive is empty or not a regular file."
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! verify_node_serviced_checksum "$checksum_url" "$asset_name" "$archive_path" "$tmp_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    colorized_echo cyan "  Extracting node-serviced..."
    if ! run_node_service_external "${NODE_SERVICE_EXTRACT_TIMEOUT_SECONDS:-30}" \
        tar -xzf "$archive_path" -C "$tmp_dir" "$NODE_SERVICE_BINARY_NAME" 2>/dev/null; then
        colorized_echo red "Failed to extract node-serviced binary from archive."
        rm -rf "$tmp_dir"
        return 1
    fi
    binary_path="${tmp_dir}/${NODE_SERVICE_BINARY_NAME}"
    if ! verify_node_serviced_binary "$binary_path"; then
        colorized_echo red "Extracted node-serviced is not a non-empty Linux executable."
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! activate_node_serviced_binary "$binary_path" "$keep_backup"; then
        colorized_echo red "Failed to atomically install node-serviced at $SERVICE_BINARY_PATH"
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
    colorized_echo green "node-serviced installed successfully at $SERVICE_BINARY_PATH (v${latest_version})"
}
# Get a list of occupied ports
get_occupied_ports() {
    if command -v ss &>/dev/null; then
        OCCUPIED_PORTS=$(ss -tuln | awk '{print $5}' | grep -Eo '[0-9]+$' | sort | uniq)
    elif command -v netstat &>/dev/null; then
        OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort | uniq)
    else
        colorized_echo yellow "Neither ss nor netstat found. Attempting to install net-tools."
        detect_os
        install_package net-tools
        if command -v netstat &>/dev/null; then
            OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort | uniq)
        else
            colorized_echo red "Failed to install net-tools. Please install it manually."
            exit 1
        fi
    fi
}
# Function to check if a port is occupied
is_port_occupied() {
    if echo "$OCCUPIED_PORTS" | grep -q -w "$1"; then
        return 0
    else
        return 1
    fi
}
# Function to detect if a string is an IP address (IPv4 or IPv6)
is_ip_address() {
    local input="$1"
    # Check for IPv4 (e.g., 192.168.1.1)
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Validate each octet is 0-255
        IFS='.' read -ra octets <<< "$input"
        for octet in "${octets[@]}"; do
            if [[ $octet -lt 0 || $octet -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    # Check for IPv6 (simplified check - contains colons and hex digits)
    if [[ "$input" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] || [[ "$input" =~ ^:: ]] || [[ "$input" =~ :: ]]; then
        return 0
    fi
    return 1
}

# Function to normalize SAN entry (add DNS: or IP: prefix if missing)
normalize_san_entry() {
    local entry="$1"
    local normalized=""
    
    # Remove leading/trailing whitespace
    entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # If already has prefix, return as-is
    if [[ "$entry" =~ ^DNS:.+ ]]; then
        echo "$entry"
        return 0
    elif [[ "$entry" =~ ^IP:.+ ]]; then
        echo "$entry"
        return 0
    fi
    
    # Auto-detect and add prefix
    if is_ip_address "$entry"; then
        normalized="IP:$entry"
    else
        # Assume it's a domain name
        normalized="DNS:$entry"
    fi
    
    echo "$normalized"
}

validate_san_entry() {
    local entry="$1"
    # Remove leading/trailing whitespace
    entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Empty entry is invalid
    if [ -z "$entry" ]; then
        return 1
    fi
    
    # Normalize the entry (add prefix if missing)
    local normalized
    normalized=$(normalize_san_entry "$entry")
    
    # Check if normalized entry is valid
    if [[ "$normalized" =~ ^DNS:.+ ]] || [[ "$normalized" =~ ^IP:.+ ]]; then
        return 0
    else
        return 1
    fi
}

generate_uuid_v4() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null ||
        uuidgen 2>/dev/null ||
        python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null ||
        python -c "import uuid; print(uuid.uuid4())" 2>/dev/null
}

openssl_supports_addext() {
    openssl req -help 2>&1 | grep -q -- '-addext'
}

generate_self_signed_cert_with_addext() {
    local san_string="$1"

    openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$SSL_KEY_FILE" \
        -out "$SSL_CERT_FILE" -days 3650 -nodes \
        -subj "/CN=$NODE_IP" \
        -addext "subjectAltName = $san_string" >/dev/null 2>&1
}

generate_self_signed_cert_with_config() {
    local san_string="$1"
    local openssl_config=""
    local status=0

    openssl_config=$(create_temp_file "pg-node-openssl" ".cnf")
    {
        echo "[req]"
        echo "distinguished_name = req_distinguished_name"
        echo "x509_extensions = v3_req"
        echo "prompt = no"
        echo ""
        echo "[req_distinguished_name]"
        echo "CN = $NODE_IP"
        echo ""
        echo "[v3_req]"
        echo "subjectAltName = $san_string"
    } >"$openssl_config"

    openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$SSL_KEY_FILE" \
        -out "$SSL_CERT_FILE" -days 3650 -nodes \
        -config "$openssl_config" \
        -extensions v3_req >/dev/null 2>&1 || status=$?

    rm -f "$openssl_config"
    return "$status"
}

gen_self_signed_cert() {
    local san_entries=("DNS:localhost" "IP:127.0.0.1")
    local extra_san=""
    local user_san_entries=()
    # Add IPv4 if it exists
    if [ -n "$NODE_IP_V4" ]; then
        san_entries+=("IP:$NODE_IP_V4")
    fi
    # Add IPv6 if it exists
    if [ -n "$NODE_IP_V6" ]; then
        san_entries+=("IP:$NODE_IP_V6")
    fi
    colorized_echo cyan "================================"
    colorized_echo cyan "Current SAN (Subject Alternative Name) entries:"
    for entry in "${san_entries[@]}"; do
        if [[ "$entry" =~ ^DNS: ]]; then
            colorized_echo green "  ✓ DNS: ${entry#DNS:}"
        elif [[ "$entry" =~ ^IP: ]]; then
            colorized_echo green "  ✓ IP: ${entry#IP:}"
        fi
    done
    colorized_echo cyan "================================"
    if [ -n "${INSTALL_SAN_ENTRIES:-}" ]; then
        extra_san="$INSTALL_SAN_ENTRIES"
        IFS=',' read -ra user_entries <<<"$extra_san"
        local valid_entries=()
        local invalid_entries=()
        for entry in "${user_entries[@]}"; do
            entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$entry" ]; then
                if validate_san_entry "$entry"; then
                    valid_entries+=("$(normalize_san_entry "$entry")")
                else
                    invalid_entries+=("$entry")
                fi
            fi
        done
        if [ ${#invalid_entries[@]} -gt 0 ]; then
            colorized_echo red "ERROR: Invalid SAN entries provided via argument: ${invalid_entries[*]}"
            exit 1
        fi
        user_san_entries=("${valid_entries[@]}")
    elif [ "$AUTO_CONFIRM" = true ]; then
        :
    else
        while true; do
            # Temporarily disable exit on error for user input
            set +e
            colorized_echo cyan ""
            colorized_echo yellow "You can add additional SAN entries (IP addresses or domain names)."
            colorized_echo yellow "Examples:"
            colorized_echo cyan "  • IP addresses: 192.168.1.100, 203.0.113.45"
            colorized_echo cyan "  • Domain names: node.example.com, vpn.mydomain.com"
            colorized_echo cyan "  • Wildcard domains: *.example.com"
            colorized_echo cyan "  • IPv6: 2001:db8::1"
            colorized_echo yellow ""
            read -rp "Enter additional SAN entries (comma separated), or press ENTER to keep current: " extra_san
            local read_status=$?
            set -e
            # Check if read was interrupted (Ctrl+C)
            if [ $read_status -ne 0 ]; then
                colorized_echo yellow "Input cancelled, using default SAN entries only"
                break
            fi
            if [[ -z "$extra_san" ]]; then
                break
            fi
            # Split input by comma and validate each entry
            IFS=',' read -ra user_entries <<<"$extra_san"
            local valid_entries=()
            local invalid_entries=()
            local skipped_entries=()
            
            colorized_echo cyan "Validating SAN entries..."
            for entry in "${user_entries[@]}"; do
                # Trim whitespace
                entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [ -z "$entry" ]; then
                    skipped_entries+=("(empty)")
                    continue
                fi
                if validate_san_entry "$entry"; then
                    # Normalize the entry to get the proper format
                    local normalized
                    normalized=$(normalize_san_entry "$entry")
                    valid_entries+=("$normalized")
                    if [[ "$normalized" =~ ^DNS: ]]; then
                        colorized_echo green "  ✓ Valid: ${normalized#DNS:} (detected as DNS)"
                    elif [[ "$normalized" =~ ^IP: ]]; then
                        colorized_echo green "  ✓ Valid: ${normalized#IP:} (detected as IP)"
                    fi
                else
                    invalid_entries+=("$entry")
                    colorized_echo red "  ✗ Invalid: '$entry'"
                    colorized_echo yellow "    → Please enter a valid IP address (e.g., 192.168.1.100) or domain name (e.g., node.example.com)"
                fi
            done
            
            if [ ${#skipped_entries[@]} -gt 0 ]; then
                colorized_echo yellow "  ⚠ Skipped ${#skipped_entries[@]} empty entry/entries"
            fi
            
            if [ ${#invalid_entries[@]} -gt 0 ]; then
                colorized_echo red ""
                colorized_echo red "ERROR: ${#invalid_entries[@]} invalid SAN entry/entries found:"
                for invalid in "${invalid_entries[@]}"; do
                    colorized_echo red "  • '$invalid'"
                done
                colorized_echo yellow ""
                colorized_echo yellow "Valid format examples:"
                colorized_echo cyan "  • IP addresses: 192.168.1.100, 203.0.113.45"
                colorized_echo cyan "  • Domain names: node.example.com, vpn.mydomain.com"
                colorized_echo cyan "  • Wildcard domains: *.example.com"
                colorized_echo cyan "  • IPv6 addresses: 2001:db8::1, ::1"
                colorized_echo yellow ""
                colorized_echo yellow "Note: Enter IPs and domains directly (no DNS: or IP: prefix needed)."
                colorized_echo yellow "The script will automatically detect the type."
                colorized_echo yellow ""
                colorized_echo yellow "Please correct the invalid entries and try again."
                continue
            fi
            if [ ${#valid_entries[@]} -gt 0 ]; then
                user_san_entries=("${valid_entries[@]}")
                colorized_echo green ""
                colorized_echo green "✓ Successfully accepted ${#valid_entries[@]} SAN entry/entries"
            fi
            break
        done
    fi
    if [ ${#user_san_entries[@]} -gt 0 ]; then
        san_entries+=("${user_san_entries[@]}")
    fi
    # Join SAN entries into a comma-separated string and remove duplicates
    local san_string
    san_string=$(printf '%s\n' "${san_entries[@]}" | sort -u | paste -sd, - 2>/dev/null)
    # Check if san_string was created successfully
    if [ -z "$san_string" ]; then
        colorized_echo red "Error: Failed to process SAN entries"
        exit 1
    fi
    # Display final SAN entries
    colorized_echo cyan ""
    colorized_echo cyan "Final SAN entries that will be used:"
    IFS=',' read -ra final_entries <<<"$san_string"
    for entry in "${final_entries[@]}"; do
        if [[ "$entry" =~ ^DNS: ]]; then
            colorized_echo green "  • DNS: ${entry#DNS:}"
        elif [[ "$entry" =~ ^IP: ]]; then
            colorized_echo green "  • IP: ${entry#IP:}"
        fi
    done
    colorized_echo cyan ""
    # Generate certificate
    colorized_echo blue "Generating self-signed certificate..."
    colorized_echo cyan "  Command: openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 ..."
    if ! command -v openssl >/dev/null 2>&1; then
        colorized_echo yellow "OpenSSL not found. Attempting to install openssl."
        detect_os
        install_package openssl
    fi
    local cert_generated=false
    if openssl_supports_addext; then
        if generate_self_signed_cert_with_addext "$san_string"; then
            cert_generated=true
        fi
    else
        colorized_echo yellow "  OpenSSL -addext is unavailable; using config-file SAN fallback."
        if generate_self_signed_cert_with_config "$san_string"; then
            cert_generated=true
        fi
    fi
    if [ "$cert_generated" = true ]; then
        # openssl -keyout preserves a pre-existing file's mode, so tighten the
        # private key to owner-only after every (re)generation.
        harden_secret_file "$SSL_KEY_FILE"
        colorized_echo green "✓ Certificate generated successfully!"
        colorized_echo green "  Certificate: $SSL_CERT_FILE"
        colorized_echo green "  Private Key: $SSL_KEY_FILE"
    else
        colorized_echo red "✗ Error: Failed to generate certificate"
        colorized_echo red "  Please check that openssl is installed and you have write permissions."
        exit 1
    fi
}
read_and_save_file() {
    local prompt_message=$1
    local output_file=$2
    local allow_file_input=$3
    local first_line_read=0
    # Check if the file exists before clearing it
    if [ -f "$output_file" ]; then
        : >"$output_file"
    fi
    colorized_echo cyan "$prompt_message"
    colorized_echo yellow "Press ENTER on a new line when finished: "
    while IFS= read -r line; do
        [[ -z $line ]] && break
        if [[ "$first_line_read" -eq 0 && "$allow_file_input" -eq 1 && -f "$line" ]]; then
            first_line_read=1
            colorized_echo cyan "  Detected file path, copying: $line"
            cp "$line" "$output_file"
            break
        fi
        echo "$line" >>"$output_file"
    done
}
install_node() {
    local node_version=$1
    FILES_URL_PREFIX="https://raw.githubusercontent.com/PasarGuard/node/main"
    COMPOSE_FILES_URL_PREFIX="https://raw.githubusercontent.com/PasarGuard/scripts/main/docker-compose"
    colorized_echo blue "Creating directories..."
    colorized_echo cyan "  Command: mkdir -p $DATA_DIR $DATA_DIR/certs $APP_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$DATA_DIR/certs"
    # The certs dir holds the TLS private key; keep it owner-only.
    chmod 700 "$DATA_DIR/certs" 2>/dev/null || true
    mkdir -p "$APP_DIR"
    colorized_echo green "  ✓ Directories created"
    colorized_echo cyan ""
    colorized_echo yellow "A self-signed certificate will be generated by default."
    if [ "${INSTALL_SELF_SIGNED:-false}" = true ]; then
        use_public_cert=""
    elif [ -n "${INSTALL_CERT_PATH:-}" ] && [ -n "${INSTALL_KEY_PATH:-}" ]; then
        use_public_cert="y"
    elif [ "$AUTO_CONFIRM" = true ]; then
        use_public_cert=""
    else
        read -r -p "Do you want to use your own public certificate instead? (Y/n): " use_public_cert
    fi
    if [[ "$use_public_cert" =~ ^[Yy]$ ]]; then
        if [ -n "${INSTALL_CERT_PATH:-}" ] && [ -f "$INSTALL_CERT_PATH" ]; then
            cp "$INSTALL_CERT_PATH" "$SSL_CERT_FILE"
            colorized_echo blue "Certificate copied to $SSL_CERT_FILE"
        else
            read_and_save_file "Please paste the content OR the path to the Client Certificate file." "$SSL_CERT_FILE" 1
            colorized_echo blue "Certificate saved to $SSL_CERT_FILE"
        fi

        if [ -n "${INSTALL_KEY_PATH:-}" ] && [ -f "$INSTALL_KEY_PATH" ]; then
            cp "$INSTALL_KEY_PATH" "$SSL_KEY_FILE"
            colorized_echo blue "Private key copied to $SSL_KEY_FILE"
        else
            read_and_save_file "Please paste the content OR the path to the Private Key file." "$SSL_KEY_FILE" 1
            colorized_echo blue "Private key saved to $SSL_KEY_FILE"
        fi
        # cp/paste create the key with the default umask (0644); restrict it.
        harden_secret_file "$SSL_KEY_FILE"
    else
        gen_self_signed_cert
        colorized_echo blue "self-signed certificate successfully generated"
    fi
    if [ -n "${INSTALL_API_KEY:-}" ]; then
        API_KEY="$INSTALL_API_KEY"
    elif [ "$AUTO_CONFIRM" = true ]; then
        API_KEY=""
    else
        read -p "Enter your API Key (must be a valid UUID (any version), leave blank to auto-generate): " -r API_KEY
    fi
    if [[ -z "$API_KEY" ]]; then
        # Generate a valid UUIDv4
        API_KEY=$(generate_uuid_v4)
        colorized_echo green "No API Key provided. A random UUID version 4 has been generated"
    fi
    if [ "${INSTALL_USE_REST:-}" = "true" ]; then
        USE_REST=1
    elif [ "${INSTALL_USE_REST:-}" = "false" ]; then
        USE_REST=0
    else
        if [ "$AUTO_CONFIRM" = true ]; then
            use_rest=""
        else
            read -p "GRPC is recommended by default. Do you want to use REST protocol instead? (y/N): " -r use_rest
        fi
        # Default to GRPC (the recommended default) when the user just presses ENTER
        if [[ "$use_rest" =~ ^[Yy]$ ]]; then
            USE_REST=1
        else
            USE_REST=0
        fi
    fi
    get_occupied_ports
    if [ -n "${INSTALL_SERVICE_PORT:-}" ]; then
        SERVICE_PORT="$INSTALL_SERVICE_PORT"
        if is_port_occupied "$SERVICE_PORT"; then
            colorized_echo red "Port $SERVICE_PORT is already in use."
            exit 1
        fi
        if ! [[ "$SERVICE_PORT" -ge 1 && "$SERVICE_PORT" -le 65535 ]]; then
            colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
            exit 1
        fi
    elif [ "$AUTO_CONFIRM" = true ]; then
        SERVICE_PORT=62050
        if is_port_occupied "$SERVICE_PORT"; then
            colorized_echo red "Port $SERVICE_PORT is already in use. Run without -y to choose another port."
            exit 1
        fi
    else
        # Prompt user to enter the service port, ensuring the selected port is not already in use
        while true; do
            read -p "Enter the SERVICE_PORT (default 62050): " -r SERVICE_PORT
            if [[ -z "$SERVICE_PORT" ]]; then
                SERVICE_PORT=62050
            fi
            if [[ "$SERVICE_PORT" -ge 1 && "$SERVICE_PORT" -le 65535 ]]; then
                if is_port_occupied "$SERVICE_PORT"; then
                    colorized_echo red "Port $SERVICE_PORT is already in use. Please enter another port."
                else
                    break
                fi
            else
                colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
            fi
        done
    fi
    colorized_echo blue "Fetching .env and compose file"
    colorized_echo cyan "  Command: curl -fsL $FILES_URL_PREFIX/.env.example -o $APP_DIR/.env"
    # Pre-create .env as 0600 (and tighten any pre-existing copy) so the node
    # API_KEY written below is never world-readable.
    harden_secret_file "$APP_DIR/.env"
    if curl -fsL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"; then
        colorized_echo green "  ✓ File saved: $APP_DIR/.env"
    else
        colorized_echo red "  ✗ Failed to download .env.example"
        exit 1
    fi
    colorized_echo cyan "  Command: curl -fsL $COMPOSE_FILES_URL_PREFIX/node.yml -o $APP_DIR/docker-compose.yml"
    if curl -fsL "$COMPOSE_FILES_URL_PREFIX/node.yml" -o "$APP_DIR/docker-compose.yml"; then
        colorized_echo green "  ✓ File saved: $APP_DIR/docker-compose.yml"
    else
        colorized_echo red "  ✗ Failed to download node.yml"
        exit 1
    fi
    # Modifying .env file
    sed -i "s/^SERVICE_PORT *= *.*/SERVICE_PORT= ${SERVICE_PORT}/" "$APP_DIR/.env"
    sed -i "s/^API_KEY *= *.*/API_KEY= ${API_KEY}/" "$APP_DIR/.env"
    if [ "$USE_REST" -eq 1 ]; then
        sed -i 's/^# \(SERVICE_PROTOCOL *=.*\)/SERVICE_PROTOCOL= "rest"/' "$APP_DIR/.env"
    else
        sed -i 's/^# \(SERVICE_PROTOCOL *=.*\)/SERVICE_PROTOCOL= "grpc"/' "$APP_DIR/.env"
    fi
    colorized_echo green ".env file modified successfully"
    # Modifying compose file
    colorized_echo blue "Modifying docker-compose.yml..."
    service_name="node"
    if [ "$APP_NAME" != "pg-node" ]; then
        colorized_echo cyan "  Command: yq eval ...container_name = \"$APP_NAME\"..."
        if yq eval ".services[\"$service_name\"].container_name = \"$APP_NAME\"" -i "$APP_DIR/docker-compose.yml" 2>/dev/null; then
            colorized_echo green "  ✓ Container name set to: $APP_NAME"
        else
            colorized_echo yellow "  ⚠ Failed to set container name (may not be critical)"
        fi
    fi
    container_path=""
    existing_volume=$(yq eval -r ".services[\"$service_name\"].volumes[0]" "$APP_DIR/docker-compose.yml" 2>/dev/null)
    if [ -n "$existing_volume" ] && [ "$existing_volume" != "null" ]; then
        # Extract container path (everything after the colon)
        if [[ "$existing_volume" == *:* ]]; then
            container_path="${existing_volume#*:}"
        else
            # If no colon found, use the existing volume as container path
            container_path="$existing_volume"
        fi
    fi
    # For custom names, keep host/container paths aligned to the APP_NAME data dir
    if [ "$APP_NAME" != "pg-node" ] || [ -z "$container_path" ]; then
        container_path="$DATA_DIR"
    fi
    colorized_echo cyan "  Command: yq eval ...volumes[0] = \"${DATA_DIR}:${container_path}\"..."
    if yq eval ".services[\"$service_name\"].volumes[0] = \"${DATA_DIR}:${container_path}\"" -i "$APP_DIR/docker-compose.yml" 2>/dev/null; then
        colorized_echo green "  ✓ Volume path configured: ${DATA_DIR}:${container_path}"
    else
        colorized_echo yellow "  ⚠ Failed to configure volume (may not be critical)"
    fi
    # Keep SSL paths in .env aligned with the mapped volume (important for node-serviced on host)
    ssl_cert_env="${container_path}/certs/ssl_cert.pem"
    ssl_key_env="${container_path}/certs/ssl_key.pem"
    sed -i "s|^SSL_CERT_FILE *=.*|SSL_CERT_FILE= ${ssl_cert_env}|" "$APP_DIR/.env"
    sed -i "s|^SSL_KEY_FILE *=.*|SSL_KEY_FILE= ${ssl_key_env}|" "$APP_DIR/.env"
    if [ "$node_version" != "latest" ]; then
        colorized_echo cyan "  Command: yq eval ...image = ...:${node_version}..."
        if yq eval ".services[\"$service_name\"].image = (.services[\"$service_name\"].image | sub(\":.*$\"; \":${node_version}\"))" -i "$APP_DIR/docker-compose.yml" 2>/dev/null; then
            colorized_echo green "  ✓ Docker image version set to: ${node_version}"
        else
            colorized_echo yellow "  ⚠ Failed to set image version (may not be critical)"
        fi
    fi
    # Final sync to ensure env has the correct SSL paths for custom names
    sync_env_ssl_paths
    colorized_echo green "✓ docker-compose.yml modified successfully"
}
uninstall_node_script() {
    if [ -f "/usr/local/bin/$APP_NAME" ]; then
        colorized_echo yellow "Removing node script"
        rm "/usr/local/bin/$APP_NAME"
    fi
}
uninstall_node_service_script() {
    set_service_paths
    if [ -f "$SERVICE_BINARY_PATH" ]; then
        colorized_echo yellow "Removing node-serviced binary"
        rm "$SERVICE_BINARY_PATH"
    fi
}
uninstall_node() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}
uninstall_node_docker_images() {
    local images
    images=$(docker images --format '{{.Repository}} {{.ID}}' | awk '$1 ~ /^pasarguard\/node(:|$)/ {print $2}' | sort -u)

    if [ -z "$images" ]; then
        colorized_echo yellow "pasarguard/node images not found"
        return 0
    fi

    colorized_echo yellow "Checking pasarguard/node images for removal..."

    for image in $images; do
        if docker ps -a --filter "ancestor=$image" -q | grep -q .; then
		    local container
            container=$(docker ps -a --filter "ancestor=$image" --format '{{.Names}}' | tr '\n' ' ')
            colorized_echo yellow "Skipping image $image (still used by: $container)"
            continue
        fi

        if docker rmi "$image" >/dev/null 2>&1; then
            colorized_echo yellow "Image $image removed"
        else
            colorized_echo yellow "Failed to remove image $image"
        fi
    done
}
uninstall_node_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}
up_node() {
    compose_up
}
down_node() {
    compose_down
}
show_node_logs() {
    compose_logs
}
follow_node_logs() {
    compose_logs_follow
}
update_node_script() {
    colorized_echo blue "Updating node script"

    local backup_dir
    backup_dir=$(backup_scripts)

    if ! install_shared_libs_from_repo "$FETCH_REPO" common.sh system.sh docker.sh github.sh; then
        colorized_echo red "Failed to update shared libraries. Restoring from backup..."
        restore_scripts "$backup_dir"
        cleanup_backup "$backup_dir"
        exit 1
    fi

    if ! github_install_script_from_repo "$FETCH_REPO" "pg-node.sh" "$APP_NAME"; then
        colorized_echo red "Failed to update node script. Restoring from backup..."
        restore_scripts "$backup_dir"
        cleanup_backup "$backup_dir"
        exit 1
    fi

    cleanup_backup "$backup_dir"
    colorized_echo green "node script updated successfully"
}
update_node() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull
}
is_node_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}
ensure_env_exists() {
    if [ ! -f "$ENV_FILE" ]; then
        colorized_echo red "Environment file not found at $ENV_FILE. Please install the node first."
        exit 1
    fi
}
sync_env_ssl_paths() {
    # Adjust SSL_CERT_FILE/SSL_KEY_FILE in .env if a custom APP_NAME still points to the default pg-node path
    if [ "$APP_NAME" = "pg-node" ]; then
        return
    fi
    if [ ! -f "$ENV_FILE" ]; then
        return
    fi
    local desired_cert="${DATA_DIR}/certs/ssl_cert.pem"
    local desired_key="${DATA_DIR}/certs/ssl_key.pem"
    local current_cert current_key updated=false
    current_cert=$(grep -E '^[[:space:]]*SSL_CERT_FILE[[:space:]]*=' "$ENV_FILE" | head -n1 | sed "s/^[[:space:]]*SSL_CERT_FILE[[:space:]]*=[[:space:]]*//;s/[\"']//g")
    current_key=$(grep -E '^[[:space:]]*SSL_KEY_FILE[[:space:]]*=' "$ENV_FILE" | head -n1 | sed "s/^[[:space:]]*SSL_KEY_FILE[[:space:]]*=[[:space:]]*//;s/[\"']//g")
    if [[ -z "$current_cert" || "$current_cert" =~ /var/lib/pg-node/ || -z "$current_key" || "$current_key" =~ /var/lib/pg-node/ ]]; then
        mark_node_service_transaction_mutation_started || return 1
    fi
    if [[ -z "$current_cert" || "$current_cert" =~ /var/lib/pg-node/ ]]; then
        sed -i "s|^[[:space:]]*SSL_CERT_FILE[[:space:]]*=.*|SSL_CERT_FILE= ${desired_cert}|" "$ENV_FILE"
        grep -q '^[[:space:]]*SSL_CERT_FILE[[:space:]]*=' "$ENV_FILE" || echo "SSL_CERT_FILE= ${desired_cert}" >>"$ENV_FILE"
        updated=true
    fi
    if [[ -z "$current_key" || "$current_key" =~ /var/lib/pg-node/ ]]; then
        sed -i "s|^[[:space:]]*SSL_KEY_FILE[[:space:]]*=.*|SSL_KEY_FILE= ${desired_key}|" "$ENV_FILE"
        grep -q '^[[:space:]]*SSL_KEY_FILE[[:space:]]*=' "$ENV_FILE" || echo "SSL_KEY_FILE= ${desired_key}" >>"$ENV_FILE"
        updated=true
    fi
    if [ "$updated" = true ]; then
        colorized_echo cyan "Updated SSL file paths in $ENV_FILE to match APP_NAME ($APP_NAME)."
    fi
}
is_node_up() {
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}
install_command() {
    check_running_as_root
    print_script_execution_header "pg-node" "$SCRIPT_COMMIT_SHA" "install"
    # Default values
    node_version="latest"
    node_version_set="false"
    # Parse options
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
        -v | --version)
            if [[ "$node_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release and --version options simultaneously."
                exit 1
            fi
            node_version="$2"
            node_version_set="true"
            shift 2
            ;;
        --pre-release)
            if [[ "$node_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release and --version options simultaneously."
                exit 1
            fi
            node_version="pre-release"
            node_version_set="true"
            shift
            ;;
        --name)
            # --name is handled globally; ignore here to prevent unknown option errors
            shift 2
            ;;
        --override)
            INSTALL_OVERRIDE=true
            shift
            ;;
        --api-key)
            INSTALL_API_KEY="$2"
            shift 2
            ;;
        --use-rest)
            INSTALL_USE_REST=true
            shift
            ;;
        --use-grpc)
            INSTALL_USE_REST=false
            shift
            ;;
        --service-port)
            INSTALL_SERVICE_PORT="$2"
            shift 2
            ;;
        --cert-path)
            INSTALL_CERT_PATH="$2"
            shift 2
            ;;
        --key-path)
            INSTALL_KEY_PATH="$2"
            shift 2
            ;;
        --self-signed)
            INSTALL_SELF_SIGNED=true
            shift
            ;;
        --api-port)
            INSTALL_API_PORT="$2"
            shift 2
            ;;
        --install-service)
            INSTALL_SERVICE_CHOICE="y"
            shift
            ;;
        --no-install-service)
            INSTALL_SERVICE_CHOICE="n"
            shift
            ;;
        --san-entries)
            INSTALL_SAN_ENTRIES="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
    done
    # Check if  node is already installed
    if is_node_installed; then
        colorized_echo red "node is already installed at $APP_DIR"
        if [ "${INSTALL_OVERRIDE:-false}" = true ] || [ "$AUTO_CONFIRM" = true ]; then
            REPLY="y"
        else
            read -p "Do you want to override the previous installation? (y/n) "
        fi
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi
    ensure_docker_compose
    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi
    detect_compose
    # Function to check if a version exists in the GitHub releases
    check_version_exists() {
        local version=$1
        repo_url="https://api.github.com/repos/PasarGuard/node/releases"
        if [ "$version" == "latest" ]; then
            latest_tag=$(curl -s ${repo_url}/latest | jq -r '.tag_name')
            # Check if there is any stable release of  node v1
            if [ "$latest_tag" == "null" ]; then
                return 1
            fi
            return 0
        fi
        if [ "$version" == "pre-release" ]; then
            local latest_stable_tag=$(curl -s "$repo_url/latest" | jq -r '.tag_name')
            local latest_pre_release_tag=$(curl -s "$repo_url" | jq -r '[.[] | select(.prerelease == true)][0].tag_name')
            if [ "$latest_stable_tag" == "null" ] && [ "$latest_pre_release_tag" == "null" ]; then
                return 1 # No releases found at all
            elif [ "$latest_stable_tag" == "null" ]; then
                node_version=$latest_pre_release_tag
            elif [ "$latest_pre_release_tag" == "null" ]; then
                node_version=$latest_stable_tag
            else
                # Compare versions using sort -V
                local chosen_version=$(printf "%s\n" "$latest_stable_tag" "$latest_pre_release_tag" | sort -V | tail -n 1)
                node_version=$chosen_version
            fi
            return 0
        fi
        # Check if the repos contains the version tag
        if curl -s -o /dev/null -w "%{http_code}" "${repo_url}/tags/${version}" | grep -q "^200$"; then
            return 0
        else
            return 1
        fi
    }
    # Check if the version is valid and exists
    if [[ "$node_version" == "latest" || "$node_version" == "pre-release" || "$node_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if check_version_exists "$node_version"; then
            colorized_echo cyan "================================"
            colorized_echo cyan "Installing PasarGuard Node"
            colorized_echo cyan "Version: $node_version"
            colorized_echo cyan "================================"
            install_node "$node_version"
            colorized_echo green "✓ Node installation completed for version: $node_version"
        else
            colorized_echo red "✗ Version $node_version does not exist. Please enter a valid version (e.g. v0.1.2)"
            exit 1
        fi
    else
        colorized_echo red "✗ Invalid version format. Please enter a valid version (e.g. v1.0.0)"
        exit 1
    fi
    install_node_script
    install_completion
    up_node
    show_node_logs
    local install_service_choice=""
    if [ -n "${INSTALL_SERVICE_CHOICE:-}" ]; then
        install_service_choice="$INSTALL_SERVICE_CHOICE"
    elif [ "$AUTO_CONFIRM" = true ]; then
        install_service_choice="y"
    else
        read -p "Do you want to install and start the systemd service for $APP_NAME? (Y/n): " install_service_choice
    fi
    if [[ -z "$install_service_choice" || "$install_service_choice" =~ ^[Yy]$ ]]; then
        install_service_command || return 1
    else
        colorized_echo yellow "Skipped installing systemd service for $APP_NAME."
    fi
    colorized_echo blue "================================"
    colorized_echo magenta " node is set up with the following IP: $NODE_IP and Port: $SERVICE_PORT."
    colorized_echo magenta "Please use the following Certificate in pasarguard Panel (it's located in ${DATA_DIR}/certs):"
    cat "$SSL_CERT_FILE"
    colorized_echo blue "================================"
    colorized_echo magenta "Next, use the API Key (UUID v4) in pasarguard Panel: "
    colorized_echo red "${API_KEY}"
}
uninstall_command() {
    check_running_as_root
    # Check if  node is installed
    if ! is_node_installed; then
        colorized_echo red "node not installed!"
        exit 1
    fi
    if [ "$AUTO_CONFIRM" = true ]; then
        REPLY="y"
    else
        read -p "Do you really want to uninstall node? (y/n) "
    fi
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi
    detect_compose
    if is_node_up; then
        down_node
    fi
    uninstall_service_command true || return 1
    uninstall_completion
    uninstall_node_script
    uninstall_node
    uninstall_node_docker_images
    if [ "$AUTO_CONFIRM" = true ]; then
        REPLY="y"
    else
        read -p "Do you want to remove node data files too ($DATA_DIR)? (y/n) "
    fi
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo green "node uninstalled successfully"
    else
        uninstall_node_data_files
        colorized_echo green "node uninstalled successfully"
    fi
}
up_command() {
    help() {
        colorized_echo red "Usage: node up [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        -n | --no-logs)
            no_logs=true
            ;;
        -h | --help)
            help
            exit 0
            ;;
        *)
            echo "Error: Invalid option: $1" >&2
            help
            exit 0
            ;;
        esac
        shift
    done
    # Check if node is installed
    if ! is_node_installed; then
        colorized_echo red "node's not installed!"
        exit 1
    fi
    detect_compose
    if is_node_up; then
        colorized_echo red "node's already up"
        exit 1
    fi
    up_node
    if [ "$no_logs" = false ]; then
        follow_node_logs
    fi
}
down_command() {
    # Check if node is installed
    if ! is_node_installed; then
        colorized_echo red "node not installed!"
        exit 1
    fi
    detect_compose
    if ! is_node_up; then
        colorized_echo red "node already down"
        exit 1
    fi
    down_node
}
restart_command() {
    help() {
        colorized_echo red "Usage: node restart [options]"
        echo
        echo "OPTIONS:"
        echo "  -h, --help              display this help message"
        echo "  -n, --no-logs           do not follow logs after starting"
        echo "  --no-restart-service    do not restart the systemd service (if installed)"
    }
    local no_logs=false
    local no_restart_service=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        -n | --no-logs)
            no_logs=true
            ;;
        --no-restart-service)
            no_restart_service=true
            ;;
        -h | --help)
            help
            exit 0
            ;;
        *)
            echo "Error: Invalid option: $1" >&2
            help
            exit 1
            ;;
        esac
        shift
    done
    # Check if node is installed
    if ! is_node_installed; then
        colorized_echo red "node not installed!"
        exit 1
    fi
    detect_compose
    down_node
    up_node

    if [ "$no_restart_service" = false ]; then
        restart_service_if_installed
    else
        colorized_echo yellow "Skipped restarting $SERVICE_NAME (due to --no-restart-service)"
    fi

    if [ "$no_logs" = false ]; then
        follow_node_logs
    fi
}
write_node_service_unit() {
    local unit_dir unit_temp

    unit_dir=$(dirname "$SERVICE_UNIT")
    unit_temp=$(create_temp_file_in_dir "$unit_dir" ".${SERVICE_NAME}.unit" "") || return 1
    if ! cat >"$unit_temp" <<EOF
[Unit]
Description=PasarGuard Node Service API ($APP_NAME)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=$SERVICE_BINARY_PATH
WorkingDirectory=$APP_DIR
Restart=on-failure
RestartSec=5
TimeoutStartSec=30
TimeoutStopSec=10
Environment="ENV_FILE=$ENV_FILE"
Environment="APP_NAME=$APP_NAME"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[Install]
WantedBy=multi-user.target
EOF
    then
        rm -f "$unit_temp"
        return 1
    fi
    if ! mark_node_service_transaction_mutation_started; then
        rm -f "$unit_temp"
        return 1
    fi
    mv -f "$unit_temp" "$SERVICE_UNIT"
}

can_reuse_node_service_api_port() {
    local had_service="$1"
    local requested_port="$2"
    local existing_port="$3"

    [ "$had_service" = true ] && [ "$requested_port" = "$existing_port" ]
}

replace_node_service_api_port() {
    local api_port="$1"
    local api_port_comment="$2"

    sed -i "s/^API_PORT[[:space:]]*=.*/API_PORT= ${api_port}/" "$ENV_FILE" || return 1
    if ! grep -q '^# *API_PORT' "$ENV_FILE"; then
        sed -i "/^API_PORT[[:space:]]*=.*/i ${api_port_comment}" "$ENV_FILE" || return 1
    fi
}

append_node_service_api_port() {
    local api_port="$1"
    local api_port_comment="$2"

    {
        printf '\n'
        printf '%s\n' "$api_port_comment"
        printf 'API_PORT= %s\n' "$api_port"
    } >>"$ENV_FILE"
}

persist_node_service_api_port() {
    local api_port="$1"
    local api_port_comment="$2"

    if grep -q '^API_PORT[[:space:]]*=' "$ENV_FILE"; then
        replace_node_service_api_port "$api_port" "$api_port_comment"
    else
        append_node_service_api_port "$api_port" "$api_port_comment"
    fi
}

install_service_command() (
    check_running_as_root
    require_systemd
    set_service_paths

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --api-port)
            INSTALL_API_PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
    done
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! is_node_installed; then
        colorized_echo red "node not installed! Install it before setting up the service."
        exit 1
    fi
    # Serialize the complete installation transaction with service-update.
    # The lock must be held before any backup or mutation so a later rollback
    # can never overwrite a successfully completed concurrent transaction.
    if ! acquire_node_serviced_update_lock; then
        return 1
    fi
    if ! begin_node_service_transaction; then
        colorized_echo red "Failed to snapshot $SERVICE_NAME before installation."
        return 1
    fi

    ensure_env_exists
    sync_env_ssl_paths || return 1
    get_occupied_ports
    local api_port existing_api_port=""
    local default_api_port=62051
    existing_api_port=$(read_node_service_env_value API_PORT 2>/dev/null || true)
    if [[ "$existing_api_port" =~ ^[0-9]+$ ]] && [ "$existing_api_port" -ge 1 ] && [ "$existing_api_port" -le 65535 ]; then
        colorized_echo blue "Existing API_PORT found in $ENV_FILE: $existing_api_port"
        default_api_port="$existing_api_port"
    fi
    if [ -n "${INSTALL_API_PORT:-}" ]; then
        api_port="$INSTALL_API_PORT"
        if ! [[ "$api_port" =~ ^[0-9]+$ && "$api_port" -ge 1 && "$api_port" -le 65535 ]]; then
            colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
            exit 1
        fi
        if is_port_occupied "$api_port" &&
            ! can_reuse_node_service_api_port "$NODE_SERVICE_TRANSACTION_HAD_SERVICE" "$api_port" "$existing_api_port"; then
            colorized_echo red "Port $api_port is already in use."
            exit 1
        fi
    elif [ "$AUTO_CONFIRM" = true ]; then
        api_port="$default_api_port"
        if is_port_occupied "$api_port" &&
            ! can_reuse_node_service_api_port "$NODE_SERVICE_TRANSACTION_HAD_SERVICE" "$api_port" "$existing_api_port"; then
            colorized_echo red "Port $api_port is already in use. Run without -y to choose another port."
            exit 1
        fi
    else
        while true; do
            read -p "Enter the API_PORT for node service (default ${default_api_port}): " -r api_port
            if [[ -z "$api_port" ]]; then
                api_port="$default_api_port"
            fi
            if [[ "$api_port" =~ ^[0-9]+$ && "$api_port" -ge 1 && "$api_port" -le 65535 ]]; then
                if is_port_occupied "$api_port" &&
                    ! can_reuse_node_service_api_port "$NODE_SERVICE_TRANSACTION_HAD_SERVICE" "$api_port" "$existing_api_port"; then
                    colorized_echo red "Port $api_port is already in use. Please enter another port."
                else
                    break
                fi
            else
                colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
            fi
        done
    fi
    local api_port_comment="# API_PORT is used by the node service API ($APP_NAME)"
    mark_node_service_transaction_mutation_started || return 1
    if persist_node_service_api_port "$api_port" "$api_port_comment"; then
        :
    else
        colorized_echo red "Failed to save API_PORT in $ENV_FILE; restoring the previous service configuration."
        abort_node_service_transaction ||
            colorized_echo red "Failed to restore the previous $SERVICE_NAME configuration."
        return 1
    fi
    colorized_echo magenta "API_PORT selected: ${api_port}"
    configure_firewall_for_port "$api_port" "tcp"
    if ! install_node_service_script false; then
        colorized_echo red "Failed to install $SERVICE_NAME binary; restoring the previous service configuration."
        abort_node_service_transaction ||
            colorized_echo red "Failed to restore the previous $SERVICE_NAME configuration."
        return 1
    fi
    colorized_echo blue "Creating systemd unit at $SERVICE_UNIT"
    if ! write_node_service_unit || ! run_node_service_systemctl daemon-reload || ! run_node_service_systemctl enable "$SERVICE_NAME" ||
        ! run_node_service_systemctl restart "$SERVICE_NAME" || ! wait_for_node_service_ready; then
        colorized_echo red "$SERVICE_NAME failed to become ready; restoring the previous installation."
        if ! abort_node_service_transaction; then
            colorized_echo red "Failed to restore the previous $SERVICE_NAME installation."
        fi
        return 1
    fi
    commit_node_service_transaction
    colorized_echo green "$SERVICE_NAME service installed and started."
)
uninstall_service_command() (
    local quiet_if_missing="${1:-false}"

    check_running_as_root
    # The general node uninstall historically skipped service cleanup on
    # non-systemd hosts. Keep that harmless behavior for its quiet probe.
    if [ "$quiet_if_missing" = true ] && ! command -v systemctl >/dev/null 2>&1; then
        return
    fi
    require_systemd
    set_service_paths
    if ! acquire_node_serviced_update_lock; then
        return 1
    fi
    if ! begin_node_service_transaction; then
        colorized_echo red "Failed to snapshot or inspect $SERVICE_NAME before uninstalling it."
        return 1
    fi
    if [ "$NODE_SERVICE_TRANSACTION_HAD_SERVICE" != true ]; then
        commit_node_service_transaction
        if [ "$quiet_if_missing" != true ]; then
            colorized_echo yellow "Service not installed; nothing to uninstall."
        fi
        return
    fi
    if [ "$NODE_SERVICE_TRANSACTION_WAS_ACTIVE" = true ]; then
        mark_node_service_transaction_mutation_started || return 1
        if ! run_node_service_systemctl stop "$SERVICE_NAME" >/dev/null 2>&1; then
            colorized_echo red "Failed to stop $SERVICE_NAME; keeping the installed service intact."
            abort_node_service_transaction ||
                colorized_echo red "Failed to fully restore the previous $SERVICE_NAME state."
            return 1
        fi
    fi
    if [ "$NODE_SERVICE_TRANSACTION_WAS_ENABLED" = true ]; then
        mark_node_service_transaction_mutation_started || return 1
        if ! run_node_service_systemctl disable "$SERVICE_NAME" >/dev/null 2>&1; then
            colorized_echo red "Failed to disable $SERVICE_NAME; restoring its previous state."
            abort_node_service_transaction ||
                colorized_echo red "Failed to fully restore the previous $SERVICE_NAME state."
            return 1
        fi
    fi
    mark_node_service_transaction_mutation_started || return 1
    if [ -f "$SERVICE_UNIT" ]; then
        colorized_echo yellow "Removing systemd unit $SERVICE_UNIT"
        rm "$SERVICE_UNIT" || {
            abort_node_service_transaction ||
                colorized_echo red "Failed to fully restore the previous $SERVICE_NAME installation."
            return 1
        }
    fi
    if ! uninstall_node_service_script || ! run_node_service_systemctl daemon-reload; then
        colorized_echo red "Failed to remove $SERVICE_NAME cleanly; restoring the previous installation."
        abort_node_service_transaction ||
            colorized_echo red "Failed to fully restore the previous $SERVICE_NAME installation."
        return 1
    fi
    commit_node_service_transaction
    colorized_echo green "$SERVICE_NAME service uninstalled."
)

service_start_command() {
    check_running_as_root
    require_systemd
    require_node_service_installed || return 1
    systemctl start "$SERVICE_NAME"
    colorized_echo green "$SERVICE_NAME service started."
}
service_stop_command() {
    check_running_as_root
    require_systemd
    require_node_service_installed || return 1
    systemctl stop "$SERVICE_NAME"
    colorized_echo green "$SERVICE_NAME service stopped."
}

service_update_command() {
    check_running_as_root
    require_systemd
    update_service_if_installed true
}

service_logs_command() {
    require_systemd
    require_node_service_installed || return 1
    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        -n | --no-follow)
            no_follow=true
            ;;
        -h | --help)
            colorized_echo red "Usage: $APP_NAME service-logs [options]"
            echo "  -n, --no-follow   Show logs without following"
            exit 0
            ;;
        *)
            echo "Error: Invalid option: $1" >&2
            exit 1
            ;;
        esac
        shift
    done

    if [ "$no_follow" = true ]; then
        journalctl -u "$SERVICE_NAME" --no-pager
    else
        journalctl -u "$SERVICE_NAME" -f
    fi
}

restart_service_command() {
    check_running_as_root
    require_systemd
    require_node_service_installed || return 1
    restart_service_if_installed
}
status_service_command() {
    require_systemd
    require_node_service_installed || return 1
    systemctl status --no-pager "$SERVICE_NAME"
}
status_command() {
    # Check if node is installed
    if ! is_node_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi
    detect_compose
    if ! is_node_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi
    echo -n "Status: "
    colorized_echo green "Up"
    json=$($COMPOSE -f $COMPOSE_FILE ps -a --format=json)
    services=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .Service')
    states=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .State')
    # Print out the service names and statuses
    for i in $(seq 0 $(expr $(echo $services | wc -w) - 1)); do
        service=$(echo $services | cut -d' ' -f $(expr $i + 1))
        state=$(echo $states | cut -d' ' -f $(expr $i + 1))
        echo -n "- $service: "
        if [ "$state" == "running" ]; then
            colorized_echo green $state
        else
            colorized_echo red $state
        fi
    done
}
logs_command() {
    help() {
        colorized_echo red "Usage: node logs [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-follow   do not show follow logs"
    }
    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        -n | --no-follow)
            no_follow=true
            ;;
        -h | --help)
            help
            exit 0
            ;;
        *)
            echo "Error: Invalid option: $1" >&2
            help
            exit 0
            ;;
        esac
        shift
    done
    # Check if node is installed
    if ! is_node_installed; then
        colorized_echo red "node's not installed!"
        exit 1
    fi
    detect_compose
    if ! is_node_up; then
        colorized_echo red "node is not up."
        exit 1
    fi
    if [ "$no_follow" = true ]; then
        show_node_logs
    else
        follow_node_logs
    fi
}
update_command() {
    check_running_as_root
    local no_update_service=false
    # Parse args
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        --no-update-service)
            no_update_service=true
            shift
            ;;
        *)
            break
            ;;
        esac
    done

    # Check if node is installed
    if ! is_node_installed; then
        colorized_echo red "node not installed!"
        exit 1
    fi
    detect_compose
    update_node_script
    uninstall_completion
    install_completion
    colorized_echo blue "Pulling latest version"
    update_node
    colorized_echo blue "Restarting node services"
    down_node
    up_node

    if [ "$no_update_service" = false ]; then
        update_service_if_installed
    else
        colorized_echo yellow "Skipped updating $SERVICE_NAME (due to --no-update-service)"
    fi

    colorized_echo blue "node updated successfully"
}
# Function to update the Xray core
get_xray_core() {
    local requested_version="${1:-}"
    identify_the_operating_system_and_architecture
    if ! command -v curl >/dev/null 2>&1; then
        colorized_echo yellow "curl is required. Attempting to install curl."
        detect_os
        install_package curl
    fi
    # Systemd/non-TTY environments may not have TERM set; ignore clear failures to avoid exiting under set -e
    safe_clear() { clear 2>/dev/null || true; }
    safe_clear
    validate_version() {
        local version="$1"
        local response
        local curl_exit_code
        
        # Use curl with timeout and error handling
        response=$(curl -s --max-time 10 --connect-timeout 5 "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version" 2>&1)
        curl_exit_code=$?
        
        # Check if curl failed (network error, timeout, etc.)
        if [ $curl_exit_code -ne 0 ] || [ -z "$response" ]; then
            echo -e "\033[1;31mError: Failed to validate version. Network error or GitHub API unavailable.\033[0m" >&2
            echo "network_error"
            return
        fi
        
        # Check if version exists
        if echo "$response" | grep -q '"message": "Not Found"'; then
            echo "invalid"
        else
            echo "valid"
        fi
    }
    print_menu() {
        safe_clear
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;32m      Xray-core Installer     \033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        current_version=$(get_current_xray_core_version)
        echo -e "\033[1;33m>>>> Current Xray-core version: \033[1;1m$current_version\033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;33mAvailable Xray-core versions:\033[0m"
        for ((i = 0; i < ${#versions[@]}; i++)); do
            echo -e "\033[1;34m$((i + 1)):\033[0m ${versions[i]}"
        done
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;35mM:\033[0m Enter a version manually"
        echo -e "\033[1;31mQ:\033[0m Quit"
        echo -e "\033[1;32m==============================\033[0m"
    }
    latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=$LAST_XRAY_CORES")
    versions=($(echo "$latest_releases" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'))
    if [ ${#versions[@]} -eq 0 ]; then
        echo -e "\033[1;31mNo Xray-core releases found.\033[0m"
        exit 1
    fi
    if [[ -n "$requested_version" ]]; then
        if [[ "$requested_version" == "latest" ]]; then
            selected_version=${versions[0]}
        else
            local validation_result
            validation_result=$(validate_version "$requested_version")
            if [ "$validation_result" == "valid" ]; then
                selected_version="$requested_version"
            elif [ "$validation_result" == "network_error" ]; then
                echo -e "\033[1;31mError: Failed to validate version due to network error. Please check your internet connection and try again.\033[0m" >&2
                exit 1
            else
                echo -e "\033[1;31mInvalid version or version does not exist: $requested_version. Please try again.\033[0m" >&2
                exit 1
            fi
        fi
    elif [ "$AUTO_CONFIRM" = true ]; then
        selected_version=${versions[0]}
    else
        while true; do
            print_menu
            read -p "Choose a version to install (1-${#versions[@]}), or press M to enter manually, Q to quit: " choice
            if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#versions[@]}" ]; then
                choice=$((choice - 1))
                selected_version=${versions[choice]}
                break
            elif [ "$choice" == "M" ] || [ "$choice" == "m" ]; then
                while true; do
                    read -p "Enter the version manually (e.g., v1.2.3): " custom_version
                    if [ "$(validate_version "$custom_version")" == "valid" ]; then
                        selected_version="$custom_version"
                        break 2
                    else
                        echo -e "\033[1;31mInvalid version or version does not exist. Please try again.\033[0m"
                    fi
                done
            elif [ "$choice" == "Q" ] || [ "$choice" == "q" ]; then
                echo -e "\033[1;31mExiting.\033[0m"
                exit 0
            else
                echo -e "\033[1;31mInvalid choice. Please try again.\033[0m"
                sleep 2
            fi
        done
    fi
    echo -e "\033[1;32mSelected version $selected_version for installation.\033[0m"
    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package unzip
    fi
    mkdir -p "$DATA_DIR/xray-core"
    cd "$DATA_DIR/xray-core"
    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"
    echo -e "\033[1;33mDownloading Xray-core version ${selected_version}...\033[0m"
    curl -fsSL "$xray_download_url" -o "$xray_filename" || die "Failed to download Xray-core from $xray_download_url"
    echo -e "\033[1;33mExtracting Xray-core...\033[0m"
    unzip -o "$xray_filename" >/dev/null 2>&1 || die "Failed to extract $xray_filename"
    rm -f "$xray_filename"
}
get_current_xray_core_version() {
    XRAY_BINARY="$DATA_DIR/xray-core/xray"
    if [ -f "$XRAY_BINARY" ]; then
        version_output=$("$XRAY_BINARY" -version 2>/dev/null)
        if [ $? -eq 0 ]; then
            version=$(echo "$version_output" | head -n1 | awk '{print $2}')
            echo "$version"
            return
        fi
    fi
    # If local binary is not found or failed, check in the Docker container
    CONTAINER_NAME="$APP_NAME"
    if docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        version_output=$(docker exec "$CONTAINER_NAME" xray -version 2>/dev/null)
        if [ $? -eq 0 ]; then
            # Extract the version number from the first line
            version=$(echo "$version_output" | head -n1 | awk '{print $2}')
            echo "$version (in container)"
            return
        fi
    fi
    echo "Not installed"
}
update_core_command() {
    check_running_as_root
    local core_version_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -v | --version)
            if [[ -z "${2:-}" ]]; then
                colorized_echo red "Error: --version requires a value."
                exit 1
            fi
            core_version_arg="$2"
            shift 2
            ;;
        -h | --help)
            colorized_echo red "Usage: node core-update [--version VERSION]"
            echo "  --version VERSION   Install a specific Xray-core version (use 'latest' for newest release)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
    done
    get_xray_core "$core_version_arg"
    # Ensure volumes match DATA_DIR when custom name is used
    service_name="node"
    existing_volume=$(yq eval -r ".services[\"$service_name\"].volumes[0]" "$APP_DIR/docker-compose.yml")
    if [ -n "$existing_volume" ] && [ "$existing_volume" != "null" ]; then
        # Extract container path (everything after the colon)
        if [[ "$existing_volume" == *:* ]]; then
            container_path="${existing_volume#*:}"
        else
            # If no colon found, use the existing volume as container path
            container_path="$existing_volume"
        fi
        # Update volumes to use DATA_DIR (which is based on APP_NAME)
        yq eval ".services[\"$service_name\"].volumes[0] = \"${DATA_DIR}:${container_path}\"" -i "$APP_DIR/docker-compose.yml"
        # Set XRAY_EXECUTABLE_PATH to the container path, not host path
        sed -i "s|^# *XRAY_EXECUTABLE_PATH *=.*|XRAY_EXECUTABLE_PATH= ${container_path}/xray-core/xray|" "$APP_DIR/.env"
        grep -q '^XRAY_EXECUTABLE_PATH=' "$APP_DIR/.env" || echo "XRAY_EXECUTABLE_PATH= ${container_path}/xray-core/xray" >>"$APP_DIR/.env"
    else
        # Fallback to APP_NAME-based path if no volume mapping is detected
        local fallback_path="${DATA_DIR}/xray-core/xray"
        sed -i "s|^# *XRAY_EXECUTABLE_PATH *=.*|XRAY_EXECUTABLE_PATH= ${fallback_path}|" "$APP_DIR/.env"
        grep -q '^XRAY_EXECUTABLE_PATH=' "$APP_DIR/.env" || echo "XRAY_EXECUTABLE_PATH= ${fallback_path}" >>"$APP_DIR/.env"
    fi
    # Restart node
    colorized_echo red "Restarting node..."
    restart_command -n --no-restart-service
    colorized_echo blue "Installation of XRAY-CORE version $selected_version completed."
}
edit_command() {
    detect_os
    check_editor
    if [ -f "$COMPOSE_FILE" ]; then
        $EDITOR "$COMPOSE_FILE"
    else
        colorized_echo red "Compose file not found at $COMPOSE_FILE"
        exit 1
    fi
}
edit_env_command() {
    detect_os
    check_editor
    if [ -f "$ENV_FILE" ]; then
        $EDITOR "$ENV_FILE"
    else
        colorized_echo red "Environment file not found at $ENV_FILE"
        exit 1
    fi
}
generate_bash_completion() {
    cat <<'EOF'
_node_completions()
{
    local cur cmds
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmds="up down restart status logs install update uninstall install-script uninstall-script core-update geofiles renew-cert version-script script-version edit edit-env completion service-install service-uninstall service-restart service-status service-logs service-update service-start service-stop"
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
}
EOF
    echo "complete -F _node_completions node.sh"
    echo "complete -F _node_completions $APP_NAME"
}

generate_zsh_completion() {
    cat <<EOF
#compdef $APP_NAME

local -a commands
commands=(
  up
  down
  restart
  status
  logs
  install
  update
  uninstall
  install-script
  uninstall-script
  core-update
  geofiles
  renew-cert
  version-script
  script-version
  edit
  edit-env
  completion
  service-install
  service-uninstall
  service-restart
  service-status
  service-logs
  service-update
  service-start
  service-stop
)

_describe 'command' commands
EOF
}

install_completion() {
    local bash_completion_dir="/etc/bash_completion.d"
    local bash_completion_file="$bash_completion_dir/$APP_NAME"
    local zsh_completion_dir="/usr/local/share/zsh/site-functions"
    local zsh_completion_file="$zsh_completion_dir/_$APP_NAME"

    colorized_echo blue "Installing shell completion for $APP_NAME..."

    mkdir -p "$bash_completion_dir"
    generate_bash_completion >"$bash_completion_file"
    chmod 644 "$bash_completion_file"
    colorized_echo green "✓ Bash completion installed to $bash_completion_file"

    mkdir -p "$zsh_completion_dir"
    generate_zsh_completion >"$zsh_completion_file"
    chmod 644 "$zsh_completion_file"
    colorized_echo green "✓ Zsh completion installed to $zsh_completion_file"
}
uninstall_completion() {
    local bash_completion_dir="/etc/bash_completion.d"
    local bash_completion_file="$bash_completion_dir/$APP_NAME"
    local zsh_completion_dir="/usr/local/share/zsh/site-functions"
    local zsh_completion_file="$zsh_completion_dir/_$APP_NAME"

    if [ -f "$bash_completion_file" ]; then
        rm "$bash_completion_file"
        colorized_echo yellow "Bash completion removed from $bash_completion_file"
    fi

    if [ -f "$zsh_completion_file" ]; then
        rm "$zsh_completion_file"
        colorized_echo yellow "Zsh completion removed from $zsh_completion_file"
    fi
}
usage() {
    colorized_echo blue "================================"
    colorized_echo magenta "       $APP_NAME Node CLI Help"
    colorized_echo blue "================================"
    colorized_echo cyan "Usage:"
    echo "  $APP_NAME [command] [options]"
    echo
    colorized_echo cyan "Options:"
    colorized_echo yellow "  -y, --yes       $(tput sgr0)✓  Use default answers for all prompts"
    colorized_echo yellow "  --name NAME     $(tput sgr0)✓  Target a specific node instance"
    echo
    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up                $(tput sgr0)✓  Start services"
    colorized_echo yellow "  down              $(tput sgr0)✓  Stop services"
    colorized_echo yellow "  restart           $(tput sgr0)✓  Restart services"
    colorized_echo yellow "  status            $(tput sgr0)✓  Show status"
    colorized_echo yellow "  logs              $(tput sgr0)✓  Show logs"
    colorized_echo yellow "  install           $(tput sgr0)✓  Install/reinstall node"
    colorized_echo yellow "  update            $(tput sgr0)✓  Update to latest version"
    colorized_echo yellow "  uninstall         $(tput sgr0)✓  Uninstall node"
    colorized_echo yellow "  install-script    $(tput sgr0)✓  Install node script"
    colorized_echo yellow "  uninstall-script  $(tput sgr0)✓  Uninstall node script"
    colorized_echo yellow "  service-install   $(tput sgr0)✓  Install and start pg-node-service (systemd)"
    colorized_echo yellow "  service-uninstall $(tput sgr0)✓  Remove pg-node-service (systemd)"
    colorized_echo yellow "  service-restart   $(tput sgr0)✓  Restart pg-node-service (systemd)"
    colorized_echo yellow "  service-status    $(tput sgr0)✓  Show pg-node-service status"
    colorized_echo yellow "  service-logs      $(tput sgr0)✓  View systemd service logs"
    colorized_echo yellow "  service-update    $(tput sgr0)✓  Update pg-node-service script"
    colorized_echo yellow "  service-start     $(tput sgr0)✓  Start pg-node-service (systemd)"
    colorized_echo yellow "  service-stop      $(tput sgr0)✓  Stop pg-node-service"
    colorized_echo yellow "  edit              $(tput sgr0)✓  Edit docker-compose.yml (via nano or vi)"
    colorized_echo yellow "  edit-env          $(tput sgr0)✓  Edit .env file (via nano or vi)"
    colorized_echo yellow "  core-update       $(tput sgr0)✓  Update/Change Xray core"
    colorized_echo yellow "  geofiles          $(tput sgr0)✓  Download geoip and geosite files for specific regions"
    colorized_echo yellow "  renew-cert        $(tput sgr0)✓  Regenerate SSL/TLS certificate"
    colorized_echo yellow "  version-script    $(tput sgr0)✓  Show script version and commit"
    colorized_echo yellow "  completion        $(tput sgr0)✓  Install bash/zsh tab completion"
    echo
    colorized_echo cyan "Restart Options:"
    colorized_echo yellow "  -n, --no-logs           $(tput sgr0)✓  Do not follow logs after restart"
    colorized_echo yellow "  --no-restart-service    $(tput sgr0)✓  Skip restarting systemd service"
    colorized_echo cyan "Update Options:"
    colorized_echo yellow "  --no-update-service     $(tput sgr0)✓  Skip updating systemd service"
    colorized_echo cyan "Uninstall Options:"
    colorized_echo yellow "  -y, --yes               $(tput sgr0)✓  Auto-confirm uninstall and data removal"
    colorized_echo yellow "  --name NAME             $(tput sgr0)✓  Uninstall specific node instance"
    colorized_echo cyan "Install Options:"
    colorized_echo yellow "  -v, --version VERSION   $(tput sgr0)✓  Install specific version"
    colorized_echo yellow "  --pre-release           $(tput sgr0)✓  Install pre-release version"
    colorized_echo yellow "  --name NAME             $(tput sgr0)✓  Install with custom name"
    colorized_echo yellow "  --override              $(tput sgr0)✓  Override existing installation"
    colorized_echo yellow "  --api-key KEY           $(tput sgr0)✓  Set API Key"
    colorized_echo yellow "  --use-rest              $(tput sgr0)✓  Use REST protocol instead of GRPC"
    colorized_echo yellow "  --use-grpc              $(tput sgr0)✓  Use GRPC protocol (default)"
    colorized_echo yellow "  --service-port PORT     $(tput sgr0)✓  Set service port"
    colorized_echo yellow "  --cert-path PATH        $(tput sgr0)✓  Set public certificate path"
    colorized_echo yellow "  --key-path PATH         $(tput sgr0)✓  Set private key path"
    colorized_echo yellow "  --self-signed           $(tput sgr0)✓  Generate self-signed certificate"
    colorized_echo yellow "  --api-port PORT         $(tput sgr0)✓  Set API port for node service"
    colorized_echo yellow "  --install-service       $(tput sgr0)✓  Install systemd service"
    colorized_echo yellow "  --no-install-service    $(tput sgr0)✓  Skip systemd service installation"
    colorized_echo yellow "  --san-entries ENTRIES   $(tput sgr0)✓  Add SAN entries (comma separated)"
    colorized_echo cyan "Core-update Options:"
    colorized_echo yellow "  --version VERSION       $(tput sgr0)✓  Update Xray-core to specific version (use 'latest' for newest)"
    colorized_echo cyan "Service Logs Options:"
    colorized_echo yellow "  -n, --no-follow         $(tput sgr0)✓  Show logs once without following"
    echo
    colorized_echo cyan "Node Information:"
    colorized_echo magenta "  Node IP: $NODE_IP_V4"
    SERVICE_PORT=$(grep '^SERVICE_PORT[[:space:]]*=' "$APP_DIR/.env" | sed 's/^SERVICE_PORT[[:space:]]*=[[:space:]]*//')
    colorized_echo magenta "  Service port: $SERVICE_PORT"
    colorized_echo magenta "  Cert file path: $SSL_CERT_FILE"
    API_KEY=$(grep '^API_KEY[[:space:]]*=' "$APP_DIR/.env" | sed 's/^API_KEY[[:space:]]*=[[:space:]]*//')
    colorized_echo magenta "  API Key : $API_KEY"
    echo
    current_version=$(get_current_xray_core_version)
    colorized_echo cyan "Current Xray-core version: " 1 # 1 for bold
    colorized_echo magenta "$current_version" 1
    echo
    colorized_echo blue "================================="
    echo
}
geofiles_command() {
    check_running_as_root
    mkdir -p "$DATA_DIR/assets"
    local restart_needed=false
    local args_provided=false
    if [[ $# -eq 0 ]]; then
        colorized_echo blue "No region specified, defaulting to Iran geofiles..."
        set -- "--iran"
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --iran)
            colorized_echo blue "Downloading Iran geofiles..."
            curl -sL "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geoip.dat" -o "$DATA_DIR/assets/geoip.dat"
            curl -sL "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geosite.dat" -o "$DATA_DIR/assets/geosite.dat"
            colorized_echo green "Iran geofiles downloaded to $DATA_DIR/assets"
            restart_needed=true
            args_provided=true
            shift
            ;;
        --russia)
            colorized_echo blue "Downloading Russia geofiles..."
            curl -sL "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat" -o "$DATA_DIR/assets/geoip.dat"
            curl -sL "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat" -o "$DATA_DIR/assets/geosite.dat"
            colorized_echo green "Russia geofiles downloaded to $DATA_DIR/assets"
            restart_needed=true
            args_provided=true
            shift
            ;;
        --china)
            colorized_echo blue "Downloading China geofiles..."
            curl -sL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -o "$DATA_DIR/assets/geoip.dat"
            curl -sL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o "$DATA_DIR/assets/geosite.dat"
            colorized_echo green "China geofiles downloaded to $DATA_DIR/assets"
            restart_needed=true
            args_provided=true
            shift
            ;;
        *)
            colorized_echo red "Unknown option: $1"
            exit 1
            ;;
        esac
    done
    if [ "$restart_needed" = true ]; then
        # Get the container path from the volume mapping
        service_name="node"
        existing_volume=$(yq eval -r ".services[\"$service_name\"].volumes[0]" "$APP_DIR/docker-compose.yml")
        if [ -n "$existing_volume" ] && [ "$existing_volume" != "null" ]; then
            # Extract container path (everything after the colon)
            if [[ "$existing_volume" == *:* ]]; then
                container_path="${existing_volume#*:}"
                # XRAY_ASSETS_PATH should point to the container path
                xray_assets_path="${container_path}/assets"
            else
                xray_assets_path="$DATA_DIR/assets"
            fi
        else
            xray_assets_path="$DATA_DIR/assets"
        fi
        sed -i "s|^# *XRAY_ASSETS_PATH *=.*|XRAY_ASSETS_PATH = $xray_assets_path|" "$ENV_FILE"
        grep -q '^XRAY_ASSETS_PATH =' "$ENV_FILE" || echo "XRAY_ASSETS_PATH = $xray_assets_path" >> "$ENV_FILE"
        colorized_echo blue "XRAY_ASSETS_PATH updated in $ENV_FILE"
        colorized_echo blue "Restarting node services..."
        restart_command -n --no-restart-service
        colorized_echo green "Geofiles updated and node restarted."
    else
        colorized_echo yellow "No geofiles specified for download."
    fi
}

renew_cert_command() {
    check_running_as_root
    # Check if node is installed
    if ! is_node_installed; then
        colorized_echo red "✗ Node is not installed. Please install node first."
        exit 1
    fi
    colorized_echo cyan "================================"
    colorized_echo cyan "Renewing SSL/TLS Certificate"
    colorized_echo cyan "================================"
    colorized_echo yellow "This will create a new SSL/TLS certificate for your node."
    
    # Check if existing certificate is self-signed (generated by script)
    local is_self_signed=false
    if [ -f "$SSL_CERT_FILE" ]; then
        # Check if certificate is self-signed (subject == issuer)
        local subject=$(openssl x509 -in "$SSL_CERT_FILE" -noout -subject 2>/dev/null | sed 's/^subject= *//')
        local issuer=$(openssl x509 -in "$SSL_CERT_FILE" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
        if [ "$subject" = "$issuer" ]; then
            is_self_signed=true
        fi
    fi
    
    # Only backup if it's a self-signed certificate (generated by script)
    if [ "$is_self_signed" = true ] && [ -f "$SSL_CERT_FILE" ]; then
        # Clean up old backups first (keep only the 2 most recent)
        local cert_backups=($(ls -t "${SSL_CERT_FILE}.backup."* 2>/dev/null | tail -n +3 2>/dev/null))
        local key_backups=($(ls -t "${SSL_KEY_FILE}.backup."* 2>/dev/null | tail -n +3 2>/dev/null))
        
        if [ ${#cert_backups[@]} -gt 0 ] || [ ${#key_backups[@]} -gt 0 ]; then
            colorized_echo blue "Cleaning up old backups (keeping 2 most recent)..."
            for backup in "${cert_backups[@]}"; do
                if [ -f "$backup" ]; then
                    rm -f "$backup" 2>/dev/null && colorized_echo cyan "  Removed old backup: $(basename "$backup")"
                fi
            done
            for backup in "${key_backups[@]}"; do
                if [ -f "$backup" ]; then
                    rm -f "$backup" 2>/dev/null && colorized_echo cyan "  Removed old backup: $(basename "$backup")"
                fi
            done
        fi
        
        # Create new backup
        local backup_cert="${SSL_CERT_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        local backup_key="${SSL_KEY_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        colorized_echo blue "Backing up existing self-signed certificate..."
        cp "$SSL_CERT_FILE" "$backup_cert" 2>/dev/null || true
        if [ -f "$SSL_KEY_FILE" ]; then
            cp "$SSL_KEY_FILE" "$backup_key" 2>/dev/null || true
        fi
        colorized_echo green "  ✓ Backup created: $(basename "$backup_cert")"
        if [ -f "$backup_key" ]; then
            colorized_echo green "  ✓ Backup created: $(basename "$backup_key")"
        fi
    elif [ -f "$SSL_CERT_FILE" ]; then
        # User-provided certificate - don't backup, just warn
        colorized_echo yellow "⚠ Existing certificate appears to be user-provided (not self-signed)."
        colorized_echo yellow "  It will be replaced with a new self-signed certificate."
        if [ "$AUTO_CONFIRM" != true ]; then
            read -p "Continue? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                colorized_echo yellow "Cancelled."
                exit 0
            fi
        fi
    fi
    
    # Generate new certificate
    gen_self_signed_cert
    
    # Ask user if they want to restart the node
    if docker ps --format '{{.Names}}' | grep -q "^$APP_NAME$"; then
        colorized_echo cyan ""
        colorized_echo yellow "The node needs to be restarted to apply the new certificate."
        local restart_choice=""
        if [ "$AUTO_CONFIRM" = true ]; then
            restart_choice="n"
        else
            read -p "Do you want to restart the node now? (y/N): " restart_choice
        fi
        if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
            colorized_echo blue "Restarting node to apply new certificate..."
            restart_command -n --no-restart-service
            colorized_echo green "✓ Node restarted with new certificate"
        else
            colorized_echo yellow "Skipped restart. Please restart the node manually to apply the new certificate."
            colorized_echo yellow "You can restart it later with: $APP_NAME restart"
        fi
    fi
    
    colorized_echo cyan ""
    colorized_echo cyan "================================"
    colorized_echo green "✓ Certificate renewal completed!"
    colorized_echo cyan "================================"
    colorized_echo magenta "Please use the following Certificate in pasarguard Panel (it's located in ${DATA_DIR}/certs):"
    cat "$SSL_CERT_FILE"
    colorized_echo cyan "================================"
    restart_command
}

pg_node_main() {
    # Bring existing env SSL paths in line with the current APP_NAME (safe no-op if not installed/default)
    sync_env_ssl_paths

    case "$1" in
    install)
        shift
        install_command "$@"
        ;;
    update)
        shift
        update_command "$@"
        ;;
    uninstall)
        uninstall_command
        ;;
    up)
        shift
        up_command "$@"
        ;;
    down)
        down_command
        ;;
    restart)
        shift
        restart_command "$@"
        ;;
    status)
        status_command
        ;;
    logs)
        shift
        logs_command "$@"
        ;;
    core-update)
        shift
        update_core_command "$@"
        ;;
    geofiles)
        shift
        geofiles_command "$@"
        ;;
    renew-cert)
        shift
        renew_cert_command "$@"
        ;;
    install-script)
        install_node_script
        ;;
    uninstall-script)
        uninstall_node_script
        ;;
    service-install)
        shift
        install_service_command "$@" || return 1
        ;;
    service-uninstall)
        uninstall_service_command || return 1
        ;;
    service-restart)
        restart_service_command
        ;;
    service-status)
        status_service_command
        ;;
    service-logs)
        shift
        service_logs_command "$@"
        ;;
    service-update)
        service_update_command
        ;;
    service-start)
        service_start_command
        ;;
    service-stop)
        service_stop_command
        ;;
    edit)
        edit_command
        ;;
    edit-env)
        edit_env_command
        ;;
    version-script | script-version)
        print_script_execution_header "pg-node" "$SCRIPT_COMMIT_SHA"
        ;;
    completion)
        check_running_as_root
        install_completion
        colorized_echo cyan ""
        colorized_echo yellow "To activate completion in this session:"
        colorized_echo cyan "  bash: source /etc/bash_completion.d/$APP_NAME"
        colorized_echo cyan "  zsh : autoload -Uz compinit && compinit"
        colorized_echo yellow "Or simply restart your terminal."
        ;;
    *)
        usage
        ;;
    esac
}

if [ "${PG_NODE_SOURCE_ONLY:-false}" != "true" ]; then
    pg_node_main "$@"
fi
