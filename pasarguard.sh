#!/usr/bin/env bash
set -e

# Handle @ symbol if used in installation (skip it)
if [ "$1" == "@" ]; then
    shift
fi

INSTALL_DIR="/opt"
if [ -z "$APP_NAME" ]; then
    APP_NAME="pasarguard"
fi
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
THEMES_DIR="$APP_DIR/themes"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
LAST_XRAY_CORES=10

colorized_echo() {
    local color=$1
    local text=$2

    case $color in
    "red")
        printf "\e[91m${text}\e[0m\n"
        ;;
    "green")
        printf "\e[92m${text}\e[0m\n"
        ;;
    "yellow")
        printf "\e[93m${text}\e[0m\n"
        ;;
    "blue")
        printf "\e[94m${text}\e[0m\n"
        ;;
    "magenta")
        printf "\e[95m${text}\e[0m\n"
        ;;
    "cyan")
        printf "\e[96m${text}\e[0m\n"
        ;;
    *)
        echo "${text}"
        ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

detect_os() {
    # Detect the operating system
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        PKG_MANAGER="yum"
        $PKG_MANAGER update -y
        $PKG_MANAGER install -y epel-release
    elif [ "$OS" == "Fedora"* ]; then
        PKG_MANAGER="dnf"
        $PKG_MANAGER update
    elif [ "$OS" == "Arch" ]; then
        PKG_MANAGER="pacman"
        $PKG_MANAGER -Sy
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER refresh
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_package() {
    if [ -z $PKG_MANAGER ]; then
        detect_and_update_package_manager
    fi

    PACKAGE=$1
    colorized_echo blue "Installing $PACKAGE"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER -y install "$PACKAGE"
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        $PKG_MANAGER install -y "$PACKAGE"
    elif [ "$OS" == "Fedora"* ]; then
        $PKG_MANAGER install -y "$PACKAGE"
    elif [ "$OS" == "Arch" ]; then
        $PKG_MANAGER -S --noconfirm "$PACKAGE"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_docker() {
    # Install Docker and Docker Compose using the official installation script
    colorized_echo blue "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    colorized_echo green "Docker installed successfully"
}

detect_compose() {
    # Check if docker compose command exists
    if docker compose version >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        colorized_echo red "docker compose not found"
        exit 1
    fi
}

find_container() {
    local db_type=$1
    local container_name=""
    detect_compose
    
    case $db_type in
    mariadb)
        container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps --format json mariadb 2>/dev/null | jq -r '.Name' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name=$(docker ps --filter "name=${APP_NAME}" --filter "name=mariadb" --format '{{.ID}}' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name="mariadb"
        ;;
    mysql)
        container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mysql 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps --format json mysql mariadb 2>/dev/null | jq -r 'if type == "array" then .[] else . end | .Name' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name=$(docker ps --filter "name=${APP_NAME}" --filter "name=mysql" --format '{{.ID}}' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name=$(docker ps --filter "name=${APP_NAME}" --filter "name=mariadb" --format '{{.ID}}' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name="mysql"
        ;;
    postgresql|timescaledb)
        container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q timescaledb 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q postgresql 2>/dev/null || true)
        [ -z "$container_name" ] && container_name=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps --format json timescaledb postgresql 2>/dev/null | jq -r 'if type == "array" then .[] else . end | .Name' 2>/dev/null | head -n 1 || true)
        [ -z "$container_name" ] && container_name="${APP_NAME}-timescaledb-1"
        ;;
    esac
    echo "$container_name"
}

check_container() {
    local container_name=$1
    local db_type=$2
    local actual_container=""
    
    if docker inspect "$container_name" >/dev/null 2>&1; then
        actual_container="$container_name"
    else
        case $db_type in
        mariadb)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-mariadb-1"
            ;;
        mysql)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mysql 2>/dev/null || true)
            [ -z "$actual_container" ] && actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-mysql-1"
            ;;
        postgresql|timescaledb)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q postgresql 2>/dev/null || true)
            [ -z "$actual_container" ] && actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q timescaledb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-postgresql-1"
            ;;
        esac
    fi
    
    [ -z "$actual_container" ] && { echo ""; return 1; }
    container_name="$actual_container"
    docker ps --filter "id=${container_name}" --format '{{.ID}}' 2>/dev/null | grep -q . || \
    docker ps --filter "name=${container_name}" --format '{{.Names}}' 2>/dev/null | grep -q . || \
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^${container_name}$|/${container_name}$" || \
    docker ps --format '{{.ID}}' 2>/dev/null | grep -q "^${container_name}" || { echo ""; return 1; }
    echo "$container_name"
    return 0
}

verify_and_start_container() {
    local container_name=$1
    local db_type=$2
    local actual_container=""
    
    if docker inspect "$container_name" >/dev/null 2>&1; then
        actual_container="$container_name"
    else
        case $db_type in
        mariadb)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-mariadb-1"
            ;;
        mysql)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mysql 2>/dev/null || true)
            [ -z "$actual_container" ] && actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q mariadb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-mysql-1"
            ;;
        postgresql|timescaledb)
            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q postgresql 2>/dev/null || true)
            [ -z "$actual_container" ] && actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q timescaledb 2>/dev/null || true)
            [ -z "$actual_container" ] && [ -f "$COMPOSE_FILE" ] && actual_container="${APP_NAME}-postgresql-1"
            ;;
        esac
    fi
    
    [ -z "$actual_container" ] && { echo ""; return 1; }
    container_name="$actual_container"
    local container_running=false
    docker ps --filter "id=${container_name}" --format '{{.ID}}' 2>/dev/null | grep -q . && container_running=true || \
    docker ps --filter "name=${container_name}" --format '{{.Names}}' 2>/dev/null | grep -q . && container_running=true || \
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^${container_name}$|/${container_name}$" && container_running=true || \
    docker ps --format '{{.ID}}' 2>/dev/null | grep -q "^${container_name}" && container_running=true
    
    if [ "$container_running" = false ]; then
        colorized_echo yellow "Database container '$container_name' is not running. Attempting to start it..."
        docker start "$container_name" >/dev/null 2>&1 || \
        $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" start "${db_type%%|*}" 2>/dev/null || true
        sleep 2
        docker ps --filter "id=${container_name}" --format '{{.ID}}' 2>/dev/null | grep -q . && container_running=true || \
        docker ps --filter "name=${container_name}" --format '{{.Names}}' 2>/dev/null | grep -q . && container_running=true
    fi
    
    [ "$container_running" = true ] && { echo "$container_name"; return 0; } || { echo ""; return 1; }
}

install_pasarguard_script() {
    FETCH_REPO="PasarGuard/scripts"
    SCRIPT_URL="https://github.com/$FETCH_REPO/raw/main/pasarguard.sh"
    colorized_echo blue "Installing pasarguard script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/pasarguard
    colorized_echo green "pasarguard script installed successfully"
}

is_pasarguard_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}

