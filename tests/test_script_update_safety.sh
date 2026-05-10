#!/usr/bin/env bash
set -euo pipefail

# This test verifies the script update backup and restore logic.
# It mocks the environment and GitHub functions to simulate failures.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Mocking the environment
MOCK_ROOT="$(mktemp -d)"
trap 'rm -rf "$MOCK_ROOT"' EXIT

MOCK_BIN="$MOCK_ROOT/bin"
MOCK_LIB="$MOCK_ROOT/lib"
MOCK_TMP="$MOCK_ROOT/tmp"
mkdir -p "$MOCK_BIN" "$MOCK_LIB" "$MOCK_TMP"

# Override paths for testing to avoid permission issues
export APP_TMP_DIR="$MOCK_TMP"
export DATA_DIR="$MOCK_ROOT/data"
mkdir -p "$DATA_DIR"
export SHARED_LIB_INSTALL_DIR="$MOCK_LIB"

# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/github.sh
source "$ROOT_DIR/lib/github.sh"

# Mock backup_scripts to use MOCK_BIN
backup_scripts() {
    local backup_dir=""
    backup_dir=$(create_temp_dir "scripts-backup")

    # Backup main scripts
    [ -f "$MOCK_BIN/pasarguard" ] && cp "$MOCK_BIN/pasarguard" "$backup_dir/"
    [ -f "$MOCK_BIN/pg-node" ] && cp "$MOCK_BIN/pg-node" "$backup_dir/"

    # Backup shared libraries
    if [ -d "$SHARED_LIB_INSTALL_DIR" ]; then
        mkdir -p "$backup_dir/lib"
        if [ "$(ls -A "$SHARED_LIB_INSTALL_DIR")" ]; then
            cp -r "$SHARED_LIB_INSTALL_DIR/"* "$backup_dir/lib/"
        fi
    fi

    printf '%s\n' "$backup_dir"
}

# Mock restore_scripts to use MOCK_BIN
restore_scripts() {
    local backup_dir="$1"
    [ -z "$backup_dir" ] && return 1

    # Restore main scripts
    [ -f "$backup_dir/pasarguard" ] && install -m 755 "$backup_dir/pasarguard" "$MOCK_BIN/pasarguard"
    [ -f "$backup_dir/pg-node" ] && install -m 755 "$backup_dir/pg-node" "$MOCK_BIN/pg-node"

    # Restore shared libraries
    if [ -d "$backup_dir/lib" ]; then
        mkdir -p "$SHARED_LIB_INSTALL_DIR"
        if [ "$(ls -A "$backup_dir/lib")" ]; then
            install -m 644 "$backup_dir/lib/"* "$SHARED_LIB_INSTALL_DIR/"
        fi
    fi
}

# Create initial state
echo "original-pasarguard" > "$MOCK_BIN/pasarguard"
chmod 755 "$MOCK_BIN/pasarguard"
echo "original-lib" > "$MOCK_LIB/common.sh"
chmod 644 "$MOCK_LIB/common.sh"

echo "Running Test 1: Successful update simulation..."
# Mock github functions to succeed
github_download_file() { echo "new-lib-content" > "$2"; }
github_install_script_from_repo() { echo "new-script-content" > "$MOCK_BIN/$3"; chmod 755 "$MOCK_BIN/$3"; }

backup_dir=$(backup_scripts)
install_shared_libs_from_repo "repo" "common.sh"
github_install_script_from_repo "repo" "pasarguard.sh" "pasarguard"
cleanup_backup "$backup_dir"

if grep -q "new-script-content" "$MOCK_BIN/pasarguard" && grep -q "new-lib-content" "$MOCK_LIB/common.sh"; then
    echo "✓ Test 1 passed: Update successful."
else
    echo "✗ Test 1 failed: Update content incorrect."
    exit 1
fi

echo "Running Test 2: Failed update simulation (shared lib failure)..."
# Reset to "current" state
echo "current-pasarguard" > "$MOCK_BIN/pasarguard"
echo "current-lib" > "$MOCK_LIB/common.sh"

# Mock failure in download
github_download_file() { return 1; }

backup_dir=$(backup_scripts)
if ! install_shared_libs_from_repo "repo" "common.sh"; then
    echo "Caught expected failure in shared libs update. Restoring..."
    restore_scripts "$backup_dir"
    cleanup_backup "$backup_dir"
fi

if grep -q "current-pasarguard" "$MOCK_BIN/pasarguard" && grep -q "current-lib" "$MOCK_LIB/common.sh"; then
    echo "✓ Test 2 passed: Restoration successful after shared lib failure."
else
    echo "✗ Test 2 failed: Restoration failed."
    exit 1
fi

echo "Running Test 3: Failed update simulation (script installation failure)..."
# Reset
echo "current-pasarguard" > "$MOCK_BIN/pasarguard"
echo "current-lib" > "$MOCK_LIB/common.sh"

# Mock success for libs, failure for script
github_download_file() { echo "new-lib-content" > "$2"; }
github_install_script_from_repo() { return 1; }

backup_dir=$(backup_scripts)
if install_shared_libs_from_repo "repo" "common.sh"; then
    if ! github_install_script_from_repo "repo" "pasarguard.sh" "pasarguard"; then
        echo "Caught expected failure in script update. Restoring..."
        restore_scripts "$backup_dir"
        cleanup_backup "$backup_dir"
    fi
fi

if grep -q "current-pasarguard" "$MOCK_BIN/pasarguard" && grep -q "current-lib" "$MOCK_LIB/common.sh"; then
    echo "✓ Test 3 passed: Restoration successful after script failure (libs also reverted)."
else
    echo "✗ Test 3 failed: Restoration failed."
    exit 1
fi

echo "All tests passed successfully!"
