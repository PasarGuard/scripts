#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SHARED_LIB_DIR="${SCRIPT_DIR}/lib"
REQUIRED_SHARED_LIBS="common.sh system.sh docker.sh github.sh env.sh pasarguard-backup.sh pasarguard-restore.sh"
if [ ! -f "$SHARED_LIB_DIR/common.sh" ]; then
    SHARED_LIB_DIR="/usr/local/lib/pasarguard-scripts/lib"
fi

bootstrap_pasarguard_shared_libs() {
    local fetch_repo="PasarGuard/scripts"
    local bootstrap_dir="/usr/local/lib/pasarguard-scripts/lib"
    local tmp_dir=""
    local shared_lib=""

    tmp_dir=$(mktemp -d) || return 1
    mkdir -p "$bootstrap_dir" || {
        rm -rf "$tmp_dir"
        return 1
    }

    for shared_lib in $REQUIRED_SHARED_LIBS; do
        if ! curl -fsSL "https://github.com/${fetch_repo}/raw/main/lib/${shared_lib}" -o "$tmp_dir/$shared_lib"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        if ! install -m 644 "$tmp_dir/$shared_lib" "$bootstrap_dir/$shared_lib"; then
            rm -rf "$tmp_dir"
            return 1
        fi
    done

    rm -rf "$tmp_dir"
    SHARED_LIB_DIR="$bootstrap_dir"
    return 0
}

missing_shared_lib=false
for shared_lib in $REQUIRED_SHARED_LIBS; do
    if [ ! -f "$SHARED_LIB_DIR/$shared_lib" ]; then
        missing_shared_lib=true
        break
    fi
done

if [ "$missing_shared_lib" = true ]; then
    bootstrap_pasarguard_shared_libs
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
# shellcheck source=lib/env.sh
source "$SHARED_LIB_DIR/env.sh"
# shellcheck source=lib/pasarguard-backup.sh
source "$SHARED_LIB_DIR/pasarguard-backup.sh"
# shellcheck source=lib/pasarguard-restore.sh
source "$SHARED_LIB_DIR/pasarguard-restore.sh"

# Handle @ symbol if used in installation (skip it)
if [ "$1" == "@" ]; then
    shift
fi

INSTALL_DIR="/opt"
if [ -z "$APP_NAME" ]; then
    APP_NAME="pasarguard"
fi
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
THEMES_DIR="$APP_DIR/themes"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
LAST_XRAY_CORES=10

is_valid_proxy_url() {
    local proxy_url="$1"
    [[ -z "$proxy_url" ]] && return 1
    if [[ "$proxy_url" =~ ^(http|https|socks|socks4|socks4a|socks5|socks5h):// ]]; then
        return 0
    fi
    return 1
}

get_backup_proxy_url() {
    local proxy_value="${BACKUP_PROXY_URL:-${BACKUP_PROXY:-}}"
    local proxy_enabled="${BACKUP_PROXY_ENABLED:-}"

    if [ -z "$proxy_value" ]; then
        return 1
    fi

    if [ -n "$proxy_enabled" ] && [[ ! "$proxy_enabled" =~ ^([Tt]rue|[Yy]es|1)$ ]]; then
        return 1
    fi

    printf '%s\n' "$proxy_value"
    return 0
}

is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

is_ipv4() {
    local ip="$1"
    local IFS='.'
    local octets=()

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<<"$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1

    for octet in "${octets[@]}"; do
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            return 1
        fi
    done

    return 0
}

is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}

get_public_ipv4() {
    local urls=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.ident.me"
        "https://ipv4.myexternalip.com/raw"
        "https://ifconfig.me/ip"
    )
    local server_ip=""
    local url=""

    for url in "${urls[@]}"; do
        server_ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if is_ipv4 "$server_ip"; then
            echo "$server_ip"
            return 0
        fi
    done

    return 1
}

is_port_in_use() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi

    return 1
}

ensure_acme_dependencies() {
    command -v socat >/dev/null 2>&1 || install_package socat
    command -v openssl >/dev/null 2>&1 || install_package openssl
}

install_acme() {
    colorized_echo blue "Installing acme.sh for SSL certificate management..."
    if curl -s https://get.acme.sh | sh >/dev/null 2>&1; then
        colorized_echo green "acme.sh installed successfully"
        return 0
    fi
    colorized_echo red "Failed to install acme.sh"
    return 1
}

get_acme_sh_binary() {
    if [ -x "${HOME}/.acme.sh/acme.sh" ]; then
        echo "${HOME}/.acme.sh/acme.sh"
        return 0
    fi

    if [ -x "/root/.acme.sh/acme.sh" ]; then
        echo "/root/.acme.sh/acme.sh"
        return 0
    fi

    if command -v acme.sh >/dev/null 2>&1; then
        command -v acme.sh
        return 0
    fi

    return 1
}

ensure_acme_auto_renew() {
    local acme_bin="$1"

    [ -n "$acme_bin" ] || return 0
    "$acme_bin" --upgrade --auto-upgrade >/dev/null 2>&1 || true
    "$acme_bin" --install-cronjob >/dev/null 2>&1 || true
}

build_pasarguard_ssl_reload_command() {
    local backend_service=""
    backend_service=$(detect_pasarguard_backend_service 2>/dev/null || true)

    if [ -n "$backend_service" ]; then
        echo "docker compose -f ${COMPOSE_FILE} -p ${APP_NAME} restart ${backend_service} >/dev/null 2>&1 || docker-compose -f ${COMPOSE_FILE} -p ${APP_NAME} restart ${backend_service} >/dev/null 2>&1 || docker compose -f ${COMPOSE_FILE} -p ${APP_NAME} restart >/dev/null 2>&1 || docker-compose -f ${COMPOSE_FILE} -p ${APP_NAME} restart >/dev/null 2>&1 || true"
    else
        echo "docker compose -f ${COMPOSE_FILE} -p ${APP_NAME} restart >/dev/null 2>&1 || docker-compose -f ${COMPOSE_FILE} -p ${APP_NAME} restart >/dev/null 2>&1 || true"
    fi
}

has_nonempty_ssl_pair() {
    local cert_file="$1"
    local key_file="$2"

    [ -s "$cert_file" ] && [ -s "$key_file" ]
}

copy_acme_cert_pair_from_store() {
    local identifier="$1"
    local cert_file="$2"
    local key_file="$3"
    local acme_home=""
    local candidate_dir=""
    local candidate_cert=""
    local candidate_key=""

    for acme_home in "${HOME}/.acme.sh" "/root/.acme.sh"; do
        [ -d "$acme_home" ] || continue
        for candidate_dir in "${acme_home}/${identifier}" "${acme_home}/${identifier}_ecc"; do
            [ -d "$candidate_dir" ] || continue

            candidate_cert="${candidate_dir}/fullchain.cer"
            [ -s "$candidate_cert" ] || candidate_cert="${candidate_dir}/${identifier}.cer"
            candidate_key="${candidate_dir}/${identifier}.key"

            if [ -s "$candidate_cert" ] && [ -s "$candidate_key" ] &&
                cp "$candidate_cert" "$cert_file" &&
                cp "$candidate_key" "$key_file"; then
                return 0
            fi
        done
    done

    return 1
}

