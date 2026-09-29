#!/bin/bash
#
# Unified network setup for browser.lol cluster nodes.
#
# This script does two things:
#   1. Applies P0 sysctl tuning for Tailscale/WireGuard + WebRTC + outbound TLS.
#   2. Sets up Docker-only Tailscale tunneling with exit node auto-failover.
#      (Docker 172.17.0.0/16 routes through Mullvad; k3s, SSH, host traffic
#       use the normal ISP route.)
#
# The k3s-flannel watchdog now lives in flannel-watchdog.sh; keeping it there avoids two
# services racing to restart k3s.
#
# With --direct it applies only the tuning and removes the routing: Docker then
# egresses through the host's own address (the direct-egress module).
#
# Idempotent: safe to re-run.
#
# Rollback:
#   systemctl disable --now docker-tailscale-routing.service
#   rm -f /etc/systemd/system/docker-tailscale-routing.service \
#         /usr/local/bin/docker-tailscale-routing.sh \
#         /etc/sysctl.d/99-net-tuning.conf
#   systemctl daemon-reload && sysctl --system
#
set -euo pipefail

PRIORITY_DOCKER_INTERNAL=5000
PRIORITY_TAILSCALE_PEERS=5050
PRIORITY_BYPASS=5100
DOCKER_NETWORK="172.17.0.0/16"
TAILSCALE_CGNAT="100.64.0.0/10"

ROUTING_SERVICE="docker-tailscale-routing.service"
ROUTING_SERVICE_FILE="/etc/systemd/system/${ROUTING_SERVICE}"
ROUTING_SCRIPT="/usr/local/bin/docker-tailscale-routing.sh"

SYSCTL_FILE="/etc/sysctl.d/99-net-tuning.conf"
MIN_RAM_MB=2048

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [tailscale-exitnode] $*"; }
die() { echo "$(date '+%Y-%m-%d %H:%M:%S') [tailscale-exitnode] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"

MODE="exitnode"
case "${1:-}" in
    "") ;;
    --direct) MODE="direct" ;;
    *) die "usage: exitnode-routing.sh [--direct]" ;;
esac

# 1. SYSCTL TUNING
# Default kernel socket buffers (208 KiB) are too small for Tailscale userspace
# WireGuard under burst; contributed to the tailscaled D-state hang on hjd6.

apply_sysctl() {
    local already_applied=false
    if [[ "$(sysctl -n net.core.rmem_max 2>/dev/null)" == "26214400" ]] &&
       [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] &&
       [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == "fq" ]]; then
        already_applied=true
    fi

    if $already_applied; then
        log "sysctl tuning already applied"
        return 0
    fi

    local ram_mb
    ram_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    (( ram_mb >= MIN_RAM_MB )) || die "host has ${ram_mb} MiB RAM (< ${MIN_RAM_MB})"
    log "sysctl: RAM ${ram_mb} MiB OK"

    modprobe tcp_bbr 2>/dev/null || true
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control \
        || die "kernel has no BBR (need tcp_bbr, kernel >= 4.9)"

    modprobe sch_fq 2>/dev/null || true
    [[ -d /sys/module/sch_fq ]] || die "sch_fq qdisc not available"

    local snapshot=""
    for k in net.core.rmem_max net.core.wmem_max net.core.rmem_default \
             net.core.wmem_default net.core.netdev_max_backlog \
             net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
             net.ipv4.tcp_congestion_control net.core.default_qdisc; do
        snapshot+=$(printf "# %-38s = %s\n" "$k" "$(sysctl -n "$k")")
        snapshot+=$'\n'
    done

    log "sysctl: writing ${SYSCTL_FILE}"
    cat > "${SYSCTL_FILE}" <<EOF
# Applied $(date -u +%Y-%m-%dT%H:%M:%SZ) by exitnode-routing.sh on $(hostname).
# P0 tuning for Tailscale/WireGuard + WebRTC + high outbound TLS.
# Rollback: rm ${SYSCTL_FILE} && sysctl --system
#
# Pre-change values on this host (for reference):
${snapshot}
# UDP/TCP socket buffer ceilings (kernel default 212992 = 208 KiB, too small
# for WireGuard/Tailscale and WebRTC under burst).
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# Per-CPU packet queue depth before kernel accepts from NIC (default 1000).
net.core.netdev_max_backlog = 16384

