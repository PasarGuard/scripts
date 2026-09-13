#!/usr/bin/env bash

SHARED_LIB_INSTALL_DIR="${SHARED_LIB_INSTALL_DIR:-/usr/local/lib/pasarguard-scripts/lib}"
MIRROR_INSTALL_DIR="${MIRROR_INSTALL_DIR:-/usr/local/lib/pasarguard-scripts/iran-sanction}"

# Construct the raw GitHub download URL for a file in a given repository.
github_raw_url() {
    local repo="$1"
    local path="$2"

    printf 'https://github.com/%s/raw/main/%s\n' "$repo" "$path"
}

# Download a remote file using curl with fail-fast and silent options.
github_download_file() {
    local url="$1"
    local target_path="$2"

    curl -fsSL "$url" -o "$target_path"
}

# Back up installed scripts and shared libraries into a temporary directory.
backup_scripts() {
    local backup_dir=""
    backup_dir=$(create_temp_dir "scripts-backup")

    # Backup main scripts
    [ -f "/usr/local/bin/pasarguard" ] && cp "/usr/local/bin/pasarguard" "$backup_dir/"
    [ -f "/usr/local/bin/pg-node" ] && cp "/usr/local/bin/pg-node" "$backup_dir/"

    # Backup shared libraries
    if [ -d "$SHARED_LIB_INSTALL_DIR" ]; then
        mkdir -p "$backup_dir/lib"
        # Only copy if directory is not empty
        if [ "$(ls -A "$SHARED_LIB_INSTALL_DIR")" ]; then
            cp -r "$SHARED_LIB_INSTALL_DIR/"* "$backup_dir/lib/"
        fi
    fi

    # Backup mirror script
    if [ -f "$MIRROR_INSTALL_DIR/mirror.sh" ]; then
        mkdir -p "$backup_dir/iran-sanction"
        cp "$MIRROR_INSTALL_DIR/mirror.sh" "$backup_dir/iran-sanction/"
    fi

    printf '%s\n' "$backup_dir"
}

# Restore main scripts and shared libraries from a previous backup directory.
restore_scripts() {
    local backup_dir="$1"
    [ -z "$backup_dir" ] && return 1

    # Restore main scripts
    [ -f "$backup_dir/pasarguard" ] && install -m 755 "$backup_dir/pasarguard" "/usr/local/bin/pasarguard"
    [ -f "$backup_dir/pg-node" ] && install -m 755 "$backup_dir/pg-node" "/usr/local/bin/pg-node"

    # Restore shared libraries
    if [ -d "$backup_dir/lib" ]; then
        mkdir -p "$SHARED_LIB_INSTALL_DIR"
        if [ "$(ls -A "$backup_dir/lib")" ]; then
            install -m 644 "$backup_dir/lib/"* "$SHARED_LIB_INSTALL_DIR/"
        fi
    fi

    # Restore mirror script
    if [ -f "$backup_dir/iran-sanction/mirror.sh" ]; then
        mkdir -p "$MIRROR_INSTALL_DIR"
        install -m 755 "$backup_dir/iran-sanction/mirror.sh" "$MIRROR_INSTALL_DIR/mirror.sh"
    fi
}

# Clean up temporary backup directory created by backup_scripts.
cleanup_backup() {
    local backup_dir="$1"
    if [ -n "$backup_dir" ]; then
        rm -rf "$backup_dir"
    fi
}

# Download and install an executable shell script from a repository into /usr/local/bin.
github_install_script_from_repo() {
    local repo="$1"
    local script_name="$2"
    local install_name="$3"
    local tmp_file=""

    tmp_file=$(mktemp) || return 1
    trap 'rm -f "$tmp_file"' RETURN

    if ! curl -fSL "$(github_raw_url "$repo" "$script_name")" -o "$tmp_file"; then
        trap - RETURN
        rm -f "$tmp_file"
        return 1
    fi

    if ! chmod 755 "$tmp_file"; then
        trap - RETURN
        rm -f "$tmp_file"
        return 1
    fi

    if ! install -m 755 "$tmp_file" "/usr/local/bin/$install_name"; then
        trap - RETURN
        rm -f "$tmp_file"
        return 1
    fi

    trap - RETURN
    rm -f "$tmp_file"
}

# Copy specified shared library files from a local source directory into SHARED_LIB_INSTALL_DIR.
install_shared_libs_from_local() {
    local source_dir="$1"
    shift
    local lib_name=""

    mkdir -p "$SHARED_LIB_INSTALL_DIR"
    for lib_name in "$@"; do
        if [ -f "$source_dir/lib/$lib_name" ]; then
            install -m 644 "$source_dir/lib/$lib_name" "$SHARED_LIB_INSTALL_DIR/$lib_name"
        fi
    done
}

# Download and install specified shared library files from GitHub repository into SHARED_LIB_INSTALL_DIR.
install_shared_libs_from_repo() {
    local fetch_repo="$1"
    shift
    local tmp_dir=""
    local lib_name=""

    tmp_dir=$(create_temp_dir "shared-libs")
    mkdir -p "$SHARED_LIB_INSTALL_DIR"

    for lib_name in "$@"; do
        if ! github_download_file "$(github_raw_url "$fetch_repo" "lib/$lib_name")" "$tmp_dir/$lib_name"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        if ! install -m 644 "$tmp_dir/$lib_name" "$SHARED_LIB_INSTALL_DIR/$lib_name"; then
            rm -rf "$tmp_dir"
            return 1
        fi
    done

    rm -rf "$tmp_dir"
}

# Install the domestic mirror management script from a local source directory.
install_mirror_from_local() {
    local source_dir="$1"

    if [ -f "$source_dir/iran-sanction/mirror.sh" ]; then
        mkdir -p "$MIRROR_INSTALL_DIR"
        install -m 755 "$source_dir/iran-sanction/mirror.sh" "$MIRROR_INSTALL_DIR/mirror.sh"
    fi
}

# Download and install the domestic mirror management script from GitHub repository.
install_mirror_from_repo() {
    local fetch_repo="$1"
    local tmp_dir=""

    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/iran-sanction/mirror.sh" ]; then
        install_mirror_from_local "$SCRIPT_DIR"
        return 0
    fi

    tmp_dir=$(create_temp_dir "mirror-install")
    if ! github_download_file "$(github_raw_url "$fetch_repo" "iran-sanction/mirror.sh")" "$tmp_dir/mirror.sh"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$MIRROR_INSTALL_DIR"
    if ! install -m 755 "$tmp_dir/mirror.sh" "$MIRROR_INSTALL_DIR/mirror.sh"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}
