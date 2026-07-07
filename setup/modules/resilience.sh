# resilience.sh - node-down insurance beyond the flannel watchdog: OOM-kill
# protection for critical daemons, kernel table limits, hardware watchdog,
# and a disk-space guard. Every step is safe on every role (each part checks
# what actually exists on the node).
# shellcheck shell=bash

# --- OOM protection -------------------------------------------------------------
# Under memory pressure (browser workspaces are the biggest consumer in this
# fleet) the kernel OOM killer must sacrifice workspaces, never the daemons
# whose death takes the node off the cluster. tailscaled is covered by the
# flannel-watchdog payload; this protects the rest.
_OOM_UNITS=(k3s k3s-agent docker containerd ssh postgresql@)

STEP_DESC["oom-guards"]="OOMScoreAdjust=-900 for critical daemons (workspaces die first, never the node)"
oom-guards::apply() {
  local u changed=0
  for u in "${_OOM_UNITS[@]}"; do
    systemctl cat "${u}.service" >/dev/null 2>&1 || continue
    mkdir -p "/etc/systemd/system/${u}.service.d"
    # heredoc on a simple command, not `if cmd <<EOF; then` (declare -f in the
    # step runner cannot re-serialize that construct; see lib/framework.sh)
    write_if_changed "/etc/systemd/system/${u}.service.d/90-oom.conf" <<'EOF' && changed=1
# Managed by node-setup (oom-guards): under memory pressure the OOM killer
# must take browser workspaces, never this daemon.
[Service]
OOMScoreAdjust=-900
EOF
  done
  [[ "$changed" == "1" ]] && systemctl daemon-reload

  # Drop-ins apply on the next unit start; also protect the currently running
  # processes so the node is safe immediately, without restarting anything.
  local pid
  for u in "${_OOM_UNITS[@]}"; do
    [[ "$u" == *@ ]] && continue   # template units: instances covered below
    pid="$(systemctl show -p MainPID --value "${u}.service" 2>/dev/null || echo 0)"
    if [[ "$pid" -gt 0 && -w "/proc/$pid/oom_score_adj" ]]; then
      echo -900 > "/proc/$pid/oom_score_adj" 2>/dev/null || true
    fi
  done
  # postgres instances (postgresql@17-main etc.)
  local inst
  for inst in $(systemctl list-units --plain --no-legend 'postgresql@*' 2>/dev/null | awk '{print $1}'); do
    pid="$(systemctl show -p MainPID --value "$inst" 2>/dev/null || echo 0)"
    if [[ "$pid" -gt 0 && -w "/proc/$pid/oom_score_adj" ]]; then
      echo -900 > "/proc/$pid/oom_score_adj" 2>/dev/null || true
    fi
  done
  return 0
}
oom-guards::verify() {
  # at least one guarded unit must exist and carry the drop-in
  local u
  for u in "${_OOM_UNITS[@]}"; do
    if systemctl cat "${u}.service" >/dev/null 2>&1; then
      [[ -f "/etc/systemd/system/${u}.service.d/90-oom.conf" ]] || return 1
    fi
  done
}

# --- kernel table limits -----------------------------------------------------------
# A full conntrack table silently drops NEW connections (looks exactly like
# "network down"); a full ARP/neighbour table breaks tailnet + container
# traffic on busy nodes. Raise both well above what the fleet can generate.
STEP_DESC["net-limits"]="raise conntrack + neighbour table limits (full tables look like a dead network)"
net-limits::apply() {
  # ufw already loads nf_conntrack; make sure it is present so sysctl applies
  modprobe nf_conntrack 2>/dev/null || true
  write_if_changed /etc/sysctl.d/91-node-setup-limits.conf <<'EOF' || true
# Managed by node-setup (net-limits).
# Browser workspaces open thousands of concurrent connections; the kernel
# default conntrack ceiling silently drops new connections when reached.
net.netfilter.nf_conntrack_max = 1048576
# Evict established-but-idle entries sooner than the 5-day default so the
# table cannot be filled by leaked long-lived entries.
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
# Neighbour (ARP/NDP) table: tailnet peers + flannel + hundreds of container
# veths outgrow the 1024-entry default; overflow breaks pod networking.
net.ipv4.neigh.default.gc_thresh1 = 2048
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
EOF
  # -e: ignore keys unavailable on this kernel instead of failing the step
  sysctl -e -p /etc/sysctl.d/91-node-setup-limits.conf >/dev/null
}
net-limits::verify() {
  [[ "$(sysctl -n net.ipv4.neigh.default.gc_thresh3 2>/dev/null)" == "8192" ]]
}