# TCP auto-tune ceilings (defaults: rx max 6 MiB, tx max 4 MiB).
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# BBR + fq pairing. Reduces retransmits on lossy paths. BBR applies to NEW
# TCP connections only; existing flows keep their current cc until they
# reconnect. fq applies to NEW interfaces only; to change an existing NIC
# live (brief blip): tc qdisc replace dev <iface> root fq
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF

    log "sysctl: applying"
    sysctl -p "${SYSCTL_FILE}" >/dev/null

    local fail=0
    check_sysctl() {
        local k=$1 want got
        want=$(echo "$2" | tr -s '[:space:]' ' ')
        got=$(sysctl -n "$k" | tr -s '[:space:]' ' ')
        if [[ "$got" == "$want" ]]; then
            log "  ok    $k = $got"
        else
            log "  FAIL  $k = $got (wanted $want)"
            fail=1
        fi
    }
    check_sysctl net.core.rmem_max               26214400
    check_sysctl net.core.wmem_max               26214400
    check_sysctl net.core.rmem_default           262144
    check_sysctl net.core.wmem_default           262144
    check_sysctl net.core.netdev_max_backlog     16384
    check_sysctl net.ipv4.tcp_rmem               "4096 262144 16777216"
    check_sysctl net.ipv4.tcp_wmem               "4096 65536 16777216"
    check_sysctl net.ipv4.tcp_congestion_control bbr
    check_sysctl net.core.default_qdisc          fq
    (( fail == 0 )) || die "sysctl values did not apply cleanly"
}

# 2. TAILSCALE ROUTING + EXIT-NODE FAILOVER

reset_routing() {
    log "routing: resetting prior state"
    systemctl stop "${ROUTING_SERVICE}" 2>/dev/null || true
    systemctl disable "${ROUTING_SERVICE}" 2>/dev/null || true
    rm -f "${ROUTING_SERVICE_FILE}" "${ROUTING_SCRIPT}"
    systemctl reset-failed "${ROUTING_SERVICE}" 2>/dev/null || true
    systemctl daemon-reload

    for P in "${PRIORITY_DOCKER_INTERNAL}" "${PRIORITY_TAILSCALE_PEERS}" "${PRIORITY_BYPASS}"; do
        while ip rule del priority "${P}" 2>/dev/null; do :; done
    done
}

