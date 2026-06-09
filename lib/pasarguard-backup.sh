#!/usr/bin/env bash

mask_telegram_bot_key() {
    local secret="$1"
    local length=${#secret}

    if [ -z "$secret" ]; then
        printf '%s\n' ""
        return 0
    fi

    if [ "$length" -le 6 ]; then
        printf '****%s\n' "$secret"
        return 0
    fi

    printf '****%s\n' "${secret: -6}"
}

filter_backup_cron_entries() {
    local source_file="$1"
    local target_file="$2"

    grep -F -v "# pasarguard-backup-service" "$source_file" >"$target_file" || true
}

is_local_db_host() {
    local host="${1:-}"

    host="${host#[}"
    host="${host%]}"
    host="${host%.}"
    host="${host,,}"

    [[ -z "$host" ]] && return 1
    [[ "$host" == "localhost" ]] && return 0
    [[ "$host" == "localhost.localdomain" ]] && return 0
    [[ "$host" == "127" ]] && return 0
    [[ "$host" =~ ^127\.([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] && return 0
    [[ "$host" == "::1" ]] && return 0
    [[ "$host" == "0:0:0:0:0:0:0:1" ]] && return 0

    return 1
}

send_backup_to_telegram() {
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            value=$(echo "$value" | sed -E 's/^["'"'"'](.*)["'"'"']$/\1/')
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

    local proxy_url=""
    local curl_proxy_args=()
    if proxy_url=$(get_backup_proxy_url); then
        curl_proxy_args=(--proxy "$proxy_url")
    fi

    local server_ip="$(curl "${curl_proxy_args[@]}" -4 -s --max-time 5 ifconfig.me 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')"
    if [ -z "$server_ip" ]; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$server_ip" ]; then
        server_ip="Unknown IP"
    fi
    local backup_dir="$APP_DIR/backup"
    local latest_backup=""
    latest_backup=$(find "$backup_dir" -maxdepth 1 -type f \
        \( -name 'backup_*.tar.gz' -o -name 'backup_*.zip' -o -name 'backup_*.z[0-9][0-9]' -o -name 'backup_*.part[0-9][0-9].zip' \) \
        -printf '%T@ %f\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)

    if [ -z "$latest_backup" ]; then
        colorized_echo red "No backups found to send."
        return 1
    fi

    local backup_paths=()
    local uploaded_files=()
    local cleanup_dir=""
    local extraction_mode="zip"

    local telegram_split_bytes=$((49 * 1000 * 1000))

    if [[ "$latest_backup" =~ \.part[0-9]{2}\.zip$ ]]; then
        extraction_mode="part_zip"
        local base="${latest_backup%%.part*}"
        while IFS= read -r file; do
            [ -n "$file" ] && backup_paths+=("$file")
        done < <(find "$backup_dir" -maxdepth 1 -type f -name "${base}.part*.zip" | sort)
        if [ ${#backup_paths[@]} -eq 0 ]; then
            colorized_echo red "Incomplete backup parts for $base"
            return 1
        fi
    elif [[ "$latest_backup" =~ \.z[0-9]{2}$ ]]; then
        extraction_mode="split_zip"
        local base="${latest_backup%.z??}"
        while IFS= read -r file; do
            [ -n "$file" ] && backup_paths+=("$file")
        done < <(find "$backup_dir" -maxdepth 1 -type f -name "${base}.z[0-9][0-9]" | sort)
        if [ -f "$backup_dir/${base}.zip" ]; then
            backup_paths+=("$backup_dir/${base}.zip")
        else
            colorized_echo red "Missing final .zip file for split archive $base"
            return 1
        fi
    elif [[ "$latest_backup" =~ \.zip$ ]]; then
        local base="${latest_backup%.zip}"
        local split_files=()
        while IFS= read -r file; do
            [ -n "$file" ] && split_files+=("$file")
        done < <(find "$backup_dir" -maxdepth 1 -type f -name "${base}.z[0-9][0-9]" | sort)
        if [ ${#split_files[@]} -gt 0 ]; then
            extraction_mode="split_zip"
            backup_paths=("${split_files[@]}")
        fi
        backup_paths+=("$backup_dir/$latest_backup")
    elif [[ "$latest_backup" =~ \.tar\.gz$ ]]; then
        extraction_mode="tar"
        cleanup_dir="/tmp/pasarguard_backup_split"
        rm -rf "$cleanup_dir"
        mkdir -p "$cleanup_dir"
        local legacy_backup="$backup_dir/$latest_backup"
        local backup_size=$(du -m "$legacy_backup" | cut -f1)
        if [ "$backup_size" -gt 49 ]; then
            colorized_echo yellow "Legacy backup is larger than 49MB. Splitting before upload..."
            split -b "$telegram_split_bytes" "$legacy_backup" "$cleanup_dir/${latest_backup}_part_"
        else
            cp "$legacy_backup" "$cleanup_dir/$latest_backup"
        fi
        while IFS= read -r file; do
            [ -n "$file" ] && backup_paths+=("$file")
        done < <(find "$cleanup_dir" -maxdepth 1 -type f -print | sort)
        if [ ${#backup_paths[@]} -eq 0 ]; then
            colorized_echo red "Failed to prepare legacy backup for upload."
            rm -rf "$cleanup_dir"
            return 1
        fi
    else
        colorized_echo red "Unsupported backup format: $latest_backup"
        return 1
    fi

    local backup_time=$(date "+%Y-%m-%d %H:%M:%S %Z")

    for part in "${backup_paths[@]}"; do
        local part_name=$(basename "$part")
        local custom_filename="$part_name"

        local escaped_server_ip=$(printf '%s' "$server_ip" | sed 's/[_*\[\]()~`>#+\-=|{}!.]/\\&/g')
        local escaped_filename=$(printf '%s' "$custom_filename" | sed 's/[_*\[\]()~`>#+\-=|{}!.]/\\&/g')
        local escaped_time=$(printf '%s' "$backup_time" | sed 's/[_*\[\]()~`>#+\-=|{}!.]/\\&/g')
        local caption="📦 *Backup Information*\n🌐 *Server IP*: \`$escaped_server_ip\`\n📁 *Backup File*: \`$escaped_filename\`\n⏰ *Backup Time*: \`$escaped_time\`"

        local response=$(curl "${curl_proxy_args[@]}" -s -w "\n%{http_code}" -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$part;filename=$custom_filename" \
            -F caption="$(printf '%b' "$caption")" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument" 2>&1)

        local http_code=$(echo "$response" | tail -n1)
        local response_body=$(echo "$response" | sed '$d')

        if [ "$http_code" == "200" ]; then
            # Check if response contains "ok":true
            if echo "$response_body" | grep -q '"ok":true'; then
                uploaded_files+=("$custom_filename")
                colorized_echo green "Backup part $custom_filename successfully sent to Telegram."
            else
                # Extract error message from Telegram response
                local error_msg=$(echo "$response_body" | grep -o '"description":"[^"]*"' | cut -d'"' -f4 || echo "Unknown error")
                colorized_echo red "Failed to send backup part $custom_filename to Telegram: $error_msg"
                echo "Telegram API status: $http_code" >&2
                echo "Telegram API Response: $response_body" >&2
            fi
        else
            local error_msg=$(echo "$response_body" | grep -o '"description":"[^"]*"' | cut -d'"' -f4 || echo "HTTP $http_code")
            colorized_echo red "Failed to send backup part $custom_filename to Telegram: $error_msg"
            echo "Telegram API Response: $response_body" >&2
        fi
    done

    if [ ${#uploaded_files[@]} -gt 0 ]; then
        local files_list=""
        for file in "${uploaded_files[@]}"; do
            files_list+="- $file"$'\n'
        done
        files_list="${files_list%$'\n'}"

        local info_message=$'📦 Backup Upload Summary\n'
        info_message+=$'──────────────────────\n'
        info_message+="🌐 Server IP: $server_ip"$'\n'
        info_message+="⏰ Time: $backup_time"$'\n'
        info_message+=$'\n✅ Files Uploaded:\n'
        info_message+="$files_list"$'\n'
        info_message+=$'\n📂 Extraction Guide:\n'
        if [ "$extraction_mode" = "part_zip" ]; then
            info_message+=$'🪟 Windows: Rebuild the archive first, e.g. copy /b backup_xxx.part01.zip+backup_xxx.part02.zip+... backup_xxx.zip, then extract backup_xxx.zip with 7-Zip.\n'
            info_message+=$'🐧 Linux: Run cat backup_xxx.part*.zip > backup_xxx.zip && unzip backup_xxx.zip.\n'
            info_message+=$'🍎 macOS: Run cat backup_xxx.part*.zip > backup_xxx.zip && unzip backup_xxx.zip.\n'
            info_message+=$'⚠️ Always download every .partNN.zip file before rebuilding the archive.'
        elif [ "$extraction_mode" = "split_zip" ]; then
            info_message+=$'🪟 Windows: Install and use 7-Zip. Place the .zip and every .zXX part together, then start extraction from the .zip file.\n'
            info_message+=$'🐧 Linux: Run unzip (e.g., unzip backup_xxx.zip) with all .zXX parts in the same directory.\n'
            info_message+=$'🍎 macOS: Use Archive Utility or run unzip backup_xxx.zip from Terminal with the .zXX parts beside the .zip file.\n'
            info_message+=$'⚠️ Always download the .zip and every .zXX part before extracting.'
        else
            info_message+=$'🪟 Windows: Extract the uploaded archive with 7-Zip.\n'
            info_message+=$'🐧 Linux: Run unzip backup_xxx.zip.\n'
            info_message+=$'🍎 macOS: Open the archive with Archive Utility or run unzip backup_xxx.zip.\n'
            info_message+=$'⚠️ Download the complete archive before extracting.'
        fi

        curl "${curl_proxy_args[@]}" -s -X POST "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendMessage" \
            -d chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -d text="$info_message" >/dev/null 2>&1 || true
    fi

    if [ -n "$cleanup_dir" ]; then
        rm -rf "$cleanup_dir"
    fi
}

send_backup_error_to_telegram() {
    local error_messages=$1
    local log_file=$2
    local proxy_url=""
    local curl_proxy_args=()
    if proxy_url=$(get_backup_proxy_url); then
        curl_proxy_args=(--proxy "$proxy_url")
    fi
    local server_ip="$(curl "${curl_proxy_args[@]}" -4 -s --max-time 5 ifconfig.me 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')"
    if [ -z "$server_ip" ]; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$server_ip" ]; then
        server_ip="Unknown IP"
    fi
    local error_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local message="⚠️ Backup Error Notification
🌐 Server IP: $server_ip
❌ Errors: $error_messages
⏰ Time: $error_time"

    local max_length=1000
    if [ ${#message} -gt $max_length ]; then
        message="${message:0:$((max_length - 25))}...
[Message truncated]"
    fi

    curl "${curl_proxy_args[@]}" -s -X POST "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendMessage" \
        -d chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
        -d text="$message" >/dev/null 2>&1 &&
        colorized_echo green "Backup error notification sent to Telegram." ||
        colorized_echo red "Failed to send error notification to Telegram."

    if [ -f "$log_file" ]; then

        response=$(curl "${curl_proxy_args[@]}" -s -w "%{http_code}" -o /tmp/tg_response.json \
            -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$log_file;filename=backup_error.log" \
            -F caption="📜 Backup Error Log - $error_time" \
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
    local backup_proxy_enabled="false"
    local backup_proxy_url=""

    colorized_echo blue "====================================="
    colorized_echo blue "      Welcome to Backup Service      "
    colorized_echo blue "====================================="

    if grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        while true; do
            telegram_bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
            telegram_chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
            cron_schedule=$(awk -F'=' '/^BACKUP_CRON_SCHEDULE=/ {print $2}' "$ENV_FILE" | tr -d '"')
            backup_proxy_enabled=$(awk -F'=' '/^BACKUP_PROXY_ENABLED=/ {print $2}' "$ENV_FILE")
            backup_proxy_url=$(awk -F'=' '/^BACKUP_PROXY_URL=/ {print substr($0, index($0,"=")+1); exit}' "$ENV_FILE")
            backup_proxy_url=$(echo "$backup_proxy_url" | sed -e 's/^"//' -e 's/"$//')
            [ -z "$backup_proxy_enabled" ] && backup_proxy_enabled="false"
            local masked_telegram_bot_key=""

            if [[ "$cron_schedule" == "0 0 * * *" ]]; then
                interval_hours=24
            else
                interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
            fi

            masked_telegram_bot_key=$(mask_telegram_bot_key "$telegram_bot_key")

            colorized_echo green "====================================="
            colorized_echo green "Current Backup Configuration:"
            colorized_echo cyan "Telegram Bot API Key: $masked_telegram_bot_key"
            colorized_echo cyan "Telegram Chat ID: $telegram_chat_id"
            colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
            colorized_echo cyan "Database Mode: $(get_backup_database_mode_label)"
            if [[ "$backup_proxy_enabled" == "true" && -n "$backup_proxy_url" ]]; then
                colorized_echo cyan "Proxy: Enabled ($backup_proxy_url)"
            else
                colorized_echo cyan "Proxy: Disabled"
            fi
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

    while true; do
        read -p "Do you need to use an HTTP/SOCKS proxy for Telegram backups? (y/N): " proxy_choice
        case "$proxy_choice" in
        [Yy]*)
            backup_proxy_enabled="true"
            break
            ;;
        [Nn]*|"")
            backup_proxy_enabled="false"
            break
            ;;
        *)
            colorized_echo red "Invalid choice. Please enter y or n."
            ;;
        esac
    done

    if [ "$backup_proxy_enabled" = "true" ]; then
        while true; do
            read -p "Enter proxy URL (e.g. http://127.0.0.1:8080 or socks5://127.0.0.1:1080): " backup_proxy_url
            backup_proxy_url=$(echo "$backup_proxy_url" | xargs)
            if [ -z "$backup_proxy_url" ]; then
                colorized_echo red "Proxy URL cannot be empty."
                continue
            fi
            if is_valid_proxy_url "$backup_proxy_url"; then
                break
            else
                colorized_echo red "Invalid proxy URL. Supported prefixes: http://, https://, socks5://, socks5h://, socks4://."
            fi
        done
    else
        backup_proxy_url=""
    fi

    prompt_backup_database_mode

    sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/^BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"
    sed -i '/^BACKUP_PROXY_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_PROXY_URL/d' "$ENV_FILE"
    sed -i '/^BACKUP_CUSTOM_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_DB_TYPE/d' "$ENV_FILE"
    sed -i '/^BACKUP_DB_CONTAINER/d' "$ENV_FILE"

    {
        echo ""
        echo "# Backup service configuration"
        echo "BACKUP_SERVICE_ENABLED=true"
        echo "BACKUP_TELEGRAM_BOT_KEY=$telegram_bot_key"
        echo "BACKUP_TELEGRAM_CHAT_ID=$telegram_chat_id"
        echo "BACKUP_CRON_SCHEDULE=\"$cron_schedule\""
        echo "BACKUP_PROXY_ENABLED=$backup_proxy_enabled"
        echo "BACKUP_PROXY_URL=\"$backup_proxy_url\""
        echo "BACKUP_CUSTOM_ENABLED=$backup_custom_enabled"
    } >>"$ENV_FILE"

    if [ "$backup_custom_enabled" = "true" ]; then
        {
            echo "BACKUP_DB_TYPE=$backup_db_type"
            echo "BACKUP_DB_CONTAINER=$backup_db_container"
        } >>"$ENV_FILE"
    fi

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
    local filtered_cron="${temp_cron}.tmp"

    crontab -l 2>/dev/null >"$temp_cron" || true
    filter_backup_cron_entries "$temp_cron" "$filtered_cron"
    mv "$filtered_cron" "$temp_cron"
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
    local backup_proxy_enabled=$(awk -F'=' '/^BACKUP_PROXY_ENABLED=/ {print $2}' "$ENV_FILE")
    local backup_proxy_url=$(awk -F'=' '/^BACKUP_PROXY_URL=/ {print substr($0, index($0,"=")+1); exit}' "$ENV_FILE")
    backup_proxy_url=$(echo "$backup_proxy_url" | sed -e 's/^"//' -e 's/"$//')
    [ -z "$backup_proxy_enabled" ] && backup_proxy_enabled="false"
    local interval_hours=""
    local masked_telegram_bot_key=""

    if [[ "$cron_schedule" == "0 0 * * *" ]]; then
        interval_hours=24
    else
        interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
    fi

    masked_telegram_bot_key=$(mask_telegram_bot_key "$telegram_bot_key")

    colorized_echo blue "====================================="
    colorized_echo blue "      Backup Service Details         "
    colorized_echo blue "====================================="
    colorized_echo green "Status: Enabled"
    colorized_echo cyan "Telegram Bot API Key: $masked_telegram_bot_key"
    colorized_echo cyan "Telegram Chat ID: $telegram_chat_id"
    colorized_echo cyan "Cron Schedule: $cron_schedule"
    if [[ "$interval_hours" -eq 24 ]]; then
        colorized_echo cyan "Backup Interval: Daily at midnight (every 24 hours)"
    else
        colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
    fi
    colorized_echo cyan "Database Mode: $(get_backup_database_mode_label)"
    if [[ "$backup_proxy_enabled" == "true" && -n "$backup_proxy_url" ]]; then
        colorized_echo cyan "Proxy: Enabled ($backup_proxy_url)"
    else
        colorized_echo cyan "Proxy: Disabled"
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
    local backup_proxy_enabled=$(awk -F'=' '/^BACKUP_PROXY_ENABLED=/ {print $2}' "$ENV_FILE")
    local backup_proxy_url=$(awk -F'=' '/^BACKUP_PROXY_URL=/ {print substr($0, index($0,"=")+1); exit}' "$ENV_FILE")
    backup_proxy_url=$(echo "$backup_proxy_url" | sed -e 's/^"//' -e 's/"$//')
    [ -z "$backup_proxy_enabled" ] && backup_proxy_enabled="false"
    local interval_hours=""
    local masked_telegram_bot_key=""

    if [[ "$cron_schedule" == "0 0 * * *" ]]; then
        interval_hours=24
    else
        interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
    fi

    masked_telegram_bot_key=$(mask_telegram_bot_key "$telegram_bot_key")

    colorized_echo blue "====================================="
    colorized_echo blue "      Edit Backup Service            "
    colorized_echo blue "====================================="
    echo "Current configuration:"
    local proxy_display="Disabled"
    if [[ "$backup_proxy_enabled" == "true" && -n "$backup_proxy_url" ]]; then
        proxy_display="Enabled ($backup_proxy_url)"
    fi
    colorized_echo cyan "1. Telegram Bot API Key: $masked_telegram_bot_key"
    colorized_echo cyan "2. Telegram Chat ID: $telegram_chat_id"
    colorized_echo cyan "3. Backup Interval: Every $interval_hours hour(s)"
    colorized_echo cyan "4. Proxy: $proxy_display"
    colorized_echo cyan "5. Database Backup Mode: $(get_backup_database_mode_label)"
    colorized_echo yellow "6. Cancel"
    echo ""
    read -p "Which setting would you like to edit? (1-6): " edit_choice

    case $edit_choice in
    1)
        while true; do
            printf "Enter new Telegram bot API key [current: %s]: " "$masked_telegram_bot_key"
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
            local filtered_cron="${temp_cron}.tmp"
            crontab -l 2>/dev/null >"$temp_cron" || true
            filter_backup_cron_entries "$temp_cron" "$filtered_cron"
            mv "$filtered_cron" "$temp_cron"
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
        local new_proxy_enabled="$backup_proxy_enabled"
        local new_proxy_url="$backup_proxy_url"
        while true; do
            read -p "Enable proxy for Telegram backups? (y/N) [current: $proxy_display]: " proxy_choice
            case "$proxy_choice" in
            [Yy]*)
                new_proxy_enabled="true"
                break
                ;;
            [Nn]*|"")
                new_proxy_enabled="false"
                break
                ;;
            *)
                colorized_echo red "Invalid choice. Please enter y or n."
                ;;
            esac
        done

        if [ "$new_proxy_enabled" = "true" ]; then
            while true; do
                read -p "Enter proxy URL (e.g. http://127.0.0.1:8080 or socks5://127.0.0.1:1080) [current: $backup_proxy_url]: " input_proxy_url
                if [ -z "$input_proxy_url" ]; then
                    if [ -n "$backup_proxy_url" ]; then
                        input_proxy_url="$backup_proxy_url"
                    else
                        colorized_echo red "Proxy URL cannot be empty."
                        continue
                    fi
                fi
                input_proxy_url=$(echo "$input_proxy_url" | xargs)
                if is_valid_proxy_url "$input_proxy_url"; then
                    new_proxy_url="$input_proxy_url"
                    break
                else
                    colorized_echo red "Invalid proxy URL. Supported prefixes: http://, https://, socks5://, socks5h://, socks4://."
                fi
            done
        else
            new_proxy_url=""
        fi

        replace_or_append_env_var "BACKUP_PROXY_ENABLED" "$new_proxy_enabled"
        replace_or_append_env_var "BACKUP_PROXY_URL" "$new_proxy_url" true
        colorized_echo green "Backup proxy configuration updated successfully."
        ;;
    5)
        prompt_backup_database_mode
        save_backup_database_mode_config "$backup_custom_enabled" "$backup_db_type" "$backup_db_container"
        colorized_echo green "Database backup mode updated successfully."
        ;;
    6)
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
    sed -i '/BACKUP_PROXY_ENABLED/d' "$ENV_FILE"
    sed -i '/BACKUP_PROXY_URL/d' "$ENV_FILE"
    sed -i '/BACKUP_CUSTOM_ENABLED/d' "$ENV_FILE"
    sed -i '/BACKUP_DB_TYPE/d' "$ENV_FILE"
    sed -i '/BACKUP_DB_CONTAINER/d' "$ENV_FILE"

    local temp_cron=$(mktemp)
    local filtered_cron="${temp_cron}.tmp"
    crontab -l 2>/dev/null >"$temp_cron" || true

    filter_backup_cron_entries "$temp_cron" "$filtered_cron"
    mv "$filtered_cron" "$temp_cron"

    if crontab "$temp_cron"; then
        colorized_echo green "Backup service task removed from crontab."
    else
        colorized_echo red "Failed to update crontab. Please check manually."
    fi

    rm -f "$temp_cron"

    colorized_echo green "Backup service has been removed."
}

mask_database_password() {
    printf '%s\n' "---"
}

is_backup_custom_enabled() {
    [ "${BACKUP_CUSTOM_ENABLED:-false}" = "true" ]
}

read_backup_env_var() {
    local key="$1"
    local value=""

    if [ ! -f "$ENV_FILE" ]; then
        return 1
    fi

    value=$(awk -F= -v env_key="$key" '$1 == env_key { print substr($0, index($0, "=") + 1); exit }' "$ENV_FILE")
    value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    printf '%s\n' "$value"
}

get_backup_database_mode_label() {
    local custom_enabled=""
    local db_type=""
    local container=""
    local db_type_label=""

    custom_enabled=$(read_backup_env_var "BACKUP_CUSTOM_ENABLED" 2>/dev/null || true)
    if [ "$custom_enabled" != "true" ]; then
        printf '%s\n' "PasarGuard (SQLALCHEMY_DATABASE_URL)"
        return 0
    fi

    db_type=$(read_backup_env_var "BACKUP_DB_TYPE" 2>/dev/null || true)
    container=$(read_backup_env_var "BACKUP_DB_CONTAINER" 2>/dev/null || true)
    db_type_label=$(custom_db_type_label "$(normalize_custom_db_type "$db_type" 2>/dev/null || echo "$db_type")")

    if [ -n "$db_type" ] && [ -n "$container" ]; then
        printf 'Custom %s (%s)\n' "$db_type_label" "$container"
    elif [ -n "$container" ]; then
        printf 'Custom (%s)\n' "$container"
    else
        printf '%s\n' "Custom (incomplete configuration)"
    fi
}

save_backup_database_mode_config() {
    local enabled="$1"
    local db_type="${2:-}"
    local container="${3:-}"

    replace_or_append_env_var "BACKUP_CUSTOM_ENABLED" "$enabled"
    if [ "$enabled" = "true" ]; then
        replace_or_append_env_var "BACKUP_DB_TYPE" "$db_type"
        replace_or_append_env_var "BACKUP_DB_CONTAINER" "$container"
    else
        delete_env_var "BACKUP_DB_TYPE" "$ENV_FILE"
        delete_env_var "BACKUP_DB_CONTAINER" "$ENV_FILE"
    fi
}

prompt_backup_database_mode() {
    local mode_choice=""
    local type_choice=""
    local selected_type=""
    local container_name=""
    local running=""

    backup_custom_enabled="false"
    backup_db_type=""
    backup_db_container=""

    colorized_echo blue "====================================="
    colorized_echo blue "      Database Backup Mode           "
    colorized_echo blue "====================================="
    echo "1. PasarGuard (default - uses SQLALCHEMY_DATABASE_URL)"
    echo "2. Custom Database (backup from a specific Docker container)"
    echo ""
    colorized_echo cyan "Custom mode uses DB_NAME, DB_USER, and DB_PASSWORD from this .env file."
    echo ""
    read -p "Select database backup mode (1-2) [default: 1]: " mode_choice
    mode_choice="${mode_choice:-1}"

    case "$mode_choice" in
    2)
        backup_custom_enabled="true"
        echo ""
        echo "Select database type:"
        echo "1. MariaDB"
        echo "2. MySQL"
        echo "3. PostgreSQL"
        echo "4. TimescaleDB"
        while true; do
            read -p "Enter your choice (1-4): " type_choice
            case "$type_choice" in
            1)
                selected_type="mariadb"
                break
                ;;
            2)
                selected_type="mysql"
                break
                ;;
            3)
                selected_type="postgresql"
                break
                ;;
            4)
                selected_type="timescaledb"
                break
                ;;
            *)
                colorized_echo red "Invalid choice. Please enter 1, 2, 3, or 4."
                ;;
            esac
        done

        while true; do
            read -p "Enter the database container name or ID (e.g. pasarguard-mariadb-1): " container_name
            container_name=$(echo "$container_name" | xargs)
            if [ -z "$container_name" ]; then
                colorized_echo red "Container name cannot be empty."
                continue
            fi

            if ! docker inspect "$container_name" >/dev/null 2>&1; then
                colorized_echo red "Container '$container_name' does not exist. Please try again."
                continue
            fi

            running=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")
            if [ "$running" != "true" ]; then
                colorized_echo red "Container '$container_name' is not running. Please start it and try again."
                continue
            fi

            backup_db_type="$selected_type"
            backup_db_container="$container_name"
            colorized_echo green "Custom database mode selected: $(custom_db_type_label "$selected_type") in container '$container_name'"
            colorized_echo cyan "Credentials will be read from DB_NAME, DB_USER, and DB_PASSWORD in $ENV_FILE"
            break
        done
        ;;
    1 | "")
        backup_custom_enabled="false"
        backup_db_type=""
        backup_db_container=""
        colorized_echo green "PasarGuard database mode selected."
        ;;
    *)
        colorized_echo red "Invalid choice. Using PasarGuard database mode."
        backup_custom_enabled="false"
        ;;
    esac
}

