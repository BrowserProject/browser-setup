# tailscale.sh - install + join the tailnet. The overlay network everything
# else (k3s, DB access, SSH) rides on, so it comes right after base.
# shellcheck shell=bash

STEP_DESC["tailscale-install"]="install tailscale from pkgs.tailscale.com and hold the package"
tailscale-install::check() {
  command -v tailscale >/dev/null && apt-mark showhold 2>/dev/null | grep -qx tailscale
}
tailscale-install::apply() {
  if ! command -v tailscale >/dev/null; then
    local codename distro
    codename="$(lsb_release -cs)"
    # tailscale serves separate apt repos per distro: /stable/ubuntu/<codename>
    # and /stable/debian/<codename>. Using the wrong one 404s (e.g. Debian
    # bookworm under the ubuntu path), so derive the distro from os-release.
    # This makes node-setup work on Ubuntu workers AND Debian (Hetzner debian-12).
    distro="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
    case "$distro" in ubuntu|debian) ;; *) distro="ubuntu" ;; esac
    curl -fsSL "https://pkgs.tailscale.com/stable/${distro}/${codename}.noarmor.gpg" \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${distro} ${codename} main" \
      > /etc/apt/sources.list.d/tailscale.list
    apt-get update
    if [[ -n "${TAILSCALE_VERSION:-}" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y "tailscale=${TAILSCALE_VERSION}"
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
    fi
  fi
  # An unattended tailscale upgrade restarts tailscaled, which tears down
  # tailscale0 and wedges flannel (the watchdog exists for exactly this).
  # Upgrades to tailscale are deliberate: unhold, upgrade, re-hold.
  apt-mark hold tailscale >/dev/null
}
tailscale-install::verify() {
  command -v tailscale >/dev/null
}

STEP_DESC["tailscale-up"]="join the tailnet (prompts for an auth key) and disable auto-update"
STEP_PHASE["tailscale-up"]=boot
tailscale-up::check() {
  [[ "$(tailscale status --json 2>/dev/null | jq -r .BackendState 2>/dev/null)" == "Running" ]]
}
tailscale-up::apply() {
  svc_enable_now tailscaled
  # Auth keys expire and never live in git or the secrets file at rest; the
  # operator passes one per provisioning run (provision.sh --tailscale-key, or
  # an interactive prompt). Generate at:
  #   https://login.tailscale.com/admin/settings/keys
  require_secrets TS_AUTHKEY
  tailscale up --authkey "${TS_AUTHKEY}" --hostname "$(hostname)" \
    --accept-dns=false
  tailscale set --auto-update=false || true
}
tailscale-up::verify() {
  local ip
  ip="$(ts_ip)"
  [[ -n "$ip" ]] || return 1
  log "tailscale IP: $ip"
}

# alt-tailscale-port module: ZAP-Hosting's DDoS filter drops WireGuard
# handshake replies and data on UDP 41641 (disco still passes, so tailscale
# never falls back to DERP and the node silently loses the control plane).
# Other ports pass. Peers learn the new port through the coordination server.
# Mirrored in payloads/exitnode-routing.sh (recursion guard). Keep in sync.
TAILSCALE_ALT_PORT=41700

_tailscale_alt_port_ok() {
  grep -qx "PORT=\"${TAILSCALE_ALT_PORT}\"" /etc/default/tailscaled 2>/dev/null \
    && ss -Hlun "sport = :${TAILSCALE_ALT_PORT}" 2>/dev/null | grep -q .
}
STEP_DESC["tailscale-alt-port"]="tailscaled listens on UDP ${TAILSCALE_ALT_PORT} instead of 41641 (provider filters 41641)"
tailscale-alt-port::check() {
  _tailscale_alt_port_ok
}
tailscale-alt-port::apply() {
  [[ -f /etc/default/tailscaled ]] || die "/etc/default/tailscaled missing; is tailscale installed?"
  if grep -q '^PORT=' /etc/default/tailscaled; then
    sed -i -E "s/^PORT=.*/PORT=\"${TAILSCALE_ALT_PORT}\"/" /etc/default/tailscaled
  else
    echo "PORT=\"${TAILSCALE_ALT_PORT}\"" >> /etc/default/tailscaled
  fi
  # The restart tears down tailscale0 for a few seconds; the flannel watchdog
  # recovers k3s on a joined node.
  systemctl restart tailscaled
  local i
  for i in $(seq 1 30); do
    _tailscale_alt_port_ok && return 0
    sleep 1
  done
}
tailscale-alt-port::verify() {
  _tailscale_alt_port_ok
}