identify_the_operating_system_and_architecture() {
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

send_backup_to_telegram() {
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                colorized_echo yellow "Skipping invalid line in .env: $key=$value"
            fi
        done <"$ENV_FILE"
    else
        colorized_echo red "Environment file (.env) not found."
        exit 1
    fi

    if [ "$BACKUP_SERVICE_ENABLED" != "true" ]; then
        colorized_echo yellow "Backup service is not enabled. Skipping Telegram upload."
        return
    fi

    # Validate Telegram configuration
    if [ -z "$BACKUP_TELEGRAM_BOT_KEY" ]; then
        colorized_echo red "Error: BACKUP_TELEGRAM_BOT_KEY is not set in .env file"
        return 1
    fi

    if [ -z "$BACKUP_TELEGRAM_CHAT_ID" ]; then
        colorized_echo red "Error: BACKUP_TELEGRAM_CHAT_ID is not set in .env file"
        return 1
    fi

    local server_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || hostname -I 2>/dev/null | awk '{print $1}' || echo "Unknown IP")
    local latest_backup=$(ls -t "$APP_DIR/backup" | head -n 1)
    local backup_path="$APP_DIR/backup/$latest_backup"

    if [ ! -f "$backup_path" ]; then
        colorized_echo red "No backups found to send."
        return
    fi

    local backup_size=$(du -m "$backup_path" | cut -f1)
    local split_dir="/tmp/pasarguard_backup_split"
    local is_single_file=true

    mkdir -p "$split_dir"

    if [ "$backup_size" -gt 49 ]; then
        colorized_echo yellow "Backup is larger than 49MB. Splitting the archive..."
        split -b 49M "$backup_path" "$split_dir/part_"
        is_single_file=false
    else
        cp "$backup_path" "$split_dir/part_aa"
    fi

    local backup_time=$(date "+%Y-%m-%d %H:%M:%S %Z")

    for part in "$split_dir"/*; do
        local part_name=$(basename "$part")
        local custom_filename="backup_${part_name}.tar.gz"
        # Escape special characters in variables first (only MarkdownV2 specials)
        local escaped_server_ip=$(printf '%s' "$server_ip" | sed 's/[_*[\]()~`>#+\-=|{}!.]/\\&/g')
        local escaped_filename=$(printf '%s' "$custom_filename" | sed 's/[_*[\]()~`>#+\-=|{}!.]/\\&/g')
        local escaped_time=$(printf '%s' "$backup_time" | sed 's/[_*[\]()~`>#+\-=|{}!.]/\\&/g')

        local caption="📦 *Backup Information*
🌐 *Server IP*: \`$escaped_server_ip\`
📁 *Backup File*: \`$escaped_filename\`
⏰ *Backup Time*: \`$escaped_time\`"

        local response=$(curl -s -w "\n%{http_code}" -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$part;filename=$custom_filename" \
            -F caption="$(printf '%b' "$caption")" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument" 2>&1)
        
        local http_code=$(echo "$response" | tail -n1)
        local response_body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" == "200" ]; then
            # Check if response contains "ok":true
            if echo "$response_body" | grep -q '"ok":true'; then
                colorized_echo green "Backup part $custom_filename successfully sent to Telegram."
            else
                # Extract error message from Telegram response
                local error_msg=$(echo "$response_body" | grep -o '"description":"[^"]*"' | cut -d'"' -f4 || echo "Unknown error")
                colorized_echo red "Failed to send backup part $custom_filename to Telegram: $error_msg"
                echo "Telegram API Response: $response_body" >&2
            fi
        else
            local error_msg=$(echo "$response_body" | grep -o '"description":"[^"]*"' | cut -d'"' -f4 || echo "HTTP $http_code")
            colorized_echo red "Failed to send backup part $custom_filename to Telegram: $error_msg"
            echo "Telegram API Response: $response_body" >&2
        fi
    done

    rm -rf "$split_dir"
}

send_backup_error_to_telegram() {
    local error_messages=$1
    local log_file=$2
    local server_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || hostname -I 2>/dev/null | awk '{print $1}' || echo "Unknown IP")
    local error_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    # Escape special characters in variables first (only MarkdownV2 specials)
    local escaped_error_ip=$(printf '%s' "$server_ip" | sed 's/[_*[\]()~`>#+\-=|{}!.]/\\&/g')
    local escaped_errors=$(printf '%s' "$error_messages" | sed 's/[_*[\]()~`>#+\-=|{}!.]/\\&/g')
    local escaped_error_time=$(printf '%s' "$error_time" | sed 's/[_*[\]()~`>#+\-=|{}!.]/\\&/g')

    local message="⚠️ *Backup Error Notification*
🌐 *Server IP*: \`$escaped_error_ip\`
❌ *Errors*:
\`$escaped_errors\`
⏰ *Time*: \`$escaped_error_time\`"

    message=$(printf '%b' "$message")

    local max_length=1000
    if [ ${#message} -gt $max_length ]; then
        message="${message:0:$((max_length - 50))}...
\`[Message truncated]\`"
    fi

    curl -s -X POST "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendMessage" \
        -d chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
        -d parse_mode="MarkdownV2" \
        -d text="$message" >/dev/null 2>&1 &&
        colorized_echo green "Backup error notification sent to Telegram." ||
        colorized_echo red "Failed to send error notification to Telegram."

    if [ -f "$log_file" ]; then
        # Escape the error_time for the log caption (only MarkdownV2 specials)
        local escaped_log_time=$(printf '%s' "$error_time" | sed 's/[_*[\]()~`>#+\-=|{}!.]/\\&/g')

        response=$(curl -s -w "%{http_code}" -o /tmp/tg_response.json \
            -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$log_file;filename=backup_error.log" \
            -F caption="📜 *Backup Error Log* \\- $escaped_log_time" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument")

        http_code="${response:(-3)}"
        if [ "$http_code" -eq 200 ]; then
            colorized_echo green "Backup error log sent to Telegram."
        else
            colorized_echo red "Failed to send backup error log to Telegram. HTTP code: $http_code"
            cat /tmp/tg_response.json
        fi
    else
        colorized_echo red "Log file not found: $log_file"
    fi
}

backup_service() {
    local telegram_bot_key=""
    local telegram_chat_id=""
    local cron_schedule=""
    local interval_hours=""

    colorized_echo blue "====================================="
    colorized_echo blue "      Welcome to Backup Service      "
    colorized_echo blue "====================================="

    if grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        while true; do
            telegram_bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
            telegram_chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
            cron_schedule=$(awk -F'=' '/^BACKUP_CRON_SCHEDULE=/ {print $2}' "$ENV_FILE" | tr -d '"')

            if [[ "$cron_schedule" == "0 0 * * *" ]]; then
                interval_hours=24
            else
                interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
            fi

            colorized_echo green "====================================="
            colorized_echo green "Current Backup Configuration:"
            colorized_echo cyan "Telegram Bot API Key: $telegram_bot_key"
            colorized_echo cyan "Telegram Chat ID: $telegram_chat_id"
            colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
            colorized_echo green "====================================="
            echo "Choose an option:"
            echo "1. Check Backup Service"
            echo "2. Edit Backup Service"
            echo "3. Reconfigure Backup Service"
            echo "4. Remove Backup Service"
            echo "5. Request Instant Backup"
            echo "6. Exit"
            read -p "Enter your choice (1-6): " user_choice

            case $user_choice in
            1)
                view_backup_service
                echo ""
                ;;
            2)
                edit_backup_service
                echo ""
                ;;
            3)
                colorized_echo yellow "Starting reconfiguration..."
                remove_backup_service
                break
                ;;
            4)
                colorized_echo yellow "Removing Backup Service..."
                remove_backup_service
                return
                ;;
            5)
                colorized_echo yellow "Starting instant backup..."
                backup_command
                colorized_echo green "Instant backup completed."
                echo ""
                ;;
            6)
                colorized_echo yellow "Exiting..."
                return
                ;;
            *)
                colorized_echo red "Invalid choice. Please try again."
                echo ""
                ;;
            esac
        done
    else
        colorized_echo yellow "No backup service is currently configured."
    fi

    while true; do
        printf "Enter your Telegram bot API key: "
        read telegram_bot_key
        if [[ -n "$telegram_bot_key" ]]; then
            break
        else
            colorized_echo red "API key cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Enter your Telegram chat ID: "
        read telegram_chat_id
        if [[ -n "$telegram_chat_id" ]]; then
            break
        else
            colorized_echo red "Chat ID cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Set up the backup interval in hours (1-24):\n"
        read interval_hours

        if ! [[ "$interval_hours" =~ ^[0-9]+$ ]]; then
            colorized_echo red "Invalid input. Please enter a valid number."
            continue
        fi

        if [[ "$interval_hours" -eq 24 ]]; then
            cron_schedule="0 0 * * *"
            colorized_echo green "Setting backup to run daily at midnight."
            break
        fi

        if [[ "$interval_hours" -ge 1 && "$interval_hours" -le 23 ]]; then
            cron_schedule="0 */$interval_hours * * *"
            colorized_echo green "Setting backup to run every $interval_hours hour(s)."
            break
        else
            colorized_echo red "Invalid input. Please enter a number between 1-24."
        fi
    done

    sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/^BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    {
        echo ""
        echo "# Backup service configuration"
        echo "BACKUP_SERVICE_ENABLED=true"
        echo "BACKUP_TELEGRAM_BOT_KEY=$telegram_bot_key"
        echo "BACKUP_TELEGRAM_CHAT_ID=$telegram_chat_id"
        echo "BACKUP_CRON_SCHEDULE=\"$cron_schedule\""
    } >>"$ENV_FILE"

    colorized_echo green "Backup service configuration saved in $ENV_FILE."

    # Use full path to the script for cron job
    local script_path="/usr/local/bin/$APP_NAME"
    if [ ! -f "$script_path" ]; then
        script_path=$(which "$APP_NAME" 2>/dev/null || echo "/usr/local/bin/$APP_NAME")
    fi
    # Set PATH for cron to ensure docker and other tools are found
    local backup_command="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash $script_path backup"
    add_cron_job "$cron_schedule" "$backup_command"

    colorized_echo green "Backup service successfully configured."
    
    # Run initial backup
    colorized_echo blue "Running initial backup..."
    backup_command
    if [ $? -eq 0 ]; then
        colorized_echo green "Initial backup completed successfully."
    else
        colorized_echo yellow "Initial backup completed with warnings. Check logs if needed."
    fi
    if [[ "$interval_hours" -eq 24 ]]; then
        colorized_echo cyan "Backups will be sent to Telegram daily (every 24 hours at midnight)."
    else
        colorized_echo cyan "Backups will be sent to Telegram every $interval_hours hour(s)."
    fi
    colorized_echo green "====================================="
}

add_cron_job() {
    local schedule="$1"
    local command="$2"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null >"$temp_cron" || true
    grep -v "$command" "$temp_cron" >"${temp_cron}.tmp" && mv "${temp_cron}.tmp" "$temp_cron"
    echo "$schedule $command # pasarguard-backup-service" >>"$temp_cron"

    if crontab "$temp_cron"; then
        colorized_echo green "Cron job successfully added."
    else
        colorized_echo red "Failed to add cron job. Please check manually."
    fi
    rm -f "$temp_cron"
}

view_backup_service() {
    if ! grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        colorized_echo red "Backup service is not configured."
        return 1
    fi

    local telegram_bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
    local telegram_chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
    local cron_schedule=$(awk -F'=' '/^BACKUP_CRON_SCHEDULE=/ {print $2}' "$ENV_FILE" | tr -d '"')
    local interval_hours=""

    if [[ "$cron_schedule" == "0 0 * * *" ]]; then
        interval_hours=24
    else
        interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
    fi

    colorized_echo blue "====================================="
    colorized_echo blue "      Backup Service Details         "
    colorized_echo blue "====================================="
    colorized_echo green "Status: Enabled"
    colorized_echo cyan "Telegram Bot API Key: $telegram_bot_key"
    colorized_echo cyan "Telegram Chat ID: $telegram_chat_id"
    colorized_echo cyan "Cron Schedule: $cron_schedule"
    if [[ "$interval_hours" -eq 24 ]]; then
        colorized_echo cyan "Backup Interval: Daily at midnight (every 24 hours)"
    else
        colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
    fi
    colorized_echo blue "====================================="
    echo ""
    read -p "Press Enter to continue..."
}

edit_backup_service() {
    if ! grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        colorized_echo red "Backup service is not configured."
        return 1
    fi

    local telegram_bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
    local telegram_chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
    local cron_schedule=$(awk -F'=' '/^BACKUP_CRON_SCHEDULE=/ {print $2}' "$ENV_FILE" | tr -d '"')
    local interval_hours=""

    if [[ "$cron_schedule" == "0 0 * * *" ]]; then
        interval_hours=24
    else
        interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
    fi

    colorized_echo blue "====================================="
    colorized_echo blue "      Edit Backup Service            "
    colorized_echo blue "====================================="
    echo "Current configuration:"
    colorized_echo cyan "1. Telegram Bot API Key: $telegram_bot_key"
    colorized_echo cyan "2. Telegram Chat ID: $telegram_chat_id"
    colorized_echo cyan "3. Backup Interval: Every $interval_hours hour(s)"
    colorized_echo yellow "4. Cancel"
    echo ""
    read -p "Which setting would you like to edit? (1-4): " edit_choice

    case $edit_choice in
    1)
        while true; do
            printf "Enter new Telegram bot API key [current: $telegram_bot_key]: "
            read new_bot_key
            if [[ -n "$new_bot_key" ]]; then
                sed -i "s|^BACKUP_TELEGRAM_BOT_KEY=.*|BACKUP_TELEGRAM_BOT_KEY=$new_bot_key|" "$ENV_FILE"
                colorized_echo green "Telegram Bot API Key updated successfully."
                break
            else
                colorized_echo red "API key cannot be empty. Please try again."
            fi
        done
        ;;
    2)
        while true; do
            printf "Enter new Telegram chat ID [current: $telegram_chat_id]: "
            read new_chat_id
            if [[ -n "$new_chat_id" ]]; then
                sed -i "s|^BACKUP_TELEGRAM_CHAT_ID=.*|BACKUP_TELEGRAM_CHAT_ID=$new_chat_id|" "$ENV_FILE"
                colorized_echo green "Telegram Chat ID updated successfully."
                break
            else
                colorized_echo red "Chat ID cannot be empty. Please try again."
            fi
        done
        ;;
    3)
        while true; do
            printf "Set new backup interval in hours (1-24) [current: $interval_hours]:\n"
            read new_interval_hours

            if ! [[ "$new_interval_hours" =~ ^[0-9]+$ ]]; then
                colorized_echo red "Invalid input. Please enter a valid number."
                continue
            fi

            local new_cron_schedule=""
            if [[ "$new_interval_hours" -eq 24 ]]; then
                new_cron_schedule="0 0 * * *"
                colorized_echo green "Setting backup to run daily at midnight."
            elif [[ "$new_interval_hours" -ge 1 && "$new_interval_hours" -le 23 ]]; then
                new_cron_schedule="0 */$new_interval_hours * * *"
                colorized_echo green "Setting backup to run every $new_interval_hours hour(s)."
            else
                colorized_echo red "Invalid input. Please enter a number between 1-24."
                continue
            fi

            sed -i "s|^BACKUP_CRON_SCHEDULE=.*|BACKUP_CRON_SCHEDULE=\"$new_cron_schedule\"|" "$ENV_FILE"
            
            # Use full path to the script for cron job
            local script_path="/usr/local/bin/$APP_NAME"
            if [ ! -f "$script_path" ]; then
                script_path=$(which "$APP_NAME" 2>/dev/null || echo "/usr/local/bin/$APP_NAME")
            fi
            # Set PATH for cron to ensure docker and other tools are found
            local backup_command="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash $script_path backup"
            local temp_cron=$(mktemp)
            crontab -l 2>/dev/null >"$temp_cron" || true
            grep -v "# pasarguard-backup-service" "$temp_cron" >"${temp_cron}.tmp" && mv "${temp_cron}.tmp" "$temp_cron"
            echo "$new_cron_schedule $backup_command # pasarguard-backup-service" >>"$temp_cron"

            if crontab "$temp_cron"; then
                colorized_echo green "Backup interval and cron schedule updated successfully."
            else
                colorized_echo red "Failed to update cron job. Please check manually."
            fi
            rm -f "$temp_cron"
            break
        done
        ;;
    4)
        colorized_echo yellow "Edit cancelled."
        return
        ;;
    *)
        colorized_echo red "Invalid choice."
        return
        ;;
    esac

    colorized_echo green "Backup service configuration updated successfully."
}

