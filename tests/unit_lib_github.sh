#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export SHARED_LIB_INSTALL_DIR="$WORK_DIR/lib-install"
mkdir -p "$APP_TMP_DIR" "$SHARED_LIB_INSTALL_DIR"

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/github.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_lib_github.sh ==="

# -----------------------------------------------------------------------
# github_raw_url
# -----------------------------------------------------------------------
url=$(github_raw_url "PasarGuard/scripts" "lib/common.sh")
assert_eq "$url" "https://github.com/PasarGuard/scripts/raw/main/lib/common.sh" "github_raw_url: correct URL for lib file"

url2=$(github_raw_url "PasarGuard/scripts" "pasarguard.sh")
assert_eq "$url2" "https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh" "github_raw_url: correct URL for root file"

url3=$(github_raw_url "MyOrg/MyRepo" "some/deep/path.sh")
assert_eq "$url3" "https://github.com/MyOrg/MyRepo/raw/main/some/deep/path.sh" "github_raw_url: handles deep path"

# -----------------------------------------------------------------------
# backup_scripts / restore_scripts / cleanup_backup
# (override to use our mock paths)
# -----------------------------------------------------------------------
MOCK_BIN="$WORK_DIR/bin"
mkdir -p "$MOCK_BIN"

# Override the functions to use mock paths instead of /usr/local/bin
backup_scripts() {
    local backup_dir
    backup_dir=$(create_temp_dir "scripts-backup")
    [ -f "$MOCK_BIN/pasarguard" ] && cp "$MOCK_BIN/pasarguard" "$backup_dir/"
    [ -f "$MOCK_BIN/pg-node" ]    && cp "$MOCK_BIN/pg-node"    "$backup_dir/"
    if [ -d "$SHARED_LIB_INSTALL_DIR" ] && [ "$(ls -A "$SHARED_LIB_INSTALL_DIR" 2>/dev/null)" ]; then
        mkdir -p "$backup_dir/lib"
        cp -r "$SHARED_LIB_INSTALL_DIR/"* "$backup_dir/lib/"
    fi
    printf '%s\n' "$backup_dir"
}
restore_scripts() {
    local backup_dir="$1"
    [ -z "$backup_dir" ] && return 1
    [ -f "$backup_dir/pasarguard" ] && install -m 755 "$backup_dir/pasarguard" "$MOCK_BIN/pasarguard"
    [ -f "$backup_dir/pg-node" ]    && install -m 755 "$backup_dir/pg-node"    "$MOCK_BIN/pg-node"
    if [ -d "$backup_dir/lib" ] && [ "$(ls -A "$backup_dir/lib")" ]; then
        mkdir -p "$SHARED_LIB_INSTALL_DIR"
        install -m 644 "$backup_dir/lib/"* "$SHARED_LIB_INSTALL_DIR/"
    fi
}

# Seed mock state
echo "v1-pasarguard" > "$MOCK_BIN/pasarguard"; chmod 755 "$MOCK_BIN/pasarguard"
echo "v1-pg-node"    > "$MOCK_BIN/pg-node";    chmod 755 "$MOCK_BIN/pg-node"
echo "v1-common"     > "$SHARED_LIB_INSTALL_DIR/common.sh"; chmod 644 "$SHARED_LIB_INSTALL_DIR/common.sh"

# backup
bdir=$(backup_scripts)
if [ -f "$bdir/pasarguard" ] && grep -q "v1-pasarguard" "$bdir/pasarguard"; then
    pass "backup_scripts: pasarguard backed up"
else
    fail "backup_scripts: pasarguard backed up"
fi
if [ -f "$bdir/pg-node" ] && grep -q "v1-pg-node" "$bdir/pg-node"; then
    pass "backup_scripts: pg-node backed up"
else
    fail "backup_scripts: pg-node backed up"
fi
if [ -f "$bdir/lib/common.sh" ] && grep -q "v1-common" "$bdir/lib/common.sh"; then
    pass "backup_scripts: lib backed up"
else
    fail "backup_scripts: lib backed up"
fi

# Simulate an update (overwrite originals)
echo "v2-pasarguard" > "$MOCK_BIN/pasarguard"
echo "v2-common"     > "$SHARED_LIB_INSTALL_DIR/common.sh"

# restore
restore_scripts "$bdir"
if grep -q "v1-pasarguard" "$MOCK_BIN/pasarguard"; then
    pass "restore_scripts: pasarguard restored to v1"
else
    fail "restore_scripts: pasarguard restored to v1"
fi
if grep -q "v1-common" "$SHARED_LIB_INSTALL_DIR/common.sh"; then
    pass "restore_scripts: lib restored to v1"
else
    fail "restore_scripts: lib restored to v1"
fi

# cleanup_backup
cleanup_backup "$bdir"
if [ ! -d "$bdir" ]; then
    pass "cleanup_backup: backup dir removed"
else
    fail "cleanup_backup: backup dir removed"
fi

# cleanup_backup with empty string is a no-op
cleanup_backup ""
pass "cleanup_backup: empty string is safe"

# -----------------------------------------------------------------------
# install_shared_libs_from_local
# -----------------------------------------------------------------------
SRC_DIR="$WORK_DIR/src"
mkdir -p "$SRC_DIR/lib"
echo "local-common-content" > "$SRC_DIR/lib/common.sh"
echo "local-docker-content" > "$SRC_DIR/lib/docker.sh"

install_shared_libs_from_local "$SRC_DIR" "common.sh" "docker.sh"
if grep -q "local-common-content" "$SHARED_LIB_INSTALL_DIR/common.sh"; then
    pass "install_shared_libs_from_local: common.sh installed"
else
    fail "install_shared_libs_from_local: common.sh installed"
fi
if grep -q "local-docker-content" "$SHARED_LIB_INSTALL_DIR/docker.sh"; then
    pass "install_shared_libs_from_local: docker.sh installed"
else
    fail "install_shared_libs_from_local: docker.sh installed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
