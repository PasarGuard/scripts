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

# Record and print a passed test assertion.
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
# Record and print a failed test assertion.
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

# Assert equality between actual and expected values.
assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

# Assert that the given command evaluates to true (zero exit status).
assert_true() {
    local label="$1"; shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

# Assert that the given command evaluates to false (nonzero exit status).
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
# Mock cat to simulate unavailable /proc/sys/kernel/random/uuid.
cat() { return 1; }
# Mock uuidgen to simulate unavailable uuidgen binary.
uuidgen() { return 1; }
# Mock python3 to return a fixed UUID string.
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
# Mock openssl to report -addext support in req -help.
openssl() {
    if [ "${1:-}" = "req" ] && [ "${2:-}" = "-help" ]; then
        echo "Usage: openssl req [-addext ext]"
        return 0
    fi
    return 1
}
export -f openssl
assert_true "openssl_supports_addext: detects -addext support" openssl_supports_addext

# Mock openssl to report lack of -addext support in req -help.
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

# Mock uname to simulate Linux aarch64 architecture.
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

# -----------------------------------------------------------------------
# install_command version selection (--dev, --pre-release, --version)
# Host-touching steps are stubbed in a subshell; curl and install_node
# record their calls so the release lookup and chosen tag can be checked.
# -----------------------------------------------------------------------
INSTALL_CALLS="$WORK_DIR/install-calls.log"
INSTALL_OUT=""
INSTALL_STATUS=0

# Canned GitHub releases API answers for the curl stubs: v9.9.99 does not exist.
release_api_reply() {
    case "$*" in
        *"/tags/v9.9.99"*) printf '404' ;;
        *"%{http_code}"*) printf '200' ;;
        */releases/latest*) printf '{"tag_name":"v9.9.9"}' ;;
        */releases) printf '[{"tag_name":"v9.9.10-beta","prerelease":true}]' ;;
        *) printf '{}' ;;
    esac
}

# Run install_command with stubbed host steps; sets INSTALL_OUT and INSTALL_STATUS.
run_install_command() {
    : > "$INSTALL_CALLS"
    if INSTALL_OUT=$(
        check_running_as_root() { :; }
        print_script_execution_header() { :; }
        is_node_installed() { return 1; }
        detect_os() { :; }
        install_package() { :; }
        install_docker() { :; }
        ensure_docker_compose() { :; }
        install_yq() { :; }
        detect_compose() { :; }
        curl() { echo "curl $*" >> "$INSTALL_CALLS"; release_api_reply "$@"; }
        install_node() { echo "install_node $1" >> "$INSTALL_CALLS"; }
        install_node_script() { :; }
        install_completion() { :; }
        up_node() { :; }
        show_node_logs() { :; }
        install_service_command() { :; }
        INSTALL_SERVICE_CHOICE="n"
        SERVICE_PORT="62050"
        API_KEY="00000000-0000-4000-8000-000000000000"
        SSL_CERT_FILE="/dev/null"
        install_command "$@" 2>&1
    ); then
        INSTALL_STATUS=0
    else
        INSTALL_STATUS=$?
    fi
}

# Print the version install_node was called with, or nothing.
installed_version() {
    sed -n 's/^install_node //p' "$INSTALL_CALLS"
}

# Succeed if any recorded curl call hit the node GitHub releases API.
release_lookup_done() {
    grep -q "api.github.com/repos/PasarGuard/node/releases" "$INSTALL_CALLS"
}

run_install_command --dev
assert_eq "$INSTALL_STATUS" "0" "install --dev: exits 0"
assert_eq "$(installed_version)" "dev" "install --dev: installs image tag dev"
assert_false "install --dev: skips the GitHub release lookup" release_lookup_done
if [[ "$INSTALL_OUT" == *"unreleased"* ]]; then
    pass "install --dev: prints the unreleased build note"
else
    fail "install --dev: prints the unreleased build note"
fi

for dev_conflict in "--dev --version v1.2.3" "--version v1.2.3 --dev" "--dev --pre-release" "--pre-release --dev" "-v v1.2.3 --dev"; do
    # shellcheck disable=SC2086
    run_install_command $dev_conflict
    assert_eq "$INSTALL_STATUS" "1" "install $dev_conflict: exits 1"
    assert_eq "$(installed_version)" "" "install $dev_conflict: installs nothing"
    if [[ "$INSTALL_OUT" == *"Cannot use --pre-release, --dev and --version options simultaneously."* ]]; then
        pass "install $dev_conflict: names all three exclusive options"
    else
        fail "install $dev_conflict: names all three exclusive options (got: $INSTALL_OUT)"
    fi