resolve_custom_backup_db_password() {
    local db_type="$1"

    # Standard PasarGuard .env uses DB_USER (e.g. pasarguard) + DB_PASSWORD.
    if [ -n "${DB_PASSWORD:-}" ]; then
        printf '%s\n' "$DB_PASSWORD"
        return 0
    fi

    case "$db_type" in
    mariadb | mysql)
        if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
            printf '%s\n' "$MYSQL_ROOT_PASSWORD"
        fi
        ;;
    esac
}

normalize_custom_db_type() {
    local raw="${1,,}"

    case "$raw" in
    mariadb)
        printf '%s\n' "mariadb"
        ;;
    mysql)
        printf '%s\n' "mysql"
        ;;
    postgresql | postgres)
        printf '%s\n' "postgresql"
        ;;
    timescaledb | timescale)
        printf '%s\n' "timescaledb"
        ;;
    *)
        return 1
        ;;
    esac
}

custom_db_client_cmd() {
    case "$1" in
    mariadb)
        printf '%s\n' "mariadb"
        ;;
    mysql)
        printf '%s\n' "mysql"
        ;;
    postgresql | timescaledb)
        printf '%s\n' "psql"
        ;;
    esac
}

custom_db_dump_cmd() {
    case "$1" in
    mariadb)
        printf '%s\n' "mariadb-dump"
        ;;
    mysql)
        printf '%s\n' "mysqldump"
        ;;
    postgresql | timescaledb)
        printf '%s\n' "pg_dump"
        ;;
    esac
}

