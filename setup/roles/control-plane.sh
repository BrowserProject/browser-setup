# role: control-plane - the single k3s server (API1 on prod). Also applies the
# cluster-level objects: registry pull secret, services manifest, CoreDNS
# DaemonSet swap (prod). Exposes nothing publicly; the API (6443) is reachable
# over the tailnet only.
# shellcheck shell=bash

UFW_PUBLIC_TCP=("${CONTROL_PLANE_PUBLIC_TCP[@]}")
UFW_PUBLIC_UDP=("${CONTROL_PLANE_PUBLIC_UDP[@]}")

ROLE_STEPS=(
  base-packages
  base-time
  base-journald
  base-unattended
  base-ssh-harden
  swap-disable
  tailscale-install
  tailscale-up
  ufw-rules
)

if [[ "${K3S_DATASTORE:-sqlite}" == "sqlite" ]]; then
  ROLE_STEPS+=(k3s-sqlite-init)
fi

ROLE_STEPS+=(k3s-server-install)

if [[ "${K3S_DATASTORE:-sqlite}" == "sqlite" ]]; then
  ROLE_STEPS+=(k3s-vacuum-timer)
fi

ROLE_STEPS+=(
  flannel-watchdog
  oom-guards
  net-limits
  hw-watchdog
  disk-guard
  k3s-registry-secret
  k3s-services
)

if [[ "${COREDNS_DAEMONSET:-0}" == "1" ]]; then
  ROLE_STEPS+=(k3s-coredns)
fi
