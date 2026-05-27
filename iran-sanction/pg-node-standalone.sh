#!/usr/bin/env bash
set -e

STANDALONE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STANDALONE_ROOT_DIR="$(cd -- "${STANDALONE_SCRIPT_DIR}/.." && pwd)"
if [ ! -f "$STANDALONE_ROOT_DIR/pg-node.sh" ] && [ -f "/usr/local/lib/pasarguard-scripts/pg-node-standalone/pg-node.sh" ]; then
    STANDALONE_ROOT_DIR="/usr/local/lib/pasarguard-scripts/pg-node-standalone"
fi

MIRROR_LIB="$STANDALONE_SCRIPT_DIR/mirror.sh"
if [ "$STANDALONE_ROOT_DIR" = "/usr/local/lib/pasarguard-scripts/pg-node-standalone" ]; then
    MIRROR_LIB="$STANDALONE_ROOT_DIR/iran-sanction/mirror.sh"
fi
LOCAL_ENV_TEMPLATE="$STANDALONE_ROOT_DIR/pg-node-assets/.env.example"
LOCAL_COMPOSE_TEMPLATE="$STANDALONE_ROOT_DIR/docker-compose/node.yml"
STANDALONE_INSTALL_ROOT="/usr/local/lib/pasarguard-scripts/pg-node-standalone"
APT_MIRROR_PREPARED=false
APT_MIRROR_PROMPTED=false
DOCKER_MIRROR_PREPARED=false
DOCKER_MIRROR_PROMPTED=false
COMMAND="${1:-}"

if [ ! -f "$STANDALONE_ROOT_DIR/pg-node.sh" ]; then
    printf 'Missing base script: %s\n' "$STANDALONE_ROOT_DIR/pg-node.sh" >&2
    exit 1
fi
if [ ! -f "$MIRROR_LIB" ]; then
    printf 'Missing mirror library: %s\n' "$MIRROR_LIB" >&2
    exit 1
fi

# shellcheck source=iran-sanction/mirror.sh
source "$MIRROR_LIB"

export PG_NODE_SCRIPT_DIR="$STANDALONE_ROOT_DIR"
export PG_NODE_SOURCE_ONLY=true
# shellcheck source=pg-node.sh
source "$STANDALONE_ROOT_DIR/pg-node.sh"

NODE_IP_V4=$(curl -s -4 --fail --max-time 5 ipify.ir 2>/dev/null || echo "")
NODE_IP_V6=$(curl -s -6 --fail --max-time 5 ipify.ir 2>/dev/null || echo "")
NODE_IP="${NODE_IP_V4:-}"
if [ -z "$NODE_IP" ]; then
    NODE_IP="${NODE_IP_V6:-}"
fi
if [ -z "$NODE_IP" ]; then
    NODE_IP="127.0.0.1"
fi

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

ensure_standalone_assets() {
    [ -f "$LOCAL_ENV_TEMPLATE" ] || die "Missing bundled env template: $LOCAL_ENV_TEMPLATE"
    [ -f "$LOCAL_COMPOSE_TEMPLATE" ] || die "Missing bundled compose template: $LOCAL_COMPOSE_TEMPLATE"
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

    if [[ ! "${COMMAND:-}" =~ ^(install|update)$ ]]; then
        APT_MIRROR_PREPARED=true
        return
    fi

    require_apt
    ensure_apt_prerequisites

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

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        ensure_docker_running
        return
    fi
    prepare_apt_mirror
    colorized_echo blue "Installing Docker with apt"
    apt_install_packages docker.io docker-compose-v2
    prepare_docker_mirror
    ensure_docker_running
}

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

install_yq() {
    return
}

require_systemd() {
    die "systemd support is disabled in pg-node-standalone for now."
}

service_installed() {
    return 1
}

restart_service_if_installed() {
    return
}

update_service_if_installed() {
    return
}

