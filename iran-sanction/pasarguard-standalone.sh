#!/usr/bin/env bash
set -e

STANDALONE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STANDALONE_ROOT_DIR="$(cd -- "${STANDALONE_SCRIPT_DIR}/.." && pwd)"
if [ ! -f "$STANDALONE_ROOT_DIR/pasarguard.sh" ] && [ -f "/usr/local/lib/pasarguard-scripts/pasarguard-standalone/pasarguard.sh" ]; then
    STANDALONE_ROOT_DIR="/usr/local/lib/pasarguard-scripts/pasarguard-standalone"
fi

MIRROR_LIB="$STANDALONE_SCRIPT_DIR/mirror.sh"
if [ "$STANDALONE_ROOT_DIR" = "/usr/local/lib/pasarguard-scripts/pasarguard-standalone" ]; then
    MIRROR_LIB="$STANDALONE_ROOT_DIR/iran-sanction/mirror.sh"
fi

PASARGUARD_ENV_TEMPLATE="$STANDALONE_ROOT_DIR/pasarguard-assets/.env.example"
PASARGUARD_COMPOSE_DIR="$STANDALONE_ROOT_DIR/docker-compose"
STANDALONE_INSTALL_ROOT="/usr/local/lib/pasarguard-scripts/pasarguard-standalone"
APT_MIRROR_PREPARED=false
APT_MIRROR_PROMPTED=false
STANDALONE_PKG_MANAGER=""
STANDALONE_PKG_MANAGER_UPDATED=false
DOCKER_MIRROR_PREPARED=false
DOCKER_MIRROR_PROMPTED=false
COMMAND="${1:-}"

[ -f "$STANDALONE_ROOT_DIR/pasarguard.sh" ] || { printf 'Missing base script: %s\n' "$STANDALONE_ROOT_DIR/pasarguard.sh" >&2; exit 1; }
[ -f "$MIRROR_LIB" ] || { printf 'Missing mirror library: %s\n' "$MIRROR_LIB" >&2; exit 1; }

# shellcheck source=iran-sanction/mirror.sh
source "$MIRROR_LIB"

export PASARGUARD_SOURCE_ONLY=true
# shellcheck source=pasarguard.sh
source "$STANDALONE_ROOT_DIR/pasarguard.sh"

eval "$(declare -f detect_compose | sed '1s/detect_compose/original_detect_compose/')"

# Install a file to a destination path with specific permissions if different.
# Arguments:
#   $1 - File mode permissions (e.g. 755, 644).
#   $2 - Source file path.
#   $3 - Destination file path.
# Returns:
#   0 on success.
install_if_different() {
    local mode="$1"
    local source_path="$2"
    local dest_path="$3"

    [ -f "$source_path" ] || die "Required source file not found: $source_path"
    mkdir -p "$(dirname "$dest_path")"
    if [ "$source_path" = "$dest_path" ]; then
        return
    fi
    install -m "$mode" "$source_path" "$dest_path"
}

# Check if the provided argument is a non-negative integer.
# Arguments:
#   $1 - String to validate.
# Returns:
#   0 if integer, 1 otherwise.
is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Verify that bundled standalone asset templates exist.
# Returns:
#   0 if assets exist; terminates via die otherwise.
ensure_standalone_assets() {
    [ -f "$PASARGUARD_ENV_TEMPLATE" ] || die "Missing bundled env template: $PASARGUARD_ENV_TEMPLATE"
}

# Check whether apt-get is available on the system.
# Returns:
#   0 if apt-get exists, 1 otherwise.
has_apt() {
    command -v apt-get >/dev/null 2>&1
}

