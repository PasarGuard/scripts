#!/usr/bin/env bash

# Reject archives whose members would escape the extraction directory — an
# absolute path or a '..' component (zip-slip / tar path traversal). Backups
# are later rsynced into $DATA_DIR/$APP_DIR as root, so a tampered archive must
# not be extracted unchecked. $2 is the archive kind: "zip" or "tar".
archive_entries_are_safe() {
    local archive="$1"
    local kind="$2"
    local entries=""

    case "$kind" in
        zip) entries=$(unzip -Z1 "$archive" 2>/dev/null) ;;
        tar) entries=$(tar -tzf "$archive" 2>/dev/null) ;;
        *) return 1 ;;
    esac
    [ -n "$entries" ] || return 1

    local entry
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        case "$entry" in
            /* | ../* | */../* | */.. | ..) return 1 ;;
        esac
    done <<<"$entries"
    return 0
}

# Heuristic check that a plain-SQL pg_dump file is restorable before a
# destructive DROP DATABASE (the TimescaleDB path drops the live DB before
# restoring). Catches the realistic bad-backup cases — empty/truncated dumps or
# an HTTP error body saved as the backup — that would otherwise wipe the
# database with nothing to restore. It is not a guarantee the restore succeeds.
postgres_dump_looks_restorable() {
    local dump_file="$1"
    [ -s "$dump_file" ] || return 1
    # Require at least one real schema/data statement, not just comments/SET.
    grep -qiE '^[[:space:]]*(CREATE|COPY|INSERT|ALTER)[[:space:]]' "$dump_file" || return 1
    # pg_dump writes this only after completing the output. Requiring it keeps a
    # dump truncated by a full disk or interrupted process from being accepted.
    grep -qE '^-- PostgreSQL database dump complete([[:space:]]*)$' "$dump_file"
}

# pg_dumpall uses a different completion marker for the globals-only file.
postgres_globals_dump_looks_complete() {
    local dump_file="$1"
    [ -s "$dump_file" ] || return 1
    grep -qE '^-- PostgreSQL database cluster dump complete([[:space:]]*)$' "$dump_file"
}

# Both mysqldump and mariadb-dump emit a completion marker after a successful
# plain-SQL dump. This accepts either tool while rejecting empty and truncated
# files before they can be archived or restored.
mysql_dump_looks_restorable() {
    local dump_file="$1"
    [ -s "$dump_file" ] || return 1
    grep -qE '^-- (MySQL|MariaDB) dump ' "$dump_file" || return 1
    grep -qE '^-- Dump completed on ' "$dump_file"
}

# Detect the dump layout inside an extracted backup directory.
# "multi"  -> new per-database layout (pg_dump/manifest.tsv present)
# "single" -> legacy single-file layout (db_backup.sql present)
# "none"   -> neither
pg_backup_layout() {
    local dir="$1"
    if [ -f "$dir/pg_dump/manifest.tsv" ]; then
        echo "multi"
    elif [ -f "$dir/db_backup.sql" ]; then
        echo "single"
    else
        echo "none"
    fi
}

# Convert a versioned single-database TimescaleDB backup into the same manifest
# layout used by new multi-database backups. Version lookup order supports new
# sidecars, an exact version pinned in the archived compose file, and an
# explicit override for old archives that recorded neither.
pg_promote_timescaledb_single_backup() {
    local restore_dir="$1"
    local database_name="$2"
    local database_owner="$3"
    local log_file="$4"
    local requested_source_version="${5:-}"
    local source_version=""
    local has_timescaledb="1"

    if [ -s "$restore_dir/db_backup.timescaledb-version" ]; then
        source_version=$(head -n 1 "$restore_dir/db_backup.timescaledb-version" | tr -d '[:space:]')
    elif [ -n "$requested_source_version" ]; then
        source_version="$requested_source_version"
    elif [ -s "$restore_dir/docker-compose.yml" ]; then
        source_version=$(sed -nE \
            -e 's#^[[:space:]]*image:[[:space:]]*timescale/timescaledb:([0-9]+([.][0-9]+){1,3})(-pg[0-9]+.*)?[[:space:]]*$#\1#p' \
            -e 's#^[[:space:]]*image:[[:space:]]*timescale/timescaledb-ha:pg[0-9]+-ts([0-9]+([.][0-9]+){1,3})(-all)?[[:space:]]*$#\1#p' \
            "$restore_dir/docker-compose.yml" | head -n 1)
    fi

    if [ "$source_version" = "none" ]; then
        has_timescaledb="0"
        source_version=""
    elif ! timescaledb_version_is_safe "$source_version"; then
        echo "Single-database TimescaleDB backup has no safe source-version metadata" >>"$log_file"
        return 1
    fi
    case "${database_name}${database_owner}" in
        *$'\t'* | *$'\n'*) return 1 ;;
    esac
    [ -n "$database_name" ] && [ -n "$database_owner" ] || return 1

    local dump_dir="$restore_dir/pg_dump"
    mkdir -p "$dump_dir" || return 1
    cp "$restore_dir/db_backup.sql" "$dump_dir/db-001.sql" || return 1

    local owner_ident="${database_owner//\"/\"\"}"
    printf '%s\n' \
        '-- PasarGuard synthetic globals for a legacy single-database backup' \
        "CREATE ROLE \"$owner_ident\";" \
        '-- PostgreSQL database cluster dump complete' >"$dump_dir/globals.sql"
    printf '%s\t%s\t%s\tdb-001.sql\t%s\n' \
        "$database_name" "$database_owner" "$has_timescaledb" "$source_version" >"$dump_dir/manifest.tsv"
    return 0
}

# Strip "DROP/CREATE EXTENSION ... timescaledb" statements from a dump on stdin.
# These would undo the timescaledb_pre_restore() setup during restore.
pg_filter_timescaledb_extension_lines() {
    grep -v -E '^\s*(DROP|CREATE)\s+EXTENSION\s+(IF\s+(EXISTS|NOT\s+EXISTS)\s+)?timescaledb\b' || true
}

# Keep cluster roles and grants from pg_dumpall, but never restore password
# verifiers from another installation. Restoring an archived ALTER ROLE ...
# PASSWORD silently changes the destination password while its .env still has
# the current password, locking the application out after an otherwise
# successful restore.
pg_filter_global_passwords() {
    sed -E \
        -e "s/[[:space:]]+((ENCRYPTED|UNENCRYPTED)[[:space:]]+)?PASSWORD[[:space:]]+'([^']|'')*'//g" \
        -e 's/[[:space:]]+PASSWORD[[:space:]]+NULL//g'
}

# In addition to removing every archived password, keep the destination admin
# role itself entirely unchanged. pg_dumpall emits CREATE ROLE followed by
# ALTER ROLE; the latter succeeds for an existing role and could otherwise
# remove destination privileges or change connection limits.
pg_filter_globals_for_destination() {
    local destination_role="$1"
    pg_filter_global_passwords | awk -v role="$destination_role" '
        BEGIN {
            quoted_role = role
            gsub(/"/, "\"\"", quoted_role)
            quoted_role = "\"" quoted_role "\""
        }
        {
            if ($0 ~ /^(CREATE|ALTER)[[:space:]]+ROLE[[:space:]]/) {
                rest = $0
                sub(/^(CREATE|ALTER)[[:space:]]+ROLE[[:space:]]+/, "", rest)
                if (rest == role || rest == role ";" || index(rest, role " ") == 1 ||
                    rest == quoted_role || rest == quoted_role ";" || index(rest, quoted_role " ") == 1) {
                    next
                }
            }
            print
        }
    '
}

# True (0) when two timescaledb version strings are identical. Restore uses this
# to gate a destructive cross-version restore. The caller treats an empty source
# version (legacy backup) as "do not gate".
timescaledb_version_matches() {
    [ "$1" = "$2" ]
}

# Validate that a TimescaleDB extension version string consists solely of safe
# semantic version numbers and optional hyphen/dot pre-release qualifiers.
timescaledb_version_is_safe() {
    [[ "$1" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][A-Za-z0-9]+)*$ ]]
}

# Stop and remove the temporary TimescaleDB compatibility container and its
# associated Docker volume if they exist.
cleanup_timescaledb_compat_container() {
    local container_name="$1"
    local volume_name="$2"

    [ -n "$container_name" ] && docker rm -f "$container_name" >/dev/null 2>&1 || true
    [ -n "$volume_name" ] && docker volume rm "$volume_name" >/dev/null 2>&1 || true
}

TIMESCALEDB_COMPAT_CONTAINER=""
TIMESCALEDB_COMPAT_VOLUME=""

# Signal handler invoked when the process receives HUP, INT, or TERM during
# compatibility container operations. Ensures temporary containers and volumes
# are cleaned up and application services are restarted before exiting.
handle_timescaledb_compat_signal() {
    local exit_code="$1"
    trap - HUP INT TERM
    cleanup_timescaledb_compat_container "$TIMESCALEDB_COMPAT_CONTAINER" "$TIMESCALEDB_COMPAT_VOLUME"
    TIMESCALEDB_COMPAT_CONTAINER=""
    TIMESCALEDB_COMPAT_VOLUME=""
    if declare -F start_pasarguard_app_services >/dev/null 2>&1; then
        start_pasarguard_app_services >/dev/null 2>&1 || true
    fi
    exit "$exit_code"
}

# Arm signal traps for HUP, INT, and TERM to guarantee cleanup of temporary
# compatibility containers and volumes if interrupted.
arm_timescaledb_compat_cleanup() {
    TIMESCALEDB_COMPAT_CONTAINER="$1"
    TIMESCALEDB_COMPAT_VOLUME="$2"
    trap 'handle_timescaledb_compat_signal 129' HUP
    trap 'handle_timescaledb_compat_signal 130' INT
    trap 'handle_timescaledb_compat_signal 143' TERM
}

# Disarm signal traps and perform final cleanup of the temporary TimescaleDB
# compatibility container and volume.
finish_timescaledb_compat_cleanup() {
    trap - HUP INT TERM
    cleanup_timescaledb_compat_container "$TIMESCALEDB_COMPAT_CONTAINER" "$TIMESCALEDB_COMPAT_VOLUME"
    TIMESCALEDB_COMPAT_CONTAINER=""
    TIMESCALEDB_COMPAT_VOLUME=""
}

