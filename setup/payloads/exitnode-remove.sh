#!/bin/bash
#
# Tailscale setup: Docker-only tunneling + exit node auto-failover.
# Docker containers (172.17.0.0/16) route through the Mullvad exit node.
# K3s, SSH, and all host traffic use the normal ISP route.
# Exit node is monitored every 60s and auto-switched if it goes offline.
#
# ip rules:
#   5000: to 172.17.0.0/16 → main        (Docker-internal traffic stays local)
#   5050: to 100.64.0.0/10 → table 52    (Tailscale peer traffic via WireGuard)
#   5100: not from 172.17.0.0/16 → main  (everything else bypasses tunnel)
#   5210+: Tailscale → Docker containers exit via Mullvad
#
set -euo pipefail

PRIORITY_DOCKER_INTERNAL=5000
PRIORITY_TAILSCALE_PEERS=5050
PRIORITY_BYPASS=5100
DOCKER_NETWORK="172.17.0.0/16"
TAILSCALE_CGNAT="100.64.0.0/10"
SERVICE_NAME="docker-tailscale-routing.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
MONITOR_SCRIPT="/usr/local/bin/docker-tailscale-routing.sh"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [tailscale-fix] $*"
}

# Cleanup

log "Cleaning up old services and rules..."

for SVC in k3s-ip-rules.service \
           k3s-tailscale-routing.service \
           tailscale-exitnode-monitor.timer \
           tailscale-exitnode-monitor.service \
           "${SERVICE_NAME}"; do
    systemctl stop "${SVC}" 2>/dev/null || true
    systemctl disable "${SVC}" 2>/dev/null || true
    systemctl kill "${SVC}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SVC}"
    systemctl reset-failed "${SVC}" 2>/dev/null || true
done
rm -f /usr/local/bin/k3s-ip-rules.sh \
      /usr/local/bin/k3s-tailscale-routing.sh \
      /usr/local/bin/tailscale-exitnode-monitor.sh \
      "${MONITOR_SCRIPT}"
systemctl daemon-reload

for P in "${PRIORITY_DOCKER_INTERNAL}" "${PRIORITY_TAILSCALE_PEERS}" "${PRIORITY_BYPASS}" 5200; do
    while ip rule del priority "${P}" 2>/dev/null; do :; done
done

OLD_CHAIN="K3S_PORT_BYPASS"
iptables -t mangle -F "${OLD_CHAIN}" 2>/dev/null || true
for CHAIN in OUTPUT PREROUTING; do
    while iptables -t mangle -D "${CHAIN}" -j "${OLD_CHAIN}" 2>/dev/null; do :; done
    for DIR in --sport --dport; do
        for PORT in 80 443 6443 10250; do
            iptables -t mangle -D "${CHAIN}" -p tcp "${DIR}" "${PORT}" -j "${OLD_CHAIN}" 2>/dev/null || true
        done
        iptables -t mangle -D "${CHAIN}" -p udp "${DIR}" 8472 -j "${OLD_CHAIN}" 2>/dev/null || true
    done
    iptables -t mangle -D "${CHAIN}" -p tcp --dport 30000:32767 -j "${OLD_CHAIN}" 2>/dev/null || true
    iptables -t mangle -D "${CHAIN}" -p tcp --sport 30000:32767 -j "${OLD_CHAIN}" 2>/dev/null || true
done
iptables -t mangle -X "${OLD_CHAIN}" 2>/dev/null || true
log "Cleanup complete"

# ip rules

log "Adding ip rules..."
ip rule add to "${DOCKER_NETWORK}" lookup main priority "${PRIORITY_DOCKER_INTERNAL}"
ip rule add to "${TAILSCALE_CGNAT}" lookup 52 priority "${PRIORITY_TAILSCALE_PEERS}"
ip rule add not from "${DOCKER_NETWORK}" lookup main priority "${PRIORITY_BYPASS}"
log "ip rules in place"

# Monitor script

log "Creating monitor script..."
cat > "${MONITOR_SCRIPT}" << 'MONITOR_EOF'
#!/bin/bash
set -euo pipefail

PRIORITY_DOCKER_INTERNAL=5000
PRIORITY_TAILSCALE_PEERS=5050
PRIORITY_BYPASS=5100
DOCKER_NETWORK="172.17.0.0/16"
TAILSCALE_CGNAT="100.64.0.0/10"
EXIT_NODE_CHECK_INTERVAL=12  # iterations × 5s = 60s

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [docker-tailscale] $*"; }

ensure_rule() {
    local priority="$1"; shift
    if ! ip rule show priority "${priority}" 2>/dev/null | grep -q .; then
        log "Restoring: ip rule add $* priority ${priority}"
        ip rule add "$@" priority "${priority}"
    fi
}

check_exit_node() {
    local status
    status=$(tailscale status --json 2>/dev/null | jq -r '.ExitNodeStatus.Online' 2>/dev/null || echo "false")
    if [ "${status}" != "true" ]; then
        log "Exit node offline - getting suggestion..."
        local suggested
        suggested=$(tailscale exit-node suggest 2>/dev/null | grep "exit-node=" | sed 's/.*--exit-node=\([^`]*\)`.*/\1/' || true)
        if [ -n "${suggested}" ]; then
            log "Switching to: ${suggested}"
            tailscale set --exit-node="${suggested}"
        else
            log "No suggestion available"
        fi
    fi
}

log "Monitor started (ip rules every 5s, exit node check every 60s)"
iter=0
while true; do
    ensure_rule "${PRIORITY_DOCKER_INTERNAL}" to "${DOCKER_NETWORK}" lookup main
    ensure_rule "${PRIORITY_TAILSCALE_PEERS}" to "${TAILSCALE_CGNAT}" lookup 52
    ensure_rule "${PRIORITY_BYPASS}" not from "${DOCKER_NETWORK}" lookup main
    iter=$(( iter + 1 ))
    if (( iter % EXIT_NODE_CHECK_INTERVAL == 0 )); then check_exit_node; fi
    sleep 5
done
MONITOR_EOF
chmod +x "${MONITOR_SCRIPT}"

# Systemd service

log "Creating ${SERVICE_NAME}..."
cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Docker Tailscale Routing - Docker-only tunneling + exit node auto-failover
After=network.target tailscaled.service docker.service
Wants=tailscaled.service

[Service]
Type=simple
Restart=always
RestartSec=60
ExecStart=${MONITOR_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

# Verify

sleep 2
STATUS=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)
if [[ "${STATUS}" != "active" ]]; then
    log "ERROR: service status is '${STATUS}'"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 20
    exit 1
fi

log "SUCCESS - unified Tailscale service is active"
log ""
ip rule show | head -15
log ""
log "  docker run --rm curlimages/curl -s ifconfig.me   # Mullvad IP"
log "  curl -s ifconfig.me                               # real server IP"
log "  kubectl exec <pod> -- curl -s ifconfig.me         # real server IP"
log ""
log "  systemctl status ${SERVICE_NAME}"
log "  journalctl -u ${SERVICE_NAME} -f"
