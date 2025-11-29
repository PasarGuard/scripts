#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

load_env_file() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line%%$'\r'*}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      local key=${BASH_REMATCH[1]}
      local val=${BASH_REMATCH[2]}
      val="${val#"${val%%[![:space:]]*}"}"  # trim leading ws
      val="${val%"${val##*[![:space:]]}"}"  # trim trailing ws
      if [[ "$val" =~ ^\".*\"$ || "$val" =~ ^\'.*\'$ ]]; then
        val=${val:1:${#val}-2}
      fi
      export "$key=$val"
    fi
  done < "$ENV_FILE"
}

APP_NAME="pg-node"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ENV_FILE="/opt/$APP_NAME/.env"
LOCAL_ENV_FILE="$SCRIPT_DIR/.env"
ENV_FILE="${ENV_FILE:-$DEFAULT_ENV_FILE}"

if [[ ! -f "$ENV_FILE" && -f "$LOCAL_ENV_FILE" ]]; then
  ENV_FILE="$LOCAL_ENV_FILE"
fi

if [[ -f "$ENV_FILE" ]]; then
  load_env_file
  log "Loaded env file: $ENV_FILE"
else
  log "Env file not found, using defaults: $ENV_FILE"
fi

API_PORT="${API_PORT:-3000}"
MAX_BODY=1048576
API_KEY="${API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
  log "API_KEY must be set in the env file"
  exit 1
fi

if [[ -z "${SSL_CERT_FILE:-}" || -z "${SSL_KEY_FILE:-}" ]]; then
  log "TLS required: set SSL_CERT_FILE and SSL_KEY_FILE in the env file"
  exit 1
fi
if [[ ! -r "$SSL_CERT_FILE" ]]; then
  log "Cannot read SSL_CERT_FILE: $SSL_CERT_FILE"
  exit 1
fi
if [[ ! -r "$SSL_KEY_FILE" ]]; then
  log "Cannot read SSL_KEY_FILE: $SSL_KEY_FILE"
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  log "openssl is required for TLS mode"
  exit 1
fi

# Enhanced certificate validation
check_certificate() {
  local cert_file="$1"
  
  if ! openssl x509 -in "$cert_file" -noout >/dev/null 2>&1; then
    log "Error: Invalid certificate file: $cert_file"
    return 1
  fi
  
  # Check if certificate is self-signed
  if openssl x509 -in "$cert_file" -noout -subject | grep -q "subject= *CN *= *" && \
     openssl x509 -in "$cert_file" -noout -issuer | grep -q "issuer= *CN *= *" && \
     [[ $(openssl x509 -in "$cert_file" -noout -subject) == $(openssl x509 -in "$cert_file" -noout -issuer) ]]; then
    log "Certificate is self-signed: $cert_file"
    return 2
  else
    log "Certificate appears to be CA-signed: $cert_file"
    
    # Check certificate expiration
    local not_after
    not_after=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
    local expire_date
    expire_date=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo "unknown")
    local current_date
    current_date=$(date +%s)
    
    if [[ "$expire_date" != "unknown" ]] && (( current_date > expire_date )); then
      log "Warning: Certificate has expired: $cert_file"
      log "Expiration: $not_after"
    elif [[ "$expire_date" != "unknown" ]]; then
      local days_until_expire=$(( (expire_date - current_date) / 86400 ))
      log "Certificate valid for $days_until_expire more days (expires: $not_after)"
    fi
    return 0
  fi
}

# Validate certificate
if check_certificate "$SSL_CERT_FILE"; then
  case $? in
    0) log "Using CA-signed TLS certificate: $SSL_CERT_FILE" ;;
    2) log "Using self-signed TLS certificate: $SSL_CERT_FILE" ;;
    *) log "Using TLS certificate: $SSL_CERT_FILE" ;;
  esac
else
  log "Certificate validation failed, but continuing anyway..."
fi

log "TLS enabled on port $API_PORT with cert=$SSL_CERT_FILE key=$SSL_KEY_FILE"
log "API key protection enabled"

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  echo -n "$s"
}

status_text() {
  case "$1" in
    200) echo -n "OK" ;;
    401) echo -n "Unauthorized" ;;
    400) echo -n "Bad Request" ;;
    404) echo -n "Not Found" ;;
    *) echo -n "Internal Server Error" ;;
  esac
}

