#!/usr/bin/env bash
# =============================================================================
# mirror.sh - Sourceable helpers for selecting and applying Iranian mirrors
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/system.sh
source "$ROOT_DIR/lib/system.sh"

# Number of throughput samples per mirror (averaged to reduce variance).
SAMPLES="${SAMPLES:-3}"
# Max seconds to wait per curl attempt.
TIMEOUT="${TIMEOUT:-8}"
# Minimum acceptable speed in bytes/sec (512 KB/s).
MIN_SPEED="${MIN_SPEED:-524288}"
# Composite score = speed weight + latency weight.
SPEED_WEIGHT="${SPEED_WEIGHT:-0.70}"
LAT_WEIGHT="${LAT_WEIGHT:-0.30}"

DRY_RUN="${DRY_RUN:-false}"
BEST_MIRROR=""
OS_ID=""
OS_CODENAME=""
OS_LIKE=""

APT_MIRRORS=(
    "https://mirror.arvancloud.ir/debian"
    "https://repo.hmirror.ir/debian"
    "https://mirror.iranserver.com/debian"
    "https://mirror.mobinhost.com/debian"
    "https://repo.iut.ac.ir/repo/debian"
)

APT_MIRRORS_UBUNTU=(
    "http://ir.archive.ubuntu.com/ubuntu"
    "https://mirror.arvancloud.ir/ubuntu"
    "https://repo.hmirror.ir/ubuntu"
    "https://mirror.iranserver.com/ubuntu"
    "https://mirror.mobinhost.com/ubuntu"
    "https://repo.iut.ac.ir/repo/ubuntu"
)

DOCKER_MIRRORS=(
    "https://docker.arvancloud.ir"
    "https://hub.hamdocker.ir"
    "https://docker.iranserver.com"
    "https://mirror.iranserver.com"
    "https://docker.mobinhost.com"
)

DOCKER_PROBE_PATH="/v2/"

info() { colorized_echo cyan "[INFO]  $*"; }
success() { colorized_echo green "[OK]    $*"; }
warn() { colorized_echo yellow "[WARN]  $*"; }
error() { colorized_echo red "[ERR]   $*" >&2; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

require() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || {
            error "Required command not found: $cmd"
            exit 1
        }
    done
}

detect_release_info() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-}"
        OS_LIKE="${ID_LIKE:-}"
    else
        OS_ID="unknown"
        OS_CODENAME=""
        OS_LIKE=""
    fi
}

get_os_codename() {
    detect_release_info
    if [[ -n "${OS_CODENAME:-}" ]]; then
        echo "$OS_CODENAME"
    else
        lsb_release -cs 2>/dev/null || echo "stable"
    fi
}

is_ubuntu_family() {
    [[ "$OS_ID" == "ubuntu" ]] || [[ "${OS_LIKE:-}" == *"ubuntu"* ]]
}

benchmark_mirror() {
    local base_url="$1"
    local probe="$2"
    local allow_401="${3:-false}"
    local url="${base_url}${probe}"
    local total_speed=0
    local total_latency=0
    local success_count=0
    local i

    for ((i = 0; i < SAMPLES; i++)); do
        local result http_code speed latency latency_ms
        result=$(curl -sSL \
            --max-time "$TIMEOUT" \
            --connect-timeout 4 \
            -o /dev/null \
            -w "%{http_code} %{speed_download} %{time_connect}" \
            "$url" 2>/dev/null) || continue

        read -r http_code speed latency <<< "$result"

        if [[ "$http_code" == "200" ]] || { [[ "$allow_401" == "true" ]] && [[ "$http_code" == "401" ]]; }; then
            speed=$(printf "%.0f" "$speed")
            latency_ms=$(awk "BEGIN{printf \"%.0f\", $latency * 1000}")

            if [[ "$allow_401" == "true" ]]; then
                if (( speed <= 0 )); then
                    speed=$MIN_SPEED
                fi
                total_speed=$((total_speed + speed))
                total_latency=$((total_latency + latency_ms))
                ((success_count += 1))
            elif (( speed >= MIN_SPEED )); then
                total_speed=$((total_speed + speed))
                total_latency=$((total_latency + latency_ms))
                ((success_count += 1))
            fi
        fi
    done

    if (( success_count == 0 )); then
        echo "FAIL"
        return 0
    fi

    echo "$((total_speed / success_count)) $((total_latency / success_count))"
}

