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
if [ "$running_from_checkout" = false ] && [[ " $* " != *" certificate-"* && " $* " != *" renew-cert "* ]]; then
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
NODE_IP_V4='' NODE_IP_V6=''
case "$COMMAND" in
    certificate-*|renew-cert|show-cert) ;;
    *) NODE_IP_V4=$(curl -s -4 --fail --max-time 5 ifconfig.io 2>/dev/null || echo "")
       NODE_IP_V6=$(curl -s -6 --fail --max-time 5 ifconfig.io 2>/dev/null || echo "");;
esac
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
# Configure service paths based on APP_NAME.
set_service_paths() {
    SERVICE_NAME="${APP_NAME}-service"
    SERVICE_BINARY_PATH="/usr/local/bin/${SERVICE_NAME}"
    SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
}

# Require systemd (systemctl) on the system.
require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        colorized_echo red "systemd is required to manage the service (systemctl not found)."
        exit 1
    fi
}

# Check if the node systemd service is installed.
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

# Restart the node systemd service if currently installed.
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

# Update and restart the node systemd service if currently installed.
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

# Detect system platform architecture string for node-serviced releases.
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

# Display firewall hints for opening a given port and protocol.
configure_firewall_for_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local hint="If a firewall is enabled (e.g., UFW or firewalld), allow ${port}/${proto}."
    colorized_echo yellow "$hint"
}

# Install this pg-node CLI version to /usr/local/bin, including branch installs.
install_node_script() {
    print_script_execution_header "pg-node" "$SCRIPT_COMMIT_SHA" "install"
    colorized_echo blue "Installing node script"
    TARGET_PATH="/usr/local/bin/$APP_NAME"
    TEMP_FILE=$(create_temp_file "pg-node-script" ".sh")
    
    # The ACME hook immediately invokes the installed CLI. Fetching main here
    # can replace a branch installer with an older CLI that treats renew-cert
    # as self-signed renewal and ignores --deploy-acme.
    colorized_echo cyan "  Copying the running installer..."
    local script_source="${BASH_SOURCE[0]:-}"
    if [ -f "$script_source" ]; then
        if ! cp "$script_source" "$TEMP_FILE"; then
            rm -f "$TEMP_FILE"
            return 1
        fi
    elif [ -n "${BASH_EXECUTION_STRING:-}" ]; then
        # Support the documented bash -c "$(curl ...)" installation form.
        printf '%s\n' "$BASH_EXECUTION_STRING" >"$TEMP_FILE" || return 1
    else
        colorized_echo red "✗ Cannot locate the running installer"
        rm -f "$TEMP_FILE"
        return 1
    fi
    
    # Replace APP_NAME in the script - the script has APP_NAME="" on line 5
    # We need to set it to the current APP_NAME value
    if grep -q "^APP_NAME=" "$TEMP_FILE"; then
        sed -i "s|^APP_NAME=.*|APP_NAME=\"$APP_NAME\"|" "$TEMP_FILE"
    fi

    if ! install_shared_libs_from_repo "$FETCH_REPO" common.sh system.sh docker.sh github.sh; then
        rm -f "$TEMP_FILE"
        return 1
    fi
    
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

# Download and install the node-serviced binary release from GitHub.
install_node_service_script() {
    set_service_paths
    if ! command -v jq >/dev/null 2>&1; then
        detect_os
        install_package jq
    fi
    colorized_echo blue "Installing node-serviced binary"
    local platform release_json latest_tag latest_version asset_name asset_url tmp_dir archive_path
    platform=$(detect_node_serviced_platform)
    if ! release_json=$(curl -fsSL "$NODE_SERVICE_RELEASE_API"); then
        colorized_echo red "Failed to query latest node-serviced release from $NODE_SERVICE_RELEASE_API"
        exit 1
    fi
    latest_tag=$(echo "$release_json" | jq -r '.tag_name // empty')
    latest_version="${latest_tag#v}"
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        colorized_echo red "Failed to resolve latest node-serviced version from $NODE_SERVICE_RELEASE_API"
        exit 1
    fi
    asset_name="${NODE_SERVICE_BINARY_NAME}_${latest_version}_${platform}.tar.gz"
    asset_url=$(echo "$release_json" | jq -r --arg name "$asset_name" '.assets[]? | select(.name==$name) | .browser_download_url' | head -n 1)
    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        colorized_echo red "node-serviced asset not found for platform $platform (expected $asset_name)"
        exit 1
    fi
    tmp_dir=$(create_temp_dir "node-serviced")
    archive_path="${tmp_dir}/${asset_name}"
    colorized_echo cyan "  Downloading ${asset_name}..."
    if ! curl -sSL "$asset_url" -o "$archive_path"; then
        colorized_echo red "Failed to download node-serviced from $asset_url"
        rm -rf "$tmp_dir"
        exit 1
    fi
    colorized_echo cyan "  Extracting node-serviced..."
    if ! tar -xzf "$archive_path" -C "$tmp_dir" "$NODE_SERVICE_BINARY_NAME" 2>/dev/null; then
        colorized_echo red "Failed to extract node-serviced binary from archive."
        rm -rf "$tmp_dir"
        exit 1
    fi
    install -m 755 "${tmp_dir}/${NODE_SERVICE_BINARY_NAME}" "$SERVICE_BINARY_PATH"
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

# Validate a Subject Alternative Name (SAN) entry for certificate generation.
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

# Generate a random UUID v4 using available system tools.
generate_uuid_v4() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null ||
        uuidgen 2>/dev/null ||
        python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null ||
        python -c "import uuid; print(uuid.uuid4())" 2>/dev/null
}

# Check if the installed openssl binary supports the -addext option.
openssl_supports_addext() {
    openssl req -help 2>&1 | grep -q -- '-addext'
}

# Generate an EC self-signed certificate using openssl -addext.
generate_self_signed_cert_with_addext() {
    local san_string="$1"

    openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$SSL_KEY_FILE" \
        -out "$SSL_CERT_FILE" -days 3650 -nodes \
        -subj "/CN=$NODE_IP" \
        -addext "subjectAltName = $san_string" >/dev/null 2>&1
}

# Generate an EC self-signed certificate using a temporary openssl config file.
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

# Generate a self-signed SSL/TLS certificate with Subject Alternative Names (SANs).
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
# Read multiline content or copy a file path into a target file.
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

# Replace the image tag of the node service in a compose file (e.g. :latest -> :dev).
# Only a tag after the last path segment is replaced (an untagged image gets one),
# so a registry port such as registry:5000/pasarguard/node is kept. Needs mikefarah yq v4.
# Arguments:
#   $1 - Image tag (a release tag such as v0.5.4, or dev).
#   $2 - Path to the docker-compose.yml to edit in place.
set_node_image_tag() {
    local tag="$1"
    local compose_file="$2"
    yq eval ".services[\"node\"].image = (.services[\"node\"].image | sub(\"(:[^/:]*)?$\"; \":${tag}\"))" -i "$compose_file"
}

# Point a fresh install's compose file at the requested image tag. latest is the
# downloaded default, so nothing is rewritten; any other tag must be set, or the
# install would finish on the wrong image, so a failed rewrite stops the install.
# Arguments:
#   $1 - Requested node version (latest, dev or a release tag).
#   $2 - Path to the docker-compose.yml to edit in place.
set_install_image_tag() {
    local node_version="$1"
    local compose_file="$2"
    [ "$node_version" = "latest" ] && return 0
    colorized_echo cyan "  Command: yq eval ...image = ...:${node_version}..."
    if set_node_image_tag "$node_version" "$compose_file"; then
        colorized_echo green "  ✓ Docker image version set to: ${node_version}"
    else
        colorized_echo red "  ✗ Failed to set the node image tag to ${node_version} (mikefarah yq v4 is required)"
        exit 1
    fi
}

# Download compose files, set up certificates, configure .env, and deploy the node.
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
    with_node_cert_lock prepare_install_node_certificate || exit 1
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
    sed -i '/^[[:space:]]*TLS_ENABLED[[:space:]]*=/d' "$ENV_FILE"
    echo "TLS_ENABLED=$TLS_ENABLED" >>"$ENV_FILE"
    if [ "$TLS_ENABLED" = false ]; then
        sed -i '/^[[:space:]]*NODE_HOST[[:space:]]*=/d' "$ENV_FILE"
        echo 'NODE_HOST=127.0.0.1' >>"$ENV_FILE"
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
    container_path="$DATA_DIR"
    colorized_echo cyan "  Command: yq eval ...volumes[0] = \"${DATA_DIR}:${container_path}\"..."
    if yq eval ".services[\"$service_name\"].volumes[0] = \"${DATA_DIR}:${container_path}\"" -i "$APP_DIR/docker-compose.yml" 2>/dev/null; then
        colorized_echo green "  ✓ Volume path configured: ${DATA_DIR}:${container_path}"
    else
        colorized_echo yellow "  ⚠ Failed to configure volume (may not be critical)"
    fi
    # Keep SSL paths in .env aligned with the mapped volume (important for node-serviced on host)
    ssl_cert_env="$SSL_CERT_FILE"
    ssl_key_env="$SSL_KEY_FILE"
    sed -i "s|^SSL_CERT_FILE *=.*|SSL_CERT_FILE= ${ssl_cert_env}|" "$APP_DIR/.env"
    sed -i "s|^SSL_KEY_FILE *=.*|SSL_KEY_FILE= ${ssl_key_env}|" "$APP_DIR/.env"
    set_install_image_tag "$node_version" "$APP_DIR/docker-compose.yml"
    # Final sync to ensure env has the correct SSL paths for custom names
    sync_env_ssl_paths
    colorized_echo green "✓ docker-compose.yml modified successfully"
}
# Remove the pg-node script from /usr/local/bin.
uninstall_node_script() {
    if [ -f "/usr/local/bin/$APP_NAME" ]; then
        colorized_echo yellow "Removing node script"
        rm "/usr/local/bin/$APP_NAME"
    fi
}