install_acme_cert_pair() {
    local acme_bin="$1"
    local identifier="$2"
    local cert_dir="$3"
    local reload_cmd="$4"
    local cert_file="${cert_dir}/fullchain.pem"
    local key_file="${cert_dir}/privkey.pem"

    "$acme_bin" --installcert -d "$identifier" \
        --key-file "$key_file" \
        --fullchain-file "$cert_file" \
        --reloadcmd "$reload_cmd" >/dev/null 2>&1 || true
    if has_nonempty_ssl_pair "$cert_file" "$key_file"; then
        return 0
    fi

    "$acme_bin" --installcert -d "$identifier" --ecc \
        --key-file "$key_file" \
        --fullchain-file "$cert_file" \
        --reloadcmd "$reload_cmd" >/dev/null 2>&1 || true
    if has_nonempty_ssl_pair "$cert_file" "$key_file"; then
        return 0
    fi

    if copy_acme_cert_pair_from_store "$identifier" "$cert_file" "$key_file" &&
        has_nonempty_ssl_pair "$cert_file" "$key_file"; then
        return 0
    fi

    rm -f "$cert_file" "$key_file" 2>/dev/null || true
    return 1
}

setup_ssl_certificate() {
    local domain="$1"
    local http_port="${2:-80}"
    local acme_bin=""
    local cert_dir="$DATA_DIR/certs/${domain}"
    local reload_cmd=""

    if [ -z "$domain" ]; then
        colorized_echo red "Domain is required for SSL certificate issuance."
        return 1
    fi

    if ! is_domain "$domain"; then
        colorized_echo red "Invalid domain format: ${domain}"
        return 1
    fi

    if ! [[ "$http_port" =~ ^[0-9]+$ ]] || [ "$http_port" -lt 1 ] || [ "$http_port" -gt 65535 ]; then
        colorized_echo red "Invalid HTTP challenge port: ${http_port}"
        return 1
    fi

    ensure_acme_dependencies

    if ! acme_bin=$(get_acme_sh_binary); then
        install_acme || return 1
        acme_bin=$(get_acme_sh_binary) || {
            colorized_echo red "acme.sh binary not found after installation."
            return 1
        }
    fi

    if is_port_in_use "$http_port"; then
        colorized_echo yellow "Port ${http_port} is already in use. SSL issuance may fail unless that service is stopped."
    fi

    mkdir -p "$cert_dir"
    reload_cmd=$(build_pasarguard_ssl_reload_command)

    colorized_echo blue "Issuing Let's Encrypt certificate for ${domain}..."
    "$acme_bin" --set-default-ca --server letsencrypt --force >/dev/null 2>&1 || true
    if ! "$acme_bin" --issue -d "$domain" --standalone --httpport "$http_port" --force; then
        colorized_echo red "Failed to issue certificate for ${domain}."
        rm -rf "${HOME}/.acme.sh/${domain}" "$cert_dir" 2>/dev/null || true
        return 1
    fi

    if ! install_acme_cert_pair "$acme_bin" "$domain" "$cert_dir" "$reload_cmd"; then
        colorized_echo red "Failed to install certificate for ${domain}."
        return 1
    fi

    ensure_acme_auto_renew "$acme_bin"
    chmod 600 "${cert_dir}/privkey.pem" 2>/dev/null || true
    chmod 644 "${cert_dir}/fullchain.pem" 2>/dev/null || true

    colorized_echo green "SSL certificate installed successfully."
    colorized_echo green "Certificate: ${cert_dir}/fullchain.pem"
    colorized_echo green "Private key: ${cert_dir}/privkey.pem"
    return 0
}

setup_ip_ssl_certificate() {
    local ipv4="$1"
    local ipv6="$2"
    local http_port="${3:-80}"
    local acme_bin=""
    local cert_dir="$DATA_DIR/certs/ip"
    local reload_cmd=""
    local domain_args=()

    if ! is_ipv4 "$ipv4"; then
        colorized_echo red "Invalid IPv4 address: ${ipv4}"
        return 1
    fi

    if [ -n "$ipv6" ] && ! is_ipv6 "$ipv6"; then
        colorized_echo red "Invalid IPv6 address: ${ipv6}"
        return 1
    fi

    if ! [[ "$http_port" =~ ^[0-9]+$ ]] || [ "$http_port" -lt 1 ] || [ "$http_port" -gt 65535 ]; then
        colorized_echo red "Invalid HTTP challenge port: ${http_port}"
        return 1
    fi

    ensure_acme_dependencies

    if ! acme_bin=$(get_acme_sh_binary); then
        install_acme || return 1
        acme_bin=$(get_acme_sh_binary) || {
            colorized_echo red "acme.sh binary not found after installation."
            return 1
        }
    fi

    if is_port_in_use "$http_port"; then
        colorized_echo yellow "Port ${http_port} is already in use. SSL issuance may fail unless that service is stopped."
    fi

    mkdir -p "$cert_dir"
    reload_cmd=$(build_pasarguard_ssl_reload_command)
    domain_args=(-d "$ipv4")
    if [ -n "$ipv6" ]; then
        domain_args+=(-d "$ipv6")
    fi

    colorized_echo blue "Issuing Let's Encrypt IP certificate for ${ipv4}..."
    "$acme_bin" --set-default-ca --server letsencrypt --force >/dev/null 2>&1 || true
    if ! "$acme_bin" --issue \
        "${domain_args[@]}" \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport "$http_port" \
        --force; then
        colorized_echo red "Failed to issue IP certificate."
        rm -rf "${HOME}/.acme.sh/${ipv4}" "$cert_dir" 2>/dev/null || true
        [ -n "$ipv6" ] && rm -rf "${HOME}/.acme.sh/${ipv6}" 2>/dev/null || true
        return 1
    fi

    if ! install_acme_cert_pair "$acme_bin" "$ipv4" "$cert_dir" "$reload_cmd"; then
        colorized_echo red "Failed to install IP certificate files."
        rm -rf "$cert_dir" 2>/dev/null || true
        return 1
    fi

    ensure_acme_auto_renew "$acme_bin"
    chmod 600 "${cert_dir}/privkey.pem" 2>/dev/null || true
    chmod 644 "${cert_dir}/fullchain.pem" 2>/dev/null || true

    colorized_echo green "IP certificate installed successfully."
    colorized_echo green "Certificate: ${cert_dir}/fullchain.pem"
    colorized_echo green "Private key: ${cert_dir}/privkey.pem"
    return 0
}

