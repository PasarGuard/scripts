#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export APP_TMP_DIR="$WORK_DIR/tmp" APP_NAME=pg-node-tls-test APP_DIR="$WORK_DIR/app" DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR/certs"
curl() { :; }
export PG_NODE_SOURCE_ONLY=true
source "$ROOT_DIR/pg-node.sh"
colorized_echo() { printf '%s\n' "$*"; }
check_running_as_root() { :; }
get_occupied_ports() { OCCUPIED_PORTS=""; }
AUTO_CONFIRM=true
expect_fail() { if "$@"; then echo "FAIL: accepted $*" >&2; exit 1; fi; }
expect_fail validate_ssl_selection
INSTALL_SSL_IPV6=2001:db8::1
expect_fail validate_ssl_selection
unset INSTALL_SSL_IPV6
INSTALL_SELF_SIGNED=true INSTALL_SSL_IP=192.0.2.1
expect_fail validate_ssl_selection
unset INSTALL_SELF_SIGNED
INSTALL_SSL_HTTP_PORT=0
expect_fail validate_ssl_selection
INSTALL_SSL_HTTP_PORT=8080
validate_ssl_selection
unset INSTALL_SSL_IP
INSTALL_CERT_PATH=/not-found
expect_fail validate_ssl_selection
unset INSTALL_CERT_PATH
# Generate a real valid pair; preserve full chain bytes and permissions on deployment.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj '/CN=unused' \
    -addext 'subjectAltName=IP:192.0.2.1,IP:2001:db8::1,DNS:node.example.com' \
    -keyout "$WORK_DIR/key" -out "$WORK_DIR/cert" >/dev/null 2>&1
validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" 192.0.2.1 2001:db8::1
validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" node.example.com
expect_fail validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" wrong.example.com
expect_fail validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" 192.0.2.2
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$WORK_DIR/wrong-key"
expect_fail validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/wrong-key"
openssl x509 -in "$WORK_DIR/cert" -signkey "$WORK_DIR/key" -days -1 -out "$WORK_DIR/expired" >/dev/null 2>&1
expect_fail validate_node_cert_pair "$WORK_DIR/expired" "$WORK_DIR/key"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj '/CN=node.example.com' \
    -keyout "$WORK_DIR/no-san-key" -out "$WORK_DIR/no-san" >/dev/null 2>&1
expect_fail validate_node_cert_pair "$WORK_DIR/no-san" "$WORK_DIR/no-san-key" node.example.com

deploy_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" 192.0.2.1
cmp "$WORK_DIR/cert" "$SSL_CERT_FILE"
[ "$(stat -c %a "$SSL_KEY_FILE")" = 600 ]
expect_fail deploy_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/wrong-key"
cmp "$WORK_DIR/key" "$SSL_KEY_FILE"
# Self-signed output exposes the leaf certificate pin, not a PEM-file checksum.
save_cert_source self_signed
cert_output=$(show_node_certificate)
expected_pin=$(openssl x509 -in "$WORK_DIR/cert" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
[[ "$cert_output" == *"SHA-256 certificate pin (leaf DER): $expected_pin"* ]]
[[ "$cert_output" == *"certificate_sha256=$expected_pin and server_ca=\"\""* ]]
active_cert="$SSL_CERT_FILE"
SSL_CERT_FILE="$WORK_DIR/no-certificate"
expect_fail show_node_certificate
SSL_CERT_FILE="$active_cert"
# Mock ACME: ECC fails, RSA succeeds; confirm installation tries both and preserves old files on failure.
acme_calls="$WORK_DIR/acme-calls"
mock_acme() {
    printf '%s\n' "$*" >>"$acme_calls"
    [[ " $* " != *' --ecc '* ]] || return 1
    local key='' cert=''
    while [ $# -gt 0 ]; do
        case "$1" in --key-file) key="$2"; shift;; --fullchain-file) cert="$2"; shift;; esac
        shift
    done
    [ -z "$key" ] || cp "$WORK_DIR/key" "$key"
    [ -z "$cert" ] || cp "$WORK_DIR/cert" "$cert"
}
ensure_node_acme() { :; }
get_node_acme() { echo mock_acme; }
issue_node_acme acme_ip 192.0.2.1 2001:db8::1 8080
grep -q -- '--certificate-profile shortlived --days 6' "$acme_calls"
grep -q -- '--httpport 8080' "$acme_calls"
grep -q -- '--ecc' "$acme_calls"
mock_acme() { return 1; }
expect_fail issue_node_acme acme_ip 192.0.2.1 '' 80
cmp "$WORK_DIR/key" "$SSL_KEY_FILE"
# Renewal never changes source implicitly; hook must restart both node and maintenance.
printf 'SSL_CERT_FILE=%s\nSSL_KEY_FILE=%s\n' "$SSL_CERT_FILE" "$SSL_KEY_FILE" >"$ENV_FILE"
save_cert_source external_tls
renew_cert_command
save_cert_source custom
restart_called=false
detect_compose() { :; }
restart_node_cert_services() { restart_called=true; }
renew_cert_command
[ "$restart_called" = true ]
cmp "$WORK_DIR/key" "$SSL_KEY_FILE"
save_cert_source acme_ip 192.0.2.1 '' 80
restart_called=false
renew_cert_command --deploy-acme
[ "$restart_called" = true ]
# Restart both actual deployment targets; propagate individual restart failures.
unset -f restart_node_cert_services
# Restore just this function from the checkout without executing the installer.
eval "$(sed -n '/^restart_node_cert_services() {/,/^}/p' "$ROOT_DIR/pg-node.sh")"
COMPOSE=mock_compose
compose_called=false
maintenance_called=false
mock_compose() { compose_called=true; [[ "$*" == *"-p $APP_NAME restart" ]]; }
service_installed() { SERVICE_NAME="$APP_NAME-service"; return 0; }
systemctl() { maintenance_called=true; [ "$*" = "restart $APP_NAME-service" ]; }
restart_node_cert_services
[ "$compose_called" = true ] && [ "$maintenance_called" = true ]
systemctl() { return 1; }
expect_fail restart_node_cert_services
mock_compose() { return 1; }
expect_fail restart_node_cert_services
# Upgrade loading honors managed paths unchanged.
SSL_CERT_FILE=/wrong; SSL_KEY_FILE=/wrong
load_active_cert_paths
[ "$SSL_CERT_FILE" != /wrong ]
echo 'TLS installer tests passed'