# Remove the node-serviced binary from /usr/local/bin.
uninstall_node_service_script() {
    set_service_paths
    if [ -f "$SERVICE_BINARY_PATH" ]; then
        colorized_echo yellow "Removing node-serviced binary"
        rm "$SERVICE_BINARY_PATH"
    fi
}

# Remove the node application directory.
uninstall_node() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

# Remove unused pasarguard/node Docker images.
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

# Remove the node data and certificates directory.
uninstall_node_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

# Start node Docker Compose services in background.
up_node() {
    compose_up
}

# Stop and remove node Docker Compose containers.
down_node() {
    compose_down
}

# Display node Docker Compose logs without following.
show_node_logs() {
    compose_logs
}

# Follow node Docker Compose logs in real time.
follow_node_logs() {
    compose_logs_follow
}

# Update shared libraries and the node script from the remote repository.
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

# Pull latest Docker images for the node services.
update_node() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull
}

# Check if node application directory exists.
is_node_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}

# Verify that the environment file exists.
ensure_env_exists() {
    if [ ! -f "$ENV_FILE" ]; then
        colorized_echo red "Environment file not found at $ENV_FILE. Please install the node first."
        exit 1
    fi
}

# Synchronize SSL certificate and key paths in .env with custom APP_NAME.
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
    if [[ -z "$current_cert" || "$current_cert" = /var/lib/pg-node/certs/ssl_cert.pem ]]; then
        sed -i "s|^[[:space:]]*SSL_CERT_FILE[[:space:]]*=.*|SSL_CERT_FILE= ${desired_cert}|" "$ENV_FILE"
        grep -q '^[[:space:]]*SSL_CERT_FILE[[:space:]]*=' "$ENV_FILE" || echo "SSL_CERT_FILE= ${desired_cert}" >>"$ENV_FILE"
        updated=true
    fi
    if [[ -z "$current_key" || "$current_key" = /var/lib/pg-node/certs/ssl_key.pem ]]; then
        sed -i "s|^[[:space:]]*SSL_KEY_FILE[[:space:]]*=.*|SSL_KEY_FILE= ${desired_key}|" "$ENV_FILE"
        grep -q '^[[:space:]]*SSL_KEY_FILE[[:space:]]*=' "$ENV_FILE" || echo "SSL_KEY_FILE= ${desired_key}" >>"$ENV_FILE"
        updated=true
    fi
    if [ "$updated" = true ]; then
        colorized_echo cyan "Updated SSL file paths in $ENV_FILE to match APP_NAME ($APP_NAME)."
    fi
}

# Check if node Docker containers are created or running.
is_node_up() {
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

# Check that a node image version exists as a GitHub release of PasarGuard/node.
# Arguments:
#   $1 - latest, pre-release, dev, or a release tag such as v0.5.4.
# Globals:
#   node_version - for pre-release, set to the newer of the latest stable and latest pre-release tags.
# Returns:
#   0 if the version can be used, 1 otherwise.
check_node_version_exists() {
    local version=$1
    local repo_url="https://api.github.com/repos/PasarGuard/node/releases"
    # dev is the Docker image built from the node dev branch, not a GitHub release
    if [ "$version" == "dev" ]; then
        return 0
    fi
    if [ "$version" == "latest" ]; then
        local latest_tag=$(curl -s ${repo_url}/latest | jq -r '.tag_name')
        # Check if there is any stable release of  node v1
        if [ "$latest_tag" == "null" ]; then
            return 1
        fi
        return 0
    fi
    if [ "$version" == "pre-release" ]; then
        local latest_stable_tag=$(curl -s "$repo_url/latest" | jq -r '.tag_name')
        local latest_pre_release_tag=$(curl -s "$repo_url" | jq -r '[.[] | select(.prerelease == true)][0].tag_name')
        # An unreachable or rate-limited API leaves these empty; treat that like "no release"
        [ -n "$latest_stable_tag" ] || latest_stable_tag="null"
        [ -n "$latest_pre_release_tag" ] || latest_pre_release_tag="null"
        if [ "$latest_stable_tag" == "null" ] && [ "$latest_pre_release_tag" == "null" ]; then
            return 1 # No releases found at all
        elif [ "$latest_stable_tag" == "null" ]; then
            node_version=$latest_pre_release_tag
        elif [ "$latest_pre_release_tag" == "null" ]; then
            node_version=$latest_stable_tag
        else
            # sort -V puts v1.0.0-rc.1 after v1.0.0, which would pick an older release
            # candidate over the stable release it led to. Compare the base versions
            # (the part before the first "-") instead: a pre-release wins only when its
            # base is newer, so the result does not depend on which sort -V is installed.
            local stable_base="${latest_stable_tag%%-*}"
            local pre_release_base="${latest_pre_release_tag%%-*}"
            local newest_base
            newest_base=$(printf "%s\n" "$stable_base" "$pre_release_base" | sort -V | tail -n 1)
            if [ "$pre_release_base" != "$stable_base" ] && [ "$newest_base" = "$pre_release_base" ]; then
                node_version=$latest_pre_release_tag
            else
                node_version=$latest_stable_tag
            fi
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

# Validate node_version (format, then GitHub release) and print why it cannot be used.
# Globals:
#   node_version - the requested version; pre-release is resolved to a release tag.
# Returns:
#   0 if the version can be used, 1 otherwise.
validate_node_version() {
    if ! [[ "$node_version" == "latest" || "$node_version" == "pre-release" || "$node_version" == "dev" || "$node_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        colorized_echo red "✗ Invalid version format. Please enter a valid version (e.g. v1.0.0)"
        return 1
    fi
    if ! check_node_version_exists "$node_version"; then
        colorized_echo red "✗ Version $node_version does not exist. Please enter a valid version (e.g. v0.1.2)"
        return 1
    fi
    # Never hand an empty or malformed resolved tag to the compose rewrite
    local release_tag_regex='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
    if ! [[ "$node_version" == "latest" || "$node_version" == "dev" || "$node_version" =~ $release_tag_regex ]]; then
        colorized_echo red "✗ Could not resolve a node release tag (got '$node_version'). Check that api.github.com is reachable."
        return 1
    fi
    return 0
}

# Warn that the dev image is an unreleased build and how to leave it.
print_dev_image_note() {
    colorized_echo yellow "Note: pasarguard/node:dev is an unreleased build of the node dev branch, meant for testing only."
    colorized_echo yellow "      '$APP_NAME update' pulls the newest dev build; '$APP_NAME update --version latest' returns to the latest release."
}

# Execute node installation workflow with option parsing and setup.
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
                colorized_echo red "Error: Cannot use --pre-release, --dev and --version options simultaneously."
                exit 1
            fi
            node_version="$2"
            node_version_set="true"
            shift 2
            ;;
        --pre-release)
            if [[ "$node_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release, --dev and --version options simultaneously."
                exit 1
            fi
            node_version="pre-release"
            node_version_set="true"
            shift
            ;;
        --dev)
            if [[ "$node_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release, --dev and --version options simultaneously."
                exit 1
            fi
            node_version="dev"
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
        --ssl-ip | --ssl-ipv6 | --ssl-domain | --ssl-http-port | --ssl-port)
            [ -n "${2:-}" ] || { cert_error "$1 requires a value"; return 1; }
            case "$1" in
                --ssl-ip) INSTALL_SSL_IP="$2";;
                --ssl-ipv6) INSTALL_SSL_IPV6="$2";;
                --ssl-domain) INSTALL_SSL_DOMAIN="$2";;
                *) INSTALL_SSL_HTTP_PORT="$2";;
            esac
            shift 2
            ;;
        --no-ssl)
            INSTALL_NO_SSL=true
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
    validate_ssl_selection || return 1
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
    command -v openssl >/dev/null 2>&1 || install_package openssl
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi
    ensure_docker_compose
    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi
    detect_compose
    # Check if the version is valid and exists
    if ! validate_node_version; then
        exit 1
    fi
    colorized_echo cyan "================================"
    colorized_echo cyan "Installing PasarGuard Node"
    colorized_echo cyan "Version: $node_version"
    colorized_echo cyan "================================"
    if [ "$node_version" == "dev" ]; then
        print_dev_image_note
    fi
    install_node "$node_version"
    colorized_echo green "✓ Node installation completed for version: $node_version"
    install_node_script
    install_completion
    up_node
    local install_service_choice=""
    if [ -n "${INSTALL_SERVICE_CHOICE:-}" ]; then
        install_service_choice="$INSTALL_SERVICE_CHOICE"
    elif [ "$AUTO_CONFIRM" = true ]; then
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
    register_node_acme_reload || return 1
    if [ "${TLS_ENABLED:-true}" = false ]; then
        write_node_cert_status external_tls
    elif verify_node_cert_services; then
        write_node_cert_status deployed
    else
        write_node_cert_status unverified 'Initial TLS endpoint verification failed; inspect service logs'
    fi
    show_node_certificate
    colorized_echo blue "================================"
    colorized_echo magenta "Next, use the API Key (UUID v4) in pasarguard Panel: "
    colorized_echo red "${API_KEY}"
}
# Uninstall node containers, configuration, scripts, and optionally data directories.
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
    if service_installed; then
        uninstall_service_command
    fi
    remove_node_cert_scheduler || return 1
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