# Validate presence of required standard CLI utility binaries.
# Returns:
#   0 if all utilities exist; terminates via die otherwise.
ensure_package_prerequisites() {
    local cmd=""
    for cmd in curl awk sort sed grep cp install tar; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

# Detect system package manager (apt-get, dnf, or yum) for standalone mode.
# Returns:
#   0 if a supported package manager is found; terminates via die otherwise.
detect_standalone_package_manager() {
    if [ -n "$STANDALONE_PKG_MANAGER" ]; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        STANDALONE_PKG_MANAGER="apt-get"
    elif command -v dnf >/dev/null 2>&1; then
        STANDALONE_PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        STANDALONE_PKG_MANAGER="yum"
    else
        die "No supported package manager found. Install apt-get, dnf, or yum."
    fi
}

# Select and configure the best APT mirror for systems running in Iran.
# Returns:
#   0 on completion.
prepare_apt_mirror() {
    local current_mirror=""
    local recalibrate_choice=""

    if [ "$APT_MIRROR_PREPARED" = true ]; then
        return
    fi

    if [[ ! "${COMMAND:-}" =~ ^(install|update)$ ]]; then
        APT_MIRROR_PREPARED=true
        return
    fi

    if ! has_apt; then
        APT_MIRROR_PREPARED=true
        return
    fi

    ensure_package_prerequisites

    current_mirror="$(get_current_apt_mirror 2>/dev/null || true)"
    if is_script_managed_apt_mirror "$current_mirror" && [ "$APT_MIRROR_PROMPTED" != "true" ]; then
        colorized_echo yellow "APT mirror is already set to a script-managed mirror: $current_mirror"
        read -r -p "Recalibrate APT mirror now? [y/N]: " recalibrate_choice
        APT_MIRROR_PROMPTED=true
        if [[ ! "$recalibrate_choice" =~ ^[Yy]$ ]]; then
            APT_MIRROR_PREPARED=true
            return
        fi
    fi

    colorized_echo blue "Selecting the best APT mirror"
    select_and_apply_apt_mirror
    APT_MIRROR_PREPARED=true
}

# Install system packages using apt-get with mirror optimization.
# Arguments:
#   $@ - Package names to install.
# Returns:
#   0 on success.
apt_install_packages() {
    local packages=("$@")
    prepare_apt_mirror
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

# Initialize package manager caches and repository sources.
# Returns:
#   0 on success.
prepare_standalone_package_manager() {
    detect_standalone_package_manager

    if [ "$STANDALONE_PKG_MANAGER_UPDATED" = true ]; then
        return
    fi

    if [ "$STANDALONE_PKG_MANAGER" = "apt-get" ]; then
        prepare_apt_mirror
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
    else
        "$STANDALONE_PKG_MANAGER" -y -q makecache >/dev/null 2>&1 || true
        "$STANDALONE_PKG_MANAGER" install -y -q epel-release >/dev/null 2>&1 || true
    fi

    STANDALONE_PKG_MANAGER_UPDATED=true
}

# Install system packages using the detected standalone package manager.
# Arguments:
#   $@ - Package names to install.
# Returns:
#   0 on success.
standalone_install_packages() {
    local packages=("$@")

    prepare_standalone_package_manager
    case "$STANDALONE_PKG_MANAGER" in
    apt-get)
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
        ;;
    dnf | yum)
        "$STANDALONE_PKG_MANAGER" install -y -q "${packages[@]}"
        ;;
    *)
        die "Unsupported package manager: $STANDALONE_PKG_MANAGER"
        ;;
    esac
}

# Install a single package using the standalone package manager.
# Arguments:
#   $1 - Package name to install.
# Returns:
#   0 on success.
install_package() {
    local package="$1"
    detect_standalone_package_manager
    colorized_echo blue "Installing $package with $STANDALONE_PKG_MANAGER"
    standalone_install_packages "$package"
}

# Ensure the Docker service daemon is active and running.
# Returns:
#   0 on success; terminates via die if Docker cannot run.
ensure_docker_running() {
    if docker info >/dev/null 2>&1; then
        return
    fi
    colorized_echo blue "Starting Docker daemon"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable --now docker >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
    fi
    docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is not running. Start Docker manually and retry."
}

# Install Docker Engine and dependencies if not already installed.
# Returns:
#   0 on success; terminates via die on failure.
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        ensure_docker_running
    else
        detect_standalone_package_manager
        if [ "$STANDALONE_PKG_MANAGER" = "apt-get" ]; then
            colorized_echo blue "Installing Docker with apt"
            apt_install_packages docker.io docker-compose-v2
        else
            colorized_echo blue "Installing Docker with Docker's Linux installer"
            command -v curl >/dev/null 2>&1 || standalone_install_packages curl
            if ! bash -o pipefail -c 'curl -fsSL https://get.docker.com | sh'; then
                die "Failed to install Docker"
            fi
        fi
        ensure_docker_running
    fi
    prepare_docker_mirror
}

# Configure optimal Docker registry mirror for Iranian infrastructure.
# Returns:
#   0 on success.
prepare_docker_mirror() {
    local current_mirror=""
    local recalibrate_choice=""

    if [ "$DOCKER_MIRROR_PREPARED" = "true" ]; then
        return
    fi

    if [[ ! "${COMMAND:-}" =~ ^(install|update)$ ]]; then
        DOCKER_MIRROR_PREPARED=true
        return
    fi

    current_mirror="$(get_current_docker_mirror 2>/dev/null || true)"
    if is_script_managed_docker_mirror "$current_mirror" && [ "$DOCKER_MIRROR_PROMPTED" != "true" ]; then
        colorized_echo yellow "Docker mirror is already set to a script-managed mirror: $current_mirror"
        read -r -p "Recalibrate Docker mirror now? [y/N]: " recalibrate_choice
        DOCKER_MIRROR_PROMPTED=true
        if [[ ! "$recalibrate_choice" =~ ^[Yy]$ ]]; then
            DOCKER_MIRROR_PREPARED=true
            return
        fi
    fi

    colorized_echo blue "Selecting the best Docker mirror"
    select_and_apply_docker_mirror
    DOCKER_MIRROR_PREPARED=true
}