# Convert cross-version TimescaleDB dumps before the destination is changed.
# The temporary `pgNN-all` image contains historical extension versions: each
# mismatched database is restored at its source version, upgraded to the exact
# target version, and dumped again. The caller may then use the normal restore
# path against a dump whose extension version matches the destination.
#
# On success PG_PREPARED_DUMP_DIR is set to either source_dir (no conversion was
# needed) or output_dir (every mismatched dump converted and validated).
pg_prepare_timescaledb_compatible_dumps() {
    local destination_container="$1"
    local admin_user="$2"
    local admin_password="$3"
    local source_dir="$4"
    local output_dir="$5"
    local log_file="$6"
    local expected_database="${7:-}"
    local requested_compat_image="${8:-}"
    local manifest="$source_dir/manifest.tsv"

    PG_PREPARED_DUMP_DIR="$source_dir"
    [ -s "$manifest" ] || return 1

    local has_versioned_timescale=false
    local needs_conversion=false
    local dbname owner has_ts filename source_version
    while IFS=$'\t' read -r dbname owner has_ts filename source_version; do
        [ -n "$dbname" ] || continue
        if [ "$has_ts" = "1" ] && [ -z "$source_version" ]; then
            echo "TimescaleDB database '$dbname' has no source-version metadata" >>"$log_file"
            return 1
        elif [ "$has_ts" = "1" ]; then
            has_versioned_timescale=true
            if ! timescaledb_version_is_safe "$source_version"; then
                echo "Unsafe TimescaleDB version in manifest: $source_version" >>"$log_file"
                return 1
            fi
        fi
    done <"$manifest"

    [ "$has_versioned_timescale" = true ] || return 0

    local target_version=""
    local server_version_num=""
    if ! target_version=$(docker exec -e PGPASSWORD="$admin_password" "$destination_container" \
        psql -X -U "$admin_user" -d postgres -At \
        -c "SELECT default_version FROM pg_available_extensions WHERE name = 'timescaledb';" \
        2>>"$log_file") || ! timescaledb_version_is_safe "$target_version"; then
        echo "Could not determine a safe destination TimescaleDB version" >>"$log_file"
        return 1
    fi
    if ! server_version_num=$(docker exec -e PGPASSWORD="$admin_password" "$destination_container" \
        psql -X -U "$admin_user" -d postgres -At -c "SHOW server_version_num;" \
        2>>"$log_file") || [[ ! "$server_version_num" =~ ^[0-9]+$ ]]; then
        echo "Could not determine destination PostgreSQL major version" >>"$log_file"
        return 1
    fi

    while IFS=$'\t' read -r dbname owner has_ts filename source_version; do
        [ -n "$dbname" ] || continue
        if [ "$has_ts" = "1" ] && [ -n "$source_version" ] && [ "$source_version" != "$target_version" ]; then
            needs_conversion=true
            break
        fi
    done <"$manifest"
    [ "$needs_conversion" = true ] || return 0

    local pg_major
    pg_major=$((server_version_num / 10000))
    local target_series="${target_version%.*}"
    local compat_image="${requested_compat_image:-timescale/timescaledb-ha:pg${pg_major}-ts${target_series}-all}"
    local compat_pgdata=""
    case "$compat_image" in
        *timescale/timescaledb-ha:*)
            compat_pgdata="/home/postgres/pgdata/data"
            ;;
        *timescale/timescaledb:*)
            if [ "$pg_major" -ge 18 ]; then
                compat_pgdata="/var/lib/postgresql/${pg_major}/docker"
            else
                compat_pgdata="/var/lib/postgresql/data"
            fi
            ;;
        *)
            echo "Unsupported TimescaleDB compatibility image: $compat_image" >>"$log_file"
            return 1
            ;;
    esac
    local compat_suffix
    compat_suffix="${$}-${RANDOM}-$(date +%s)"
    local compat_container="pasarguard-ts-compat-${compat_suffix}"
    local compat_volume=""

    colorized_echo blue "Preparing TimescaleDB $target_version-compatible dumps before changing the destination..."
    colorized_echo blue "Pulling temporary compatibility image: $compat_image"
    if ! docker pull "$compat_image" >>"$log_file" 2>&1; then
        echo "Could not pull TimescaleDB compatibility image: $compat_image" >>"$log_file"
        return 1
    fi
    if ! compat_volume=$(docker volume create --label "com.pasarguard.restore=$compat_suffix" 2>>"$log_file"); then
        echo "Could not create temporary TimescaleDB compatibility volume" >>"$log_file"
        return 1
    fi
    if ! docker run -d --name "$compat_container" --restart=no \
        --user 0 \
        -e POSTGRES_USER="$admin_user" \
        -e POSTGRES_PASSWORD="$admin_password" \
        -e POSTGRES_HOST_AUTH_METHOD=trust \
        -e POSTGRES_DB=postgres \
        -e PGDATA="$compat_pgdata" \
        -v "$compat_volume:$compat_pgdata" \
        "$compat_image" >>"$log_file" 2>&1; then
        echo "Could not start temporary TimescaleDB compatibility container" >>"$log_file"
        cleanup_timescaledb_compat_container "" "$compat_volume"
        return 1
    fi
    arm_timescaledb_compat_cleanup "$compat_container" "$compat_volume"

    local ready=false
    local waited=0
    while [ "$waited" -lt 180 ]; do
        if docker exec "$compat_container" pg_isready -q -U "$admin_user" -d postgres >/dev/null 2>&1 && \
           docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
               psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            # Verify the container is stable and not in a temporary initdb/bootstrap restart window
            sleep 3
            if docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
                ready=true
                break
            fi
        fi
        local container_status=""
        container_status=$(docker inspect -f '{{.State.Status}}' "$compat_container" 2>/dev/null || true)
        if [ "$container_status" = "exited" ] || [ "$container_status" = "dead" ]; then
            echo "Temporary TimescaleDB compatibility container stopped unexpectedly with status: $container_status" >>"$log_file"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    if [ "$ready" != true ]; then
        echo "Temporary TimescaleDB compatibility container did not become ready" >>"$log_file"
        docker logs "$compat_container" >>"$log_file" 2>&1 || true
        finish_timescaledb_compat_cleanup
        return 1
    fi

    # Verify every required version exists before doing any conversion work.
    local required_versions="$target_version"
    while IFS=$'\t' read -r dbname owner has_ts filename source_version; do
        [ "$has_ts" = "1" ] && [ -n "$source_version" ] || continue
        if ! grep -F -x -q "$source_version" <<<"$required_versions"; then
            required_versions+=$'\n'"$source_version"
        fi
    done <"$manifest"
    local required_version available_count
    while IFS= read -r required_version; do
        [ -n "$required_version" ] || continue
        available_count="0"
        local check_try=0
        while [ "$check_try" -lt 15 ]; do
            if available_count=$(docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
                psql -X -U "$admin_user" -d postgres -At \
                -c "SELECT count(*) FROM pg_available_extension_versions WHERE name = 'timescaledb' AND version = '$required_version';" \
                2>>"$log_file") && [ "$available_count" = "1" ]; then
                break
            fi
            sleep 2
            check_try=$((check_try + 1))
        done
        if [ "$available_count" != "1" ]; then
            echo "Compatibility image $compat_image does not contain TimescaleDB $required_version" >>"$log_file"
            docker logs "$compat_container" >>"$log_file" 2>&1 || true
            finish_timescaledb_compat_cleanup
            return 1
        fi
    done <<<"$required_versions"

    if ! mkdir -p "$output_dir"; then
        finish_timescaledb_compat_cleanup
        return 1
    fi
    cp "$source_dir/globals.sql" "$output_dir/globals.sql" 2>>"$log_file" || {
        finish_timescaledb_compat_cleanup
        rm -rf "$output_dir"
        return 1
    }
    : >"$output_dir/manifest.tsv"

    local filtered_globals="$output_dir/globals.no-passwords.sql"
    if ! pg_filter_globals_for_destination "$admin_user" <"$source_dir/globals.sql" >"$filtered_globals"; then
        finish_timescaledb_compat_cleanup
        rm -rf "$output_dir"
        return 1
    fi
    docker exec -i -e PGPASSWORD="$admin_password" "$compat_container" \
        psql -X -U "$admin_user" -d postgres <"$filtered_globals" >>"$log_file" 2>&1 || true
    rm -f "$filtered_globals"

    local index=0
    local converted_ok=true
    while IFS=$'\t' read -r dbname owner has_ts filename source_version; do
        [ -n "$dbname" ] || continue
        index=$((index + 1))
        if [ "$has_ts" != "1" ] || [ -z "$source_version" ] || [ "$source_version" = "$target_version" ]; then
            if ! cp "$source_dir/$filename" "$output_dir/$filename" 2>>"$log_file"; then
                converted_ok=false
                break
            fi
            if ! printf '%s\t%s\t%s\t%s\t%s\n' "$dbname" "$owner" "$has_ts" "$filename" "$source_version" >>"$output_dir/manifest.tsv"; then
                converted_ok=false
                break
            fi
            continue
        fi

        local compat_db="pasarguard_restore_${index}"
        local filtered_dump="$output_dir/${filename}.source-filtered"
        colorized_echo blue "Converting '$dbname' from TimescaleDB $source_version to $target_version..."
        if ! docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
            psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d postgres \
            -c "CREATE DATABASE \"$compat_db\" TEMPLATE template0 OWNER \"${admin_user//\"/\"\"}\";" >>"$log_file" 2>&1 ||
            ! docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d "$compat_db" \
                -c "DROP EXTENSION IF EXISTS timescaledb CASCADE;" >>"$log_file" 2>&1 ||
            ! docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d "$compat_db" \
                -c "CREATE EXTENSION timescaledb VERSION '$source_version';" >>"$log_file" 2>&1 ||
            ! docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d "$compat_db" \
                -c "SELECT timescaledb_pre_restore();" >>"$log_file" 2>&1; then
            converted_ok=false
            break
        fi

        if ! pg_filter_timescaledb_extension_lines <"$source_dir/$filename" >"$filtered_dump"; then
            converted_ok=false
            break
        fi
        if ! docker exec -i -e PGPASSWORD="$admin_password" "$compat_container" \
            psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d "$compat_db" <"$filtered_dump" >>"$log_file" 2>&1 ||
            ! docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d "$compat_db" \
                -c "SELECT timescaledb_post_restore();" >>"$log_file" 2>&1 ||
            ! docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" -d "$compat_db" \
                -c "ALTER EXTENSION timescaledb UPDATE TO '$target_version';" >>"$log_file" 2>&1 ||
            ! docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
                pg_dump -U "$admin_user" -d "$compat_db" --clean --if-exists >"$output_dir/$filename" 2>>"$log_file" ||
            ! postgres_dump_looks_restorable "$output_dir/$filename"; then
            converted_ok=false
            rm -f "$filtered_dump"
            break
        fi
        rm -f "$filtered_dump"
        if ! printf '%s\t%s\t1\t%s\t%s\n' "$dbname" "$owner" "$filename" "$target_version" >>"$output_dir/manifest.tsv"; then
            converted_ok=false
            break
        fi
        docker exec -e PGPASSWORD="$admin_password" "$compat_container" \
            psql -X -U "$admin_user" -d postgres -c "DROP DATABASE \"$compat_db\";" >>"$log_file" 2>&1 || true
    done <"$manifest"

    if [ "$converted_ok" != true ]; then
        docker logs "$compat_container" >>"$log_file" 2>&1 || true
    fi
    finish_timescaledb_compat_cleanup
    if [ "$converted_ok" != true ] || ! postgres_backup_looks_restorable "$(dirname "$output_dir")" "$expected_database"; then
        echo "TimescaleDB compatibility conversion failed validation" >>"$log_file"
        rm -rf "$output_dir"
        return 1
    fi

    PG_PREPARED_DUMP_DIR="$output_dir"
    colorized_echo green "TimescaleDB dumps converted to destination version $target_version."
    return 0
}

# Operator-facing guidance shown when a backup's timescaledb version does not
# match this server's. Values are filled in so the output is copy-pasteable.
# Empty tgt_ver -> "not installed"; empty pg_major -> a pgNN placeholder.
format_timescaledb_mismatch_help() {
    local dbname="$1" src_ver="$2" tgt_ver="$3" pg_major="$4" app_name="$5"
    local tgt_display="${tgt_ver:-not installed}"
    local tag_suffix="pg${pg_major}"
    if [ -z "$pg_major" ]; then
        tag_suffix="pgNN   (replace NN with your PostgreSQL major version)"
    fi
    local target_series="${tgt_ver%.*}"
    local compat_tag="${tag_suffix}-all"
    if timescaledb_version_is_safe "$tgt_ver"; then
        compat_tag="${tag_suffix}-ts${target_series}-all"
    fi
    printf '%s\n' \
"TimescaleDB version mismatch for database '$dbname':" \
"  this backup was taken with timescaledb $src_ver" \
"  but THIS server has timescaledb $tgt_display" \
"Automatic compatibility conversion could not be completed." \
"The restore was stopped BEFORE changing anything - your current data is untouched." \
"Required compatibility image: timescale/timescaledb-ha:${compat_tag}" \
"Check Docker connectivity and the restore log, then run '$app_name restore' again."
}