# Start node services and optionally stream container logs.
up_command() {
    # Display help message for up command options.
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

# Stop running node services.
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

# Restart node services and restart systemd service if present.
restart_command() {
    # Display help message for restart command options.
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

# Configure, install, and start the node systemd service unit.
install_service_command() {
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
    if [ -n "${INSTALL_API_PORT:-}" ]; then
        api_port="$INSTALL_API_PORT"
        if is_port_occupied "$api_port"; then
            colorized_echo red "Port $api_port is already in use."
            exit 1
        fi
        if ! [[ "$api_port" =~ ^[0-9]+$ && "$api_port" -ge 1 && "$api_port" -le 65535 ]]; then
            colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
            exit 1
        fi
    elif [ "$AUTO_CONFIRM" = true ]; then
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
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    colorized_echo green "$SERVICE_NAME service installed and started."
}

# Stop, disable, and remove the node systemd service unit.
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

# Start the node systemd service unit.
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

# Stop the running node systemd service unit.
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

# Update the node-serviced binary and restart the systemd service.
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

# Display or follow journalctl logs for the node systemd service.
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

# Restart the node systemd service.
restart_service_command() {
    check_running_as_root
    require_systemd
    if ! service_installed; then
        colorized_echo red "Service not installed. Run service-install first."
        exit 1
    fi
    restart_service_if_installed
}

# Display status of the node systemd service via systemctl.
status_service_command() {
    require_systemd
    if ! service_installed; then
        colorized_echo red "Service not installed. Run service-install first."
        exit 1
    fi
    systemctl status --no-pager "$SERVICE_NAME"
}

# Display status and individual container states of the node services.
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

# Display or follow Docker Compose logs for the node.
logs_command() {
    # Display help message for logs command options.
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

# Update node script, completions, container images, and restart services.
update_command() {
    check_running_as_root
    local no_update_service=false
    # Image tag to switch to (--dev or --version); empty keeps the tag in the compose file
    local node_version=""
    local node_version_set="false"
    # Parse args
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        --no-update-service)
            no_update_service=true
            shift
            ;;
        --dev)
            if [[ "$node_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                exit 1
            fi
            node_version="dev"
            node_version_set="true"
            shift
            ;;
        -v | --version)
            if [[ "$node_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                exit 1
            fi
            if [[ -z "${2:-}" ]]; then
                colorized_echo red "Error: --version requires a value."
                exit 1
            fi
            node_version="$2"
            node_version_set="true"
            shift 2
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
    if [ "$node_version_set" = true ]; then
        if ! command -v jq >/dev/null 2>&1; then
            detect_os
            install_package jq
        fi
        if ! command -v yq >/dev/null 2>&1; then
            install_yq
        fi
        if ! validate_node_version; then
            exit 1
        fi
    fi
    detect_compose
    update_node_script
    uninstall_completion
    install_completion
    if [ "$node_version_set" = true ]; then
        # Only the image tag changes; .env, the API key and certificates stay as they are
        colorized_echo blue "Switching node image to: $node_version"
        if [ "$node_version" == "dev" ]; then
            print_dev_image_note
        fi
        if ! set_node_image_tag "$node_version" "$COMPOSE_FILE"; then
            colorized_echo red "✗ Failed to set the node image tag in $COMPOSE_FILE (mikefarah yq v4 is required)"
            exit 1
        fi
        colorized_echo green "✓ Docker image version set to: $node_version"
    fi
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
    # Validate whether a specified Xray-core version exists on GitHub.
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
    # Display the interactive selection menu for available Xray-core versions.
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
# Retrieve the currently installed Xray-core version from binary or running container.
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

# Download, extract, configure, and install a chosen Xray-core binary release.
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

# Open docker-compose.yml in default editor.
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

# Open .env in default editor.
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

# Generate bash auto-completion definition script.
generate_bash_completion() {
    cat <<'EOF'
_node_completions()
{
    local cur cmds
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmds="up down restart status logs install update uninstall install-script uninstall-script core-update geofiles renew-cert certificate-status certificate-renewal-enable show-cert version-script script-version edit edit-env completion service-install service-uninstall service-restart service-status service-logs service-update service-start service-stop"
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
}
EOF
    echo "complete -F _node_completions node.sh"
    echo "complete -F _node_completions $APP_NAME"
}

# Generate zsh auto-completion definition script.
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
  certificate-status
  certificate-renewal-enable
  show-cert
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

# Install bash and zsh completion scripts for the node CLI.
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

# Remove installed bash and zsh completion files.
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

# Display help and usage information for pg-node worker node commands and options.
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
    colorized_echo yellow "  renew-cert        $(tput sgr0)✓  Renew or validate the active certificate source"
    colorized_echo yellow "  version-script    $(tput sgr0)✓  Show script version and commit"
    colorized_echo yellow "  completion        $(tput sgr0)✓  Install bash/zsh tab completion"
    echo
    colorized_echo cyan "Restart Options:"
    colorized_echo yellow "  -n, --no-logs           $(tput sgr0)✓  Do not follow logs after restart"
    colorized_echo yellow "  --no-restart-service    $(tput sgr0)✓  Skip restarting systemd service"
    colorized_echo cyan "Update Options:"
    colorized_echo yellow "  --no-update-service     $(tput sgr0)✓  Skip updating systemd service"
    colorized_echo yellow "  --dev                   $(tput sgr0)✓  Switch to the dev image (unreleased, for testing)"
    colorized_echo yellow "  -v, --version VERSION   $(tput sgr0)✓  Switch to a release tag, latest or pre-release"
    colorized_echo cyan "Uninstall Options:"
    colorized_echo yellow "  -y, --yes               $(tput sgr0)✓  Auto-confirm uninstall and data removal"
    colorized_echo yellow "  --name NAME             $(tput sgr0)✓  Uninstall specific node instance"
    colorized_echo cyan "Install Options:"
    colorized_echo yellow "  -v, --version VERSION   $(tput sgr0)✓  Install specific version"
    colorized_echo yellow "  --pre-release           $(tput sgr0)✓  Install pre-release version"
    colorized_echo yellow "  --dev                   $(tput sgr0)✓  Install the dev image (unreleased, for testing)"
    colorized_echo yellow "  --name NAME             $(tput sgr0)✓  Install with custom name"
    colorized_echo yellow "  --override              $(tput sgr0)✓  Override existing installation"
    colorized_echo yellow "  --api-key KEY           $(tput sgr0)✓  Set API Key"
    colorized_echo yellow "  --use-rest              $(tput sgr0)✓  Use REST protocol instead of GRPC"
    colorized_echo yellow "  --use-grpc              $(tput sgr0)✓  Use GRPC protocol (default)"
    colorized_echo yellow "  --service-port PORT     $(tput sgr0)✓  Set service port"
    colorized_echo yellow "  --cert-path PATH        $(tput sgr0)✓  Set public certificate path"
    colorized_echo yellow "  --key-path PATH         $(tput sgr0)✓  Set private key path"
    echo "  certificate-renewal-enable   Enable managed ACME scheduler after upgrading both services"
    echo "  certificate-status [--json]  Show local renewal and deployment status"
    echo "  show-cert               Display identity, expiry, SHA-256 fingerprint and legacy PEM"
    echo "  --ssl-ip IPV4           Let's Encrypt IP certificate (default; required unattended)"
    echo "  --ssl-ipv6 IPV6         Add IPv6 SAN (requires --ssl-ip)"
    echo "  --ssl-domain DOMAIN     Let's Encrypt domain certificate"
    echo "  --ssl-http-port PORT    HTTP challenge port (alias: --ssl-port; public port 80 must reach it)"
    echo "  --no-ssl                Private backend behind external TLS termination only"
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
    local service_port=""
    local api_key=""
    if [ -f "$APP_DIR/.env" ]; then
        service_port=$(grep '^SERVICE_PORT[[:space:]]*=' "$APP_DIR/.env" 2>/dev/null | sed 's/^SERVICE_PORT[[:space:]]*=[[:space:]]*//' || true)
        api_key=$(grep '^API_KEY[[:space:]]*=' "$APP_DIR/.env" 2>/dev/null | sed 's/^API_KEY[[:space:]]*=[[:space:]]*//' || true)
    fi
    colorized_echo magenta "  Service port: $service_port"
    colorized_echo magenta "  Cert file path: $SSL_CERT_FILE"
    colorized_echo magenta "  API Key : $api_key"
    echo
    current_version=$(get_current_xray_core_version)
    colorized_echo cyan "Current Xray-core version: " 1 # 1 for bold
    colorized_echo magenta "$current_version" 1
    echo
    colorized_echo blue "================================="
    echo
}
# Download regional geoip and geosite rule files and restart node services.
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

# Node certificate management is deliberately independent of panel verification.
cert_error() { colorized_echo red "$*" >&2; return 1; }

node_env_value() {
    [ -f "$ENV_FILE" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | head -n1 | tr -d '\r\"\047' | sed 's/[[:space:]]*$//'
}

load_active_cert_paths() {
    local value
    value=$(node_env_value SSL_CERT_FILE)
    [ -z "$value" ] || SSL_CERT_FILE="$value"
    value=$(node_env_value SSL_KEY_FILE)
    [ -z "$value" ] || SSL_KEY_FILE="$value"
}

# Never source certificate metadata as executable shell code.
cert_metadata() { jq -r --arg key "$1" '.[$key] // empty' "$DATA_DIR/certs/source.json"; }

save_cert_source() {
    local stage
    stage=$(mktemp "$DATA_DIR/certs/.source.XXXXXX") || return 1
    jq -n --arg source "$1" --arg identifier "${2:-}" --arg ipv6 "${3:-}" --arg port "${4:-80}" \
        '{source:$source, identifier:$identifier, ipv6:$ipv6, http_port:$port}' >"$stage" || return 1
    chmod 600 "$stage"
    mv -f "$stage" "$DATA_DIR/certs/source.json"
}

validate_node_cert_pair() (
    set -o pipefail
    local cert="$1" key="$2" identity="${3:-}" ipv6="${4:-}"
    local cert_pub key_pub start end now
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || { cert_error "Invalid certificate: $cert"; return 1; }
    cert_pub=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256) || return 1
    key_pub=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER | openssl dgst -sha256) || return 1
    [ "$cert_pub" = "$key_pub" ] || { cert_error "Certificate and private key do not match"; return 1; }
    start=$(openssl x509 -in "$cert" -startdate -noout); start=$(date -d "${start#*=}" +%s) || return 1
    end=$(openssl x509 -in "$cert" -enddate -noout); end=$(date -d "${end#*=}" +%s) || return 1
    now=$(date +%s)
    [ "$start" -le "$now" ] && [ "$end" -gt "$now" ] || { cert_error "Certificate is expired or not yet valid"; return 1; }
    # Parse every PEM block, rejecting a malformed/truncated full chain.
    local begins ends
    begins=$(grep -c '^-----BEGIN CERTIFICATE-----' "$cert")
    ends=$(grep -c '^-----END CERTIFICATE-----' "$cert")
    [ "$begins" -eq "$ends" ] && openssl crl2pkcs7 -nocrl -certfile "$cert" -outform DER >/dev/null 2>&1 || {
        cert_error 'Invalid certificate chain'; return 1;
    }
    # SAN is mandatory; never rely on Common Name fallback.
    openssl x509 -in "$cert" -noout -ext subjectAltName | grep -qE 'DNS:|IP Address:' || { cert_error "Certificate requires SANs"; return 1; }
    local id flag
    for id in "$identity" "$ipv6"; do
        [ -n "$id" ] || continue
        if is_ip_address "$id"; then flag=-checkip; else
            flag=-checkhost
            openssl x509 -in "$cert" -noout -ext subjectAltName | grep -q 'DNS:' || return 1
        fi
        openssl x509 -in "$cert" -noout "$flag" "$id" | grep -q 'does match certificate' || { cert_error "Certificate SAN does not match $id"; return 1; }
    done
)

# Nested certificate operations (including synchronous ACME reload hooks) share
# the same open lock descriptor. Never unlink the lock file: waiters use its inode.
with_node_cert_lock() {
    local lock_file="$DATA_DIR/certs/.deployment.lock" status=0
    mkdir -p "$DATA_DIR/certs" || return 1
    if [[ "${PG_NODE_CERT_LOCK_FD:-}" =~ ^[0-9]+$ ]] &&
        [ "$(readlink "/proc/self/fd/$PG_NODE_CERT_LOCK_FD")" = "$lock_file" ] &&
        flock -n "$PG_NODE_CERT_LOCK_FD"; then
        "$@"
        return $?
    fi
    local PG_NODE_CERT_LOCK_FD
    exec {PG_NODE_CERT_LOCK_FD}>"$lock_file" || return 1
    if flock -x "$PG_NODE_CERT_LOCK_FD"; then
        export PG_NODE_CERT_LOCK_FD
        "$@" || status=$?
    else
        status=1
    fi
    exec {PG_NODE_CERT_LOCK_FD}>&-
    return "$status"
}

# Stage and validate before touching either active file. Keep backups for rollback.
deploy_node_cert_pair() {
    with_node_cert_lock deploy_node_cert_pair_locked "$@"
}

deploy_node_cert_pair_locked() (
    local cert="$1" key="$2" identity="${3:-}" ipv6="${4:-}"
    validate_node_cert_pair "$cert" "$key" "$identity" "$ipv6" || return 1
    mkdir -p "$(dirname "$SSL_CERT_FILE")" "$(dirname "$SSL_KEY_FILE")" || return 1
    chmod 700 "$(dirname "$SSL_KEY_FILE")" || return 1
    local stage_cert="" stage_key=""
    trap 'rm -f -- "$stage_cert" "$stage_key"' EXIT
    stage_cert=$(mktemp "${SSL_CERT_FILE}.stage.XXXXXX") || return 1
    stage_key=$(mktemp "${SSL_KEY_FILE}.stage.XXXXXX") || return 1
    cp "$cert" "$stage_cert" && cp "$key" "$stage_key" || return 1
    chmod 644 "$stage_cert" && chmod 600 "$stage_key" || return 1
    validate_node_cert_pair "$stage_cert" "$stage_key" "$identity" "$ipv6" || return 1
    if [ -f "$SSL_CERT_FILE" ]; then cp -p "$SSL_CERT_FILE" "${SSL_CERT_FILE}.previous" || return 1; fi
    if [ -f "$SSL_KEY_FILE" ]; then cp -p "$SSL_KEY_FILE" "${SSL_KEY_FILE}.previous" || return 1; fi
    if ! mv -f "$stage_key" "$SSL_KEY_FILE" || ! mv -f "$stage_cert" "$SSL_CERT_FILE"; then
        [ ! -f "${SSL_CERT_FILE}.previous" ] || cp -p "${SSL_CERT_FILE}.previous" "$SSL_CERT_FILE"
        [ ! -f "${SSL_KEY_FILE}.previous" ] || cp -p "${SSL_KEY_FILE}.previous" "$SSL_KEY_FILE"
        cert_error "Deployment failed; restored previous certificate files"
        return 1
    fi
)

validate_node_acme_chain() {
    openssl verify -purpose sslserver -untrusted "$1" "$1" >/dev/null 2>&1 || {
        cert_error 'ACME full chain does not verify against configured system trust'; return 1;
    }
}

get_node_acme() {
    if [ -x "${HOME}/.acme.sh/acme.sh" ]; then printf '%s\n' "${HOME}/.acme.sh/acme.sh"
    elif [ -x /root/.acme.sh/acme.sh ]; then printf '%s\n' /root/.acme.sh/acme.sh
    elif command -v acme.sh >/dev/null 2>&1; then command -v acme.sh
    else return 1; fi
}

ensure_node_acme() {
    local package installer
    for package in socat openssl; do command -v "$package" >/dev/null 2>&1 || install_package "$package" || return 1; done
    if ! command -v crontab >/dev/null 2>&1; then
        case "${OS:-}" in Ubuntu*|Debian*) package=cron;; *) package=cronie;; esac
        install_package "$package" || return 1
    fi
    if ! get_node_acme >/dev/null; then
        installer=$(mktemp) || return 1
        curl -fsSL https://get.acme.sh -o "$installer" && sh "$installer" -- --nocron || return 1
        rm -f "$installer"
    fi
    local acme
    acme=$(get_node_acme) || return 1
    mkdir -p "$DATA_DIR/certs/acme" && chmod 700 "$DATA_DIR/certs/acme" || return 1
}

validate_ssl_selection() {
    local count=0
    [ "${INSTALL_SELF_SIGNED:-false}" != true ] || count=$((count+1))
    [ "${INSTALL_NO_SSL:-false}" != true ] || count=$((count+1))
    [ -z "${INSTALL_SSL_IP:-}" ] || count=$((count+1))
    [ -z "${INSTALL_SSL_DOMAIN:-}" ] || count=$((count+1))
    if [ -n "${INSTALL_CERT_PATH:-}${INSTALL_KEY_PATH:-}" ]; then
        [ -n "${INSTALL_CERT_PATH:-}" ] && [ -n "${INSTALL_KEY_PATH:-}" ] || { cert_error "Use --cert-path and --key-path together"; return 1; }
        count=$((count+1))
    fi
    [ "$count" -le 1 ] || { cert_error "Conflicting certificate selections"; return 1; }
    [ -z "${INSTALL_SSL_IPV6:-}" ] || [ -n "${INSTALL_SSL_IP:-}" ] || { cert_error "--ssl-ipv6 requires --ssl-ip"; return 1; }
    local port="${INSTALL_SSL_HTTP_PORT:-80}"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || { cert_error "Invalid SSL HTTP challenge port"; return 1; }
    if [ "$count" -eq 0 ] && { [ "$AUTO_CONFIRM" = true ] || [ ! -t 0 ]; }; then
        cert_error "Unattended IP issuance requires --ssl-ip IPV4. Old unattended commands must add --self-signed to keep self-signed behavior."
        return 1
    fi
}

# Retained paths can point outside the instance's bind mount. Copy the selected
# active pair into that mount before writing its paths to .env.
prepare_install_node_certificate() {
    choose_node_certificate || return 1
    if [ "$TLS_ENABLED" = true ] &&
        { [[ "$SSL_CERT_FILE" != "$DATA_DIR/"* ]] || [[ "$SSL_KEY_FILE" != "$DATA_DIR/"* ]]; }; then
        local cert="$SSL_CERT_FILE" key="$SSL_KEY_FILE"
        SSL_CERT_FILE="$DATA_DIR/certs/ssl_cert.pem"
        SSL_KEY_FILE="$DATA_DIR/certs/ssl_key.pem"
        deploy_node_cert_pair "$cert" "$key" || return 1
    fi
}

choose_node_certificate() {
    validate_ssl_selection || return 1
    if [ -z "${INSTALL_SSL_IP:-}${INSTALL_SSL_DOMAIN:-}${INSTALL_CERT_PATH:-}" ] && [ "${INSTALL_SELF_SIGNED:-false}" != true ] && [ "${INSTALL_NO_SSL:-false}" != true ]; then
        echo "1) Let's Encrypt IP certificate (default)"
        echo "2) Let's Encrypt domain certificate"
        echo "3) Custom certificate and key paths"
        echo "4) Self-signed certificate"
        echo "   For local IPs, use a self-signed or private CA certificate containing the local IPs."
        echo "   This option generates a self-signed certificate; import a private CA certificate with option 3."
        echo "5) External web server terminates TLS (advanced)"
        local selection
        read -r -p "Certificate [1]: " selection
        case "${selection:-1}" in
            1) read -r -p "Public IPv4 [${NODE_IP_V4:-}]: " INSTALL_SSL_IP
               INSTALL_SSL_IP="${INSTALL_SSL_IP:-${NODE_IP_V4:-}}"
               read -r -p "Optional public IPv6: " INSTALL_SSL_IPV6 ;;
            2) read -r -p "Domain: " INSTALL_SSL_DOMAIN
               [ -n "$INSTALL_SSL_DOMAIN" ] || { cert_error "Domain is required"; return 1; } ;;
            3) read -r -p "Certificate path: " INSTALL_CERT_PATH
               read -r -p "Key path: " INSTALL_KEY_PATH
               [ -n "$INSTALL_CERT_PATH" ] && [ -n "$INSTALL_KEY_PATH" ] || return 1 ;;
            4) INSTALL_SELF_SIGNED=true ;;
            5) INSTALL_NO_SSL=true ;;
            *) cert_error "Invalid certificate selection"; return 1 ;;
        esac
    fi
    TLS_ENABLED=true
    if [ "${INSTALL_NO_SSL:-false}" = true ]; then
        TLS_ENABLED=false
        save_cert_source external_tls
    elif [ "${INSTALL_SELF_SIGNED:-false}" = true ]; then
        local active_cert="$SSL_CERT_FILE" active_key="$SSL_KEY_FILE" stage
        stage=$(mktemp -d "$DATA_DIR/certs/.self-signed.XXXXXX") || return 1
        SSL_CERT_FILE="$stage/fullchain.pem"; SSL_KEY_FILE="$stage/privkey.pem"
        gen_self_signed_cert || return 1
        SSL_CERT_FILE="$active_cert"; SSL_KEY_FILE="$active_key"
        deploy_node_cert_pair "$stage/fullchain.pem" "$stage/privkey.pem" || return 1
        rm -rf "$stage"
        save_cert_source self_signed
    elif [ -n "${INSTALL_CERT_PATH:-}" ]; then
        SSL_CERT_FILE="$DATA_DIR/certs/custom/fullchain.pem"; SSL_KEY_FILE="$DATA_DIR/certs/custom/privkey.pem"
        deploy_node_cert_pair "$INSTALL_CERT_PATH" "$INSTALL_KEY_PATH" || return 1
        save_cert_source custom
    else
        local source=acme_domain identifier="${INSTALL_SSL_DOMAIN:-}" ipv6="${INSTALL_SSL_IPV6:-}"
        if [ -n "${INSTALL_SSL_IP:-}" ]; then source=acme_ip; identifier="$INSTALL_SSL_IP"; fi
        if [ "$source" = acme_ip ]; then
            command -v python3 >/dev/null 2>&1 || install_package python3 || return 1
            python3 - "$identifier" "$ipv6" <<'PYIP' || return 1