remove_backup_service() {
    colorized_echo red "in process..."

    sed -i '/^# Backup service configuration/d' "$ENV_FILE"
    sed -i '/BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null >"$temp_cron"

    sed -i '/# pasarguard-backup-service/d' "$temp_cron"

    if crontab "$temp_cron"; then
        colorized_echo green "Backup service task removed from crontab."
    else
        colorized_echo red "Failed to update crontab. Please check manually."
    fi

    rm -f "$temp_cron"

    colorized_echo green "Backup service has been removed."
}

restore_command() {
    colorized_echo blue "Starting restore process..."

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard is not up. Please start pasarguard first."
        exit 1
    fi

    local backup_dir="$APP_DIR/backup"
    local temp_restore_dir="/tmp/pasarguard_restore"
    local log_file="/var/log/pasarguard_restore_error.log"
    >"$log_file"
    echo "Restore Log - $(date)" >>"$log_file"

    # Clean up temp directory
    rm -rf "$temp_restore_dir"
    mkdir -p "$temp_restore_dir"

    # Check if backup directory exists
    if [ ! -d "$backup_dir" ]; then
        colorized_echo red "Backup directory not found: $backup_dir"
        exit 1
    fi

    # List available backup files (find all backup-related files in backup directory)
    local backup_files=()
    while IFS= read -r -d '' file; do
        backup_files+=("$file")
    done < <(find "$backup_dir" -maxdepth 1 \( -name "*backup*.gz" -o -name "*backup*.tar.gz" -o -name "*.tar.gz" \) -type f -print0 2>/dev/null)

    if [ ${#backup_files[@]} -eq 0 ]; then
        # Fallback: try to find any .gz files
        while IFS= read -r -d '' file; do
            backup_files+=("$file")
        done < <(find "$backup_dir" -maxdepth 1 -name "*.gz" -type f -print0 2>/dev/null)
    fi

    if [ ${#backup_files[@]} -eq 0 ]; then
        colorized_echo red "No backup files found in $backup_dir"
        colorized_echo yellow "Looking for files with extensions: .gz, .tar.gz or containing 'backup'"
        exit 1
    fi

    colorized_echo blue "Available backup files:"
    local i=1
    for file in "${backup_files[@]}"; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            local file_size=$(du -h "$file" | cut -f1)
            local file_date=$(date -r "$file" "+%Y-%m-%d %H:%M:%S")
            echo "$i. $filename (Size: $file_size, Date: $file_date)"
            ((i++))
        fi
    done

    local file_count=$((i-1))
    if [ "$file_count" -eq 0 ]; then
        colorized_echo red "No valid backup files found."
        exit 1
    fi

    # Select backup file
    while true; do
        printf "Select backup file to restore from (1-%d): " "$file_count"
        read -r selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$file_count" ]; then
            break
        else
            colorized_echo red "Invalid selection. Please enter a number between 1 and $file_count."
        fi
    done

    local selected_file="${backup_files[$((selection-1))]}"
    local selected_filename=$(basename "$selected_file")

    colorized_echo blue "Selected backup: $selected_filename"

    # Extract backup
    colorized_echo blue "Extracting backup..."

    # Check if it's a valid gzip file
    if ! gzip -t "$selected_file" 2>/dev/null; then
        colorized_echo red "ERROR: The backup file is not a valid gzip archive."
        echo "File is not a valid gzip archive: $selected_file" >>"$log_file"
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    # Check if this is a split backup file
    if [[ "$selected_filename" =~ backup_part_[a-z]+\.tar\.gz ]]; then
        colorized_echo yellow "Detected split backup file. Checking for all parts..."

        # Look for all parts of this split backup
        local base_name="${selected_filename%_part_*}"
        local part_pattern="${base_name}_part_*.tar.gz"
        local all_parts=()
        while IFS= read -r -d '' file; do
            all_parts+=("$file")
        done < <(find "$backup_dir" -maxdepth 1 -name "$part_pattern" -type f -print0 2>/dev/null)

        if [ ${#all_parts[@]} -gt 1 ]; then
            colorized_echo blue "Found ${#all_parts[@]} parts. Concatenating before extraction..."
            # Concatenate all parts in correct order (sorted)
            local concatenated_file="$temp_restore_dir/backup_concatenated.tar.gz"
            printf '%s\n' "${all_parts[@]}" | sort | xargs cat > "$concatenated_file"
            selected_file="$concatenated_file"
            colorized_echo green "✓ Parts concatenated successfully"
        else
            colorized_echo yellow "⚠ Warning: Only found 1 part of a split backup. This may be incomplete."
            colorized_echo yellow "If you have multiple parts, ensure they're all in the backup directory."
            colorized_echo yellow "Continuing with single part (may fail if incomplete)..."
        fi
    fi

    # Try to extract the file
    if ! tar -xzf "$selected_file" -C "$temp_restore_dir" 2>>"$log_file"; then
        colorized_echo red "Failed to extract backup file."
        echo "Failed to extract $selected_file" >>"$log_file"
        if [[ "$selected_filename" =~ backup_part_[a-z]+\.tar\.gz ]]; then
            colorized_echo yellow "This appears to be a split backup part. You may need all parts to restore successfully."
        fi
        rm -rf "$temp_restore_dir"
        exit 1
    fi
    colorized_echo green "✓ Archive extracted successfully"

    # Load environment variables from extracted .env
    colorized_echo blue "Loading configuration from backup..."
    local extracted_env="$temp_restore_dir/.env"
    if [ ! -f "$extracted_env" ]; then
        colorized_echo red "Environment file not found in backup."
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    local db_type=""
    local sqlite_file=""
    local db_host=""
    local db_port=""
    local db_user=""
    local db_password=""
    local db_name=""
    local container_name=""

    # Load variables from extracted .env
    # Check if file is readable
    if [ ! -r "$extracted_env" ]; then
        colorized_echo red "ERROR: .env file is not readable"
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    # Check for binary content or null bytes (warning only, not fatal)
    if grep -q $'\x00' "$extracted_env" 2>/dev/null; then
        colorized_echo yellow "WARNING: .env file contains null bytes, cleaning..."
    fi

    local env_vars_loaded=0

    # Check if file has null bytes - if not, use it directly
    local env_file_to_use="$extracted_env"
    if grep -q $'\x00' "$extracted_env" 2>/dev/null; then
        # File has null bytes, create cleaned version
        local cleaned_env="/tmp/pasarguard_env_cleaned_$$"
        set +e
        tr -d '\000' < "$extracted_env" > "$cleaned_env" 2>/dev/null
        local tr_result=$?
        set -e
        if [ $tr_result -eq 0 ] && [ -s "$cleaned_env" ]; then
            env_file_to_use="$cleaned_env"
        else
            rm -f "$cleaned_env"
        fi
    fi

    # Use the EXACT same pattern as backup_command function
    # This ensures compatibility and works in the current shell (no subshell)
    colorized_echo blue "Loading environment variables..."
    if [ -f "$env_file_to_use" ]; then
        # Temporarily disable exit on error for the loop to handle failures gracefully
        set +e
        while IFS='=' read -r key value || [ -n "$key" ]; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            # Trim whitespace from key and value
            key=$(echo "$key" | xargs 2>/dev/null || echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            value=$(echo "$value" | xargs 2>/dev/null || echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Remove surrounding quotes from value if present
            value=$(echo "$value" | sed -E 's/^["'\''](.*)["'\'']$/\1/' 2>/dev/null || echo "$value")
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value" 2>/dev/null || true
                env_vars_loaded=$((env_vars_loaded + 1))
            else
                echo "Skipping invalid line in .env: $key=$value" >&2
            fi
        done <"$env_file_to_use"
        set -e  # Re-enable exit on error
    else
        colorized_echo red "Environment file (.env) not found in backup."
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    # Clean up temporary cleaned file if we created one
    if [ -n "${cleaned_env:-}" ] && [ -f "$cleaned_env" ]; then
        rm -f "$cleaned_env"
    fi

    colorized_echo green "✓ Loaded $env_vars_loaded environment variables"

    if [ -z "$SQLALCHEMY_DATABASE_URL" ]; then
        colorized_echo red "SQLALCHEMY_DATABASE_URL not found in backup .env file"
        colorized_echo yellow "Available environment variables:"
        grep -v '^#' "$extracted_env" | grep '=' | cut -d'=' -f1 | head -10
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    colorized_echo green "✓ Found SQLALCHEMY_DATABASE_URL: ${SQLALCHEMY_DATABASE_URL:0:50}..."

    # Parse database configuration (similar to backup function)
    colorized_echo blue "Detecting database type..."
    if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^sqlite ]]; then
        db_type="sqlite"
        colorized_echo green "✓ Detected SQLite database"
        local sqlite_url_part="${SQLALCHEMY_DATABASE_URL#*://}"
        sqlite_url_part="${sqlite_url_part%%\?*}"
        sqlite_url_part="${sqlite_url_part%%#*}"

        if [[ "$sqlite_url_part" =~ ^//(.*)$ ]]; then
            sqlite_file="/${BASH_REMATCH[1]}"
        elif [[ "$sqlite_url_part" =~ ^/(.*)$ ]]; then
            sqlite_file="/${BASH_REMATCH[1]}"
        else
            sqlite_file="$sqlite_url_part"
        fi
        colorized_echo blue "Database file: $sqlite_file"
    elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^(mysql|mariadb|postgresql)[^:]*:// ]]; then
        if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^mariadb[^:]*:// ]]; then
            db_type="mariadb"
            colorized_echo green "✓ Detected MariaDB database"
        elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^mysql[^:]*:// ]]; then
            db_type="mysql"
            colorized_echo green "✓ Detected MySQL database"
        elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^postgresql[^:]*:// ]]; then
            # Check if it's timescaledb - use set +e to prevent failure on file not found
            set +e
            if grep -q "image: timescale/timescaledb" "$temp_restore_dir/docker-compose.yml" 2>/dev/null; then
                db_type="timescaledb"
                colorized_echo green "✓ Detected TimescaleDB database"
            else
                db_type="postgresql"
                colorized_echo green "✓ Detected PostgreSQL database"
            fi
            set -e
        fi

        local url_part="${SQLALCHEMY_DATABASE_URL#*://}"
        url_part="${url_part%%\?*}"
        url_part="${url_part%%#*}"

        if [[ "$url_part" =~ ^([^@]+)@(.+)$ ]]; then
            local auth_part="${BASH_REMATCH[1]}"
            url_part="${BASH_REMATCH[2]}"

            if [[ "$auth_part" =~ ^([^:]+):(.+)$ ]]; then
                db_user="${BASH_REMATCH[1]}"
                db_password="${BASH_REMATCH[2]}"
            else
                db_user="$auth_part"
            fi
        fi

        if [[ "$url_part" =~ ^([^:/]+)(:([0-9]+))?/(.+)$ ]]; then
            db_host="${BASH_REMATCH[1]}"
            db_port="${BASH_REMATCH[3]:-}"
            db_name="${BASH_REMATCH[4]}"
            db_name="${db_name%%\?*}"
            db_name="${db_name%%#*}"

            if [ -z "$db_port" ]; then
                if [[ "$db_type" =~ ^(mysql|mariadb)$ ]]; then
                    db_port="3306"
                elif [[ "$db_type" =~ ^(postgresql|timescaledb)$ ]]; then
                    db_port="5432"
                fi
            fi
        fi

        # Find container name for local databases
        if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
            set +e
            container_name=$(find_container "$db_type")
            set -e
        fi
    fi

    if [ -z "$db_type" ]; then
        colorized_echo red "Could not determine database type from backup."
        colorized_echo yellow "SQLALCHEMY_DATABASE_URL: ${SQLALCHEMY_DATABASE_URL:-not set}"
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    colorized_echo green "✓ Database configuration detected: $db_type"

    # Confirm restore
    colorized_echo red "⚠️  CRITICAL WARNING: This action is NOT REVERSIBLE!"
    colorized_echo red "   All current data will be permanently lost!"
    colorized_echo yellow "This will overwrite your current $db_type database!"
    colorized_echo blue "Database type: $db_type"
    if [ -n "$db_name" ]; then
        colorized_echo blue "Database name: $db_name"
    fi
    if [ -n "$container_name" ]; then
        colorized_echo blue "Container: $container_name"
    fi

    while true; do
        printf "Do you want to proceed with the restore? (yes/no): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy](es)?$ ]]; then
            break
        elif [[ "$confirm" =~ ^[Nn](o)?$ ]]; then
            colorized_echo yellow "Restore cancelled."
            rm -rf "$temp_restore_dir"
            exit 0
        else
            colorized_echo red "Please answer yes or no."
        fi
    done

    # Stop pasarguard services before restore for clean state
    colorized_echo blue "🛑 Stopping pasarguard services for clean restore..."
    if [[ "$db_type" == "sqlite" ]]; then
        # For SQLite, stop all services since we need to restore files
        down_pasarguard
        colorized_echo green "✓ All services stopped"
    else
        # For containerized databases, just stop the pasarguard app container
        # Keep database containers running for restore via docker exec
        $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" stop pasarguard 2>/dev/null || true
        colorized_echo green "✓ PasarGuard app container stopped"
    fi

    # Perform restore
    colorized_echo blue "🔄 Starting database restore process..."

    case $db_type in
    sqlite)
        colorized_echo blue "🗑️  Preparing SQLite data directory for restore..."
        colorized_echo yellow "Removing existing SQLite database files..."
        if [ -f "$sqlite_file" ]; then
            colorized_echo blue "Creating backup of current database..."
            cp "$sqlite_file" "${sqlite_file}.backup.$(date +%Y%m%d%H%M%S)" 2>>"$log_file"
            rm -f "$sqlite_file" 2>>"$log_file"
            colorized_echo green "✓ Current database backed up and removed"
        fi

        if [ ! -f "$temp_restore_dir/db_backup.sqlite" ]; then
            colorized_echo red "SQLite backup file not found in backup archive."
            rm -rf "$temp_restore_dir"
            exit 1
        fi

        colorized_echo blue "Restoring SQLite database..."
        if cp "$temp_restore_dir/db_backup.sqlite" "$sqlite_file" 2>>"$log_file"; then
            colorized_echo green "✓ SQLite database restored successfully."
        else
            colorized_echo red "❌ Failed to restore SQLite database."
            echo "SQLite restore failed" >>"$log_file"
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        ;;

    mariadb|mysql)
        if [ ! -f "$temp_restore_dir/db_backup.sql" ]; then
            colorized_echo red "Database backup file not found in backup archive."
            rm -rf "$temp_restore_dir"
            exit 1
        fi

        if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
            if [ -z "$container_name" ]; then
                colorized_echo red "Error: MySQL/MariaDB container not found. Is the container running?"
                echo "MySQL/MariaDB container not found. Container name: ${container_name:-empty}" >>"$log_file"
                rm -rf "$temp_restore_dir"
                exit 1
            else
                local verified_container=$(verify_and_start_container "$container_name" "$db_type")
                if [ -z "$verified_container" ]; then
                    colorized_echo red "Failed to start database container. Please start it manually."
                    rm -rf "$temp_restore_dir"
                    exit 1
                fi
                container_name="$verified_container"

                # Check if this is actually a MariaDB container
                local is_mariadb=false
                local mysql_cmd="mysql"
                local db_type_name="MySQL"
                if docker exec "$container_name" mariadb --version >/dev/null 2>&1; then
                    is_mariadb=true
                    mysql_cmd="mariadb"
                    db_type_name="MariaDB"
                fi

                colorized_echo blue "🗑️  Preparing $db_type_name data for restore..."
                colorized_echo yellow "Removing existing $db_type_name data..."

                # Stop the container first
                colorized_echo blue "Stopping $db_type_name container..."
                $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" stop "$db_type" 2>/dev/null || docker stop "$container_name" 2>/dev/null || true

                # Remove MySQL data directory from host (bind mounted directory)
                # The compose file typically uses /var/lib/mysql/${APP_NAME}:/var/lib/mysql
                colorized_echo blue "Removing MySQL data directory..."
                rm -rf "/var/lib/mysql/${APP_NAME}" 2>>"$log_file" || {
                    colorized_echo yellow "⚠️  Could not remove MySQL data directory, continuing..."
                }

                colorized_echo green "✓ $db_type_name container prepared for restore"

                colorized_echo blue "Restoring $db_type_name database from container: $container_name"

            # Use root user if MYSQL_ROOT_PASSWORD is available
            if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
                colorized_echo blue "Using root user for restore..."
                colorized_echo blue "Importing backup data..."
                    if docker exec -i "$container_name" "$mysql_cmd" -u root -p"$MYSQL_ROOT_PASSWORD" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        colorized_echo green "✓ $db_type_name database restored successfully."
                else
                        colorized_echo red "❌ Failed to restore $db_type_name database."
                        echo "$db_type_name restore failed with root user" >>"$log_file"
                    rm -rf "$temp_restore_dir"
                    exit 1
                fi
            else
                # Use app credentials
                local restore_user="${db_user:-${DB_USER:-}}"
                local restore_password="${db_password:-${DB_PASSWORD:-}}"

                if [ -z "$restore_password" ]; then
                    colorized_echo red "❌ No database password found for restore."
                    rm -rf "$temp_restore_dir"
                    exit 1
                fi

                colorized_echo blue "Using app user '$restore_user' for restore..."
                colorized_echo blue "Importing backup data to database '$db_name'..."
                    if docker exec -i "$container_name" "$mysql_cmd" -u "$restore_user" -p"$restore_password" "$db_name" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        colorized_echo green "✓ $db_type_name database restored successfully."
                else
                        colorized_echo red "❌ Failed to restore $db_type_name database."
                        echo "$db_type_name restore failed with app user" >>"$log_file"
                    rm -rf "$temp_restore_dir"
                    exit 1
                    fi
                fi
            fi
        else
            colorized_echo red "Remote $db_type restore not supported yet."
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        ;;

    postgresql|timescaledb)
        if [ ! -f "$temp_restore_dir/db_backup.sql" ]; then
            colorized_echo red "Database backup file not found in backup archive."
            rm -rf "$temp_restore_dir"
            exit 1
        fi

        # Verify backup file is not empty and is readable
        if [ ! -s "$temp_restore_dir/db_backup.sql" ]; then
            colorized_echo red "Database backup file is empty or unreadable."
                rm -rf "$temp_restore_dir"
                exit 1
            fi

        local backup_size=$(du -h "$temp_restore_dir/db_backup.sql" | cut -f1)
        colorized_echo blue "Backup file size: $backup_size"

        if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]] && [ -n "$container_name" ]; then
            local verified_container=$(verify_and_start_container "$container_name" "$db_type")
            if [ -z "$verified_container" ]; then
                colorized_echo red "Failed to start database container. Please start it manually."
                rm -rf "$temp_restore_dir"
                exit 1
            fi
            container_name="$verified_container"

            colorized_echo blue "🗑️  Preparing $db_type data for restore..."
            colorized_echo yellow "Removing existing $db_type data..."

            # Stop the container first
            colorized_echo blue "Stopping $db_type container..."
            $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" stop "$db_type" 2>/dev/null || docker stop "$container_name" 2>/dev/null || true

            # Remove PostgreSQL data directory from host (bind mounted directory)
            # The compose file typically uses /var/lib/postgresql/${APP_NAME}:/var/lib/postgresql
            colorized_echo blue "Removing PostgreSQL data directory..."
            rm -rf "/var/lib/postgresql/${APP_NAME}" 2>>"$log_file" || {
                colorized_echo yellow "⚠️  Could not remove PostgreSQL data directory, continuing..."
            }

            colorized_echo green "✓ $db_type container prepared for restore"

            colorized_echo blue "Restoring $db_type database from container: $container_name"

            # Import backup data - since we removed all data, we need to restore as postgres superuser
            colorized_echo blue "Importing backup data..."
            export PGPASSWORD="$POSTGRES_PASSWORD"

            if docker exec -i "$container_name" psql -U postgres -d postgres < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                colorized_echo green "✓ $db_type database restored successfully."
            else
                colorized_echo red "❌ Failed to restore $db_type database."
                colorized_echo yellow "Check log file for details: $log_file"
                unset PGPASSWORD
                rm -rf "$temp_restore_dir"
                exit 1
            fi

            unset PGPASSWORD
        else
            colorized_echo red "Remote $db_type restore not supported yet."
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        ;;
    *)
        colorized_echo red "Unsupported database type: $db_type"
        rm -rf "$temp_restore_dir"
        exit 1
        ;;
    esac

    # Restore configuration files if needed
    colorized_echo blue "📄 Restoring configuration files..."
    if [ -f "$temp_restore_dir/.env" ]; then
        colorized_echo blue "Creating backup of current .env file..."
        cp "$temp_restore_dir/.env" "$APP_DIR/.env.backup.$(date +%Y%m%d%H%M%S)" 2>>"$log_file"
        cp "$temp_restore_dir/.env" "$APP_DIR/.env" 2>>"$log_file"
        colorized_echo green "✓ Environment file restored"
    fi

    if [ -f "$temp_restore_dir/docker-compose.yml" ]; then
        colorized_echo blue "Creating backup of current docker-compose.yml..."
        cp "$temp_restore_dir/docker-compose.yml" "$APP_DIR/docker-compose.yml.backup.$(date +%Y%m%d%H%M%S)" 2>>"$log_file"
        cp "$temp_restore_dir/docker-compose.yml" "$APP_DIR/docker-compose.yml" 2>>"$log_file"
        colorized_echo green "✓ Docker Compose file restored"
    fi

    # Clean up
    colorized_echo blue "🧹 Cleaning up temporary files..."
    rm -rf "$temp_restore_dir"
    colorized_echo green "✓ Cleanup completed"

    # Restart pasarguard services
    colorized_echo blue "🚀 Restarting pasarguard services..."
    if [[ "$db_type" == "sqlite" ]]; then
        # For SQLite, restart all services
        up_pasarguard
        colorized_echo green "✓ All services restarted"
    else
        # For containerized databases, just restart the pasarguard app container
        $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" start pasarguard 2>/dev/null || true
        colorized_echo green "✓ PasarGuard app container restarted"
    fi

    colorized_echo green "🎉 Restore completed successfully!"
    colorized_echo green "   PasarGuard services have been restarted and are ready to use."
}

backup_command() {
    colorized_echo blue "Starting backup process..."
    
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard is not installed!"
        return 1
    fi
    
    local backup_dir="$APP_DIR/backup"
    local temp_dir="/tmp/pasarguard_backup"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local backup_file="$backup_dir/backup_$timestamp.tar.gz"
    local error_messages=()
    local log_file="/var/log/pasarguard_backup_error.log"
    >"$log_file"
    echo "Backup Log - $(date)" >>"$log_file"
    
    colorized_echo blue "Reading environment configuration..."

    if ! command -v rsync >/dev/null 2>&1; then
        detect_os
        install_package rsync
    fi

    # Remove old backups before creating new one (keep only latest)
    rm -f "$backup_dir"/backup_*.tar.gz
    mkdir -p "$backup_dir"
    
    # Clean up temp directory completely before starting
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Remove surrounding quotes from value if present
            value=$(echo "$value" | sed -E 's/^["'\''](.*)["'\'']$/\1/')
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                echo "Skipping invalid line in .env: $key=$value" >>"$log_file"
            fi
        done <"$ENV_FILE"
    else
        error_messages+=("Environment file (.env) not found.")
        echo "Environment file (.env) not found." >>"$log_file"
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        exit 1
    fi

    local db_type=""
    local sqlite_file=""
    local db_host=""
    local db_port=""
    local db_user=""
    local db_password=""
    local db_name=""
    local container_name=""

    # SQLALCHEMY_DATABASE_URL should already be loaded from .env above
    # Just log what we have
    echo "SQLALCHEMY_DATABASE_URL from environment: ${SQLALCHEMY_DATABASE_URL:-not set}" >>"$log_file"
    
    if [ -z "$SQLALCHEMY_DATABASE_URL" ]; then
        colorized_echo red "Error: SQLALCHEMY_DATABASE_URL not found in .env file or not set"
        echo "Please check $ENV_FILE for SQLALCHEMY_DATABASE_URL" >>"$log_file"
        error_messages+=("SQLALCHEMY_DATABASE_URL not found in .env file")
        colorized_echo yellow "Please check the log file for details: $log_file"
        return 1
    fi

    if [ -n "$SQLALCHEMY_DATABASE_URL" ]; then
        echo "Parsing SQLALCHEMY_DATABASE_URL: ${SQLALCHEMY_DATABASE_URL%%@*}" >>"$log_file"
        
        # Extract database type from scheme
        if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^sqlite ]]; then
        db_type="sqlite"
            # Extract SQLite file path
            # SQLite URLs: sqlite:///relative/path or sqlite:////absolute/path
            local sqlite_url_part="${SQLALCHEMY_DATABASE_URL#*://}"
            sqlite_url_part="${sqlite_url_part%%\?*}"
            sqlite_url_part="${sqlite_url_part%%#*}"
            
            # SQLite URL format:
            # sqlite:////absolute/path (4 slashes = absolute path /path)
            # After removing 'sqlite://', //absolute/path remains, convert to /absolute/path
            if [[ "$sqlite_url_part" =~ ^//(.*)$ ]]; then
                # Absolute path: sqlite:////absolute/path -> /absolute/path
                sqlite_file="/${BASH_REMATCH[1]}"
            elif [[ "$sqlite_url_part" =~ ^/(.*)$ ]]; then
                # Could be absolute (sqlite:///path) or relative depending on context
                # In practice, treat as absolute since SQLAlchemy uses 4 slashes for absolute
                sqlite_file="/${BASH_REMATCH[1]}"
            else
                # Relative path (no leading slash)
                sqlite_file="$sqlite_url_part"
            fi
        elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^(mysql|mariadb|postgresql)[^:]*:// ]]; then
            # Extract scheme to determine type
            if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^mariadb[^:]*:// ]]; then
                db_type="mariadb"
            elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^mysql[^:]*:// ]]; then
                db_type="mysql"
            elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^postgresql[^:]*:// ]]; then
                # Check if it's timescaledb by checking for specific patterns or container
                if grep -q "image: timescale/timescaledb" "$COMPOSE_FILE" 2>/dev/null; then
                    db_type="timescaledb"
                else
                    db_type="postgresql"
                fi
            fi

            # Parse connection string: scheme://[user[:password]@]host[:port]/database[?query]
            # Remove scheme prefix
            local url_part="${SQLALCHEMY_DATABASE_URL#*://}"
            # Remove query parameters if present
            url_part="${url_part%%\?*}"
            url_part="${url_part%%#*}"
            
            # Extract auth part (user:password@)
            if [[ "$url_part" =~ ^([^@]+)@(.+)$ ]]; then
                local auth_part="${BASH_REMATCH[1]}"
                url_part="${BASH_REMATCH[2]}"
                
                # Extract username and password
                if [[ "$auth_part" =~ ^([^:]+):(.+)$ ]]; then
                    db_user="${BASH_REMATCH[1]}"
                    db_password="${BASH_REMATCH[2]}"
                else
                    db_user="$auth_part"
                fi
            fi
            
            # Extract host, port, and database
            if [[ "$url_part" =~ ^([^:/]+)(:([0-9]+))?/(.+)$ ]]; then
                db_host="${BASH_REMATCH[1]}"
                db_port="${BASH_REMATCH[3]:-}"
                db_name="${BASH_REMATCH[4]}"
                
                # Remove query parameters from database name if any
                db_name="${db_name%%\?*}"
                db_name="${db_name%%#*}"
                
                # Set default ports if not specified
                if [ -z "$db_port" ]; then
                    if [[ "$db_type" =~ ^(mysql|mariadb)$ ]]; then
                        db_port="3306"
                    elif [[ "$db_type" =~ ^(postgresql|timescaledb)$ ]]; then
                        db_port="5432"
                    fi
                fi
            fi

            # For local databases, try to find container name from docker-compose
            if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
                container_name=$(find_container "$db_type")
                echo "Container name/ID for $db_type: $container_name" >>"$log_file"
            fi
        fi
    fi

    if [ -n "$db_type" ]; then
        echo "Database detected: $db_type" >>"$log_file"
        echo "Database host: ${db_host:-localhost}" >>"$log_file"
        colorized_echo blue "Database detected: $db_type"
        colorized_echo blue "Backing up database..."
        case $db_type in
        mariadb)
            if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
                if [ -z "$container_name" ]; then
                    colorized_echo red "Error: MariaDB container not found. Is the container running?"
                    echo "MariaDB container not found. Container name: ${container_name:-empty}" >>"$log_file"
                    error_messages+=("MariaDB container not found or not running.")
                else
                    local verified_container=$(check_container "$container_name" "$db_type")
                    if [ -z "$verified_container" ]; then
                        colorized_echo red "Error: MariaDB container not found or not running."
                        echo "Container not found or not running: $container_name" >>"$log_file"
                        error_messages+=("MariaDB container not found or not running.")
                    else
                        container_name="$verified_container"
                # Local Docker container
                # Try root user with MYSQL_ROOT_PASSWORD first for all databases backup
                if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
                    colorized_echo blue "Backing up all MariaDB databases from container: $container_name (using root user)"
                    if docker exec "$container_name" mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases --ignore-database=mysql --ignore-database=performance_schema --ignore-database=information_schema --ignore-database=sys --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                        colorized_echo green "MariaDB backup completed successfully (all databases)"
                    else
                        # Fallback to SQL URL credentials for specific database
                        colorized_echo yellow "Root backup failed, falling back to app user for specific database"
                        local backup_user="${db_user:-${DB_USER:-}}"
                        local backup_password="${db_password:-${DB_PASSWORD:-}}"
                        
                        if [ -z "$backup_password" ] || [ -z "$db_name" ]; then
                            colorized_echo red "Error: Cannot fallback - missing database name or password in SQLALCHEMY_DATABASE_URL"
                            error_messages+=("MariaDB backup failed - root backup failed and fallback credentials incomplete.")
                        else
                            colorized_echo blue "Backing up MariaDB database '$db_name' from container: $container_name (using app user)"
                            if ! docker exec "$container_name" mariadb-dump -u "$backup_user" -p"$backup_password" "$db_name" --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                                colorized_echo red "MariaDB dump failed. Check log file for details."
                                error_messages+=("MariaDB dump failed.")
                            else
                                colorized_echo green "MariaDB backup completed successfully"
                            fi
                        fi
                    fi
                else
                    # No MYSQL_ROOT_PASSWORD, use SQL URL credentials for specific database
                    local backup_user="${db_user:-${DB_USER:-}}"
                    local backup_password="${db_password:-${DB_PASSWORD:-}}"
                    
                    if [ -z "$backup_password" ]; then
                        colorized_echo red "Error: Database password not found. Check MYSQL_ROOT_PASSWORD or SQLALCHEMY_DATABASE_URL in .env"
                        error_messages+=("MariaDB password not found.")
                    elif [ -z "$db_name" ]; then
                        colorized_echo red "Error: Database name not found in SQLALCHEMY_DATABASE_URL"
                        error_messages+=("MariaDB database name not found.")
                    else
                        colorized_echo blue "Backing up MariaDB database '$db_name' from container: $container_name (using app user)"
                        if ! docker exec "$container_name" mariadb-dump -u "$backup_user" -p"$backup_password" "$db_name" --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                            colorized_echo red "MariaDB dump failed. Check log file for details."
                            error_messages+=("MariaDB dump failed.")
                        else
                            colorized_echo green "MariaDB backup completed successfully"
                        fi
                    fi
                fi
                    fi
                fi
            else
                # Remote database - would need mariadb-client installed
                colorized_echo red "Remote MariaDB backup not yet supported. Please use local database or install mariadb-client."
                error_messages+=("Remote MariaDB backup not yet supported. Please use local database or install mariadb-client.")
            fi
            ;;
        mysql)
            if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
                if [ -z "$container_name" ]; then
                    colorized_echo red "Error: MySQL container not found. Is the container running?"
                    echo "MySQL container not found. Container name: ${container_name:-empty}" >>"$log_file"
                    error_messages+=("MySQL container not found or not running.")
                else
                    local verified_container=$(check_container "$container_name" "$db_type")
                    if [ -z "$verified_container" ]; then
                        colorized_echo red "Error: MySQL/MariaDB container not found or not running."
                        echo "Container not found or not running: $container_name" >>"$log_file"
                        error_messages+=("MySQL/MariaDB container not found or not running.")
                    else
                        container_name="$verified_container"
                            # Check if this is actually a MariaDB container (try mariadb-dump first)
                            local is_mariadb=false
                            if docker exec "$container_name" mariadb-dump --version >/dev/null 2>&1; then
                                is_mariadb=true
                            fi
                            
                    # Local Docker container
                    # Try root user with MYSQL_ROOT_PASSWORD first for all databases backup
                    if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
                                # Choose command based on whether it's MariaDB or MySQL
                                local mysql_cmd="mysql"
                                local dump_cmd="mysqldump"
                                local db_type_name="MySQL"
                                if [ "$is_mariadb" = true ]; then
                                    mysql_cmd="mariadb"
                                    dump_cmd="mariadb-dump"
                                    db_type_name="MariaDB"
                                fi
                                
                                colorized_echo blue "Backing up all $db_type_name databases from container: $container_name (using root user)"
                                databases=$(docker exec "$container_name" "$mysql_cmd" -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;" 2>>"$log_file" | grep -Ev "^(Database|mysql|performance_schema|information_schema|sys)$")
                        if [ -z "$databases" ]; then
                            colorized_echo yellow "No user databases found, falling back to specific database backup"
                            # Fallback to SQL URL credentials
                            local backup_user="${db_user:-${DB_USER:-}}"
                            local backup_password="${db_password:-${DB_PASSWORD:-}}"
                            
                            if [ -z "$backup_password" ] || [ -z "$db_name" ]; then
                                colorized_echo red "Error: Cannot fallback - missing database name or password in SQLALCHEMY_DATABASE_URL"
                                error_messages+=("MySQL backup failed - no databases found and fallback credentials incomplete.")
                            else
                                        colorized_echo blue "Backing up $db_type_name database '$db_name' from container: $container_name (using app user)"
                                        if ! docker exec "$container_name" "$dump_cmd" -u "$backup_user" -p"$backup_password" "$db_name" --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                                            colorized_echo red "$db_type_name dump failed. Check log file for details."
                                            error_messages+=("$db_type_name dump failed.")
                                        else
                                            colorized_echo green "$db_type_name backup completed successfully"
                                        fi
                                    fi
                                elif ! docker exec "$container_name" "$dump_cmd" -u root -p"$MYSQL_ROOT_PASSWORD" --databases $databases --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                            # Root backup failed, fallback to SQL URL credentials
                            colorized_echo yellow "Root backup failed, falling back to app user for specific database"
                            local backup_user="${db_user:-${DB_USER:-}}"
                            local backup_password="${db_password:-${DB_PASSWORD:-}}"
                            
                            if [ -z "$backup_password" ] || [ -z "$db_name" ]; then
                                colorized_echo red "Error: Cannot fallback - missing database name or password in SQLALCHEMY_DATABASE_URL"
                                error_messages+=("MySQL backup failed - root backup failed and fallback credentials incomplete.")
                            else
                                        colorized_echo blue "Backing up $db_type_name database '$db_name' from container: $container_name (using app user)"
                                        if ! docker exec "$container_name" "$dump_cmd" -u "$backup_user" -p"$backup_password" "$db_name" --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                                            colorized_echo red "$db_type_name dump failed. Check log file for details."
                                            error_messages+=("$db_type_name dump failed.")
                                        else
                                            colorized_echo green "$db_type_name backup completed successfully"
                                        fi
                            fi
                        else
                                    colorized_echo green "$db_type_name backup completed successfully (all databases)"
                        fi
                    else
                        # No MYSQL_ROOT_PASSWORD, use SQL URL credentials for specific database
                        local backup_user="${db_user:-${DB_USER:-}}"
                        local backup_password="${db_password:-${DB_PASSWORD:-}}"
                                local dump_cmd="mysqldump"
                                local db_type_name="MySQL"
                                if [ "$is_mariadb" = true ]; then
                                    dump_cmd="mariadb-dump"
                                    db_type_name="MariaDB"
                                fi
                        
                        if [ -z "$backup_password" ]; then
                            colorized_echo red "Error: Database password not found. Check MYSQL_ROOT_PASSWORD or SQLALCHEMY_DATABASE_URL in .env"
                            error_messages+=("MySQL password not found.")
                        elif [ -z "$db_name" ]; then
                            colorized_echo red "Error: Database name not found in SQLALCHEMY_DATABASE_URL"
                            error_messages+=("MySQL database name not found.")
                        else
                                    colorized_echo blue "Backing up $db_type_name database '$db_name' from container: $container_name (using app user)"
                                    if ! docker exec "$container_name" "$dump_cmd" -u "$backup_user" -p"$backup_password" "$db_name" --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                                        colorized_echo red "$db_type_name dump failed. Check log file for details."
                                        error_messages+=("$db_type_name dump failed.")
                                    else
                                        colorized_echo green "$db_type_name backup completed successfully"
                                    fi
                                fi
                        fi
                    fi
                fi
            else
                # Remote database - would need mysql-client installed
                colorized_echo red "Remote MySQL backup not yet supported. Please use local database or install mysql-client."
                error_messages+=("Remote MySQL backup not yet supported. Please use local database or install mysql-client.")
            fi
            ;;
        postgresql)
            if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
                if [ -z "$container_name" ]; then
                    colorized_echo red "Error: PostgreSQL container not found. Is the container running?"
                    echo "PostgreSQL container not found. Container name: ${container_name:-empty}" >>"$log_file"
                    error_messages+=("PostgreSQL container not found or not running.")
                else
                    local verified_container=$(check_container "$container_name" "$db_type")
                    if [ -z "$verified_container" ]; then
                        colorized_echo red "Error: PostgreSQL container not found or not running."
                        echo "Container not found or not running: $container_name" >>"$log_file"
                        error_messages+=("PostgreSQL container not found or not running.")
                    else
                        container_name="$verified_container"
                # Local Docker container
                # Try postgres superuser with DB_PASSWORD first for pg_dumpall (all databases)
                if [ -n "${DB_PASSWORD:-}" ]; then
                    colorized_echo blue "Backing up all PostgreSQL databases from container: $container_name (using postgres superuser)"
                    export PGPASSWORD="$DB_PASSWORD"
                    if docker exec "$container_name" pg_dumpall -U postgres >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                        colorized_echo green "PostgreSQL backup completed successfully (all databases)"
                        unset PGPASSWORD
                    else
                        # Fallback to pg_dump with SQL URL credentials
                        unset PGPASSWORD
                        colorized_echo yellow "pg_dumpall failed, falling back to pg_dump for specific database"
                        local backup_user="${db_user:-${DB_USER:-postgres}}"
                        local backup_password="${db_password:-${DB_PASSWORD:-}}"
                        
                        if [ -z "$backup_password" ] || [ -z "$db_name" ]; then
                            colorized_echo red "Error: Cannot fallback - missing database name or password in SQLALCHEMY_DATABASE_URL"
                            error_messages+=("PostgreSQL backup failed - pg_dumpall failed and fallback credentials incomplete.")
                        else
                            colorized_echo blue "Backing up PostgreSQL database '$db_name' from container: $container_name (using app user)"
                            export PGPASSWORD="$backup_password"
                            if ! docker exec "$container_name" pg_dump -U "$backup_user" -d "$db_name" --clean --if-exists >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                                colorized_echo red "PostgreSQL dump failed. Check log file for details."
                                error_messages+=("PostgreSQL dump failed.")
                            else
                                colorized_echo green "PostgreSQL backup completed successfully"
                            fi
                            unset PGPASSWORD
                        fi
                    fi
                else
                    # No DB_PASSWORD, use SQL URL credentials for pg_dump
                    local backup_user="${db_user:-${DB_USER:-postgres}}"
                    local backup_password="${db_password:-${DB_PASSWORD:-}}"
                    
                    if [ -z "$backup_password" ]; then
                        colorized_echo red "Error: Database password not found. Check DB_PASSWORD or SQLALCHEMY_DATABASE_URL in .env"
                        error_messages+=("PostgreSQL password not found.")
                    elif [ -z "$db_name" ]; then
                        colorized_echo red "Error: Database name not found in SQLALCHEMY_DATABASE_URL"
                        error_messages+=("PostgreSQL database name not found.")
                    else
                        colorized_echo blue "Backing up PostgreSQL database '$db_name' from container: $container_name (using app user)"
                        export PGPASSWORD="$backup_password"
                        if ! docker exec "$container_name" pg_dump -U "$backup_user" -d "$db_name" --clean --if-exists >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                            colorized_echo red "PostgreSQL dump failed. Check log file for details."
                            error_messages+=("PostgreSQL dump failed.")
                        else
                            colorized_echo green "PostgreSQL backup completed successfully"
                        fi
                        unset PGPASSWORD
                    fi
                fi
                    fi
                fi
            else
                # Remote database - would need postgresql-client installed
                colorized_echo red "Remote PostgreSQL backup not yet supported. Please use local database or install postgresql-client."
                error_messages+=("Remote PostgreSQL backup not yet supported. Please use local database or install postgresql-client.")
            fi
            ;;
        timescaledb)
            if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
                if [ -z "$container_name" ]; then
                    colorized_echo red "Error: TimescaleDB container not found. Is the container running?"
                    echo "Container name detection failed. Checked for: timescaledb, postgresql" >>"$log_file"
                    error_messages+=("TimescaleDB container not found or not running.")
                else
                    # Get actual container name/ID - ps -q returns container ID, which is what we need
                    # But first verify the container exists
                    local actual_container=""
                    if docker inspect "$container_name" >/dev/null 2>&1; then
                        actual_container="$container_name"
                    else
                        # Try to find container by service name using docker compose
                        actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q timescaledb 2>/dev/null)
                        if [ -z "$actual_container" ]; then
                            actual_container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q postgresql 2>/dev/null)
                        fi
                        if [ -z "$actual_container" ]; then
                            # Try with full container name pattern
                            local full_container_name="${APP_NAME}-timescaledb-1"
                            if docker inspect "$full_container_name" >/dev/null 2>&1; then
                                actual_container="$full_container_name"
                            else
                                full_container_name="${APP_NAME}-postgresql-1"
                                if docker inspect "$full_container_name" >/dev/null 2>&1; then
                                    actual_container="$full_container_name"
                                fi
                            fi
                        fi
                    fi
                    
                    if [ -z "$actual_container" ]; then
                        colorized_echo red "Error: TimescaleDB container not found. Is the container running?"
                        echo "Container not found. Tried: $container_name and various patterns" >>"$log_file"
                        error_messages+=("TimescaleDB container not found or not running.")
                    else
                        container_name="$actual_container"
                        # Local Docker container
                        # Use SQL URL credentials directly for pg_dump (more reliable than pg_dumpall)
                        local backup_user="${db_user:-${DB_USER:-postgres}}"
                        local backup_password="${db_password:-${DB_PASSWORD:-}}"
                        
                        if [ -z "$backup_password" ]; then
                            colorized_echo red "Error: Database password not found. Check DB_PASSWORD or SQLALCHEMY_DATABASE_URL in .env"
                            error_messages+=("TimescaleDB password not found.")
                        elif [ -z "$db_name" ]; then
                            colorized_echo red "Error: Database name not found in SQLALCHEMY_DATABASE_URL"
                            error_messages+=("TimescaleDB database name not found.")
                        else
                            colorized_echo blue "Backing up TimescaleDB database '$db_name' from container: $container_name (using user: $backup_user)"
                            export PGPASSWORD="$backup_password"
                            if ! docker exec "$container_name" pg_dump -U "$backup_user" -d "$db_name" --clean --if-exists >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                                colorized_echo red "TimescaleDB dump failed. Check log file for details: $log_file"
                                error_messages+=("TimescaleDB dump failed for database '$db_name'.")
                            else
                                colorized_echo green "TimescaleDB backup completed successfully"
                            fi
                            unset PGPASSWORD
                        fi
                    fi
                fi
            else
                # Remote database - would need postgresql-client installed
                colorized_echo red "Remote TimescaleDB backup not yet supported. Please use local database or install postgresql-client."
                error_messages+=("Remote TimescaleDB backup not yet supported. Please use local database or install postgresql-client.")
            fi
            ;;
        sqlite)
            if [ -f "$sqlite_file" ]; then
                if ! cp "$sqlite_file" "$temp_dir/db_backup.sqlite" 2>>"$log_file"; then
                    error_messages+=("Failed to copy SQLite database.")
                fi
            else
                error_messages+=("SQLite database file not found at $sqlite_file.")
            fi
            ;;
        esac
    else
        colorized_echo yellow "Warning: No database type detected. Skipping database backup."
        echo "Warning: No database type detected." >>"$log_file"
        echo "SQLALCHEMY_DATABASE_URL: ${SQLALCHEMY_DATABASE_URL:-not set}" >>"$log_file"
    fi

    colorized_echo blue "Copying configuration files..."
    if ! cp "$APP_DIR/.env" "$temp_dir/" 2>>"$log_file"; then
        error_messages+=("Failed to copy .env file.")
        echo "Failed to copy .env file" >>"$log_file"
    fi
    if ! cp "$APP_DIR/docker-compose.yml" "$temp_dir/" 2>>"$log_file"; then
        error_messages+=("Failed to copy docker-compose.yml file.")
        echo "Failed to copy docker-compose.yml file" >>"$log_file"
    fi
    
    colorized_echo blue "Copying data directory..."
    # Ensure destination directory exists and is empty (already cleaned above, but be explicit)
    if [ -d "$DATA_DIR" ]; then
        if ! rsync -av --exclude 'xray-core' --exclude 'mysql' "$DATA_DIR/" "$temp_dir/pasarguard_data/" >>"$log_file" 2>&1; then
            error_messages+=("Failed to copy data directory.")
            echo "Failed to copy data directory" >>"$log_file"
        fi
    else
        colorized_echo yellow "Data directory $DATA_DIR does not exist. Skipping data directory backup."
        echo "Data directory $DATA_DIR does not exist. Skipping." >>"$log_file"
        # Create empty directory structure so tar doesn't fail
        mkdir -p "$temp_dir/pasarguard_data"
    fi

    colorized_echo blue "Creating backup archive..."
    # Verify temp_dir exists and has content before creating archive
    if [ ! -d "$temp_dir" ] || [ -z "$(ls -A "$temp_dir" 2>/dev/null)" ]; then
        error_messages+=("Temporary directory is empty or missing. Cannot create archive.")
        echo "Temporary directory is empty or missing: $temp_dir" >>"$log_file"
    elif ! tar -czf "$backup_file" -C "$temp_dir" . 2>>"$log_file"; then
        error_messages+=("Failed to create backup archive.")
        echo "Failed to create backup archive." >>"$log_file"
    else
        local backup_size=$(du -h "$backup_file" | cut -f1)
        colorized_echo green "Backup archive created: $backup_file (Size: $backup_size)"
    fi

    # Clean up temp directory after archive is created
    rm -rf "$temp_dir"

    if [ ${#error_messages[@]} -gt 0 ]; then
        colorized_echo red "Backup completed with errors:"
        for error in "${error_messages[@]}"; do
            colorized_echo red "  - $error"
        done
        colorized_echo yellow "Check log file: $log_file"
        if [ -f "$ENV_FILE" ]; then
            send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        fi
        return 1
    fi
    
    if [ ! -f "$backup_file" ]; then
        colorized_echo red "Backup file was not created. Check log file: $log_file"
        return 1
    fi
    
    colorized_echo green "Backup completed successfully: $backup_file"
    if [ -f "$ENV_FILE" ]; then
        send_backup_to_telegram "$backup_file"
    fi
}

install_pasarguard() {
    local pasarguard_version=$1
    local major_version=$2
    local database_type=$3

    FILES_URL_PREFIX="https://raw.githubusercontent.com/pasarguard/panel"
    COMPOSE_FILES_URL_PREFIX="https://raw.githubusercontent.com/pasarguard/scripts/main"

    mkdir -p "$DATA_DIR"
    mkdir -p "$APP_DIR"

    colorized_echo blue "Fetching .env file"
    curl -sL "$FILES_URL_PREFIX/main/.env.example" -o "$APP_DIR/.env"

    colorized_echo green "File saved in $APP_DIR/.env"

    if [[ "$database_type" =~ ^(mysql|mariadb|postgresql|timescaledb)$ ]]; then

        case "$database_type" in
        mysql) db_name="MySQL" ;;
        mariadb) db_name="MariaDB" ;;
        timescaledb) db_name="TimeScaleDB" ;;
        *) db_name="PostgreSQL" ;;
        esac

        echo "----------------------------"
        colorized_echo red "Using $db_name as database"
        echo "----------------------------"
        colorized_echo blue "Fetching compose file for pasarguard+$db_name"
        curl -sL "$COMPOSE_FILES_URL_PREFIX/pasarguard-$database_type.yml" -o "$COMPOSE_FILE"

        # Comment out the SQLite line
        sed -i 's~^SQLALCHEMY_DATABASE_URL = "sqlite~#&~' "$APP_DIR/.env"

        DB_NAME="pasarguard"
        DB_USER="pasarguard"
        prompt_for_db_password

        echo "" >>"$ENV_FILE"
        echo "# Database configuration" >>"$ENV_FILE"
        echo "DB_NAME=${DB_NAME}" >>"$ENV_FILE"
        echo "DB_USER=${DB_USER}" >>"$ENV_FILE"
        echo "DB_PASSWORD=${DB_PASSWORD}" >>"$ENV_FILE"

        if [[ "$database_type" == "postgresql" || "$database_type" == "timescaledb" ]]; then
            DB_PORT="5432"
            prompt_for_pgadmin_password
            echo "" >>"$ENV_FILE"
            echo "# PGAdmin configuration" >>"$ENV_FILE"
            echo "PGADMIN_EMAIL=pg@github.io" >>"$ENV_FILE"
            echo "PGADMIN_PASSWORD=${PGADMIN_PASSWORD}" >>"$ENV_FILE"
        else
            colorized_echo green "phpMyAdmin address: 0.0.0.0:8010"
            DB_PORT="3306"
            MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
            echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >>"$ENV_FILE"
        fi

        if [ "$major_version" -eq 1 ]; then
            db_driver_scheme="$([[ "$database_type" =~ ^(mysql|mariadb)$ ]] && echo 'mysql+asyncmy' || echo 'postgresql+asyncpg')"
        else
            db_driver_scheme="mysql+pymysql"
        fi

        SQLALCHEMY_DATABASE_URL="${db_driver_scheme}://${DB_USER}:${DB_PASSWORD}@127.0.0.1:${DB_PORT}/${DB_NAME}"

        echo "" >>"$ENV_FILE"
        echo "# SQLAlchemy Database URL" >>"$ENV_FILE"
        echo "SQLALCHEMY_DATABASE_URL=\"$SQLALCHEMY_DATABASE_URL\"" >>"$ENV_FILE"

    else
        echo "----------------------------"
        colorized_echo red "Using SQLite as database"
        echo "----------------------------"
        colorized_echo blue "Fetching compose file"
        curl -sL "$FILES_URL_PREFIX/main/docker-compose.yml" -o "$COMPOSE_FILE"

        sed -i 's/^# \(SQLALCHEMY_DATABASE_URL = .*\)$/\1/' "$APP_DIR/.env"

        if [ "$major_version" -eq 1 ]; then
            db_driver_scheme="sqlite+aiosqlite"
        else
            db_driver_scheme="sqlite"
        fi

        sed -i "s~\(SQLALCHEMY_DATABASE_URL = \).*~\1\"${db_driver_scheme}:////${DATA_DIR}/db.sqlite3\"~" "$APP_DIR/.env"

    fi

    # Install requested version
    if [ "$pasarguard_version" == "latest" ]; then
        yq -i '.services.pasarguard.image = "pasarguard/panel:latest"' "$COMPOSE_FILE"
    else
        yq -i ".services.pasarguard.image = \"pasarguard/panel:${pasarguard_version}\"" "$COMPOSE_FILE"
    fi
    colorized_echo green "File saved in $APP_DIR/docker-compose.yml"

    colorized_echo green "pasarguard installed successfully"
}