configure_custom_ssl_certificate() {
    local cert_source="$1"
    local key_source="$2"
    local ca_type="${3:-public}"
    local cert_dir="$DATA_DIR/certs/custom"
    local target_cert="${cert_dir}/fullchain.pem"
    local target_key="${cert_dir}/privkey.pem"

    if [ ! -f "$cert_source" ] || [ ! -r "$cert_source" ] || [ ! -s "$cert_source" ]; then
        colorized_echo red "Certificate file is missing or unreadable: $cert_source"
        return 1
    fi
    if [ ! -f "$key_source" ] || [ ! -r "$key_source" ] || [ ! -s "$key_source" ]; then
        colorized_echo red "Key file is missing or unreadable: $key_source"
        return 1
    fi

    mkdir -p "$cert_dir"
    cp "$cert_source" "$target_cert"
    cp "$key_source" "$target_key"
    chmod 644 "$target_cert" 2>/dev/null || true
    chmod 600 "$target_key" 2>/dev/null || true

    enable_pasarguard_ssl_env "$target_cert" "$target_key" "$ca_type"
    colorized_echo green "Custom SSL certificate configured successfully."
    return 0
}

enable_pasarguard_ssl_env() {
    local cert_file="$1"
    local key_file="$2"
    local ca_type="${3:-public}"

    set_or_uncomment_env_var "UVICORN_SSL_CERTFILE" "$cert_file" true "$ENV_FILE"
    set_or_uncomment_env_var "UVICORN_SSL_KEYFILE" "$key_file" true "$ENV_FILE"
    set_or_uncomment_env_var "UVICORN_SSL_CA_TYPE" "$ca_type" true "$ENV_FILE"
}

disable_pasarguard_ssl_env() {
    comment_out_env_var "UVICORN_SSL_CERTFILE" "$ENV_FILE"
    comment_out_env_var "UVICORN_SSL_KEYFILE" "$ENV_FILE"
    comment_out_env_var "UVICORN_SSL_CA_TYPE" "$ENV_FILE"
}

setup_pasarguard_ssl_during_install() {
    local ssl_mode="$1"
    local ssl_domain="$2"
    local ssl_http_port="$3"
    local ssl_choice=""
    local detected_ipv4=""
    local input_ipv4=""
    local input_ipv6=""
    local custom_cert=""
    local custom_key=""
    local custom_ca_choice=""
    local custom_ca_type="public"

    if [ "$ssl_mode" = "disabled" ]; then
        disable_pasarguard_ssl_env
        colorized_echo yellow "Skipping SSL setup (--no-ssl). PasarGuard will bind to localhost only."
        return 0
    fi

    if ! [[ "$ssl_http_port" =~ ^[0-9]+$ ]] || [ "$ssl_http_port" -lt 1 ] || [ "$ssl_http_port" -gt 65535 ]; then
        colorized_echo red "Invalid SSL HTTP challenge port: ${ssl_http_port}"
        return 1
    fi

    if [ "$ssl_mode" = "domain" ] && [ -n "$ssl_domain" ]; then
        ssl_choice="1"
    else
        colorized_echo cyan "Choose SSL setup method for panel installation:"
        colorized_echo green "  1) Let's Encrypt Domain certificate"
        colorized_echo green "  2) Let's Encrypt IP certificate (short-lived)"
        colorized_echo green "  3) Custom certificate + key paths"
        colorized_echo yellow "  4) No SSL"
        colorized_echo yellow "Port 80 (or configured --ssl-http-port) must be reachable for Let's Encrypt."
        read -p "Select SSL option [1-4] (default: 1): " ssl_choice
        ssl_choice="${ssl_choice// /}"
        [ -z "$ssl_choice" ] && ssl_choice="1"
    fi

    case "$ssl_choice" in
    1)
        while [ -z "$ssl_domain" ]; do
            read -p "Enter domain for SSL certificate (example: panel.example.com): " ssl_domain
            ssl_domain="${ssl_domain// /}"

            if [ -z "$ssl_domain" ]; then
                colorized_echo red "Domain cannot be empty."
                continue
            fi

            if ! is_domain "$ssl_domain"; then
                colorized_echo red "Invalid domain format: ${ssl_domain}"
                ssl_domain=""
            fi
        done

        if setup_ssl_certificate "$ssl_domain" "$ssl_http_port"; then
            enable_pasarguard_ssl_env "${DATA_DIR}/certs/${ssl_domain}/fullchain.pem" "${DATA_DIR}/certs/${ssl_domain}/privkey.pem" "public"
            colorized_echo green "SSL enabled for https://${ssl_domain}:8000/dashboard/"
            return 0
        fi
        ;;
    2)
        detected_ipv4=$(get_public_ipv4 || true)
        if [ -n "$detected_ipv4" ]; then
            read -p "Enter IPv4 for SSL certificate (default: ${detected_ipv4}): " input_ipv4
            input_ipv4="${input_ipv4// /}"
            [ -z "$input_ipv4" ] && input_ipv4="$detected_ipv4"
        else
            read -p "Enter IPv4 for SSL certificate: " input_ipv4
            input_ipv4="${input_ipv4// /}"
        fi

        if ! is_ipv4 "$input_ipv4"; then
            colorized_echo red "Invalid IPv4 address: ${input_ipv4}"
            disable_pasarguard_ssl_env
            colorized_echo yellow "Continuing without SSL."
            return 0
        fi

        read -p "Enter IPv6 for SSL certificate (optional, press Enter to skip): " input_ipv6
        input_ipv6="${input_ipv6// /}"
        if [ -n "$input_ipv6" ] && ! is_ipv6 "$input_ipv6"; then
            colorized_echo red "Invalid IPv6 address: ${input_ipv6}"
            disable_pasarguard_ssl_env
            colorized_echo yellow "Continuing without SSL."
            return 0
        fi

        if setup_ip_ssl_certificate "$input_ipv4" "$input_ipv6" "$ssl_http_port"; then
            enable_pasarguard_ssl_env "${DATA_DIR}/certs/ip/fullchain.pem" "${DATA_DIR}/certs/ip/privkey.pem" "public"
            colorized_echo green "SSL enabled for https://${input_ipv4}:8000/dashboard/"
            return 0
        fi
        ;;
    3)
        while true; do
            read -p "Enter full path to certificate file (crt/pem/fullchain): " custom_cert
            custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'" | xargs)
            if [ -f "$custom_cert" ] && [ -r "$custom_cert" ] && [ -s "$custom_cert" ]; then
                break
            fi
            colorized_echo red "Certificate file not found/readable: $custom_cert"
        done

        while true; do
            read -p "Enter full path to private key file (key/pem): " custom_key
            custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'" | xargs)
            if [ -f "$custom_key" ] && [ -r "$custom_key" ] && [ -s "$custom_key" ]; then
                break
            fi
            colorized_echo red "Private key file not found/readable: $custom_key"
        done

        read -p "Is this certificate from a public CA? [Y/n]: " custom_ca_choice
        if [[ -n "$custom_ca_choice" && ! "$custom_ca_choice" =~ ^[Yy]$ ]]; then
            custom_ca_type="private"
        fi

        if configure_custom_ssl_certificate "$custom_cert" "$custom_key" "$custom_ca_type"; then
            colorized_echo green "SSL enabled from custom certificate files."
            return 0
        fi
        ;;
    4)
        disable_pasarguard_ssl_env
        colorized_echo yellow "Continuing without SSL."
        return 0
        ;;
    *)
        disable_pasarguard_ssl_env
        colorized_echo yellow "Invalid SSL option. Continuing without SSL."
        return 0
        ;;
    esac

    disable_pasarguard_ssl_env
    colorized_echo yellow "SSL setup failed. Continuing without SSL. You can configure SSL later in ${ENV_FILE}."
    return 0
}