import ipaddress, sys
try:
    for value, version in zip(sys.argv[1:], (4, 6)):
        if version == 6 and not value: continue
        addr = ipaddress.ip_address(value)
        if addr.version != version or not addr.is_global or '%' in value:
            raise ValueError('ACME requires public IPv4 and optional public IPv6 identifiers')
except ValueError as err:
    print(err, file=sys.stderr)
    sys.exit(1)
PYIP
        else
            [[ "$identifier" =~ ^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,}$ ]] || { cert_error "Invalid domain identifier"; return 1; }
        fi
        local dir="$identifier"
        [ "$source" != acme_ip ] || dir=ip
        SSL_CERT_FILE="$DATA_DIR/certs/$dir/fullchain.pem"; SSL_KEY_FILE="$DATA_DIR/certs/$dir/privkey.pem"
        issue_node_acme "$source" "$identifier" "$ipv6" "${INSTALL_SSL_HTTP_PORT:-80}" || return 1
        save_cert_source "$source" "$identifier" "$ipv6" "${INSTALL_SSL_HTTP_PORT:-80}"
    fi
}

issue_node_acme() {
    with_node_cert_lock issue_node_acme_locked "$@"
}

issue_node_acme_locked() {
    local source="$1" identifier="$2" ipv6="$3" port="$4" acme
    ensure_node_acme || return 1
    get_occupied_ports
    if is_port_occupied "$port"; then cert_error "Challenge port $port is in use. Configure challenge routing or free it explicitly; no services were stopped."; return 1; fi
    [ "$port" = 80 ] || colorized_echo yellow "Route public TCP port 80 to local challenge port $port."
    acme=$(get_node_acme) || return 1
    local args=(--issue -d "$identifier" --standalone --server letsencrypt --httpport "$port" --force)
    [ -z "$ipv6" ] || args+=(-d "$ipv6")
    [ "$source" != acme_ip ] || args+=(--certificate-profile shortlived --days 4)
    run_node_acme "$acme" "${args[@]}" || { cert_error "ACME issuance failed; existing certificates were preserved. Retry explicitly."; return 1; }
    stage_node_acme "$acme" "$identifier" || return 1
    validate_node_acme_chain "$DATA_DIR/certs/.acme-staging/fullchain.pem" || return 1
    deploy_node_cert_pair "$DATA_DIR/certs/.acme-staging/fullchain.pem" "$DATA_DIR/certs/.acme-staging/privkey.pem" "$identifier" "$ipv6"
}

