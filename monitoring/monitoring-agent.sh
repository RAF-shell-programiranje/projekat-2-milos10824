#!/usr/bin/env bash
set -euo pipefail

CONF_FILE="${1:-/etc/monitoring/monitoring.conf}"
if [[ ! -f "$CONF_FILE" ]]; then
  echo "Config not found: $CONF_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONF_FILE"

STATE_DIR="/var/lib/monitoring"
LOG_FILE="/var/log/monitoring-agent.log"
mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG_FILE" >/dev/null; }

send_email() {
  local subject="$1"
  local body="$2"

  if command -v msmtp >/dev/null 2>&1; then
    {
      echo "From: ${SMTP_FROM}"
      echo "To: ${SMTP_TO}"
      echo "Subject: ${subject}"
      echo "Date: $(date -R)"
      echo
      echo -e "$body"
    } | msmtp --read-envelope-from -t || log "ERROR: Failed to send email via msmtp"
  else
    log "WARN: msmtp not installed; email not sent. Subject=$subject"
    log "BODY: $body"
  fi
}

ensure_msmtp_config() {
  # Configure /etc/msmtprc based on monitoring.conf
  # NOTE: This stores SMTP_PASS on disk. For coursework this is OK; in real systems use vault/secrets.
  if [[ -z "${SMTP_HOST:-}" || -z "${SMTP_PORT:-}" || -z "${SMTP_USER:-}" || -z "${SMTP_PASS:-}" ]]; then
    log "WARN: SMTP_* not fully configured; skipping /etc/msmtprc setup"
    return 0
  fi

  cat >/etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT}
user           ${SMTP_USER}
password       ${SMTP_PASS}
from           ${SMTP_FROM}

account default : default
EOF
  chmod 600 /etc/msmtprc
}

remote() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${APP_SSH_KEY_PATH}" \
    "${APP_SSH_USER}@${APP_HOST}" "$@"
}

check_http() {
  local url="http://${APP_HOST}:${APP_PORT}/"
  if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
    log "HTTP OK: $url"
    return 0
  else
    log "HTTP FAIL: $url"
    send_email "[ALERT] App HTTP unreachable" "App is not reachable at: $url\nTime: $(date -Is)"
    return 1
  fi
}

check_service() {
  local st
  st="$(remote "systemctl is-active ${APP_SERVICE_NAME} || true")"
  if [[ "$st" == "active" ]]; then
    log "Service OK: ${APP_SERVICE_NAME}"
    return 0
  else
    log "Service FAIL: ${APP_SERVICE_NAME} (status=$st)"
    send_email "[ALERT] App service down" "Service ${APP_SERVICE_NAME} is not active (status=$st)\nHost: ${APP_HOST}\nTime: $(date -Is)"
    return 1
  fi
}

check_logs() {
  # Look at last 500 lines and count WARN/ERROR
  local last
  last="$(remote "test -f '${APP_LOG_PATH}' && tail -n 500 '${APP_LOG_PATH}' || echo '__NOLOG__'")"
  if [[ "$last" == "__NOLOG__" ]]; then
    log "WARN: Log file not found: ${APP_LOG_PATH}"
    return 0
  fi
  local errors warns
  errors="$(echo "$last" | grep -i -c "error" || true)"
  warns="$(echo "$last" | grep -i -c "warn" || true)"

  log "Log stats: ERROR=$errors WARN=$warns (last 500 lines)"

  if [[ "$errors" -gt 0 ]]; then
    send_email "[WARN] App log contains ERROR" "Detected ${errors} lines containing 'error' in last 500 log lines.\nHost: ${APP_HOST}\nLog: ${APP_LOG_PATH}\nTime: $(date -Is)"
  fi
}

check_resources() {
  # CPU (% used), MEM (% used), DISK (% used on /)
  local cpu mem disk

  cpu="$(remote "LC_ALL=C top -bn1 | awk -F',' '/Cpu\\(s\\)/ {gsub(\"%id\",\"\",\$4); gsub(/^[ \\t]+/,\"\",\$4); print int(100-\$4)}' | head -n1" || echo "0")"
  mem="$(remote "free | awk '/Mem:/ {print int(\$3*100/\$2)}'" || echo "0")"
  disk="$(remote "df -P / | awk 'NR==2 {gsub(/%/,\"\",\$5); print int(\$5)}'" || echo "0")"

  log "Resources: CPU=${cpu}% MEM=${mem}% DISK=${disk}%"

  local alert=""
  if [[ "$cpu" -ge "${CPU_THRESHOLD}" ]]; then alert+="CPU ${cpu}% >= ${CPU_THRESHOLD}%\n"; fi
  if [[ "$mem" -ge "${MEM_THRESHOLD}" ]]; then alert+="MEM ${mem}% >= ${MEM_THRESHOLD}%\n"; fi
  if [[ "$disk" -ge "${DISK_THRESHOLD}" ]]; then alert+="DISK ${disk}% >= ${DISK_THRESHOLD}%\n"; fi

  if [[ -n "$alert" ]]; then
    send_email "[ALERT] Resource threshold exceeded" "One or more resource thresholds exceeded on APP VM (${APP_HOST}):\n\n${alert}\nTime: $(date -Is)"
  fi
}

maybe_send_maintenance() {
  if [[ "${MAINTENANCE_NOTIFY}" != "true" ]]; then
    return 0
  fi

  local today
  today="$(date +%F)"
  local stamp="${STATE_DIR}/maintenance_last_sent"
  local last=""
  [[ -f "$stamp" ]] && last="$(cat "$stamp" || true)"

  if [[ "$last" != "$today" ]]; then
    send_email "[INFO] Maintenance notice" "${MAINTENANCE_MESSAGE}\nTime: $(date -Is)"
    echo "$today" > "$stamp"
    log "Maintenance notice sent."
  fi
}

main() {
  ensure_msmtp_config
  maybe_send_maintenance
  # Each check is independent; we don't want one failure to stop others.
  check_http || true
  check_service || true
  check_logs || true
  check_resources || true
}

main "$@"
