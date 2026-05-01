#!/usr/bin/env bash

SHARED_LIB_INSTALL_DIR="/usr/local/lib/pasarguard-scripts/lib"

github_raw_url() {
    local repo="$1"
    local path="$2"

    printf 'https://github.com/%s/raw/main/%s\n' "$repo" "$path"
}

github_download_file() {
    local url="$1"
    local target_path="$2"

    curl -fsSL "$url" -o "$target_path"
}

github_install_script_from_repo() {
    local repo="$1"
    local script_name="$2"
    local install_name="$3"

    curl -fsSL "$(github_raw_url "$repo" "$script_name")" | install -m 755 /dev/stdin "/usr/local/bin/$install_name"
}

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

install_shared_libs_from_repo() {
    local fetch_repo="$1"
    shift
    local tmp_dir=""
    local lib_name=""

    tmp_dir=$(create_temp_dir "shared-libs")
    mkdir -p "$SHARED_LIB_INSTALL_DIR"

    for lib_name in "$@"; do
        github_download_file "$(github_raw_url "$fetch_repo" "lib/$lib_name")" "$tmp_dir/$lib_name"
        install -m 644 "$tmp_dir/$lib_name" "$SHARED_LIB_INSTALL_DIR/$lib_name"
    done

    rm -rf "$tmp_dir"
}