up_pasarguard() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" up -d --remove-orphans
}

follow_pasarguard_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

status_command() {

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi

    echo -n "Status: "
    colorized_echo green "Up"

    json=$($COMPOSE -f $COMPOSE_FILE ps -a --format=json)
    services=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .Service')
    states=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .State')
    # Print out the service names and statuses
    for i in $(seq 0 $(expr $(echo $services | wc -w) - 1)); do
        service=$(echo $services | cut -d' ' -f $(expr $i + 1))
        state=$(echo $states | cut -d' ' -f $(expr $i + 1))
        echo -n "- $service: "
        if [ "$state" == "running" ]; then
            colorized_echo green $state
        else
            colorized_echo red $state
        fi
    done
}

prompt_for_db_password() {
    colorized_echo cyan "This password will be used to access the database and should be strong."
    colorized_echo cyan "If you do not enter a custom password, a secure 20-character password will be generated automatically."

    # Prompt for password input
    read -p "Enter the password for the database (or press Enter to generate a secure default password): " DB_PASSWORD

    # Generate a 20-character password if the user leaves the input empty
    if [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        colorized_echo green "A secure password has been generated automatically."
    fi
    colorized_echo green "This password will be recorded in the .env file for future use."

}

prompt_for_pgadmin_password() {
    # Prompt for password input
    read -p "Enter the password for PGAdmin panel (or press Enter to generate a secure default password): " PGADMIN_PASSWORD

    # Generate a 20-character password if the user leaves the input empty
    if [ -z "$PGADMIN_PASSWORD" ]; then
        PGADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        colorized_echo green "A secure password has been generated automatically."
    fi
    colorized_echo green "pgAdmin address: 0.0.0.0:8010"
    colorized_echo green "pgAdmin default email: pg@github.io"
    colorized_echo green "pgAdmin Password: $PGADMIN_PASSWORD"
    colorized_echo green "This password will be recorded in the .env file for future use."

}

install_command() {
    check_running_as_root

    # Default values
    pasarguard_version="latest"
    major_version=1
    pasarguard_version_set="false"
    database_type="sqlite"

    # Parse options
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
        --database)
            database_type="$2"
            if [[ ! $database_type =~ ^(mysql|mariadb|postgresql|timescaledb)$ ]]; then
                colorized_echo red "Unsupported database type: $database_type"
                exit 1
            fi
            shift 2
            ;;
        --dev)
            if [[ "$pasarguard_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release , --dev and --version options simultaneously."
                exit 1
            fi
            pasarguard_version="dev"
            pasarguard_version_set="true"
            shift
            ;;
        --pre-release)
            if [[ "$pasarguard_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release , --dev and --version options simultaneously."
                exit 1
            fi
            pasarguard_version="pre-release"
            pasarguard_version_set="true"
            shift
            ;;
        --version)
            if [[ "$pasarguard_version_set" == "true" ]]; then
                colorized_echo red "Error: Cannot use --pre-release , --dev and --version options simultaneously."
                exit 1
            fi
            pasarguard_version="$2"
            pasarguard_version_set="true"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
    done

    # Check if pasarguard is already installed
    if is_pasarguard_installed; then
        colorized_echo red "pasarguard is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi
    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi
    detect_compose
    install_pasarguard_script
    # Function to check if a version exists in the GitHub releases
    check_version_exists() {
        local version=$1
        repo_url="https://api.github.com/repos/pasarguard/panel/releases"

        if [ "$version" == "latest" ]; then
            latest_tag=$(curl -s ${repo_url}/latest | jq -r '.tag_name')
            major_version=$(echo "$latest_tag" | sed 's/^v//' | sed 's/[^0-9]*\([0-9]*\)\..*/\1/')
            return 0
        fi

        if [ "$version" == "dev" ]; then
            major_version=0
            return 0
        fi

        if [ "$version" == "pre-release" ]; then
            local latest_stable_tag=$(curl -s "$repo_url/latest" | jq -r '.tag_name')
            local latest_pre_release_tag=$(curl -s "$repo_url" | jq -r '[.[] | select(.prerelease == true)][0].tag_name')

            if [ "$latest_stable_tag" == "null" ] && [ "$latest_pre_release_tag" == "null" ]; then
                return 1 # No releases found at all
            elif [ "$latest_stable_tag" == "null" ]; then
                pasarguard_version=$latest_pre_release_tag
            elif [ "$latest_pre_release_tag" == "null" ]; then
                pasarguard_version=$latest_stable_tag
            else
                # Compare versions using sort -V
                local chosen_version=$(printf "%s\n" "$latest_stable_tag" "$latest_pre_release_tag" | sort -V | tail -n 1)
                pasarguard_version=$chosen_version
            fi
            # Determine major_version for the chosen version
            if [[ "$pasarguard_version" =~ ^v1 ]]; then
                major_version=1
            else
                major_version=0
            fi
            return 0
        fi

        # Check if the repo contains the version tag
        if curl -s -o /dev/null -w "%{http_code}" "${repo_url}/tags/${version}" | grep -q "^200$"; then
            major_version=$(echo "$version" | sed 's/^v//' | sed 's/[^0-9]*\([0-9]*\)\..*/\1/')
            return 0
        else
            return 1
        fi
    }

    semver_regex='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
    # Check if the version is valid and exists
    if [[ "$pasarguard_version" == "latest" || "$pasarguard_version" == "dev" || "$pasarguard_version" == "pre-release" || "$pasarguard_version" =~ $semver_regex ]]; then
        if check_version_exists "$pasarguard_version"; then
            install_pasarguard "$pasarguard_version" "$major_version" "$database_type"
            echo "Installing $pasarguard_version version"
        else
            echo "Version $pasarguard_version does not exist. Please enter a valid version (e.g. v0.5.2)"
            exit 1
        fi
    else
        echo "Invalid version format. Please enter a valid version (e.g. v0.5.2)"
        exit 1
    fi
    install_completion
    up_pasarguard

    echo
    colorized_echo blue "=============================="
    colorized_echo yellow "PasarGuard doesn't have any core by default."
    colorized_echo yellow "You need at least one node for proxy connection."
    echo
    colorized_echo cyan "Want to install node on same server?"
    colorized_echo red "(Not recommended for commercial use)"
    echo
    read -p "Do you want to install PasarGuard node? (y/n) " install_node_choice
    if [[ $install_node_choice =~ ^[Yy]$ ]]; then
        install_node_command
    else
        colorized_echo yellow "Skipping node installation."
    fi

    follow_pasarguard_logs
}

install_yq() {
    if command -v yq &>/dev/null; then
        colorized_echo green "yq is already installed."
        return
    fi

    identify_the_operating_system_and_architecture

    local base_url="https://github.com/mikefarah/yq/releases/latest/download"
    local yq_binary=""

    case "$ARCH" in
    '64' | 'x86_64')
        yq_binary="yq_linux_amd64"
        ;;
    'arm32-v7a' | 'arm32-v6' | 'arm32-v5' | 'armv7l')
        yq_binary="yq_linux_arm"
        ;;
    'arm64-v8a' | 'aarch64')
        yq_binary="yq_linux_arm64"
        ;;
    '32' | 'i386' | 'i686')
        yq_binary="yq_linux_386"
        ;;
    *)
        colorized_echo red "Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac

    local yq_url="${base_url}/${yq_binary}"
    colorized_echo blue "Downloading yq from ${yq_url}..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        colorized_echo yellow "Neither curl nor wget is installed. Attempting to install curl."
        install_package curl || {
            colorized_echo red "Failed to install curl. Please install curl or wget manually."
            exit 1
        }
    fi

    if command -v curl &>/dev/null; then
        if curl -L "$yq_url" -o /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using curl. Please check your internet connection."
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if wget -O /usr/local/bin/yq "$yq_url"; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using wget. Please check your internet connection."
            exit 1
        fi
    fi

    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi

    hash -r

    if command -v yq &>/dev/null; then
        colorized_echo green "yq is ready to use."
    elif [ -x "/usr/local/bin/yq" ]; then

        colorized_echo yellow "yq is installed at /usr/local/bin/yq but not found in PATH."
        colorized_echo yellow "You can add /usr/local/bin to your PATH environment variable."
    else
        colorized_echo red "yq installation failed. Please try again or install manually."
        exit 1
    fi
}

