#!/usr/bin/env bash
set -e

# Download Xray latest

RELEASE_TAG="latest"
TARGET_OS=""
TARGET_ARCH=""

usage() {
    cat <<'EOF'
Usage: install_core.sh [--tag <release-tag>] [--os <linux>] [--arch <arch>]

Options:
  --tag    Xray release tag (default: latest)
  --os     Target OS (default: autodetect; supported: linux)
  --arch   Target arch (default: autodetect; supported: 32,64,arm32-v5,arm32-v6,arm32-v7a,arm64-v8a,mips32,mips32le,mips64,mips64le,ppc64,ppc64le,riscv64,s390x)
  -h, --help  Show this help

Examples:
  install_core.sh --arch arm64-v8a
  install_core.sh --tag v1.8.10 --arch mips32le
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)
                RELEASE_TAG="$2"; shift 2;;
            --os)
                TARGET_OS="$2"; shift 2;;
            --arch)
                TARGET_ARCH="$2"; shift 2;;
            -h|--help)
                usage; exit 0;;
            *)
                echo "error: unknown option $1"
                usage
                exit 1
                ;;
        esac
    done
}

parse_args "$@"

check_if_running_as_root() {
    # If you want to run as another user, please modify $EUID to be owned by this user
    if [[ "$EUID" -ne '0' ]]; then
        echo "error: You must run this script as root!"
        exit 1
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ -n "$TARGET_OS" && "$TARGET_OS" != "linux" ]]; then
        echo "error: This operating system is not supported (supported: linux)."
        exit 1
    fi

    # If arch explicitly provided, trust it after minimal validation
    if [[ -n "$TARGET_ARCH" ]]; then
        ARCH="$TARGET_ARCH"
        return
    fi
    
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                ARCH='32'
            ;;
            'amd64' | 'x86_64')
                ARCH='64'
            ;;
            'armv5tel')
                ARCH='arm32-v5'
            ;;
            'armv6l')
                ARCH='arm32-v6'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv7' | 'armv7l')
                ARCH='arm32-v7a'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv8' | 'aarch64')
                ARCH='arm64-v8a'
            ;;
            'mips')
                ARCH='mips32'
            ;;
            'mipsle')
                ARCH='mips32le'
            ;;
            'mips64')
                ARCH='mips64'
                lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
            'mips64le')
                ARCH='mips64le'
            ;;
            'ppc64')
                ARCH='ppc64'
            ;;
            'ppc64le')
                ARCH='ppc64le'
            ;;
            'riscv64')
                ARCH='riscv64'
            ;;
            's390x')
                ARCH='s390x'
            ;;
            *)
                echo "error: The architecture is not supported."
                exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

download_xray() {
    TARGET_OS_VALUE="${TARGET_OS:-linux}"

    if [[ "$RELEASE_TAG" == "latest" ]]; then
        DOWNLOAD_LINK="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-${TARGET_OS_VALUE}-$ARCH.zip"
    else
        DOWNLOAD_LINK="https://github.com/XTLS/Xray-core/releases/download/$RELEASE_TAG/Xray-${TARGET_OS_VALUE}-$ARCH.zip"
    fi
    
    echo "Downloading Xray archive: $DOWNLOAD_LINK"
    if ! curl -RL -H 'Cache-Control: no-cache' -o "$ZIP_FILE" "$DOWNLOAD_LINK"; then
        echo 'error: Download failed! Please check your network or try again.'
        rm -rf "$TMP_DIRECTORY"
        exit 1
    fi
}

extract_xray() {
    if ! unzip -q "$ZIP_FILE" -d "$TMP_DIRECTORY"; then
        echo 'error: Xray decompression failed.'
        rm -rf "$TMP_DIRECTORY"
        echo "removed: $TMP_DIRECTORY"
        exit 1
    fi
    echo "Extracted Xray archive to $TMP_DIRECTORY"
    
    # Validate required files exist
    if [[ ! -f "${TMP_DIRECTORY}/xray" ]]; then
        echo 'error: xray binary not found in archive.'
        rm -rf "$TMP_DIRECTORY"
        exit 1
    fi
    if [[ ! -f "${TMP_DIRECTORY}/geoip.dat" ]]; then
        echo 'error: geoip.dat not found in archive.'
        rm -rf "$TMP_DIRECTORY"
        exit 1
    fi
    if [[ ! -f "${TMP_DIRECTORY}/geosite.dat" ]]; then
        echo 'error: geosite.dat not found in archive.'
        rm -rf "$TMP_DIRECTORY"
        exit 1
    fi
}

place_xray() {
    if ! install -m 755 "${TMP_DIRECTORY}/xray" "/usr/local/bin/xray"; then
        echo 'error: Failed to install xray binary.'
        rm -rf "$TMP_DIRECTORY"
        exit 1
    fi
    install -d "/usr/local/share/xray/"
    if ! install -m 644 "${TMP_DIRECTORY}/geoip.dat" "/usr/local/share/xray/geoip.dat"; then
        echo 'error: Failed to install geoip.dat.'
        rm -rf "$TMP_DIRECTORY"
        exit 1
    fi
    if ! install -m 644 "${TMP_DIRECTORY}/geosite.dat" "/usr/local/share/xray/geosite.dat"; then
        echo 'error: Failed to install geosite.dat.'
        rm -rf "$TMP_DIRECTORY"
        exit 1
    fi
    echo "Xray files installed"
}

check_if_running_as_root
identify_the_operating_system_and_architecture

TMP_DIRECTORY="$(mktemp -d)"
ZIP_FILE="${TMP_DIRECTORY}/Xray-linux-$ARCH.zip"

download_xray
extract_xray
place_xray

rm -rf "$TMP_DIRECTORY"
echo "Installation complete!"
exit 0