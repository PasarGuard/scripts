#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pg-node-unit-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

# Suppress IP-detection curl calls at source time
curl() { echo ""; return 0; }
export -f curl

export PG_NODE_SOURCE_ONLY="true"
# shellcheck source=pg-node.sh
source "$ROOT_DIR/pg-node.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

assert_true() {
    local label="$1"; shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

assert_false() {
    local label="$1"; shift
    if ! "$@"; then pass "$label"; else fail "$label"; fi
}

echo "=== unit_pgnode.sh ==="

# -----------------------------------------------------------------------
# is_ip_address
# -----------------------------------------------------------------------
assert_true  "is_ip_address: IPv4 basic"       is_ip_address "192.168.1.1"
assert_true  "is_ip_address: IPv4 zeros"        is_ip_address "0.0.0.0"
assert_true  "is_ip_address: IPv4 max"          is_ip_address "255.255.255.255"
assert_true  "is_ip_address: IPv4 10.x"         is_ip_address "10.0.0.1"
assert_true  "is_ip_address: IPv6 full"         is_ip_address "2001:db8::1"
assert_true  "is_ip_address: IPv6 loopback"     is_ip_address "::1"
assert_true  "is_ip_address: IPv6 double colon" is_ip_address "::"
assert_false "is_ip_address: octet > 255"       is_ip_address "256.0.0.1"
assert_false "is_ip_address: 3 octets"          is_ip_address "192.168.1"
assert_false "is_ip_address: domain"            is_ip_address "example.com"
assert_false "is_ip_address: empty"             is_ip_address ""
assert_false "is_ip_address: letters"           is_ip_address "abc.def.ghi.jkl"

# -----------------------------------------------------------------------
# normalize_san_entry
# -----------------------------------------------------------------------
assert_eq "$(normalize_san_entry "192.168.1.1")"        "IP:192.168.1.1"     "normalize_san_entry: bare IPv4 -> IP:"
assert_eq "$(normalize_san_entry "10.0.0.5")"           "IP:10.0.0.5"        "normalize_san_entry: bare IPv4 -> IP:"
assert_eq "$(normalize_san_entry "example.com")"        "DNS:example.com"    "normalize_san_entry: domain -> DNS:"
assert_eq "$(normalize_san_entry "sub.example.com")"    "DNS:sub.example.com" "normalize_san_entry: subdomain -> DNS:"
assert_eq "$(normalize_san_entry "*.example.com")"      "DNS:*.example.com"  "normalize_san_entry: wildcard -> DNS:"
assert_eq "$(normalize_san_entry "IP:10.0.0.1")"        "IP:10.0.0.1"        "normalize_san_entry: already prefixed IP: passthrough"
assert_eq "$(normalize_san_entry "DNS:example.com")"    "DNS:example.com"    "normalize_san_entry: already prefixed DNS: passthrough"
# Whitespace trimming
assert_eq "$(normalize_san_entry "  example.com  ")"   "DNS:example.com"    "normalize_san_entry: trims whitespace"
assert_eq "$(normalize_san_entry "  192.168.1.1  ")"   "IP:192.168.1.1"     "normalize_san_entry: trims whitespace on IP"

# -----------------------------------------------------------------------
# validate_san_entry
# -----------------------------------------------------------------------
assert_true  "validate_san_entry: IPv4"             validate_san_entry "192.168.1.1"
assert_true  "validate_san_entry: domain"           validate_san_entry "example.com"
assert_true  "validate_san_entry: subdomain"        validate_san_entry "sub.example.com"
assert_true  "validate_san_entry: wildcard domain"  validate_san_entry "*.example.com"
assert_true  "validate_san_entry: already IP:"      validate_san_entry "IP:10.0.0.1"
assert_true  "validate_san_entry: already DNS:"     validate_san_entry "DNS:example.com"
assert_true  "validate_san_entry: IPv6"             validate_san_entry "2001:db8::1"
assert_false "validate_san_entry: empty"            validate_san_entry ""
assert_false "validate_san_entry: whitespace only"  validate_san_entry "   "

# -----------------------------------------------------------------------
# validate_app_name  (guards --name against path/systemd/sed/yq injection)
# -----------------------------------------------------------------------
assert_true  "validate_app_name: simple"            validate_app_name "pg-node"
assert_true  "validate_app_name: with digit"        validate_app_name "Node2"
assert_true  "validate_app_name: underscore"        validate_app_name "my_node"
assert_true  "validate_app_name: single char"       validate_app_name "a"
assert_true  "validate_app_name: digit start"       validate_app_name "2node"
assert_false "validate_app_name: empty"             validate_app_name ""
assert_false "validate_app_name: slash traversal"   validate_app_name "../etc/cron.d/x"
assert_false "validate_app_name: embedded slash"    validate_app_name "a/b"
assert_false "validate_app_name: space"             validate_app_name "a b"
assert_false "validate_app_name: newline"           validate_app_name $'a\nb'
assert_false "validate_app_name: pipe"              validate_app_name "a|b"
assert_false "validate_app_name: ampersand"         validate_app_name "a&b"
assert_false "validate_app_name: semicolon"         validate_app_name "a;b"
assert_false "validate_app_name: command sub"       validate_app_name 'a$(id)'
assert_false "validate_app_name: leading dash"      validate_app_name "-node"
assert_false "validate_app_name: dot"               validate_app_name "a.b"
assert_false "validate_app_name: too long"          validate_app_name "$(printf 'a%.0s' {1..64})"

# -----------------------------------------------------------------------
# generate_uuid_v4
# -----------------------------------------------------------------------
cat() { return 1; }
uuidgen() { return 1; }
python3() {
    if [ "${1:-}" = "-c" ]; then
        echo "11111111-2222-4333-8444-555555555555"
        return 0
    fi
    return 1
}
export -f cat uuidgen python3
assert_eq "$(generate_uuid_v4)" "11111111-2222-4333-8444-555555555555" \
    "generate_uuid_v4: falls back to python3"
unset -f cat uuidgen python3

# -----------------------------------------------------------------------
# openssl_supports_addext
# -----------------------------------------------------------------------
openssl() {
    if [ "${1:-}" = "req" ] && [ "${2:-}" = "-help" ]; then
        echo "Usage: openssl req [-addext ext]"
        return 0
    fi
    return 1
}
export -f openssl
assert_true "openssl_supports_addext: detects -addext support" openssl_supports_addext

openssl() {
    if [ "${1:-}" = "req" ] && [ "${2:-}" = "-help" ]; then
        echo "Usage: openssl req"
        return 0
    fi
    return 1
}
export -f openssl
assert_false "openssl_supports_addext: handles older OpenSSL help" openssl_supports_addext
unset -f openssl

# -----------------------------------------------------------------------
# gen_self_signed_cert  (must leave the private key owner-readable only)
# -----------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
    cert_test_dir="$WORK_DIR/certtest/certs"
    mkdir -p "$cert_test_dir"
    SSL_CERT_FILE="$cert_test_dir/ssl_cert.pem"
    SSL_KEY_FILE="$cert_test_dir/ssl_key.pem"
    AUTO_CONFIRM=true
    INSTALL_SAN_ENTRIES=""
    # Simulate a re-install/renew over a previously world-readable key:
    # openssl -keyout truncates in place and preserves the existing 0644 mode,
    # so the key would stay world-readable without explicit hardening.
    install -m 644 /dev/null "$SSL_KEY_FILE"
    gen_self_signed_cert >/dev/null 2>&1
    if [ -f "$SSL_KEY_FILE" ]; then
        pass "gen_self_signed_cert: key generated"
        assert_eq "$(stat -c '%a' "$SSL_KEY_FILE")" "600" "gen_self_signed_cert: private key is 0600"
    else
        fail "gen_self_signed_cert: key generated"
    fi
    AUTO_CONFIRM=false
    # Restore globals to source-time values for later tests
    SSL_CERT_FILE="$DATA_DIR/certs/ssl_cert.pem"
    SSL_KEY_FILE="$DATA_DIR/certs/ssl_key.pem"
else
    echo "(skipped gen_self_signed_cert: openssl not available)"
fi

# -----------------------------------------------------------------------
# detect_node_serviced_platform
# -----------------------------------------------------------------------
# Mock uname
uname() {
    case "${1:-}" in
        -s) echo "Linux" ;;
        -m) echo "x86_64" ;;
    esac
}
export -f uname
assert_eq "$(detect_node_serviced_platform)" "Linux_x86_64" \
    "detect_node_serviced_platform: identifies x86_64"

