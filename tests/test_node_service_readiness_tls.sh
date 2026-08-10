#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
    [ -z "$SERVER_PID" ] || wait "$SERVER_PID" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="readiness-tls-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

curl() { printf '\n'; }
export -f curl
export PG_NODE_SOURCE_ONLY=true
# shellcheck source=pg-node.sh
source "$ROOT_DIR/pg-node.sh"
unset -f curl

CERT_FILE="$WORK_DIR/dns-only-cert.pem"
KEY_FILE="$WORK_DIR/dns-only-key.pem"
ENV_FILE="$WORK_DIR/service.env"
SERVICE_NAME="readiness-tls-test-service"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=node.example.test' \
    -addext 'subjectAltName=DNS:node.example.test' \
    -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1
printf 'API_PORT= %s\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$PORT" "$CERT_FILE" > "$ENV_FILE"

openssl s_server -accept "127.0.0.1:$PORT" -cert "$CERT_FILE" -key "$KEY_FILE" -www \
    >"$WORK_DIR/server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..100}; do
    if (exec 7<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        exec 7>&-
        break
    fi
    sleep 0.02
done

set +e
curl --silent --show-error --fail --noproxy '*' --cacert "$CERT_FILE" \
    "https://127.0.0.1:$PORT/" >/dev/null 2>&1
baseline_status=$?
set -e
if [ "$baseline_status" -eq 60 ]; then
    printf '✓ baseline: DNS-only certificate rejects https://127.0.0.1 with rc60\n'
else
    printf '✗ baseline: expected curl rc60, got %s\n' "$baseline_status"
    exit 1
fi

if node_service_api_ready; then
    printf '✓ readiness: DNS SAN keeps Host/SNI while TCP connects to loopback without DNS\n'
else
    printf '✗ readiness: DNS-only certificate probe failed\n'
    exit 1
fi

kill "$SERVER_PID" >/dev/null 2>&1 || true
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=""
CERT_FILE="$WORK_DIR/wildcard-cert.pem"
KEY_FILE="$WORK_DIR/wildcard-key.pem"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=*.example.test' \
    -addext 'subjectAltName=DNS:*.example.test' \
    -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1
printf 'API_PORT= %s\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$PORT" "$CERT_FILE" > "$ENV_FILE"
openssl s_server -accept "127.0.0.1:$PORT" -cert "$CERT_FILE" -key "$KEY_FILE" -www \
    >"$WORK_DIR/wildcard-server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..100}; do
    if (exec 7<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        exec 7>&-
        break
    fi
    sleep 0.02
done
if node_service_api_ready; then
    printf '✓ readiness: wildcard DNS SAN uses a covered synthetic host over loopback\n'
else
    printf '✗ readiness: wildcard DNS SAN probe failed\n'
    exit 1
fi

kill "$SERVER_PID" >/dev/null 2>&1 || true
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=""
CERT_FILE="$WORK_DIR/cn-only-cert.pem"
KEY_FILE="$WORK_DIR/cn-only-key.pem"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config /dev/null \
    -subj '/CN=legacy.example.test' \
    -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1
if openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | grep -q 'Subject Alternative Name'; then
    printf '✗ setup: CN-only certificate unexpectedly carries a SAN\n'
    exit 1
fi
printf 'API_PORT= %s\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$PORT" "$CERT_FILE" > "$ENV_FILE"
openssl s_server -accept "127.0.0.1:$PORT" -cert "$CERT_FILE" -key "$KEY_FILE" -www \
    >"$WORK_DIR/cn-only-server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..100}; do
    if (exec 7<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        exec 7>&-
        break
    fi
    sleep 0.02
done
if node_service_api_ready; then
    printf '✓ readiness: SAN-less legacy CN remains supported over loopback\n'
else
    printf '✗ readiness: SAN-less legacy CN probe failed\n'
    exit 1
fi

kill "$SERVER_PID" >/dev/null 2>&1 || true
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=""
CERT_FILE="$WORK_DIR/unusable-san-cert.pem"
KEY_FILE="$WORK_DIR/unusable-san-key.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=must-not-fallback.example.test' \
    -addext 'subjectAltName=email:health@example.test' \
    -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1
printf 'API_PORT= 3000\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$CERT_FILE" > "$ENV_FILE"
if node_service_api_ready >/dev/null 2>&1; then
    printf '✗ readiness: unusable SAN incorrectly fell back to CN\n'
    exit 1
else
    printf '✓ readiness: SAN without DNS/IP identity fails closed\n'
fi

CERT_FILE="$WORK_DIR/ipv6-san-cert.pem"
KEY_FILE="$WORK_DIR/ipv6-san-key.pem"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=unused.example.test' \
    -addext 'subjectAltName=IP:::1' \
    -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1
printf 'API_PORT= %s\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$PORT" "$CERT_FILE" > "$ENV_FILE"
# Deliberately bind IPv4 loopback only. A broken connect-to source match tries
# ::1 and fails; readiness succeeds only when curl is forced to 127.0.0.1 while
# TLS still verifies the IPv6 IP SAN from the URL identity.
openssl s_server -accept "127.0.0.1:$PORT" -cert "$CERT_FILE" -key "$KEY_FILE" -www \
    >"$WORK_DIR/ipv6-san-server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..100}; do
    if (exec 7<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        exec 7>&-
        break
    fi
    sleep 0.02
done
if node_service_api_ready; then
    printf '✓ readiness: IPv6 IP SAN keeps TLS identity while TCP connects to IPv4 loopback\n'
else
    printf '✗ readiness: IPv6 IP SAN probe was not forced to IPv4 loopback\n'
    exit 1
fi
