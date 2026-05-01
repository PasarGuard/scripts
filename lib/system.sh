#!/usr/bin/env bash

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        die "This command must be run as root."
    fi
}

detect_os() {
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
    elif [ -f /etc/redhat-release ]; then
        OS=$(awk '{print $1}' /etc/redhat-release)
    elif [ -f /etc/arch-release ]; then
        OS="Arch Linux"
    else
        die "Unsupported operating system"
    fi
}

detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"

    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update -qq >/dev/null 2>&1
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        PKG_MANAGER="yum"
        $PKG_MANAGER update -y -q >/dev/null 2>&1
        $PKG_MANAGER install -y -q epel-release >/dev/null 2>&1
    elif [[ "$OS" == "Fedora"* ]]; then
        PKG_MANAGER="dnf"
        $PKG_MANAGER update -q -y >/dev/null 2>&1
    elif [[ "$OS" == "Arch Linux" ]] || [[ "$OS" == "Arch"* ]]; then
        PKG_MANAGER="pacman"
        $PKG_MANAGER -Sy --noconfirm --quiet >/dev/null 2>&1
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER refresh --quiet >/dev/null 2>&1
    else
        die "Unsupported operating system"
    fi
}

install_package() {
    local package="$1"

    if [ -z "${PKG_MANAGER:-}" ]; then
        detect_and_update_package_manager
    fi

    colorized_echo blue "Installing $package"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER -y -qq install "$package" >/dev/null 2>&1
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        $PKG_MANAGER install -y -q "$package" >/dev/null 2>&1
    elif [[ "$OS" == "Fedora"* ]]; then
        $PKG_MANAGER install -y -q "$package" >/dev/null 2>&1
    elif [[ "$OS" == "Arch Linux" ]] || [[ "$OS" == "Arch"* ]]; then
        $PKG_MANAGER -S --noconfirm --quiet "$package" >/dev/null 2>&1
    elif [[ "$OS" == "openSUSE"* ]]; then
        $PKG_MANAGER --quiet install -y "$package" >/dev/null 2>&1
    else
        die "Unsupported operating system"
    fi
}

check_editor() {
    if [ -z "${EDITOR:-}" ]; then
        if command -v nano >/dev/null 2>&1; then
            EDITOR="nano"
        elif command -v vi >/dev/null 2>&1; then
            EDITOR="vi"
        else
            detect_os
            install_package nano
            EDITOR="nano"
        fi
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" != "Linux" ]]; then
        die "error: This operating system is not supported."
    fi

    case "$(uname -m)" in
    i386 | i686)
        ARCH='32'
        ;;
    amd64 | x86_64)
        ARCH='64'
        ;;
    armv5tel)
        ARCH='arm32-v5'
        ;;
    armv6l)
        ARCH='arm32-v6'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
        ;;
    armv7 | armv7l)
        ARCH='arm32-v7a'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
        ;;
    armv8 | aarch64)
        ARCH='arm64-v8a'
        ;;
    mips)
        ARCH='mips32'
        ;;
    mipsle)
        ARCH='mips32le'
        ;;
    mips64)
        ARCH='mips64'
        lscpu | grep -q "Little Endian" && ARCH='mips64le'
        ;;
    mips64le)
        ARCH='mips64le'
        ;;
    ppc64)
        ARCH='ppc64'
        ;;
    ppc64le)
        ARCH='ppc64le'
        ;;
    riscv64)
        ARCH='riscv64'
        ;;
    s390x)
        ARCH='s390x'
        ;;
    *)
        die "error: The architecture is not supported."
        ;;
    esac
}

install_yq() {
    local base_url="https://github.com/mikefarah/yq/releases/latest/download"
    local yq_binary=""
    local yq_url=""

    if command -v yq >/dev/null 2>&1; then
        colorized_echo green "yq is already installed."
        return
    fi

    identify_the_operating_system_and_architecture

    case "$ARCH" in
    64 | x86_64)
        yq_binary="yq_linux_amd64"
        ;;
    arm32-v7a | arm32-v6 | arm32-v5 | armv7l)
        yq_binary="yq_linux_arm"
        ;;
    arm64-v8a | aarch64)
        yq_binary="yq_linux_arm64"
        ;;
    32 | i386 | i686)
        yq_binary="yq_linux_386"
        ;;
    *)
        die "Unsupported architecture: $ARCH"
        ;;
    esac

    yq_url="${base_url}/${yq_binary}"
    colorized_echo blue "Downloading yq from ${yq_url}..."

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        colorized_echo yellow "Neither curl nor wget is installed. Attempting to install curl."
        install_package curl || die "Failed to install curl. Please install curl or wget manually."
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -L "$yq_url" -o /usr/local/bin/yq || die "Failed to download yq using curl. Please check your internet connection."
    elif command -v wget >/dev/null 2>&1; then
        wget -O /usr/local/bin/yq "$yq_url" || die "Failed to download yq using wget. Please check your internet connection."
    fi

    chmod +x /usr/local/bin/yq
    colorized_echo green "yq installed successfully!"

    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi
}
