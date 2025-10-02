#!/usr/bin/env bash
set -e

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

    local server_ip=$(curl -4 -s ifconfig.me || echo "Unknown IP")
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
        local caption="📦 *Backup Information*\n🌐 *Server IP*: \`${server_ip}\`\n📁 *Backup File*: \`${custom_filename}\`\n⏰ *Backup Time*: \`${backup_time}\`"
        curl -s -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$part;filename=$custom_filename" \
            -F caption="$(echo -e "$caption" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g')" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument" >/dev/null 2>&1 &&
            colorized_echo green "Backup part $custom_filename successfully sent to Telegram." ||
            colorized_echo red "Failed to send backup part $custom_filename to Telegram."
    done

    rm -rf "$split_dir"
}

send_backup_error_to_telegram() {
    local error_messages=$1
    local log_file=$2
    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local error_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local message="⚠️ *Backup Error Notification*\n"
    message+="🌐 *Server IP*: \`${server_ip}\`\n"
    message+="❌ *Errors*:\n\`${error_messages//_/\\_}\`\n"
    message+="⏰ *Time*: \`${error_time}\`"

    message=$(echo -e "$message" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g;s/(/\\(/g;s/)/\\)/g')

    local max_length=1000
    if [ ${#message} -gt $max_length ]; then
        message="${message:0:$((max_length - 50))}...\n\`[Message truncated]\`"
    fi

    curl -s -X POST "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendMessage" \
        -d chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
        -d parse_mode="MarkdownV2" \
        -d text="$message" >/dev/null 2>&1 &&
        colorized_echo green "Backup error notification sent to Telegram." ||
        colorized_echo red "Failed to send error notification to Telegram."

    if [ -f "$log_file" ]; then
        response=$(curl -s -w "%{http_code}" -o /tmp/tg_response.json \
            -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$log_file;filename=backup_error.log" \
            -F caption="📜 *Backup Error Log* - ${error_time}" \
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
        echo "1. Reconfigure Backup Service"
        echo "2. Remove Backup Service"
        echo "3. Exit"
        read -p "Enter your choice (1-3): " user_choice

        case $user_choice in
        1)
            colorized_echo yellow "Starting reconfiguration..."
            remove_backup_service
            ;;
        2)
            colorized_echo yellow "Removing Backup Service..."
            remove_backup_service
            return
            ;;
        3)
            colorized_echo yellow "Exiting..."
            return
            ;;
        *)
            colorized_echo red "Invalid choice. Exiting."
            return
            ;;
        esac
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

    local backup_command="$(which bash) -c '$APP_NAME backup'"
    add_cron_job "$cron_schedule" "$backup_command"

    colorized_echo green "Backup service successfully configured."
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

backup_command() {
    local backup_dir="$APP_DIR/backup"
    local temp_dir="/tmp/pasarguard_backup"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local backup_file="$backup_dir/backup_$timestamp.tar.gz"
    local error_messages=()
    local log_file="/var/log/pasarguard_backup_error.log"
    >"$log_file"
    echo "Backup Log - $(date)" >"$log_file"

    if ! command -v rsync >/dev/null 2>&1; then
        detect_os
        install_package rsync
    fi

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"
    mkdir -p "$temp_dir"

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
    if grep -q "image: mariadb" "$COMPOSE_FILE"; then
        db_type="mariadb"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q mariadb || echo "mariadb")

    elif grep -q "image: mysql" "$COMPOSE_FILE"; then
        db_type="mysql"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q mysql || echo "mysql")

    elif grep -q "image: postgres" "$COMPOSE_FILE"; then
        db_type="postgresql"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q postgresql || echo "postgresql")

    elif grep -q "image: timescale/timescaledb" "$COMPOSE_FILE"; then
        db_type="timescaledb"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q timescaledb || echo "timescaledb")

    elif grep -q "SQLALCHEMY_DATABASE_URL = .*sqlite" "$ENV_FILE"; then
        db_type="sqlite"
        sqlite_file=$(grep -Po '(?<=SQLALCHEMY_DATABASE_URL = "sqlite:////).*"' "$ENV_FILE" | tr -d '"')
        if [[ ! "$sqlite_file" =~ ^/ ]]; then
            sqlite_file="/$sqlite_file"
        fi

    fi

    if [ -n "$db_type" ]; then
        echo "Database detected: $db_type" >>"$log_file"
        case $db_type in
        mariadb)
            if ! docker exec "$container_name" mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases --ignore-database=mysql --ignore-database=performance_schema --ignore-database=information_schema --ignore-database=sys --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                error_messages+=("MariaDB dump failed.")
            fi
            ;;
        mysql)
            databases=$(docker exec "$container_name" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;" 2>>"$log_file" | grep -Ev "^(Database|mysql|performance_schema|information_schema|sys)$")
            if [ -z "$databases" ]; then
                echo "No user databases found to backup" >>"$log_file"
            elif ! docker exec "$container_name" mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --databases $databases --events --triggers >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                error_messages+=("MySQL dump failed.")
            fi
            ;;
        postgresql)
            if ! docker exec "$container_name" pg_dumpall -U "$DB_USER" >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                error_messages+=("PostgreSQL dump failed.")
            fi
            ;;
        timescaledb)
            if ! docker exec "$container_name" pg_dumpall -U "$DB_USER" >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                error_messages+=("TimescaleDB dump failed.")
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
    fi

    cp "$APP_DIR/.env" "$temp_dir/" 2>>"$log_file"
    cp "$APP_DIR/docker-compose.yml" "$temp_dir/" 2>>"$log_file"
    rsync -av --exclude 'xray-core' --exclude 'mysql' "$DATA_DIR/" "$temp_dir/pasarguard_data/" >>"$log_file" 2>&1

    if ! tar -czf "$backup_file" -C "$temp_dir" .; then
        error_messages+=("Failed to create backup archive.")
        echo "Failed to create backup archive." >>"$log_file"
    fi

    rm -rf "$temp_dir"

    if [ ${#error_messages[@]} -gt 0 ]; then
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        return
    fi
    colorized_echo green "Backup created: $backup_file"
    send_backup_to_telegram "$backup_file"
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

generate_completion() {
    cat <<'EOF'
_pasarguard_completions()
{
    local cur cmds
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmds="up down restart status logs cli tui install update uninstall install-script backup backup-service core-update edit edit-env help completion"
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
    colorized_echo yellow "  backup          $(tput sgr0)– Manual backup launch"
    colorized_echo yellow "  backup-service  $(tput sgr0)– pasarguard Backupservice to backup to TG, and a new job in crontab"
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