benchmark_list() {
    local label="$1"
    shift
    local probe="$1"
    shift
    local allow_401="$1"
    shift
    local mirrors=("$@")
    local raw_results=()
    local mirror result spd lat

    BEST_MIRROR=""
    bold "\n-- Benchmarking ${label} mirrors ------------------------------"

    for mirror in "${mirrors[@]}"; do
        printf "  %-55s" "$mirror"
        result=$(benchmark_mirror "$mirror" "$probe" "$allow_401")
        if [[ "$result" == "FAIL" ]]; then
            echo " FAIL"
            continue
        fi

        read -r spd lat <<< "$result"
        printf " %8s KB/s  %4s ms\n" "$((spd / 1024))" "$lat"
        raw_results+=("$mirror|$spd|$lat")
    done

    if [[ ${#raw_results[@]} -eq 0 ]]; then
        error "All ${label} mirrors failed"
        return 1
    fi

    local max_speed=0
    local max_lat=0
    local min_lat=999999
    local entry score sorted rank=1
    local scored=()

    for entry in "${raw_results[@]}"; do
        IFS='|' read -r mirror spd lat <<< "$entry"
        (( spd > max_speed )) && max_speed="$spd"
        (( lat > max_lat )) && max_lat="$lat"
        (( lat < min_lat )) && min_lat="$lat"
    done

    for entry in "${raw_results[@]}"; do
        IFS='|' read -r mirror spd lat <<< "$entry"
        score=$(awk -v spd="$spd" -v lat="$lat" \
            -v max_s="$max_speed" -v max_l="$max_lat" -v min_l="$min_lat" \
            -v sw="$SPEED_WEIGHT" -v lw="$LAT_WEIGHT" '
            BEGIN {
                lat_range = (max_l - min_l == 0) ? 1 : (max_l - min_l)
                norm_speed = (max_s > 0) ? spd / max_s : 0
                norm_lat = 1 - (lat - min_l) / lat_range
                printf "%.6f", sw * norm_speed + lw * norm_lat
            }')
        scored+=("$score|$mirror|$spd|$lat")
    done

    sorted=$(printf '%s\n' "${scored[@]}" | sort -t'|' -k1,1rn)

    bold "\n  Ranked results (${label}):"
    while IFS= read -r entry; do
        IFS='|' read -r score mirror spd lat <<< "$entry"
        if (( rank == 1 )); then
            BEST_MIRROR="$mirror"
            printf "  %2d. %-52s score=%.3f  %6s KB/s  %4s ms\n" \
                "$rank" "$mirror" "$score" "$((spd / 1024))" "$lat"
        else
            printf "  %2d. %-52s score=%.3f  %6s KB/s  %4s ms\n" \
                "$rank" "$mirror" "$score" "$((spd / 1024))" "$lat"
        fi
        ((rank += 1))
    done <<< "$sorted"

    echo
    success "Best ${label} mirror: $BEST_MIRROR"
}

apply_apt_mirror() {
    local mirror="$1"
    local sources_file="/etc/apt/sources.list"
    local backup="${sources_file}.bak.$(date +%Y%m%d%H%M%S)"
    local codename

    detect_release_info
    codename="$(get_os_codename)"

    if is_ubuntu_family && [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        sources_file="/etc/apt/sources.list.d/ubuntu.sources"
        backup="${sources_file}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would write $sources_file using mirror: $mirror (codename: $codename)"
        return 0
    fi

    mkdir -p "$(dirname "$sources_file")"
    [[ -f "$sources_file" ]] || touch "$sources_file"
    cp "$sources_file" "$backup"
    info "Backed up $sources_file -> $backup"

    if is_ubuntu_family; then
        if [[ "${sources_file##*/}" == "ubuntu.sources" ]]; then
            cat > "$sources_file" <<EOF
Types: deb
URIs: ${mirror}
Suites: ${codename} ${codename}-updates ${codename}-backports ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        else
            cat > "$sources_file" <<EOF
deb ${mirror} ${codename} main restricted universe multiverse
deb ${mirror} ${codename}-updates main restricted universe multiverse
deb ${mirror} ${codename}-backports main restricted universe multiverse
deb ${mirror} ${codename}-security main restricted universe multiverse
EOF
        fi
    else
        cat > "$sources_file" <<EOF
deb ${mirror} ${codename} main contrib non-free non-free-firmware
deb ${mirror} ${codename}-updates main contrib non-free non-free-firmware
deb ${mirror} ${codename}-backports main contrib non-free non-free-firmware
deb ${mirror} ${codename}-security main contrib non-free non-free-firmware
EOF
    fi

    success "Written new $sources_file"
    info "Running apt-get update to verify..."
    apt-get update -qq && success "apt-get update succeeded" || warn "apt-get update returned errors; check $sources_file"
}

write_docker_daemon_json() {
    local daemon_file="$1"
    local mirror="$2"

    if [[ -f "$daemon_file" ]] && command -v python3 >/dev/null 2>&1; then
        python3 - "$daemon_file" "$mirror" <<'PYEOF'
import json
import sys

path, mirror = sys.argv[1], sys.argv[2]

with open(path, encoding="utf-8") as f:
    config = json.load(f)

config["registry-mirrors"] = [mirror]

with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
        return 0
    fi

    if [[ -f "$daemon_file" ]]; then
        warn "python3 not found; overwriting $daemon_file and preserving only registry-mirrors"
    fi
    cat > "$daemon_file" <<EOF
{
  "registry-mirrors": [
    "$mirror"
  ]
}
EOF
}

apply_docker_mirror() {
    local mirror="$1"
    local daemon_file="/etc/docker/daemon.json"
    local backup="${daemon_file}.bak.$(date +%Y%m%d%H%M%S)"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would set Docker registry-mirror to: $mirror in $daemon_file"
        return 0
    fi

    mkdir -p /etc/docker

    if [[ -f "$daemon_file" ]]; then
        cp "$daemon_file" "$backup"
        info "Backed up $daemon_file -> $backup"
    fi

    write_docker_daemon_json "$daemon_file" "$mirror"
    success "Written $daemon_file"

    if systemctl is-active --quiet docker 2>/dev/null; then
        info "Reloading Docker daemon..."
        systemctl reload docker 2>/dev/null || systemctl restart docker
        success "Docker daemon reloaded"
    else
        warn "Docker is not running; start it manually for changes to take effect"
    fi
}

select_best_apt_mirror() {
    ensure_benchmark_requirements
    detect_release_info
    local codename
    local -a active_mirrors
    codename="$(get_os_codename)"

    if is_ubuntu_family; then
        info "Detected Ubuntu (${codename}); using Ubuntu mirror list"
        active_mirrors=("${APT_MIRRORS_UBUNTU[@]}")
    else
        info "Detected Debian/other (${codename}); using Debian mirror list"
        active_mirrors=("${APT_MIRRORS[@]}")
    fi

    benchmark_list "APT" "/dists/${codename}/Release" "false" "${active_mirrors[@]}"
}

select_best_docker_mirror() {
    ensure_benchmark_requirements
    benchmark_list "Docker" "$DOCKER_PROBE_PATH" "true" "${DOCKER_MIRRORS[@]}"
}

select_and_apply_apt_mirror() {
    ensure_runtime_requirements
    select_best_apt_mirror || return 1
    apply_apt_mirror "$BEST_MIRROR"
}

select_and_apply_docker_mirror() {
    ensure_runtime_requirements
    select_best_docker_mirror || return 1
    apply_docker_mirror "$BEST_MIRROR"
}

ensure_runtime_requirements() {
    require curl awk sort
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY-RUN mode; no files will be modified"
        return 0
    fi
    check_running_as_root
}

ensure_benchmark_requirements() {
    require curl awk sort
}

get_current_docker_mirror() {
    local daemon_file="/etc/docker/daemon.json"

    [ -f "$daemon_file" ] || return 1

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$daemon_file" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    mirrors = data.get("registry-mirrors") or []
    if mirrors:
        print(mirrors[0])
except Exception:
    pass
PYEOF
        return 0
    fi

    sed -n 's/.*"registry-mirrors"[[:space:]]*:[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p' "$daemon_file" | head -n 1
}

is_script_managed_docker_mirror() {
    local current_mirror="$1"
    local mirror=""

    [ -n "$current_mirror" ] || return 1

    for mirror in "${DOCKER_MIRRORS[@]}"; do
        if [ "$mirror" = "$current_mirror" ]; then
            return 0
        fi
    done

    return 1
}

get_current_apt_mirror() {
    local source_file=""
    local mirror=""

    for source_file in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list; do
        [ -f "$source_file" ] || continue

        if [[ "${source_file##*.}" == "sources" ]]; then
            mirror=$(sed -n 's/^URIs:[[:space:]]*//p' "$source_file" | awk '{print $1}' | head -n 1)
        else
            mirror=$(awk '$1 == "deb" && $2 !~ /^\[/ {print $2; exit} $1 == "deb" && $2 ~ /^\[/ {print $3; exit}' "$source_file")
        fi

        if [ -n "$mirror" ]; then
            echo "$mirror"
            return 0
        fi
    done

    return 1
}

is_script_managed_apt_mirror() {
    local current_mirror="$1"
    local mirror=""

    [ -n "$current_mirror" ] || return 1

    for mirror in "${APT_MIRRORS[@]}" "${APT_MIRRORS_UBUNTU[@]}"; do
        if [ "$mirror" = "$current_mirror" ]; then
            return 0
        fi
    done

    return 1
}
