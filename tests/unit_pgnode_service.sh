#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Source only the function definitions; skip the server/env-validation body.
export PG_NODE_SERVICE_SOURCE_ONLY="true"
# shellcheck source=pg-node-service.sh
source "$ROOT_DIR/pg-node-service.sh"

PASS=0
FAIL=0
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_pgnode_service.sh ==="

# describe_certificate must map each check_certificate status to the right
# message. The original code read $? inside `if ...; then`, where it is always
# 0, so the self-signed (2) and invalid (1) branches were dead.

check_certificate() { return 0; }   # CA-signed
out=$(describe_certificate "/tmp/cert.pem" 2>&1)
if echo "$out" | grep -q "CA-signed"; then pass "describe_certificate: status 0 -> CA-signed"; else fail "describe_certificate: status 0 -> CA-signed (got: $out)"; fi

check_certificate() { return 2; }   # self-signed
out=$(describe_certificate "/tmp/cert.pem" 2>&1)
if echo "$out" | grep -q "self-signed"; then pass "describe_certificate: status 2 -> self-signed"; else fail "describe_certificate: status 2 -> self-signed (got: $out)"; fi

check_certificate() { return 1; }   # invalid
out=$(describe_certificate "/tmp/cert.pem" 2>&1)
if echo "$out" | grep -q "validation failed"; then pass "describe_certificate: status 1 -> validation failed"; else fail "describe_certificate: status 1 -> validation failed (got: $out)"; fi

# describe_certificate must not abort the caller under set -e when the cert is
# self-signed/invalid (non-zero check_certificate).
check_certificate() { return 2; }
if ( set -e; describe_certificate "/tmp/cert.pem" >/dev/null 2>&1; echo ok ) | grep -q ok; then
    pass "describe_certificate: survives set -e on non-zero status"
else
    fail "describe_certificate: survives set -e on non-zero status"
fi

# tls_verify_level: client-cert verification on only for CA-signed certs.
check_certificate() { return 0; }
assert_eq "$(tls_verify_level /tmp/cert.pem)" "verify=1" "tls_verify_level: CA-signed -> verify=1"
check_certificate() { return 2; }
assert_eq "$(tls_verify_level /tmp/cert.pem)" "verify=0" "tls_verify_level: self-signed -> verify=0"
check_certificate() { return 1; }
assert_eq "$(tls_verify_level /tmp/cert.pem)" "verify=0" "tls_verify_level: invalid -> verify=0"

# byte_length must count bytes (for Content-Length), not characters: a
# multibyte UTF-8 body otherwise advertises a too-small length and truncates.
assert_eq "$(byte_length "hello")" "5" "byte_length: ASCII counts bytes"
assert_eq "$(byte_length "")" "0" "byte_length: empty is 0"
# 'é' is 2 bytes in UTF-8, so "café" is 5 bytes though ${#} reports 4 chars.
assert_eq "$(byte_length "café")" "5" "byte_length: multibyte UTF-8 counts bytes"
# A JSON body with an embedded multibyte error message.
multibyte_body='{"detail":"versión inválida"}'
assert_eq "$(byte_length "$multibyte_body")" "$(printf '%s' "$multibyte_body" | wc -c | tr -d '[:space:]')" "byte_length: matches wc -c"

# Startup certificate validation behavior: fail-closed by default, allow override.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
tmp_cert="$tmp_dir/invalid_cert.pem"
tmp_key="$tmp_dir/key.pem"
echo "not a valid pem" > "$tmp_cert"
touch "$tmp_key"
mock_bin="$tmp_dir/bin"
mkdir -p "$mock_bin"
cat << 'EOF' > "$mock_bin/socat"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$mock_bin/socat"

# 1. Invalid certificate without ALLOW_INSECURE_TLS must fail closed.
status_fail=0
out_fail=$(PG_NODE_SERVICE_SOURCE_ONLY="false" ENV_FILE=/dev/null API_KEY="test" SSL_CERT_FILE="$tmp_cert" SSL_KEY_FILE="$tmp_key" PATH="$mock_bin:$PATH" bash "$ROOT_DIR/pg-node-service.sh" 2>&1) || status_fail=$?
if [ "$status_fail" -ne 0 ] && echo "$out_fail" | grep -q "Refusing to start"; then
    pass "startup: invalid certificate fails closed by default"
else
    fail "startup: invalid certificate fails closed by default (status=$status_fail, out=$out_fail)"
fi

# 2. Invalid certificate with ALLOW_INSECURE_TLS=true must proceed.
status_override=0
out_override=$(PG_NODE_SERVICE_SOURCE_ONLY="false" ENV_FILE=/dev/null API_KEY="test" SSL_CERT_FILE="$tmp_cert" SSL_KEY_FILE="$tmp_key" ALLOW_INSECURE_TLS=true PATH="$mock_bin:$PATH" bash "$ROOT_DIR/pg-node-service.sh" 2>&1) || status_override=$?
if [ "$status_override" -eq 0 ] && echo "$out_override" | grep -q "ALLOW_INSECURE_TLS=true is set"; then
    pass "startup: ALLOW_INSECURE_TLS=true allows startup with invalid certificate"
else
    fail "startup: ALLOW_INSECURE_TLS=true allows startup with invalid certificate (status=$status_override, out=$out_override)"
fi

rm -rf "$tmp_dir"
trap - EXIT

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