done

# Existing selections keep their release lookup and resolved tag
run_install_command
assert_eq "$INSTALL_STATUS" "0" "install (latest): exits 0"
assert_eq "$(installed_version)" "latest" "install (latest): installs image tag latest"
assert_true "install (latest): checks releases/latest" grep -q "PasarGuard/node/releases/latest" "$INSTALL_CALLS"
if [[ "$INSTALL_OUT" != *"unreleased"* ]]; then
    pass "install (latest): no dev note"
else
    fail "install (latest): no dev note"
fi

run_install_command --pre-release
assert_eq "$INSTALL_STATUS" "0" "install --pre-release: exits 0"
assert_eq "$(installed_version)" "v9.9.10-beta" "install --pre-release: installs the newest release tag"

run_install_command --version v1.2.3
assert_eq "$INSTALL_STATUS" "0" "install --version v1.2.3: exits 0"
assert_eq "$(installed_version)" "v1.2.3" "install --version v1.2.3: installs image tag v1.2.3"
assert_true "install --version v1.2.3: checks releases/tags/v1.2.3" grep -q "PasarGuard/node/releases/tags/v1.2.3" "$INSTALL_CALLS"

run_install_command --version v1.2.3 --pre-release
assert_eq "$INSTALL_STATUS" "1" "install --version with --pre-release: exits 1"

run_install_command --version 1.2
assert_eq "$INSTALL_STATUS" "1" "install --version 1.2: rejects an invalid version"
assert_eq "$(installed_version)" "" "install --version 1.2: installs nothing"

# -----------------------------------------------------------------------
# set_node_image_tag  (compose image rewrite used by install_node)
# Needs mikefarah yq v4 (what install_yq installs); skipped otherwise.
# -----------------------------------------------------------------------
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q "mikefarah"; then
    image_compose="$WORK_DIR/image-test/docker-compose.yml"
    mkdir -p "$(dirname "$image_compose")"
    cp "$ROOT_DIR/docker-compose/node.yml" "$image_compose"
    if set_node_image_tag "dev" "$image_compose"; then
        pass "set_node_image_tag: dev rewrite succeeds"
    else
        fail "set_node_image_tag: dev rewrite succeeds"
    fi
    assert_eq "$(yq eval -r '.services["node"].image' "$image_compose")" "pasarguard/node:dev" \
        "set_node_image_tag: image becomes pasarguard/node:dev"
    assert_true "set_node_image_tag: compose file has 'image: pasarguard/node:dev'" \
        grep -q "^    image: pasarguard/node:dev$" "$image_compose"
    assert_eq "$(yq eval -r '.services["node"].container_name' "$image_compose")" "node" \
        "set_node_image_tag: other keys untouched"
    if set_node_image_tag "v0.5.4" "$image_compose"; then
        pass "set_node_image_tag: release rewrite succeeds"
    else
        fail "set_node_image_tag: release rewrite succeeds"
    fi
    assert_eq "$(yq eval -r '.services["node"].image' "$image_compose")" "pasarguard/node:v0.5.4" \
        "set_node_image_tag: a dev compose file can move back to a release tag"
else
    echo "(skipped set_node_image_tag: mikefarah yq v4 not available)"
fi

# -----------------------------------------------------------------------
# update_command image selection (--dev, --version) and the plain update.
# Host steps, compose and curl are stubbed in a subshell; the compose file,
# .env and certs are real files in a fresh temp dir per case.
# -----------------------------------------------------------------------
UPDATE_CALLS="$WORK_DIR/update-calls.log"
UPDATE_DIR=""
UPDATE_OUT=""
UPDATE_STATUS=0
UPDATE_CASE=0
UPDATE_TAG_FAILS="false"