compose_service_exists() {
    local service_name="$1"
    [ -z "$service_name" ] && return 1
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" config --services 2>/dev/null | grep -Fxq "$service_name"
}

list_pasarguard_app_services() {
    local detected_services=""
    detected_services=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" config 2>/dev/null | awk '
        BEGIN { in_services = 0; service = ""; is_app = 0 }
        function flush_service() {
            if (service != "" && is_app) {
                print service
            }
        }
        /^services:[[:space:]]*$/ {
            in_services = 1
            next
        }
        in_services && /^[^[:space:]]/ {
            flush_service()
            in_services = 0
            service = ""
            is_app = 0
            next
        }
        !in_services {
            next
        }
        /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            flush_service()
            service = $0
            sub(/^  /, "", service)
            sub(/:[[:space:]]*$/, "", service)
            is_app = 0
            next
        }
        /^[[:space:]]+image:[[:space:]]*pasarguard\/panel([:@].*)?$/ {
            is_app = 1
            next
        }
        /^[[:space:]]+ROLE:[[:space:]]*(backend|node|scheduler)([[:space:]]|$)/ {
            is_app = 1
            next
        }
        /^[[:space:]]+-[[:space:]]*ROLE=(backend|node|scheduler)([[:space:]]|$)/ {
            is_app = 1
            next
        }
        END {
            flush_service()
        }
    ' 2>/dev/null || true)

    if [ -n "$detected_services" ]; then
        echo "$detected_services"
        return 0
    fi

    for candidate in panel pasarguard node-worker scheduler; do
        if compose_service_exists "$candidate"; then
            echo "$candidate"
        fi
    done
}

detect_pasarguard_backend_service() {
    local service_name=""

    for candidate in panel pasarguard; do
        if compose_service_exists "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done

    service_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" config 2>/dev/null | awk '
        BEGIN { in_services = 0; service = ""; is_backend = 0 }
        function flush_service() {
            if (service != "" && is_backend) {
                print service
                exit
            }
        }
        /^services:[[:space:]]*$/ {
            in_services = 1
            next
        }
        in_services && /^[^[:space:]]/ {
            flush_service()
            in_services = 0
            next
        }
        !in_services {
            next
        }
        /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            flush_service()
            service = $0
            sub(/^  /, "", service)
            sub(/:[[:space:]]*$/, "", service)
            is_backend = 0
            next
        }
        /^[[:space:]]+ROLE:[[:space:]]*backend([[:space:]]|$)/ {
            is_backend = 1
            next
        }
        /^[[:space:]]+-[[:space:]]*ROLE=backend([[:space:]]|$)/ {
            is_backend = 1
            next
        }
        END {
            if (service != "" && is_backend) {
                print service
            }
        }
    ' | head -n 1)

    if [ -n "$service_name" ]; then
        echo "$service_name"
        return 0
    fi

    service_name=$(list_pasarguard_app_services | head -n 1)
    if [ -n "$service_name" ]; then
        echo "$service_name"
        return 0
    fi

    return 1
}

stop_pasarguard_app_services() {
    local services
    services=$(list_pasarguard_app_services | xargs)
    [ -z "$services" ] && services="pasarguard"
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" stop $services 2>/dev/null || true
}

start_pasarguard_app_services() {
    local services
    services=$(list_pasarguard_app_services | xargs)
    [ -z "$services" ] && services="pasarguard"
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" start $services 2>/dev/null || true
}

find_container() {
    local db_type=$1
    local container_name=""
    detect_compose

    case $db_type in
    mariadb)
        container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps --format json mariadb 2>/dev/null | jq -r '.Name' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name=$(docker ps --filter "name=${APP_NAME}" --filter "name=mariadb" --format '{{.ID}}' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name="mariadb"
        ;;
    mysql)
        container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mysql 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps --format json mysql mariadb 2>/dev/null | jq -r 'if type == "array" then .[] else . end | .Name' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name=$(docker ps --filter "name=${APP_NAME}" --filter "name=mysql" --format '{{.ID}}' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name=$(docker ps --filter "name=${APP_NAME}" --filter "name=mariadb" --format '{{.ID}}' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name="mysql"
        ;;
    postgresql|timescaledb)
        container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q timescaledb 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q postgresql 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps --format json timescaledb postgresql 2>/dev/null | jq -r 'if type == "array" then .[] else . end | .Name' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name="${APP_NAME}-timescaledb-1"
        ;;
    esac
    echo "$container_name"
}

check_container() {
    local container_name=$1
    local db_type=$2
    local actual_container=""

    if docker inspect "$container_name" >/dev/null 2>&1; then
        actual_container="$container_name"
    else
        case $db_type in
        mariadb)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-mariadb-1"
            ;;
        mysql)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mysql 2>/dev/null || true)
            [ -z "$actual_container" ] && actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-mysql-1"
            ;;
        postgresql|timescaledb)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q postgresql 2>/dev/null || true)
            [ -z "$actual_container" ] && actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q timescaledb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-postgresql-1"
            ;;
        esac
    fi

    [ -z "$actual_container" ] && { echo ""; return 1; }
    container_name="$actual_container"
    docker ps --filter "id=${container_name}" --format '{{.ID}}' 2>/dev/null | grep -q . || \
    docker ps --filter "name=${container_name}" --format '{{.Names}}' 2>/dev/null | grep -q . || \
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^${container_name}$|/${container_name}$" || \
    docker ps --format '{{.ID}}' 2>/dev/null | grep -q "^${container_name}" || { echo ""; return 1; }
    echo "$container_name"
    return 0
}