custom_db_type_label() {
    case "$1" in
    mariadb)
        printf '%s\n' "MariaDB"
        ;;
    mysql)
        printf '%s\n' "MySQL"
        ;;
    postgresql)
        printf '%s\n' "PostgreSQL"
        ;;
    timescaledb)
        printf '%s\n' "TimescaleDB"
        ;;
    *)
        printf '%s\n' "$1"
        ;;
    esac
}

log_custom_backup_config() {
    local log_file="$1"

    echo "Custom Database Mode: enabled" >>"$log_file"
    echo "BACKUP_DB_TYPE: ${BACKUP_DB_TYPE:-}" >>"$log_file"
    echo "BACKUP_DB_CONTAINER: ${BACKUP_DB_CONTAINER:-}" >>"$log_file"
    echo "DB_NAME: ${DB_NAME:-}" >>"$log_file"
    echo "DB_USER: ${DB_USER:-}" >>"$log_file"
    echo "Database password: $(mask_database_password)" >>"$log_file"
}

validate_custom_backup_container() {
    local container="$1"
    local log_file="$2"
    local running=""

    if [ -z "$container" ]; then
        colorized_echo red "Error: BACKUP_DB_CONTAINER is not set"
        echo "BACKUP_DB_CONTAINER is not set" >>"$log_file"
        return 1
    fi

    if ! docker inspect "$container" >/dev/null 2>&1; then
        colorized_echo red "Error: Container '$container' does not exist"
        echo "Container does not exist: $container" >>"$log_file"
        return 1
    fi

    running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
    if [ "$running" != "true" ]; then
        colorized_echo red "Error: Container '$container' is not running"
        echo "Container is not running: $container" >>"$log_file"
        return 1
    fi

    return 0
}

