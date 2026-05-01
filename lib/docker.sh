#!/usr/bin/env bash

install_docker() {
    colorized_echo blue "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    colorized_echo green "Docker installed successfully"
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        die "docker compose not found"
    fi
}

compose_up() {
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