apply_routing() {
    log "routing: adding ip rules"
    ip rule add to "${DOCKER_NETWORK}"     lookup main priority "${PRIORITY_DOCKER_INTERNAL}"
    ip rule add to "${TAILSCALE_CGNAT}"    lookup 52   priority "${PRIORITY_TAILSCALE_PEERS}"
    ip rule add not from "${DOCKER_NETWORK}" lookup main priority "${PRIORITY_BYPASS}"

    log "routing: writing ${ROUTING_SCRIPT}"
    cat > "${ROUTING_SCRIPT}" << 'MONITOR_EOF'
#!/bin/bash
# Docker-only Tailscale routing + exit-node health monitor.
#
# Two independent jobs on one resilient loop:
#   1. Every RECONCILE_INTERVAL: re-assert the ip rules + recursion-block iptables
#      rules that steer Docker (172.17/16) traffic through the Mullvad exit node
#      while the host bypasses it. Idempotent; cheap; never blocks.
#   2. Every CHECK_INTERVAL (faster while degraded): verify the exit node both
#      handshakes AND actually forwards to the internet, and fail over / fail open
#      when it does not.
#
# Recursion-block rationale:
#   tailscaled enumerates flannel.1 (10.42.X.0) and cni0 (10.42.X.1) as local
#   endpoints and advertises them via the coordination server. Peers receive
#   these as candidate paths; magicsock may pick them and route tailscale
#   traffic to 10.42.X.X:41641, which the kernel then sends through flannel.1
#   (VXLAN-encapsulated, port 8472) and back over tailscale0 itself. This
#   double-encapsulates every packet, doubles the userspace WireGuard CPU
#   cost, and overflows tailscale0's TX queue (default qlen=500), observed
#   at ~17% packet drop on zap fleet, causing intermittent ClusterIP timeouts
#   and 50-100% loss on ping to remote flannel VTEPs.
#   The three iptables rules below break the recursion: peers' attempts to
#   reach our tailscale via overlay are dropped at flannel.1/cni0 INPUT, and
#   our own outbound tailscale traffic to overlay endpoints gets ICMP
#   port-unreachable so magicsock immediately drops them as candidates.
#
# Robustness notes:
#   - Deliberately NOT `set -e`: a transient failure in any single command (a
#     tailscaled hiccup, a slow curl) must never kill the monitor. Every external
#     call is timeout-bounded and its failure handled locally. systemd restarts
#     us if the process dies anyway.
#   - Exit-node failover is bounded and hysteretic (threshold + post-switch settle
#     grace + switch budget + known-bad avoidance + fail-open + cooldown) so it
#     cannot flap user sessions or spin re-pinning a node that keeps gray-failing.
#   - Degrades gracefully if jq (status parsing) or curl (egress probe) is absent.
set -u

# ---- network constants (data-path critical; do not change casually) ----
PRIORITY_DOCKER_INTERNAL=5000
PRIORITY_TAILSCALE_PEERS=5050
PRIORITY_BYPASS=5100
DOCKER_NETWORK="172.17.0.0/16"
TAILSCALE_CGNAT="100.64.0.0/10"
FLANNEL_NETWORK="10.42.0.0/16"
TAILSCALE_PORT=41641

# ---- tunables ----
RECONCILE_INTERVAL=5          # seconds between ip/iptables reconciliations
CHECK_INTERVAL_NORMAL=60      # seconds between exit-node checks when healthy
CHECK_INTERVAL_BUSY=15        # faster cadence while degraded/switching/settling
EGRESS_FAIL_THRESHOLD=2       # consecutive failed egress probes before acting
MAX_SWITCH_ATTEMPTS=3         # switches without recovery before failing open
COOLDOWN_SECS=300             # stay failed-open this long before re-acquiring
SWITCH_GRACE_SECS=20          # let a freshly-set exit node establish before judging
TS_TIMEOUT=15                 # hard cap on any tailscale CLI call
PROBE_TIMEOUT=6               # per-target curl timeout
PROBE_TARGETS="1.1.1.1 1.0.0.1"   # Cloudflare anycast, distinct /24s, serve HTTP/:80
LOCKFILE="/run/docker-tailscale-routing.lock"

# ---- mutable state (all initialized; required under `set -u`) ----
egress_fail_count=0
switch_attempts=0
bad_nodes=""                  # space-delimited hostnames known-bad this episode
cooldown_until=0              # now() value until which we stay failed-open
grace_until=0                 # now() value until which a fresh node is settling
last_state=""                 # for log-on-change of steady states
last_current_name=""          # for logging exit-node changes
STATUS_JSON=""                # cached `tailscale status --json` for one check
have_jq=1
have_curl=1
manage_exit=1                 # disabled if jq/tailscale missing

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [docker-tailscale] $*"; }

# Log a steady-state only when it changes, to avoid per-cycle spam. Actions
# (switch / fail-open) call log() directly so they are always recorded.
log_state() {
    local st="$1" msg="$2"
    if [ "$st" != "$last_state" ]; then
        log "[$st] $msg"
        last_state="$st"
    fi
}

# Monotonic-ish clock. Wrapped so tests can drive time deterministically.
now() { echo "$SECONDS"; }

# ---- data-path reconciliation (never aborts the loop) ----
ensure_rule() {
    local priority="$1"; shift
    if ! ip rule show priority "${priority}" 2>/dev/null | grep -q .; then
        log "Restoring: ip rule add $* priority ${priority}"
        ip rule add "$@" priority "${priority}" 2>/dev/null || log "ip rule add failed (priority ${priority}); will retry"
    fi
}

ensure_iptables_rule() {
    local chain=$1; shift
    if ! iptables -C "${chain}" "$@" 2>/dev/null; then
        log "Restoring: iptables -I ${chain} $*"
        iptables -I "${chain}" "$@" 2>/dev/null || log "iptables -I ${chain} failed; will retry"
    fi
}

reconcile_rules() {
    ensure_rule "${PRIORITY_DOCKER_INTERNAL}" to "${DOCKER_NETWORK}"       lookup main
    ensure_rule "${PRIORITY_TAILSCALE_PEERS}" to "${TAILSCALE_CGNAT}"      lookup 52
    ensure_rule "${PRIORITY_BYPASS}"          not from "${DOCKER_NETWORK}" lookup main

    # Tailscale-over-flannel recursion guard. Three rules: stop sending UDP/41641
    # to overlay IPs (REJECT so magicsock learns the path is dead immediately),
    # and silently drop incoming UDP/41641 on flannel.1 / cni0 (these would only
    # arrive as a result of a peer's broken recursive path).
    ensure_iptables_rule OUTPUT -d "${FLANNEL_NETWORK}" -p udp --dport "${TAILSCALE_PORT}" -j REJECT --reject-with icmp-port-unreachable -m comment --comment "block tailscale recursion via flannel"
    ensure_iptables_rule INPUT  -i flannel.1 -p udp --dport "${TAILSCALE_PORT}" -j DROP -m comment --comment "block tailscale recursion via flannel"
    ensure_iptables_rule INPUT  -i cni0      -p udp --dport "${TAILSCALE_PORT}" -j DROP -m comment --comment "block tailscale recursion via cni0"
}

# ---- known-bad-node set (avoid re-pinning a node that keeps failing) ----
mark_bad()  { case " ${bad_nodes} " in *" $1 "*) ;; *) bad_nodes="${bad_nodes} $1" ;; esac; }
is_bad()    { case " ${bad_nodes} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
clear_bad() { bad_nodes=""; }

# Accept only a plausible exit-node hostname: non-empty, no whitespace, a dot,
# and a conservative charset. Rejects parse garbage so we never `tailscale set`
# something nonsensical.
valid_node_name() {
    local n="$1"
    [ -n "$n" ] || return 1
    case "$n" in *[!a-zA-Z0-9._-]*) return 1 ;; esac
    case "$n" in *.*) return 0 ;; *) return 1 ;; esac
}

