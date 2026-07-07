# exitnode.sh - network sysctl tuning + Docker-only Mullvad exit-node routing
# with gray-failure failover. The battle-tested implementation lives in
# payloads/exitnode-routing.sh (formerly wiki/k8s-manifests/tailscale-exitnode.sh);
# this step just runs it. Rollback tool: payloads/exitnode-remove.sh.
#
# Workers only: docker (172.17.0.0/16) egresses via a Mullvad Tailscale exit
# node; the host itself (k3s, SSH) bypasses the tunnel.
# shellcheck shell=bash

STEP_DESC["exitnode-routing"]="sysctl tuning + Docker-via-Mullvad routing with auto-failover"
exitnode-routing::check() {
  systemctl is-active --quiet docker-tailscale-routing.service \
    && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]
}
exitnode-routing::apply() {
  bash "$PAYLOAD_DIR/exitnode-routing.sh"
}
exitnode-routing::verify() {
  systemctl is-active --quiet docker-tailscale-routing.service
}
