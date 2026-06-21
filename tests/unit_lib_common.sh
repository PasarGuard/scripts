#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$APP_TMP_DIR"

source "$ROOT_DIR/lib/common.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

echo "=== unit_lib_common.sh ==="

# --- colorized_echo ---
out=$(colorized_echo green "hello")
if echo "$out" | grep -q "hello"; then pass "colorized_echo: contains text"; else fail "colorized_echo: contains text"; fi

# --- create_temp_dir ---
d=$(create_temp_dir "myprefix")
if [ -d "$d" ]; then pass "create_temp_dir: directory exists"; else fail "create_temp_dir: directory exists"; fi
if [[ "$d" == *"myprefix"* ]]; then pass "create_temp_dir: prefix in name"; else fail "create_temp_dir: prefix in name"; fi
rm -rf "$d"

d2=$(create_temp_dir)
if [ -d "$d2" ]; then pass "create_temp_dir: default prefix works"; else fail "create_temp_dir: default prefix works"; fi
rm -rf "$d2"

# --- create_temp_file ---
f=$(create_temp_file "mypfx" ".sh")
if [ -f "$f" ]; then pass "create_temp_file: file exists"; else fail "create_temp_file: file exists"; fi
if [[ "$f" == *"mypfx"* ]]; then pass "create_temp_file: prefix in name"; else fail "create_temp_file: prefix in name"; fi
if [[ "$f" == *".sh" ]]; then pass "create_temp_file: suffix in name"; else fail "create_temp_file: suffix in name"; fi
rm -f "$f"

f2=$(create_temp_file)
if [ -f "$f2" ]; then pass "create_temp_file: default args work"; else fail "create_temp_file: default args work"; fi
rm -f "$f2"

# --- create_temp_file_in_dir ---
subdir="$WORK_DIR/subdir"
mkdir -p "$subdir"
f3=$(create_temp_file_in_dir "$subdir" "sub" ".txt")
if [ -f "$f3" ]; then pass "create_temp_file_in_dir: file exists"; else fail "create_temp_file_in_dir: file exists"; fi
if [[ "$f3" == "$subdir"* ]]; then pass "create_temp_file_in_dir: file in correct dir"; else fail "create_temp_file_in_dir: file in correct dir"; fi
rm -f "$f3"

# --- temp_root_dir uses APP_TMP_DIR ---
troot=$(temp_root_dir)
assert_eq "$troot" "$APP_TMP_DIR" "temp_root_dir: returns APP_TMP_DIR when set"

# --- harden_secret_file ---
# Tightens an existing world-readable file to 0600.
secret_existing="$WORK_DIR/existing.env"
: >"$secret_existing"
chmod 644 "$secret_existing"
harden_secret_file "$secret_existing"
assert_eq "$(stat -c '%a' "$secret_existing")" "600" "harden_secret_file: tightens existing file to 600"

# Creates the file 0600 when it does not yet exist (so caller can write into it).
secret_new="$WORK_DIR/new.env"
harden_secret_file "$secret_new"
if [ -f "$secret_new" ]; then pass "harden_secret_file: creates missing file"; else fail "harden_secret_file: creates missing file"; fi
assert_eq "$(stat -c '%a' "$secret_new")" "600" "harden_secret_file: creates missing file as 600"

# Content written after hardening keeps 0600 (truncate-in-place preserves perms).
printf 'SECRET=value\n' >>"$secret_new"
assert_eq "$(stat -c '%a' "$secret_new")" "600" "harden_secret_file: appended content stays 600"

# Empty path is rejected without creating anything.
if harden_secret_file ""; then fail "harden_secret_file: rejects empty path"; else pass "harden_secret_file: rejects empty path"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
