#!/usr/bin/env bash
set -e

# Handle global options
AUTO_CONFIRM=false
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    -y | --yes)
        AUTO_CONFIRM=true
        shift
        ;;
    *)
        ARGS+=("$1")
        shift
        ;;
    esac
done
set -- "${ARGS[@]}"

if [[ "$1" == "install" || "$1" == "install script" ]]; then
    if echo "$@" | grep -q -- "--name"; then
        APP_NAME=$(echo "$@" | sed -n 's/.*--name \([^ ]*\).*/\1/p')
    fi
else
    if echo "$@" | grep -q -- "--name"; then
        echo "Error: --name is only allowed with 'install' or 'install script' commands."
        exit 1
    fi
fi

# Fetch IP address from ifconfig.io API
NODE_IP_V4=$(curl -s -4 --fail --max-time 5 ifconfig.io 2>/dev/null || echo "")
NODE_IP_V6=$(curl -s -6 --fail --max-time 5 ifconfig.io 2>/dev/null || echo "")

if [[ "$1" == "install" || "$1" == "install-script" ]] && [ -z "$APP_NAME" ]; then
    APP_NAME="pg-node"
fi
# Set script name if APP_NAME is not set
if [ -z "$APP_NAME" ]; then
    SCRIPT_NAME=$(basename "$0")
    APP_NAME="${SCRIPT_NAME%.*}"
fi

INSTALL_DIR="/opt"

if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
    APP_DIR="$INSTALL_DIR/$APP_NAME"
elif [ -d "$INSTALL_DIR/node" ]; then
    APP_DIR="$INSTALL_DIR/node"
else
    APP_DIR="$INSTALL_DIR/$APP_NAME"
fi

DATA_DIR="/var/lib/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
SSL_CERT_FILE="$DATA_DIR/certs/ssl_cert.pem"
SSL_KEY_FILE="$DATA_DIR/certs/ssl_key.pem"
LAST_XRAY_CORES=5
FETCH_REPO="PasarGuard/scripts"
SCRIPT_URL="https://github.com/$FETCH_REPO/raw/main/pg-node.sh"

colorized_echo() {
    local color=$1
    local text=$2
    local style=${3:-0} # Default style is normal

    case $color in
    "red")
        printf "\e[${style};91m${text}\e[0m\n"
        ;;
    "green")
        printf "\e[${style};92m${text}\e[0m\n"
        ;;
    "yellow")
        printf "\e[${style};93m${text}\e[0m\n"
        ;;
    "blue")
        printf "\e[${style};94m${text}\e[0m\n"
        ;;
    "magenta")
        printf "\e[${style};95m${text}\e[0m\n"
        ;;
    "cyan")
        printf "\e[${style};96m${text}\e[0m\n"
        ;;
    *)
        echo "${text}"
        ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

detect_os() {
    # Detect the operating system
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update -qq >/dev/null 2>&1
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        PKG_MANAGER="yum"
        $PKG_MANAGER update -y -q >/dev/null 2>&1
        $PKG_MANAGER install -y -q epel-release >/dev/null 2>&1
    elif [[ "$OS" == "Fedora"* ]]; then
        PKG_MANAGER="dnf"
        $PKG_MANAGER update -q -y >/dev/null 2>&1
    elif [[ "$OS" == "Arch"* ]]; then
        PKG_MANAGER="pacman"
        $PKG_MANAGER -Sy --noconfirm --quiet >/dev/null 2>&1
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER refresh --quiet >/dev/null 2>&1
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

detect_compose() {
    # Check if docker compose command exists
    if docker compose >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        colorized_echo red "docker compose not found"
        exit 1
    fi
}

install_package() {
    if [ -z "$PKG_MANAGER" ]; then
        detect_and_update_package_manager
    fi

    PACKAGE=$1
    colorized_echo blue "Installing $PACKAGE"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER -y -qq install "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        $PKG_MANAGER install -y -q "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "Fedora"* ]]; then
        $PKG_MANAGER install -y -q "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "Arch"* ]]; then
        $PKG_MANAGER -S --noconfirm --quiet "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER --quiet install -y "$PACKAGE" >/dev/null 2>&1
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_docker() {
    # Install Docker and Docker Compose using the official installation script
    colorized_echo blue "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    colorized_echo green "Docker installed successfully"
}

