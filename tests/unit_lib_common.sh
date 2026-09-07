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

# --- SQLite SQLAlchemy URL helpers ---
assert_eq "$(sqlite_database_path_from_url 'sqlite:///db.sqlite3')" "db.sqlite3" \
    "sqlite_database_path_from_url: relative path"
assert_eq "$(sqlite_database_path_from_url 'sqlite+aiosqlite:////var/lib/pasarguard/db.sqlite3')" \
    "/var/lib/pasarguard/db.sqlite3" "sqlite_database_path_from_url: absolute path"
assert_eq "$(sqlite_database_path_from_url 'sqlite+aiosqlite://///var/lib/pasarguard/db.sqlite3')" \
    "/var/lib/pasarguard/db.sqlite3" "sqlite_database_path_from_url: legacy five-slash path"
assert_eq "$(sqlite_database_path_from_url 'sqlite:////var/lib/pasarguard/db.sqlite3?mode=ro#fragment')" \
    "/var/lib/pasarguard/db.sqlite3" "sqlite_database_path_from_url: strips query and fragment"
assert_eq "$(sqlite_absolute_database_url 'sqlite+aiosqlite' '/var/lib/pasarguard/db.sqlite3')" \
    "sqlite+aiosqlite:////var/lib/pasarguard/db.sqlite3" "sqlite_absolute_database_url: exactly four slashes"

# --- get_script_commit_sha & print_script_execution_header ---
assert_eq "$(get_script_commit_sha "$WORK_DIR" "a23123f03978989e95d257beb9de0c5ad9da6e70")" \
    "a23123f03978989e95d257beb9de0c5ad9da6e70" "get_script_commit_sha: returns baked-in SHA"

(
    export PASARGUARD_SCRIPT_COMMIT="custom_env_commit_sha"
    assert_eq "$(get_script_commit_sha "$WORK_DIR" "__SCRIPT_COMMIT_SHA__")" \
        "custom_env_commit_sha" "get_script_commit_sha: respects PASARGUARD_SCRIPT_COMMIT override"
)

(
    export SCRIPT_COMMIT_SHA="custom_script_sha"
    assert_eq "$(get_script_commit_sha "$WORK_DIR" "__SCRIPT_COMMIT_SHA__")" \
        "custom_script_sha" "get_script_commit_sha: respects SCRIPT_COMMIT_SHA override"
)

git_expected=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo "main")
assert_eq "$(get_script_commit_sha "$ROOT_DIR" "__SCRIPT_COMMIT_SHA__")" \
    "$git_expected" "get_script_commit_sha: resolves commit from git repo"

no_git_dir="$WORK_DIR/no_git_dir"
mkdir -p "$no_git_dir"
(
    export PASARGUARD_SKIP_REMOTE_COMMIT_LOOKUP=1
    assert_eq "$(get_script_commit_sha "$no_git_dir" "__SCRIPT_COMMIT_SHA__")" \
        "main" "get_script_commit_sha: falls back to 'main' outside git repo when remote lookup is unavailable"
)

# When no git checkout is present (e.g. `curl | bash` installs), the real
# commit SHA is resolved from GitHub instead of printing the literal branch name.
(
    stub_bin_dir="$WORK_DIR/stub_bin"
    mkdir -p "$stub_bin_dir"
    cat >"$stub_bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"sha":"deadbeef1234567890deadbeef1234567890dead","commit":{"tree":{"sha":"other"}}}'
EOF
    chmod +x "$stub_bin_dir/curl"
    export PATH="$stub_bin_dir:$PATH"
    assert_eq "$(get_script_commit_sha "$no_git_dir" "__SCRIPT_COMMIT_SHA__")" \
        "deadbeef1234567890deadbeef1234567890dead" \
        "get_script_commit_sha: resolves real commit SHA from GitHub when no git checkout is available"
)

assert_eq "$(print_script_execution_header "pasarguard" "test_commit_sha" "install")" \
    "# Executing pasarguard install script, commit: test_commit_sha" \
    "print_script_execution_header: formats install banner correctly"

assert_eq "$(print_script_execution_header "pg-node" "test_commit_sha")" \
    "# Executing pg-node script, commit: test_commit_sha" \
    "print_script_execution_header: formats general script banner correctly"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
