#!/bin/bash
# session-isolation.sh - installed as /usr/local/sbin/browser-session-isolation
# and run by browser-session-isolation.service before docker starts. Needs root.
#
# A browser container may open connections to the public internet and to the
# API's internal callback address (VM_API_INTERNAL_URL), nothing else: no other
# container (bridge addresses, ports the edge publishes on the tailnet address),
# no tailnet peer, pod, service or host-local private address. The chain sits
# in mangle PREROUTING, before Docker's and kube-proxy's DNAT and their accept
# rules, so it judges the address a container dialled and no later rule can let
# a session past it. Only packets a container originates are judged: replies on
# connections the edge, the proxy, coturn, the API or the analyzer opened to a
# container pass. Idempotent; the chain is replaced atomically.
set -euo pipefail

BRIDGE="docker0"
CHAIN="BROWSER-SESSION-ISOLATION"
# The egress dispatcher's denied ranges (browser repo,
# containers/base/root/opt/egress/netpolicy.py), IPv4 part.
DENIED_V4=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
  172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4)

[[ $# -ge 1 ]] || { echo "usage: browser-session-isolation <api-ipv4:port>..." >&2; exit 64; }
for allow in "$@"; do
  [[ "$allow" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] \
    || { echo "browser-session-isolation: '$allow' is not ipv4:port" >&2; exit 64; }
done

# Container-to-container frames on the bridge reach iptables only through
# br_netfilter.
modprobe br_netfilter
sysctl -qw net.bridge.bridge-nf-call-iptables=1 net.bridge.bridge-nf-call-ip6tables=1

rules_v4() {
  echo "*mangle"
  echo ":$CHAIN - [0:0]"
  echo "-F $CHAIN"
  echo "-A $CHAIN -m conntrack --ctdir REPLY -j RETURN"
  local allow net
  for allow in "$@"; do
    echo "-A $CHAIN -d ${allow%:*}/32 -p tcp --dport ${allow##*:} -j RETURN"
  done
  for net in "${DENIED_V4[@]}"; do
    echo "-A $CHAIN -d $net -j DROP"
  done
  echo "COMMIT"
}

# Sessions have no IPv6 route; anything but global unicast stays on the node.
rules_v6() {
  echo "*mangle"
  echo ":$CHAIN - [0:0]"
  echo "-F $CHAIN"
  echo "-A $CHAIN -m conntrack --ctdir REPLY -j RETURN"
  echo "-A $CHAIN ! -d 2000::/3 -j DROP"
  echo "COMMIT"
}

rules_v4 "$@" | iptables-restore -w --noflush
iptables -w -t mangle -C PREROUTING -i "$BRIDGE" -j "$CHAIN" 2>/dev/null \
  || iptables -w -t mangle -I PREROUTING 1 -i "$BRIDGE" -j "$CHAIN"

if command -v ip6tables >/dev/null; then
  rules_v6 | ip6tables-restore -w --noflush
  ip6tables -w -t mangle -C PREROUTING -i "$BRIDGE" -j "$CHAIN" 2>/dev/null \
    || ip6tables -w -t mangle -I PREROUTING 1 -i "$BRIDGE" -j "$CHAIN"
fi