# ---- tailscale / probe wrappers (overridable in tests) ----
read_status() { STATUS_JSON=$(timeout "$TS_TIMEOUT" tailscale status --json 2>/dev/null) || STATUS_JSON=""; }
status_ok()   { [ -n "$STATUS_JSON" ]; }

ts_online() {
    # "true" or "false" (defaults to false when ExitNodeStatus is absent).
    printf '%s' "$STATUS_JSON" | jq -r '.ExitNodeStatus.Online // false' 2>/dev/null || echo "false"
}

ts_current_name() {
    # FQDN (trailing dot stripped) of the exit node in use, or "" if none. We use
    # .DNSName, not .HostName, so this matches the format get_suggestion returns
    # and the known-bad set compares like-for-like (else suggest returning the
    # FQDN of the node we are already on would slip past is_bad and get re-pinned).
    printf '%s' "$STATUS_JSON" \
        | jq -r 'first((.Peer // {})[] | select(.ExitNode == true) | (.DNSName // .HostName)) // empty' 2>/dev/null \
        | sed -e 's/[[:space:].]*$//' | head -n1
}

suggest_raw() { timeout "$TS_TIMEOUT" tailscale exit-node suggest 2>/dev/null || true; }

get_suggestion() {
    local name
    name=$(suggest_raw | grep -F -- '--exit-node=' | head -n1 \
           | sed -e 's/.*--exit-node=\([^`]*\)`.*/\1/' -e 's/[[:space:].]*$//' -e 's/^[[:space:]]*//')
    if valid_node_name "$name"; then printf '%s' "$name"; else printf ''; fi
}

# $1 = exit-node hostname, or "" to clear. Returns the tailscale exit code.
ts_set_exit() { timeout "$TS_TIMEOUT" tailscale set --exit-node="$1"; }

docker0_ip() { ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }

