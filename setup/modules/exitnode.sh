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

# direct-egress module: nodes whose Docker traffic leaves through their own
# address. Same tuning, no exit-node routing; replaces exitnode-routing.
_direct_egress_ok() {
  ! systemctl is-active --quiet docker-tailscale-routing.service \
    && [[ ! -f /etc/systemd/system/docker-tailscale-routing.service ]] \
    && ! ip rule show | grep -q "^5100:" \
    && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]
}
STEP_DESC["direct-egress"]="sysctl tuning, Docker egress through the host's own address (no exit node)"
direct-egress::check() {
  _direct_egress_ok
}
direct-egress::apply() {
  bash "$PAYLOAD_DIR/exitnode-routing.sh" --direct
}
direct-egress::verify() {
  _direct_egress_ok
}
