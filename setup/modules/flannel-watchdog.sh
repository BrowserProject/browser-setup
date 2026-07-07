# flannel-watchdog.sh - harden k3s+tailscale against the "flannel stuck after
# tailscaled restart" failure and every adjacent tailscaled failure mode
# (wedged daemon, missing interface, gray offline, key expiry warning, boot
# race, OOM kill). The battle-tested implementation lives in
# payloads/flannel-watchdog.sh (formerly wiki/k8s-manifests/fix.sh); this step
# just runs it. It is idempotent and safe on both servers and agents.
# shellcheck shell=bash

_fw_has_k3s() {
  systemctl cat k3s.service >/dev/null 2>&1 || systemctl cat k3s-agent.service >/dev/null 2>&1
}

STEP_DESC["flannel-watchdog"]="tailscale/k3s data-path hardening: watchdog, boot ordering, restart coupling, apt hold"
flannel-watchdog::check() {
  systemctl is-active --quiet k3s-flannel-watchdog.service \
    && [[ -f /etc/systemd/system/tailscaled.service.d/10-node-setup.conf ]] \
    && { ! _fw_has_k3s \
      || { [[ -x /usr/local/bin/k3s-wait-tailscale.sh ]] \
        && { [[ -f /etc/systemd/system/k3s-agent.service.d/10-tailscale.conf ]] \
          || [[ -f /etc/systemd/system/k3s.service.d/10-tailscale.conf ]]; }; }; }
}
flannel-watchdog::apply() {
  # never let the payload's immediate-heal restart k3s mid-provisioning run;
  # on a broken node the running watchdog heals it within ~2 minutes anyway
  FIX_NO_HEAL="${FIX_NO_HEAL:-0}" bash "$PAYLOAD_DIR/flannel-watchdog.sh"
}
flannel-watchdog::verify() {
  systemctl is-active --quiet k3s-flannel-watchdog.service
}
