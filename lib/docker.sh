#!/usr/bin/env bash

install_docker() {
    colorized_echo blue "Installing Docker"
    if ! bash -o pipefail -c 'curl -fsSL https://get.docker.com | sh'; then
        die "Failed to install Docker"
    fi
    ensure_docker_service_running
    colorized_echo green "Docker installed successfully"
}

ensure_docker_service_running() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    if [ ! -d /run/systemd/system ]; then
        return
    fi

    if ! systemctl list-unit-files docker.service >/dev/null 2>&1; then
        return
    fi

    if systemctl is-active --quiet docker; then
        return
    fi

    colorized_echo blue "Starting Docker service"
    if ! systemctl enable --now docker >/dev/null 2>&1; then
        systemctl start docker >/dev/null 2>&1 || die "Failed to start Docker service"
    fi
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE='docker compose'
    else
        die "docker compose v2 not found"
    fi
}

compose_up() {
    ensure_docker_service_running
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d --remove-orphans
}

compose_down() {
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down
}

compose_logs() {
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" logs
}

compose_logs_follow() {
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" logs -f
}
