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

PORT="${PORT:-3000}"
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
log "TLS enforced with cert=$SSL_CERT_FILE key=$SSL_KEY_FILE on port $PORT"
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
}
handle_node_update(){
    log "Executing $APP_NAME update"
    $APP_NAME update
    respond 200 "{\"detaile\":\"node updated successfully\"}"
}

handle_node_core_update(){
    log "Executing $APP_NAME core-update"
    $APP_NAME core-update
    respond 200 "{\"detaile\":\"node core updated successfully\"}"
}

handle_connection() {
  local request_line method path version
  if ! IFS= read -r request_line; then
    return 0
  fi
  request_line=${request_line%$'\r'}
  read -r method path version <<<"$request_line"
  log "Request line: $request_line"

  local header_line content_length=0 x_api_key="" header_name header_value
  while IFS= read -r header_line; do
    header_line=${header_line%$'\r'}
    [[ -z "$header_line" ]] && break
    log "Header: $header_line"
    if [[ "$header_line" =~ ^[Cc]ontent-[Ll]ength:\ ([0-9]+) ]]; then
      content_length=${BASH_REMATCH[1]}
    fi
    header_name=${header_line%%:*}
    header_value=${header_line#*:}
    header_name=${header_name,,}
    header_value=${header_value# }
    if [[ "$header_name" == "x-api-key" ]]; then
      x_api_key="$header_value"
    fi
  done

  if [[ -z "$x_api_key" ]]; then
    respond 401 '{"error":"missing api key"}'
    log "Unauthorized: missing x-api-key for $method $path"
    return 0
  fi
  if [[ "$x_api_key" != "$API_KEY" ]]; then
    respond 401 '{"error":"invalid api key"}'
    log "Unauthorized: invalid x-api-key for $method $path"
    return 0
  fi

  local body=""
  if (( content_length > 0 )); then
    if (( content_length > MAX_BODY )); then
      respond 400 '{"error":"Payload too large"}'
      log "Body rejected: $content_length bytes (too large)"
      return 0
    fi
    IFS= read -r -N "$content_length" body || true
    log "Body received: ${#body} bytes"
  fi

  case "$method $path" in
    "GET /")
      respond 200 '{"status":"ok"}'
      ;;
    "POST /node/update")
        handle_node_update
      ;;
    "POST /node/core_update")
        handle_node_core_update
      ;;
    *)
      respond 404 '{"error":"Not found"}'
      ;;
  esac
  log "Responded $LAST_STATUS to $method $path"
}

log "Bash REST API listening (TLS only) on https://localhost:${PORT}"
while true; do
  coproc OPENSSL { openssl s_server -quiet -accept "$PORT" -cert "$SSL_CERT_FILE" -key "$SSL_KEY_FILE" -naccept 1; }
  handle_connection <&"${OPENSSL[0]}" >&"${OPENSSL[1]}" || true
  exec {OPENSSL[0]}>&-
  exec {OPENSSL[1]}>&-
  wait "$OPENSSL_PID" 2>/dev/null || true
done