install_node_script() {
    colorized_echo blue "Installing node script"
    TARGET_PATH="/usr/local/bin/$APP_NAME"
    curl -sSL $SCRIPT_URL -o $TARGET_PATH

    sed -i "s/^APP_NAME=.*/APP_NAME=\"$APP_NAME\"/" $TARGET_PATH

    chmod 755 $TARGET_PATH
    colorized_echo green "node script installed successfully at $TARGET_PATH"
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

gen_self_signed_cert() {
    local san_entries=("DNS:localhost" "IP:127.0.0.1")

    # Add IPv4 if it exists
    if [ -n "$NODE_IP_V4" ]; then
        san_entries+=("IP:$NODE_IP_V4")
    fi

    # Add IPv6 if it exists
    if [ -n "$NODE_IP_V6" ]; then
        san_entries+=("IP:$NODE_IP_V6")
    fi

    echo "Current SAN entries: ${san_entries[*]}"
    if [ "$AUTO_CONFIRM" = true ]; then
        extra_san=""
    else
        read -rp "Enter additional SAN entries (comma separated), or leave empty to keep current: " extra_san
    fi

    if [[ -n "$extra_san" ]]; then
        IFS=',' read -ra user_entries <<<"$extra_san"
        san_entries+=("${user_entries[@]}")
    fi

    # Join SAN entries into a comma-separated string and remove duplicates
    local san_string
    san_string=$(printf '%s\n' "${san_entries[@]}" | sort -u | paste -sd, -)

    openssl req -x509 -newkey rsa:4096 -keyout "$SSL_KEY_FILE" \
        -out "$SSL_CERT_FILE" -days 36500 -nodes \
        -subj "/CN=$NODE_IP" \
        -addext "subjectAltName = $san_string" >/dev/null 2>&1

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

    echo -e "$prompt_message"
    echo "Press ENTER on a new line when finished: "

    while IFS= read -r line; do
        [[ -z $line ]] && break

        if [[ "$first_line_read" -eq 0 && "$allow_file_input" -eq 1 && -f "$line" ]]; then
            first_line_read=1
            cp "$line" "$output_file"
            break
        fi

        echo "$line" >>"$output_file"
    done
}

install_node() {
    local node_version=$1

    FILES_URL_PREFIX="https://raw.githubusercontent.com/PasarGuard/node/main"
    COMPOSE_FILES_URL_PREFIX="https://raw.githubusercontent.com/PasarGuard/scripts/main"

    mkdir -p "$DATA_DIR"
    mkdir -p "$DATA_DIR/certs"
    mkdir -p "$APP_DIR"

    echo "A self-signed certificate will be generated by default."
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
        # Generate a valid UUIDv4
        API_KEY=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || python -c "import uuid; print(uuid.uuid4())")
        colorized_echo green "No API Key provided. A random UUID version 4 has been generated"
    fi

    if [ "$AUTO_CONFIRM" = true ]; then
        use_rest=""
    else
        read -p "GRPC is recommended by default. Do you want to use REST protocol instead? (Y/n): " -r use_rest
    fi

    # Default to "Y" if the user just presses ENTER
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
    curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"
    curl -sL "$COMPOSE_FILES_URL_PREFIX/node.yml" -o "$APP_DIR/docker-compose.yml"
    colorized_echo green "File saved in $APP_DIR/.env"
    colorized_echo green "File saved in $APP_DIR/docker-compose.yml"

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
    service_name="node"

    if [ "$APP_NAME" != "pg-node" ]; then
        yq eval ".services[\"$service_name\"].container_name = \"$APP_NAME\"" -i "$APP_DIR/docker-compose.yml"
        yq eval ".services[\"$service_name\"].volumes[0] = \"${DATA_DIR}:\${(.services[\"$service_name\"].volumes[0] | split(\":\")[1])}\"" -i "$APP_DIR/docker-compose.yml"
    fi

    if [ "$node_version" != "latest" ]; then
        yq eval ".services[\"$service_name\"].image = (.services[\"$service_name\"].image | sub(\":.*$\"; \":${node_version}\"))" -i "$APP_DIR/docker-compose.yml"
    fi

    colorized_echo green "compose file modified successfully"
}

uninstall_node_script() {
    if [ -f "/usr/local/bin/$APP_NAME" ]; then
        colorized_echo yellow "Removing node script"
        rm "/usr/local/bin/$APP_NAME"
    fi
}

uninstall_node() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_node_docker_images() {
    images=$(docker images | grep node | awk '{print $3}')

    if [ -n "$images" ]; then
        colorized_echo yellow "Removing Docker images of node"
        for image in $images; do
            if docker rmi "$image" >/dev/null 2>&1; then
                colorized_echo yellow "Image $image removed"
            fi
        done
    fi
}

uninstall_node_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

up_node() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" up -d --remove-orphans
}

down_node() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" down
}

show_node_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs
}