# No-op override for yq dependency since compose files are bundled locally.
# Returns:
#   0 on success.
install_yq() {
    return
}

# Update the PasarGuard panel container image tag in docker-compose.yml.
# Arguments:
#   $1 - Full Docker image reference (e.g. pasarguard/panel:v1.2.3).
# Returns:
#   0 on success; terminates via die if compose file is missing.
set_pasarguard_panel_image() {
    local target_image="$1"
    [ -f "$COMPOSE_FILE" ] || die "Compose file not found: $COMPOSE_FILE"
    sed -i "0,/^[[:space:]]*image:[[:space:]]*pasarguard\/panel:.*/s#^[[:space:]]*image:[[:space:]]*pasarguard/panel:.*#    image: ${target_image}#" "$COMPOSE_FILE"
}

# Prepare Docker daemon and mirror if needed, then invoke original compose detection.
# Returns:
#   0 on successful detection.
detect_compose() {
    if [[ "${COMMAND:-}" =~ ^(install|update)$ ]] && command -v docker >/dev/null 2>&1 && [ "$DOCKER_MIRROR_PREPARED" != "true" ] && [ "$(id -u)" = "0" ]; then
        prepare_docker_mirror
    fi
    ensure_docker_running
    original_detect_compose
}

# Install the standalone PasarGuard CLI script and all supporting bundled files.
# Returns:
#   0 on success; terminates via die on missing files.
install_pasarguard_script() {
    print_script_execution_header "pasarguard-standalone" "$SCRIPT_COMMIT_SHA" "install"
    local target_path="/usr/local/bin/pasarguard"
    local wrapper_source="$STANDALONE_SCRIPT_DIR/pasarguard-standalone.sh"
    local installed_wrapper="$STANDALONE_INSTALL_ROOT/iran-sanction/pasarguard-standalone.sh"

    if [ ! -f "$wrapper_source" ]; then
        wrapper_source="$installed_wrapper"
    fi
    [ -f "$wrapper_source" ] || die "Standalone pasarguard wrapper not found: $wrapper_source"

    colorized_echo blue "Installing standalone pasarguard script"
    ensure_standalone_assets
    mkdir -p "$STANDALONE_INSTALL_ROOT/lib" "$STANDALONE_INSTALL_ROOT/iran-sanction" "$STANDALONE_INSTALL_ROOT/docker-compose" "$STANDALONE_INSTALL_ROOT/pasarguard-assets"
    install_if_different 755 "$wrapper_source" "$target_path"
    install_if_different 755 "$wrapper_source" "$installed_wrapper"
    install_if_different 644 "$STANDALONE_ROOT_DIR/pasarguard.sh" "$STANDALONE_INSTALL_ROOT/pasarguard.sh"
    if [ -f "$STANDALONE_ROOT_DIR/pg-node.sh" ]; then
        install_if_different 644 "$STANDALONE_ROOT_DIR/pg-node.sh" "$STANDALONE_INSTALL_ROOT/pg-node.sh"
    fi
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/common.sh" "$STANDALONE_INSTALL_ROOT/lib/common.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/system.sh" "$STANDALONE_INSTALL_ROOT/lib/system.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/docker.sh" "$STANDALONE_INSTALL_ROOT/lib/docker.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/github.sh" "$STANDALONE_INSTALL_ROOT/lib/github.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/env.sh" "$STANDALONE_INSTALL_ROOT/lib/env.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/pasarguard-backup.sh" "$STANDALONE_INSTALL_ROOT/lib/pasarguard-backup.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/pasarguard-restore.sh" "$STANDALONE_INSTALL_ROOT/lib/pasarguard-restore.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/iran-sanction/mirror.sh" "$STANDALONE_INSTALL_ROOT/iran-sanction/mirror.sh"
    if [ -f "$STANDALONE_ROOT_DIR/iran-sanction/pg-node-standalone.sh" ]; then
        install_if_different 755 "$STANDALONE_ROOT_DIR/iran-sanction/pg-node-standalone.sh" "$STANDALONE_INSTALL_ROOT/iran-sanction/pg-node-standalone.sh"
    fi
    install_if_different 644 "$PASARGUARD_ENV_TEMPLATE" "$STANDALONE_INSTALL_ROOT/pasarguard-assets/.env.example"
    install_if_different 644 "$STANDALONE_ROOT_DIR/docker-compose/pasarguard-mysql.yml" "$STANDALONE_INSTALL_ROOT/docker-compose/pasarguard-mysql.yml"
    install_if_different 644 "$STANDALONE_ROOT_DIR/docker-compose/pasarguard-mariadb.yml" "$STANDALONE_INSTALL_ROOT/docker-compose/pasarguard-mariadb.yml"
    install_if_different 644 "$STANDALONE_ROOT_DIR/docker-compose/pasarguard-postgresql.yml" "$STANDALONE_INSTALL_ROOT/docker-compose/pasarguard-postgresql.yml"
    install_if_different 644 "$STANDALONE_ROOT_DIR/docker-compose/pasarguard-timescaledb.yml" "$STANDALONE_INSTALL_ROOT/docker-compose/pasarguard-timescaledb.yml"
    if [ -f "$STANDALONE_ROOT_DIR/docker-compose/pasarguard-sqlite.yml" ]; then
        install_if_different 644 "$STANDALONE_ROOT_DIR/docker-compose/pasarguard-sqlite.yml" "$STANDALONE_INSTALL_ROOT/docker-compose/pasarguard-sqlite.yml"
    fi
    colorized_echo green "Standalone pasarguard script installed successfully at $target_path"
}