stage_node_acme() {
    with_node_cert_lock stage_node_acme_locked "$@"
}

stage_node_acme_locked() {
    local acme="$1" identifier="$2" reload="${3:-:}" stage="$DATA_DIR/certs/.acme-staging"
    mkdir -p "$stage" && chmod 700 "$stage" || return 1
    local ecc
    for ecc in '--ecc' ''; do
        local key_target=no cert_target=no
        if [ "$reload" = : ]; then
            # Remove only staging files so a failed install cannot look successful.
            rm -f "$stage/fullchain.pem" "$stage/privkey.pem"
            key_target="$stage/privkey.pem"; cert_target="$stage/fullchain.pem"
        fi
        # For automatic renewals ACME invokes the hook without writing staging.
        # The hook copies ACME's exported source paths while holding our lock.
        local args=(--installcert -d "$identifier" --key-file "$key_target" --fullchain-file "$cert_target" --reloadcmd "$reload")
        [ -z "$ecc" ] || args+=("$ecc")
        if run_node_acme "$acme" "${args[@]}" &&
            { [ "$reload" != : ] || { [ -s "$stage/fullchain.pem" ] && [ -s "$stage/privkey.pem" ]; }; }; then
            if [ "$reload" = : ]; then
                chmod 600 "$stage/privkey.pem" || return 1
                # Do not leave staging as an unattended ACME write target while
                # installation is still preparing the permanent reload hook.
                local reset_args=(--installcert -d "$identifier" --key-file no --fullchain-file no --reloadcmd :)
                [ -z "$ecc" ] || reset_args+=("$ecc")
                run_node_acme "$acme" "${reset_args[@]}" || return 1
            fi
            printf '%s' "$ecc" >"$stage/key-type"
            return 0
        fi
    done
    cert_error "ACME deployment failed; active certificate files were preserved"
}