follow_node_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

update_node_script() {
    colorized_echo blue "Updating node script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/$APP_NAME
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

is_node_up() {
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

install_command() {
    check_running_as_root
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
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
    done

    # Check if  node is already installed
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
    fi
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
            install_node "$node_version"
            echo "Installing $node_version version"
        else
            echo "Version $node_version does not exist. Please enter a valid version (e.g. v0.5.2)"
            exit 1
        fi
    else
        echo "Invalid version format. Please enter a valid version (e.g. v1.0.0)"
        exit 1
    fi
    install_node_script
    install_completion
    up_node
    show_node_logs

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
        REPLY=""
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
    uninstall_completion
    uninstall_node_script
    uninstall_node
    uninstall_node_docker_images

    if [ "$AUTO_CONFIRM" = true ]; then
        REPLY=""
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
        colorized_echo red "node not installed!"
        exit 1
    fi

    detect_compose

    down_node
    up_node

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

    colorized_echo blue "node updated successfully"
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
        'i386' | 'i686')
            ARCH='32'
            ;;
        'amd64' | 'x86_64')
            ARCH='64'
            ;;
        'armv5tel')
            ARCH='arm32-v5'
            ;;
        'armv6l')
            ARCH='arm32-v6'
            grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
        'armv7' | 'armv7l')
            ARCH='arm32-v7a'
            grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
        'armv8' | 'aarch64')
            ARCH='arm64-v8a'
            ;;
        'mips')
            ARCH='mips32'
            ;;
        'mipsle')
            ARCH='mips32le'
            ;;
        'mips64')
            ARCH='mips64'
            lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
        'mips64le')
            ARCH='mips64le'
            ;;
        'ppc64')
            ARCH='ppc64'
            ;;
        'ppc64le')
            ARCH='ppc64le'
            ;;
        'riscv64')
            ARCH='riscv64'
            ;;
        's390x')
            ARCH='s390x'
            ;;
        *)
            echo "error: The architecture is not supported."
            exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

# Function to update the Xray core
get_xray_core() {
    identify_the_operating_system_and_architecture
    clear

    validate_version() {
        local version="$1"

        local response=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version")
        if echo "$response" | grep -q '"message": "Not Found"'; then
            echo "invalid"
        else
            echo "valid"
        fi
    }

    print_menu() {
        clear
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

    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))

    if [ "$AUTO_CONFIRM" = true ]; then
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

    if ! dpkg -s unzip >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package unzip
    fi

    mkdir -p $DATA_DIR/xray-core
    cd $DATA_DIR/xray-core

    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"

    echo -e "\033[1;33mDownloading Xray-core version ${selected_version} in the background...\033[0m"
    wget "${xray_download_url}" -q &
    wait

    echo -e "\033[1;33mExtracting Xray-core in the background...\033[0m"
    unzip -o "${xray_filename}" >/dev/null 2>&1 &
    wait
    rm "${xray_filename}"
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

install_yq() {
    if command -v yq &>/dev/null; then
        colorized_echo green "yq is already installed."
        return
    fi

    identify_the_operating_system_and_architecture

    local base_url="https://github.com/mikefarah/yq/releases/latest/download"
    local yq_binary=""

    case "$ARCH" in
    '64' | 'x86_64')
        yq_binary="yq_linux_amd64"
        ;;
    'arm32-v7a' | 'arm32-v6' | 'arm32-v5' | 'armv7l')
        yq_binary="yq_linux_arm"
        ;;
    'arm64-v8a' | 'aarch64')
        yq_binary="yq_linux_arm64"
        ;;
    '32' | 'i386' | 'i686')
        yq_binary="yq_linux_386"
        ;;
    *)
        colorized_echo red "Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac

    local yq_url="${base_url}/${yq_binary}"
    colorized_echo blue "Downloading yq from ${yq_url}..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        colorized_echo yellow "Neither curl nor wget is installed. Attempting to install curl."
        install_package curl || {
            colorized_echo red "Failed to install curl. Please install curl or wget manually."
            exit 1
        }
    fi

    if command -v curl &>/dev/null; then
        if curl -L "$yq_url" -o /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using curl. Please check your internet connection."
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if wget -O /usr/local/bin/yq "$yq_url"; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using wget. Please check your internet connection."
            exit 1
        fi
    fi

    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi

    hash -r

    if command -v yq &>/dev/null; then
        colorized_echo green "yq is ready to use."
    elif [ -x "/usr/local/bin/yq" ]; then

        colorized_echo yellow "yq is installed at /usr/local/bin/yq but not found in PATH."
        colorized_echo yellow "You can add /usr/local/bin to your PATH environment variable."
    else
        colorized_echo red "yq installation failed. Please try again or install manually."
        exit 1
    fi
}