# Restore every database listed in <pg_dump_dir>/manifest.tsv. Globals are
# restored first (without ON_ERROR_STOP so pre-existing roles don't abort it);
# each database is then DROP/CREATEd with its recorded owner and loaded, using
# the TimescaleDB-safe procedure when has_timescaledb=1. Per-database failures
# are isolated and reported. Returns 0 only if every database restored.
pg_restore_all_user_databases() {
    local container_name="$1"
    local restore_user="$2"
    local restore_password="$3"
    local admin_user="$4"
    local admin_password="$5"
    local pg_dump_dir="$6"
    local log_file="$7"
    local source_app_database="${8:-}"
    local target_app_database="${9:-}"
    local target_app_owner="${10:-}"

    local manifest="$pg_dump_dir/manifest.tsv"
    if [ ! -s "$manifest" ]; then
        echo "Manifest missing or empty: $manifest" >>"$log_file"
        return 1
    fi

    if [ -s "$pg_dump_dir/globals.sql" ]; then
        colorized_echo blue "Restoring global roles and grants..."
        local filtered_globals="$pg_dump_dir/globals.no-passwords.sql"
        if ! pg_filter_globals_for_destination "$admin_user" <"$pg_dump_dir/globals.sql" >"$filtered_globals"; then
            echo "Could not remove archived role passwords from globals.sql" >>"$log_file"
            return 1
        fi
        docker exec -i -e PGPASSWORD="$admin_password" "$container_name" \
            psql -X -U "$admin_user" -d postgres <"$filtered_globals" >>"$log_file" 2>&1 || true
        rm -f "$filtered_globals"
    fi

    local total=0 ok=0
    local dbname owner has_ts filename ts_version
    while IFS=$'\t' read -r dbname owner has_ts filename ts_version; do
        [ -n "$dbname" ] || continue
        total=$((total + 1))
        local dump_path="$pg_dump_dir/$filename"

        if ! postgres_dump_looks_restorable "$dump_path"; then
            colorized_echo red "Dump for database '$dbname' is missing or invalid; skipping."
            echo "Validation failed for $dump_path" >>"$log_file"
            continue
        fi

        local destination_dbname="$dbname"
        local destination_owner="$owner"
        if [ -n "$source_app_database" ] && [ "$dbname" = "$source_app_database" ]; then
            destination_dbname="${target_app_database:-$dbname}"
            destination_owner="${target_app_owner:-$owner}"
        fi

        local db_ident="${destination_dbname//\"/\"\"}"
        local db_sql="${destination_dbname//\'/\'\'}"
        local owner_ident="${destination_owner//\"/\"\"}"
        [ -n "$owner_ident" ] || owner_ident="$admin_user"

        # TimescaleDB cross-version safety gate. If this backup recorded a
        # timescaledb version, refuse to touch the database unless THIS server's
        # bundled version matches. Runs BEFORE any terminate/DROP so a mismatch
        # never wipes or half-restores data. The preflight rejects versionless
        # Timescale manifests before this function is called.
        if [ "$has_ts" = "1" ] && [ -n "$ts_version" ]; then
            # Read THIS server's bundled timescaledb version (read-only). Separate
            # a probe that FAILED (transient docker/psql error -> non-zero exit)
            # from one that SUCCEEDED but returned nothing (the target genuinely
            # has no timescaledb available). Only a successful probe gates the
            # restore: both a failed probe and a successful empty result fail
            # closed before any destructive step.
            local target_ts="" probe_ok=0
            if target_ts=$(docker exec -e PGPASSWORD="$admin_password" "$container_name" \
                psql -X -U "$admin_user" -d postgres -At \
                -c "SELECT default_version FROM pg_available_extensions WHERE name = 'timescaledb';" \
                2>>"$log_file"); then
                probe_ok=1
            else
                target_ts=""
            fi
            if [ "$probe_ok" = "1" ] && ! timescaledb_version_matches "$ts_version" "$target_ts"; then
                local svn="" pg_major=""
                svn=$(docker exec -e PGPASSWORD="$admin_password" "$container_name" \
                    psql -X -U "$admin_user" -d postgres -At -c "SHOW server_version_num;" \
                    2>>"$log_file") || svn=""
                [ -n "$svn" ] && pg_major=$(( svn / 10000 ))
                colorized_echo red "$(format_timescaledb_mismatch_help "$dbname" "$ts_version" "$target_ts" "$pg_major" "${APP_NAME:-pasarguard}")"
                echo "TimescaleDB version mismatch for '$dbname' (backup=$ts_version target=${target_ts:-unavailable}); skipped before any destructive change" >>"$log_file"
                continue
            elif [ "$probe_ok" != "1" ]; then
                colorized_echo red "Could not verify this server's TimescaleDB version for '$dbname'; skipping it before any destructive change."
                echo "Could not read target timescaledb version for '$dbname'; skipped before destructive change" >>"$log_file"
                continue
            fi
        fi

        colorized_echo blue "Restoring database '$dbname' as '$destination_dbname'..."
        docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" -d postgres \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_sql' AND pid <> pg_backend_pid();" \
            >>"$log_file" 2>&1
        docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" -d postgres \
            -c "DROP DATABASE IF EXISTS \"$db_ident\";" >>"$log_file" 2>&1
        if ! docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" -d postgres \
            -c "CREATE DATABASE \"$db_ident\" OWNER \"$owner_ident\";" >>"$log_file" 2>&1; then
            colorized_echo red "Failed to create database '$dbname'; skipping."
            echo "CREATE DATABASE failed for '$dbname'" >>"$log_file"
            continue
        fi

        local restored=false
        if [ "$has_ts" = "1" ]; then
            local create_extension_sql="CREATE EXTENSION IF NOT EXISTS timescaledb;"
            if [ -n "$ts_version" ]; then
                create_extension_sql="CREATE EXTENSION IF NOT EXISTS timescaledb VERSION '$ts_version';"
            fi
            if ! docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -X -v ON_ERROR_STOP=1 -U "$admin_user" --dbname="$destination_dbname" \
                -c "$create_extension_sql" >>"$log_file" 2>&1 ||
                ! docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -X -v ON_ERROR_STOP=1 -U "$admin_user" --dbname="$destination_dbname" \
                    -c "SELECT timescaledb_pre_restore();" >>"$log_file" 2>&1; then
                colorized_echo red "Could not prepare TimescaleDB database '$destination_dbname'."
                continue
            fi
            local filtered="$pg_dump_dir/${filename}.filtered"
            pg_filter_timescaledb_extension_lines < "$dump_path" > "$filtered" 2>>"$log_file"
            if docker exec -i -e PGPASSWORD="$restore_password" "$container_name" \
                psql -X -v ON_ERROR_STOP=1 -U "$restore_user" --dbname="$destination_dbname" < "$filtered" >>"$log_file" 2>&1; then
                restored=true
            elif docker exec -i -e PGPASSWORD="$admin_password" "$container_name" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" --dbname="$destination_dbname" < "$filtered" >>"$log_file" 2>&1; then
                restored=true
            fi
            rm -f "$filtered"
            docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -X -U "$admin_user" --dbname="$destination_dbname" \
                -c "SELECT timescaledb_post_restore();" >>"$log_file" 2>&1
        else
            if docker exec -i -e PGPASSWORD="$restore_password" "$container_name" \
                psql -X -v ON_ERROR_STOP=1 -U "$restore_user" --dbname="$destination_dbname" < "$dump_path" >>"$log_file" 2>&1; then
                restored=true
            elif docker exec -i -e PGPASSWORD="$admin_password" "$container_name" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" --dbname="$destination_dbname" < "$dump_path" >>"$log_file" 2>&1; then
                restored=true
            fi
        fi

        if [ "$restored" = true ] && [ "$destination_owner" != "$owner" ] && [ -n "$owner" ] && [ -n "$destination_owner" ]; then
            local source_owner_ident="${owner//\"/\"\"}"
            local target_owner_ident="${destination_owner//\"/\"\"}"
            if ! docker exec -e PGPASSWORD="$admin_password" "$container_name" \
                psql -X -v ON_ERROR_STOP=1 -U "$admin_user" --dbname="$destination_dbname" \
                -c "REASSIGN OWNED BY \"$source_owner_ident\" TO \"$target_owner_ident\";" >>"$log_file" 2>&1; then
                echo "Could not reassign '$destination_dbname' from '$owner' to '$destination_owner'" >>"$log_file"
                restored=false
            fi
        fi

        if [ "$restored" = true ]; then
            colorized_echo green "Database '$dbname' restored."
            ok=$((ok + 1))
        else
            colorized_echo red "Database '$dbname' restore failed. Check log: $log_file"
        fi
    done < "$manifest"

    colorized_echo blue "Restored $ok of $total databases."
    # A skipped database (failed dump validation OR a version-gate mismatch)
    # increments 'total' but never 'ok', so this yields non-zero whenever any
    # database was skipped. Do not "simplify" these counters — that guarantee
    # depends on it.
    [ "$total" -gt 0 ] && [ "$ok" -eq "$total" ]
}

# Read recovery metadata as data, without evaluating archived shell input.
backup_runtime_value() {
    local stage="$1" key="$2"
    [ -f "$stage/backup-runtime.tsv" ] || return 1
    awk -F '\t' -v key="$key" '$1 == key {print $2; exit}' "$stage/backup-runtime.tsv"
}

