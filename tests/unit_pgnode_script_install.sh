#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export ROOT_DIR WORK_DIR
export APP_TMP_DIR="$WORK_DIR/tmp" APP_DIR="$WORK_DIR/app" DATA_DIR="$WORK_DIR/data"
export PG_NODE_SOURCE_ONLY=true PG_NODE_SCRIPT_DIR="$ROOT_DIR"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR" "$WORK_DIR/bin"
# Block source-time IP detection and any accidental network requests.
curl() { :; }
export -f curl

cat >"$WORK_DIR/install-harness.sh" <<'HARNESS'
colorized_echo() { :; }
print_script_execution_header() { :; }
github_download_file() { echo 'Unexpected script download' >&2; return 1; }
install_shared_libs_from_repo() { :; }
# Redirect the production install destination without touching system files.
mv() {
    [ "$2" = "/usr/local/bin/$APP_NAME" ]
    TARGET_PATH="$WORK_DIR/bin/$APP_NAME"
    command mv "$1" "$TARGET_PATH"
}
rm() {
    local arg
    for arg in "$@"; do
        case "$arg" in /usr/*) echo 'Unexpected system file removal' >&2; return 1;; esac
    done
    command rm "$@"
}
APP_NAME="pg-node-install-regression"
install_node_script
sed "s|^APP_NAME=.*|APP_NAME=\"$APP_NAME\"|" "$EXPECTED_SCRIPT" >"$WORK_DIR/expected.sh"
cmp "$WORK_DIR/expected.sh" "$TARGET_PATH"
[ -x "$TARGET_PATH" ]
# The installed copy must retain the ACME deployment handler.
grep -q -- '--deploy-acme' "$TARGET_PATH"
HARNESS

# File/checkout invocation must preserve the running version.
export EXPECTED_SCRIPT="$ROOT_DIR/pg-node.sh"
bash -c 'source "$ROOT_DIR/pg-node.sh"; source "$WORK_DIR/install-harness.sh"'

# Reproduce bash -c "$(curl ...)": the script has no backing source file.
cat "$ROOT_DIR/pg-node.sh" >"$WORK_DIR/inline.sh"
printf '\nsource "$WORK_DIR/install-harness.sh"\n' >>"$WORK_DIR/inline.sh"
export EXPECTED_SCRIPT="$WORK_DIR/inline.sh"
bash -c "$(cat "$WORK_DIR/inline.sh")" @ install-script

echo 'Node script installation tests passed'