register_node_acme_reload() {
    with_node_cert_lock register_node_acme_reload_locked "$@"
}

register_node_acme_reload_locked() {
    [ -f "$DATA_DIR/certs/source.json" ] || return 0
    case "$(cert_metadata source)" in acme_ip|acme_domain) ;; *) return 0;; esac
    local acme hook
    acme=$(get_node_acme) || return 1
    migrate_node_acme_storage "$acme" "$(cert_metadata identifier)" || return 1
    # printf %q protects paths with spaces and custom instance names in shell hooks.
    printf -v hook 'env %q %q %q renew-cert --deploy-acme' "DATA_DIR=$DATA_DIR" "APP_DIR=$APP_DIR" "/usr/local/bin/$APP_NAME"
    stage_node_acme "$acme" "$(cert_metadata identifier)" "$hook" || return 1
    install_node_cert_scheduler
}

show_node_certificate() {
    local source=legacy
    [ ! -f "$DATA_DIR/certs/source.json" ] || source=$(cert_metadata source)
    colorized_echo cyan "Certificate source: $source"
    if [ "$source" = external_tls ]; then
        colorized_echo yellow "Configure the panel with the web server's TLS address and ports. Manage its certificate on the web server."
        return 0
    fi
    openssl x509 -in "$SSL_CERT_FILE" -noout -subject -issuer -dates -ext subjectAltName || return 1
    local pin
    pin=$(set -o pipefail; openssl x509 -in "$SSL_CERT_FILE" -outform DER | openssl dgst -sha256 | awk '{print tolower($NF)}') || {
        cert_error "Could not calculate the certificate SHA-256 pin"
        return 1
    }
    [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || { cert_error "Invalid certificate SHA-256 pin"; return 1; }
    colorized_echo cyan "SHA-256 certificate pin (leaf DER): $pin"
    colorized_echo cyan 'PEM for older panels:'
    colorized_echo yellow 'If multiple PEM certificate blocks appear below, copy only the first block (the node certificate) into the panel certificate field, including its BEGIN CERTIFICATE and END CERTIFICATE lines.'
    cat "$SSL_CERT_FILE"
}

# ACME certificate storage is private to this deployment, outside the shared
# client's cron scan. Account/CA configuration remains managed by acme.sh.
run_node_acme() {
    local acme="$1"; shift
    "$acme" --cert-home "$DATA_DIR/certs/acme" "$@"
}

# Move only this certificate out of the shared scheduler. The original client
# command disables its old renewal entry after a complete copy has succeeded.
migrate_node_acme_storage() {
    local acme="$1" identifier="$2" base old suffix
    base=$(dirname "$(readlink -f "$acme")")
    mkdir -p "$DATA_DIR/certs/acme" || return 1
    for suffix in _ecc ''; do
        old="$base/$identifier$suffix"
        if [ -f "$old/$identifier.conf" ]; then
            if [ ! -d "$DATA_DIR/certs/acme/$identifier$suffix" ]; then
                cp -a "$old" "$DATA_DIR/certs/acme/" || return 1
            fi
            local args=(--remove -d "$identifier")
            [ -z "$suffix" ] || args+=(--ecc)
            "$acme" "${args[@]}" || return 1
        fi
    done
}

node_cert_fingerprint() (
    set -o pipefail
    openssl x509 -in "$1" -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print tolower($NF)}'
)

node_cert_status_value() {
    [ -f "$DATA_DIR/certs/renewal-status.json" ] || return 0
    jq -r --arg key "$1" '.[$key] // empty' "$DATA_DIR/certs/renewal-status.json"
}

# Status describes verified listeners separately from the files on disk. A
# failed partial reload must never claim the replacement is active everywhere.
write_node_cert_status() (
    local state="$1" error="${2:-}" next="${3:-0}" failures="${4:-}" stage old='{}'
    local file="$DATA_DIR/certs/renewal-status.json" pin='' expiry='' source=legacy now
    now=$(date +%s)
    [ ! -f "$file" ] || old=$(cat "$file")
    failures="${failures:-$(printf '%s' "$old" | jq -r '.failures // 0')}"
    [ ! -f "$DATA_DIR/certs/source.json" ] || source=$(cert_metadata source)
    pin=$(node_cert_fingerprint "$SSL_CERT_FILE") || pin=''
    expiry=$(openssl x509 -in "$SSL_CERT_FILE" -enddate -noout 2>/dev/null) || expiry=''
    expiry="${expiry#*=}"
    stage=$(mktemp "$DATA_DIR/certs/.status.XXXXXX") || return 1
    trap 'rm -f "$stage"' EXIT
    jq -n --argjson old "$old" --arg source "$source" --arg state "$state" \
        --arg error "$error" --arg pin "$pin" --arg expiry "$expiry" \
        --argjson now "$now" --argjson next "$next" --argjson failures "$failures" \
        '$old + {source:$source, deployment_state:$state, error:$error,
          file_fingerprint:$pin, file_expiry:$expiry, next_attempt:$next, failures:$failures}
        | if $state == "attempting" then .last_attempt=$now else . end
        | if $state == "deployed" then .active_fingerprint=$pin | .expiry=$expiry |
          .last_success=$now | .failures=0 | .error="" else . end' >"$stage" || return 1
    chmod 600 "$stage" && mv -f "$stage" "$file"
)