# Validate every recorded payload before parsing credentials or touching Docker.
# Legacy archives have no checksum inventory and retain structural validation.
# Every archive with recovery metadata was written with an inventory, so a
# missing one means the archive was altered.
verify_backup_checksums() {
    local stage="$1" inventory="$1/backup-files.sha256"
    local line="" path="" digest="" count=0
    if [ ! -e "$inventory" ]; then
        if [ -e "$stage/backup-runtime.tsv" ]; then
            colorized_echo red "This backup has recovery metadata but no backup-files.sha256 inventory, so its payload cannot be verified."
            return 1
        fi
        colorized_echo yellow "Legacy backup: no checksum inventory; only archive structure and database dump checks apply."
        return 0
    fi
    [ ! -L "$inventory" ] && [ -s "$inventory" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        digest="${line:0:64}"
        [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
        case "${line:64:2}" in '  '|' *') ;; *) return 1 ;; esac
        path="${line:66}"
        case "$path" in
            ./*) ;;
            *) return 1 ;;
        esac
        case "$path" in *$'\r'* | *\\* | */../* | */.. | */./* | ./backup-files.sha256) return 1 ;; esac
        [ -f "$stage/$path" ] && [ ! -L "$stage/$path" ] || return 1
        count=$((count + 1))
    done <"$inventory"
    [ "$count" -gt 0 ] || return 1
    (cd "$stage" && sha256sum --check --status backup-files.sha256)
}

print_backup_runtime() {
    local stage="$1"
    if [ ! -f "$stage/backup-runtime.tsv" ]; then
        colorized_echo yellow "Legacy backup: exact source image digests were not recorded. Use an installation with the original panel/database versions."
        return 0
    fi
    [ "$(backup_runtime_value "$stage" format)" = 1 ] || {
        colorized_echo red "Unsupported recovery metadata format. Update the PasarGuard script."
        return 1
    }
    local key="" value="" digest="" image_id=""
    while IFS=$'\t' read -r key value digest image_id; do
        case "$key" in
            created_utc|database|server_version|dump_tool_version|schema_revision|project|app_dir|data_dir)
                printf '%s: %s\n' "$key" "$value" ;;
            image) printf 'Recovery image (%s): %s\n' "$value" "$digest" ;;
        esac
    done <"$stage/backup-runtime.tsv"
}

# Reject cross-engine imports and version downgrades before the first SQL
# statement. Upgrades within one engine still use its normal logical restore
# path (and the existing TimescaleDB compatibility conversion).
check_restore_database_version() {
    local stage="$1" engine="$2" container="$3" log="$4"
    local source_version="" target_version="" client="mysql" user="" password=""
    source_version=$(backup_runtime_value "$stage" server_version) || source_version=""
    if [[ ! "$source_version" =~ ^([0-9]+)\.([0-9]+) ]]; then
        # Old SQL dumps commonly retain a useful server-version header.
        source_version=$(sed -n -E 's/^-- (Server version[[:space:]]+|Dumped from database version )//p' "$stage/db_backup.sql" 2>/dev/null | head -n 1)
    fi
    [[ "$source_version" =~ ^([0-9]+)\.([0-9]+) ]] || return 0
    local source_major="${BASH_REMATCH[1]}" source_minor="${BASH_REMATCH[2]}"
    case "$engine" in
        mysql|mariadb)
            if docker exec "$container" mariadb --version >/dev/null 2>&1; then client=mariadb; fi
            if [ -n "$current_mysql_root_password" ]; then
                user=root; password="$current_mysql_root_password"
            else
                user="${current_db_user:-$db_user}"; password="${current_db_password:-$db_password}"
            fi
            target_version=$(docker exec -e MYSQL_PWD="$password" "$container" "$client" \
                -u "$user" -N -s -e 'SELECT VERSION();' 2>>"$log") || return 1
            if { [[ "$source_version" == *MariaDB* ]] && [[ "$target_version" != *MariaDB* ]]; } || \
                { [[ "$source_version" != *MariaDB* ]] && [[ "$target_version" == *MariaDB* ]]; }; then
                colorized_echo red "Backup engine ($source_version) differs from destination ($target_version). Restore with the original engine, or use --fresh on an empty server."
                return 1
            fi
            ;;
        postgresql|timescaledb)
            user="${current_db_user:-${db_user:-postgres}}"; password="${current_db_password:-$db_password}"
            target_version=$(docker exec -e PGPASSWORD="$password" "$container" psql -X -U "$user" -d postgres -At \
                -c 'SHOW server_version;' 2>>"$log") || return 1
            ;;
        *) return 0 ;;
    esac
    [[ "$target_version" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    local target_major="${BASH_REMATCH[1]}" target_minor="${BASH_REMATCH[2]}"
    if [ "$source_major" -gt "$target_major" ] || \
        { [[ "$engine" =~ ^(mysql|mariadb)$ ]] && [ "$source_major" -eq "$target_major" ] && [ "$source_minor" -gt "$target_minor" ]; }; then
        colorized_echo red "Database downgrade is unsupported (backup: $source_version, destination: $target_version). Use the source version or --fresh on an empty server."
        return 1
    fi
}

# Ask the database server inside its container whether it accepts connections.
# Probe over TCP: on an empty data directory the image entrypoint first runs a
# temporary socket-only server for initialisation, which must not be mistaken
# for the final server. A refused login still proves the server is up.
recovery_database_responds() {
    local container="$1" engine="$2" port="$3"
    case "$engine" in
        postgresql|timescaledb)
            docker exec "$container" pg_isready -q -h 127.0.0.1 -p "$port"
            ;;
        mysql|mariadb)
            # shellcheck disable=SC2016 # $1 expands inside the container shell.
            docker exec "$container" sh -c 'if command -v mariadb-admin >/dev/null 2>&1; then exec mariadb-admin ping --silent -h 127.0.0.1 -P "$1"; fi; exec mysqladmin ping --silent -h 127.0.0.1 -P "$1"' sh "$port"
            ;;
        *) return 1 ;;
    esac
}

# Wait until the fresh database can take the import. A Compose healthcheck is
# authoritative when present; a service without one stays "running" while it
# initialises, so probe the server itself on the connection URL port, then on
# the engine's default port (the URL may name a published host port).
wait_for_recovery_database() {
    local container="$1" engine="$2" port="$3" log="$4"
    local state="" waited=0 default_port=5432
    case "$engine" in mysql|mariadb) default_port=3306 ;; esac
    [ -n "$port" ] || port="$default_port"
    while [ "$waited" -lt 180 ]; do
        state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>>"$log") || return 1
        case "$state" in
            healthy) return 0 ;;
            running)
                if recovery_database_responds "$container" "$engine" "$port" >>"$log" 2>&1; then return 0; fi
                if [ "$port" != "$default_port" ] && recovery_database_responds "$container" "$engine" "$default_port" >>"$log" 2>&1; then
                    return 0
                fi
                ;;
            exited|dead|unhealthy) break ;;
        esac
        sleep 2
        waited=$((waited + 2))
    done
    docker logs --tail 80 "$container" >>"$log" 2>&1 || true
    colorized_echo red "Recovery database did not become ready. The panel has not been started. See the restore log."
    return 1
}

# Prepare a fresh deployment using the source images. Refuse existing app/data,
# containers and database storage; this mode is never an in-place downgrade.
# The archived Compose file is installed unchanged. Each recorded source image
# gets the name that file already uses (for example pasarguard/panel:latest),
# so Compose runs the source versions now and `pasarguard update` can still
# pull newer images later.
# Arguments: stage, engine, log, database port from the connection URL, and the
# name of the caller's variable that receives the database container ID.
prepare_fresh_restore() {
    local stage="$1" engine="$2" log="$3" db_port="$4" container_var="$5"
    local recovery_compose="$stage/docker-compose.yml"
    [ "$(backup_runtime_value "$stage" format)" = 1 ] || {
        colorized_echo red "--fresh needs a backup with recovery metadata. For a legacy backup, install the original versions and run restore with its file path."
        return 1
    }
    local key="" expected=""
    for key in project app_dir data_dir; do
        expected=$(backup_runtime_value "$stage" "$key")
        case "$key" in
            project) [ "$expected" = "$APP_NAME" ] && continue ;;
            app_dir) [ "$expected" = "$APP_DIR" ] && continue ;;
            data_dir) [ "$expected" = "$DATA_DIR" ] && continue ;;
        esac
        colorized_echo red "Recovery $key must match the backup ($expected). Set APP_NAME, APP_DIR and DATA_DIR to the recorded values, then retry."
        return 1
    done
    local directory=""
    for directory in "$APP_DIR" "$DATA_DIR"; do
        [[ "$directory" == /* ]] && [ "$directory" != / ] && [ ! -L "$directory" ] || return 1
        local existing_entry=""
        if [ -d "$directory" ]; then
            if [ "$directory" = "$APP_DIR" ]; then
                existing_entry=$(find "$directory" -mindepth 1 -maxdepth 1 ! -name backup -print -quit) || return 1
            else
                existing_entry=$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit) || return 1
            fi
        fi
        if [ -e "$directory" ] && { [ ! -d "$directory" ] || [ -n "$existing_entry" ]; }; then
            colorized_echo red "--fresh requires empty application and data directories: $directory. Use ordinary restore for an existing installation."
            return 1
        fi
    done
    [ -f "$recovery_compose" ] && [ ! -L "$recovery_compose" ] || return 1
    if ! command -v jq >/dev/null 2>&1; then detect_os; install_package jq; fi

    local config="$stage/.pasarguard-recovery-compose.json"
    # Resolve env_file references and image interpolation in staging, then
    # translate relative bind paths for the storage checks against the
    # eventual installation.
    $COMPOSE --project-directory "$stage" --env-file "$stage/.env" -f "$recovery_compose" -p "$APP_NAME" \
        config --format json >"$config" 2>>"$log" || return 1
    jq --arg stage "$stage/" --arg app "$APP_DIR/" \
        '(.services[].volumes[]? | select(.type == "bind") | .source) |=
         (if startswith($stage) then $app + ltrimstr($stage) else . end)' \
        "$config" >"$config.tmp" && mv "$config.tmp" "$config" || return 1

    # Pair each service's Compose image name with its recorded source image.
    local services="" service="" image="" digest="" image_id="" reference="" record=""
    local recovery_images=()
    services=$(jq -r '.services | keys[]' "$config") || return 1
    [ -n "$services" ] || return 1
    while IFS= read -r service; do
        [[ "$service" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || return 1
        image=$(jq -r --arg service "$service" '.services[$service].image // empty' "$config") || return 1
        if [[ ! "$image" =~ ^[a-zA-Z0-9._:/@-]+$ ]]; then
            colorized_echo red "Service '$service' has no usable image name in docker-compose.yml. --fresh supports image-based services only."
            return 1
        fi
        record=$(awk -F '\t' -v service="$service" '$1 == "image" && $2 == service {print $3 "\t" $4; exit}' "$stage/backup-runtime.tsv")
        IFS=$'\t' read -r digest image_id <<<"$record"
        reference=""
        [[ ! "$digest" =~ ^[a-zA-Z0-9._:/-]+@sha256:[a-f0-9]{64}$ ]] || reference="$digest"
        # docker save/load by image ID can retain the original image without
        # RepoDigests. Prefer that local image over a registry download.
        if [[ "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] && docker image inspect "$image_id" >/dev/null 2>&1 && \
            { [ -z "$reference" ] || ! docker image inspect "$reference" >/dev/null 2>&1; }; then
            reference="$image_id"
        fi
        if [ -z "$reference" ]; then
            colorized_echo red "No reproducible image for service '$service'. Load its original Docker image or use ordinary restore with explicitly pinned source versions."
            return 1
        fi
        # A name that is already a digest cannot be retagged; it must be the recorded one.
        if [[ "$image" == *@sha256:* ]]; then
            if [ "$image" != "$digest" ]; then
                colorized_echo red "docker-compose.yml pins service '$service' to $image, but the backup recorded ${digest}. Restore the original Compose file or use ordinary restore."
                return 1
            fi
            reference="$digest"
        fi
        recovery_images+=("$reference"$'\t'"$image")
    done <<<"$services"
    local existing=""
    existing=$($COMPOSE --project-directory "$stage" --env-file "$stage/.env" -f "$recovery_compose" -p "$APP_NAME" ps -a -q 2>>"$log") || return 1
    [ -z "$existing" ] || { colorized_echo red "This Compose project already has containers. Use ordinary restore."; return 1; }
    local source=""
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        if [ -L "$source" ]; then
            colorized_echo red "Bind-mounted storage at $source is a symbolic link. Use ordinary restore after checking its target."
            return 1
        fi
        case "$source" in "$APP_DIR"|"$APP_DIR/"*|"$DATA_DIR"|"$DATA_DIR/"*) continue ;; esac
        if [ -e "$source" ] && { [ ! -d "$source" ] || [ -n "$(find "$source" -mindepth 1 -print -quit)" ]; }; then
            colorized_echo red "Existing bind-mounted storage at $source. --fresh will not overwrite it."
            return 1
        fi
    done < <(jq -r '.services[].volumes[]? | select(.type == "bind") | .source' "$config")
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        if docker volume inspect "$source" >/dev/null 2>&1; then
            colorized_echo red "Existing Docker volume '$source'. --fresh will not reuse it."
            return 1
        fi
    done < <(jq -r '.volumes // {} | .[].name' "$config")
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        if docker inspect "$source" >/dev/null 2>&1; then
            colorized_echo red "Container name '$source' is already in use. --fresh will not replace it."
            return 1
        fi
    done < <(jq -r '.services[].container_name // empty' "$config")
    if jq -e '.volumes // {} | .[] | select(.external == true)' "$config" >/dev/null; then
        colorized_echo red "External volumes need manual provisioning; use ordinary restore for this custom deployment."
        return 1
    fi
    local db_service=""
    if [ "$engine" != sqlite ]; then
        case "$engine" in
            mysql|mariadb) db_service=$(jq -r '.services | keys[] | select(. == "mysql" or . == "mariadb")' "$config" | head -n 1) ;;
            postgresql|timescaledb) db_service=$(jq -r '.services | keys[] | select(. == "postgresql" or . == "timescaledb")' "$config" | head -n 1) ;;
        esac
        [ -n "$db_service" ] || { colorized_echo red "--fresh supports local database services in the official Compose layouts."; return 1; }
    fi
    colorized_echo blue "Fetching the recorded recovery images before provisioning the installation..."
    local entry=""
    for entry in "${recovery_images[@]}"; do
        reference="${entry%%$'\t'*}"
        if ! docker image inspect "$reference" >/dev/null 2>&1; then
            docker pull "$reference" >>"$log" 2>&1 || {
                colorized_echo red "Cannot fetch recovery image $reference. Check registry access, or docker load the original image and retry."
                return 1
            }
        fi
    done
    for entry in "${recovery_images[@]}"; do
        reference="${entry%%$'\t'*}"
        image="${entry#*$'\t'}"
        [[ "$image" != *@sha256:* ]] || continue
        docker tag "$reference" "$image" >>"$log" 2>&1 || {
            colorized_echo red "Cannot tag recovery image $reference as $image."
            return 1
        }
        colorized_echo blue "Using recorded image $reference as $image"
    done
    mkdir -p "$APP_DIR" "$DATA_DIR" || return 1
    install -m 600 "$stage/.env" "$ENV_FILE" || return 1
    install -m 600 "$recovery_compose" "$COMPOSE_FILE" || return 1
    if [ -n "$db_service" ]; then
        colorized_echo blue "Starting only the database; panel migrations stay stopped until the import finishes."
        $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d --no-deps "$db_service" >>"$log" 2>&1 || return 1
        local container=""
        container=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps -q "$db_service") || return 1
        [ -n "$container" ] || return 1
        wait_for_recovery_database "$container" "$engine" "$db_port" "$log" || return 1
        # Hand the exact container to the import; name-based lookups can match
        # an unrelated container on the host.
        [ -z "$container_var" ] || printf -v "$container_var" '%s' "$container"
    fi
}

# Execute interactive restore of PasarGuard databases, configurations, and data.
restore_command() {
    local restore_file="" fresh_restore=false check_only=false assume_yes=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fresh) fresh_restore=true ;;
            --check) check_only=true ;;
            --yes) assume_yes=true ;;
            --file)
                [ "$#" -ge 2 ] || { colorized_echo red "--file requires an archive path."; return 1; }
                shift
                restore_file="$1"
                ;;
            --help|-h)
                echo "Usage: pasarguard restore [ARCHIVE | --file ARCHIVE] [--check] [--fresh] [--yes]"
                echo "  --check  Validate the archive and show source versions without starting/stopping services."
                echo "  --fresh  Recover onto an empty server using recorded images; no previous panel install needed."
                echo "  --yes    Skip the confirmation prompt (archive checks still apply)."
                return 0
                ;;
            -*) colorized_echo red "Unknown restore option: $1"; return 1 ;;
            *)
                [ -z "$restore_file" ] || { colorized_echo red "Specify only one backup archive."; return 1; }
                restore_file="$1"
                ;;
        esac
        shift
    done
    if [ -n "$restore_file" ]; then
        [ -f "$restore_file" ] && [ -r "$restore_file" ] || { colorized_echo red "Backup archive is missing or unreadable: $restore_file"; return 1; }
        restore_file="$(cd -- "$(dirname -- "$restore_file")" && pwd)/$(basename -- "$restore_file")"
        local requested_name="${restore_file##*/}" requested_dir="${restore_file%/*}"
        if [[ "$requested_name" =~ \.part[0-9]{2}\.zip$ ]]; then
            local part_base="${requested_name%%.part*}"
            if [ -f "$requested_dir/$part_base.part00.zip" ]; then
                restore_file="$requested_dir/$part_base.part00.zip"
            elif [ -f "$requested_dir/$part_base.part01.zip" ]; then
                restore_file="$requested_dir/$part_base.part01.zip"
            fi
        elif [[ "$requested_name" =~ \.z[0-9]{2}$ ]]; then
            restore_file="$requested_dir/${requested_name%.z??}.zip"
            [ -f "$restore_file" ] || { colorized_echo red "Missing final .zip file for the split archive."; return 1; }
        fi
    fi
    colorized_echo blue "Starting restore process..."

    if [ "$fresh_restore" = false ] && [ "$check_only" = false ]; then
        if ! is_pasarguard_installed || [ ! -f "$COMPOSE_FILE" ]; then
            colorized_echo red "No installation found. To recover onto an empty server, use: pasarguard restore --fresh /path/to/backup.zip"
            return 1
        fi
        detect_compose
    fi

    local current_db_user=""
    local current_db_password=""
    local current_db_name=""
    local current_sqlalchemy_url=""
    local current_mysql_root_password=""
    local requested_timescaledb_backup_version="${TIMESCALEDB_BACKUP_VERSION:-}"
    local requested_timescaledb_compat_image="${TIMESCALEDB_COMPAT_IMAGE:-}"
    local sqlite_basename=""
    local sqlite_backup_source=""
    local sqlite_safety_backup=""
    local services_stopped=false
    local restore_timestamp=""
    restore_timestamp=$(date +%Y%m%d%H%M%S)

    # Redact credentials embedded in a database connection URL for safe logging.
    redact_database_url() {
        local url="$1"

        if [ -z "$url" ]; then
            printf '%s\n' "not set"
            return 0
        fi

        printf '%s\n' "$url" | sed -E 's#^([^:]+://)([^@/]+)@#\1REDACTED@#'
    }

    if [ "$fresh_restore" = false ] && [ "$check_only" = false ] && [ -f "$ENV_FILE" ]; then
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
    local archive_dir="$backup_dir"
    local restore_staging_root=""
    local temp_restore_dir=""
    local current_compose_snapshot=""

    # Check if backup directory exists
    if [ -n "$restore_file" ]; then
        archive_dir=$(dirname -- "$restore_file")
    fi
    if [ ! -d "$archive_dir" ]; then
        colorized_echo red "Backup directory not found: $backup_dir"
        exit 1
    fi

    # Restores can be large, so avoid /tmp by default and stage beside the
    # backup unless RESTORE_TMPDIR is explicitly set.
    restore_staging_root="${RESTORE_TMPDIR:-$archive_dir}"
    if ! mkdir -p "$restore_staging_root"; then
        colorized_echo red "Failed to prepare restore staging directory: $restore_staging_root"
        exit 1
    fi

    if ! temp_restore_dir=$(mktemp -d "${restore_staging_root}/pasarguard_restore.XXXXXX"); then
        colorized_echo red "Failed to create restore temp directory."
        exit 1
    fi

    current_compose_snapshot="$temp_restore_dir/.pasarguard-destination-compose.yml"

    local log_file="${temp_restore_dir}/pasarguard_restore_error.log"
    >"$log_file"
    echo "Restore Log - $(date)" >>"$log_file"

    # Clean up staging files, display and persist the error log, restart stopped
    # application services if they were shut down, and terminate with the error code.
    cleanup_and_exit_restore_error() {
        local code="${1:-1}"
        if [ "$services_stopped" = true ] && [ "$fresh_restore" = false ]; then
            if [[ "$db_type" == "sqlite" ]]; then
                up_pasarguard || echo "Failed to restart pasarguard after SQLite restore failure" >>"$log_file"
            else
                start_pasarguard_app_services || echo "Failed to restart pasarguard services after restore failure" >>"$log_file"
            fi
        fi
        if [ -n "$log_file" ] && [ -f "$log_file" ]; then
            if [ -s "$log_file" ]; then
                colorized_echo yellow "=== Restore Error Log ===" >&2
                cat "$log_file" >&2
            fi
            if [ "$check_only" = false ] && mkdir -p "$backup_dir"; then
                cp -f "$log_file" "$backup_dir/pasarguard_restore_error.log" 2>/dev/null || true
            fi
        fi
        if [ -n "$temp_restore_dir" ] && [ -d "$temp_restore_dir" ]; then
            rm -rf "$temp_restore_dir"
        fi
        exit "$code"
    }

    # List available backup files (find all backup-related files in backup directory)
    local backup_candidates=()
    if [ -n "$restore_file" ]; then
        backup_candidates=("$restore_file")
    else
        while IFS= read -r -d '' file; do
            backup_candidates+=("$file")
        done < <(find "$archive_dir" -maxdepth 1 \( -name "*backup*.gz" -o -name "*backup*.tar.gz" -o -name "*.tar.gz" -o -name "*backup*.zip" -o -name "*.zip" \) -type f -print0 2>/dev/null)
    fi

    if [ ${#backup_candidates[@]} -eq 0 ]; then
        # Fallback: try to find any archive files
        while IFS= read -r -d '' file; do
            backup_candidates+=("$file")
        done < <(find "$archive_dir" -maxdepth 1 \( -name "*.gz" -o -name "*.zip" \) -type f -print0 2>/dev/null)
    fi

    local backup_files=()
    for file in "${backup_candidates[@]}"; do
        local filename=$(basename "$file")
        if [[ "$filename" =~ \.part[0-9]{2}\.zip$ ]]; then
            local base_name="${filename%%.part*}"
            if [ -f "$archive_dir/${base_name}.part00.zip" ]; then
                [[ "$filename" =~ \.part00\.zip$ ]] || continue
            else
                [[ "$filename" =~ \.part01\.zip$ ]] || continue
            fi
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
                local part_count=$(find "$archive_dir" -maxdepth 1 -type f -name "${base_name}.part*.zip" | wc -l | awk '{print $1}')
                [ -z "$part_count" ] && part_count=0
                local total_size_bytes=0
                while IFS= read -r part_file; do
                    local part_size=$(stat -c%s "$part_file" 2>/dev/null || stat -f%z "$part_file" 2>/dev/null)
                    if [ -z "$part_size" ]; then
                        part_size=$(wc -c <"$part_file")
                    fi
                    total_size_bytes=$((total_size_bytes + part_size))
                done < <(find "$archive_dir" -maxdepth 1 -type f -name "${base_name}.part*.zip")
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
                done < <(find "$archive_dir" -maxdepth 1 -type f -name "${base_name}.z[0-9][0-9]" | sort)
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

    # An explicit path selects its archive without an extra numbered prompt.
    local selection=1
    if [ -z "$restore_file" ]; then
    while true; do
        printf "Select backup file to restore from (1-%d): " "$file_count"
        read -r selection || { rm -rf "$temp_restore_dir"; return 1; }
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$file_count" ]; then
            break
        else
            colorized_echo red "Invalid selection. Please enter a number between 1 and $file_count."
        fi
    done

    fi

    local selected_file="${backup_files[$((selection-1))]}"
    local selected_filename=$(basename "$selected_file")

    colorized_echo blue "Selected backup: $selected_filename"

    colorized_echo blue "Preparing archive for extraction..."
    local archive_to_extract="$selected_file"
    local archive_format="tar"
    local zip_split_archive=false
    local split_zip_base_name=""

    if [[ "$selected_filename" =~ \.part[0-9]{2}\.zip$ ]]; then
        archive_format="zip"
        local base_name="${selected_filename%%.part*}"
        colorized_echo yellow "Detected split zip backup. Checking available parts..."
        local first_part_number=""
        if [ -f "$archive_dir/${base_name}.part00.zip" ]; then
            first_part_number=0
        elif [ -f "$archive_dir/${base_name}.part01.zip" ]; then
            first_part_number=1
        else
            colorized_echo red "Missing initial split part for ${base_name}. Cannot restore split backup."
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        local concatenated_file="$temp_restore_dir/${base_name}_combined.zip"
        >"$concatenated_file"
        local part_count=0
        local expected_part_number="$first_part_number"
        while IFS= read -r part_file; do
            local part_filename
            local actual_part_number
            part_filename=$(basename "$part_file")
            actual_part_number="${part_filename##*.part}"
            actual_part_number="${actual_part_number%.zip}"
            actual_part_number=$((10#$actual_part_number))

            if [ "$actual_part_number" -ne "$expected_part_number" ]; then
                colorized_echo red "Missing split part $(printf "%s.part%02d.zip" "$base_name" "$expected_part_number"). Cannot restore split backup."
                rm -rf "$temp_restore_dir"
                exit 1
            fi
            cat "$part_file" >>"$concatenated_file"
            part_count=$((part_count + 1))
            expected_part_number=$((expected_part_number + 1))
        done < <(find "$archive_dir" -maxdepth 1 -type f -name "${base_name}.part*.zip" | sort)
        if [ "$part_count" -eq 0 ]; then
            colorized_echo red "No parts found for $base_name"
            rm -rf "$temp_restore_dir"
            exit 1
        fi
        archive_to_extract="$concatenated_file"
        colorized_echo green "✓ Combined $part_count part(s)"
    elif [[ "$selected_filename" =~ \.zip$ ]]; then
        archive_format="zip"
        split_zip_base_name="${selected_filename%.zip}"
        local zip_split_parts=()
        while IFS= read -r part_file; do
            [ -n "$part_file" ] && zip_split_parts+=("$part_file")
        done < <(find "$archive_dir" -maxdepth 1 -type f -name "${split_zip_base_name}.z[0-9][0-9]" | sort)

        if [ ${#zip_split_parts[@]} -gt 0 ]; then
            zip_split_archive=true
            colorized_echo yellow "Detected split zip backup (.zXX + .zip)."
            local expected_part=1
            for part_file in "${zip_split_parts[@]}"; do
                local expected_name
                expected_name=$(printf "%s.z%02d" "$split_zip_base_name" "$expected_part")
                if [ "$(basename "$part_file")" != "$expected_name" ]; then
                    colorized_echo red "Missing split part $expected_name. Cannot restore split backup."
                    rm -rf "$temp_restore_dir"
                    exit 1
                fi
                expected_part=$((expected_part + 1))
            done
            colorized_echo blue "Using main zip file with adjacent split parts for extraction."
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
        if [ "$zip_split_archive" = true ] && ! command -v zip >/dev/null 2>&1; then
            detect_os
            install_package zip
        fi
        if ! unzip -tq "$archive_to_extract" >/dev/null 2>>"$log_file"; then
            if [ "$zip_split_archive" = true ] && command -v zip >/dev/null 2>&1; then
                local rebuilt_archive="$temp_restore_dir/${split_zip_base_name}_combined.zip"
                colorized_echo yellow "Direct split-zip validation failed. Rebuilding archive with zip utility..."
                if zip -s 0 "$selected_file" --out "$rebuilt_archive" >>"$log_file" 2>&1 && unzip -tq "$rebuilt_archive" >/dev/null 2>>"$log_file"; then
                    archive_to_extract="$rebuilt_archive"
                    colorized_echo green "✓ Rebuilt split zip archive with zip utility"
                else
                    colorized_echo red "ERROR: The split backup archive could not be validated."
                    echo "Failed to validate split zip archive: $selected_file" >>"$log_file"
                    rm -rf "$temp_restore_dir"
                    exit 1
                fi
            else
                colorized_echo red "ERROR: The backup file is not a valid zip archive."
                echo "File is not a valid zip archive: $archive_to_extract" >>"$log_file"
                rm -rf "$temp_restore_dir"
                exit 1
            fi
        fi
        if ! archive_entries_are_safe "$archive_to_extract" zip; then
            colorized_echo red "ERROR: The backup archive contains unsafe paths (absolute or '..'). Refusing to extract."
            echo "Unsafe archive paths detected in $archive_to_extract" >>"$log_file"
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
        if ! archive_entries_are_safe "$archive_to_extract" tar; then
            colorized_echo red "ERROR: The backup archive contains unsafe paths (absolute or '..'). Refusing to extract."
            echo "Unsafe archive paths detected in $archive_to_extract" >>"$log_file"
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
    colorized_echo green "✓ Archive extracted successfully"

    if [ -n "$(find "$temp_restore_dir" -type l -print -quit)" ]; then
        colorized_echo red "Archive contains symbolic links. Repackage it with regular files before restoring."
        cleanup_and_exit_restore_error 1
    fi
    if ! verify_backup_checksums "$temp_restore_dir"; then
        colorized_echo red "Backup payload checksum validation failed. Download the complete original backup again."
        echo "Backup payload checksum validation failed" >>"$log_file"
        cleanup_and_exit_restore_error 1
    fi
    if ! print_backup_runtime "$temp_restore_dir"; then cleanup_and_exit_restore_error 1; fi

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

    local env_vars_loaded=0
    local SQLALCHEMY_DATABASE_URL="" MYSQL_ROOT_PASSWORD="" DB_USER="" DB_PASSWORD="" DB_NAME=""

    local env_file_to_use="$extracted_env"
    local cleaned_env="$temp_restore_dir/pasarguard_env_cleaned"
    set +e
    tr -d '\000' < "$extracted_env" > "$cleaned_env" 2>/dev/null
    local tr_result=$?
    set -e
    if [ $tr_result -eq 0 ] && [ -s "$cleaned_env" ]; then
        if ! cmp -s "$extracted_env" "$cleaned_env" 2>/dev/null; then
            colorized_echo yellow "WARNING: .env file contains null bytes, cleaning..."
            env_file_to_use="$cleaned_env"
        else
            rm -f "$cleaned_env"
        fi
    else
        rm -f "$cleaned_env"
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
            # Application settings remain in .env for Compose. Only import
            # connection fields into this shell, never PATH/APP_DIR/COMPOSE etc.
            case "$key" in
                SQLALCHEMY_DATABASE_URL|MYSQL_ROOT_PASSWORD|DB_USER|DB_PASSWORD|DB_NAME)
                    printf -v "$key" '%s' "$value"
                    env_vars_loaded=$((env_vars_loaded + 1))
                    ;;
            esac
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

    colorized_echo green "✓ Found SQLALCHEMY_DATABASE_URL: $(redact_database_url "$SQLALCHEMY_DATABASE_URL")"

    # Parse database configuration (similar to backup function)
    colorized_echo blue "Detecting database type..."
    if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^sqlite ]]; then
        db_type="sqlite"
        colorized_echo green "✓ Detected SQLite database"
        if ! sqlite_file=$(sqlite_database_path_from_url "$SQLALCHEMY_DATABASE_URL") || [ -z "$sqlite_file" ]; then
            colorized_echo red "Invalid SQLite SQLALCHEMY_DATABASE_URL in backup; expected sqlite[+driver]:// followed by a database path."
            echo "Invalid SQLite SQLALCHEMY_DATABASE_URL: $(redact_database_url "$SQLALCHEMY_DATABASE_URL")" >>"$log_file"
            rm -rf "$temp_restore_dir"
            exit 1
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

        if [[ "$url_part" =~ ^\[([^]]+)\](:([0-9]+))?/(.+)$ ]] || [[ "$url_part" =~ ^([^:/]+)(:([0-9]+))?/(.+)$ ]]; then
            db_host="${BASH_REMATCH[1]}"
            db_port="${BASH_REMATCH[3]:-}"
            db_name="${BASH_REMATCH[4]}"
            db_name="${db_name%%\?*}"
            db_name="${db_name%%#*}"

            # Decode URL-encoded strings (percent-encoding).
            urldecode() { local url_encoded="${1//+/ }"; printf '%b' "${url_encoded//%/\\x}"; }
            db_user=$(urldecode "$db_user")
            db_password=$(urldecode "$db_password")
            db_name=$(urldecode "$db_name")

            if [ -z "$db_port" ]; then
                if [[ "$db_type" =~ ^(mysql|mariadb)$ ]]; then
                    db_port="3306"
                elif [[ "$db_type" =~ ^(postgresql|timescaledb)$ ]]; then
                    db_port="5432"
                fi
            fi
        fi

        # Find container name for local databases
        if [ "$check_only" = false ] && [ "$fresh_restore" = false ] && is_local_db_host "$db_host"; then
            set +e
            container_name=$(find_container "$db_type")
            set -e
        fi
    fi

    if [ -z "$db_type" ]; then
        colorized_echo red "Could not determine database type from backup."
        colorized_echo yellow "SQLALCHEMY_DATABASE_URL: $(redact_database_url "${SQLALCHEMY_DATABASE_URL:-}")"
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    colorized_echo green "✓ Database configuration detected: $db_type"

    if [ -f "$temp_restore_dir/backup-runtime.tsv" ]; then
        local recorded_engine=""
        recorded_engine=$(backup_runtime_value "$temp_restore_dir" database)
        # mysql+asyncmy is also used for MariaDB. Prefer the recorded server
        # identity over the SQLAlchemy driver name when selecting the client.
        if [ "$db_type" = mysql ] && [ "$recorded_engine" = mariadb ]; then db_type=mariadb; fi
    fi
    local payload_valid=false
    case "$db_type" in
        mysql|mariadb)
            if mysql_dump_looks_restorable "$temp_restore_dir/db_backup.sql"; then payload_valid=true; fi
            ;;
        postgresql|timescaledb)
            if postgres_backup_looks_restorable "$temp_restore_dir" "$db_name"; then payload_valid=true; fi
            ;;
        sqlite)
            local check_sqlite="$temp_restore_dir/$(basename "$sqlite_file")"
            [ -f "$check_sqlite" ] || check_sqlite="$temp_restore_dir/db_backup.sqlite"
            if [ "$check_only" = false ] && ! command -v sqlite3 >/dev/null 2>&1; then
                detect_os
                try_install_package sqlite3 || true
            fi
            if ! command -v sqlite3 >/dev/null 2>&1; then
                colorized_echo red "Install sqlite3 to validate this SQLite snapshot before restoring."
            elif sqlite_snapshot_looks_restorable "$check_sqlite"; then
                payload_valid=true
            fi
            ;;
    esac
    if [ "$payload_valid" = false ]; then
        colorized_echo red "Database artifact is missing, corrupt, or incomplete; restore stopped before changing services or data."
        echo "Database payload validation failed for $db_type" >>"$log_file"
        cleanup_and_exit_restore_error 1
    fi
    if [ "$check_only" = true ]; then
        rm -rf "$temp_restore_dir"
        colorized_echo green "Backup validation passed. No services or destination data were changed. This check does not perform a database import."
        return 0
    fi
    if [ "$fresh_restore" = true ]; then
        if [ "$db_type" != sqlite ] && ! is_local_db_host "$db_host"; then
            colorized_echo red "--fresh requires a local database from the official Compose templates."
            cleanup_and_exit_restore_error 1
        fi
        colorized_echo blue "Fresh recovery will recreate the recorded panel/database versions in $APP_DIR."
    fi

    # Confirm restore
    if [ "$fresh_restore" = false ]; then
        colorized_echo red "⚠️  DANGER: This will PERMANENTLY overwrite your current $db_type database!"
    fi
    colorized_echo blue "Database type: $db_type"
    if [ -n "$db_name" ]; then
        colorized_echo blue "Database name: $db_name"
    fi
    if [ -n "$container_name" ]; then
        colorized_echo blue "Container: $container_name"
    fi

    while [ "$assume_yes" = false ]; do
        printf "Do you want to proceed with the restore? (yes/no): "
        read -r confirm || { rm -rf "$temp_restore_dir"; return 1; }
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

    if [ "$fresh_restore" = true ]; then
        check_running_as_root
        if ! command -v docker >/dev/null 2>&1; then install_docker; fi
        ensure_docker_compose
        detect_compose
        local fresh_db_container=""
        if ! prepare_fresh_restore "$temp_restore_dir" "$db_type" "$log_file" "$db_port" fresh_db_container; then
            cleanup_and_exit_restore_error 1
        fi
        current_mysql_root_password="$MYSQL_ROOT_PASSWORD"
        current_db_user="${DB_USER:-$db_user}"
        current_db_password="${DB_PASSWORD:-$db_password}"
        current_db_name="${DB_NAME:-$db_name}"
        current_sqlalchemy_url="$SQLALCHEMY_DATABASE_URL"
        if [ "$db_type" != sqlite ]; then
            if ! is_local_db_host "$db_host"; then
                colorized_echo red "--fresh requires a local database from the official Compose templates."
                cleanup_and_exit_restore_error 1
            fi
            container_name="$fresh_db_container"
            if [ -z "$container_name" ]; then
                colorized_echo red "The recovery database container was not identified. The panel has not been started."
                cleanup_and_exit_restore_error 1
            fi
        fi
    fi

    if [ "$db_type" != sqlite ] && is_local_db_host "$db_host" && [ -n "$container_name" ]; then
        if ! container_name=$(verify_and_start_container "$container_name" "$db_type") || [ -z "$container_name" ]; then
            colorized_echo red "Destination database could not be started for compatibility checks."
            cleanup_and_exit_restore_error 1
        fi
        if ! check_restore_database_version "$temp_restore_dir" "$db_type" "$container_name" "$log_file"; then
            colorized_echo red "Could not validate database version compatibility. Check destination credentials and the restore log."
            cleanup_and_exit_restore_error 1
        fi
    fi

    # Stop pasarguard services before restore for clean state
    colorized_echo blue "Stopping pasarguard services for clean restore..."
    if [[ "$db_type" == "sqlite" ]]; then
        # For SQLite, stop all services since we need to restore files
        services_stopped=true
        if ! down_pasarguard; then
            colorized_echo red "Failed to stop pasarguard services for SQLite restore."
            echo "Failed to stop pasarguard services via down_pasarguard" >>"$log_file"
            cleanup_and_exit_restore_error 1
        fi
    else
        # For containerized databases, stop only application services
        # Keep database containers running for restore via docker exec
        services_stopped=true
        stop_pasarguard_app_services
    fi

    # Perform restore
    if [ "$fresh_restore" = false ]; then
        colorized_echo red "⚠️  DANGER: Starting database restore - this will overwrite existing data!"
    fi
    colorized_echo blue "Starting database restore..."

    case $db_type in
    sqlite)
        sqlite_basename=$(basename "$sqlite_file")

        if [ -f "$temp_restore_dir/$sqlite_basename" ]; then
            sqlite_backup_source="$temp_restore_dir/$sqlite_basename"
        elif [ -f "$temp_restore_dir/db_backup.sqlite" ]; then
            sqlite_backup_source="$temp_restore_dir/db_backup.sqlite"
        fi

        if [ -z "$sqlite_backup_source" ]; then
            colorized_echo red "SQLite backup file not found in backup archive (looked for $sqlite_basename or db_backup.sqlite)."
            cleanup_and_exit_restore_error 1
        fi

        if ! command -v sqlite3 >/dev/null 2>&1; then
            detect_os
            try_install_package sqlite3 || true
        fi
        if ! command -v sqlite3 >/dev/null 2>&1; then
            colorized_echo red "sqlite3 is required to validate the SQLite snapshot before restore. Install sqlite3 and run the restore again."
            echo "sqlite3 unavailable; cannot validate $sqlite_backup_source" >>"$log_file"
            cleanup_and_exit_restore_error 1
        fi
        if ! sqlite_snapshot_looks_restorable "$sqlite_backup_source"; then
            colorized_echo red "SQLite backup is corrupt or incomplete; aborting before replacing the current database."
            echo "SQLite snapshot validation failed for $sqlite_backup_source" >>"$log_file"
            cleanup_and_exit_restore_error 1
        fi

        if [ -f "$sqlite_file" ]; then
            sqlite_safety_backup="$backup_dir/sqlite_before_restore_${restore_timestamp}_${sqlite_basename}"
            if ! sqlite3 "$sqlite_file" ".backup '$sqlite_safety_backup'" >>"$log_file" 2>&1; then
                colorized_echo red "Failed to create a safety snapshot of the current SQLite database; restore aborted."
                echo "SQLite safety snapshot failed: $sqlite_file -> $sqlite_safety_backup" >>"$log_file"
                rm -f "$sqlite_safety_backup"
                cleanup_and_exit_restore_error 1
            fi
            colorized_echo blue "Current SQLite database saved to $sqlite_safety_backup"
        fi
        ;;

    mariadb|mysql)
        if ! mysql_dump_looks_restorable "$temp_restore_dir/db_backup.sql"; then
            colorized_echo red "Database backup is missing, truncated, or invalid; aborting before restore."
            echo "MySQL/MariaDB dump validation failed for $temp_restore_dir/db_backup.sql" >>"$log_file"
            cleanup_and_exit_restore_error 1
        fi

        if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
            if [ -z "$container_name" ]; then
                colorized_echo red "Error: MySQL/MariaDB container not found. Is the container running?"
                echo "MySQL/MariaDB container not found. Container name: ${container_name:-empty}" >>"$log_file"
                cleanup_and_exit_restore_error 1
            else
                local verified_container=$(verify_and_start_container "$container_name" "$db_type")
                if [ -z "$verified_container" ]; then
                    colorized_echo red "Failed to start database container. Please start it manually."
                    cleanup_and_exit_restore_error 1
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
                local app_db_target="${current_db_name:-${db_name:-}}"

                # The destination root password is authoritative. The archived
                # value belongs to the source server and is only a legacy
                # fallback when the current installation did not provide one.
                if [ -n "$current_mysql_root_password" ]; then
                    colorized_echo blue "Trying root user from current installation .env..."
                    if docker exec -i -e MYSQL_PWD="$current_mysql_root_password" "$container_name" "$mysql_cmd" -u root < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        restore_success=true
                        colorized_echo green "$db_type_name database restored successfully."
                    else
                        colorized_echo yellow "Root restore failed with current .env credentials, trying fallback..."
                        echo "$db_type_name restore failed with current MYSQL_ROOT_PASSWORD" >>"$log_file"
                    fi
                fi

                if [ "$restore_success" = false ] && [ -z "$current_mysql_root_password" ] && [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
                    colorized_echo blue "No destination root password was found; trying the backup .env value..."
                    if docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$container_name" "$mysql_cmd" -u root < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        restore_success=true
                        colorized_echo green "$db_type_name database restored successfully."
                    else
                        colorized_echo yellow "Backup root credentials failed, trying app user fallback..."
                        echo "$db_type_name restore failed with backup MYSQL_ROOT_PASSWORD" >>"$log_file"
                    fi
                fi

                # Try app user from backup SQL URL/.env
                if [ "$restore_success" = false ] && [ -n "$backup_restore_user" ] && [ -n "$backup_restore_password" ]; then
                    colorized_echo blue "Trying app user '$backup_restore_user' from backup credentials..."
                    if [ -n "$app_db_target" ]; then
                        if docker exec -i -e MYSQL_PWD="$backup_restore_password" "$container_name" "$mysql_cmd" -u "$backup_restore_user" "$app_db_target" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                            restore_success=true
                            colorized_echo green "$db_type_name database restored successfully."
                        fi
                    fi
                    if [ "$restore_success" = false ] && docker exec -i -e MYSQL_PWD="$backup_restore_password" "$container_name" "$mysql_cmd" -u "$backup_restore_user" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        restore_success=true
                        colorized_echo green "$db_type_name database restored successfully."
                    elif [ "$restore_success" = false ]; then
                        colorized_echo yellow "App user restore failed with backup credentials, trying current installation credentials..."
                        echo "$db_type_name restore failed with backup app credentials" >>"$log_file"
                    fi
                fi

                # Final fallback: current installation app credentials
                if [ "$restore_success" = false ] && [ -n "$current_db_user" ] && [ -n "$current_db_password" ] && { [ "$current_db_user" != "$backup_restore_user" ] || [ "$current_db_password" != "$backup_restore_password" ] || [ "${current_db_name:-}" != "${db_name:-}" ]; }; then
                    colorized_echo blue "Trying app user '$current_db_user' from current installation .env..."
                    if [ -n "$app_db_target" ]; then
                        if docker exec -i -e MYSQL_PWD="$current_db_password" "$container_name" "$mysql_cmd" -u "$current_db_user" "$app_db_target" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                            restore_success=true
                            colorized_echo green "$db_type_name database restored successfully."
                        fi
                    fi
                    if [ "$restore_success" = false ] && docker exec -i -e MYSQL_PWD="$current_db_password" "$container_name" "$mysql_cmd" -u "$current_db_user" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        restore_success=true
                        colorized_echo green "$db_type_name database restored successfully."
                    elif [ "$restore_success" = false ]; then
                        echo "$db_type_name restore failed with current app credentials" >>"$log_file"
                    fi
                fi

                if [ "$restore_success" = false ]; then
                    colorized_echo red "Failed to restore $db_type_name database with all available credentials."
                    colorized_echo yellow "Check log file for details: $log_file"
                    cleanup_and_exit_restore_error 1
                fi
            fi
        else
            colorized_echo red "Remote $db_type restore not supported yet."
            cleanup_and_exit_restore_error 1
        fi
        ;;

    postgresql|timescaledb)
        local pg_layout
        pg_layout=$(pg_backup_layout "$temp_restore_dir")

        if [ "$db_type" = "timescaledb" ] && [ "$pg_layout" = "single" ]; then
            if ! pg_promote_timescaledb_single_backup \
                "$temp_restore_dir" "$db_name" "${db_user:-${DB_USER:-postgres}}" "$log_file" \
                "$requested_timescaledb_backup_version"; then
                colorized_echo red "This TimescaleDB backup does not record its source extension version; restore stopped before changing the current database."
                colorized_echo yellow "For a legacy archive, set TIMESCALEDB_BACKUP_VERSION to its exact source version and run restore again."
                cleanup_and_exit_restore_error 1
            fi
            pg_layout="multi"
            colorized_echo blue "Prepared versioned TimescaleDB metadata for the single-database backup."
        fi

        if [ "$pg_layout" = "none" ]; then
            colorized_echo red "Database backup not found in backup archive."
            cleanup_and_exit_restore_error 1
        fi

        if [ "$pg_layout" = "multi" ] && ! postgres_backup_looks_restorable "$temp_restore_dir" "$db_name"; then
            colorized_echo red "Multi-database backup is incomplete or does not contain the configured database; aborting before restore."
            echo "Multi-database dump validation failed for $temp_restore_dir/pg_dump" >>"$log_file"
            cleanup_and_exit_restore_error 1
        fi

        if [ "$pg_layout" = "single" ]; then
            # Verify backup file is not empty and is readable
            if [ ! -s "$temp_restore_dir/db_backup.sql" ]; then
                colorized_echo red "Database backup file is empty or unreadable."
                cleanup_and_exit_restore_error 1
            fi

            # Validate dump content *before* any destructive step (the TimescaleDB
            # path drops the live database), so an empty/truncated/garbage dump can
            # never wipe the database with nothing to restore.
            if ! postgres_dump_looks_restorable "$temp_restore_dir/db_backup.sql"; then
                colorized_echo red "Database backup does not look like a valid SQL dump; aborting before any changes."
                echo "Dump content validation failed for $temp_restore_dir/db_backup.sql" >>"$log_file"
                cleanup_and_exit_restore_error 1
            fi

            local backup_size=$(du -h "$temp_restore_dir/db_backup.sql" | cut -f1)
            colorized_echo blue "Backup file size: $backup_size"
        fi

        if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" || "$db_host" == "::1" ]]; then
            if [ -z "$container_name" ]; then
                colorized_echo red "Error: Database container not found. Please start the DB container or specify a valid container name."
                cleanup_and_exit_restore_error 1
            fi
            local verified_container=$(verify_and_start_container "$container_name" "$db_type")
            if [ -z "$verified_container" ]; then
                colorized_echo red "Failed to start database container. Please start it manually."
                cleanup_and_exit_restore_error 1
            fi
            container_name="$verified_container"

            colorized_echo blue "Restoring $db_type database from container: $container_name"

            # Prepare restore credentials, preferring the current installation values.
                local restore_user="${current_db_user:-${db_user:-${DB_USER:-postgres}}}"
                local restore_password="${current_db_password:-${db_password:-${DB_PASSWORD:-}}}"
                local restore_db_name="${current_db_name:-${db_name:-${DB_NAME:-postgres}}}"
                local admin_user="${current_db_user:-${db_user:-${DB_USER:-postgres}}}"
                local admin_password="${current_db_password:-${db_password:-${DB_PASSWORD:-$restore_password}}}"

                if [ -z "$restore_password" ]; then
                    colorized_echo red "No database password found for restore."
                    cleanup_and_exit_restore_error 1
                fi

            local restore_success=false

            if [ "$pg_layout" = "multi" ]; then
                local prepared_pg_dump_dir="$temp_restore_dir/pg_dump"
                local compat_restore_root=""
                if ! compat_restore_root=$(mktemp -d "$temp_restore_dir/pasarguard_ts_compat.XXXXXX"); then
                    colorized_echo red "Could not create TimescaleDB compatibility staging directory."
                    cleanup_and_exit_restore_error 1
                fi
                if ! pg_prepare_timescaledb_compatible_dumps \
                    "$container_name" "$admin_user" "$admin_password" \
                    "$temp_restore_dir/pg_dump" "$compat_restore_root/pg_dump" \
                    "$log_file" "$db_name" "$requested_timescaledb_compat_image"; then
                    colorized_echo red "TimescaleDB version compatibility preflight failed. The current database was not changed."
                    colorized_echo yellow "Check log file for details: $log_file"
                    cleanup_and_exit_restore_error 1
                fi
                prepared_pg_dump_dir="$PG_PREPARED_DUMP_DIR"

                if pg_restore_all_user_databases \
                    "$container_name" "$restore_user" "$restore_password" "$admin_user" "$admin_password" \
                    "$prepared_pg_dump_dir" "$log_file" "$db_name" "$restore_db_name" "${current_db_user:-$restore_user}"; then
                    colorized_echo green "All $db_type databases restored successfully."
                    restore_success=true
                else
                    colorized_echo red "One or more databases failed to restore. Check log: $log_file"
                fi
            elif [ "$db_type" = "timescaledb" ]; then
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
                local target_db_name="$restore_db_name"
                local target_db_owner="${current_db_user:-$restore_user}"
                local target_db_name_sql="${target_db_name//\'/\'\'}"
                local target_db_name_ident="${target_db_name//\"/\"\"}"
                local target_db_owner_ident="${target_db_owner//\"/\"\"}"

                # Drop and recreate the target database for a clean slate
                colorized_echo blue "Dropping and recreating database '$target_db_name'..."
                docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" -d postgres \
                    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$target_db_name_sql' AND pid <> pg_backend_pid();" \
                    >>"$log_file" 2>&1
                docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" -d postgres \
                    -c "DROP DATABASE IF EXISTS \"$target_db_name_ident\";" >>"$log_file" 2>&1
                docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" -d postgres \
                    -c "CREATE DATABASE \"$target_db_name_ident\" OWNER \"$target_db_owner_ident\";" >>"$log_file" 2>&1

                # Create the timescaledb extension in the fresh database
                docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" --dbname="$target_db_name" \
                    -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" >>"$log_file" 2>&1

                # Call pre_restore to put TimescaleDB into restore mode
                colorized_echo blue "Calling timescaledb_pre_restore()..."
                docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" --dbname="$target_db_name" \
                    -c "SELECT timescaledb_pre_restore();" >>"$log_file" 2>&1

                # Filter out extension DROP/CREATE statements from the dump.
                colorized_echo blue "Preparing dump (filtering extension statements)..."
                pg_filter_timescaledb_extension_lines < "$temp_restore_dir/db_backup.sql" \
                    > "$temp_restore_dir/db_backup_filtered.sql" 2>>"$log_file"

                # Restore the filtered dump with ON_ERROR_STOP so psql exits non-zero on SQL errors
                colorized_echo blue "Restoring database dump..."
                if docker exec -i -e PGPASSWORD="$restore_password" "$container_name" psql -v ON_ERROR_STOP=1 -U "$restore_user" --dbname="$target_db_name" < "$temp_restore_dir/db_backup_filtered.sql" 2>>"$log_file"; then
                    restore_success=true
                else
                    # Fallback: try with the configured admin user.
                    colorized_echo yellow "Trying with admin user..."
                    if docker exec -i -e PGPASSWORD="$admin_password" "$container_name" psql -v ON_ERROR_STOP=1 -U "$admin_user" --dbname="$target_db_name" < "$temp_restore_dir/db_backup_filtered.sql" 2>>"$log_file"; then
                        restore_success=true
                    fi
                fi

                # Clean up filtered dump
                rm -f "$temp_restore_dir/db_backup_filtered.sql"

                # Call post_restore regardless of outcome to leave DB in a usable state
                colorized_echo blue "Calling timescaledb_post_restore()..."
                docker exec -e PGPASSWORD="$admin_password" "$container_name" psql -U "$admin_user" --dbname="$target_db_name" \
                    -c "SELECT timescaledb_post_restore();" >>"$log_file" 2>&1

                if [ "$restore_success" = true ]; then
                    colorized_echo green "TimescaleDB database restored successfully."
                fi
            else
                # Plain PostgreSQL restore with ON_ERROR_STOP so psql exits non-zero on SQL errors
                colorized_echo blue "Attempting restore using app user '$restore_user' to database '$restore_db_name'..."
                if docker exec -i -e PGPASSWORD="$restore_password" "$container_name" psql -v ON_ERROR_STOP=1 -U "$restore_user" -d "$restore_db_name" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                    colorized_echo green "$db_type database restored successfully."
                    restore_success=true
                else
                    # If that fails, try using the configured admin user.
                    colorized_echo yellow "Trying with admin user..."
                    if docker exec -i -e PGPASSWORD="$admin_password" "$container_name" psql -v ON_ERROR_STOP=1 -U "$admin_user" -d "$restore_db_name" < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                        colorized_echo green "$db_type database restored successfully."
                        restore_success=true
                    else
                        # Try restoring to postgres database (for pg_dumpall backups)
                        if docker exec -i -e PGPASSWORD="$admin_password" "$container_name" psql -v ON_ERROR_STOP=1 -U "$admin_user" -d postgres < "$temp_restore_dir/db_backup.sql" 2>>"$log_file"; then
                            colorized_echo green "$db_type database restored successfully."
                            restore_success=true
                        fi
                    fi
                fi
            fi

            if [ "$restore_success" = false ]; then
                colorized_echo red "Failed to restore $db_type database."
                colorized_echo yellow "Check log file for details: $log_file"
                cleanup_and_exit_restore_error 1
            fi
        else
            colorized_echo red "Remote $db_type restore not supported yet."
            cleanup_and_exit_restore_error 1
        fi
        ;;
    *)
        colorized_echo red "Unsupported database type: $db_type"
        cleanup_and_exit_restore_error 1
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
        if [ "$fresh_restore" = false ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
            colorized_echo blue "Backing up current data directory before restore..."
            cp -r "$DATA_DIR" "$DATA_DIR.backup.$(date +%Y%m%d%H%M%S)" 2>>"$log_file" || true
        fi
        if ! rsync -a --delete --exclude mysql --exclude mariadb --exclude postgresql --exclude timescaledb "$extracted_data_dir/" "$DATA_DIR/" 2>>"$log_file"; then
            colorized_echo red "Failed to restore data directory."
            echo "Failed to restore data directory from $extracted_data_dir to $DATA_DIR" >>"$log_file"
            cleanup_and_exit_restore_error 1
        fi
        if [ "$db_type" = "sqlite" ] && [ -n "${sqlite_file:-}" ]; then
            rm -f "${sqlite_file}-wal" "${sqlite_file}-shm" "${sqlite_file}-journal" 2>>"$log_file" || true
        fi
        colorized_echo green "Data directory restored to $DATA_DIR."
    else
        colorized_echo yellow "No pasarguard_data directory found in backup. Skipping data restore."
    fi

    # The data directory in legacy archives may contain a raw SQLite main file
    # and WAL. Apply the consistent snapshot only after that directory has been
    # restored so the raw copy can never overwrite the authoritative backup.
    if [ "$db_type" = "sqlite" ]; then
        mkdir -p "$(dirname "$sqlite_file")"
        rm -f "${sqlite_file}-wal" "${sqlite_file}-shm" "${sqlite_file}-journal" 2>>"$log_file" || true
        if cp "$sqlite_backup_source" "$sqlite_file" 2>>"$log_file"; then
            colorized_echo green "SQLite database restored successfully."
        else
            colorized_echo red "Failed to restore SQLite database."
            echo "SQLite restore failed" >>"$log_file"
            cleanup_and_exit_restore_error 1
        fi
    fi

    # Restore app directory files (full app backup support)
    colorized_echo blue "Restoring app directory files..."
    if [ -d "$temp_restore_dir" ]; then
        # Capture this only after archive extraction/DB restore and immediately
        # before app-file sync. An archive member with the same internal helper
        # name therefore cannot spoof the destination snapshot. Infrastructure
        # belongs to the destination installation; restoring an old compose
        # file could otherwise downgrade TimescaleDB again.
        if [[ "$db_type" != "sqlite" ]] && [ -f "$COMPOSE_FILE" ]; then
            if ! cp "$COMPOSE_FILE" "$current_compose_snapshot"; then
                colorized_echo red "Failed to snapshot destination docker-compose.yml."
                cleanup_and_exit_restore_error 1
            fi
        fi
        if ! command -v rsync >/dev/null 2>&1; then
            detect_os
            install_package rsync
        fi
        mkdir -p "$APP_DIR"
        if [ "$fresh_restore" = false ] && [ "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
            colorized_echo blue "Backing up current app directory before restore..."
            if ! rsync -a --exclude backup "$APP_DIR/" "$APP_DIR.backup.$(date +%Y%m%d%H%M%S)/" 2>>"$log_file"; then
                colorized_echo red "Failed to save the current application files before replacement."
                cleanup_and_exit_restore_error 1
            fi
        fi
        if ! rsync -av --exclude 'pasarguard_data' --exclude 'db_backup.sql' --exclude 'db_backup.sqlite' \
            --exclude 'db_backup.timescaledb-version' --exclude 'pg_dump' \
            --exclude 'backup-runtime.tsv' --exclude 'backup-files.sha256' --exclude '.pasarguard-recovery-compose.json' \
            --exclude '.pasarguard-destination-compose.yml' --exclude 'pasarguard_ts_compat.*' \
            --exclude '*_combined.zip' --exclude 'pasarguard_env_cleaned' \
            --exclude 'pasarguard_restore_error.log' --exclude "$sqlite_basename" \
            "$temp_restore_dir/" "$APP_DIR/" >>"$log_file" 2>&1; then
            colorized_echo red "Failed to restore app directory files."
            echo "Failed to restore app directory files from $temp_restore_dir to $APP_DIR" >>"$log_file"
            cleanup_and_exit_restore_error 1
        else
            colorized_echo green "App directory files restored."
        fi
    fi

    # Keep the destination database identity. Archived credentials describe the
    # source server and must never replace credentials already provisioned on
    # this installation, even if the literal values happen to compare equal.
    if [ -f "$APP_DIR/.env" ]; then
        if [[ "$db_type" != "sqlite" ]]; then
            colorized_echo blue "Preserving destination database credentials and connection URL."
            if [ -n "$current_mysql_root_password" ]; then
                replace_or_append_env_var "MYSQL_ROOT_PASSWORD" "$current_mysql_root_password" true "$ENV_FILE"
            fi
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

    if [[ "$db_type" != "sqlite" ]] && [ -s "$current_compose_snapshot" ]; then
        if ! cp "$current_compose_snapshot" "$COMPOSE_FILE"; then
            colorized_echo red "Failed to preserve the destination docker-compose.yml."
            cleanup_and_exit_restore_error 1
        fi
        colorized_echo blue "Preserved destination docker-compose.yml."
    fi

    # Keep staging/logs until starting services has succeeded. Fresh recovery
    # has no application containers to `start`, so provision them only now.
    colorized_echo blue "Starting pasarguard services..."
    if ! up_pasarguard; then
        colorized_echo red "Data was restored, but services could not start. See the restore log."
        cleanup_and_exit_restore_error 1
    fi
    harden_secret_file "$ENV_FILE"
    harden_secret_file "$COMPOSE_FILE"
    rm -rf "$temp_restore_dir"
    colorized_echo green "Restore completed successfully!"
    colorized_echo green "PasarGuard services have been started. Check panel login, subscriptions and node connections before upgrading."
}
