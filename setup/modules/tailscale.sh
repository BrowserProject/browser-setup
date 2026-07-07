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
    --accept-dns=false --auto-update=false
  tailscale set --auto-update=false || true
}
tailscale-up::verify() {
  local ip
  ip="$(ts_ip)"
  [[ -n "$ip" ]] || return 1
  log "tailscale IP: $ip"
}