certificate_status_command() {
    [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --json ]; } || { cert_error 'Usage: certificate-status [--json]'; return 1; }
    load_active_cert_paths
    local source=legacy status='{}' expiry='' valid=false
    [ ! -f "$DATA_DIR/certs/source.json" ] || source=$(cert_metadata source)
    [ ! -f "$DATA_DIR/certs/renewal-status.json" ] || status=$(cat "$DATA_DIR/certs/renewal-status.json")
    expiry=$(openssl x509 -in "$SSL_CERT_FILE" -enddate -noout 2>/dev/null) || expiry=''
    # Date validity is live; a persisted success does not make expired files valid.
    if validate_node_cert_pair "$SSL_CERT_FILE" "$SSL_KEY_FILE" >/dev/null 2>&1; then valid=true; fi
    status=$(jq -n --argjson old "$status" --arg source "$source" --arg expiry "${expiry#*=}" \
        --argjson valid "$valid" '$old + {source:$source, files_currently_valid:$valid, file_expiry:$expiry}
        | .deployment_state //= "unknown" | .active_fingerprint //= null | .expiry //= null
        | .last_attempt //= null | .last_success //= null | .next_attempt //= null | .error //= ""') || return 1
    if [ "${1:-}" = --json ]; then printf '%s\n' "$status"
    else printf '%s\n' "$status" | jq -r 'to_entries[] | "\(.key): \(.value)"'; fi
}

reload_node_cert_services() {
    detect_compose
    local failed=0
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" kill --signal SIGHUP node || failed=1
    if service_installed; then
        systemctl kill --kill-whom=main --signal=SIGHUP "$SERVICE_NAME" || failed=1
    fi
    return "$failed"
}

# Each invocation opens a new TLS socket, with no session cache or resumption.
verify_node_cert_endpoint() (
    set -o pipefail
    local host="$1" port="$2" expected="$3" identity="$4" peer connect
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    connect="$host:$port"
    [[ "$host" != *:* ]] || connect="[$host]:$port"
    peer=$(timeout 10 openssl s_client -connect "$connect" -servername "$identity" -showcerts </dev/null 2>/dev/null |
        openssl x509 -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print tolower($NF)}') || return 1
    [ "$peer" = "$expected" ]
)

verify_node_cert_services() {
    local pin identity host port attempt
    pin=$(node_cert_fingerprint "$SSL_CERT_FILE") || return 1
    identity=$(cert_metadata identifier 2>/dev/null) || identity=''
    host=$(node_env_value NODE_HOST); host="${host:-127.0.0.1}"
    case "$host" in 0.0.0.0) host=127.0.0.1;; ::|'[::]') host=::1;; esac
    local ports=("$(node_env_value SERVICE_PORT)")
    if service_installed; then ports+=("$(node_env_value API_PORT)"); fi
    for port in "${ports[@]}"; do
        for attempt in 1 2 3 4 5; do
            if verify_node_cert_endpoint "$host" "$port" "$pin" "${identity:-$host}"; then break; fi
            [ "$attempt" -lt 5 ] || return 1
            sleep 1
        done
    done
}

finish_node_cert_deployment() {
    if ! validate_node_cert_pair "$SSL_CERT_FILE" "$SSL_KEY_FILE"; then
        write_node_cert_status invalid_files 'Current certificate files are invalid or expired; no reload attempted' "$(( $(date +%s) + 300 ))"
        return 1
    fi
    if reload_node_cert_services && verify_node_cert_services; then
        write_node_cert_status deployed '' "$(( $(date +%s) + 3600 ))" || return 1
        colorized_echo green 'Certificate hot reload verified on all configured TLS endpoints.'
    else
        write_node_cert_status reload_pending 'Reload or endpoint verification failed; no restart attempted' "$(( $(date +%s) + 300 ))" || return 1
        cert_error 'Certificate reload incomplete. Retained files and backups; retrying reload without issuance.'
        return 1
    fi
}

# One cron entry per deployment. The installed command preserves DATA_DIR and
# APP_DIR; % must be escaped even within shell quotes in a crontab.
install_node_cert_scheduler() {
    local entry entries stage
    printf -v entry '*/5 * * * * env %q %q %q certificate-renewal-tick >>%q 2>&1 # pg-node-cert:%s' \
        "DATA_DIR=$DATA_DIR" "APP_DIR=$APP_DIR" "/usr/local/bin/$APP_NAME" "$DATA_DIR/certs/renewal.log" "$APP_NAME"
    entry="${entry//%/\\%}"
    touch "$DATA_DIR/certs/renewal.log" && chmod 600 "$DATA_DIR/certs/renewal.log" || return 1
    entries=$(crontab -l 2>/dev/null) || entries=''
    stage=$(mktemp) || return 1
    printf '%s\n' "$entries" | sed "/# pg-node-cert:${APP_NAME}$/d" >"$stage"
    printf '%s\n' "$entry" >>"$stage"
    crontab "$stage"
    local result=$?
    rm -f "$stage"
    return "$result"
}

remove_node_cert_scheduler() {
    local entries stage
    entries=$(crontab -l 2>/dev/null) || return 0
    stage=$(mktemp) || return 1
    printf '%s\n' "$entries" | sed "/# pg-node-cert:${APP_NAME}$/d" >"$stage"
    crontab "$stage"
    local result=$?
    rm -f "$stage"
    return "$result"
}

node_cert_config_digest() {
    { cat "$DATA_DIR/certs/source.json" "$ENV_FILE"; } | sha256sum | awk '{print $1}'
}

certificate_renewal_tick() {
    check_running_as_root
    with_node_cert_lock certificate_renewal_tick_locked
}

certificate_renewal_tick_locked() {
    local source state next now digest
    [ -f "$DATA_DIR/certs/source.json" ] || return 0
    source=$(cert_metadata source)
    case "$source" in acme_ip|acme_domain) ;; *) return 0;; esac
    load_active_cert_paths
    now=$(date +%s); next=$(node_cert_status_value next_attempt)
    state=$(node_cert_status_value deployment_state)
    digest=$(node_cert_config_digest) || return 1
    if [ "$state" = suspended ]; then
        [ "$(cat "$DATA_DIR/certs/.suspended-config" 2>/dev/null)" != "$digest" ] || return 0
    elif [ "${next:-0}" -gt "$now" ]; then return 0; fi
    case "$state" in
        reload_pending) finish_node_cert_deployment;;
        deployment_pending) renew_cert_command_locked --deploy-acme;;
        *) renew_node_acme_scheduled;;
    esac
}

# acme.sh evaluates ARI during --renew. Supply an exact lifetime-based fallback
# without --days, which would pin its schedule and reject later CA windows.
# Only the isolated, locked domain configuration is edited, never sourced here.
set_node_acme_fallback() (
    local identifier="$1" due="$2" suffix='' config stage
    [ "$(cat "$DATA_DIR/certs/.acme-staging/key-type" 2>/dev/null)" != --ecc ] || suffix=_ecc
    config="$DATA_DIR/certs/acme/$identifier$suffix/$identifier.conf"
    [ -f "$config" ] || return 0
    stage=$(mktemp "${config}.stage.XXXXXX") || return 1
    trap 'rm -f "$stage"' EXIT
    sed '/^Le_RenewalDays=/d; /^Le_NextRenewTime=/d' "$config" >"$stage" || return 1
    printf "Le_NextRenewTime='%s'\n" "$due" >>"$stage"
    chmod 600 "$stage" && mv -f "$stage" "$config"
)

