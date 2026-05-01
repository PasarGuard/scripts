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
