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
# Reject unsupported plaintext selections before saving metadata or certificates.
(
    INSTALL_NO_SSL=true
    node_version=v0.5.7
    curl() { printf '# No plaintext setting\n'; }
    expect_fail choose_node_certificate
    [ ! -e "$DATA_DIR/certs/source.json" ]
    [ ! -e "$SSL_CERT_FILE" ]
    node_version=dev
    curl() { printf '# TLS_ENABLED = true\n'; }
    choose_node_certificate
    [ "$TLS_ENABLED" = false ]
    [ "$(cert_metadata source)" = external_tls ]
    rm "$DATA_DIR/certs/source.json"
)
# Generate a real valid pair; preserve full chain bytes and permissions on deployment.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj '/CN=unused' \
    -addext 'subjectAltName=IP:192.0.2.1,IP:2001:db8::1,DNS:node.example.com,DNS:*.example.net' \
    -keyout "$WORK_DIR/key" -out "$WORK_DIR/cert" >/dev/null 2>&1
validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" 192.0.2.1 2001:db8::1
validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" node.example.com
expect_fail validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" wrong.example.com
expect_fail validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" 192.0.2.2
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$WORK_DIR/wrong-key"
expect_fail validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/wrong-key"
# Advance validation's clock past notAfter; newer OpenSSL rejects -days -1.
(
    expiry=$(openssl x509 -in "$WORK_DIR/cert" -enddate -noout)
    future=$(date -d "${expiry#*=}" +%s)
    date() {
        if [ "$*" = +%s ]; then printf '%s\n' "$((future + 1))"
        else command date "$@"; fi
    }
    expect_fail validate_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key"
)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj '/CN=node.example.com' \
    -keyout "$WORK_DIR/no-san-key" -out "$WORK_DIR/no-san" >/dev/null 2>&1
expect_fail validate_node_cert_pair "$WORK_DIR/no-san" "$WORK_DIR/no-san-key" node.example.com