# Remove installed standalone PasarGuard script binary and support directory.
# Returns:
#   0 on completion.
uninstall_pasarguard_script() {
    if [ -f "/usr/local/bin/pasarguard" ]; then
        colorized_echo yellow "Removing pasarguard script"
        rm "/usr/local/bin/pasarguard"
    fi
    if [ -d "$STANDALONE_INSTALL_ROOT" ]; then
        colorized_echo yellow "Removing standalone support files from $STANDALONE_INSTALL_ROOT"
        rm -r "$STANDALONE_INSTALL_ROOT"
    fi
}

# Install PasarGuard panel using bundled Docker Compose templates and configure database.
# Arguments:
#   $1 - PasarGuard release version string.
#   $2 - Major version number.
#   $3 - Database engine type (sqlite, mysql, mariadb, postgresql, timescaledb).
# Returns:
#   0 on success; exits with code 1 or terminates on configuration errors.
install_pasarguard() {
    local pasarguard_version="$1"
    local major_version="$2"
    local database_type="$3"
    local target_image=""
    local compose_source=""
    local db_name=""
    local db_driver_scheme=""

    ensure_standalone_assets
    mkdir -p "$DATA_DIR" "$APP_DIR"
    colorized_echo blue "Copying bundled .env file"
    cp "$PASARGUARD_ENV_TEMPLATE" "$APP_DIR/.env"
    # Restrict .env to owner-only before writing DB/pgAdmin/MySQL-root secrets.
    harden_secret_file "$APP_DIR/.env"
    colorized_echo green "File saved in $APP_DIR/.env"

    if [[ "$database_type" =~ ^(mysql|mariadb|postgresql|timescaledb)$ ]]; then
        case "$database_type" in
        mysql) db_name="MySQL" ;;
        mariadb) db_name="MariaDB" ;;
        timescaledb) db_name="TimeScaleDB" ;;
        *) db_name="PostgreSQL" ;;
        esac

        echo "----------------------------"
        colorized_echo red "Using $db_name as database"
        echo "----------------------------"
        colorized_echo blue "Copying bundled compose file for pasarguard+$db_name"
        compose_source="$PASARGUARD_COMPOSE_DIR/pasarguard-$database_type.yml"
        [ -f "$compose_source" ] || die "Missing bundled compose file: $compose_source"
        cp "$compose_source" "$COMPOSE_FILE"

        sed -i 's~^SQLALCHEMY_DATABASE_URL = "sqlite~#&~' "$APP_DIR/.env"
        DB_NAME="pasarguard"
        DB_USER="pasarguard"
        prompt_for_db_password

        echo "" >>"$ENV_FILE"
        echo "# Database configuration" >>"$ENV_FILE"
        echo "DB_NAME=\"${DB_NAME}\"" >>"$ENV_FILE"
        echo "DB_USER=\"${DB_USER}\"" >>"$ENV_FILE"
        echo "DB_PASSWORD=\"${DB_PASSWORD}\"" >>"$ENV_FILE"

        if [[ "$database_type" == "postgresql" || "$database_type" == "timescaledb" ]]; then
            DB_PORT="6432"
            prompt_for_pgadmin_password
            echo "" >>"$ENV_FILE"
            echo "# PGAdmin configuration" >>"$ENV_FILE"
            echo "PGADMIN_EMAIL=\"pg@github.io\"" >>"$ENV_FILE"
            echo "PGADMIN_PASSWORD=\"${PGADMIN_PASSWORD}\"" >>"$ENV_FILE"
        else
            colorized_echo green "phpMyAdmin address: 0.0.0.0:8010"
            DB_PORT="3306"
            MYSQL_ROOT_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)
            echo "MYSQL_ROOT_PASSWORD=\"$MYSQL_ROOT_PASSWORD\"" >>"$ENV_FILE"
        fi

        if [[ "$database_type" =~ ^(postgresql|timescaledb)$ ]]; then
            if [ "$major_version" -lt 1 ]; then
                colorized_echo red "Error: --database $database_type is only supported in v1.0.0 and later."
                colorized_echo yellow "Use --pre-release or --version v1.x.y, or choose mysql/mariadb/sqlite for v0.x."
                exit 1
            fi
            db_driver_scheme="postgresql+asyncpg"
        else
            db_driver_scheme="mysql+asyncmy"
        fi

        SQLALCHEMY_DATABASE_URL="${db_driver_scheme}://${DB_USER}:${DB_PASSWORD}@127.0.0.1:${DB_PORT}/${DB_NAME}"
        echo "" >>"$ENV_FILE"
        echo "# SQLAlchemy Database URL" >>"$ENV_FILE"
        echo "SQLALCHEMY_DATABASE_URL=\"$SQLALCHEMY_DATABASE_URL\"" >>"$ENV_FILE"
    else
        echo "----------------------------"
        colorized_echo red "Using SQLite as database"
        echo "----------------------------"
        compose_source="$PASARGUARD_COMPOSE_DIR/pasarguard-sqlite.yml"
        [ -f "$compose_source" ] || die "Missing bundled compose file: $compose_source"
        cp "$compose_source" "$COMPOSE_FILE"
        sed -i 's/^# \(SQLALCHEMY_DATABASE_URL = .*\)$/\1/' "$APP_DIR/.env"

        if is_integer "$major_version" && [ "$major_version" -eq 1 ]; then
            db_driver_scheme="sqlite+aiosqlite"
        elif grep -Eq '^[#[:space:]]*SQLALCHEMY_DATABASE_URL[[:space:]]*=[[:space:]]*"sqlite\+aiosqlite' "$APP_DIR/.env"; then
            db_driver_scheme="sqlite+aiosqlite"
        else
            db_driver_scheme="sqlite"
        fi

        sed -i "s~\(SQLALCHEMY_DATABASE_URL = \).*~\1\"${db_driver_scheme}:////${DATA_DIR}/db.sqlite3\"~" "$APP_DIR/.env"
    fi

    target_image="pasarguard/panel:${pasarguard_version}"
    if [ "$pasarguard_version" = "latest" ]; then
        target_image="pasarguard/panel:latest"
    fi
    set_pasarguard_panel_image "$target_image"
    colorized_echo green "File saved in $APP_DIR/docker-compose.yml"
    colorized_echo green "pasarguard installed successfully"
}