down_pasarguard() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" down
}

show_pasarguard_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs
}

follow_pasarguard_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

pasarguard_cli() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" exec -e CLI_PROG_NAME="pasarguard cli" pasarguard pasarguard-cli "$@"
}

pasarguard_tui() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" exec -e TUI_PROG_NAME="pasarguard tui" pasarguard pasarguard-tui "$@"
}


is_pasarguard_up() {
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

uninstall_command() {
    check_running_as_root
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    read -p "Do you really want to uninstall pasarguard? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi

    detect_compose
    if is_pasarguard_up; then
        down_pasarguard
    fi
    uninstall_completion
    uninstall_pasarguard_script
    uninstall_pasarguard
    uninstall_pasarguard_docker_images

    read -p "Do you want to remove pasarguard's data files too ($DATA_DIR)? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo green "pasarguard uninstalled successfully"
    else
        uninstall_pasarguard_data_files
        colorized_echo green "pasarguard uninstalled successfully"
    fi
}

uninstall_pasarguard_script() {
    if [ -f "/usr/local/bin/pasarguard" ]; then
        colorized_echo yellow "Removing pasarguard script"
        rm "/usr/local/bin/pasarguard"
    fi
}

uninstall_pasarguard() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_pasarguard_docker_images() {
    images=$(docker images | grep pasarguard | awk '{print $3}')

    if [ -n "$images" ]; then
        colorized_echo yellow "Removing Docker images of pasarguard"
        for image in $images; do
            if docker rmi "$image" >/dev/null 2>&1; then
                colorized_echo yellow "Image $image removed"
            fi
        done
    fi
}

uninstall_pasarguard_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

restart_command() {
    help() {
        colorized_echo red "Usage: pasarguard restart [options]"
        echo
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }

    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        -n | --no-logs)
            no_logs=true
            ;;
        -h | --help)
            help
            exit 0
            ;;
        *)
            echo "Error: Invalid option: $1" >&2
            help
            exit 0
            ;;
        esac
        shift
    done

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    down_pasarguard
    up_pasarguard
    if [ "$no_logs" = false ]; then
        follow_pasarguard_logs
    fi
    colorized_echo green "pasarguard successfully restarted!"
}
logs_command() {
    help() {
        colorized_echo red "Usage: pasarguard logs [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-follow   do not show follow logs"
    }

    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        -n | --no-follow)
            no_follow=true
            ;;
        -h | --help)
            help
            exit 0
            ;;
        *)
            echo "Error: Invalid option: $1" >&2
            help
            exit 0
            ;;
        esac
        shift
    done

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard is not up."
        exit 1
    fi

    if [ "$no_follow" = true ]; then
        show_pasarguard_logs
    else
        follow_pasarguard_logs
    fi
}

