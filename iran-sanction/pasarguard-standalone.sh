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
DOCKER_MIRROR_PREPARED=false
DOCKER_MIRROR_PROMPTED=false

[ -f "$STANDALONE_ROOT_DIR/pasarguard.sh" ] || { printf 'Missing base script: %s\n' "$STANDALONE_ROOT_DIR/pasarguard.sh" >&2; exit 1; }
[ -f "$MIRROR_LIB" ] || { printf 'Missing mirror library: %s\n' "$MIRROR_LIB" >&2; exit 1; }

# shellcheck source=iran-sanction/mirror.sh
source "$MIRROR_LIB"

export PASARGUARD_SOURCE_ONLY=true
# shellcheck source=pasarguard.sh
source "$STANDALONE_ROOT_DIR/pasarguard.sh"

eval "$(declare -f detect_compose | sed '1s/detect_compose/original_detect_compose/')"

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

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

ensure_standalone_assets() {
    [ -f "$PASARGUARD_ENV_TEMPLATE" ] || die "Missing bundled env template: $PASARGUARD_ENV_TEMPLATE"
}

require_apt() {
    command -v apt-get >/dev/null 2>&1 || die "This standalone installer currently supports Debian/Ubuntu systems with apt-get only."
}

ensure_apt_prerequisites() {
    local cmd=""
    for cmd in curl awk sort sed grep cp install tar; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

prepare_apt_mirror() {
    local current_mirror=""
    local recalibrate_choice=""

    if [ "$APT_MIRROR_PREPARED" = true ]; then
        return
    fi

    if [[ "${COMMAND:-}" != "install" ]]; then
        current_mirror="$(get_current_apt_mirror 2>/dev/null || true)"
        if is_script_managed_apt_mirror "$current_mirror"; then
            if [ "$APT_MIRROR_PROMPTED" != "true" ]; then
                colorized_echo yellow "APT mirror is already set to a script-managed mirror: $current_mirror"
                read -r -p "Recalibrate APT mirror now? [y/N]: " recalibrate_choice
                APT_MIRROR_PROMPTED=true
                if [[ "$recalibrate_choice" =~ ^[Yy]$ ]]; then
                    require_apt
                    ensure_apt_prerequisites
                    colorized_echo blue "Selecting the best APT mirror"
                    select_and_apply_apt_mirror
                fi
            fi
        fi
        APT_MIRROR_PREPARED=true
        return
    fi
    require_apt
    ensure_apt_prerequisites
    colorized_echo blue "Selecting the best APT mirror"
    select_and_apply_apt_mirror
    APT_MIRROR_PREPARED=true
}

apt_install_packages() {
    local packages=("$@")
    require_apt
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

install_package() {
    local package="$1"
    prepare_apt_mirror
    colorized_echo blue "Installing $package with apt"
    apt_install_packages "$package"
}

ensure_docker_running() {
    if docker info >/dev/null 2>&1; then
        return
    fi
    colorized_echo blue "Starting Docker daemon"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
    fi
    docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is not running. Start Docker manually and retry."
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        ensure_docker_running
    else
        prepare_apt_mirror
        colorized_echo blue "Installing Docker with apt"
        apt_install_packages docker.io docker-compose-v2
        ensure_docker_running
    fi
    if [ "$DOCKER_MIRROR_PREPARED" != "true" ]; then
        colorized_echo blue "Selecting the best Docker mirror"
        select_and_apply_docker_mirror
        DOCKER_MIRROR_PREPARED=true
    fi
}

prepare_docker_mirror() {
    local current_mirror=""
    local recalibrate_choice=""

    if [ "$DOCKER_MIRROR_PREPARED" = "true" ]; then
        return
    fi

    if [[ "${COMMAND:-}" == "install" ]]; then
        colorized_echo blue "Selecting the best Docker mirror"
        select_and_apply_docker_mirror
        DOCKER_MIRROR_PREPARED=true
        return
    fi

    current_mirror="$(get_current_docker_mirror 2>/dev/null || true)"
    if is_script_managed_docker_mirror "$current_mirror"; then
        if [ "$DOCKER_MIRROR_PROMPTED" != "true" ]; then
            colorized_echo yellow "Docker mirror is already set to a script-managed mirror: $current_mirror"
            read -r -p "Recalibrate Docker mirror now? [y/N]: " recalibrate_choice
            DOCKER_MIRROR_PROMPTED=true
            if [[ "$recalibrate_choice" =~ ^[Yy]$ ]]; then
                colorized_echo blue "Selecting the best Docker mirror"
                select_and_apply_docker_mirror
            fi
        fi
        DOCKER_MIRROR_PREPARED=true
        return
    fi

    colorized_echo blue "Selecting the best Docker mirror"
    select_and_apply_docker_mirror
    DOCKER_MIRROR_PREPARED=true
}

install_yq() {
    return
}

set_pasarguard_panel_image() {
    local target_image="$1"
    [ -f "$COMPOSE_FILE" ] || die "Compose file not found: $COMPOSE_FILE"
    sed -i "0,/^[[:space:]]*image:[[:space:]]*pasarguard\/panel:.*/s#^[[:space:]]*image:[[:space:]]*pasarguard/panel:.*#    image: ${target_image}#" "$COMPOSE_FILE"
}

detect_compose() {
    if command -v docker >/dev/null 2>&1 && [ "$DOCKER_MIRROR_PREPARED" != "true" ] && [ "$(id -u)" = "0" ]; then
        prepare_docker_mirror
    fi
    ensure_docker_running
    original_detect_compose
}

install_pasarguard_script() {
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

update_pasarguard_script() {
    colorized_echo yellow "Automatic script updates are disabled in pasarguard-standalone."
}

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