# Create an installed node layout whose compose image uses the given tag.
make_update_fixture() {
    UPDATE_CASE=$((UPDATE_CASE + 1))
    UPDATE_DIR="$WORK_DIR/update-$UPDATE_CASE"
    mkdir -p "$UPDATE_DIR/app" "$UPDATE_DIR/data/certs" "$UPDATE_DIR/before"
    cat > "$UPDATE_DIR/app/docker-compose.yml" <<EOF
services:
  node:
    container_name: node
    image: pasarguard/node:$1
    restart: always
    network_mode: host
    env_file: .env
EOF
    printf 'SERVICE_PORT= 62050\nAPI_KEY= 11111111-2222-4333-8444-555555555555\nAPI_PORT= 62051\n' > "$UPDATE_DIR/app/.env"
    printf 'CERT\n' > "$UPDATE_DIR/data/certs/ssl_cert.pem"
    printf 'KEY\n' > "$UPDATE_DIR/data/certs/ssl_key.pem"
    cp "$UPDATE_DIR/app/docker-compose.yml" "$UPDATE_DIR/app/.env" "$UPDATE_DIR/data/certs/ssl_cert.pem" \
        "$UPDATE_DIR/data/certs/ssl_key.pem" "$UPDATE_DIR/before/"
}

# Run update_command against the current fixture; sets UPDATE_OUT and UPDATE_STATUS.
run_update_command() {
    : > "$UPDATE_CALLS"
    if UPDATE_OUT=$(
        APP_DIR="$UPDATE_DIR/app"
        DATA_DIR="$UPDATE_DIR/data"
        COMPOSE_FILE="$APP_DIR/docker-compose.yml"
        ENV_FILE="$APP_DIR/.env"
        set_service_paths
        check_running_as_root() { :; }
        detect_os() { :; }
        install_package() { :; }
        install_yq() { :; }
        detect_compose() { COMPOSE="fake_compose"; }
        fake_compose() { echo "compose $*" >> "$UPDATE_CALLS"; }
        ensure_docker_service_running() { :; }
        update_node_script() { echo "update_node_script" >> "$UPDATE_CALLS"; }
        uninstall_completion() { :; }
        install_completion() { :; }
        update_service_if_installed() { echo "update_service_if_installed" >> "$UPDATE_CALLS"; }
        curl() { echo "curl $*" >> "$UPDATE_CALLS"; release_api_reply "$@"; }
        if [ "$UPDATE_TAG_FAILS" = "true" ]; then
            set_node_image_tag() { return 1; }
        fi
        update_command "$@" 2>&1
    ); then
        UPDATE_STATUS=0
    else
        UPDATE_STATUS=$?
    fi
}

# Print the image line of the fixture compose file.
fixture_image() {
    sed -n 's/^    image: //p' "$UPDATE_DIR/app/docker-compose.yml"
}

# Succeed if the given fixture file is byte-identical to its copy taken before the run.
fixture_unchanged() {
    cmp -s "$UPDATE_DIR/before/$(basename "$1")" "$1"
}

# Assert .env and both cert files are byte-identical after the run.
assert_secrets_unchanged() {
    assert_true "$1: .env unchanged" fixture_unchanged "$UPDATE_DIR/app/.env"
    assert_true "$1: ssl_cert.pem unchanged" fixture_unchanged "$UPDATE_DIR/data/certs/ssl_cert.pem"
    assert_true "$1: ssl_key.pem unchanged" fixture_unchanged "$UPDATE_DIR/data/certs/ssl_key.pem"
}

# Assert the run stopped before touching anything: compose file intact, no script update, no pull.
assert_update_refused() {
    assert_eq "$UPDATE_STATUS" "1" "$1: exits 1"
    assert_true "$1: compose file unchanged" fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"
    assert_false "$1: no script update" grep -q "^update_node_script$" "$UPDATE_CALLS"
    assert_false "$1: no image pull" grep -q " pull$" "$UPDATE_CALLS"
}

# Plain update (what node-serviced runs) keeps the compose file as it is
make_update_fixture "latest"
run_update_command
assert_eq "$UPDATE_STATUS" "0" "update: exits 0"
assert_true "update: compose file byte-identical" fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"
assert_false "update: no release lookup" grep -q "^curl " "$UPDATE_CALLS"
assert_true "update: pulls images" grep -q " pull$" "$UPDATE_CALLS"
assert_true "update: updates node-serviced" grep -q "^update_service_if_installed$" "$UPDATE_CALLS"
assert_secrets_unchanged "update"

make_update_fixture "dev"
run_update_command --no-update-service
assert_eq "$UPDATE_STATUS" "0" "update --no-update-service on dev: exits 0"
assert_true "update --no-update-service on dev: compose file byte-identical (dev stays dev)" \
    fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"
assert_true "update --no-update-service on dev: pulls images" grep -q " pull$" "$UPDATE_CALLS"
assert_false "update --no-update-service on dev: skips node-serviced" \
    grep -q "^update_service_if_installed$" "$UPDATE_CALLS"