respond() {
  local code=$1
  local body=$2
  local text body_len
  LAST_STATUS=$code
  text=$(status_text "$code")
  body_len=${#body}
  printf 'HTTP/1.1 %s %s\r\n' "$code" "$text"
  printf 'Content-Type: application/json\r\n'
  printf 'Content-Length: %s\r\n' "$body_len"
  printf 'Connection: close\r\n\r\n'
  printf '%s' "$body"
  # Flush the output to ensure response is sent immediately
  if command -v flush >/dev/null 2>&1; then
    flush
  fi
}

handle_node_update(){
    log "Executing $APP_NAME update"
   if ! $APP_NAME update --no-update-service >/dev/null 2>&1; then 
      log "update failed with exit code: $?" 
      respond 500 '{"detail":"update failed on server"}' 
      return 
    fi
    respond 200 "{\"detail\":\"node updated successfully\"}"
}

handle_node_core_update(){
    local body="${1:-}"
    local core_version=""

    if ! command -v jq >/dev/null 2>&1; then
      log "jq is required to parse core_version from request body"
      respond 500 '{"detail":"jq not installed on server"}'
      return
    fi

    if [[ -n "$body" ]]; then
      if ! core_version=$(printf '%s' "$body" | jq -r '."core_version" // ""' 2>/dev/null); then
        log "Failed to parse JSON body for core_version"
        respond 400 '{"detail":"Invalid JSON body"}'
        return
      fi
    fi

    if [[ -n "$core_version" ]]; then
      log "Executing $APP_NAME core-update with version: $core_version"
      local error_output
      error_output=$($APP_NAME core-update --version "$core_version" 2>&1)
      local exit_code=$?
      if [ $exit_code -eq 0 ]; then
        respond 200 "{\"detail\":\"node core updated successfully\"}"
      else
        log "core-update failed for version: $core_version (exit code: $exit_code)"
        log "Error output: $error_output"
        # Extract the actual error message, removing ANSI color codes
        local clean_error=$(echo "$error_output" | sed 's/\x1b\[[0-9;]*m//g' | head -n 1)
        if [[ -n "$clean_error" ]]; then
          respond 404 "{\"detail\":\"core-update failed for version $(json_escape "$core_version"): $(json_escape "$clean_error")\"}"
        else
          respond 404 "{\"detail\":\"core-update failed for version $(json_escape "$core_version"). Version may not exist or network error occurred.\"}"
        fi
      fi
    fi
}

handle_geofiles_update(){
    local body="${1:-}"
    local region="" flag=""

    if [[ -n "$body" ]]; then
      if ! command -v jq >/dev/null 2>&1; then
        log "jq is required to parse region from request body"
        respond 500 '{"detail":"jq not installed on server"}'
        return
      fi

      if ! region=$(printf '%s' "$body" | jq -r '.region // empty' 2>/dev/null); then
        log "Failed to parse JSON body for region"
        respond 400 '{"detail":"Invalid JSON body"}'
        return
      fi
    fi

    if [[ -z "$region" ]]; then
      respond 400 '{"detail":"region is required (iran, russia, china)"}'
      return
    fi

    case "${region,,}" in
      iran) flag="--iran" ;;
      russia) flag="--russia" ;;
      china) flag="--china" ;;
      *)
        log "Invalid region provided: $region"
        respond 400 "{\"detail\":\"Unsupported region $(json_escape "$region")\"}"
        return
        ;;
    esac

    log "Executing $APP_NAME geofiles $flag"
    if $APP_NAME geofiles "$flag" >/dev/null 2>&1; then
      respond 200 '{"detail":"geofiles updated successfully"}'
    else
      log "geofiles update failed"
      respond 500 '{"detail":"geofiles update failed on server"}'
    fi
}