ensure_custom_backup_container_running() {
    local container="$1"
    local log_file="$2"

    if validate_custom_backup_container "$container" "$log_file"; then
        return 0
    fi

    if ! docker inspect "$container" >/dev/null 2>&1; then
        return 1
    fi

    colorized_echo yellow "Container '$container' is not running. Attempting to start..."
    echo "Attempting to start container: $container" >>"$log_file"
    if ! docker start "$container" >>"$log_file" 2>&1; then
        colorized_echo red "Error: Failed to start container '$container'"
        echo "Failed to start container: $container" >>"$log_file"
        return 1
    fi

    sleep 2
    validate_custom_backup_container "$container" "$log_file"
}

resolve_restore_db_password() {
    local db_type="$1"
    local preferred_password="${3:-}"

    if [ -n "$preferred_password" ]; then
        printf '%s\n' "$preferred_password"
        return 0
    fi

    resolve_custom_backup_db_password "$db_type"
}

validate_custom_backup_credentials() {
    local container="$1"
    local db_type="$2"
    local db_user="$3"
    local db_password="$4"
    local log_file="$5"
    local client_cmd=""
    local db_type_label=""

    client_cmd=$(custom_db_client_cmd "$db_type")
    db_type_label=$(custom_db_type_label "$db_type")

    case "$db_type" in
    mariadb | mysql)
        if ! docker exec "$container" "$client_cmd" -u "$db_user" -p"$db_password" -e "SELECT 1" >/dev/null 2>>"$log_file"; then
            colorized_echo red "Error: Invalid $db_type_label credentials for user '$db_user'"
            echo "Database credential validation failed for user: $db_user" >>"$log_file"
            return 1
        fi
        ;;
    postgresql | timescaledb)
        if ! docker exec -e PGPASSWORD="$db_password" "$container" psql -U "$db_user" -d postgres -tAc "SELECT 1" >/dev/null 2>>"$log_file"; then
            colorized_echo red "Error: Invalid $db_type_label credentials for user '$db_user'"
            echo "Database credential validation failed for user: $db_user" >>"$log_file"
            return 1
        fi
        ;;
    esac

    return 0
}