update_core_command() {
    check_running_as_root
    get_xray_core

    sed -i "s|^# *XRAY_EXECUTABLE_PATH *=.*|XRAY_EXECUTABLE_PATH= ${DATA_DIR}/xray-core/xray|" "$APP_DIR/.env"
    grep -q '^XRAY_EXECUTABLE_PATH=' "$APP_DIR/.env" || echo "XRAY_EXECUTABLE_PATH= ${DATA_DIR}/xray-core/xray" >>"$APP_DIR/.env"

    # Restart node
    colorized_echo red "Restarting node..."
    $APP_NAME restart -n
    colorized_echo blue "Installation of XRAY-CORE version $selected_version completed."
}

check_editor() {
    if [ -z "$EDITOR" ]; then
        if command -v nano >/dev/null 2>&1; then
            EDITOR="nano"
        elif command -v vi >/dev/null 2>&1; then
            EDITOR="vi"
        else
            detect_os
            install_package nano
            EDITOR="nano"
        fi
    fi
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

generate_completion() {
    cat <<'EOF'
_node_completions()
{
    local cur cmds
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmds="up down restart status logs install update uninstall install-script uninstall-script core-update geofiles edit edit-env completion"
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
}
EOF
    echo "complete -F _node_completions node.sh"
    echo "complete -F _node_completions $APP_NAME"
}

install_completion() {
    local completion_dir="/etc/bash_completion.d"
    local completion_file="$completion_dir/$APP_NAME"
    mkdir -p "$completion_dir"
    generate_completion >"$completion_file"
    colorized_echo green "Bash completion installed to $completion_file"
}

uninstall_completion() {
    local completion_dir="/etc/bash_completion.d"
    local completion_file="$completion_dir/$APP_NAME"
    if [ -f "$completion_file" ]; then
        rm "$completion_file"
        colorized_echo yellow "Bash completion removed from $completion_file"
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
    colorized_echo yellow "  -y, --yes       $(tput sgr0)– Use default answers for all prompts"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              $(tput sgr0)– Start services"
    colorized_echo yellow "  down            $(tput sgr0)– Stop services"
    colorized_echo yellow "  restart         $(tput sgr0)– Restart services"
    colorized_echo yellow "  status          $(tput sgr0)– Show status"
    colorized_echo yellow "  logs            $(tput sgr0)– Show logs"
    colorized_echo yellow "  install         $(tput sgr0)– Install/reinstall node"
    colorized_echo yellow "  update          $(tput sgr0)– Update to latest version"
    colorized_echo yellow "  uninstall       $(tput sgr0)– Uninstall node"
    colorized_echo yellow "  install-script  $(tput sgr0)– Install node script"
    colorized_echo yellow "  uninstall-script  $(tput sgr0)– Uninstall node script"
    colorized_echo yellow "  edit            $(tput sgr0)– Edit docker-compose.yml (via nano or vi)"
    colorized_echo yellow "  edit-env        $(tput sgr0)– Edit .env file (via nano or vi)"
    colorized_echo yellow "  core-update     $(tput sgr0)– Update/Change Xray core"
    colorized_echo yellow "  geofiles        $(tput sgr0)– Download geoip and geosite files for specific regions"

    echo
    colorized_echo cyan "Node Information:"
    colorized_echo magenta "  Node IP: $NODE_IP"

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
        sed -i "s|^# *XRAY_ASSETS_PATH *=.*|XRAY_ASSETS_PATH = $DATA_DIR/assets|" "$ENV_FILE"
        grep -q '^XRAY_ASSETS_PATH =' "$ENV_FILE" || echo "XRAY_ASSETS_PATH = $DATA_DIR/assets" >> "$ENV_FILE"
        colorized_echo blue "XRAY_ASSETS_PATH updated in $ENV_FILE"
        colorized_echo blue "Restarting node services..."
        restart_command -n
        colorized_echo green "Geofiles updated and node restarted."
    else
        colorized_echo yellow "No geofiles specified for download."
    fi
}

case "$1" in
install)
    shift
    install_command "$@"
    ;;
update)
    update_command
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
    update_core_command
    ;;
geofiles)
    shift
    geofiles_command "$@"
    ;;
install-script)
    install_node_script
    ;;
uninstall-script)
    uninstall_node_script
    ;;
edit)
    edit_command
    ;;
edit-env)
    edit_env_command
    ;;
completion)
    generate_completion
    ;;
*)
    usage
    ;;
esac