handle_connection() {
  local request_line method path version
  
  # Read the first line and check if it's a valid HTTP request
  if ! IFS= read -r request_line; then
    log "Connection closed without data"
    return 1
  fi
  
  request_line=${request_line%$'\r'}
  
  # Check if this looks like an HTTP request (not an error message)
  if [[ ! "$request_line" =~ ^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)[[:space:]]+/ ]]; then
    log "Invalid request line (likely SSL error or non-HTTP data): $request_line"
    # Consume any remaining data to clear the pipe
    while IFS= read -r -t 0.1 discard; do
      : # Discard remaining data
    done
    return 1
  fi
  
  read -r method path version <<<"$request_line"
  log "Valid HTTP request: $method $path"

  local header_line content_length=0 x_api_key="" header_name header_value
  local connection="close"
  
  while IFS= read -r header_line; do
    header_line=${header_line%$'\r'}
    [[ -z "$header_line" ]] && break
    
    # Skip any lines that don't look like headers
    if [[ ! "$header_line" =~ ^[[:alnum:]-]+: ]]; then
      continue
    fi
    
    if [[ "$header_line" =~ ^[Cc]ontent-[Ll]ength:\ ([0-9]+) ]]; then
      content_length=${BASH_REMATCH[1]}
    fi
    header_name=${header_line%%:*}
    header_value=${header_line#*:}
    header_name=${header_name,,}
    header_value=${header_value# }
    if [[ "$header_name" == "x-api-key" ]]; then
      x_api_key="$header_value"
    elif [[ "$header_name" == "connection" ]]; then
      connection="${header_value,,}"
    fi
  done

  if [[ -z "$x_api_key" ]]; then
    respond 401 '{"detail":"missing api key"}'
    log "Unauthorized: missing x-api-key for $method $path"
    return 0
  fi
  if [[ "$x_api_key" != "$API_KEY" ]]; then
    respond 401 '{"detail":"invalid api key"}'
    log "Unauthorized: invalid x-api-key for $method $path"
    return 0
  fi

  local body=""
  if (( content_length > 0 )); then
    if (( content_length > MAX_BODY )); then
      respond 400 '{"detail":"Payload too large"}'
      log "Body rejected: $content_length bytes (too large)"
      return 0
    fi
    if ! IFS= read -r -N "$content_length" body; then
      log "Failed to read request body"
      respond 400 '{"detail":"Failed to read request body"}'
      return 0
    fi
    log "Body received: ${#body} bytes"
  fi

  # Process the request and send response
  case "$method $path" in
    "GET /")
      respond 200 '{"status":"ok"}'
      ;;
    "POST /node/update")
        handle_node_update
      ;;
    "POST /node/core_update")
        handle_node_core_update "$body"
      ;;
    "POST /node/geofiles")
        handle_geofiles_update "$body"
      ;;
    *)
      respond 404 '{"detail":"Not found"}'
      ;;
  esac
  
  log "Responded $LAST_STATUS to $method $path"
  
  # If connection is keep-alive, wait for next request
  if [[ "$connection" == "keep-alive" ]]; then
    log "Keep-alive connection, waiting for next request..."
    return 0
  else
    log "Closing connection as requested"
    return 1
  fi
}

# Check if we should use socat (recommended) or openssl s_server
if command -v socat >/dev/null 2>&1; then
  log "Starting HTTPS server with socat on port $API_PORT..."
  
  # For socat, we need to handle the case where we're called as a subprocess
  if [[ "${1:-}" == "--handle-connection" ]]; then
    # Keep processing requests on the same connection until client disconnects or sends "close"
    while handle_connection; do
      : # Continue processing requests on the same connection
    done
    exit 0
  fi
  
  # Determine verify level based on certificate type
  verify_level="verify=0"
  if check_certificate "$SSL_CERT_FILE" && [[ $? -eq 0 ]]; then
    verify_level="verify=1"
    log "Enabling client certificate verification (CA-signed certificate detected)"
  else
    log "Disabling client certificate verification (self-signed or invalid certificate)"
  fi
  
  exec socat \
    "OPENSSL-LISTEN:${API_PORT},cert=${SSL_CERT_FILE},key=${SSL_KEY_FILE},${verify_level},reuseaddr,fork" \
    EXEC:"'$0' --handle-connection"
else
  log "socat not available, using openssl s_server"
  log "Install socat for better performance: sudo apt-get install socat"
  
  # Main server loop with openssl s_server
  log "Bash REST API listening on https://localhost:${API_PORT}"
  
  while true; do
    # Use openssl s_server with stderr redirected
    if coproc OPENSSL { 
      openssl s_server \
        -quiet \
        -accept "$API_PORT" \
        -cert "$SSL_CERT_FILE" \
        -key "$SSL_KEY_FILE" \
        -ign_eof \
        2>/dev/null
    }; then
      log "OpenSSL server started, waiting for connections..."
      
      # Handle connections - keep processing requests on the same connection
      while handle_connection <&"${OPENSSL[0]}" >&"${OPENSSL[1]}"; do
        log "Processing next request on same connection..."
      done
      
      # Clean up file descriptors
      exec {OPENSSL[0]}<&-
      exec {OPENSSL[1]}>&-
      wait "${OPENSSL_PID}" 2>/dev/null || true
      log "Client disconnected, restarting OpenSSL server..."
    else
      log "Failed to start openssl s_server, retrying in 5 seconds..."
      sleep 5
    fi
    sleep 1
  done
fi
