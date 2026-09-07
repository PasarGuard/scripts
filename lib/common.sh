#!/usr/bin/env bash

colorized_echo() {
    local color="$1"
    local text="$2"
    local style="${3:-0}"

    case "$color" in
    red)
        printf "\e[${style};91m%s\e[0m\n" "$text"
        ;;
    green)
        printf "\e[${style};92m%s\e[0m\n" "$text"
        ;;
    yellow)
        printf "\e[${style};93m%s\e[0m\n" "$text"
        ;;
    blue)
        printf "\e[${style};94m%s\e[0m\n" "$text"
        ;;
    magenta)
        printf "\e[${style};95m%s\e[0m\n" "$text"
        ;;
    cyan)
        printf "\e[${style};96m%s\e[0m\n" "$text"
        ;;
    *)
        printf "%s\n" "$text"
        ;;
    esac
}

die() {
    colorized_echo red "$*"
    exit 1
}

# Normalize redundant leading and trailing slashes without requiring the path
# to exist. This keeps legacy SQLite URLs containing five slashes compatible
# while producing the same path used by normal four-slash absolute URLs.
normalize_posix_path() {
    local path="$1"

    while [[ "$path" == *//* ]]; do
        path="${path//\/\//\/}"
    done
    while [[ "$path" == //* ]]; do
        path="${path#/}"
    done
    while [[ "$path" != "/" && "$path" == */ ]]; do
        path="${path%/}"
    done

    printf '%s\n' "$path"
}

# Return the filesystem path represented by a SQLAlchemy SQLite URL.
#   sqlite:///relative.db       -> relative.db
#   sqlite:////absolute/db      -> /absolute/db
#   sqlite://///absolute/db     -> /absolute/db (legacy installer output)
sqlite_database_path_from_url() {
    local url="$1"
    local url_part=""
    local path=""

    [[ "$url" =~ ^sqlite[^:]*:// ]] || return 1

    url_part="${url#*://}"
    url_part="${url_part%%\?*}"
    url_part="${url_part%%#*}"

    if [[ "$url_part" == //* ]]; then
        path="/${url_part#//}"
    elif [[ "$url_part" == /* ]]; then
        path="${url_part#/}"
    else
        path="$url_part"
    fi

    normalize_posix_path "$path"
}

# Build a SQLAlchemy URL for an absolute SQLite database path. Stripping the
# path's leading slash before adding the URL prefix guarantees exactly four
# slashes after the scheme separator.
sqlite_absolute_database_url() {
    local driver="$1"
    local path=""

    path=$(normalize_posix_path "$2")
    [[ "$driver" =~ ^sqlite([+][A-Za-z0-9_]+)?$ ]] || return 1
    [[ "$path" == /* ]] || return 1

    printf '%s:////%s\n' "$driver" "${path#/}"
}

# Ensure a secret-bearing file (e.g. .env, TLS private key) is only readable by
# its owner. Creates the file with 0600 if it is missing so callers can harden
# it *before* writing secrets; tightens it to 0600 if it already exists. A
# truncating writer such as `curl -o` preserves the inode's mode, so writing
# into the pre-created file keeps it private.
harden_secret_file() {
    local path="$1"
    [ -n "$path" ] || return 1
    if [ ! -e "$path" ]; then
        (umask 077 && : >"$path") || return 1
    fi
    chmod 600 "$path"
}

temp_root_dir() {
    local root=""

    if [ -n "${APP_TMP_DIR:-}" ]; then
        root="$APP_TMP_DIR"
    elif [ -n "${DATA_DIR:-}" ]; then
        root="$DATA_DIR/tmp"
    elif [ -n "${APP_NAME:-}" ]; then
        root="/var/lib/$APP_NAME/tmp"
    else
        root="/var/lib/pasarguard-scripts/tmp"
    fi

    mkdir -p "$root"
    printf '%s\n' "$root"
}

create_temp_dir() {
    local prefix="${1:-tmpdir}"
    local root=""
    local candidate=""
    local attempt=0

    root=$(temp_root_dir)
    while [ "$attempt" -lt 20 ]; do
        candidate="${root}/${prefix}-$$-${RANDOM}-${attempt}"
        if mkdir "$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
        attempt=$((attempt + 1))
    done

    die "Failed to create temporary directory in $root"
}

create_temp_file() {
    local prefix="${1:-tmpfile}"
    local suffix="${2:-}"
    local root=""

    root=$(temp_root_dir)
    create_temp_file_in_dir "$root" "$prefix" "$suffix"
}

create_temp_file_in_dir() {
    local dir="$1"
    local prefix="${2:-tmpfile}"
    local suffix="${3:-}"
    local candidate=""
    local attempt=0

    mkdir -p "$dir"
    while [ "$attempt" -lt 20 ]; do
        candidate="${dir}/${prefix}-$$-${RANDOM}-${attempt}${suffix}"
        if (set -C; : >"$candidate") 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
        attempt=$((attempt + 1))
    done

    die "Failed to create temporary file in $dir"
}

resolve_remote_commit_sha() {
    local repo="${1:-PasarGuard/scripts}"
    local branch="${2:-main}"
    local response=""
    local sha=""

    [ -n "${PASARGUARD_SKIP_REMOTE_COMMIT_LOOKUP:-}" ] && return 1
    command -v curl >/dev/null 2>&1 || return 1

    response=$(curl -fsSL --connect-timeout 3 --max-time 5 \
        "https://api.github.com/repos/${repo}/commits/${branch}" 2>/dev/null) || return 1
    sha=$(printf '%s' "$response" | grep -m1 -o '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]\{7,40\}"' | grep -o '[0-9a-f]\{7,40\}')

    [ -n "$sha" ] || return 1
    printf '%s\n' "$sha"
}

get_script_commit_sha() {
    local script_dir="${1:-}"
    local baked_sha="${2:-}"
    local commit_sha=""

    if [ -n "$baked_sha" ] && [ "$baked_sha" != "__SCRIPT_COMMIT_SHA__" ]; then
        printf '%s\n' "$baked_sha"
        return 0
    fi

    if [ -n "${PASARGUARD_SCRIPT_COMMIT:-}" ] && [ "$PASARGUARD_SCRIPT_COMMIT" != "__SCRIPT_COMMIT_SHA__" ]; then
        printf '%s\n' "$PASARGUARD_SCRIPT_COMMIT"
        return 0
    fi

    if [ -n "${SCRIPT_COMMIT_SHA:-}" ] && [ "$SCRIPT_COMMIT_SHA" != "__SCRIPT_COMMIT_SHA__" ]; then
        printf '%s\n' "$SCRIPT_COMMIT_SHA"
        return 0
    fi

    if [ -n "$script_dir" ] && command -v git >/dev/null 2>&1; then
        commit_sha=$(git -C "$script_dir" rev-parse HEAD 2>/dev/null || true)
        if [ -n "$commit_sha" ]; then
            printf '%s\n' "$commit_sha"
            return 0
        fi
    fi

    # Scripts are normally installed via `curl ... | bash`, so there is no git
    # checkout and no baked-in SHA to fall back on. Ask GitHub which commit
    # "main" currently points to instead of printing the literal branch name.
    commit_sha=$(resolve_remote_commit_sha "${PASARGUARD_SCRIPT_REPO:-}" "${PASARGUARD_SCRIPT_BRANCH:-}")
    if [ -n "$commit_sha" ]; then
        printf '%s\n' "$commit_sha"
        return 0
    fi

    printf '%s\n' "main"
}

print_script_execution_header() {
    local script_name="$1"
    local baked_sha="${2:-}"
    local action_type="${3:-}"
    local script_dir="${4:-${SCRIPT_DIR:-}}"
    local commit_sha=""

    commit_sha=$(get_script_commit_sha "$script_dir" "$baked_sha")

    if [ -n "$action_type" ]; then
        printf '# Executing %s %s script, commit: %s\n' "$script_name" "$action_type" "$commit_sha"
    else
        printf '# Executing %s script, commit: %s\n' "$script_name" "$commit_sha"
    fi
}