uname() {
    case "${1:-}" in
        -s) echo "Linux" ;;
        -m) echo "aarch64" ;;
    esac
}
export -f uname
assert_eq "$(detect_node_serviced_platform)" "Linux_arm64" \
    "detect_node_serviced_platform: identifies arm64"
unset -f uname

# -----------------------------------------------------------------------
# node-serviced binary validation and atomic replacement
# -----------------------------------------------------------------------
service_test_dir="$WORK_DIR/node-serviced"
mkdir -p "$service_test_dir"
valid_binary="$service_test_dir/valid"
empty_binary="$service_test_dir/empty"
invalid_binary="$service_test_dir/invalid"
printf '\177ELFtest-binary\n' > "$valid_binary"
: > "$empty_binary"
printf '<html>download failed</html>\n' > "$invalid_binary"

assert_true "verify_node_serviced_binary: accepts non-empty ELF" \
    verify_node_serviced_binary "$valid_binary"
assert_false "verify_node_serviced_binary: rejects empty file" \
    verify_node_serviced_binary "$empty_binary"
assert_false "verify_node_serviced_binary: rejects non-ELF content" \
    verify_node_serviced_binary "$invalid_binary"

checksum_archive="$service_test_dir/archive.tar.gz"
checksum_dir="$service_test_dir/checksum"
checksum_asset="node-serviced_test_Linux_x86_64.tar.gz"
mkdir -p "$checksum_dir"
printf 'archive-content\n' > "$checksum_archive"
checksum_value=$(sha256sum "$checksum_archive" | awk '{print $1}')
curl() {
    local output=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then
            output="$2"
            shift 2
        else
            shift
        fi
    done
    printf '%s  %s\n' "$checksum_value" "$checksum_asset" > "$output"
}
assert_true "verify_node_serviced_checksum: accepts matching release checksum" \
    verify_node_serviced_checksum "https://example.invalid/checksums.txt" "$checksum_asset" "$checksum_archive" "$checksum_dir"
