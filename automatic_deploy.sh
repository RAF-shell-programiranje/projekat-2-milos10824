#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
ANS_DIR="${ROOT_DIR}/ansible"
MON_DIR="${ROOT_DIR}/monitoring"
KEY_DIR="${ROOT_DIR}/.keys"
DEPLOY_DIR="${ROOT_DIR}/.deploy"

usage() {
  cat <<EOF
Usage:
  ./automatic_deploy.sh --provision
  ./automatic_deploy.sh --deploy
  ./automatic_deploy.sh --check-status
  ./automatic_deploy.sh --monitor
  ./automatic_deploy.sh --teardown

Optional environment variables:
  AZ_LOCATION           Azure region (default: westeurope)
  VM_SIZE               Azure VM size (default: Standard_B1s)
  ALLOWED_SSH_CIDR      CIDR allowed for SSH (recommended: your_public_ip/32)
  ADMIN_USERNAME        Linux admin user (default: azureuser)
  APP_PORT              Application port (default: 8080)
  APP_AGENTS            Number of agents passed to the jar (default: 50)

Notes:
  - This script generates a dedicated SSH key in .keys/ for this project.
  - After --provision it writes ansible/inventory.ini and monitoring/monitoring.conf (edit SMTP_*).
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

ensure_key() {
  mkdir -p "$KEY_DIR"
  if [[ ! -f "${KEY_DIR}/project2_id_rsa" ]]; then
    echo "Generating SSH keypair in ${KEY_DIR}/project2_id_rsa ..."
    ssh-keygen -t rsa -b 4096 -N "" -f "${KEY_DIR}/project2_id_rsa" >/dev/null
  fi
}

ensure_tfvars() {
  local tfvars="${TF_DIR}/terraform.tfvars"
  if [[ ! -f "$tfvars" ]]; then
    echo "Creating ${tfvars} from example ..."
    cp "${TF_DIR}/terraform.tfvars.example" "$tfvars"
  fi

  # Ensure ssh_public_key_path is set to our generated key.
  local pub="${KEY_DIR}/project2_id_rsa.pub"
  if ! grep -q '^ssh_public_key_path' "$tfvars"; then
    echo "ssh_public_key_path = \"${pub}\"" >>"$tfvars"
  else
    # replace line
    sed -i.bak "s|^ssh_public_key_path.*|ssh_public_key_path = \"${pub}\"|g" "$tfvars" && rm -f "${tfvars}.bak"
  fi

  # Set a few defaults if user wants via env
  local loc="${AZ_LOCATION:-}"
  local size="${VM_SIZE:-}"
  local cidr="${ALLOWED_SSH_CIDR:-}"
  local user="${ADMIN_USERNAME:-}"
  local port="${APP_PORT:-}"

  [[ -n "$loc" ]]  && sed -i.bak "s|^location.*|location = \"${loc}\"|g" "$tfvars" && rm -f "${tfvars}.bak"
  [[ -n "$size" ]] && sed -i.bak "s|^vm_size.*|vm_size = \"${size}\"|g" "$tfvars" && rm -f "${tfvars}.bak"
  [[ -n "$cidr" ]] && sed -i.bak "s|^allowed_ssh_cidr.*|allowed_ssh_cidr = \"${cidr}\"|g" "$tfvars" && rm -f "${tfvars}.bak"
  [[ -n "$user" ]] && sed -i.bak "s|^admin_username.*|admin_username = \"${user}\"|g" "$tfvars" && rm -f "${tfvars}.bak"
  [[ -n "$port" ]] && sed -i.bak "s|^app_port.*|app_port = ${port}|g" "$tfvars" && rm -f "${tfvars}.bak"
}

tf_output_json() {
  terraform -chdir="$TF_DIR" output -json
}

write_inventory_and_monitor_conf() {
  mkdir -p "$DEPLOY_DIR"

  local out
  out="$(tf_output_json)"
  echo "$out" > "${DEPLOY_DIR}/terraform_outputs.json"

  local app_pub mon_pub app_priv mon_priv user port
  app_pub="$(echo "$out" | python3 -c 'import sys, json; o=json.load(sys.stdin); print(o["app_public_ip"]["value"])')"
  mon_pub="$(echo "$out" | python3 -c 'import sys, json; o=json.load(sys.stdin); print(o["monitor_public_ip"]["value"])')"
  app_priv="$(echo "$out" | python3 -c 'import sys, json; o=json.load(sys.stdin); print(o["app_private_ip"]["value"])')"
  mon_priv="$(echo "$out" | python3 -c 'import sys, json; o=json.load(sys.stdin); print(o["monitor_private_ip"]["value"])')"

  user="$(grep -E '^admin_username' "${TF_DIR}/terraform.tfvars" | sed -E 's/.*"([^"]+)".*/\1/')"
  port="$(grep -E '^app_port' "${TF_DIR}/terraform.tfvars" | awk -F'=' '{gsub(/ /,"",$2); print $2}' | head -n1)"
  [[ -z "$port" ]] && port="8080"

  cat > "${ANS_DIR}/inventory.ini" <<EOF
[app]
app ansible_host=${app_pub} ansible_user=${user} ansible_ssh_private_key_file=${KEY_DIR}/project2_id_rsa

[monitor]
monitor ansible_host=${mon_pub} ansible_user=${user} ansible_ssh_private_key_file=${KEY_DIR}/project2_id_rsa

[all:vars]
app_port=${port}
app_private_ip=${app_priv}
monitor_private_ip=${mon_priv}
app_log_path=/var/log/project2-dummy/app.log
EOF

  # Create monitoring.conf if not exists; fill in APP_HOST/PORT
  local conf="${MON_DIR}/monitoring.conf"
  if [[ ! -f "$conf" ]]; then
    cp "${MON_DIR}/monitoring.conf.example" "$conf"
  fi
  sed -i.bak "s|^APP_HOST=.*|APP_HOST=\"${app_priv}\"|g" "$conf" && rm -f "${conf}.bak"
  sed -i.bak "s|^APP_PORT=.*|APP_PORT=\"${port}\"|g" "$conf" && rm -f "${conf}.bak"
  sed -i.bak "s|^APP_SSH_USER=.*|APP_SSH_USER=\"${user}\"|g" "$conf" && rm -f "${conf}.bak"

  echo
  echo "Provision complete."
  echo "APP public IP:     ${app_pub}"
  echo "MONITOR public IP: ${mon_pub}"
  echo
  echo "SSH:"
  echo "  ssh -i ${KEY_DIR}/project2_id_rsa ${user}@${app_pub}"
  echo "  ssh -i ${KEY_DIR}/project2_id_rsa ${user}@${mon_pub}"
  echo
  echo "Generated:"
  echo "  - ${ANS_DIR}/inventory.ini"
  echo "  - ${MON_DIR}/monitoring.conf (EDIT SMTP_* values before --monitor)"
}

provision() {
  need_cmd terraform
  need_cmd ssh-keygen
  need_cmd python3

  ensure_key
  ensure_tfvars

  echo "Running terraform init/apply..."
  terraform -chdir="$TF_DIR" init -upgrade
  terraform -chdir="$TF_DIR" apply -auto-approve

  write_inventory_and_monitor_conf
}

deploy() {
  need_cmd ansible-playbook
  [[ -f "${ANS_DIR}/inventory.ini" ]] || { echo "Missing ansible/inventory.ini. Run --provision first." >&2; exit 1; }

  local agents="${APP_AGENTS:-50}"
  local port="${APP_PORT:-}"
  echo "Deploying app with Ansible (agents=${agents})..."
  ANSIBLE_CONFIG="${ANS_DIR}/ansible.cfg" ansible-playbook "${ANS_DIR}/deploy_app.yml" \
    -i "${ANS_DIR}/inventory.ini" \
    --extra-vars "app_agents=${agents} ${port:+app_port=${port}}"

  # Optional: prepare app with extra tools used by monitoring
  ANSIBLE_CONFIG="${ANS_DIR}/ansible.cfg" ansible-playbook "${ANS_DIR}/prepare_app_for_monitor.yml" \
    -i "${ANS_DIR}/inventory.ini" || true
}

check_status() {
  need_cmd ansible
  [[ -f "${ANS_DIR}/inventory.ini" ]] || { echo "Missing ansible/inventory.ini. Run --provision first." >&2; exit 1; }

  echo "Checking service status on APP VM..."
  ANSIBLE_CONFIG="${ANS_DIR}/ansible.cfg" ansible app -i "${ANS_DIR}/inventory.ini" -b -m shell -a "systemctl is-active project2-dummy && systemctl --no-pager -l status project2-dummy | head -n 30" || true

  echo
  echo "Checking if app port is reachable from APP VM (localhost)..."
  ANSIBLE_CONFIG="${ANS_DIR}/ansible.cfg" ansible app -i "${ANS_DIR}/inventory.ini" -b -m shell -a "curl -fsS --max-time 3 http://127.0.0.1:\${app_port:-8080}/ >/dev/null && echo OK || echo FAIL" || true
}

monitor() {
  need_cmd ssh
  need_cmd scp
  [[ -f "${ANS_DIR}/inventory.ini" ]] || { echo "Missing ansible/inventory.ini. Run --provision first." >&2; exit 1; }
  [[ -f "${MON_DIR}/monitoring.conf" ]] || { echo "Missing monitoring/monitoring.conf. Run --provision first." >&2; exit 1; }

  local mon_host user
  mon_host="$(awk '/^\[monitor\]/{f=1;next} /^\[/{f=0} f && $1 ~ /^monitor/ {for(i=1;i<=NF;i++){if($i ~ /^ansible_host=/){split($i,a,"="); print a[2]}}}' "${ANS_DIR}/inventory.ini")"
  user="$(awk '/^\[monitor\]/{f=1;next} /^\[/{f=0} f && $1 ~ /^monitor/ {for(i=1;i<=NF;i++){if($i ~ /^ansible_user=/){split($i,a,"="); print a[2]}}}' "${ANS_DIR}/inventory.ini")"
  [[ -z "$user" ]] && user="azureuser"

  echo "Uploading monitoring scripts to MONITOR VM (${mon_host})..."
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_DIR}/project2_id_rsa" \
    "${MON_DIR}/monitoring.conf" \
    "${MON_DIR}/monitoring-agent.sh" \
    "${MON_DIR}/monitoring-agent.service" \
    "${MON_DIR}/monitoring-agent.timer" \
    "${MON_DIR}/install_monitoring.sh" \
    "${KEY_DIR}/project2_id_rsa" \
    "${user}@${mon_host}:/tmp/" >/dev/null

  echo "Installing monitoring on MONITOR VM..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_DIR}/project2_id_rsa" \
    "${user}@${mon_host}" \
    "bash /tmp/install_monitoring.sh /tmp/monitoring.conf /tmp/monitoring-agent.sh /tmp/monitoring-agent.service /tmp/monitoring-agent.timer /tmp/project2_id_rsa"

  echo
  echo "Done. You can check logs on MONITOR VM:"
  echo "  sudo tail -n 200 /var/log/monitoring-agent.log"
  echo "  sudo systemctl list-timers --all | grep monitoring-agent"
}

teardown() {
  need_cmd terraform
  echo "Running terraform destroy..."
  terraform -chdir="$TF_DIR" destroy -auto-approve || true
  echo "Teardown complete."
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  --provision) provision ;;
  --deploy) deploy ;;
  --check-status) check_status ;;
  --monitor) monitor ;;
  --teardown) teardown ;;
  -h|--help) usage ;;
  *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
esac