validate_custom_backup_database_exists() {
    local container="$1"
    local db_type="$2"
    local db_user="$3"
    local db_password="$4"
    local db_name="$5"
    local log_file="$6"
    local client_cmd=""
    local escaped_db_name=""
    local db_exists=""

    client_cmd=$(custom_db_client_cmd "$db_type")
    escaped_db_name="${db_name//\'/\'\'}"

    case "$db_type" in
    mariadb | mysql)
        if ! docker exec "$container" "$client_cmd" -u "$db_user" -p"$db_password" -N -e "SHOW DATABASES LIKE '${escaped_db_name}';" 2>>"$log_file" | grep -qFx "$db_name"; then
            colorized_echo red "Error: Database '$db_name' does not exist in container '$container'"
            echo "Database does not exist: $db_name" >>"$log_file"
            return 1
        fi
        ;;
    postgresql | timescaledb)
        db_exists=$(docker exec -e PGPASSWORD="$db_password" "$container" psql -U "$db_user" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${escaped_db_name}'" 2>>"$log_file" || true)
        if [ "$db_exists" != "1" ]; then
            colorized_echo red "Error: Database '$db_name' does not exist in container '$container'"
            echo "Database does not exist: $db_name" >>"$log_file"
            return 1
        fi
        ;;
    esac

    return 0
}

dump_custom_backup_database() {
    local container="$1"
    local db_type="$2"
    local db_user="$3"
    local db_password="$4"
    local db_name="$5"
    local output_file="$6"
    local log_file="$7"
    local dump_cmd=""
    local db_type_label=""

    dump_cmd=$(custom_db_dump_cmd "$db_type")
    db_type_label=$(custom_db_type_label "$db_type")

    case "$db_type" in
    mariadb | mysql)
        if ! docker exec "$container" "$dump_cmd" -u "$db_user" -p"$db_password" "$db_name" --events --triggers >"$output_file" 2>>"$log_file"; then
            colorized_echo red "Error: $db_type_label dump failed. Check log file for details."
            echo "$db_type_label dump failed for database: $db_name" >>"$log_file"
            return 1
        fi
        ;;
    postgresql | timescaledb)
        if ! docker exec -e PGPASSWORD="$db_password" "$container" pg_dump -U "$db_user" -d "$db_name" --clean --if-exists >"$output_file" 2>>"$log_file"; then
            colorized_echo red "Error: $db_type_label dump failed. Check log file for details."
            echo "$db_type_label dump failed for database: $db_name" >>"$log_file"
            return 1
        fi
        ;;
    esac

    return 0
}