checksum_value="$(printf '0%.0s' {1..64})"
assert_false "verify_node_serviced_checksum: rejects mismatch" \
    verify_node_serviced_checksum "https://example.invalid/checksums.txt" "$checksum_asset" "$checksum_archive" "$checksum_dir"
curl() { echo ""; return 0; }

assert_false "verify_node_serviced_checksum: rejects missing checksum by default" \
    verify_node_serviced_checksum "" "$checksum_asset" "$checksum_archive" "$checksum_dir"
NODE_SERVICE_REQUIRE_CHECKSUM=false
assert_true "verify_node_serviced_checksum: allows missing checksum only when explicitly disabled" \
    verify_node_serviced_checksum "" "$checksum_asset" "$checksum_archive" "$checksum_dir"
unset NODE_SERVICE_REQUIRE_CHECKSUM

# A failed temporary-directory allocation must stop before constructing
# /release.json or attempting any release API request.
original_create_temp_dir_definition=$(declare -f create_temp_dir)
original_run_node_service_external_definition=$(declare -f run_node_service_external)
release_request_attempted=false
release_request_target=""
create_temp_dir() { return 73; }
run_node_service_external() {
    release_request_attempted=true
    release_request_target="${*: -1}"
    return 1
}
assert_false "install_node_service_script: temp-dir failure is fatal" \
    install_node_service_script false