# Probe real internet egress THROUGH the exit node, exactly as a VM would: a
# curl sourced from docker0 misses the PRIORITY_BYPASS rule and falls through to
# table 52 (default dev tailscale0 = exit node). Raw anycast IPs keep it DNS-free.
# Returns healthy (0) when curl or docker0 is absent (nothing to fail over for).
egress_ok() {
    [ "$have_curl" = 1 ] || return 0
    local src; src=$(docker0_ip)
    [ -n "$src" ] || return 0
    local tgt
    for tgt in $PROBE_TARGETS; do
        if timeout "$((PROBE_TIMEOUT + 2))" curl -sS --interface "$src" \
                --connect-timeout "$PROBE_TIMEOUT" --max-time "$PROBE_TIMEOUT" \
                -o /dev/null "http://$tgt" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ---- failover state machine ----
in_cooldown() { [ "$cooldown_until" -gt 0 ] && [ "$(now)" -lt "$cooldown_until" ]; }

settling()    { [ "$grace_until" -gt 0 ] && [ "$(now)" -lt "$grace_until" ]; }

become_healthy() {
    local via="$1"
    if [ "$egress_fail_count" -ne 0 ] || [ "$switch_attempts" -ne 0 ] || [ -n "$bad_nodes" ] || [ "$cooldown_until" -ne 0 ]; then
        log "recovered: egress healthy via ${via:-?}; clearing failure state"
    fi
    egress_fail_count=0
    switch_attempts=0
    grace_until=0
    cooldown_until=0
    clear_bad
    log_state healthy "egress OK via ${via:-?}"
}

fail_open() {
    local reason="$1"
    # Loud announcement only on the transition INTO fail-open. A node permanently
    # without a usable exit node (e.g. no Mullvad nodes shared with it) re-enters
    # here every cooldown; stay quiet then so journald is not spammed.
    if [ "$last_state" != "failed_open" ]; then
        log "FAIL-OPEN: clearing exit node so Docker falls back to the host route (online but deanonymized). Reason: ${reason}. Cooldown ${COOLDOWN_SECS}s."
    fi
    ts_set_exit "" >/dev/null 2>&1 || log "warning: 'tailscale set --exit-node=' failed; will retry"
    egress_fail_count=0
    switch_attempts=0
    grace_until=0
    cooldown_until=$(( $(now) + COOLDOWN_SECS ))
    last_state="failed_open"
}

# Acquire (or re-acquire) a working exit node, with all the guardrails.
acquire() {
    local reason="$1"

    if in_cooldown; then
        log_state failed_open "no usable exit node; VMs on host route (cooldown $(( cooldown_until - $(now) ))s)"
        return
    fi
    # Cooldown just expired: start a fresh episode, give every node another chance.
    # No log here; the resulting switch or fail_open reports the outcome.
    if [ "$cooldown_until" -gt 0 ]; then
        cooldown_until=0
        switch_attempts=0
        clear_bad
    fi

    if [ "$switch_attempts" -ge "$MAX_SWITCH_ATTEMPTS" ]; then
        fail_open "switch budget exhausted after ${switch_attempts} attempts (${reason})"
        return
    fi

    local sug; sug=$(get_suggestion)
    if [ -z "$sug" ]; then
        fail_open "no exit-node suggestion available (${reason})"
        return
    fi
    if is_bad "$sug"; then
        fail_open "only suggestion (${sug}) is already known-bad this episode (${reason})"
        return
    fi

    log "${reason} -> switching to ${sug} (attempt $((switch_attempts + 1))/${MAX_SWITCH_ATTEMPTS})"
    if ts_set_exit "$sug" >/dev/null 2>&1; then
        switch_attempts=$(( switch_attempts + 1 ))
        egress_fail_count=0
        grace_until=$(( $(now) + SWITCH_GRACE_SECS ))
        log_state switching "set exit node to ${sug}; settling before re-check"
    else
        log "tailscale set --exit-node=${sug} failed; will retry next cycle"
    fi
}

# One health evaluation. Reads status once, then drives the state machine.
manage_exit_node() {
    # A freshly-set node needs a moment to handshake; don't judge it yet.
    if settling; then
        log_state settling "new exit node establishing ($(( grace_until - $(now) ))s)"
        return
    fi

    read_status
    if ! status_ok; then
        # tailscaled busy/restarting: defer rather than thrash the exit node.
        log_state unknown "tailscale status unavailable; deferring exit-node action"
        return
    fi

    local online current
    online=$(ts_online)
    current=$(ts_current_name)

    if [ "$current" != "$last_current_name" ]; then
        [ -n "$current" ] && log "active exit node is now ${current}"
        last_current_name="$current"
    fi

    if [ "$online" = "true" ]; then
        if egress_ok; then
            become_healthy "$current"
            return
        fi
        egress_fail_count=$(( egress_fail_count + 1 ))
        if [ "$egress_fail_count" -lt "$EGRESS_FAIL_THRESHOLD" ]; then
            log_state degraded "exit node ${current:-?} Online but egress failed (${egress_fail_count}/${EGRESS_FAIL_THRESHOLD})"
            return
        fi
        log "exit node ${current:-?} Online but egress dead ${egress_fail_count}x (gray failure)"
        [ -n "$current" ] && mark_bad "$current"
        acquire "gray failure on ${current:-?}"
        return
    fi

    # online == false: offline, or no exit node set (incl. our own fail-open).
    [ -n "$current" ] && mark_bad "$current"
    acquire "exit node ${current:-<none>} offline/unset"
}

# How long until the next exit-node check, given current state.
compute_interval() {
    if in_cooldown; then
        echo "$CHECK_INTERVAL_NORMAL"
    elif [ "$egress_fail_count" -gt 0 ] || [ "$switch_attempts" -gt 0 ] || settling; then
        echo "$CHECK_INTERVAL_BUSY"
    else
        echo "$CHECK_INTERVAL_NORMAL"
    fi
}

main() {
    # Single instance only: a second copy must not fight over the exit node.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCKFILE" 2>/dev/null || exec 9>"/tmp/$(basename "$LOCKFILE")"
        if ! flock -n 9; then
            log "another instance holds ${LOCKFILE}; exiting"
            exit 0
        fi
    fi

    command -v jq        >/dev/null 2>&1 || have_jq=0
    command -v curl      >/dev/null 2>&1 || have_curl=0
    command -v tailscale >/dev/null 2>&1 || { log "WARNING: tailscale not found; exit-node management disabled"; manage_exit=0; }
    [ "$have_jq" = 1 ]   || { log "WARNING: jq not found; exit-node management disabled (ip-rule reconciliation continues)"; manage_exit=0; }
    [ "$have_curl" = 1 ] || log "WARNING: curl not found; gray-failure detection disabled (offline detection + fail-open still active)"

    log "Monitor started (pid $$): reconcile every ${RECONCILE_INTERVAL}s; exit-node check ${CHECK_INTERVAL_NORMAL}s (->${CHECK_INTERVAL_BUSY}s while degraded); manage_exit=${manage_exit}"

    local next_check_at=$(( $(now) + 10 ))   # first check shortly after start
    while true; do
        reconcile_rules
        if [ "$manage_exit" = 1 ] && [ "$(now)" -ge "$next_check_at" ]; then
            manage_exit_node
            next_check_at=$(( $(now) + $(compute_interval) ))
        fi
        sleep "$RECONCILE_INTERVAL"
    done
}

# Run only when executed directly; sourcing (DTR_TEST=1) loads functions for tests.
[ "${DTR_TEST:-0}" = 1 ] || main "$@"
MONITOR_EOF
    chmod +x "${ROUTING_SCRIPT}"

    log "routing: writing ${ROUTING_SERVICE_FILE}"
    cat > "${ROUTING_SERVICE_FILE}" << EOF
[Unit]
Description=Docker Tailscale Routing - Docker-only tunneling + exit node auto-failover
After=network.target tailscaled.service docker.service
Wants=tailscaled.service
# Never rate-limit restarts: the monitor must always come back, even under a
# fast crash loop, so the data-path rules and exit-node failover are never left
# unattended.
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStart=${ROUTING_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${ROUTING_SERVICE}"
    systemctl restart "${ROUTING_SERVICE}"
}

# ENTRYPOINT

apply_sysctl
reset_routing

if [[ "${MODE}" == "direct" ]]; then
    tailscale set --exit-node= 2>/dev/null || true
    log "direct egress: Docker leaves through the host's own address"
    log "SUCCESS"
    exit 0
fi

apply_routing

# VERIFY

sleep 2
for unit in "${ROUTING_SERVICE}"; do
    if systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
        status=$(systemctl is-active "${unit}" 2>/dev/null || true)
        if [[ "${status}" != "active" ]]; then
            log "ERROR: ${unit} is '${status}'"
            journalctl -u "${unit}" --no-pager -n 20
            exit 1
        fi
        log "OK: ${unit} active"
    fi
done

log ""
log "ip rules:"
ip rule show | head -15
log ""
log "Verify Mullvad routing:"
log "  docker run --rm curlimages/curl -s ifconfig.me   # Mullvad IP"
log "  curl -s ifconfig.me                              # real server IP"
log "  kubectl exec <pod> -- curl -s ifconfig.me        # real server IP"
log ""
log "Status:"
log "  systemctl status ${ROUTING_SERVICE}"
log "  journalctl -u ${ROUTING_SERVICE} -f"
log ""
log "SUCCESS"
