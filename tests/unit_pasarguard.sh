#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pasarguard-unit-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

# Stub everything that pasarguard.sh tries to set up at source time
# so it doesn't fail or make network calls.
curl() {
    # Suppress all curl calls during sourcing to avoid network dependency
    case "${1:-}" in
        -s|-4|-fsSL) echo "" ;;
        *) echo "" ;;
    esac
    return 0
}
export -f curl

export PASARGUARD_SOURCE_ONLY="true"
# shellcheck source=pasarguard.sh
source "$ROOT_DIR/pasarguard.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_true() {
    local label="$1"; shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

assert_false() {
    local label="$1"; shift
    if ! "$@"; then pass "$label"; else fail "$label"; fi
}

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_pasarguard.sh ==="

# -----------------------------------------------------------------------
# is_valid_proxy_url
# -----------------------------------------------------------------------
assert_true  "is_valid_proxy_url: http://"     is_valid_proxy_url "http://proxy.example.com:8080"
assert_true  "is_valid_proxy_url: https://"    is_valid_proxy_url "https://proxy.example.com:8080"
assert_true  "is_valid_proxy_url: socks5://"   is_valid_proxy_url "socks5://127.0.0.1:1080"
assert_true  "is_valid_proxy_url: socks5h://"  is_valid_proxy_url "socks5h://127.0.0.1:1080"
assert_true  "is_valid_proxy_url: socks4://"   is_valid_proxy_url "socks4://10.0.0.1:1080"
assert_true  "is_valid_proxy_url: socks4a://"  is_valid_proxy_url "socks4a://10.0.0.1:1080"
assert_true  "is_valid_proxy_url: socks://"    is_valid_proxy_url "socks://10.0.0.1:1080"
assert_false "is_valid_proxy_url: ftp://"      is_valid_proxy_url "ftp://proxy.example.com"
assert_false "is_valid_proxy_url: no-scheme"   is_valid_proxy_url "proxy.example.com"
assert_false "is_valid_proxy_url: empty"       is_valid_proxy_url ""
assert_false "is_valid_proxy_url: just text"   is_valid_proxy_url "notaurl"

# -----------------------------------------------------------------------
# is_domain
# -----------------------------------------------------------------------
assert_true  "is_domain: simple"        is_domain "example.com"
assert_true  "is_domain: subdomain"     is_domain "panel.example.com"
assert_true  "is_domain: deep"          is_domain "a.b.c.example.com"
assert_true  "is_domain: hyphen"        is_domain "my-panel.example.com"
assert_true  "is_domain: long tld"      is_domain "example.computer"
assert_false "is_domain: bare label"    is_domain "localhost"
assert_false "is_domain: IP"            is_domain "192.168.1.1"
assert_false "is_domain: empty"         is_domain ""
assert_false "is_domain: with space"    is_domain "exam ple.com"
assert_false "is_domain: with slash"    is_domain "example.com/path"

# -----------------------------------------------------------------------
# is_ipv4
# -----------------------------------------------------------------------
assert_true  "is_ipv4: valid 1"      is_ipv4 "192.168.1.1"
assert_true  "is_ipv4: valid 2"      is_ipv4 "0.0.0.0"
assert_true  "is_ipv4: valid 3"      is_ipv4 "255.255.255.255"
assert_true  "is_ipv4: valid 4"      is_ipv4 "10.0.0.1"
assert_false "is_ipv4: octet > 255"  is_ipv4 "256.0.0.1"
assert_false "is_ipv4: 3 octets"     is_ipv4 "192.168.1"
assert_false "is_ipv4: 5 octets"     is_ipv4 "1.2.3.4.5"
assert_false "is_ipv4: letters"      is_ipv4 "abc.def.ghi.jkl"
assert_false "is_ipv4: empty"        is_ipv4 ""
assert_false "is_ipv4: domain"       is_ipv4 "example.com"

# -----------------------------------------------------------------------
# is_ipv6
# -----------------------------------------------------------------------
assert_true  "is_ipv6: full"            is_ipv6 "2001:db8::1"
assert_true  "is_ipv6: loopback"        is_ipv6 "::1"
assert_true  "is_ipv6: double colon"    is_ipv6 "::"
assert_false "is_ipv6: ipv4"            is_ipv6 "192.168.1.1"
assert_false "is_ipv6: plain text"      is_ipv6 "example.com"
assert_false "is_ipv6: empty"           is_ipv6 ""

