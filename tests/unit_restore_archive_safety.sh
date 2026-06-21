#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# pasarguard-restore.sh is a library of function definitions; sourcing it does
# not execute anything.
# shellcheck source=lib/pasarguard-restore.sh
source "$ROOT_DIR/lib/pasarguard-restore.sh"

PASS=0
FAIL=0
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
assert_true()  { local l="$1"; shift; if "$@"; then pass "$l"; else fail "$l"; fi; }
assert_false() { local l="$1"; shift; if ! "$@"; then pass "$l"; else fail "$l"; fi; }

echo "=== unit_restore_archive_safety.sh ==="

cd "$WORK_DIR"
mkdir -p src/sub
echo "hello" > src/file.txt
echo "deep"  > src/sub/deep.txt

# --- tar fixtures (tar is always available) ---
tar -czf safe.tgz -C src .
echo payload > escape.txt
tar -P -czf abs.tgz "$WORK_DIR/escape.txt" 2>/dev/null          # absolute member
mkdir -p stage && echo p > stage/payload
tar -P -czf dotdot.tgz -C stage ../stage/payload 2>/dev/null    # ../ member

assert_true  "archive_entries_are_safe: clean tar accepted"      archive_entries_are_safe safe.tgz tar
assert_false "archive_entries_are_safe: absolute-path tar rejected" archive_entries_are_safe abs.tgz tar
assert_false "archive_entries_are_safe: ../ tar rejected"        archive_entries_are_safe dotdot.tgz tar

# --- zip fixtures (guarded on tooling) ---
if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    (cd src && zip -qr "$WORK_DIR/safe.zip" .)
    echo evil > payload
    zip -q evil.zip payload
    if command -v zipnote >/dev/null 2>&1; then
        printf '@ payload\n@=../escape\n' | zipnote -w evil.zip >/dev/null 2>&1
        assert_false "archive_entries_are_safe: ../ zip rejected" archive_entries_are_safe evil.zip zip
    else
        echo "(skipped ../ zip case: zipnote unavailable)"
    fi
    assert_true "archive_entries_are_safe: clean zip accepted" archive_entries_are_safe safe.zip zip
else
    echo "(skipped zip cases: zip/unzip unavailable)"
fi

# Unknown kind and unreadable archive are treated as unsafe.
assert_false "archive_entries_are_safe: unknown kind rejected" archive_entries_are_safe safe.tgz bogus
assert_false "archive_entries_are_safe: missing archive rejected" archive_entries_are_safe /no/such.tgz tar

# -----------------------------------------------------------------------
# postgres_dump_looks_restorable
# Gate the destructive DROP DATABASE (TimescaleDB restore) on the dump
# actually looking like a pg_dump, not just being non-empty.
# -----------------------------------------------------------------------
good_dump="$WORK_DIR/good.sql"
cat > "$good_dump" <<'EOF'
--
-- PostgreSQL database dump
--
SET statement_timeout = 0;
CREATE TABLE public.users (id integer NOT NULL);
COPY public.users (id) FROM stdin;
1
\.
EOF
assert_true "postgres_dump_looks_restorable: real dump accepted" postgres_dump_looks_restorable "$good_dump"

empty_dump="$WORK_DIR/empty.sql"; : > "$empty_dump"
assert_false "postgres_dump_looks_restorable: empty file rejected" postgres_dump_looks_restorable "$empty_dump"

html_dump="$WORK_DIR/html.sql"; printf '404: Not Found\n' > "$html_dump"
assert_false "postgres_dump_looks_restorable: HTTP error body rejected" postgres_dump_looks_restorable "$html_dump"

comments_only="$WORK_DIR/comments.sql"
printf -- '-- only comments\nSET statement_timeout = 0;\n' > "$comments_only"
assert_false "postgres_dump_looks_restorable: no DDL/data rejected" postgres_dump_looks_restorable "$comments_only"

assert_false "postgres_dump_looks_restorable: missing file rejected" postgres_dump_looks_restorable "$WORK_DIR/nope.sql"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