renew_node_acme_scheduled() {
    local acme identifier rc=0 start end now failures delay retry_after
    acme=$(get_node_acme) || { node_cert_config_digest >"$DATA_DIR/certs/.suspended-config"; write_node_cert_status suspended 'ACME client is missing'; return 1; }
    identifier=$(cert_metadata identifier)
    if [ -z "$identifier" ]; then
        node_cert_config_digest >"$DATA_DIR/certs/.suspended-config"
        write_node_cert_status suspended 'ACME identifier is missing'; return 1
    fi
    now=$(date +%s)
    start=$(openssl x509 -in "$SSL_CERT_FILE" -startdate -noout); start=$(date -d "${start#*=}" +%s) || return 1
    end=$(openssl x509 -in "$SSL_CERT_FILE" -enddate -noout); end=$(date -d "${end#*=}" +%s) || return 1
    set_node_acme_fallback "$identifier" "$((start+(end-start)*2/3))" || return 1
    write_node_cert_status attempting || return 1
    local args=(--renew -d "$identifier")
    [ "$(cat "$DATA_DIR/certs/.acme-staging/key-type" 2>/dev/null)" != --ecc ] || args+=(--ecc)
    # acme.sh honors ARI and CA polling delays. Keep private diagnostic output
    # local; only fixed, sanitized messages go into machine-readable status.
    (umask 077; run_node_acme "$acme" "${args[@]}" >"$DATA_DIR/certs/acme-last-attempt.log" 2>&1) || rc=$?
    # A hook may already have recorded a partial reload. Never issue again.
    case "$(node_cert_status_value deployment_state)" in reload_pending|deployment_pending) return 1;; esac
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
        if [ "$(node_cert_status_value deployment_state)" = deployed ]; then return 0; fi
        if [ "$rc" -eq 0 ]; then
            node_cert_config_digest >"$DATA_DIR/certs/.suspended-config"
            write_node_cert_status suspended 'ACME completed without running the deployment hook; run certificate-renewal-enable'
            return 1
        fi
        write_node_cert_status waiting '' "$((now+3600))"
        return 0
    fi
    if grep -Eqi 'unauthorized|rejectedIdentifier|invalidContact|accountDoesNotExist|Invalid domain|Challenge port .* in use' "$DATA_DIR/certs/acme-last-attempt.log"; then
        node_cert_config_digest >"$DATA_DIR/certs/.suspended-config"
        write_node_cert_status suspended 'ACME configuration rejected; correct configuration or run renew-cert'
        return 1
    fi
    failures=$(node_cert_status_value failures); failures=$((${failures:-0}+1))
    delay=300
    local i
    for ((i=1; i<failures && delay<3600; i++)); do delay=$((delay*2)); done
    [ "$delay" -lt 3600 ] || delay=3600
    delay=$((delay + RANDOM % (delay/5+1)))
    [ "$delay" -le 3600 ] || delay=3600
    retry_after=$(sed -nE 's/.*[Rr]etry-[Aa]fter:[[:space:]]*(.*)/\1/p' "$DATA_DIR/certs/acme-last-attempt.log" | tail -1 | tr -d '\r')
    if [[ "$retry_after" =~ ^[0-9]{1,9}$ ]]; then
        [ "$retry_after" -le "$delay" ] || delay="$retry_after"
    elif [ -n "$retry_after" ]; then
        retry_after=$(date -d "$retry_after" +%s 2>/dev/null) || retry_after=0
        [ "$retry_after" -le "$((now+delay))" ] || delay=$((retry_after-now))
    fi
    write_node_cert_status retry_pending 'Transient ACME failure; see acme-last-attempt.log' "$((now+delay))" "$failures"
    return 1
}

renew_cert_command() {
    with_node_cert_lock renew_cert_command_locked "$@"
}

renew_cert_command_locked() {
    check_running_as_root
    ensure_env_exists
    load_active_cert_paths
    case "${1:-}" in
        ''|--deploy-acme) [ "$#" -le 1 ] || return 1;;
        *) cert_error 'Usage: renew-cert [--deploy-acme]'; return 1;;
    esac
    local source=legacy
    [ ! -f "$DATA_DIR/certs/source.json" ] || source=$(cert_metadata source)
    if [ "${1:-}" = --deploy-acme ]; then
        case "$source" in acme_ip|acme_domain) ;; *) cert_error 'ACME hook requires a managed ACME source'; return 1;; esac
    fi
    if [ "$source" = legacy ]; then
        local subject issuer
        subject=$(openssl x509 -in "$SSL_CERT_FILE" -noout -subject 2>/dev/null | sed 's/^subject= *//')
        issuer=$(openssl x509 -in "$SSL_CERT_FILE" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
        if [ -n "$subject" ] && [ "$subject" = "$issuer" ]; then source=self_signed; fi
    fi
    case "$source" in
        acme_ip|acme_domain)
            local acme identifier ipv6
            acme=$(get_node_acme) || return 1
            identifier=$(cert_metadata identifier); ipv6=$(cert_metadata ipv6)
            if [ "${1:-}" != --deploy-acme ]; then
                # An explicit retry first completes any pending deployment.
                if [ "$(node_cert_status_value deployment_state)" = deployment_pending ]; then
                    renew_cert_command_locked --deploy-acme
                    return $?
                fi
                if [ "$(node_cert_status_value deployment_state)" = reload_pending ]; then
                    finish_node_cert_deployment
                    return $?
                fi
                write_node_cert_status attempting || return 1
                # The registered hook deploys and verifies both listeners.
                # Explicit retry clears suspension but still honors CA due times.
                register_node_acme_reload || return 1
                renew_node_acme_scheduled || return 1
                show_node_certificate || return 1
                return 0
            fi
            write_node_cert_status deployment_pending 'Certificate staging or validation pending; previous active observation retained' "$(( $(date +%s) + 300 ))" || return 1
            if [ -n "${CERT_FULLCHAIN_PATH:-}${CERT_KEY_PATH:-}" ]; then
                [ -n "${CERT_FULLCHAIN_PATH:-}" ] && [ -n "${CERT_KEY_PATH:-}" ] || return 1
                local stage="$DATA_DIR/certs/.acme-staging"
                mkdir -p "$stage" && chmod 700 "$stage" || return 1
                cp "$CERT_FULLCHAIN_PATH" "$stage/fullchain.pem" &&
                    cp "$CERT_KEY_PATH" "$stage/privkey.pem" &&
                    chmod 600 "$stage/privkey.pem" || return 1
            fi
            validate_node_acme_chain "$DATA_DIR/certs/.acme-staging/fullchain.pem" || return 1
            deploy_node_cert_pair "$DATA_DIR/certs/.acme-staging/fullchain.pem" "$DATA_DIR/certs/.acme-staging/privkey.pem" "$identifier" "$ipv6" || return 1
            ;;
        self_signed)
            write_node_cert_status attempting || return 1
            # Reuse the active certificate's names, including on unattended renewals.
            local INSTALL_SAN_ENTRIES
            INSTALL_SAN_ENTRIES=$(set -o pipefail; openssl x509 -in "$SSL_CERT_FILE" -noout -ext subjectAltName |
                tr ',' '\n' | sed -n 's/^[[:space:]]*DNS:/DNS:/p; s/^[[:space:]]*IP Address:/IP:/p' |
                paste -sd, -) || { cert_error "Could not read existing certificate SANs"; return 1; }
            [ -n "$INSTALL_SAN_ENTRIES" ] || { cert_error "Existing certificate requires DNS or IP SANs for renewal"; return 1; }
            INSTALL_SELF_SIGNED=true
            choose_node_certificate || return 1
            ;;
        custom|legacy)
            write_node_cert_status attempting || return 1
            validate_node_cert_pair "$SSL_CERT_FILE" "$SSL_KEY_FILE" || return 1
            colorized_echo yellow "Custom/legacy certificates are externally renewed. Validated current files; no certificate was regenerated."
            ;;
        external_tls) colorized_echo yellow "Manage and renew the certificate on the TLS web server."; return 0 ;;
        *) cert_error "Unknown certificate source: $source"; return 1 ;;
    esac
    finish_node_cert_deployment || return 1
    if [ "${1:-}" = --deploy-acme ]; then
        colorized_echo green "ACME certificate deployed; TLS hot reload verified."
    else
        show_node_certificate
    fi
}

# Main CLI dispatch handler for pg-node.
pg_node_main() {
    # Upgrades keep the active certificate paths and files unchanged.
    load_active_cert_paths

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
    show-cert)
        show_node_certificate
        ;;
    certificate-status)
        shift
        certificate_status_command "$@"
        ;;
    certificate-renewal-enable)
        check_running_as_root
        register_node_acme_reload
        ;;
    certificate-renewal-tick)
        certificate_renewal_tick
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
        install_service_command "$@"
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
