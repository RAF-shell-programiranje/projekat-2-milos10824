#!/usr/bin/env bash
set -euo pipefail

# This script is intended to run ON THE MONITOR VM.
# It installs packages, writes /etc/monitoring/monitoring.conf, installs the agent and enables systemd timer.

CONF_SRC="${1:-/tmp/monitoring.conf}"
AGENT_SRC="${2:-/tmp/monitoring-agent.sh}"
SERVICE_SRC="${3:-/tmp/monitoring-agent.service}"
TIMER_SRC="${4:-/tmp/monitoring-agent.timer}"
SSH_KEY_SRC="${5:-/tmp/app_ssh_key}"

sudo apt-get update -y
sudo apt-get install -y curl ca-certificates openssh-client msmtp msmtp-mta bsd-mailx

sudo mkdir -p /etc/monitoring /opt/monitoring /var/lib/monitoring
sudo mkdir -p /var/log

sudo cp "$CONF_SRC" /etc/monitoring/monitoring.conf
sudo cp "$AGENT_SRC" /opt/monitoring/monitoring-agent.sh
sudo chmod 755 /opt/monitoring/monitoring-agent.sh

sudo cp "$SERVICE_SRC" /etc/systemd/system/monitoring-agent.service
sudo cp "$TIMER_SRC" /etc/systemd/system/monitoring-agent.timer

# SSH key used by monitor VM to read status/logs/resources from APP VM
sudo cp "$SSH_KEY_SRC" /opt/monitoring/app_ssh_key
sudo chmod 600 /opt/monitoring/app_ssh_key

# Adjust timer interval from config (CHECK_INTERVAL_MINUTES)
INTERVAL="$(grep -E '^CHECK_INTERVAL_MINUTES=' /etc/monitoring/monitoring.conf | sed -E 's/.*"([0-9]+)".*/\1/' || true)"
if [[ -n "$INTERVAL" ]]; then
  sudo sed -i "s/OnUnitActiveSec=.*/OnUnitActiveSec=${INTERVAL}min/" /etc/systemd/system/monitoring-agent.timer
fi

sudo systemctl daemon-reload
sudo systemctl enable --now monitoring-agent.timer

echo "Monitoring installed."
sudo systemctl status monitoring-agent.timer --no-pager || true