# Warn user that automatic script updates are disabled in standalone distribution.
# Returns:
#   0 on completion.
update_pasarguard_script() {
    colorized_echo yellow "Automatic script updates are disabled in pasarguard-standalone."
}

# Update PasarGuard Docker services to latest version and restart containers.
# Returns:
#   0 on success; exits with code 1 if PasarGuard is not installed.
update_command() {
    check_running_as_root
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi
    detect_compose
    uninstall_completion
    install_completion
    colorized_echo blue "Pulling latest version"
    update_pasarguard
    colorized_echo blue "Restarting pasarguard's services"
    down_pasarguard
    up_pasarguard
    colorized_echo blue "pasarguard updated successfully"
}

# Install the bundled standalone pg-node script and run its installer.
# Returns:
#   0 on success; terminates via die if bundled script is missing.
install_node_command() {
    local standalone_node="$STANDALONE_ROOT_DIR/iran-sanction/pg-node-standalone.sh"
    if [ "$STANDALONE_ROOT_DIR" = "$STANDALONE_INSTALL_ROOT" ]; then
        standalone_node="$STANDALONE_INSTALL_ROOT/iran-sanction/pg-node-standalone.sh"
    fi
    [ -f "$standalone_node" ] || die "Bundled standalone pg-node installer not found: $standalone_node"
    chmod +x "$standalone_node"
    "$standalone_node" install-script
    pg-node install
}

pasarguard_main "$@"