assert_eq "$release_request_attempted" "false" \
    "install_node_service_script: temp-dir failure skips release request"
assert_false "install_node_service_script: temp-dir failure never targets /release.json" \
    test "$release_request_target" = "/release.json"
eval "$original_create_temp_dir_definition"
eval "$original_run_node_service_external_definition"

SERVICE_BINARY_PATH="$service_test_dir/pg-node-service"
printf '\177ELFold-binary\n' > "$SERVICE_BINARY_PATH"
assert_true "activate_node_serviced_binary: stages a rollback candidate" \
    activate_node_serviced_binary "$valid_binary" true
if grep -q 'test-binary' "$SERVICE_BINARY_PATH"; then
    pass "activate_node_serviced_binary: activates staged binary"
else
    fail "activate_node_serviced_binary: activates staged binary"
fi
rollback_node_serviced_binary
if grep -q 'old-binary' "$SERVICE_BINARY_PATH"; then
    pass "rollback_node_serviced_binary: restores previous binary"
else
    fail "rollback_node_serviced_binary: restores previous binary"
fi
NODE_SERVICE_HAD_PREVIOUS=false
NODE_SERVICE_BACKUP_PATH=""
SERVICE_NAME=""
rollback_output=$(rollback_node_serviced_binary 2>&1)
if [[ "$rollback_output" == *"No previous node-serviced binary is available; removing the failed replacement."* ]]; then
    pass "rollback_node_serviced_binary: reports no-backup removal"
else
    fail "rollback_node_serviced_binary: reports no-backup removal"
fi
assert_false "rollback_node_serviced_binary: removes failed replacement without backup" \
    test -e "$SERVICE_BINARY_PATH"
printf '\177ELFold-binary\n' > "$SERVICE_BINARY_PATH"
assert_false "activate_node_serviced_binary: rejects invalid candidate" \
    activate_node_serviced_binary "$invalid_binary" true
if grep -q 'old-binary' "$SERVICE_BINARY_PATH"; then
    pass "activate_node_serviced_binary: preserves target after rejected candidate"
else
    fail "activate_node_serviced_binary: preserves target after rejected candidate"
fi

ready_cert="$service_test_dir/ssl-cert.pem"
ready_env="$service_test_dir/node-service.env"
: > "$ready_cert"
printf 'API_PORT= 62051\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
ENV_FILE="$ready_env"
printf 'API_KEY= "unit#test-key" # deployment note\n' > "$ready_env"
assert_eq "$(read_node_service_env_value API_KEY)" "unit#test-key" \
    "read_node_service_env_value: preserves a quoted hash before a trailing comment"
printf 'API_KEY= unit-test-key # deployment note\n' > "$ready_env"
assert_eq "$(read_node_service_env_value API_KEY)" "unit-test-key" \
    "read_node_service_env_value: removes comments from unquoted values"
cat > "$ready_env" <<'EOF'
API_PORT= 61000
export API_PORT = "62051"
PREFIX=unit
API_KEY="${PREFIX}\\nkey-\$literal"
API_KEY='last-${PREFIX}-value'
EOF
assert_eq "$(read_node_service_env_value API_PORT)" "62051" \
    "read_node_service_env_value: matches Overload export and last duplicate wins"
assert_eq "$(read_node_service_env_value API_KEY)" 'last-${PREFIX}-value' \
    "read_node_service_env_value: matches Overload single-quote literal semantics"
cat > "$ready_env" <<'EOF'
PREFIX=unit
API_KEY="${PREFIX}\nkey-\$literal"
EOF
assert_eq "$(read_node_service_env_value API_KEY)" $'unit\nkey-$literal' \
    "read_node_service_env_value: matches Overload expansion and double-quote escapes"
printf 'API_KEY="valid-prefix" trailing-garbage\n' > "$ready_env"
assert_false "read_node_service_env_value: rejects garbage after a quoted value" \
    read_node_service_env_value API_KEY