verify_and_start_container() {
    local container_name=$1
    local db_type=$2
    local actual_container=""

    if docker inspect "$container_name" >/dev/null 2>&1; then
        actual_container="$container_name"
    else
        case $db_type in
        mariadb)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-mariadb-1"
            ;;
        mysql)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mysql 2>/dev/null || true)
            [ -z "$actual_container" ] && actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-mysql-1"
            ;;
        postgresql|timescaledb)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q postgresql 2>/dev/null || true)
            [ -z "$actual_container" ] && actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q timescaledb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-postgresql-1"
            ;;
        esac
    fi

    [ -z "$actual_container" ] && { echo ""; return 1; }
    container_name="$actual_container"
    local container_running=false
    docker ps --filter "id=${container_name}" --format '{{.ID}}' 2>/dev/null | grep -q . && container_running=true || \
    docker ps --filter "name=${container_name}" --format '{{.Names}}' 2>/dev/null | grep -q . && container_running=true || \
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^${container_name}$|/${container_name}$" && container_running=true || \
    docker ps --format '{{.ID}}' 2>/dev/null | grep -q "^${container_name}" && container_running=true

    if [ "$container_running" = false ]; then
        colorized_echo yellow "Database container '$container_name' is not running. Attempting to start it..."
        docker start "$container_name" >/dev/null 2>&1 || \
        $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" start "${db_type%%|*}" 2>/dev/null || true
        sleep 2
        docker ps --filter "id=${container_name}" --format '{{.ID}}' 2>/dev/null | grep -q . && container_running=true || \
        docker ps --filter "name=${container_name}" --format '{{.Names}}' 2>/dev/null | grep -q . && container_running=true
    fi

    [ "$container_running" = true ] && { echo "$container_name"; return 0; } || { echo ""; return 1; }
}

install_pasarguard_script() {
    FETCH_REPO="PasarGuard/scripts"
    colorized_echo blue "Installing pasarguard script"
    install_shared_libs_from_repo "$FETCH_REPO" common.sh system.sh docker.sh github.sh env.sh pasarguard-backup.sh pasarguard-restore.sh
    github_install_script_from_repo "$FETCH_REPO" "pasarguard.sh" "pasarguard"
    colorized_echo green "pasarguard script installed successfully"
}

is_pasarguard_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}

set_pasarguard_panel_image() {
    local target_image="$1"
    local service_name=""
    local image_name=""
    local updated_any=false

    while IFS= read -r service_name; do
        [ -z "$service_name" ] && continue
        image_name=$(yq eval -r ".services.\"${service_name}\".image // \"\"" "$COMPOSE_FILE" 2>/dev/null)
        if [[ "$image_name" =~ ^pasarguard/panel([:@].*)?$ ]]; then
            yq -i ".services.\"${service_name}\".image = \"${target_image}\"" "$COMPOSE_FILE"
            updated_any=true
        fi
    done < <(yq eval -r '.services | keys | .[]' "$COMPOSE_FILE" 2>/dev/null || true)

    if [ "$updated_any" = false ]; then
        for service_name in panel pasarguard node-worker scheduler; do
            if yq eval -e ".services.\"${service_name}\"" "$COMPOSE_FILE" >/dev/null 2>&1; then
                yq -i ".services.\"${service_name}\".image = \"${target_image}\"" "$COMPOSE_FILE"
                updated_any=true
            fi
        done
    fi

    if [ "$updated_any" = false ]; then
        yq -i ".services.pasarguard.image = \"${target_image}\"" "$COMPOSE_FILE"
    fi
}

install_pasarguard() {
    local pasarguard_version=$1
    local major_version=$2
    local database_type=$3

    FILES_URL_PREFIX="https://raw.githubusercontent.com/pasarguard/panel"
    COMPOSE_FILES_URL_PREFIX="https://raw.githubusercontent.com/pasarguard/scripts/main/docker-compose"

    mkdir -p "$DATA_DIR"
    mkdir -p "$APP_DIR"

    colorized_echo blue "Fetching .env file"
    curl -sL "$FILES_URL_PREFIX/main/.env.example" -o "$APP_DIR/.env"

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
        colorized_echo blue "Fetching compose file for pasarguard+$db_name"
        curl -sL "$COMPOSE_FILES_URL_PREFIX/pasarguard-$database_type.yml" -o "$COMPOSE_FILE"

        # Comment out the SQLite line
        sed -i 's~^SQLALCHEMY_DATABASE_URL = "sqlite~#&~' "$APP_DIR/.env"

        DB_NAME="pasarguard"
        DB_USER="pasarguard"
        prompt_for_db_password

        echo "" >>"$ENV_FILE"
        echo "# Database configuration" >>"$ENV_FILE"
        echo "DB_NAME=${DB_NAME}" >>"$ENV_FILE"
        echo "DB_USER=${DB_USER}" >>"$ENV_FILE"
        echo "DB_PASSWORD=${DB_PASSWORD}" >>"$ENV_FILE"

        if [[ "$database_type" == "postgresql" || "$database_type" == "timescaledb" ]]; then
            DB_PORT="6432"
            prompt_for_pgadmin_password
            echo "" >>"$ENV_FILE"
            echo "# PGAdmin configuration" >>"$ENV_FILE"
            echo "PGADMIN_EMAIL=pg@github.io" >>"$ENV_FILE"
            echo "PGADMIN_PASSWORD=${PGADMIN_PASSWORD}" >>"$ENV_FILE"
        else
            colorized_echo green "phpMyAdmin address: 0.0.0.0:8010"
            DB_PORT="3306"
            MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
            echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >>"$ENV_FILE"
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
        colorized_echo blue "Fetching compose file"
        curl -sL "$FILES_URL_PREFIX/main/docker-compose.yml" -o "$COMPOSE_FILE"

        sed -i 's/^# \(SQLALCHEMY_DATABASE_URL = .*\)$/\1/' "$APP_DIR/.env"

        if [ "$major_version" -eq 1 ]; then
            db_driver_scheme="sqlite+aiosqlite"
        elif grep -Eq '^[#[:space:]]*SQLALCHEMY_DATABASE_URL[[:space:]]*=[[:space:]]*"sqlite\+aiosqlite' "$APP_DIR/.env"; then
            # Keep v1 check strict; use template hint for newer versions (e.g., v2+).
            db_driver_scheme="sqlite+aiosqlite"
        else
            db_driver_scheme="sqlite"
        fi

        sed -i "s~\(SQLALCHEMY_DATABASE_URL = \).*~\1\"${db_driver_scheme}:////${DATA_DIR}/db.sqlite3\"~" "$APP_DIR/.env"

    fi

    # Install requested version
    local target_image="pasarguard/panel:${pasarguard_version}"
    if [ "$pasarguard_version" == "latest" ]; then
        target_image="pasarguard/panel:latest"
    fi
    set_pasarguard_panel_image "$target_image"
    colorized_echo green "File saved in $APP_DIR/docker-compose.yml"

    colorized_echo green "pasarguard installed successfully"
}

