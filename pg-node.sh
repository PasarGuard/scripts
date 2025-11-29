#!/usr/bin/env bash
set -e
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
COMMAND="$1"
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
if [[ "$CUSTOM_NAME_SET" == true && "$COMMAND" =~ ^(install|install-script)$ ]]; then
    if command -v "$APP_NAME" >/dev/null 2>&1; then
        echo "Error: '$APP_NAME' is an existing Linux command. Please choose a different --name." >&2
        exit 1
    fi
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
SERVICE_SCRIPT_URL="https://github.com/$FETCH_REPO/raw/main/pg-node-service.sh"
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
set_service_paths() {
    SERVICE_NAME="${APP_NAME}-service"
    SERVICE_SCRIPT_PATH="/usr/local/bin/${SERVICE_NAME}.sh"
    SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
}
require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        colorized_echo red "systemd is required to manage the service (systemctl not found)."
        exit 1
    fi
}
service_installed() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    fi
    set_service_paths
    if [ -f "$SERVICE_UNIT" ] || systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
        return 0
    fi
    return 1
}
restart_service_if_installed() {
    if ! service_installed; then
        return
    fi
    if [ "$(id -u)" != "0" ]; then
        colorized_echo yellow "$SERVICE_NAME is installed; run as root to restart it."
        return
    fi
    systemctl restart "$SERVICE_NAME"
    colorized_echo blue "$SERVICE_NAME service restarted."
}
update_service_if_installed() {
    if ! service_installed; then
        return
    fi
    if [ "$(id -u)" != "0" ]; then
        colorized_echo yellow "$SERVICE_NAME is installed; run as root to update/restart it."
        return
    fi
    install_node_service_script
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    colorized_echo blue "$SERVICE_NAME service updated and restarted."
}
configure_firewall_for_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local hint="If a firewall is enabled (e.g., UFW or firewalld), allow ${port}/${proto}."
    colorized_echo yellow "$hint"
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
install_node_service_script() {
    set_service_paths
    colorized_echo blue "Installing node service script"
    curl -sSL $SERVICE_SCRIPT_URL -o "$SERVICE_SCRIPT_PATH"
    sed -i "s/^APP_NAME=.*/APP_NAME=\"$APP_NAME\"/" "$SERVICE_SCRIPT_PATH"
    chmod 755 "$SERVICE_SCRIPT_PATH"
    colorized_echo green "node service script installed successfully at $SERVICE_SCRIPT_PATH"
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
    if [ "$AUTO_CONFIRM" = true ]; then
        :
    else
        while true; do
            # Temporarily disable exit on error for user input
            set +e
            read -rp "Enter additional SAN entries (comma separated, e.g., 82.2.2.2, test.com, *.example.com), or leave empty to keep current: " extra_san
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
                    colorized_echo yellow "    → Please enter a valid IP address (e.g., 82.2.2.2) or domain name (e.g., test.com)"
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
                colorized_echo yellow "  • 82.2.2.2 (IP address)"
                colorized_echo yellow "  • test.com (domain name)"
                colorized_echo yellow "  • *.example.com (wildcard domain)"
                colorized_echo yellow "  • 2001:db8::1 (IPv6 address)"
                colorized_echo yellow ""
                colorized_echo yellow "Note: You can enter IPs and domains directly without prefixes."
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
    colorized_echo cyan "  Command: openssl req -x509 -newkey rsa:4096 ..."
    if openssl req -x509 -newkey rsa:4096 -keyout "$SSL_KEY_FILE" \
        -out "$SSL_CERT_FILE" -days 36500 -nodes \
        -subj "/CN=$NODE_IP" \
        -addext "subjectAltName = $san_string" >/dev/null 2>&1; then
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
    COMPOSE_FILES_URL_PREFIX="https://raw.githubusercontent.com/PasarGuard/scripts/main"
    colorized_echo blue "Creating directories..."
    colorized_echo cyan "  Command: mkdir -p $DATA_DIR $DATA_DIR/certs $APP_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$DATA_DIR/certs"
    mkdir -p "$APP_DIR"
    colorized_echo green "  ✓ Directories created"
    colorized_echo cyan ""
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
    colorized_echo cyan "  Command: curl -sL $FILES_URL_PREFIX/.env.example -o $APP_DIR/.env"
    if curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"; then
        colorized_echo green "  ✓ File saved: $APP_DIR/.env"
    else
        colorized_echo red "  ✗ Failed to download .env.example"
        exit 1
    fi
    colorized_echo cyan "  Command: curl -sL $COMPOSE_FILES_URL_PREFIX/node.yml -o $APP_DIR/docker-compose.yml"
    if curl -sL "$COMPOSE_FILES_URL_PREFIX/node.yml" -o "$APP_DIR/docker-compose.yml"; then
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
    # Keep the container mount path but point the host path at DATA_DIR
    existing_volume=$(yq eval -r ".services[\"$service_name\"].volumes[0]" "$APP_DIR/docker-compose.yml" 2>/dev/null)
    if [ -n "$existing_volume" ] && [ "$existing_volume" != "null" ]; then
        # Extract container path (everything after the colon)
        if [[ "$existing_volume" == *:* ]]; then
            container_path="${existing_volume#*:}"
        else
            # If no colon found, use the existing volume as container path
            container_path="$existing_volume"
        fi
        colorized_echo cyan "  Command: yq eval ...volumes[0] = \"${DATA_DIR}:${container_path}\"..."
        if yq eval ".services[\"$service_name\"].volumes[0] = \"${DATA_DIR}:${container_path}\"" -i "$APP_DIR/docker-compose.yml" 2>/dev/null; then
            colorized_echo green "  ✓ Volume path configured: ${DATA_DIR}:${container_path}"
        else
            colorized_echo yellow "  ⚠ Failed to configure volume (may not be critical)"
        fi
    fi
    if [ "$node_version" != "latest" ]; then
        colorized_echo cyan "  Command: yq eval ...image = ...:${node_version}..."
        if yq eval ".services[\"$service_name\"].image = (.services[\"$service_name\"].image | sub(\":.*$\"; \":${node_version}\"))" -i "$APP_DIR/docker-compose.yml" 2>/dev/null; then
            colorized_echo green "  ✓ Docker image version set to: ${node_version}"
        else
            colorized_echo yellow "  ⚠ Failed to set image version (may not be critical)"
        fi
    fi
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
    if [ -f "$SERVICE_SCRIPT_PATH" ]; then
        colorized_echo yellow "Removing node service script"
        rm "$SERVICE_SCRIPT_PATH"
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
ensure_env_exists() {
    if [ ! -f "$ENV_FILE" ]; then
        colorized_echo red "Environment file not found at $ENV_FILE. Please install the node first."
        exit 1
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
    if [ "$AUTO_CONFIRM" = true ]; then
        install_service_choice="y"
    else
        read -p "Do you want to install and start the systemd service for $APP_NAME? (Y/n): " install_service_choice
    fi
    if [[ -z "$install_service_choice" || "$install_service_choice" =~ ^[Yy]$ ]]; then
        install_service_command
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
    if service_installed; then
        uninstall_service_command
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
install_service_command() {
    check_running_as_root
    require_systemd
    set_service_paths
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! is_node_installed; then
        colorized_echo red "node not installed! Install it before setting up the service."
        exit 1
    fi
    ensure_env_exists
    get_occupied_ports
    local api_port existing_api_port=""
    local default_api_port=62051
    if existing_api_port=$(grep -E '^API_PORT[[:space:]]*=' "$ENV_FILE" | head -n1 | sed 's/^API_PORT[[:space:]]*=[[:space:]]*//'); then
        existing_api_port=$(echo "$existing_api_port" | tr -d '"'\')
    fi
    if [[ "$existing_api_port" =~ ^[0-9]+$ ]] && [ "$existing_api_port" -ge 1 ] && [ "$existing_api_port" -le 65535 ]; then
        colorized_echo blue "Existing API_PORT found in $ENV_FILE: $existing_api_port"
        default_api_port="$existing_api_port"
    fi
    if [ "$AUTO_CONFIRM" = true ]; then
        api_port="$default_api_port"
        if is_port_occupied "$api_port"; then
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
                if is_port_occupied "$api_port"; then
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
    if grep -q '^API_PORT[[:space:]]*=' "$ENV_FILE"; then
        sed -i "s/^API_PORT[[:space:]]*=.*/API_PORT= ${api_port}/" "$ENV_FILE"
        if ! grep -q '^# *API_PORT' "$ENV_FILE"; then
            sed -i "/^API_PORT[[:space:]]*=.*/i ${api_port_comment}" "$ENV_FILE"
        fi
    else
        {
            echo ""
            echo "$api_port_comment"
            echo "API_PORT= ${api_port}"
        } >>"$ENV_FILE"
    fi
    colorized_echo magenta "API_PORT selected: ${api_port}"
    configure_firewall_for_port "$api_port" "tcp"
    install_node_service_script
    colorized_echo blue "Creating systemd unit at $SERVICE_UNIT"
    cat >"$SERVICE_UNIT" <<EOF
[Unit]
Description=PasarGuard Node Service API ($APP_NAME)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=$SERVICE_SCRIPT_PATH
WorkingDirectory=$APP_DIR
Restart=on-failure
RestartSec=5
StartLimitInterval=600
StartLimitBurst=3
TimeoutStartSec=30
TimeoutStopSec=10
Environment="ENV_FILE=$ENV_FILE"
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    colorized_echo green "$SERVICE_NAME service installed and started."
}
uninstall_service_command() {
    check_running_as_root
    require_systemd
    if ! service_installed; then
        colorized_echo yellow "Service not installed; nothing to uninstall."
        return
    fi
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if [ -f "$SERVICE_UNIT" ]; then
        colorized_echo yellow "Removing systemd unit $SERVICE_UNIT"
        rm "$SERVICE_UNIT"
    fi
    uninstall_node_service_script
    systemctl daemon-reload
    colorized_echo green "$SERVICE_NAME service uninstalled."
}

service_start_command() {
    check_running_as_root
    require_systemd
    if ! service_installed; then
        colorized_echo red "Service not installed. Run service-install first."
        exit 1
    fi
    systemctl start "$SERVICE_NAME"
    colorized_echo green "$SERVICE_NAME service started."
}
service_stop_command() {
    check_running_as_root
    require_systemd
    if ! service_installed; then
        colorized_echo red "Service not installed. Run service-install first."
        exit 1
    fi
    systemctl stop "$SERVICE_NAME"
    colorized_echo green "$SERVICE_NAME service stopped."
}

service_update_command() {
    check_running_as_root
    require_systemd
    if ! service_installed; then
        colorized_echo red "Service not installed. Run service-install first."
        exit 1
    fi
    install_node_service_script
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    colorized_echo green "$SERVICE_NAME service updated and restarted."
}

service_logs_command() {
    require_systemd
    if ! service_installed; then
        colorized_echo red "Service not installed. Run service-install first."
        exit 1
    fi
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
    if ! service_installed; then
        colorized_echo red "Service not installed. Run service-install first."
        exit 1
    fi
    restart_service_if_installed
}
status_service_command() {
    require_systemd
    if ! service_installed; then
        colorized_echo red "Service not installed. Run service-install first."
        exit 1
    fi
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
    local requested_version="${1:-}"
    identify_the_operating_system_and_architecture
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
    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))
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
        # Fallback to default if no volume found
        sed -i "s|^# *XRAY_EXECUTABLE_PATH *=.*|XRAY_EXECUTABLE_PATH= /var/lib/pg-node/xray-core/xray|" "$APP_DIR/.env"
        grep -q '^XRAY_EXECUTABLE_PATH=' "$APP_DIR/.env" || echo "XRAY_EXECUTABLE_PATH= /var/lib/pg-node/xray-core/xray" >>"$APP_DIR/.env"
    fi
    # Restart node
    colorized_echo red "Restarting node..."
    restart_command -n --no-restart-service
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
    cmds="up down restart status logs install update uninstall install-script uninstall-script core-update geofiles renew-cert edit edit-env completion service-install service-uninstall service-restart service-status service-logs service-update service-start service-stop"
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
    colorized_echo blue "Installing bash completion for $APP_NAME..."
    mkdir -p "$completion_dir"
    generate_completion >"$completion_file"
    chmod 644 "$completion_file"
    colorized_echo green "✓ Bash completion installed to $completion_file"
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
    colorized_echo yellow "  completion        $(tput sgr0)✓  Install bash tab completion"
    echo
    colorized_echo cyan "Restart Options:"
    colorized_echo yellow "  -n, --no-logs           $(tput sgr0)✓  Do not follow logs after restart"
    colorized_echo yellow "  --no-restart-service    $(tput sgr0)✓  Skip restarting systemd service"
    colorized_echo cyan "Update Options:"
    colorized_echo yellow "  --no-update-service     $(tput sgr0)✓  Skip updating systemd service"
    colorized_echo cyan "Install Options:"
    colorized_echo yellow "  -v, --version VERSION   $(tput sgr0)✓  Install specific version"
    colorized_echo yellow "  --pre-release           $(tput sgr0)✓  Install pre-release version"
    colorized_echo yellow "  --name NAME             $(tput sgr0)✓  Install with custom name"
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
    colorized_echo yellow "The old certificate will be backed up automatically."
    
    # Backup existing certificates
    if [ -f "$SSL_CERT_FILE" ]; then
        local backup_cert="${SSL_CERT_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        local backup_key="${SSL_KEY_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        colorized_echo blue "Backing up existing certificates..."
        cp "$SSL_CERT_FILE" "$backup_cert" 2>/dev/null || true
        if [ -f "$SSL_KEY_FILE" ]; then
            cp "$SSL_KEY_FILE" "$backup_key" 2>/dev/null || true
        fi
        colorized_echo green "  ✓ Backup created: $backup_cert"
        if [ -f "$backup_key" ]; then
            colorized_echo green "  ✓ Backup created: $backup_key"
        fi
    fi
    
    # Generate new certificate
    gen_self_signed_cert
    
    # Restart the service if it's running
    if docker ps --format '{{.Names}}' | grep -q "^$APP_NAME$"; then
        colorized_echo blue ""
        colorized_echo blue "Restarting node to apply new certificate..."
        restart_command -n --no-restart-service
        colorized_echo green "✓ Node restarted with new certificate"
    fi
    
    colorized_echo cyan ""
    colorized_echo cyan "================================"
    colorized_echo green "✓ Certificate renewal completed!"
    colorized_echo cyan "================================"
    colorized_echo magenta "New certificate location: $SSL_CERT_FILE"
    colorized_echo magenta "Please update the certificate in your pasarguard Panel."
    colorized_echo cyan "================================"
}

# Main command router
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
    install_service_command
    ;;
service-uninstall)
    uninstall_service_command
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
completion)
    check_running_as_root
    install_completion
    colorized_echo cyan ""
    colorized_echo yellow "To activate completion in this session, run:"
    colorized_echo cyan "  source /etc/bash_completion.d/$APP_NAME"
    colorized_echo yellow "Or simply restart your terminal."
    ;;
*)
    usage
    ;;
esac
