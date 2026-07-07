# ufw.sh - host firewall. Desired rules come from the role (UFW_PUBLIC_TCP/UDP)
# and the cluster (UFW_TRUSTED_SOURCES). Default deny incoming.
#
# Lockout guard: if this SSH session came from an IP that would not be allowed
# by the new ruleset, an explicit allow for that IP:22 is added first, so
# enabling the firewall can never cut the connection provisioning runs over.
# shellcheck shell=bash

STEP_DESC["ufw-rules"]="apply role firewall rules (default deny incoming) with SSH lockout guard"

_ufw_current_ssh_client() {
  # SSH_CONNECTION="client_ip client_port server_ip server_port" survives sudo -E;
  # fall back to who am i parsing. Empty when run from a local console.
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "${SSH_CONNECTION%% *}"
  else
    who am i 2>/dev/null | grep -oE '\(([0-9a-fA-F:.]+)\)' | tr -d '()' | head -n1
  fi
}

_ufw_ip_in_sources() { # ip, then source CIDRs; pure-bash IPv4 prefix match
  local ip="$1"; shift
  local src net bits ipn netn
  _ip2n() { local IFS=. a b c d; read -r a b c d <<< "$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  ipn=$(_ip2n "$ip")
  for src in "$@"; do
    net="${src%/*}"; bits="${src#*/}"
    [[ "$bits" == "$src" ]] && bits=32
    netn=$(_ip2n "$net")
    if (( bits == 0 )) || (( (ipn >> (32 - bits)) == (netn >> (32 - bits)) )); then
      return 0
    fi
  done
  return 1
}

ufw-rules::apply() {
  ensure_pkgs ufw

  # 1. lockout guard for the live SSH session
  local client
  client="$(_ufw_current_ssh_client)"
  if [[ -n "$client" ]] && ! _ufw_ip_in_sources "$client" "${UFW_TRUSTED_SOURCES[@]}"; then
    warn "current SSH client $client is outside the trusted sources; pinning an allow rule for it (remove later with: ufw delete allow from $client to any port 22)"
    ufw allow from "$client" to any port 22 proto tcp comment 'node-setup: provisioning ssh guard' >/dev/null
  fi

  # 2. overlay + trusted sources
  ufw allow in on tailscale0 comment 'tailnet' >/dev/null
  ufw allow in on flannel.1 comment 'k3s overlay' >/dev/null 2>&1 || true
  local src
  for src in "${UFW_TRUSTED_SOURCES[@]}"; do
    ufw allow from "$src" comment 'trusted source' >/dev/null
  done

  # 3. public service ports for this role
  local p
  for p in "${UFW_PUBLIC_TCP[@]}"; do
    ufw allow "$p/tcp" >/dev/null
  done
  for p in "${UFW_PUBLIC_UDP[@]}"; do
    ufw allow "$p/udp" >/dev/null
  done

  # 4. defaults + enable
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
}

ufw-rules::verify() {
  ufw status | grep -q "Status: active"
}