up_pasarguard() {
    compose_up
}

status_command() {

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
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

prompt_for_db_password() {
    colorized_echo cyan "This password will be used to access the database and should be strong."
    colorized_echo cyan "If you do not enter a custom password, a secure 20-character password will be generated automatically."

    # Prompt for password input
    read -p "Enter the password for the database (or press Enter to generate a secure default password): " DB_PASSWORD

    # Generate a 20-character password if the user leaves the input empty
    if [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        colorized_echo green "A secure password has been generated automatically."
    fi
    colorized_echo green "This password will be recorded in the .env file for future use."

}

prompt_for_pgadmin_password() {
    # Prompt for password input
    read -p "Enter the password for PGAdmin panel (or press Enter to generate a secure default password): " PGADMIN_PASSWORD

    # Generate a 20-character password if the user leaves the input empty
    if [ -z "$PGADMIN_PASSWORD" ]; then
        PGADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        colorized_echo green "A secure password has been generated automatically."
    fi
    colorized_echo green "pgAdmin address: 0.0.0.0:8010"
    colorized_echo green "pgAdmin default email: pg@github.io"
    colorized_echo green "pgAdmin Password: $PGADMIN_PASSWORD"
    colorized_echo green "This password will be recorded in the .env file for future use."

}

check_existing_database_volumes() {
    local db_type=$1
    local found_paths=()
    local found_named_volumes=()

    if [[ "$db_type" == "sqlite" ]]; then
        return 0
    fi

    case "$db_type" in
    mariadb|mysql)
        found_paths=("/var/lib/mysql/pasarguard")
        ;;
    postgresql|timescaledb)
        found_paths=("/var/lib/postgresql/pasarguard")
        found_named_volumes=("pgadmin")
        ;;
    esac

    local existing_paths=()
    for path in "${found_paths[@]}"; do
        if [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
            existing_paths+=("$path")
        fi
    done

    local existing_named_volumes=()
    if [ ${#found_named_volumes[@]} -gt 0 ] && command -v docker >/dev/null 2>&1; then
        for vol_name in "${found_named_volumes[@]}"; do
            local prefixed_vol="${APP_NAME}_${vol_name}"
            if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qE "^${prefixed_vol}$|^${vol_name}$"; then
                existing_named_volumes+=("$vol_name")
            fi
        done
    fi

    if [ ${#existing_paths[@]} -eq 0 ] && [ ${#existing_named_volumes[@]} -eq 0 ]; then
        return 0
    fi

    colorized_echo yellow "âš ï¸  WARNING: Found existing volumes/directories that may conflict with the installation:"

    for path in "${existing_paths[@]}"; do
        local dir_size=$(du -sh "$path" 2>/dev/null | cut -f1 || echo "unknown size")
        colorized_echo yellow "  - Directory: $path (Size: $dir_size)"
    done

    for vol_name in "${existing_named_volumes[@]}"; do
        local vol_size="unknown size"
        local prefixed_vol="${APP_NAME}_${vol_name}"
        local actual_vol=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${prefixed_vol}$|^${vol_name}$" | head -n1)
        if [ -n "$actual_vol" ]; then
            local mountpoint=$(docker volume inspect "$actual_vol" --format '{{.Mountpoint}}' 2>/dev/null)
            if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
                vol_size=$(du -sh "$mountpoint" 2>/dev/null | cut -f1 || echo "unknown size")
            fi
            colorized_echo yellow "  - Docker volume: $actual_vol (Size: $vol_size)"
        else
            colorized_echo yellow "  - Docker volume: $vol_name"
        fi
    done

    echo
    colorized_echo red "âš ï¸  DANGER: These volumes may contain data from a previous pasarguard installation."
    colorized_echo yellow "If you proceed without deleting them, there may be conflicts or data corruption."
    echo
    colorized_echo cyan "Do you want to delete these volumes? (default: no)"
    colorized_echo yellow "WARNING: This will PERMANENTLY delete all data in these volumes!"
    read -p "Delete volumes? [y/N]: " delete_volumes

    if [[ "$delete_volumes" =~ ^[Yy]$ ]]; then
        colorized_echo yellow "Deleting volumes..."

        for path in "${existing_paths[@]}"; do
            if rm -rf "$path" 2>/dev/null; then
                colorized_echo green "âœ“ Deleted directory: $path"
            else
                colorized_echo red "âœ— Failed to delete directory: $path (may be in use or permission denied)"
            fi
        done

        for vol_name in "${existing_named_volumes[@]}"; do
            local prefixed_vol="${APP_NAME}_${vol_name}"
            local actual_vol=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${prefixed_vol}$|^${vol_name}$" | head -n1)
            if [ -n "$actual_vol" ]; then
                if docker volume rm "$actual_vol" >/dev/null 2>&1; then
                    colorized_echo green "âœ“ Deleted Docker volume: $actual_vol"
                else
                    colorized_echo red "âœ— Failed to delete Docker volume: $actual_vol (may be in use)"
                fi
            fi
        done

        colorized_echo green "Volume cleanup completed."
    else
        colorized_echo yellow "Keeping existing volumes. Proceeding with installation..."
        colorized_echo yellow "Note: If you encounter conflicts, you may need to manually remove these volumes later."
    fi
    echo
}

install_command() {
    check_running_as_root

    # Default values
    pasarguard_version="latest"
    major_version=1
    pasarguard_version_set="false"
    database_type="sqlite"
    ssl_mode="auto"
    ssl_domain=""
    ssl_http_port="80"

    # Parse options
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
        --database)
            database_type="$2"
            if [[ ! $database_type =~ ^(mysql|mariadb|postgresql|timescaledb)$ ]]; then
                colorized_echo red "Unsupported database type: $database_type"
                exit 1
            fi
            shift 2
            ;;
        --dev)
            if [[ "$pasarguard_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release , --dev and --version options simultaneously."
                exit 1
            fi
            pasarguard_version="dev"
            pasarguard_version_set="true"
            shift
            ;;
        --pre-release)
            if [[ "$pasarguard_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release , --dev and --version options simultaneously."
                exit 1
            fi
            pasarguard_version="pre-release"
            pasarguard_version_set="true"
            shift
            ;;
        --version)
            if [[ "$pasarguard_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release , --dev and --version options simultaneously."
                exit 1
            fi
            pasarguard_version="$2"
            pasarguard_version_set="true"
            shift 2
            ;;
        --ssl)
            if [[ "$ssl_mode" == "disabled" ]]; then
                colorized_echo red "Error: Cannot use --ssl and --no-ssl together."
                exit 1
            fi
            ssl_mode="enabled"
            shift
            ;;
        --no-ssl)
            if [[ "$ssl_mode" == "enabled" || -n "$ssl_domain" ]]; then
                colorized_echo red "Error: Cannot use --no-ssl with --ssl or --ssl-domain."
                exit 1
            fi
            ssl_mode="disabled"
            shift
            ;;
        --ssl-domain)
            if [ -z "${2:-}" ]; then
                colorized_echo red "Error: --ssl-domain requires a value."
                exit 1
            fi
            if [[ "$ssl_mode" == "disabled" ]]; then
                colorized_echo red "Error: Cannot use --ssl-domain with --no-ssl."
                exit 1
            fi
            ssl_domain="${2// /}"
            if ! is_domain "$ssl_domain"; then
                colorized_echo red "Invalid domain format for --ssl-domain: $ssl_domain"
                exit 1
            fi
            ssl_mode="domain"
            shift 2
            ;;
        --ssl-http-port | --ssl-port)
            if [ -z "${2:-}" ]; then
                colorized_echo red "Error: $1 requires a value."
                exit 1
            fi
            ssl_http_port="$2"
            if ! [[ "$ssl_http_port" =~ ^[0-9]+$ ]] || [ "$ssl_http_port" -lt 1 ] || [ "$ssl_http_port" -gt 65535 ]; then
                colorized_echo red "Invalid SSL HTTP challenge port: $ssl_http_port"
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
    done

    # Check if pasarguard is already installed
    if is_pasarguard_installed; then
        colorized_echo red "pasarguard is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n) "
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
    install_pasarguard_script
    # Function to check if a version exists in the GitHub releases
    check_version_exists() {
        local version=$1
        repo_url="https://api.github.com/repos/pasarguard/panel/releases"

        if [ "$version" == "latest" ]; then
            latest_tag=$(curl -s ${repo_url}/latest | jq -r '.tag_name')
            major_version=$(echo "$latest_tag" | sed 's/^v//' | sed 's/[^0-9]*\([0-9]*\)\..*/\1/')
            return 0
        fi

        if [ "$version" == "dev" ]; then
            major_version=0
            return 0
        fi

        if [ "$version" == "pre-release" ]; then
            local latest_stable_tag=$(curl -s "$repo_url/latest" | jq -r '.tag_name')
            local latest_pre_release_tag=$(curl -s "$repo_url" | jq -r '[.[] | select(.prerelease == true)][0].tag_name')

            if [ "$latest_stable_tag" == "null" ] && [ "$latest_pre_release_tag" == "null" ]; then
                return 1 # No releases found at all
            elif [ "$latest_stable_tag" == "null" ]; then
                pasarguard_version=$latest_pre_release_tag
            elif [ "$latest_pre_release_tag" == "null" ]; then
                pasarguard_version=$latest_stable_tag
            else
                # Compare versions using sort -V
                local chosen_version=$(printf "%s\n" "$latest_stable_tag" "$latest_pre_release_tag" | sort -V | tail -n 1)
                pasarguard_version=$chosen_version
            fi
            # Determine major_version for the chosen version (supports v1+)
            major_version=$(echo "$pasarguard_version" | sed 's/^v//' | sed 's/[^0-9]*\([0-9]*\)\..*/\1/')
            if [[ -z "$major_version" ]]; then
                major_version=0
            fi
            return 0
        fi

        # Check if the repo contains the version tag
        if curl -s -o /dev/null -w "%{http_code}" "${repo_url}/tags/${version}" | grep -q "^200$"; then
            major_version=$(echo "$version" | sed 's/^v//' | sed 's/[^0-9]*\([0-9]*\)\..*/\1/')
            return 0
        else
            return 1
        fi
    }

    semver_regex='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
    # Check if the version is valid and exists
    if [[ "$pasarguard_version" == "latest" || "$pasarguard_version" == "dev" || "$pasarguard_version" == "pre-release" || "$pasarguard_version" =~ $semver_regex ]]; then
        if check_version_exists "$pasarguard_version"; then
            if [[ "$database_type" =~ ^(postgresql|timescaledb)$ ]] && [ "$major_version" -lt 1 ]; then
                colorized_echo red "Error: --database $database_type requires v1.0.0 or newer."
                colorized_echo yellow "Try: --pre-release or --version v1.x.y"
                exit 1
            fi
            check_existing_database_volumes "$database_type"
            install_pasarguard "$pasarguard_version" "$major_version" "$database_type"
            setup_pasarguard_ssl_during_install "$ssl_mode" "$ssl_domain" "$ssl_http_port"
            echo "Installing $pasarguard_version version"
        else
            echo "Version $pasarguard_version does not exist. Please enter a valid version (e.g. v0.5.2)"
            exit 1
        fi
    else
        echo "Invalid version format. Please enter a valid version (e.g. v0.5.2)"
        exit 1
    fi
    install_completion
    up_pasarguard

    echo
    colorized_echo blue "=============================="
    colorized_echo yellow "PasarGuard doesn't have any core by default."
    colorized_echo yellow "You need at least one node for proxy connection."
    echo
    colorized_echo cyan "Want to install node on same server?"
    colorized_echo red "(Not recommended for commercial use)"
    echo
    read -p "Do you want to install PasarGuard node? (y/n) " install_node_choice
    if [[ $install_node_choice =~ ^[Yy]$ ]]; then
        install_node_command
    else
        colorized_echo yellow "Skipping node installation."
    fi

    follow_pasarguard_logs
}

down_pasarguard() {
    compose_down
}

show_pasarguard_logs() {
    compose_logs
}

follow_pasarguard_logs() {
    compose_logs_follow
}

pasarguard_cli() {
    local backend_service=""
    backend_service=$(detect_pasarguard_backend_service)
    if [ -z "$backend_service" ]; then
        colorized_echo red "Could not detect PasarGuard backend service in docker-compose."
        return 1
    fi
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" exec -e CLI_PROG_NAME="pasarguard cli" "$backend_service" pasarguard-cli "$@"
}

pasarguard_tui() {
    local backend_service=""
    backend_service=$(detect_pasarguard_backend_service)
    if [ -z "$backend_service" ]; then
        colorized_echo red "Could not detect PasarGuard backend service in docker-compose."
        return 1
    fi
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" exec -e TUI_PROG_NAME="pasarguard tui" "$backend_service" pasarguard-tui "$@"
}


is_pasarguard_up() {
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

uninstall_command() {
    check_running_as_root
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    read -p "Do you really want to uninstall pasarguard? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi

    detect_compose
    if is_pasarguard_up; then
        down_pasarguard
    fi
    uninstall_completion
    uninstall_pasarguard_script
    uninstall_pasarguard
    uninstall_pasarguard_docker_images

    read -p "Do you want to remove pasarguard's data files too ($DATA_DIR)? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo green "pasarguard uninstalled successfully"
    else
        uninstall_pasarguard_data_files
        colorized_echo green "pasarguard uninstalled successfully"
    fi
}

uninstall_pasarguard_script() {
    if [ -f "/usr/local/bin/pasarguard" ]; then
        colorized_echo yellow "Removing pasarguard script"
        rm "/usr/local/bin/pasarguard"
    fi
}

uninstall_pasarguard() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_pasarguard_docker_images() {
    local images
    images=$(docker images --format '{{.Repository}} {{.ID}}' | awk '$1 ~ /^pasarguard\/panel(:|$)/ {print $2}' | sort -u)

    if [ -z "$images" ]; then
        colorized_echo yellow "pasarguard/panel images not found"
        return 0
    fi

    colorized_echo yellow "Checking pasarguard/panel images for removal..."

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

uninstall_pasarguard_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

restart_command() {
    help() {
        colorized_echo red "Usage: pasarguard restart [options]"
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

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    down_pasarguard
    up_pasarguard
    if [ "$no_logs" = false ]; then
        follow_pasarguard_logs
    fi
    colorized_echo green "pasarguard successfully restarted!"
}
logs_command() {
    help() {
        colorized_echo red "Usage: pasarguard logs [options]"
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

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard is not up."
        exit 1
    fi

    if [ "$no_follow" = true ]; then
        show_pasarguard_logs
    else
        follow_pasarguard_logs
    fi
}

down_command() {

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard's already down"
        exit 1
    fi

    down_pasarguard
}

cli_command() {
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard is not up."
        exit 1
    fi

    pasarguard_cli "$@"
}

tui_command() {
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard is not up."
        exit 1
    fi

    pasarguard_tui "$@"
}

up_command() {
    help() {
        colorized_echo red "Usage: pasarguard up [options]"
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

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if is_pasarguard_up; then
        colorized_echo red "pasarguard's already up"
        exit 1
    fi

    up_pasarguard
    if [ "$no_logs" = false ]; then
        follow_pasarguard_logs
    fi
}

update_command() {
    check_running_as_root
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    update_pasarguard_script
    uninstall_completion
    install_completion
    colorized_echo blue "Pulling latest version"
    update_pasarguard

    colorized_echo blue "Restarting pasarguard's services"
    down_pasarguard
    up_pasarguard

    colorized_echo blue "pasarguard updated successfully"
}

update_pasarguard_script() {
    FETCH_REPO="PasarGuard/scripts"
    colorized_echo blue "Updating pasarguard script"
    install_shared_libs_from_repo "$FETCH_REPO" common.sh system.sh docker.sh github.sh env.sh pasarguard-backup.sh pasarguard-restore.sh
    github_install_script_from_repo "$FETCH_REPO" "pasarguard.sh" "pasarguard"
    colorized_echo green "pasarguard script updated successfully"
}

update_pasarguard() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull
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

install_node_command() {
    colorized_echo blue "=============================="
    colorized_echo magenta "   Install PasarGuard Node   "
    colorized_echo blue "=============================="
    echo

    if [ "$(id -u)" = "0" ]; then
        colorized_echo blue "Running node installation with sudo..."
        sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install
    else
        colorized_echo blue "Running node installation without sudo..."
        bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install
    fi

    if [ $? -eq 0 ]; then
        colorized_echo green "Node installation completed successfully!"
    else
        colorized_echo red "Node installation failed."
        exit 1
    fi
}

generate_completion() {
    cat <<'EOF'
_pasarguard_completions()
{
    local cur cmds
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmds="up down restart status logs cli tui install update uninstall install-script install-node backup backup-service restore core-update edit edit-env help completion"
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
}
EOF
    echo "complete -F _pasarguard_completions pasarguard.sh"
    echo "complete -F _pasarguard_completions $APP_NAME"
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
    local script_name="${0##*/}"
    colorized_echo blue "=============================="
    colorized_echo magenta "           pasarguard Help"
    colorized_echo blue "=============================="
    colorized_echo cyan "Usage:"
    echo "  ${script_name} [command]"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              $(tput sgr0)â€“ Start services"
    colorized_echo yellow "  down            $(tput sgr0)â€“ Stop services"
    colorized_echo yellow "  restart         $(tput sgr0)â€“ Restart services"
    colorized_echo yellow "  status          $(tput sgr0)â€“ Show status"
    colorized_echo yellow "  logs            $(tput sgr0)â€“ Show logs"
    colorized_echo yellow "  cli             $(tput sgr0)â€“ pasarguard CLI"
    colorized_echo yellow "  tui             $(tput sgr0)â€“ pasarguard TUI"
    colorized_echo yellow "  install         $(tput sgr0)â€“ Install pasarguard"
    colorized_echo yellow "  update          $(tput sgr0)â€“ Update to latest version"
    colorized_echo yellow "  uninstall       $(tput sgr0)â€“ Uninstall pasarguard"
    colorized_echo yellow "  install-script  $(tput sgr0)â€“ Install pasarguard script"
    colorized_echo yellow "  install-node    $(tput sgr0)â€“ Install PasarGuard node"
    colorized_echo yellow "  backup          $(tput sgr0)â€“ Manual backup launch"
    colorized_echo yellow "  backup-service  $(tput sgr0)â€“ pasarguard Backup service to backup to TG, and a new job in crontab"
    colorized_echo yellow "  restore         $(tput sgr0)â€“ Restore database from backup file"
    colorized_echo yellow "  edit            $(tput sgr0)â€“ Edit docker-compose.yml (via nano or vi editor)"
    colorized_echo yellow "  edit-env        $(tput sgr0)â€“ Edit environment file (via nano or vi editor)"
    colorized_echo yellow "  help            $(tput sgr0)â€“ Show this help message"

    echo
    colorized_echo cyan "Directories:"
    colorized_echo magenta "  App directory: $APP_DIR"
    colorized_echo magenta "  Data directory: $DATA_DIR"
    colorized_echo blue "================================"
    echo
}

case "$1" in
up)
    shift
    up_command "$@"
    ;;
down)
    shift
    down_command "$@"
    ;;
restart)
    shift
    restart_command "$@"
    ;;
status)
    shift
    status_command "$@"
    ;;
logs)
    shift
    logs_command "$@"
    ;;
cli)
    shift
    cli_command "$@"
    ;;
tui)
    shift
    tui_command "$@"
    ;;
backup)
    shift
    backup_command "$@"
    ;;
backup-service)
    shift
    backup_service "$@"
    ;;
restore)
    shift
    restore_command "$@"
    ;;
install)
    shift
    install_command "$@"
    ;;
update)
    shift
    update_command "$@"
    ;;
uninstall)
    shift
    uninstall_command "$@"
    ;;
install-script)
    shift
    install_pasarguard_script "$@"
    ;;
install-node)
    shift
    install_node_command "$@"
    ;;
edit)
    shift
    edit_command "$@"
    ;;
edit-env)
    shift
    edit_env_command "$@"
    ;;
completion)
    generate_completion
    ;;
help | *)
    usage
    ;;
esac