down_command() {

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard's already down"
        exit 1
    fi

    down_pasarguard
}

cli_command() {
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard is not up."
        exit 1
    fi

    pasarguard_cli "$@"
}

tui_command() {
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_pasarguard_up; then
        colorized_echo red "pasarguard is not up."
        exit 1
    fi

    pasarguard_tui "$@"
}

up_command() {
    help() {
        colorized_echo red "Usage: pasarguard up [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }

    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        -n | --no-logs)
            no_logs=true
            ;;
        -h | --help)
            help
            exit 0
            ;;
        *)
            echo "Error: Invalid option: $1" >&2
            help
            exit 0
            ;;
        esac
        shift
    done

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    if is_pasarguard_up; then
        colorized_echo red "pasarguard's already up"
        exit 1
    fi

    up_pasarguard
    if [ "$no_logs" = false ]; then
        follow_pasarguard_logs
    fi
}

update_command() {
    check_running_as_root
    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard's not installed!"
        exit 1
    fi

    detect_compose

    update_pasarguard_script
    uninstall_completion
    install_completion
    colorized_echo blue "Pulling latest version"
    update_pasarguard

    colorized_echo blue "Restarting pasarguard's services"
    down_pasarguard
    up_pasarguard

    colorized_echo blue "pasarguard updated successfully"
}

