#!/usr/bin/env bash

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

    local current_db_user=""
    local current_db_password=""
    local current_db_name=""
    local current_sqlalchemy_url=""
    local current_mysql_root_password=""

    if [ -f "$ENV_FILE" ]; then
        set +e
        while IFS='=' read -r key value || [ -n "$key" ]; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs 2>/dev/null || echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            value=$(echo "$value" | xargs 2>/dev/null || echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            value=$(echo "$value" | sed -E 's/^["'"'"'](.*)["'"'"']$/\1/' 2>/dev/null || echo "$value")
            case "$key" in
            MYSQL_ROOT_PASSWORD)
                current_mysql_root_password="$value"
                ;;
            DB_USER)
                current_db_user="$value"
                ;;
            DB_PASSWORD)
                current_db_password="$value"
                ;;
            DB_NAME)
                current_db_name="$value"
                ;;
            SQLALCHEMY_DATABASE_URL)
                current_sqlalchemy_url="$value"
                ;;
            esac
        done <"$ENV_FILE"
        set -e
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
    local backup_candidates=()
    while IFS= read -r -d '' file; do
        backup_candidates+=("$file")
    done < <(find "$backup_dir" -maxdepth 1 \( -name "*backup*.gz" -o -name "*backup*.tar.gz" -o -name "*.tar.gz" -o -name "*backup*.zip" -o -name "*.zip" \) -type f -print0 2>/dev/null)

    if [ ${#backup_candidates[@]} -eq 0 ]; then
        # Fallback: try to find any archive files
        while IFS= read -r -d '' file; do
            backup_candidates+=("$file")
        done < <(find "$backup_dir" -maxdepth 1 \( -name "*.gz" -o -name "*.zip" \) -type f -print0 2>/dev/null)
    fi

    local backup_files=()
    for file in "${backup_candidates[@]}"; do
        local filename=$(basename "$file")
        if [[ "$filename" =~ \.part[0-9]{2}\.zip$ ]] && [[ ! "$filename" =~ \.part01\.zip$ ]]; then
            continue
        fi
        if [[ "$filename" =~ \.z[0-9]{2}$ ]]; then
            continue
        fi
        backup_files+=("$file")
    done

    if [ ${#backup_files[@]} -eq 0 ]; then
        colorized_echo red "No backup files found in $backup_dir"
        colorized_echo yellow "Looking for files with extensions: .gz, .zip, .tar.gz or containing 'backup'"
        exit 1
    fi

    colorized_echo blue "Available backup files:"
    local i=1
    for file in "${backup_files[@]}"; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            if [[ "$filename" =~ \.part[0-9]{2}\.zip$ ]]; then
                local base_name="${filename%%.part*}"
                local part_count=$(find "$backup_dir" -maxdepth 1 -type f -name "${base_name}.part*.zip" | wc -l | awk '{print $1}')
                [ -z "$part_count" ] && part_count=0
                local total_size_bytes=0
                while IFS= read -r part_file; do
                    local part_size=$(stat -c%s "$part_file" 2>/dev/null || stat -f%z "$part_file" 2>/dev/null)
                    if [ -z "$part_size" ]; then
                        part_size=$(wc -c <"$part_file")
                    fi
                    total_size_bytes=$((total_size_bytes + part_size))
                done < <(find "$backup_dir" -maxdepth 1 -type f -name "${base_name}.part*.zip")
                local human_size=""
                if command -v numfmt >/dev/null 2>&1; then
                    human_size=$(numfmt --to=iec --suffix=B "$total_size_bytes" 2>/dev/null || awk -v size="$total_size_bytes" 'BEGIN { printf "%.2f MB", size/1048576 }')
                else
                    human_size=$(awk -v size="$total_size_bytes" 'BEGIN { printf "%.2f MB", size/1048576 }')
                fi
                local file_date=$(date -r "$file" "+%Y-%m-%d %H:%M:%S")
                echo "$i. $filename (Parts: ${part_count:-1}, Total Size: $human_size, Date: $file_date)"
            elif [[ "$filename" =~ \.zip$ ]]; then
                local base_name="${filename%.zip}"
                local zip_part_files=()
                while IFS= read -r part_file; do
                    zip_part_files+=("$part_file")
                done < <(find "$backup_dir" -maxdepth 1 -type f -name "${base_name}.z[0-9][0-9]" | sort)
                if [ ${#zip_part_files[@]} -gt 0 ]; then
                    local total_size_bytes=0
                    for part_file in "${zip_part_files[@]}"; do
                        local part_size=$(stat -c%s "$part_file" 2>/dev/null || stat -f%z "$part_file" 2>/dev/null)
                        if [ -z "$part_size" ]; then
                            part_size=$(wc -c <"$part_file")
                        fi
                        total_size_bytes=$((total_size_bytes + part_size))
                    done
                    local main_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
                    if [ -z "$main_size" ]; then
                        main_size=$(wc -c <"$file")
                    fi
                    total_size_bytes=$((total_size_bytes + main_size))
                    local part_display=""
                    if command -v numfmt >/dev/null 2>&1; then
                        part_display=$(numfmt --to=iec --suffix=B "$total_size_bytes" 2>/dev/null || awk -v size="$total_size_bytes" 'BEGIN { printf "%.2f MB", size/1048576 }')
                    else
                        part_display=$(awk -v size="$total_size_bytes" 'BEGIN { printf "%.2f MB", size/1048576 }')
                    fi
                    local file_date=$(date -r "$file" "+%Y-%m-%d %H:%M:%S")
                    local part_count=$(( ${#zip_part_files[@]} + 1 ))
                    echo "$i. $filename (Zip splits: $part_count parts, Total Size: $part_display, Date: $file_date)"
                else
                    local file_size=$(du -h "$file" | cut -f1)
                    local file_date=$(date -r "$file" "+%Y-%m-%d %H:%M:%S")
                    echo "$i. $filename (Size: $file_size, Date: $file_date)"
                fi
            else
                local file_size=$(du -h "$file" | cut -f1)
                local file_date=$(date -r "$file" "+%Y-%m-%d %H:%M:%S")
                echo "$i. $filename (Size: $file_size, Date: $file_date)"
            fi
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

    colorized_echo blue "Preparing archive for extraction..."
    local archive_to_extract="$selected_file"
    local archive_format="tar"

    if [[ "$selected_filename" =~ \.part[0-9]{2}\.zip$ ]]; then
        archive_format="zip"
        local base_name="${selected_filename%%.part*}"
        colorized_echo yellow "Detected split zip backup. Checking available parts..."
        if [ ! -f "$backup_dir/${base_name}.part01.zip" ]; then
            colorized_echo red "Missing ${base_name}.part01.zip. Cannot restore split backup."
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        local concatenated_file="$temp_restore_dir/${base_name}_combined.zip"
        >"$concatenated_file"
        local part_count=0
        while IFS= read -r part_file; do
            cat "$part_file" >>"$concatenated_file"
            part_count=$((part_count + 1))
        done < <(find "$backup_dir" -maxdepth 1 -type f -name "${base_name}.part*.zip" | sort)
        if [ "$part_count" -eq 0 ]; then
            colorized_echo red "No parts found for $base_name"
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        archive_to_extract="$concatenated_file"
        colorized_echo green "âœ“ Combined $part_count part(s)"
    elif [[ "$selected_filename" =~ \.zip$ ]]; then
        archive_format="zip"
        local base_name="${selected_filename%.zip}"
        local zip_split_parts=()
        while IFS= read -r part_file; do
            [ -n "$part_file" ] && zip_split_parts+=("$part_file")
        done < <(find "$backup_dir" -maxdepth 1 -type f -name "${base_name}.z[0-9][0-9]" | sort)

        if [ ${#zip_split_parts[@]} -gt 0 ]; then
            colorized_echo yellow "Detected split zip backup (.zXX + .zip). Rebuilding archive..."
            local expected_part=1
            for part_file in "${zip_split_parts[@]}"; do
                local expected_name
                expected_name=$(printf "%s.z%02d" "$base_name" "$expected_part")
                if [ "$(basename "$part_file")" != "$expected_name" ]; then
                    colorized_echo red "Missing split part $expected_name. Cannot restore split backup."
                    rm -rf "$temp_restore_dir"
                    exit 1
                fi
                expected_part=$((expected_part + 1))
            done

            local concatenated_file="$temp_restore_dir/${base_name}_combined.zip"
            if command -v zip >/dev/null 2>&1 && zip -s 0 "$selected_file" --out "$concatenated_file" >>"$log_file" 2>&1; then
                archive_to_extract="$concatenated_file"
                colorized_echo green "âœ“ Rebuilt split zip archive with zip utility"
            else
                if command -v zip >/dev/null 2>&1; then
                    colorized_echo yellow "zip rebuild failed. Falling back to direct concatenation..."
                else
                    colorized_echo yellow "zip utility not found. Falling back to direct concatenation..."
                fi
                >"$concatenated_file"
                local part_count=0
                for part_file in "${zip_split_parts[@]}"; do
                    if ! cat "$part_file" >>"$concatenated_file"; then
                        colorized_echo red "Failed to read split part: $(basename "$part_file")"
                        rm -rf "$temp_restore_dir"
                        exit 1
                    fi
                    part_count=$((part_count + 1))
                done
                if ! cat "$selected_file" >>"$concatenated_file"; then
                    colorized_echo red "Failed to read main zip file: $selected_filename"
                    rm -rf "$temp_restore_dir"
                    exit 1
                fi
                archive_to_extract="$concatenated_file"
                colorized_echo green "âœ“ Combined $((part_count + 1)) split part(s)"
            fi
        fi
    else
        archive_format="tar"
    fi

    colorized_echo blue "Extracting backup..."
    if [ "$archive_format" = "zip" ]; then
        if ! command -v unzip >/dev/null 2>&1; then
            detect_os
            install_package unzip
        fi
        if ! unzip -tq "$archive_to_extract" >/dev/null 2>>"$log_file"; then
            colorized_echo red "ERROR: The backup file is not a valid zip archive."
            echo "File is not a valid zip archive: $archive_to_extract" >>"$log_file"
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        if ! unzip -oq "$archive_to_extract" -d "$temp_restore_dir" 2>>"$log_file"; then
            colorized_echo red "Failed to extract backup file."
            echo "Failed to extract $archive_to_extract" >>"$log_file"
            rm -rf "$temp_restore_dir"
            exit 1
        fi
    else
        if ! gzip -t "$archive_to_extract" 2>/dev/null; then
            colorized_echo red "ERROR: The backup file is not a valid gzip archive."
            echo "File is not a valid gzip archive: $archive_to_extract" >>"$log_file"
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        if ! tar -xzf "$archive_to_extract" -C "$temp_restore_dir" 2>>"$log_file"; then
            colorized_echo red "Failed to extract backup file."
            echo "Failed to extract $archive_to_extract" >>"$log_file"
            rm -rf "$temp_restore_dir"
            exit 1
        fi
    fi
    colorized_echo green "âœ“ Archive extracted successfully"

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

    colorized_echo green "âœ“ Loaded $env_vars_loaded environment variables"

    if [ -z "$SQLALCHEMY_DATABASE_URL" ]; then
        colorized_echo red "SQLALCHEMY_DATABASE_URL not found in backup .env file"
        colorized_echo yellow "Available environment variables:"
        grep -v '^#' "$extracted_env" | grep '=' | cut -d'=' -f1 | head -10
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    colorized_echo green "âœ“ Found SQLALCHEMY_DATABASE_URL: ${SQLALCHEMY_DATABASE_URL:0:50}..."

    # Parse database configuration (similar to backup function)
    colorized_echo blue "Detecting database type..."
    if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^sqlite ]]; then
        db_type="sqlite"
        colorized_echo green "âœ“ Detected SQLite database"
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
            colorized_echo green "âœ“ Detected MariaDB database"
        elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^mysql[^:]*:// ]]; then
            db_type="mysql"
            colorized_echo green "âœ“ Detected MySQL database"
        elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^postgresql[^:]*:// ]]; then
            # Check if it's timescaledb - use set +e to prevent failure on file not found
            set +e
            if grep -q "image: timescale/timescaledb" "$temp_restore_dir/docker-compose.yml" 2>/dev/null; then
                db_type="timescaledb"
                colorized_echo green "âœ“ Detected TimescaleDB database"
            else
                db_type="postgresql"
                colorized_echo green "âœ“ Detected PostgreSQL database"
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

    colorized_echo green "âœ“ Database configuration detected: $db_type"

    # Confirm restore
    colorized_echo red "âš ï¸  DANGER: This will PERMANENTLY overwrite your current $db_type database!"
    colorized_echo yellow "WARNING: This will overwrite your current $db_type database!"
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
    colorized_echo blue "Stopping pasarguard services for clean restore..."
    if [[ "$db_type" == "sqlite" ]]; then
        # For SQLite, stop all services since we need to restore files
        down_pasarguard
    else
        # For containerized databases, stop only application services
        # Keep database containers running for restore via docker exec
        stop_pasarguard_app_services
    fi

    # Perform restore
    colorized_echo red "âš ï¸  DANGER: Starting database restore - this will overwrite existing data!"
    colorized_echo blue "Starting database restore..."

    case $db_type in
    sqlite)
        if [ ! -f "$temp_restore_dir/db_backup.sqlite" ]; then
            colorized_echo red "SQLite backup file not found in backup archive."
            rm -rf "$temp_restore_dir"
            exit 1
        fi

        if [ -f "$sqlite_file" ]; then
            cp "$sqlite_file" "${sqlite_file}.backup.$(date +%Y%m%d%H%M%S)" 2>>"$log_file"
        fi

        if cp "$temp_restore_dir/db_backup.sqlite" "$sqlite_file" 2>>"$log_file"; then
            colorized_echo green "SQLite database restored successfully."
        else
            colorized_echo red "Failed to restore SQLite database."
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

                colorized_echo blue "Restoring $db_type_name database from container: $container_name"

                local restore_success=false
                local backup_restore_user="${db_user:-${DB_USER:-}}"
                local backup_restore_password="${db_password:-${DB_PASSWORD:-}}"
                local app_db_target="${db_name:-${current_db_name:-}}"

                # Try root password from backup .env first
                if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
                    colorized_echo blue "Trying root user from backup .env..."
                    if docker exec -i "$container_name" "$mysql_cmd" -u root -p"$MYSQL_ROOT_PASSWORD" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        restore_success=true
                        colorized_echo green "$db_type_name database restored successfully."
                    else
                        colorized_echo yellow "Root restore failed with backup .env credentials, trying fallback..."
                        echo "$db_type_name restore failed with backup MYSQL_ROOT_PASSWORD" >>"$log_file"
                    fi
                fi

                # If root password changed after backup, try current installation value
                if [ "$restore_success" = false ] && [ -n "$current_mysql_root_password" ] && [ "$current_mysql_root_password" != "${MYSQL_ROOT_PASSWORD:-}" ]; then
                    colorized_echo blue "Trying root user from current installation .env..."
                    if docker exec -i "$container_name" "$mysql_cmd" -u root -p"$current_mysql_root_password" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        restore_success=true
                        colorized_echo green "$db_type_name database restored successfully."
                    else
                        colorized_echo yellow "Root restore failed with current .env credentials, trying app user fallback..."
                        echo "$db_type_name restore failed with current MYSQL_ROOT_PASSWORD" >>"$log_file"
                    fi
                fi

                # Try app user from backup SQL URL/.env
                if [ "$restore_success" = false ] && [ -n "$backup_restore_user" ] && [ -n "$backup_restore_password" ]; then
                    colorized_echo blue "Trying app user '$backup_restore_user' from backup credentials..."
                    if [ -n "$app_db_target" ]; then
                        if docker exec -i "$container_name" "$mysql_cmd" -u "$backup_restore_user" -p"$backup_restore_password" "$app_db_target" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                            restore_success=true
                            colorized_echo green "$db_type_name database restored successfully."
                        fi
                    fi
                    if [ "$restore_success" = false ] && docker exec -i "$container_name" "$mysql_cmd" -u "$backup_restore_user" -p"$backup_restore_password" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        restore_success=true
                        colorized_echo green "$db_type_name database restored successfully."
                    elif [ "$restore_success" = false ]; then
                        colorized_echo yellow "App user restore failed with backup credentials, trying current installation credentials..."
                        echo "$db_type_name restore failed with backup app credentials" >>"$log_file"
                    fi
                fi

                # Final fallback: current installation app credentials
                if [ "$restore_success" = false ] && [ -n "$current_db_user" ] && [ -n "$current_db_password" ] && { [ "$current_db_user" != "$backup_restore_user" ] || [ "$current_db_password" != "$backup_restore_password" ]; }; then
                    colorized_echo blue "Trying app user '$current_db_user' from current installation .env..."
                    if [ -n "$app_db_target" ]; then
                        if docker exec -i "$container_name" "$mysql_cmd" -u "$current_db_user" -p"$current_db_password" "$app_db_target" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                            restore_success=true
                            colorized_echo green "$db_type_name database restored successfully."
                        fi
                    fi
                    if [ "$restore_success" = false ] && docker exec -i "$container_name" "$mysql_cmd" -u "$current_db_user" -p"$current_db_password" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        restore_success=true
                        colorized_echo green "$db_type_name database restored successfully."
                    elif [ "$restore_success" = false ]; then
                        echo "$db_type_name restore failed with current app credentials" >>"$log_file"
                    fi
                fi

                if [ "$restore_success" = false ]; then
                    colorized_echo red "Failed to restore $db_type_name database with all available credentials."
                    colorized_echo yellow "Check log file for details: $log_file"
                    rm -rf "$temp_restore_dir"
                    exit 1
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

            colorized_echo blue "Restoring $db_type database from container: $container_name"

            # Prepare restore credentials
                local restore_user="${db_user:-${DB_USER:-postgres}}"
                local restore_password="${db_password:-${DB_PASSWORD:-}}"

                if [ -z "$restore_password" ]; then
                    colorized_echo red "No database password found for restore."
                    rm -rf "$temp_restore_dir"
                    exit 1
                fi

            export PGPASSWORD="$restore_password"
            local restore_success=false

            if [ "$db_type" = "timescaledb" ]; then
                # TimescaleDB requires special restore procedure to handle version mismatches.
                # A plain psql restore fails when the backup was taken with a different
                # TimescaleDB version because DROP EXTENSION / CREATE EXTENSION cycles
                # break when the shared library is already loaded with the new version.
                # The fix: drop & recreate the database, then use the official
                # timescaledb_pre_restore() / timescaledb_post_restore() wrapper.
                # See: https://docs.timescale.com/self-hosted/latest/backup-and-restore/
                colorized_echo blue "Using TimescaleDB-safe restore procedure..."

                # Use target installation's identity when available, falling back to backup values.
                # This ensures cross-server restores work correctly when the local DB user/name
                # differs from the backup source.
                local target_db_name="${current_db_name:-$db_name}"
                local target_db_owner="${current_db_user:-$restore_user}"

                # Drop and recreate the target database for a clean slate
                colorized_echo blue "Dropping and recreating database '$target_db_name'..."
                docker exec "$container_name" psql -U postgres -d postgres \
                    -v db_name="$target_db_name" \
                    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'db_name' AND pid <> pg_backend_pid();" \
                    >>"$log_file" 2>&1
                docker exec "$container_name" psql -U postgres -d postgres \
                    -v db_name="$target_db_name" \
                    -c "DROP DATABASE IF EXISTS :\"db_name\";" >>"$log_file" 2>&1
                docker exec "$container_name" psql -U postgres -d postgres \
                    -v db_name="$target_db_name" -v db_owner="$target_db_owner" \
                    -c "CREATE DATABASE :\"db_name\" OWNER :\"db_owner\";" >>"$log_file" 2>&1

                # Create the timescaledb extension in the fresh database
                docker exec "$container_name" psql -U postgres --dbname="$target_db_name" \
                    -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" >>"$log_file" 2>&1

                # Call pre_restore to put TimescaleDB into restore mode
                colorized_echo blue "Calling timescaledb_pre_restore()..."
                docker exec "$container_name" psql -U postgres --dbname="$target_db_name" \
                    -c "SELECT timescaledb_pre_restore();" >>"$log_file" 2>&1

                # Filter out extension DROP/CREATE statements from the dump.
                # pg_dump --clean --if-exists generates DROP EXTENSION / CREATE EXTENSION
                # lines that would undo the pre_restore() setup above.
                colorized_echo blue "Preparing dump (filtering extension statements)..."
                grep -v -E '^\s*(DROP|CREATE)\s+EXTENSION\s+(IF\s+(EXISTS|NOT\s+EXISTS)\s+)?timescaledb\b' \
                    "$temp_restore_dir/db_backup.sql" > "$temp_restore_dir/db_backup_filtered.sql" 2>>"$log_file"

                # Restore the filtered dump with ON_ERROR_STOP so psql exits non-zero on SQL errors
                colorized_echo blue "Restoring database dump..."
                if docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U "$restore_user" --dbname="$target_db_name" < "$temp_restore_dir/db_backup_filtered.sql" 2>>"$log_file"; then
                    restore_success=true
                else
                    # Fallback: try with postgres superuser
                    colorized_echo yellow "Trying with postgres superuser..."
                    if docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres --dbname="$target_db_name" < "$temp_restore_dir/db_backup_filtered.sql" 2>>"$log_file"; then
                        restore_success=true
                    fi
                fi

                # Clean up filtered dump
                rm -f "$temp_restore_dir/db_backup_filtered.sql"

                # Call post_restore regardless of outcome to leave DB in a usable state
                colorized_echo blue "Calling timescaledb_post_restore()..."
                docker exec "$container_name" psql -U postgres --dbname="$target_db_name" \
                    -c "SELECT timescaledb_post_restore();" >>"$log_file" 2>&1

                if [ "$restore_success" = true ]; then
                    colorized_echo green "TimescaleDB database restored successfully."
                fi
            else
                # Plain PostgreSQL restore with ON_ERROR_STOP so psql exits non-zero on SQL errors
                colorized_echo blue "Attempting restore using app user '$restore_user' to database '$db_name'..."
                if docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U "$restore_user" -d "$db_name" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                    colorized_echo green "$db_type database restored successfully."
                    restore_success=true
                else
                    # If that fails, try using postgres superuser
                    colorized_echo yellow "Trying with postgres superuser..."
                    if docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d "$db_name" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        colorized_echo green "$db_type database restored successfully."
                        restore_success=true
                    else
                        # Try restoring to postgres database (for pg_dumpall backups)
                        if docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                            colorized_echo green "$db_type database restored successfully."
                            restore_success=true
                        fi
                    fi
                fi
            fi

            unset PGPASSWORD

            if [ "$restore_success" = false ]; then
                colorized_echo red "Failed to restore $db_type database."
                colorized_echo yellow "Check log file for details: $log_file"
                rm -rf "$temp_restore_dir"
                exit 1
            fi
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

    # Restore data directory if included in backup
    colorized_echo blue "Restoring data directory..."
    local extracted_data_dir="$temp_restore_dir/pasarguard_data"
    if [ -d "$extracted_data_dir" ]; then
        if ! command -v rsync >/dev/null 2>&1; then
            detect_os
            install_package rsync
        fi
        mkdir -p "$DATA_DIR"
        if ! rsync -a "$extracted_data_dir/" "$DATA_DIR/" 2>>"$log_file"; then
            colorized_echo red "Failed to restore data directory."
            echo "Failed to restore data directory from $extracted_data_dir to $DATA_DIR" >>"$log_file"
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        colorized_echo green "Data directory restored to $DATA_DIR."
    else
        colorized_echo yellow "No pasarguard_data directory found in backup. Skipping data restore."
    fi

    # Restore configuration files if needed
    colorized_echo blue "Restoring configuration files..."
    if [ -f "$temp_restore_dir/.env" ]; then
        if [ -f "$APP_DIR/.env" ]; then
            cp "$APP_DIR/.env" "$APP_DIR/.env.backup.$(date +%Y%m%d%H%M%S)" 2>>"$log_file"
        fi
        cp "$temp_restore_dir/.env" "$APP_DIR/.env" 2>>"$log_file"
        colorized_echo green "Environment file restored."
        local preserve_db_credentials=false
        if [[ "$db_type" != "sqlite" ]]; then
            if [ -n "$current_db_user" ] && [ -n "${DB_USER:-}" ] && [ "$current_db_user" != "$DB_USER" ]; then
                preserve_db_credentials=true
            elif [ -n "$current_db_name" ] && [ -n "${DB_NAME:-}" ] && [ "$current_db_name" != "$DB_NAME" ]; then
                preserve_db_credentials=true
            elif [ -n "$current_db_password" ] && [ -n "${DB_PASSWORD:-}" ] && [ "$current_db_password" != "$DB_PASSWORD" ]; then
                preserve_db_credentials=true
            fi
        fi
        if [ "$preserve_db_credentials" = true ]; then
            colorized_echo yellow "Database credentials in backup differ from current installation; preserving current database credentials."
            if [ -n "$current_db_user" ]; then
                replace_or_append_env_var "DB_USER" "$current_db_user" false "$ENV_FILE"
            fi
            if [ -n "$current_db_name" ]; then
                replace_or_append_env_var "DB_NAME" "$current_db_name" false "$ENV_FILE"
            fi
            if [ -n "$current_db_password" ]; then
                replace_or_append_env_var "DB_PASSWORD" "$current_db_password" false "$ENV_FILE"
            fi
            if [ -n "$current_sqlalchemy_url" ]; then
                replace_or_append_env_var "SQLALCHEMY_DATABASE_URL" "$current_sqlalchemy_url" true "$ENV_FILE"
            fi
        fi
    fi

    if [ -f "$temp_restore_dir/docker-compose.yml" ]; then
        if [ -f "$APP_DIR/docker-compose.yml" ]; then
            cp "$APP_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml.backup.$(date +%Y%m%d%H%M%S)" 2>>"$log_file"
        fi
        cp "$temp_restore_dir/docker-compose.yml" "$APP_DIR/docker-compose.yml" 2>>"$log_file"
        colorized_echo green "Docker Compose file restored."
    fi

    # Clean up
    rm -rf "$temp_restore_dir"

    # Restart pasarguard services
    colorized_echo blue "Restarting pasarguard services..."
    if [[ "$db_type" == "sqlite" ]]; then
        # For SQLite, restart all services
        up_pasarguard
    else
        # For containerized databases, restart only application services
        start_pasarguard_app_services
    fi

    colorized_echo green "Restore completed successfully!"
    colorized_echo green "PasarGuard services have been restarted."
}