printf 'API_PORT= 62051\nAPI_KEY= "unit#test-key" # deployment note\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
SERVICE_NAME="pg-node-test-service"
NODE_SERVICE_READINESS_ATTEMPTS=1
NODE_SERVICE_READINESS_STABLE_CHECKS=1
NODE_SERVICE_READINESS_DELAY_SECONDS=0
api_ready_calls=0
systemctl() { [ "${1:-}" = "is-active" ]; }
openssl() {
    case "${NODE_SERVICE_CERT_TEST_MODE:-dns}" in
    wildcard) printf 'X509v3 Subject Alternative Name:\n    DNS:*.example.test\n' ;;
    cn)
        if [[ " $* " == *' -subject '* ]]; then
            printf 'subject=CN=legacy.example.test\n'
        else
            printf 'No extensions in certificate\n'
        fi
        ;;
    *) printf 'X509v3 Subject Alternative Name:\n    DNS:node.example.test\n' ;;
    esac
}
curl() {
    api_ready_config=$(cat "$2")
    api_ready_config_path="$2"
    api_ready_calls=$((api_ready_calls + 1))
    [ "${NODE_SERVICE_API_READY:-true}" = true ]
}
assert_true "wait_for_node_service_ready: requires authenticated API success" \
    wait_for_node_service_ready
assert_eq "$api_ready_calls" "1" \
    "wait_for_node_service_ready: checks the service API after systemd"
if [[ "$api_ready_config" == *'header = "x-api-key: unit#test-key"'* ]]; then
    pass "wait_for_node_service_ready: preserves a quoted API key before a trailing comment"
else
    fail "wait_for_node_service_ready: preserves a quoted API key before a trailing comment"
fi
if [[ "$api_ready_config" == *'connect-to = "::127.0.0.1:62051"'* ]] &&
    [[ "$api_ready_config" == *'url = "https://node.example.test:62051/"'* ]]; then
    pass "node_service_api_ready: preserves DNS SAN for SNI while connecting to loopback"
else
    fail "node_service_api_ready: preserves DNS SAN for SNI while connecting to loopback"
fi
assert_false "wait_for_node_service_ready: removes the temporary curl config" \
    test -e "$api_ready_config_path"
printf 'API_PORT= 62051\nAPI_KEY= '\''unit\\key"quote'\''\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
assert_true "node_service_api_ready: accepts API keys containing quote and backslash" \
    node_service_api_ready
expected_curl_header='header = "x-api-key: unit\\key\"quote"'
if grep -Fqx -- "$expected_curl_header" <<<"$api_ready_config"; then
    pass "node_service_api_ready: curl config escapes quote and backslash once"
else
    fail "node_service_api_ready: curl config escapes quote and backslash once"
fi
printf 'API_PORT= 62051\nAPI_KEY= "unit#test-key" # deployment note\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
NODE_SERVICE_CERT_TEST_MODE=wildcard
assert_true "node_service_certificate_identity: accepts wildcard DNS SAN" \
    node_service_certificate_identity "$ready_cert"
assert_eq "$NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT" "node-serviced-health.example.test" \
    "node_service_certificate_identity: synthesizes one wildcard label"
NODE_SERVICE_CERT_TEST_MODE=cn
assert_true "node_service_certificate_identity: supports SAN-less CN fallback" \
    node_service_certificate_identity "$ready_cert"
assert_eq "$NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT" "legacy.example.test" \
    "node_service_certificate_identity: uses CN only without SAN"
unset NODE_SERVICE_CERT_TEST_MODE
printf 'API_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
assert_true "node_service_api_ready: uses node-serviced default port when API_PORT is absent" \
    node_service_api_ready
if [[ "$api_ready_config" == *'url = "https://node.example.test:3000/"'* ]]; then
    pass "node_service_api_ready: probes node-serviced default port 3000"
