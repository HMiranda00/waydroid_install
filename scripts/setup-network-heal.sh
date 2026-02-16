#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

HEAL_SCRIPT="/usr/local/sbin/waydroid-network-heal"
HEAL_SERVICE="/etc/systemd/system/waydroid-network-heal.service"
HEAL_TIMER="/etc/systemd/system/waydroid-network-heal.timer"

run_sudo tee "${HEAL_SCRIPT}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
BRIDGE="waydroid0"
LXC_PATH="/var/lib/waydroid/lxc"
LXC_NAME="waydroid"

log() {
  printf "[waydroid-network-heal] %s\n" "$*" >&2
}

ensure_host_network() {
  ip link show "${BRIDGE}" >/dev/null 2>&1 || exit 0
  ip link set "${BRIDGE}" up || true
  ip addr add 192.168.240.1/24 dev "${BRIDGE}" 2>/dev/null || true

  local iface ipt
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  [ -n "${iface}" ] || exit 0

  if command -v iptables-legacy >/dev/null 2>&1; then
    ipt="iptables-legacy"
  else
    ipt="iptables"
  fi

  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  ${ipt} -P FORWARD ACCEPT || true
  ${ipt} -t nat -C POSTROUTING -s 192.168.240.0/24 -o "${iface}" -j MASQUERADE 2>/dev/null \
    || ${ipt} -t nat -A POSTROUTING -s 192.168.240.0/24 -o "${iface}" -j MASQUERADE
  ${ipt} -C FORWARD -i "${BRIDGE}" -o "${iface}" -j ACCEPT 2>/dev/null \
    || ${ipt} -A FORWARD -i "${BRIDGE}" -o "${iface}" -j ACCEPT
  ${ipt} -C FORWARD -i "${iface}" -o "${BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || ${ipt} -A FORWARD -i "${iface}" -o "${BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

container_running() {
  local state
  state="$(lxc-info -P "${LXC_PATH}" -n "${LXC_NAME}" -sH 2>/dev/null || true)"
  [ "${state}" = "RUNNING" ] || [ "${state}" = "FROZEN" ]
}

heal_container() {
  local veth
  veth="$(lxc-info -P "${LXC_PATH}" -n "${LXC_NAME}" 2>/dev/null | sed -n 's/^Link:[[:space:]]*//p' || true)"
  if [ -n "${veth}" ] && ip link show "${veth}" >/dev/null 2>&1; then
    ip link set "${veth}" master "${BRIDGE}" 2>/dev/null || true
    ip link set "${veth}" up 2>/dev/null || true
  fi

  lxc-attach -P "${LXC_PATH}" -n "${LXC_NAME}" -- ip link set eth0 up >/dev/null 2>&1 || true
  lxc-attach -P "${LXC_PATH}" -n "${LXC_NAME}" -- ip route replace default via 192.168.240.1 dev eth0 onlink >/dev/null 2>&1 || true
  lxc-attach -P "${LXC_PATH}" -n "${LXC_NAME}" -- ip route replace default via 192.168.240.1 dev eth0 onlink table eth0 >/dev/null 2>&1 || true
}

main() {
  ensure_host_network
  if container_running; then
    heal_container
    log "network heal applied"
  fi
}

main "$@"
EOF

run_sudo chmod 755 "${HEAL_SCRIPT}"

run_sudo tee "${HEAL_SERVICE}" >/dev/null <<EOF
[Unit]
Description=Heal Waydroid network routing and NAT
After=network-online.target waydroid-container.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${HEAL_SCRIPT}
EOF

run_sudo tee "${HEAL_TIMER}" >/dev/null <<'EOF'
[Unit]
Description=Periodic Waydroid network heal

[Timer]
OnBootSec=20s
OnUnitActiveSec=20s
Persistent=true

[Install]
WantedBy=timers.target
EOF

run_sudo systemctl daemon-reload
run_sudo systemctl enable --now waydroid-network-heal.timer
run_sudo systemctl start waydroid-network-heal.service

log_info "Installed waydroid network heal service/timer."