perform_custom_database_backup() {
    local output_file="$1"
    local log_file="$2"
    local db_type=""
    local db_type_label=""
    local container=""
    local db_name=""
    local db_user=""
    local db_password=""

    if [ -z "${BACKUP_DB_TYPE:-}" ]; then
        colorized_echo red "Error: BACKUP_DB_TYPE is not set"
        echo "BACKUP_DB_TYPE is not set" >>"$log_file"
        return 1
    fi

    if ! db_type=$(normalize_custom_db_type "$BACKUP_DB_TYPE"); then
        colorized_echo red "Error: Invalid BACKUP_DB_TYPE '$BACKUP_DB_TYPE'. Supported values: mariadb, mysql, postgresql, timescaledb"
        echo "Invalid BACKUP_DB_TYPE: $BACKUP_DB_TYPE" >>"$log_file"
        return 1
    fi

    container="${BACKUP_DB_CONTAINER:-}"
    db_name="${DB_NAME:-}"
    db_user="${DB_USER:-}"
    db_password=$(resolve_custom_backup_db_password "$db_type")
    db_type_label=$(custom_db_type_label "$db_type")

    if [ -z "$db_name" ]; then
        colorized_echo red "Error: DB_NAME is not set in $ENV_FILE"
        echo "DB_NAME is not set in .env" >>"$log_file"
        return 1
    fi

    if [ -z "$db_user" ]; then
        colorized_echo red "Error: DB_USER is not set in $ENV_FILE"
        echo "DB_USER is not set in .env" >>"$log_file"
        return 1
    fi

    if [ -z "$db_password" ]; then
        colorized_echo red "Error: Database password not found. Check DB_PASSWORD in $ENV_FILE"
        echo "Database password not found in .env" >>"$log_file"
        return 1
    fi

    if ! validate_custom_backup_container "$container" "$log_file"; then
        return 1
    fi

    if ! validate_custom_backup_credentials "$container" "$db_type" "$db_user" "$db_password" "$log_file"; then
        return 1
    fi

    if ! validate_custom_backup_database_exists "$container" "$db_type" "$db_user" "$db_password" "$db_name" "$log_file"; then
        return 1
    fi

    colorized_echo blue "Backing up $db_type_label database '$db_name' from container: $container (user: $db_user)"
    echo "Starting custom $db_type_label backup for database: $db_name" >>"$log_file"

    if ! dump_custom_backup_database "$container" "$db_type" "$db_user" "$db_password" "$db_name" "$output_file" "$log_file"; then
        return 1
    fi

    return 0
}