# -----------------------------------------------------------------------
# has_nonempty_ssl_pair
# -----------------------------------------------------------------------
CERT="$WORK_DIR/cert.pem"
KEY="$WORK_DIR/key.pem"

# Both files empty
: > "$CERT"; : > "$KEY"
assert_false "has_nonempty_ssl_pair: both empty" has_nonempty_ssl_pair "$CERT" "$KEY"

# Cert non-empty, key empty
echo "CERT" > "$CERT"; : > "$KEY"
assert_false "has_nonempty_ssl_pair: key empty" has_nonempty_ssl_pair "$CERT" "$KEY"

# Key non-empty, cert empty
: > "$CERT"; echo "KEY" > "$KEY"
assert_false "has_nonempty_ssl_pair: cert empty" has_nonempty_ssl_pair "$CERT" "$KEY"

# Both non-empty
echo "CERT" > "$CERT"; echo "KEY" > "$KEY"
assert_true  "has_nonempty_ssl_pair: both present" has_nonempty_ssl_pair "$CERT" "$KEY"

# Missing files
assert_false "has_nonempty_ssl_pair: cert missing" has_nonempty_ssl_pair "/no/cert.pem" "$KEY"
assert_false "has_nonempty_ssl_pair: key missing"  has_nonempty_ssl_pair "$CERT" "/no/key.pem"

# -----------------------------------------------------------------------
# get_backup_proxy_url
# -----------------------------------------------------------------------
unset BACKUP_PROXY_URL BACKUP_PROXY BACKUP_PROXY_ENABLED 2>/dev/null || true
assert_false "get_backup_proxy_url: no vars set" get_backup_proxy_url

export BACKUP_PROXY_URL="http://proxy.example.com:8080"
result=$(get_backup_proxy_url)
if [ "$result" = "http://proxy.example.com:8080" ]; then
    pass "get_backup_proxy_url: returns BACKUP_PROXY_URL"
else
    fail "get_backup_proxy_url: returns BACKUP_PROXY_URL (got='$result')"
fi

export BACKUP_PROXY_ENABLED="false"
assert_false "get_backup_proxy_url: BACKUP_PROXY_ENABLED=false suppresses" get_backup_proxy_url

export BACKUP_PROXY_ENABLED="true"
assert_true  "get_backup_proxy_url: BACKUP_PROXY_ENABLED=true allows" get_backup_proxy_url

unset BACKUP_PROXY_URL
export BACKUP_PROXY="socks5://127.0.0.1:1080"
unset BACKUP_PROXY_ENABLED
result2=$(get_backup_proxy_url)
if [ "$result2" = "socks5://127.0.0.1:1080" ]; then
    pass "get_backup_proxy_url: falls back to BACKUP_PROXY"
else
    fail "get_backup_proxy_url: falls back to BACKUP_PROXY (got='$result2')"
fi

# -----------------------------------------------------------------------
# backup_interval_hours_from_cron
# -----------------------------------------------------------------------
assert_eq "$(backup_interval_hours_from_cron "0 0 * * *")" "24" \
    "backup_interval_hours_from_cron: daily schedule -> 24"
assert_eq "$(backup_interval_hours_from_cron "0 */6 * * *")" "6" \
    "backup_interval_hours_from_cron: every 6 hours"
assert_eq "$(backup_interval_hours_from_cron "0 */23 * * *")" "23" \
    "backup_interval_hours_from_cron: every 23 hours"
assert_eq "$(backup_interval_hours_from_cron "15 */6 * * *")" "" \
    "backup_interval_hours_from_cron: unsupported schedule -> empty"

# -----------------------------------------------------------------------
# get_acme_sh_binary
# -----------------------------------------------------------------------
MOCK_HOME="$WORK_DIR/mock_home"
mkdir -p "$MOCK_HOME/.acme.sh"
touch "$MOCK_HOME/.acme.sh/acme.sh"
chmod +x "$MOCK_HOME/.acme.sh/acme.sh"

# Mock HOME for this test
ORIG_HOME="$HOME"
export HOME="$MOCK_HOME"

assert_eq "$(get_acme_sh_binary)" "$MOCK_HOME/.acme.sh/acme.sh" \
    "get_acme_sh_binary: finds acme.sh in HOME/.acme.sh"