detect_compose() {
    if [[ "${COMMAND:-}" =~ ^(install|update)$ ]] && command -v docker >/dev/null 2>&1 && [ "$DOCKER_MIRROR_PREPARED" != "true" ] && [ "$(id -u)" = "0" ]; then
        prepare_docker_mirror
    fi
    ensure_docker_running
    original_detect_compose
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

    if ! docker info >/dev/null 2>&1; then
        die "Docker is installed but the daemon is not running. Start Docker manually and retry."
    fi
}

install_node_service_script() {
    require_systemd
}

install_node_script() {
    local target_path="/usr/local/bin/$APP_NAME"
    local wrapper_source="$STANDALONE_SCRIPT_DIR/pg-node-standalone.sh"
    local installed_wrapper="$STANDALONE_INSTALL_ROOT/iran-sanction/pg-node-standalone.sh"

    if [ ! -f "$wrapper_source" ]; then
        wrapper_source="$installed_wrapper"
    fi
    [ -f "$wrapper_source" ] || die "Standalone pg-node wrapper not found: $wrapper_source"

    colorized_echo blue "Installing standalone node script"
    ensure_standalone_assets
    mkdir -p "$STANDALONE_INSTALL_ROOT/lib" "$STANDALONE_INSTALL_ROOT/iran-sanction" "$STANDALONE_INSTALL_ROOT/docker-compose" "$STANDALONE_INSTALL_ROOT/pg-node-assets"
    install_if_different 755 "$wrapper_source" "$target_path"
    install_if_different 755 "$wrapper_source" "$installed_wrapper"
    install_if_different 644 "$STANDALONE_ROOT_DIR/pg-node.sh" "$STANDALONE_INSTALL_ROOT/pg-node.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/common.sh" "$STANDALONE_INSTALL_ROOT/lib/common.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/system.sh" "$STANDALONE_INSTALL_ROOT/lib/system.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/docker.sh" "$STANDALONE_INSTALL_ROOT/lib/docker.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/lib/github.sh" "$STANDALONE_INSTALL_ROOT/lib/github.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/iran-sanction/mirror.sh" "$STANDALONE_INSTALL_ROOT/iran-sanction/mirror.sh"
    install_if_different 644 "$STANDALONE_ROOT_DIR/docker-compose/node.yml" "$STANDALONE_INSTALL_ROOT/docker-compose/node.yml"
    install_if_different 644 "$STANDALONE_ROOT_DIR/pg-node-assets/.env.example" "$STANDALONE_INSTALL_ROOT/pg-node-assets/.env.example"
    colorized_echo green "Standalone node script installed successfully at $target_path"
}

uninstall_node_script() {
    local target_path="/usr/local/bin/$APP_NAME"

    if [ -f "$target_path" ]; then
        colorized_echo yellow "Removing standalone node script"
        rm "$target_path"
    fi
    if [ -d "$STANDALONE_INSTALL_ROOT" ]; then
        colorized_echo yellow "Removing standalone support files from $STANDALONE_INSTALL_ROOT"
        rm -r "$STANDALONE_INSTALL_ROOT"
    fi
}

get_occupied_ports() {
    if command -v ss >/dev/null 2>&1; then
        OCCUPIED_PORTS=$(ss -tuln | awk '{print $5}' | grep -Eo '[0-9]+$' | sort | uniq)
    elif command -v netstat >/dev/null 2>&1; then
        OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort | uniq)
    else
        colorized_echo yellow "Neither ss nor netstat found. Attempting to install net-tools with apt."
        install_package net-tools
        OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort | uniq)
    fi
}