else
    fail "node_service_api_ready: probes node-serviced default port 3000"
fi
printf 'API_PORT= 62051\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
NODE_SERVICE_API_READY=false
assert_false "wait_for_node_service_ready: rejects active service with unavailable API" \
    wait_for_node_service_ready
unset NODE_SERVICE_API_READY

# The lock is held for the entire update transaction so a second updater
# cannot create a stale backup and later overwrite a successful install.
NODE_SERVICE_UPDATE_LOCK_PATH="$service_test_dir/update.lock"
flock() {
    case "${1:-}" in
    -n) [ "${NODE_SERVICE_UPDATE_LOCK_BUSY:-false}" != true ] ;;
    -u) return 0 ;;
    *) return 0 ;;
    esac
}
NODE_SERVICE_UPDATE_LOCK_BUSY=true
assert_false "acquire_node_serviced_update_lock: rejects a concurrent updater" \
    acquire_node_serviced_update_lock
NODE_SERVICE_UPDATE_LOCK_BUSY=false
assert_true "acquire_node_serviced_update_lock: acquires an available lock" \
    acquire_node_serviced_update_lock
assert_true "release_node_serviced_update_lock: releases the transaction lock" \
    release_node_serviced_update_lock
assert_eq "$NODE_SERVICE_UPDATE_LOCK_HELD" "false" \
    "release_node_serviced_update_lock: clears lock state"
unset -f flock
unset NODE_SERVICE_UPDATE_LOCK_BUSY NODE_SERVICE_UPDATE_LOCK_PATH

# Exercise kernel-level contention with a separate process. This is the
# inter-process boundary shared by service-install/update/uninstall.
NODE_SERVICE_UPDATE_LOCK_PATH="$service_test_dir/process-update.lock"
lock_ready="$service_test_dir/process-lock-ready"
lock_release="$service_test_dir/process-lock-release"
(
    exec 8>"$NODE_SERVICE_UPDATE_LOCK_PATH"
    flock 8
    : > "$lock_ready"
    while [ ! -e "$lock_release" ]; do
        sleep 0.01
    done
) &
lock_holder_pid=$!
lock_wait_attempt=0
while [ ! -e "$lock_ready" ] && [ "$lock_wait_attempt" -lt 100 ]; do
    sleep 0.01
    lock_wait_attempt=$((lock_wait_attempt + 1))
done
assert_true "node-serviced update lock: separate process acquired the lock" \
    test -e "$lock_ready"
assert_false "node-serviced update lock: blocks a concurrent transaction" \
    acquire_node_serviced_update_lock
: > "$lock_release"
wait "$lock_holder_pid"
assert_true "node-serviced update lock: becomes available after transaction exit" \
    acquire_node_serviced_update_lock
release_node_serviced_update_lock
unset NODE_SERVICE_UPDATE_LOCK_PATH

assert_true "can_reuse_node_service_api_port: permits the current service port" \
    can_reuse_node_service_api_port true 62051 62051
assert_false "can_reuse_node_service_api_port: rejects a different occupied port" \
    can_reuse_node_service_api_port true 62052 62051
assert_false "can_reuse_node_service_api_port: rejects a port without an installed service" \
    can_reuse_node_service_api_port false 62051 62051