# --- hardware watchdog ---------------------------------------------------------------
# A hard kernel hang otherwise leaves the node down until someone notices.
# With a watchdog device, systemd pets /dev/watchdog and the board reboots the
# box if PID1 stops responding. Best-effort: many VPSes expose no device.
STEP_DESC["hw-watchdog"]="hardware watchdog via systemd (auto-reboot on hard kernel hang; skipped if no device)"
hw-watchdog::check() {
  [[ ! -e /dev/watchdog ]] || [[ -f /etc/systemd/system.conf.d/90-node-setup-watchdog.conf ]]
}
hw-watchdog::apply() {
  if [[ ! -e /dev/watchdog ]]; then
    warn "no /dev/watchdog on this host; skipping hardware watchdog (nothing to configure)"
    return 0
  fi
  mkdir -p /etc/systemd/system.conf.d
  # heredoc on a simple command, not `if cmd <<EOF; then` (declare -f in the
  # step runner cannot re-serialize that construct; see lib/framework.sh)
  local rc=0
  write_if_changed /etc/systemd/system.conf.d/90-node-setup-watchdog.conf <<'EOF' || rc=$?
# Managed by node-setup (hw-watchdog): reboot on hard hang instead of staying
# down. systemd pets the watchdog every RuntimeWatchdogSec/2.
[Manager]
RuntimeWatchdogSec=30
RebootWatchdogSec=10min
EOF
  [[ "$rc" -eq 0 ]] && systemctl daemon-reexec
  return 0
}
hw-watchdog::verify() {
  [[ ! -e /dev/watchdog ]] && return 0
  [[ "$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null)" == "30s" ]]
}

# --- disk guard --------------------------------------------------------------------
# A full root filesystem takes everything down at once (k3s, docker, journald,
# even SSH logins). journald and docker logs are already capped; this timer is
# the backstop that reclaims safe space before the cliff and screams in the
# journal when it cannot.
STEP_DESC["disk-guard"]="hourly disk-space guard (prune safe caches above 85%, log loudly above 95%)"
disk-guard::apply() {
  write_if_changed /usr/local/bin/disk-guard.sh 0755 <<'EOF' || true
#!/bin/bash
# Managed by node-setup (disk-guard). Runs from disk-guard.timer.
set -u
THRESHOLD=85
CRITICAL=95

usage() { df --output=pcent / | tail -1 | tr -dc '0-9'; }

use=$(usage)
[ "$use" -lt "$THRESHOLD" ] && exit 0
logger -t disk-guard "root filesystem at ${use}%; reclaiming safe space"

# journal down to 300M (already capped at 500M; this trims further under pressure)
journalctl --vacuum-size=300M >/dev/null 2>&1

# apt caches are always safe to drop
apt-get clean >/dev/null 2>&1

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # browser workspaces are ephemeral: exited containers older than 1h are
  # garbage, dangling layers likewise. Never touches running workspaces or
  # tagged images (the edge agent re-pulls those on demand anyway).
  docker container prune -f --filter "until=1h" >/dev/null 2>&1
  docker image prune -f >/dev/null 2>&1
  docker builder prune -f >/dev/null 2>&1
fi

after=$(usage)
logger -t disk-guard "done: ${use}% -> ${after}%"
if [ "$after" -ge "$CRITICAL" ]; then
  logger -p user.err -t disk-guard "CRITICAL: root filesystem still at ${after}% after pruning; manual cleanup needed NOW or the node will fail"
fi
exit 0
EOF
  write_if_changed /etc/systemd/system/disk-guard.service <<'EOF' || true
# Managed by node-setup (disk-guard).
[Unit]
Description=Disk-space guard - reclaim safe space before the disk fills

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk-guard.sh
EOF
  write_if_changed /etc/systemd/system/disk-guard.timer <<'EOF' || true
# Managed by node-setup (disk-guard).
[Unit]
Description=Hourly disk-space guard

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
  svc_enable_now disk-guard.timer
}
disk-guard::verify() {
  systemctl is-active --quiet disk-guard.timer && [[ -x /usr/local/bin/disk-guard.sh ]]
}