install_node() {
    local node_version="$1"
    local ssl_cert_env="$DATA_DIR/certs/ssl_cert.pem"
    local ssl_key_env="$DATA_DIR/certs/ssl_key.pem"

    ensure_standalone_assets
    colorized_echo blue "Creating directories..."
    mkdir -p "$DATA_DIR" "$DATA_DIR/certs" "$APP_DIR"
    colorized_echo green "Directories created"
    colorized_echo yellow "A self-signed certificate will be generated by default."
    if [ "$AUTO_CONFIRM" = true ]; then
        use_public_cert=""
    else
        read -r -p "Do you want to use your own public certificate instead? (Y/n): " use_public_cert
    fi
    if [[ "$use_public_cert" =~ ^[Yy]$ ]]; then
        read_and_save_file "Please paste the content OR the path to the Client Certificate file." "$SSL_CERT_FILE" 1
        colorized_echo blue "Certificate saved to $SSL_CERT_FILE"
        read_and_save_file "Please paste the content OR the path to the Private Key file." "$SSL_KEY_FILE" 1
        colorized_echo blue "Private key saved to $SSL_KEY_FILE"
    else
        gen_self_signed_cert
        colorized_echo blue "self-signed certificate successfully generated"
    fi
    if [ "$AUTO_CONFIRM" = true ]; then
        API_KEY=""
    else
        read -p "Enter your API Key (must be a valid UUID (any version), leave blank to auto-generate): " -r API_KEY
    fi
    if [[ -z "$API_KEY" ]]; then
        API_KEY=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || python -c "import uuid; print(uuid.uuid4())")
        colorized_echo green "No API Key provided. A random UUID version 4 has been generated"
    fi
    if [ "$AUTO_CONFIRM" = true ]; then
        use_rest=""
    else
        read -p "GRPC is recommended by default. Do you want to use REST protocol instead? (Y/n): " -r use_rest
    fi
    if [[ "$use_rest" =~ ^[Yy]$ ]]; then
        USE_REST=1
    else
        USE_REST=0
    fi
    get_occupied_ports
    if [ "$AUTO_CONFIRM" = true ]; then
        SERVICE_PORT=62050
        if is_port_occupied "$SERVICE_PORT"; then
            colorized_echo red "Port $SERVICE_PORT is already in use. Run without -y to choose another port."
            exit 1
        fi
    else
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
    colorized_echo blue "Copying bundled .env and compose file"
    cp "$LOCAL_ENV_TEMPLATE" "$APP_DIR/.env"
    cp "$LOCAL_COMPOSE_TEMPLATE" "$APP_DIR/docker-compose.yml"
    sed -i "s/^SERVICE_PORT *= *.*/SERVICE_PORT= ${SERVICE_PORT}/" "$APP_DIR/.env"
    sed -i "s/^API_KEY *= *.*/API_KEY= ${API_KEY}/" "$APP_DIR/.env"
    if [ "$USE_REST" -eq 1 ]; then
        sed -i 's/^# \(SERVICE_PROTOCOL *=.*\)/SERVICE_PROTOCOL= "rest"/' "$APP_DIR/.env"
    else
        sed -i 's/^# \(SERVICE_PROTOCOL *=.*\)/SERVICE_PROTOCOL= "grpc"/' "$APP_DIR/.env"
    fi
    sed -i "s|^SSL_CERT_FILE *=.*|SSL_CERT_FILE= ${ssl_cert_env}|" "$APP_DIR/.env"
    sed -i "s|^SSL_KEY_FILE *=.*|SSL_KEY_FILE= ${ssl_key_env}|" "$APP_DIR/.env"
    colorized_echo green "Bundled node configuration prepared successfully"
}

update_node_script() {
    colorized_echo yellow "Automatic script updates are disabled in pg-node-standalone."
}