deploy_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" 192.0.2.1
cmp "$WORK_DIR/cert" "$SSL_CERT_FILE"
[ "$(stat -c %a "$SSL_KEY_FILE")" = 600 ]
expect_fail deploy_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/wrong-key"
cmp "$WORK_DIR/key" "$SSL_KEY_FILE"
# Concurrent deployments cannot interleave their key and certificate moves.
move_log="$WORK_DIR/moves"
(
    mv() {
        if [ "${*: -1}" = "$SSL_KEY_FILE" ]; then
            echo key >>"$move_log"
            sleep 0.1
        elif [ "${*: -1}" = "$SSL_CERT_FILE" ]; then
            echo cert >>"$move_log"
        fi
        command mv "$@"
    }
    deploy_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" &
    first=$!
    deploy_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key" &
    second=$!
    wait "$first"
    wait "$second"
)
[ "$(cat "$move_log")" = "$(printf 'key\ncert\nkey\ncert')" ]
# Failure closes the descriptor and removes temporary files.
(
    cp() { return 1; }
    expect_fail deploy_node_cert_pair "$WORK_DIR/cert" "$WORK_DIR/key"
)
flock -n "$DATA_DIR/certs/.deployment.lock" true
# Synchronous reload subprocesses inherit ownership without deadlocking.
with_node_cert_lock bash -c 'flock -n "$PG_NODE_CERT_LOCK_FD" && ! flock -n "$DATA_DIR/certs/.deployment.lock" true'
[ -z "$(find "$DATA_DIR/certs" -name '*.stage.*' -print)" ]
# Selected certificates outside the data mount are relocated with matching paths.
(
    choose_node_certificate() { TLS_ENABLED=true; }
    SSL_CERT_FILE="$WORK_DIR/cert"; SSL_KEY_FILE="$WORK_DIR/key"
    with_node_cert_lock prepare_install_node_certificate
    [ "$SSL_CERT_FILE" = "$DATA_DIR/certs/ssl_cert.pem" ]
    [ "$SSL_KEY_FILE" = "$DATA_DIR/certs/ssl_key.pem" ]
    cmp "$WORK_DIR/cert" "$SSL_CERT_FILE"
    cmp "$WORK_DIR/key" "$SSL_KEY_FILE"
)
# Self-signed output exposes the leaf certificate pin, not a PEM-file checksum.
save_cert_source self_signed
cert_output=$(show_node_certificate)
expected_pin=$(openssl x509 -in "$WORK_DIR/cert" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
[[ "$cert_output" == *"SHA-256 certificate pin (leaf DER): $expected_pin"* ]]
[[ "$cert_output" != *certificate_sha256* ]]
[[ "$cert_output" != *server_ca* ]]
active_cert="$SSL_CERT_FILE"
SSL_CERT_FILE="$WORK_DIR/no-certificate"
expect_fail show_node_certificate
SSL_CERT_FILE="$active_cert"
# Mock ACME: ECC fails, RSA succeeds; confirm installation tries both and preserves old files on failure.
acme_calls="$WORK_DIR/acme-calls"
mock_acme() {
    # ACME staging is owned by the same lock as certificate deployment.
    if flock -n "$DATA_DIR/certs/.deployment.lock" true; then
        echo 'FAIL: ACME ran without the deployment lock' >&2
        return 1
    fi
    printf '%s\n' "$*" >>"$acme_calls"
    [[ " $* " != *' --ecc '* ]] || return 1
    local key='' cert=''
    while [ $# -gt 0 ]; do
        case "$1" in --key-file) key="$2"; shift;; --fullchain-file) cert="$2"; shift;; esac
        shift
    done
    [ "$key" != no ] || key=''
    [ "$cert" != no ] || cert=''
    [ -z "$key" ] || cp "$WORK_DIR/key" "$key"
    [ -z "$cert" ] || cp "$WORK_DIR/cert" "$cert"
}
ensure_node_acme() { :; }
validate_node_acme_chain() { :; }
get_node_acme() { echo mock_acme; }
issue_node_acme acme_ip 192.0.2.1 2001:db8::1 8080
grep -q -- '--certificate-profile shortlived --days 4' "$acme_calls"
grep -q -- '--httpport 8080' "$acme_calls"
grep -q -- '--ecc' "$acme_calls"
mock_acme() { return 1; }
expect_fail issue_node_acme acme_ip 192.0.2.1 '' 80
cmp "$WORK_DIR/key" "$SSL_KEY_FILE"
# Renewal never changes source implicitly; hook must reload both node and maintenance.
printf 'SSL_CERT_FILE=%s\nSSL_KEY_FILE=%s\n' "$SSL_CERT_FILE" "$SSL_KEY_FILE" >"$ENV_FILE"
save_cert_source external_tls
renew_cert_command
save_cert_source custom
verify_node_cert_services() { return 0; }
install_node_cert_scheduler() { :; }
reload_called=false
detect_compose() { :; }
reload_node_cert_services() {
    if flock -n "$DATA_DIR/certs/.deployment.lock" true; then
        echo 'FAIL: deployment lock released before reload' >&2
        return 1
    fi
    reload_called=true
}
renew_cert_command
[ "$reload_called" = true ]
cmp "$WORK_DIR/key" "$SSL_KEY_FILE"
# Renewal preserves installed DNS, wildcard, IPv4 and IPv6 SANs without prompting.
(
    ENV_FILE="$WORK_DIR/renew.env"
    SSL_CERT_FILE="$WORK_DIR/renew.pem" SSL_KEY_FILE="$WORK_DIR/renew.key"
    printf 'SSL_CERT_FILE=%s\nSSL_KEY_FILE=%s\n' "$SSL_CERT_FILE" "$SSL_KEY_FILE" >"$ENV_FILE"
    NODE_IP=198.51.100.2 NODE_IP_V4=198.51.100.2 NODE_IP_V6=''
    read() {
        if [[ "$*" == *'Enter additional SAN entries'* ]]; then
            touch "$WORK_DIR/san-prompt"
            return 1
        fi
        builtin read "$@"
    }
    for mode in self_signed legacy; do
        cp "$WORK_DIR/cert" "$SSL_CERT_FILE"
        cp "$WORK_DIR/key" "$SSL_KEY_FILE"
        if [ "$mode" = legacy ]; then
            rm -f "$DATA_DIR/certs/source.json"
            AUTO_CONFIRM=true
        else
            save_cert_source self_signed
            AUTO_CONFIRM=false
        fi
        reload_called=false
        renew_cert_command </dev/null
        [ "$reload_called" = true ]
        start=$(openssl x509 -in "$SSL_CERT_FILE" -noout -startdate)
        end=$(openssl x509 -in "$SSL_CERT_FILE" -noout -enddate)
        [ "$(( $(date -d "${end#*=}" +%s) - $(date -d "${start#*=}" +%s) ))" -eq "$((3650*86400))" ]
        [ ! -f "$WORK_DIR/san-prompt" ]
        validate_node_cert_pair "$SSL_CERT_FILE" "$SSL_KEY_FILE" node.example.com
        validate_node_cert_pair "$SSL_CERT_FILE" "$SSL_KEY_FILE" wildcard.example.net
        validate_node_cert_pair "$SSL_CERT_FILE" "$SSL_KEY_FILE" 192.0.2.1 2001:db8::1
    done
    # Unreadable or SAN-less certificates must not be replaced with default SANs.
    for invalid in no-san no-certificate; do
        SSL_CERT_FILE="$WORK_DIR/$invalid"
        printf 'SSL_CERT_FILE=%s\nSSL_KEY_FILE=%s\n' "$SSL_CERT_FILE" "$SSL_KEY_FILE" >"$ENV_FILE"
        reload_called=false
        expect_fail renew_cert_command </dev/null
        [ "$reload_called" = false ]
    done
)
save_cert_source acme_ip 192.0.2.1 '' 80
# ACME's cron must not write shared staging before the locked reload hook.
mock_acme() {
    printf '%s\n' "$*" >>"$acme_calls"
    if [[ " $* " == *' --renew '* ]]; then
        CERT_FULLCHAIN_PATH="$WORK_DIR/cert" CERT_KEY_PATH="$WORK_DIR/key" renew_cert_command --deploy-acme
    fi
}
register_node_acme_reload
grep -q -- '--key-file no --fullchain-file no' "$acme_calls"
reload_called=false
CERT_FULLCHAIN_PATH="$WORK_DIR/cert" CERT_KEY_PATH="$WORK_DIR/key" renew_cert_command --deploy-acme >"$WORK_DIR/deploy-output"
[ "$reload_called" = true ]
# The internal hook does not duplicate the installer's certificate output.
if grep -q -- 'BEGIN CERTIFICATE' "$WORK_DIR/deploy-output"; then
    echo 'FAIL: deployment hook printed PEM' >&2; exit 1
fi
# Explicit renewal still prints the resulting certificate once.
renew_cert_command >"$WORK_DIR/renew-output"
[ "$(grep -c -- '^-----BEGIN CERTIFICATE-----' "$WORK_DIR/renew-output")" = 1 ] || { cat "$WORK_DIR/renew-output"; exit 1; }
# Signal both actual deployment targets; propagate individual failures.
unset -f reload_node_cert_services
# Restore just this function from the checkout without executing the installer.
eval "$(sed -n '/^reload_node_cert_services() {/,/^}/p' "$ROOT_DIR/pg-node.sh")"
COMPOSE=mock_compose
compose_called=false
maintenance_called=false
mock_compose() { compose_called=true; [[ "$*" == *"-p $APP_NAME restart node" ]]; }
service_installed() { SERVICE_NAME="$APP_NAME-service"; return 0; }
systemctl() {
    [ "$*" != "is-active --quiet $APP_NAME-service" ] || return 0
    maintenance_called=true
    [ "$*" = "kill --kill-whom=main --signal=SIGHUP $APP_NAME-service" ]
}
reload_node_cert_services
[ "$compose_called" = true ] && [ "$maintenance_called" = true ]
systemctl() { [ "$1" = is-active ]; }
expect_fail reload_node_cert_services
systemctl() {
    [ "$1" != is-active ] || return 1
    maintenance_called=true
    return 0
}
maintenance_called=false
reload_node_cert_services
[ "$maintenance_called" = false ]
mock_compose() { return 1; }
expect_fail reload_node_cert_services
# Only running maintenance services add their API listener to verification.
eval "$(sed -n '/^verify_node_cert_services() {/,/^}/p' "$ROOT_DIR/pg-node.sh")"
printf 'SERVICE_PORT=62050\nAPI_PORT=62051\n' >>"$ENV_FILE"
verified_ports="$WORK_DIR/verified-ports"
verify_node_cert_endpoint() { echo "$2" >>"$verified_ports"; }
verify_node_cert_services
[ "$(cat "$verified_ports")" = 62050 ]
: >"$verified_ports"
systemctl() { [ "$1" = is-active ]; }
verify_node_cert_services
[ "$(cat "$verified_ports")" = "$(printf '62050\n62051')" ]
# Shared ACME entries belong to this node only when their reload hook matches.
(
    shared="$WORK_DIR/shared-acme"
    mkdir -p "$shared/192.0.2.1" "$shared/192.0.2.1_ecc"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$MIGRATION_CALLS"\n' >"$shared/acme.sh"
    chmod +x "$shared/acme.sh"
    export MIGRATION_CALLS="$WORK_DIR/migration-calls"
    printf "Le_ReloadCmd='systemctl reload nginx'\n" >"$shared/192.0.2.1/192.0.2.1.conf"
    printf "Le_ReloadCmd='env DATA_DIR=/another-node /usr/local/bin/pg-node renew-cert --deploy-acme'\n" >"$shared/192.0.2.1_ecc/192.0.2.1.conf"
    migrate_node_acme_storage "$shared/acme.sh" 192.0.2.1
    [ ! -e "$MIGRATION_CALLS" ]
    [ ! -d "$DATA_DIR/certs/acme/192.0.2.1" ]
    [ ! -d "$DATA_DIR/certs/acme/192.0.2.1_ecc" ]
    printf -v hook 'env %q %q %q renew-cert --deploy-acme' "DATA_DIR=$DATA_DIR" "APP_DIR=$APP_DIR" "/usr/local/bin/$APP_NAME"
    printf "Le_ReloadCmd='%s'\n" "$hook" >"$shared/192.0.2.1/192.0.2.1.conf"
    encoded=$(printf '%s' "$hook" | openssl base64 -A)
    printf "Le_ReloadCmd='__ACME_BASE64__START_%s__ACME_BASE64__END_'\n" "$encoded" >"$shared/192.0.2.1_ecc/192.0.2.1.conf"
    migrate_node_acme_storage "$shared/acme.sh" 192.0.2.1
    cmp "$shared/192.0.2.1/192.0.2.1.conf" "$DATA_DIR/certs/acme/192.0.2.1/192.0.2.1.conf"
    cmp "$shared/192.0.2.1_ecc/192.0.2.1.conf" "$DATA_DIR/certs/acme/192.0.2.1_ecc/192.0.2.1.conf"
    [ "$(cat "$MIGRATION_CALLS")" = "$(printf '%s\n' '--remove -d 192.0.2.1 --ecc' '--remove -d 192.0.2.1')" ]
)
# Failed hook staging must leave the scheduler uninstalled.
(
    stage_node_acme() { return 1; }
    migrate_node_acme_storage() { :; }
    install_node_cert_scheduler() { touch "$WORK_DIR/unexpected-scheduler"; }
    expect_fail register_node_acme_reload
    [ ! -e "$WORK_DIR/unexpected-scheduler" ]
)
# Upgrade loading honors managed paths unchanged.
SSL_CERT_FILE=/wrong; SSL_KEY_FILE=/wrong
load_active_cert_paths
[ "$SSL_CERT_FILE" != /wrong ]
echo 'TLS installer tests passed'
