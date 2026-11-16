#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

# Postgres puts parallel query and parallel VACUUM shared memory in /dev/shm.
# Docker's default is 64 MB, which fails under concurrent usage charts.
check_shm_size() {
    local file="$1" service="$2" value
    # Read the key inside the service block (2-space service names, 4-space keys).
    value=$(awk -v svc="  ${service}:" '
        $0 == svc { in_svc = 1; next }
        in_svc && /^  [^ ]/ { in_svc = 0 }
        in_svc && $1 == "shm_size:" { print $2; exit }
    ' "$ROOT_DIR/docker-compose/$file")
    if [ "$value" = '${PG_SHM_SIZE:-1gb}' ]; then
        echo "✓ $file: $service sets shm_size (default 1gb)"; PASS=$((PASS + 1))
    else
        echo "✗ $file: $service shm_size is '${value}', expected \${PG_SHM_SIZE:-1gb}"; FAIL=$((FAIL + 1))
    fi
}

check_shm_size pasarguard-postgresql.yml postgresql
check_shm_size pasarguard-timescaledb.yml timescaledb

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