update_pasarguard_script() {
    FETCH_REPO="pasarguard/scripts"
    SCRIPT_URL="https://github.com/$FETCH_REPO/raw/main/pasarguard.sh"
    colorized_echo blue "Updating pasarguard script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/pasarguard
    colorized_echo green "pasarguard script updated successfully"
}

update_pasarguard() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull
}

check_editor() {
    if [ -z "$EDITOR" ]; then
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

edit_command() {
    detect_os
    check_editor
    if [ -f "$COMPOSE_FILE" ]; then
        $EDITOR "$COMPOSE_FILE"
    else
        colorized_echo red "Compose file not found at $COMPOSE_FILE"
        exit 1
    fi
}

edit_env_command() {
    detect_os
    check_editor
    if [ -f "$ENV_FILE" ]; then
        $EDITOR "$ENV_FILE"
    else
        colorized_echo red "Environment file not found at $ENV_FILE"
        exit 1
    fi
}

install_node_command() {
    colorized_echo blue "=============================="
    colorized_echo magenta "   Install PasarGuard Node   "
    colorized_echo blue "=============================="
    echo

    if [ "$(id -u)" = "0" ]; then
        colorized_echo blue "Running node installation with sudo..."
        sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install
    else
        colorized_echo blue "Running node installation without sudo..."
        bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install
    fi

    if [ $? -eq 0 ]; then
        colorized_echo green "Node installation completed successfully!"
    else
        colorized_echo red "Node installation failed."
        exit 1
    fi
}

generate_completion() {
    cat <<'EOF'
_pasarguard_completions()
{
    local cur cmds
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmds="up down restart status logs cli tui install update uninstall install-script install-node backup backup-service restore core-update edit edit-env help completion"
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
}
EOF
    echo "complete -F _pasarguard_completions pasarguard.sh"
    echo "complete -F _pasarguard_completions $APP_NAME"
}

install_completion() {
    local completion_dir="/etc/bash_completion.d"
    local completion_file="$completion_dir/$APP_NAME"
    mkdir -p "$completion_dir"
    generate_completion >"$completion_file"
    colorized_echo green "Bash completion installed to $completion_file"
}

uninstall_completion() {
    local completion_dir="/etc/bash_completion.d"
    local completion_file="$completion_dir/$APP_NAME"
    if [ -f "$completion_file" ]; then
        rm "$completion_file"
        colorized_echo yellow "Bash completion removed from $completion_file"
    fi
}

usage() {
    local script_name="${0##*/}"
    colorized_echo blue "=============================="
    colorized_echo magenta "           pasarguard Help"
    colorized_echo blue "=============================="
    colorized_echo cyan "Usage:"
    echo "  ${script_name} [command]"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              $(tput sgr0)– Start services"
    colorized_echo yellow "  down            $(tput sgr0)– Stop services"
    colorized_echo yellow "  restart         $(tput sgr0)– Restart services"
    colorized_echo yellow "  status          $(tput sgr0)– Show status"
    colorized_echo yellow "  logs            $(tput sgr0)– Show logs"
    colorized_echo yellow "  cli             $(tput sgr0)– pasarguard CLI"
    colorized_echo yellow "  tui             $(tput sgr0)– pasarguard TUI"
    colorized_echo yellow "  install         $(tput sgr0)– Install pasarguard"
    colorized_echo yellow "  update          $(tput sgr0)– Update to latest version"
    colorized_echo yellow "  uninstall       $(tput sgr0)– Uninstall pasarguard"
    colorized_echo yellow "  install-script  $(tput sgr0)– Install pasarguard script"
    colorized_echo yellow "  install-node    $(tput sgr0)– Install PasarGuard node"
    colorized_echo yellow "  backup          $(tput sgr0)– Manual backup launch"
    colorized_echo yellow "  backup-service  $(tput sgr0)– pasarguard Backup service to backup to TG, and a new job in crontab"
    colorized_echo yellow "  restore         $(tput sgr0)– Restore database from backup file"
    colorized_echo yellow "  edit            $(tput sgr0)– Edit docker-compose.yml (via nano or vi editor)"
    colorized_echo yellow "  edit-env        $(tput sgr0)– Edit environment file (via nano or vi editor)"
    colorized_echo yellow "  help            $(tput sgr0)– Show this help message"

    echo
    colorized_echo cyan "Directories:"
    colorized_echo magenta "  App directory: $APP_DIR"
    colorized_echo magenta "  Data directory: $DATA_DIR"
    colorized_echo blue "================================"
    echo
}

case "$1" in
up)
    shift
    up_command "$@"
    ;;
down)
    shift
    down_command "$@"
    ;;
restart)
    shift
    restart_command "$@"
    ;;
status)
    shift
    status_command "$@"
    ;;
logs)
    shift
    logs_command "$@"
    ;;
cli)
    shift
    cli_command "$@"
    ;;
tui)
    shift
    tui_command "$@"
    ;;
backup)
    shift
    backup_command "$@"
    ;;
backup-service)
    shift
    backup_service "$@"
    ;;
restore)
    shift
    restore_command "$@"
    ;;
install)
    shift
    install_command "$@"
    ;;
update)
    shift
    update_command "$@"
    ;;
uninstall)
    shift
    uninstall_command "$@"
    ;;
install-script)
    shift
    install_pasarguard_script "$@"
    ;;
install-node)
    shift
    install_node_command "$@"
    ;;
edit)
    shift
    edit_command "$@"
    ;;
edit-env)
    shift
    edit_env_command "$@"
    ;;
completion)
    generate_completion
    ;;
help | *)
    usage
    ;;
esac