backup_command() {
    colorized_echo blue "Starting backup process..."

    # Check if pasarguard is installed
    if ! is_pasarguard_installed; then
        colorized_echo red "pasarguard is not installed!"
        return 1
    fi

    local backup_dir="$APP_DIR/backup"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local backup_file="$backup_dir/backup_$timestamp.zip"
    local error_messages=()
    local final_backup_paths=()
    local split_size_bytes="${BACKUP_SPLIT_SIZE_BYTES:-$((47 * 1024 * 1024))}" # keep Telegram chunks under 50MB
    local split_threshold_bytes="${BACKUP_SPLIT_THRESHOLD_BYTES:-$split_size_bytes}"
    local staging_root=""
    local temp_dir=""
    local log_file=""
    # Keep the lock with the backup artifacts so it is not affected by sticky-dir
    # protections on /tmp when different users invoke the command.
    local lock_dir="${backup_dir}/.${APP_NAME}-backup.lock.d"
    local keep_log_file=false

    if ! mkdir -p "$backup_dir"; then
        colorized_echo red "Failed to prepare backup directory: $backup_dir"
        return 1
    fi

    # Backups can be large, so avoid /tmp by default and stage beside the final
    # archive unless BACKUP_TMPDIR is explicitly set.
    staging_root="${BACKUP_TMPDIR:-$backup_dir}"
    if ! mkdir -p "$staging_root"; then
        colorized_echo red "Failed to prepare backup staging directory: $staging_root"
        return 1
    fi

    if ! temp_dir=$(mktemp -d "${staging_root}/pasarguard_backup.XXXXXX"); then
        colorized_echo red "Failed to create backup temp directory."
        return 1
    fi

    if ! log_file=$(mktemp "${staging_root}/pasarguard_backup_error.XXXXXX.log"); then
        colorized_echo red "Failed to create backup log file."
        rm -rf "$temp_dir"
        return 1
    fi

    acquire_backup_lock() {
        local lock_pid=""

        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" >"$lock_dir/pid"
            return 0
        fi

        if [ -f "$lock_dir/pid" ]; then
            lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
            if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                return 1
            fi
        fi

        if rm -rf "$lock_dir" 2>/dev/null && mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" >"$lock_dir/pid"
            return 0
        fi

        return 2
    }

    local lock_status=0
    if acquire_backup_lock; then
        lock_status=0
    else
        lock_status=$?
    fi

    case "$lock_status" in
    0)
        ;;
    1)
        colorized_echo yellow "Another backup process is already running."
        rm -rf "$temp_dir"
        rm -f "$log_file"
        return 1
        ;;
    *)
        colorized_echo red "Failed to acquire backup lock: $lock_dir"
        rm -rf "$temp_dir"
        rm -f "$log_file"
        return 1
        ;;
    esac

    cleanup_backup_command() {
        rm -rf "$temp_dir"
        if [ "$keep_log_file" != true ] && [ -n "$log_file" ]; then
            rm -f "$log_file"
        fi
        rm -rf "$lock_dir"
    }

    >"$log_file"
    echo "Backup Log - $(date)" >>"$log_file"

    colorized_echo blue "Reading environment configuration..."

    if ! command -v rsync >/dev/null 2>&1; then
        detect_os
        install_package rsync
    fi

    if ! command -v zip >/dev/null 2>&1; then
        detect_os
        install_package zip
    fi

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
        keep_log_file=true
        cleanup_backup_command
        return 1
    fi

    local db_type=""
    local sqlite_file=""
    local db_host=""
    local db_port=""
    local db_user=""
    local db_password=""
    local db_name=""
    local container_name=""
    local safe_sqlalchemy_url=""
    local custom_backup_mode=false

    if is_backup_custom_enabled; then
        custom_backup_mode=true
    fi

    if [ "$custom_backup_mode" = true ]; then
        colorized_echo blue "Custom Database Mode enabled"
        log_custom_backup_config "$log_file"
        colorized_echo blue "Database configuration:"
        colorized_echo blue "  Type: ${BACKUP_DB_TYPE:-}"
        colorized_echo blue "  Container: ${BACKUP_DB_CONTAINER:-}"
        colorized_echo blue "  Database: ${DB_NAME:-}"
        colorized_echo blue "  User: ${DB_USER:-}"
        colorized_echo blue "  Password: $(mask_database_password)"

        colorized_echo blue "Backing up custom database..."
        if ! perform_custom_database_backup "$temp_dir/db_backup.sql" "$log_file"; then
            error_messages+=("Custom database backup failed.")
            colorized_echo yellow "Please check the log file for details: $log_file"
            keep_log_file=true
            send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
            cleanup_backup_command
            return 1
        fi

        colorized_echo green "Custom database backup completed successfully"
        db_type=$(normalize_custom_db_type "${BACKUP_DB_TYPE}" 2>/dev/null || true)
    else
    safe_sqlalchemy_url=$(printf '%s' "${SQLALCHEMY_DATABASE_URL:-not set}" | sed -E 's#^([^:]+://)([^@/]+)@#\1REDACTED@#')

    # SQLALCHEMY_DATABASE_URL should already be loaded from .env above
    # Just log what we have
    echo "SQLALCHEMY_DATABASE_URL from environment: ${safe_sqlalchemy_url}" >>"$log_file"

    if [ -z "$SQLALCHEMY_DATABASE_URL" ]; then
        colorized_echo red "Error: SQLALCHEMY_DATABASE_URL not found in .env file or not set"
        echo "Please check $ENV_FILE for SQLALCHEMY_DATABASE_URL" >>"$log_file"
        error_messages+=("SQLALCHEMY_DATABASE_URL not found in .env file")
        colorized_echo yellow "Please check the log file for details: $log_file"
        keep_log_file=true
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        cleanup_backup_command
        return 1
    fi

    if [ -n "$SQLALCHEMY_DATABASE_URL" ]; then
        echo "Parsing SQLALCHEMY_DATABASE_URL: ${safe_sqlalchemy_url}" >>"$log_file"

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
            # Use the last '@' as the separator between auth and host
            if [[ "$url_part" == *@* ]]; then
                local auth_part="${url_part%@*}"
                url_part="${url_part##*@}"

                # Extract username and password (first ':' is the separator)
                if [[ "$auth_part" == *:* ]]; then
                    db_user="${auth_part%%:*}"
                    db_password="${auth_part#*:}"
                else
                    db_user="$auth_part"
                fi
            fi

            # Extract host, port, and database
            if [[ "$url_part" =~ ^\[([^]]+)\](:([0-9]+))?/(.+)$ ]]; then
                db_host="${BASH_REMATCH[1]}"
                db_port="${BASH_REMATCH[3]:-}"
                db_name="${BASH_REMATCH[4]}"
            elif [[ "$url_part" =~ ^([^:/]+)(:([0-9]+))?/(.+)$ ]]; then
                db_host="${BASH_REMATCH[1]}"
                db_port="${BASH_REMATCH[3]:-}"
                db_name="${BASH_REMATCH[4]}"
            fi

            if [ -n "$db_host" ]; then
                # Remove query parameters from database name if any
                db_name="${db_name%%\?*}"
                db_name="${db_name%%#*}"

                urldecode() { local url_encoded="${1//+/ }"; printf '%b' "${url_encoded//%/\\x}"; }
                db_user=$(urldecode "$db_user")
                db_password=$(urldecode "$db_password")
                db_name=$(urldecode "$db_name")

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
            if is_local_db_host "$db_host"; then
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
            if is_local_db_host "$db_host"; then
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
            if is_local_db_host "$db_host"; then
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
                                databases=$(docker exec "$container_name" "$mysql_cmd" -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;" 2>>"$log_file" | grep -Ev "^(Database|mysql|performance_schema|information_schema|sys)$" || true)
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
            if is_local_db_host "$db_host"; then
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
                        local backup_user="${db_user:-${DB_USER:-postgres}}"
                        local backup_password="${db_password:-${DB_PASSWORD:-}}"

                        if [ -z "$backup_password" ]; then
                            colorized_echo red "Error: Database password not found. Check DB_PASSWORD or SQLALCHEMY_DATABASE_URL in .env"
                            error_messages+=("PostgreSQL password not found.")
                        elif [ -z "$db_name" ]; then
                            colorized_echo red "Error: Database name not found in SQLALCHEMY_DATABASE_URL"
                            error_messages+=("PostgreSQL database name not found.")
                        else
                            colorized_echo blue "Backing up PostgreSQL database '$db_name' from container: $container_name (using user: $backup_user)"
                            if ! docker exec -e PGPASSWORD="$backup_password" "$container_name" pg_dump -U "$backup_user" -d "$db_name" --clean --if-exists >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                                colorized_echo red "PostgreSQL dump failed. Check log file for details."
                                error_messages+=("PostgreSQL dump failed.")
                            else
                                colorized_echo green "PostgreSQL backup completed successfully"
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
            if is_local_db_host "$db_host"; then
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
                            if ! docker exec -e PGPASSWORD="$backup_password" "$container_name" pg_dump -U "$backup_user" -d "$db_name" --clean --if-exists >"$temp_dir/db_backup.sql" 2>>"$log_file"; then
                                colorized_echo red "TimescaleDB dump failed. Check log file for details: $log_file"
                                error_messages+=("TimescaleDB dump failed for database '$db_name'.")
                            else
                                colorized_echo green "TimescaleDB backup completed successfully"
                            fi
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
                if ! command -v sqlite3 >/dev/null 2>&1; then
                    detect_os
                    install_package sqlite3 || true
                fi

                local sqlite_basename=$(basename "$sqlite_file")
                if command -v sqlite3 >/dev/null 2>&1; then
                    if ! sqlite3 "$sqlite_file" ".backup '$temp_dir/$sqlite_basename'" >>"$log_file" 2>&1; then
                        error_messages+=("Failed to create SQLite backup snapshot.")
                    fi
                elif ! cp "$sqlite_file" "$temp_dir/$sqlite_basename" 2>>"$log_file"; then
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
        echo "SQLALCHEMY_DATABASE_URL: ${safe_sqlalchemy_url}" >>"$log_file"
    fi
    fi

    colorized_echo blue "Copying app directory..."
    if [ -d "$APP_DIR" ]; then
        # Use rsync to copy the entire app directory, excluding the backup folder
        if ! rsync -av --exclude 'backup' "$APP_DIR/" "$temp_dir/" >>"$log_file" 2>&1; then
            error_messages+=("Failed to copy app directory.")
            echo "Failed to copy app directory" >>"$log_file"
        fi
    else
        colorized_echo yellow "Warning: App directory $APP_DIR does not exist. Copying individual files as fallback."
        if [ -f "$APP_DIR/.env" ]; then
            cp "$APP_DIR/.env" "$temp_dir/" 2>>"$log_file" || true
        fi
        if [ -f "$APP_DIR/docker-compose.yml" ]; then
            cp "$APP_DIR/docker-compose.yml" "$temp_dir/" 2>>"$log_file" || true
        fi
    fi

    colorized_echo blue "Copying data directory..."
    # Ensure destination directory exists and is empty (already cleaned above, but be explicit)
    if [ -d "$DATA_DIR" ]; then
        local rsync_args=(-av --exclude 'xray-core' --exclude 'mysql' --exclude 'mariadb' --exclude 'postgresql' --exclude 'timescaledb')

        if [ "$db_type" = "sqlite" ] && [ -n "$sqlite_file" ] && [[ "$sqlite_file" == "$DATA_DIR/"* ]]; then
            local sqlite_relative_path="${sqlite_file#$DATA_DIR/}"
            rsync_args+=(--exclude "$sqlite_relative_path")
            rsync_args+=(--exclude "${sqlite_relative_path}-wal")
            rsync_args+=(--exclude "${sqlite_relative_path}-shm")
            echo "Excluding SQLite database from data directory copy: $sqlite_relative_path" >>"$log_file"
        fi

        if ! rsync "${rsync_args[@]}" "$DATA_DIR/" "$temp_dir/pasarguard_data/" >>"$log_file" 2>&1; then
            error_messages+=("Failed to copy data directory.")
            echo "Failed to copy data directory" >>"$log_file"
        elif [ "$db_type" = "sqlite" ] && [ -n "$sqlite_file" ] && [[ "$sqlite_file" == "$DATA_DIR/"* ]]; then
            local sqlite_relative_path="${sqlite_file#$DATA_DIR/}"
            rm -f "$temp_dir/pasarguard_data/$sqlite_relative_path" \
                "$temp_dir/pasarguard_data/${sqlite_relative_path}-wal" \
                "$temp_dir/pasarguard_data/${sqlite_relative_path}-shm" 2>>"$log_file" || true
        fi
    else
        colorized_echo yellow "Data directory $DATA_DIR does not exist. Skipping data directory backup."
        echo "Data directory $DATA_DIR does not exist. Skipping." >>"$log_file"
        # Create empty directory structure so tar doesn't fail
        mkdir -p "$temp_dir/pasarguard_data"
    fi

    # Remove Unix socket files so zip doesn't fail with ENXIO ("No such device or address")
    if [ -d "$temp_dir" ]; then
        local socket_files
        socket_files=$(find "$temp_dir" -type s -print 2>/dev/null || true)
        if [ -n "$socket_files" ]; then
            colorized_echo yellow "Removing Unix socket files before archiving (zip cannot archive sockets)."
            printf "%s\n" "$socket_files" >>"$log_file"
            find "$temp_dir" -type s -delete >>"$log_file" 2>&1 || true
        fi
    fi

    colorized_echo blue "Creating backup archive..."
    # Verify temp_dir exists and has content before creating archive
    if [ ! -d "$temp_dir" ] || [ -z "$(ls -A "$temp_dir" 2>/dev/null)" ]; then
        error_messages+=("Temporary directory is empty or missing. Cannot create archive.")
        echo "Temporary directory is empty or missing: $temp_dir" >>"$log_file"
    elif ! (cd "$temp_dir" && zip -rq "$backup_file" .) 2>>"$log_file"; then
        error_messages+=("Failed to create backup archive.")
        echo "Failed to create backup archive." >>"$log_file"
    else
        local archive_size_bytes=0
        archive_size_bytes=$(stat -c%s "$backup_file" 2>/dev/null || wc -c <"$backup_file")

        if [ "$archive_size_bytes" -gt "$split_threshold_bytes" ]; then
            colorized_echo blue "Splitting backup archive into Telegram-sized parts..."
            if ! split -d -a 2 --numeric-suffixes=1 -b "$split_size_bytes" --additional-suffix=".zip" \
                "$backup_file" "$backup_dir/backup_${timestamp}.part" 2>>"$log_file"; then
                error_messages+=("Failed to split backup archive.")
                echo "Failed to split backup archive." >>"$log_file"
            else
                rm -f "$backup_file"
            fi
        fi

        if [ ${#error_messages[@]} -eq 0 ]; then
            find "$backup_dir" -maxdepth 1 -type f \
                \( -name "backup_*.tar.gz" -o -name "backup_*.zip" -o -name "backup_*.z[0-9][0-9]" -o -name "backup_*.part[0-9][0-9].zip" \) \
                ! -name "backup_${timestamp}.zip" \
                ! -name "backup_${timestamp}.z[0-9][0-9]" \
                ! -name "backup_${timestamp}.part[0-9][0-9].zip" \
                -delete 2>/dev/null || true
        fi
    fi

    while IFS= read -r file; do
        final_backup_paths+=("$file")
    done < <(find "$backup_dir" -maxdepth 1 -type f -name "backup_${timestamp}.part[0-9][0-9].zip" | sort)

    if [ ${#final_backup_paths[@]} -eq 0 ] && [ -f "$backup_file" ]; then
        final_backup_paths+=("$backup_file")
    fi

    if [ ${#error_messages[@]} -eq 0 ] && [ ${#final_backup_paths[@]} -gt 0 ]; then
        local backup_size_bytes=0
        local size_file=""
        for size_file in "${final_backup_paths[@]}"; do
            [ -n "$size_file" ] || continue
            local size_bytes=0
            size_bytes=$(stat -c%s "$size_file" 2>/dev/null || wc -c <"$size_file")
            backup_size_bytes=$((backup_size_bytes + size_bytes))
        done

        local backup_size=""
        if command -v numfmt >/dev/null 2>&1; then
            backup_size=$(numfmt --to=iec --suffix=B "$backup_size_bytes" 2>/dev/null || awk -v size="$backup_size_bytes" 'BEGIN { printf "%.2f MB", size/1048576 }')
        else
            backup_size=$(awk -v size="$backup_size_bytes" 'BEGIN { printf "%.2f MB", size/1048576 }')
        fi
        if [ ${#final_backup_paths[@]} -eq 1 ]; then
            colorized_echo green "Backup archive created: ${final_backup_paths[0]} (Size: $backup_size)"
        else
            colorized_echo green "Backup archive created in ${#final_backup_paths[@]} parts (Total Size: $backup_size)"
        fi
    fi

    if [ ${#error_messages[@]} -gt 0 ]; then
        keep_log_file=true
        colorized_echo red "Backup completed with errors:"
        for error in "${error_messages[@]}"; do
            colorized_echo red "  - $error"
        done
        colorized_echo yellow "Check log file: $log_file"
        if [ -f "$ENV_FILE" ]; then
            send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        fi
        cleanup_backup_command
        return 1
    fi

    if [ ${#final_backup_paths[@]} -eq 0 ]; then
        keep_log_file=true
        colorized_echo red "Backup file was not created. Check log file: $log_file"
        cleanup_backup_command
        return 1
    fi

    if [ ${#final_backup_paths[@]} -eq 1 ]; then
        colorized_echo green "Backup completed successfully: ${final_backup_paths[0]}"
    else
        colorized_echo green "Backup completed successfully in ${#final_backup_paths[@]} parts:"
        for part in "${final_backup_paths[@]}"; do
            colorized_echo green "  - $(basename "$part")"
        done
    fi
    if [ -f "$ENV_FILE" ]; then
        send_backup_to_telegram "$backup_file"
    fi
    cleanup_backup_command
}