# --dev and --version are mutually exclusive; bad versions stop before any change
for update_conflict in "--dev --version v1.2.3" "--version v1.2.3 --dev" "--no-update-service -v v1.2.3 --dev" "--dev --dev"; do
    make_update_fixture "latest"
    # shellcheck disable=SC2086
    run_update_command $update_conflict
    assert_update_refused "update $update_conflict"
    if [[ "$UPDATE_OUT" == *"Cannot use --dev and --version options simultaneously."* ]]; then
        pass "update $update_conflict: names both exclusive options"
    else
        fail "update $update_conflict: names both exclusive options (got: $UPDATE_OUT)"
    fi
done

make_update_fixture "latest"
run_update_command --version
assert_update_refused "update --version (no value)"

make_update_fixture "latest"
run_update_command --version 1.2
assert_update_refused "update --version 1.2"

make_update_fixture "dev"
run_update_command --version v9.9.99
assert_update_refused "update --version v9.9.99 (no such release)"
assert_true "update --version v9.9.99: checked releases/tags/v9.9.99" \
    grep -q "PasarGuard/node/releases/tags/v9.9.99" "$UPDATE_CALLS"

make_update_fixture "latest"
UPDATE_TAG_FAILS="true"
run_update_command --dev
UPDATE_TAG_FAILS="false"
assert_eq "$UPDATE_STATUS" "1" "update --dev with a failing tag rewrite: exits 1"
assert_false "update --dev with a failing tag rewrite: no image pull" grep -q " pull$" "$UPDATE_CALLS"

# The tag rewrites themselves need mikefarah yq v4; skipped otherwise.
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q "mikefarah"; then
    make_update_fixture "latest"
    run_update_command --dev
    assert_eq "$UPDATE_STATUS" "0" "update --dev: exits 0"
    assert_eq "$(fixture_image)" "pasarguard/node:dev" "update --dev: image becomes pasarguard/node:dev"
    assert_false "update --dev: no release lookup" grep -q "^curl " "$UPDATE_CALLS"
    assert_true "update --dev: pulls images" grep -q " pull$" "$UPDATE_CALLS"
    if [[ "$UPDATE_OUT" == *"unreleased"* ]]; then
        pass "update --dev: prints the unreleased build note"
    else
        fail "update --dev: prints the unreleased build note"
    fi
    assert_secrets_unchanged "update --dev"

    for dev_args in "--no-update-service --dev" "--dev --no-update-service"; do
        make_update_fixture "latest"
        # shellcheck disable=SC2086
        run_update_command $dev_args
        assert_eq "$UPDATE_STATUS" "0" "update $dev_args: exits 0"
        assert_eq "$(fixture_image)" "pasarguard/node:dev" "update $dev_args: image becomes pasarguard/node:dev"
        assert_false "update $dev_args: skips node-serviced" grep -q "^update_service_if_installed$" "$UPDATE_CALLS"
    done

    make_update_fixture "dev"
    run_update_command --version v1.2.3
    assert_eq "$UPDATE_STATUS" "0" "update --version v1.2.3: exits 0"
    assert_eq "$(fixture_image)" "pasarguard/node:v1.2.3" "update --version v1.2.3: image becomes pasarguard/node:v1.2.3"
    assert_true "update --version v1.2.3: checked releases/tags/v1.2.3" \
        grep -q "PasarGuard/node/releases/tags/v1.2.3" "$UPDATE_CALLS"
    assert_true "update --version v1.2.3: pulls images" grep -q " pull$" "$UPDATE_CALLS"
    assert_secrets_unchanged "update --version v1.2.3"

    make_update_fixture "dev"
    run_update_command -v latest --no-update-service
    assert_eq "$UPDATE_STATUS" "0" "update -v latest: exits 0"
    assert_eq "$(fixture_image)" "pasarguard/node:latest" "update -v latest: dev node goes back to pasarguard/node:latest"
    assert_true "update -v latest: checked releases/latest" grep -q "PasarGuard/node/releases/latest" "$UPDATE_CALLS"

    make_update_fixture "latest"
    run_update_command --version pre-release
    assert_eq "$UPDATE_STATUS" "0" "update --version pre-release: exits 0"
    assert_eq "$(fixture_image)" "pasarguard/node:v9.9.10-beta" \
        "update --version pre-release: image becomes the newest release tag"
else
    echo "(skipped update --dev/--version tag rewrites: mikefarah yq v4 not available)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
