# session-isolation.sh - browser sessions reach the internet and the API's
# internal callback address only: never another container, the tailnet, pods,
# services or the node itself (payloads/session-isolation.sh). The rules load
# before docker starts, so no container runs a moment without them.
#
# SESSION_API_ENDPOINT is the host:port of the API's VM_API_INTERNAL_URL that
# containers post their webhooks to; it defaults to the control plane on port 80.
# shellcheck shell=bash

STEP_DESC["session-isolation"]="isolate browser containers from each other, the tailnet and the cluster (mangle PREROUTING)"
_si_unit() {
  cat <<EOF2
# Managed by node-setup (session-isolation).
[Unit]
Description=Isolate browser session containers from each other and the internal network
Before=docker.service
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/browser-session-isolation ${SESSION_API_ENDPOINT:-${K3S_SERVER_IP}:80}

[Install]
WantedBy=multi-user.target docker.service
EOF2
}
session-isolation::check() {
  systemctl is-active --quiet browser-session-isolation.service \
    && cmp -s "$PAYLOAD_DIR/session-isolation.sh" /usr/local/sbin/browser-session-isolation \
    && cmp -s <(_si_unit) /etc/systemd/system/browser-session-isolation.service \
    && iptables -w -t mangle -C PREROUTING -i docker0 -j BROWSER-SESSION-ISOLATION 2>/dev/null
}
session-isolation::apply() {
  install -m 0755 "$PAYLOAD_DIR/session-isolation.sh" /usr/local/sbin/browser-session-isolation
  _si_unit | write_if_changed /etc/systemd/system/browser-session-isolation.service || true
  systemctl daemon-reload
  systemctl enable browser-session-isolation.service >/dev/null
  systemctl restart browser-session-isolation.service
}
session-isolation::verify() {
  systemctl is-active --quiet browser-session-isolation.service \
    && iptables -w -t mangle -C PREROUTING -i docker0 -j BROWSER-SESSION-ISOLATION 2>/dev/null \
    && [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables)" == "1" ]]
}