rm -rf "$MOCK_HOME/.acme.sh"
# Should check /root/.acme.sh (but we can't easily mock that if not root)
# Let's mock 'command -v acme.sh'
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "acme.sh" ]]; then
        echo "/usr/bin/acme.sh"
        return 0
    fi
    builtin command "$@"
}
export -f command
assert_eq "$(get_acme_sh_binary)" "/usr/bin/acme.sh" \
    "get_acme_sh_binary: finds acme.sh in PATH"
unset -f command

export HOME="$ORIG_HOME"

# -----------------------------------------------------------------------
# compose_service_exists & detect_pasarguard_backend_service
# -----------------------------------------------------------------------
# Mock COMPOSE to return specific services
COMPOSE_MOCK_FILE="$WORK_DIR/compose_mock.sh"
cat > "$COMPOSE_MOCK_FILE" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--services"* ]]; then
    echo "panel"
    echo "postgres"
    echo "redis"
elif [[ "$*" == *"config"* ]]; then
    cat <<'EOM'
services:
  panel:
    image: pasarguard/panel
    labels:
      ROLE: backend
  postgres:
    image: postgres
EOM
fi
EOF
chmod +x "$COMPOSE_MOCK_FILE"
COMPOSE="$COMPOSE_MOCK_FILE"

assert_true  "compose_service_exists: panel exists"  compose_service_exists "panel"
assert_false "compose_service_exists: missing service" compose_service_exists "missing"

assert_eq "$(detect_pasarguard_backend_service)" "panel" \
    "detect_pasarguard_backend_service: identifies panel as backend"

# Test fallback logic in detect_pasarguard_backend_service
cat > "$COMPOSE_MOCK_FILE" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--services"* ]]; then
    echo "pasarguard"
elif [[ "$*" == *"config"* ]]; then
    echo "services: { pasarguard: { labels: { ROLE: backend } } }"
fi
EOF
assert_eq "$(detect_pasarguard_backend_service)" "pasarguard" \
    "detect_pasarguard_backend_service: identifies pasarguard as fallback"

# -----------------------------------------------------------------------
# is_port_in_use
# -----------------------------------------------------------------------
# Mock port monitoring commands
ss() {
    if [[ "${1:-}" == "-ltn" ]]; then
        echo "LISTEN 0 128 *:55555 *:* "
        echo "LISTEN 0 128 *:443 *:* "
        return 0
    fi
    return 1
}
netstat() {
    if [[ "${1:-}" == "-lnt" ]]; then
        echo "tcp 0 0 0.0.0.0:55555 0.0.0.0:* LISTEN"
        echo "tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN"
        return 0
    fi
    return 1
}
export -f ss netstat
assert_true  "is_port_in_use: detects port 55555" is_port_in_use 55555
assert_false "is_port_in_use: port 9000 free"  is_port_in_use 9000
unset -f ss netstat

# -----------------------------------------------------------------------
# build_pasarguard_ssl_reload_command
# -----------------------------------------------------------------------
# With panel detected
cat > "$COMPOSE_MOCK_FILE" <<'EOF'
#!/usr/bin/env bash
echo "panel"
EOF
cmd=$(build_pasarguard_ssl_reload_command)
if [[ "$cmd" == *"restart panel"* ]]; then
    pass "build_pasarguard_ssl_reload_command: restarts specific service"
else
    fail "build_pasarguard_ssl_reload_command: restarts specific service (got: $cmd)"
fi

# With no service detected
cat > "$COMPOSE_MOCK_FILE" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cmd2=$(build_pasarguard_ssl_reload_command)
if [[ "$cmd2" == *"restart"* && ! "$cmd2" == *"restart panel"* ]]; then
    pass "build_pasarguard_ssl_reload_command: restarts entire stack as fallback"
else
    fail "build_pasarguard_ssl_reload_command: restarts entire stack as fallback"
fi

# -----------------------------------------------------------------------
# is_pasarguard_installed  (APP_DIR is a temp dir we created)
# -----------------------------------------------------------------------
assert_true  "is_pasarguard_installed: APP_DIR exists"    is_pasarguard_installed
rm -rf "$APP_DIR"
assert_false "is_pasarguard_installed: APP_DIR removed"   is_pasarguard_installed
mkdir -p "$APP_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