install_command() {
    check_running_as_root
    local node_version="latest"
    local node_version_set="false"
    local key=""

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
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
    done

    if is_node_installed; then
        colorized_echo red "node is already installed at $APP_DIR"
        if [ "$AUTO_CONFIRM" = true ]; then
            REPLY=""
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
    else
        ensure_docker_running
    fi
    install_yq
    detect_compose

    check_version_exists() {
        local version="$1"
        local repo_url="https://api.github.com/repos/PasarGuard/node/releases"
        
        # In standalone mode, we trust 'latest' and 'pre-release' and 'dev' without checking GitHub
        if [[ "$version" == "latest" || "$version" == "pre-release" || "$version" == "dev" ]]; then
            return 0
        fi

        # For specific versions, try to verify but proceed if GitHub is unreachable
        local http_code
        http_code=$(curl -s -o /dev/null --max-time 5 -w "%{http_code}" "${repo_url}/tags/${version}" 2>/dev/null || echo "000")
        
        if [[ "$http_code" == "200" || "$http_code" == "000" ]]; then
            if [[ "$http_code" == "000" ]]; then
                colorized_echo yellow "  ⚠ Unable to reach GitHub to verify version $version. Proceeding anyway."
            fi
            return 0
        fi

        return 1
    }

    if [[ "$node_version" == "latest" || "$node_version" == "pre-release" || "$node_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if check_version_exists "$node_version"; then
            colorized_echo cyan "================================"
            colorized_echo cyan "Installing PasarGuard Node"
            colorized_echo cyan "Version: $node_version"
            colorized_echo cyan "================================"
            install_node "$node_version"
            colorized_echo green "Node installation completed for version: $node_version"
        else
            colorized_echo red "Version $node_version does not exist. Please enter a valid version."
            exit 1
        fi
    else
        colorized_echo red "Invalid version format. Please enter a valid version (e.g. v1.0.0)"
        exit 1
    fi

    install_node_script
    install_completion
    up_node
    show_node_logs
    colorized_echo yellow "Systemd integration is disabled in pg-node-standalone."
    colorized_echo blue "================================"
    colorized_echo magenta "node is set up with the following IP: $NODE_IP and Port: $SERVICE_PORT."
    colorized_echo magenta "Please use the following Certificate in pasarguard Panel (it's located in ${DATA_DIR}/certs):"
    cat "$SSL_CERT_FILE"
    colorized_echo blue "================================"
    colorized_echo magenta "Next, use the API Key (UUID v4) in pasarguard Panel: "
    colorized_echo red "${API_KEY}"
}

update_command() {
    check_running_as_root
    if ! is_node_installed; then
        colorized_echo red "node not installed!"
        exit 1
    fi
    detect_compose
    colorized_echo blue "Pulling latest node image"
    update_node
    colorized_echo blue "Restarting node services"
    down_node
    up_node
    colorized_echo blue "node updated successfully"
}

usage() {
    colorized_echo blue "================================"
    colorized_echo magenta "   $APP_NAME Standalone Node CLI"
    colorized_echo blue "================================"
    colorized_echo cyan "Usage:"
    echo "  $APP_NAME [command] [options]"
    echo
    colorized_echo cyan "Options:"
    colorized_echo yellow "  -y, --yes       Use default answers for all prompts"
    colorized_echo yellow "  --name NAME     Target a specific node instance"
    echo
    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up                Start services"
    colorized_echo yellow "  down              Stop services"
    colorized_echo yellow "  restart           Restart services"
    colorized_echo yellow "  status            Show status"
    colorized_echo yellow "  logs              Show logs"
    colorized_echo yellow "  install           Install/reinstall node"
    colorized_echo yellow "  update            Update node containers only"
    colorized_echo yellow "  uninstall         Uninstall node"
    colorized_echo yellow "  install-script    Install standalone node script"
    colorized_echo yellow "  uninstall-script  Uninstall standalone node script"
    colorized_echo yellow "  service-install   Disabled in standalone mode"
    colorized_echo yellow "  service-uninstall Disabled in standalone mode"
    colorized_echo yellow "  service-restart   Disabled in standalone mode"
    colorized_echo yellow "  service-status    Disabled in standalone mode"
    colorized_echo yellow "  service-logs      Disabled in standalone mode"
    colorized_echo yellow "  service-update    Disabled in standalone mode"
    colorized_echo yellow "  service-start     Disabled in standalone mode"
    colorized_echo yellow "  service-stop      Disabled in standalone mode"
    colorized_echo yellow "  edit              Edit docker-compose.yml (via nano or vi)"
    colorized_echo yellow "  edit-env          Edit .env file (via nano or vi)"
    colorized_echo yellow "  core-update       Update/Change Xray core"
    colorized_echo yellow "  geofiles          Download geoip and geosite files for specific regions"
    colorized_echo yellow "  renew-cert        Regenerate SSL/TLS certificate"
    colorized_echo yellow "  completion        Install bash tab completion"
}

pg_node_main "$@"