# Exercise the complete update failure path: the replacement is installed,
# the first restart fails, rollback restores the old binary, and the second
# restart attempts to bring the old version back online.
set_service_paths() {
    SERVICE_NAME="pg-node-test-service"
    SERVICE_BINARY_PATH="$service_test_dir/pg-node-service"
    SERVICE_UNIT="$service_test_dir/pg-node-test-service.service"
}
service_installed() {
    [ "$NODE_SERVICE_UPDATE_LOCK_HELD" = true ]
}
id() { echo 0; }
update_activation_marker="$service_test_dir/update-activated"
install_node_service_script() {
    activate_node_serviced_binary "$valid_binary" true
    : > "$update_activation_marker"
}
NODE_SERVICE_UPDATE_LOCK_PATH="$service_test_dir/transaction-update.lock"
NODE_SERVICE_READINESS_ATTEMPTS=1
NODE_SERVICE_READINESS_STABLE_CHECKS=1
NODE_SERVICE_READINESS_DELAY_SECONDS=0
restart_attempts_file="$service_test_dir/restart-attempts"
printf '0\n' > "$restart_attempts_file"
systemctl() {
    if [ "${1:-}" = "daemon-reload" ]; then
        return 0
    fi
    if [ "${1:-}" = "restart" ]; then
        local attempts
        attempts=$(cat "$restart_attempts_file")
        attempts=$((attempts + 1))
        printf '%s\n' "$attempts" > "$restart_attempts_file"
        [ "$attempts" -gt 1 ]
        return
    fi
    return 0
}
if (update_service_if_installed >/dev/null 2>&1); then
    fail "update_service_if_installed: reports restart failure"
else
    pass "update_service_if_installed: reports restart failure"
fi
if grep -q 'old-binary' "$SERVICE_BINARY_PATH"; then
    pass "update_service_if_installed: rolls back failed replacement"
else
    fail "update_service_if_installed: rolls back failed replacement"
fi
assert_eq "$(cat "$restart_attempts_file")" "2" \
    "update_service_if_installed: restarts restored binary"

# A successful `systemctl restart` is not sufficient: systemd can return zero
# before a crashing Type=simple process exits. Readiness failure must retain and
# restore the backup just like an immediate restart failure.
rm -f "$update_activation_marker"
printf '\177ELFold-binary\n' > "$SERVICE_BINARY_PATH"
printf '0\n' > "$restart_attempts_file"
readiness_attempts_file="$service_test_dir/readiness-attempts"
printf '0\n' > "$readiness_attempts_file"
systemctl() {
    case "${1:-}" in
    daemon-reload)
        return 0
        ;;
    restart)
        local restarts
        restarts=$(cat "$restart_attempts_file")
        printf '%s\n' "$((restarts + 1))" > "$restart_attempts_file"
        return 0
        ;;
    is-active)
        local checks
        if [ ! -e "$update_activation_marker" ]; then
            return 0
        fi
        checks=$(cat "$readiness_attempts_file")
        printf '%s\n' "$((checks + 1))" > "$readiness_attempts_file"
        return 1
        ;;
    esac
    return 0
}
sleep() { return 0; }
if (update_service_if_installed >/dev/null 2>&1); then
    fail "update_service_if_installed: reports inactive service after restart=0"
else
    pass "update_service_if_installed: reports inactive service after restart=0"
fi
if grep -q 'old-binary' "$SERVICE_BINARY_PATH"; then
    pass "update_service_if_installed: rolls back restart=0 but inactive replacement"
else
    fail "update_service_if_installed: rolls back restart=0 but inactive replacement"
fi
assert_eq "$(cat "$restart_attempts_file")" "2" \
    "update_service_if_installed: retries restored binary after readiness failure"
assert_eq "$(cat "$readiness_attempts_file")" "2" \
    "update_service_if_installed: readiness-checks replacement and restored binary"
unset -f set_service_paths service_installed id install_node_service_script systemctl sleep openssl
rm -f "$update_activation_marker"
unset NODE_SERVICE_READINESS_ATTEMPTS NODE_SERVICE_READINESS_STABLE_CHECKS NODE_SERVICE_READINESS_DELAY_SECONDS
unset NODE_SERVICE_UPDATE_LOCK_PATH

# -----------------------------------------------------------------------
# is_port_occupied
# -----------------------------------------------------------------------
OCCUPIED_PORTS=$(printf "80\n443\n62051\n")
assert_true  "is_port_occupied: 80 is busy"    is_port_occupied 80
assert_true  "is_port_occupied: 62051 is busy" is_port_occupied 62051
assert_false "is_port_occupied: 9000 is free"  is_port_occupied 9000

