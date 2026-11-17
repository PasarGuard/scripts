#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export APP_TMP_DIR="$WORK_DIR/tmp" APP_DIR="$WORK_DIR/app" DATA_DIR="$WORK_DIR/data" PG_NODE_SOURCE_ONLY=true
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR/certs"
curl() { :; }
source "$ROOT_DIR/pg-node.sh"
check_running_as_root() { :; }
colorized_echo() { printf '%s\n' "$*"; }
expect_fail() { if "$@"; then echo "FAIL: accepted $*" >&2; exit 1; fi; }
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 6 -subj '/CN=test' \
    -addext 'subjectAltName=IP:192.0.2.1' -keyout "$SSL_KEY_FILE" -out "$SSL_CERT_FILE" >/dev/null 2>&1
printf 'SSL_CERT_FILE=%s\nSSL_KEY_FILE=%s\nSERVICE_PORT=62050\nAPI_PORT=62051\n' "$SSL_CERT_FILE" "$SSL_KEY_FILE" >"$ENV_FILE"
# A controllable clock leaves certificate parsing on the real date command.
clock_now=$(command date +%s)
date() { if [ "$*" = +%s ]; then echo "$clock_now"; else command date "$@"; fi; }
acme_calls="$WORK_DIR/acme-calls"
get_node_acme() { echo mock_acme; }
mock_acme() {
    [[ " $* " == *" --cert-home $DATA_DIR/certs/acme "* ]]
    # Scheduler and synchronous hook retain the certificate lock.
    ! flock -n "$DATA_DIR/certs/.deployment.lock" true
    echo call >>"$acme_calls"
    case "$acme_result" in
        skip) return 2;;
        transient) echo 'network failed secret-token'; return 1;;
        ca_delay) echo 'Retry-After: 7200'; return 1;;
        config) echo 'rejectedIdentifier secret-token'; return 1;;
        success) finish_node_cert_deployment;;
    esac
}
reload_calls="$WORK_DIR/reloads"
reload_node_cert_services() { echo signal >>"$reload_calls"; return 0; }
verify_node_cert_services() { [ "$verify_ok" = true ]; }
verify_ok=true
# Scheduler ignores every operator-managed source, even expired self-signed files.
for source in self_signed custom external_tls; do
    save_cert_source "$source"
    certificate_renewal_tick
    [ ! -e "$acme_calls" ]
done
save_cert_source acme_ip 192.0.2.1 '' 80
# Exact fallback stays unpinned so acme.sh can honor CA renewal windows.
mkdir -p "$DATA_DIR/certs/acme/192.0.2.1"
printf "Le_RenewalDays='6'\nLe_NextRenewTime='1'\nLe_Domain='192.0.2.1'\n" >"$DATA_DIR/certs/acme/192.0.2.1/192.0.2.1.conf"
acme_result=skip
certificate_renewal_tick
[ "$(node_cert_status_value next_attempt)" -eq "$((clock_now+3600))" ]
! grep -q '^Le_RenewalDays=' "$DATA_DIR/certs/acme/192.0.2.1/192.0.2.1.conf"
grep -q "Le_NextRenewTime='$((clock_now+4*86400))'" "$DATA_DIR/certs/acme/192.0.2.1/192.0.2.1.conf"
certificate_renewal_tick
[ "$(wc -l <"$acme_calls")" -eq 1 ]
clock_now=$((clock_now+3600)); acme_result=transient
expect_fail certificate_renewal_tick
[ "$(node_cert_status_value failures)" -eq 1 ]
next=$(node_cert_status_value next_attempt)
[ "$next" -ge "$((clock_now+300))" ] && [ "$next" -le "$((clock_now+360))" ]
! grep -q secret-token "$DATA_DIR/certs/renewal-status.json"
clock_now="$next"
expect_fail certificate_renewal_tick
[ "$(node_cert_status_value failures)" -eq 2 ]
next=$(node_cert_status_value next_attempt)
[ "$next" -ge "$((clock_now+600))" ] && [ "$next" -le "$((clock_now+720))" ]
clock_now="$next"; acme_result=ca_delay
expect_fail certificate_renewal_tick
[ "$(node_cert_status_value next_attempt)" -eq "$((clock_now+7200))" ]
clock_now=$((clock_now+7200)); acme_result=config
expect_fail certificate_renewal_tick
[ "$(node_cert_status_value deployment_state)" = suspended ]
previous_calls=$(wc -l <"$acme_calls")
clock_now=$((clock_now+10000))
certificate_renewal_tick
[ "$(wc -l <"$acme_calls")" -eq "$previous_calls" ]
# Configuration changes resume checks; retries may not expose ACME output in status.
printf '\n# corrected challenge routing\n' >>"$ENV_FILE"
acme_result=skip
certificate_renewal_tick
[ "$(wc -l <"$acme_calls")" -eq "$((previous_calls+1))" ]
# Success requires both fresh endpoint checks. A partial reload preserves the last
# verified observation and retries only signalling, without any ACME invocation.
clock_now=$(command date +%s)
write_node_cert_status deployed
active_pin=$(node_cert_status_value active_fingerprint)
verify_ok=false
expect_fail finish_node_cert_deployment
[ "$(node_cert_status_value active_fingerprint)" = "$active_pin" ]
[ "$(node_cert_status_value deployment_state)" = reload_pending ]
previous_calls=$(wc -l <"$acme_calls")
clock_now=$((clock_now+300)); verify_ok=true
certificate_renewal_tick
[ "$(node_cert_status_value deployment_state)" = deployed ]
[ "$(wc -l <"$acme_calls")" -eq "$previous_calls" ]
[ "$(stat -c %a "$DATA_DIR/certs/renewal-status.json")" = 600 ]
[ -z "$(find "$DATA_DIR/certs" -name '.status.*' -print)" ]
certificate_status_command --json | jq -e '.files_currently_valid and .last_success != null' >/dev/null
clock_now=$((clock_now+7*86400))
certificate_status_command --json | jq -e '.files_currently_valid == false' >/dev/null
expect_fail certificate_status_command --bogus
# Invalid trailing PEM blocks cannot be mistaken for a valid full chain.
clock_now=$(command date +%s)
cp "$SSL_CERT_FILE" "$WORK_DIR/broken-chain"
printf '\n-----BEGIN CERTIFICATE-----\ninvalid\n' >>"$WORK_DIR/broken-chain"
expect_fail validate_node_cert_pair "$WORK_DIR/broken-chain" "$SSL_KEY_FILE"
# Idempotent scheduler registration preserves unrelated jobs and removes only ours.
cronfile="$WORK_DIR/crontab"
printf '0 0 * * * echo unrelated\n' >"$cronfile"
crontab() { if [ "$1" = -l ]; then cat "$cronfile"; else cp "$1" "$cronfile"; fi; }
install_node_cert_scheduler
install_node_cert_scheduler
[ "$(grep -c 'pg-node-cert:' "$cronfile")" -eq 1 ]
grep -q '^\*/5 ' "$cronfile"
remove_node_cert_scheduler
[ "$(cat "$cronfile")" = '0 0 * * * echo unrelated' ]
echo 'Certificate renewal scheduler tests passed'