# -----------------------------------------------------------------------
# is_node_installed  (APP_DIR is a temp dir we created)
# -----------------------------------------------------------------------
assert_true  "is_node_installed: APP_DIR exists"   is_node_installed
rm -rf "$APP_DIR"
assert_false "is_node_installed: APP_DIR missing"  is_node_installed
mkdir -p "$APP_DIR"

# -----------------------------------------------------------------------
# sync_env_ssl_paths
# Skips when APP_NAME="pg-node"; updates old /var/lib/pg-node/ paths;
# appends if key is missing; is no-op when ENV_FILE doesn't exist.
# -----------------------------------------------------------------------

# Case 1: APP_NAME is the default "pg-node" — function exits immediately
APP_NAME="pg-node"
cat > "$ENV_FILE" <<'EOF'
SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem
SSL_KEY_FILE= /var/lib/pg-node/certs/ssl_key.pem
EOF
sync_env_ssl_paths
if grep -q "/var/lib/pg-node/" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: no-op when APP_NAME=pg-node"
else
    fail "sync_env_ssl_paths: no-op when APP_NAME=pg-node"
fi

# Case 2: custom APP_NAME with old pg-node paths — should update them
APP_NAME="my-node"
DATA_DIR="$WORK_DIR/my-node-data"
APP_DIR="$WORK_DIR/my-node-app"
ENV_FILE="$APP_DIR/.env"
mkdir -p "$APP_DIR" "$DATA_DIR"
cat > "$ENV_FILE" <<'EOF'
SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem
SSL_KEY_FILE= /var/lib/pg-node/certs/ssl_key.pem
EOF
sync_env_ssl_paths
expected_cert="$DATA_DIR/certs/ssl_cert.pem"
expected_key="$DATA_DIR/certs/ssl_key.pem"
if grep -q "SSL_CERT_FILE= $expected_cert" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: cert path updated for custom APP_NAME"
else
    fail "sync_env_ssl_paths: cert path updated for custom APP_NAME (got: $(grep SSL_CERT_FILE "$ENV_FILE"))"
fi
if grep -q "SSL_KEY_FILE= $expected_key" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: key path updated for custom APP_NAME"
else
    fail "sync_env_ssl_paths: key path updated for custom APP_NAME (got: $(grep SSL_KEY_FILE "$ENV_FILE"))"
fi

# Case 3: custom APP_NAME with correct paths already — should NOT change them
cat > "$ENV_FILE" <<EOF
SSL_CERT_FILE= $expected_cert
SSL_KEY_FILE= $expected_key
EOF
sync_env_ssl_paths
if grep -q "SSL_CERT_FILE= $expected_cert" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: already-correct paths left unchanged"
else
    fail "sync_env_ssl_paths: already-correct paths left unchanged"
fi

# Case 4: missing ENV_FILE — function must not crash
APP_NAME="my-node"
ENV_FILE="/nonexistent/dir/.env"
sync_env_ssl_paths
pass "sync_env_ssl_paths: no crash when ENV_FILE missing"

# -----------------------------------------------------------------------
# version-script CLI command & completions
# -----------------------------------------------------------------------
ver_out=$(pg_node_main version-script)
if [[ "$ver_out" == *"# Executing pg-node script, commit:"* ]]; then
    pass "version-script: output contains '# Executing pg-node script, commit:'"
else
    fail "version-script: output contains '# Executing pg-node script, commit:'"
fi

bash_comp_out=$(generate_bash_completion)
if [[ "$bash_comp_out" == *"version-script"* && "$bash_comp_out" == *"script-version"* ]]; then
    pass "bash completion: contains version-script and script-version"
else
    fail "bash completion: contains version-script and script-version"
fi

zsh_comp_out=$(generate_zsh_completion)
if [[ "$zsh_comp_out" == *"version-script"* && "$zsh_comp_out" == *"script-version"* ]]; then
    pass "zsh completion: contains version-script and script-version"
else
    fail "zsh completion: contains version-script and script-version"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
