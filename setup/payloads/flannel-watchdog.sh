#!/usr/bin/env bash
#
# flannel-watchdog.sh (formerly wiki fix.sh) - keep the tailscale0 / flannel
# data path of a k3s node alive through every known failure mode.
#
# BACKGROUND
#   This cluster runs flannel VXLAN bound to the Tailscale interface
#   (k3s is started with --flannel-iface tailscale0). When tailscaled
#   restarts, e.g. a package upgrade or a crash, the tailscale0 interface is
#   destroyed and recreated. The long-running k3s process's embedded flannel
#   deletes flannel.1 but then fails to re-attach, looping forever:
#
#       vxlan_network.go:167] external interface  not found, retrying in 30s
#
#   k3s itself never restarts, so the node loses ALL cross-node pod
#   networking until k3s is restarted. Separately, tailscaled itself can hang
#   in D-state (observed on hjd6), be OOM-killed, or drop off the tailnet with
#   an expired node key - all of which take the node down the same way.
#
# WHAT THIS SCRIPT INSTALLS (idempotent, safe to re-run)
#   Layer 0  boot ordering: an ExecStartPre drop-in makes k3s wait (up to
#            180s) for tailscale0 to exist with an IP before starting, so a
#            reboot can never race k3s ahead of the tailnet.
#   Layer 1  systemd drop-in so k3s is restarted automatically whenever
#            tailscaled is *explicitly* restarted (PartOf=tailscaled.service),
#            e.g. by an apt postinst. NOTE: systemd does NOT propagate
#            auto-restarts to PartOf units; Layer 4 covers that case.
#   Layer 2  hardens tailscaled itself: Restart=always (stock unit is only
#            on-failure, so a clean exit stays down), no restart rate-limit,
#            and OOMScoreAdjust=-900 so the kernel OOM killer takes browser
#            workspaces before it ever takes the tailnet.
#   Layer 3  pins the `tailscale` apt package and disables Tailscale's
#            built-in auto-update, so restarts only happen during planned
#            maintenance instead of at random.
#   Layer 4  a polling watchdog daemon (k3s-flannel-watchdog.service) that
#            detects and heals, rate-limited per target:
#              a) flannel stuck (tailscale0 up + flannel.1 missing + the
#                 recreate-loop log line)           -> restart k3s
#              b) tailscaled wedged (status socket unresponsive), tailscale0
#                 gone, or logged-in-but-offline    -> restart tailscaled
#                 (Layer 1 then restarts k3s with it)
#            plus a daily node-key-expiry check that logs loudly when the key
#            expires within 30 days (an expired key silently drops the node
#            off the tailnet; disable expiry per-machine in the admin console).
#   Heal     if the node is CURRENTLY in the broken state, restart k3s once
#            to recover immediately.
#
# USAGE
#   sudo ./flannel-watchdog.sh                 # apply all layers (+ heal if broken)
#   sudo FIX_NO_HEAL=1 ./flannel-watchdog.sh   # apply, never restart k3s now
#   sudo FIX_FORCE_HEAL=1 ./flannel-watchdog.sh# force a k3s restart even if ok
#
set -euo pipefail

log()  { printf '\033[0;34m[fix ]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[err ]\033[0m %s\n' "$*" >&2; }

# preconditions
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "must run as root (try: sudo $0)"; exit 1
fi

K3S_UNIT=""
for u in k3s.service k3s-agent.service; do
  if systemctl cat "$u" >/dev/null 2>&1; then K3S_UNIT="$u"; break; fi
done
if [[ -z "$K3S_UNIT" ]]; then
  # tailscaled-only mode (e.g. the DB node): no flannel layers, but tailscaled
  # hardening + the tailscaled half of the watchdog still apply - a dead
  # tailnet takes a non-k3s node down just the same.
  K3S_UNIT="none"
  warn "no k3s unit found - installing tailscaled-only protection"
else
  log "k3s unit: $K3S_UNIT"
fi

HAVE_TS=0
if systemctl cat tailscaled.service >/dev/null 2>&1; then
  HAVE_TS=1
else
  warn "tailscaled.service not found - skipping Tailscale-specific steps"
fi

# Helper: write file only if content differs. Returns 0 if changed.
write_if_changed() {  # $1=path  (content on stdin)
  local path="$1" tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
  install -D -m 0644 "$tmp" "$path"; rm -f "$tmp"; return 0
}

reload_needed=0

# Layer 0: k3s waits for tailscale0 before starting (closes the boot race)
WAIT_SCRIPT="/usr/local/bin/k3s-wait-tailscale.sh"
if [[ "$K3S_UNIT" != "none" ]]; then
if write_if_changed "$WAIT_SCRIPT" <<'EOF'
#!/bin/bash
# Managed by node-setup flannel-watchdog.
# ExecStartPre for k3s: wait for tailscale0 to exist with an IPv4 address so
# flannel can bind it on the first try. Gives up after 180s and lets k3s start
# anyway (the watchdog heals the stuck-flannel case), so a tailscale problem
# can never leave k3s permanently unstarted either.
for _ in $(seq 1 90); do
    if ip -4 -o addr show tailscale0 2>/dev/null | grep -q 'inet '; then
        exit 0
    fi
    sleep 2
done
echo "k3s-wait-tailscale: tailscale0 still absent/unaddressed after 180s; starting k3s anyway" >&2
exit 0
EOF
then
  ok "installed $WAIT_SCRIPT"
fi
chmod +x "$WAIT_SCRIPT"
fi

# Layer 1: restart k3s whenever tailscaled restarts + boot ordering
if [[ $HAVE_TS -eq 1 && "$K3S_UNIT" != "none" ]]; then
  DROPIN_DIR="/etc/systemd/system/${K3S_UNIT}.d"
  DROPIN="${DROPIN_DIR}/10-tailscale.conf"
  mkdir -p "$DROPIN_DIR"
  if write_if_changed "$DROPIN" <<EOF
# Managed by node-setup flannel-watchdog.
# flannel is bound to the tailscale0 interface; when tailscaled restarts the
# interface is recreated and k3s's flannel hangs ("external interface not
# found"). PartOf makes systemd restart k3s whenever it restarts tailscaled,
# so flannel re-attaches cleanly. After/Wants fix boot ordering, and the
# ExecStartPre wait closes the boot race where k3s starts before the tailnet.
[Unit]
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target
PartOf=tailscaled.service

[Service]
ExecStartPre=${WAIT_SCRIPT}
EOF
  then
    reload_needed=1
    ok "installed drop-in $DROPIN"
  else
    ok "drop-in already current: $DROPIN"
  fi
fi

# Layer 2: harden tailscaled itself (stock unit: Restart=on-failure only, no
# OOM protection, default restart rate-limit)
if [[ $HAVE_TS -eq 1 ]]; then
  TS_DROPIN="/etc/systemd/system/tailscaled.service.d/10-node-setup.conf"
  if write_if_changed "$TS_DROPIN" <<'EOF'
# Managed by node-setup flannel-watchdog.
# - Restart=always: the stock unit only restarts on-failure, so a clean exit
#   would leave the node off the tailnet forever. Everything on this node
#   rides tailscale0; it must always come back.
# - StartLimitIntervalSec=0: never give up restarting, even in a crash loop.
# - OOMScoreAdjust=-900: under memory pressure the kernel must kill browser
#   workspaces, never the tailnet daemon (losing it takes the whole node off
#   the cluster).
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=5
OOMScoreAdjust=-900
EOF
  then
    reload_needed=1
    ok "installed tailscaled hardening drop-in"
  else
    ok "tailscaled hardening drop-in already current"
  fi
fi

if [[ $reload_needed -eq 1 ]]; then
  systemctl daemon-reload
  ok "systemd daemon-reload done"
fi

# Apply the OOM protection to the RUNNING tailscaled immediately (the drop-in
# only takes effect on the next start, and we do not restart tailscaled here -
# that would tear down the interface we are protecting).
if [[ $HAVE_TS -eq 1 ]]; then
  TS_PID="$(systemctl show -p MainPID --value tailscaled 2>/dev/null || echo 0)"
  if [[ "$TS_PID" -gt 0 && -w "/proc/$TS_PID/oom_score_adj" ]]; then
    echo -900 > "/proc/$TS_PID/oom_score_adj" 2>/dev/null || true
    ok "applied oom_score_adj=-900 to running tailscaled (pid $TS_PID)"
  fi
fi

# Layer 3: keep tailscaled from restarting unexpectedly
if [[ $HAVE_TS -eq 1 ]]; then
  # 3a. Hold the apt package so unattended-upgrades won't bump+restart it.
  if command -v apt-mark >/dev/null 2>&1 && dpkg -s tailscale >/dev/null 2>&1; then
    if apt-mark showhold 2>/dev/null | grep -qx tailscale; then
      ok "apt package 'tailscale' already on hold"
    else
      apt-mark hold tailscale >/dev/null && ok "held apt package 'tailscale' (no auto-upgrade)"
    fi
  else
    warn "tailscale is not an apt package here - skipping apt hold"
  fi

  # 3b. Disable Tailscale's own auto-update (best effort; needs tailscaled up).
  if command -v tailscale >/dev/null 2>&1; then
    if tailscale set --auto-update=false >/dev/null 2>&1; then
      ok "disabled Tailscale built-in auto-update"
    else
      warn "could not run 'tailscale set --auto-update=false' (daemon down?) - skipping"
    fi
  fi
fi

# Layer 4: polling watchdog (covers the crash / auto-restart / wedge paths)
# Layer 1 only fires on an explicit `systemctl restart tailscaled`. The outages
# actually seen are: tailscaled hanging in D-state, getting killed and
# auto-restarted (which tears down/recreates tailscale0, deletes flannel.1,
# and leaves k3s's flannel looping without ever restarting k3s), and nodes
# silently dropping off the tailnet. systemd does NOT propagate auto-restarts
# to PartOf units, so a symptom-based watchdog is required.
if [[ $HAVE_TS -eq 1 ]]; then
  WATCHDOG_SCRIPT="/usr/local/bin/k3s-flannel-watchdog.sh"
  WATCHDOG_SERVICE="k3s-flannel-watchdog.service"
  WATCHDOG_SERVICE_FILE="/etc/systemd/system/${WATCHDOG_SERVICE}"
  wd_changed=0

  write_if_changed "$WATCHDOG_SCRIPT" <<'EOF' && wd_changed=1
#!/bin/bash
# Managed by node-setup flannel-watchdog; see k3s-flannel-watchdog.service.
#
# Two independent healing loops. All decisions come from LOCAL symptoms only -
# a remote outage (control plane down, DERP region unreachable) must never
# trigger restarts here, so no cross-node probes are used.
#
#   flannel layer: tailscale0 up + flannel.1 missing + "external interface
#     not found" loop in the k3s journal  -> restart the k3s unit.
#
#   tailscaled layer: any of
#     - `tailscale status` socket unresponsive/failing repeatedly (D-state
#       hang: unit shows active, socket is dead)
#     - tailscale0 interface missing for a sustained period while the daemon
#       claims to be running
#     - backend Running but Self.Online=false for a sustained period
#       (gray drop: daemon alive, tailnet gone)
#     -> restart tailscaled. The k3s drop-in (PartOf) restarts k3s with it,
#        re-attaching flannel cleanly. NeedsLogin/Stopped states are operator
#        states a restart cannot fix and never trigger action.
#
#   plus: a daily node-key-expiry check; expiring keys are logged loudly for
#   30 days before they would silently take the node off the tailnet.
#
# Every action is threshold-gated (no flapping on transient blips),
# rate-limited per target (no restart storms), and logged with its reason.
set -u

# "none" = tailscaled-only mode (no k3s on this node; flannel checks skipped)
K3S_UNIT="${1:?usage: k3s-flannel-watchdog.sh <k3s.service|k3s-agent.service|none>}"

CHECK_INTERVAL=30                 # seconds between checks
MISSING_THRESHOLD=120             # seconds flannel.1 must be missing before action
MIN_K3S_UPTIME=300                # don't act during k3s startup
RESTART_COOLDOWN=600              # min seconds between k3s restarts
TS_STATUS_FAIL_LIMIT=4            # consecutive status failures (~2 min) before tailscaled restart
TS_IFACE_THRESHOLD=180            # seconds tailscale0 may be missing before tailscaled restart
TS_OFFLINE_THRESHOLD=600          # seconds Running-but-offline before tailscaled restart
TS_RESTART_COOLDOWN=900           # min seconds between tailscaled restarts
TS_MIN_UPTIME=120                 # don't judge a freshly started tailscaled
KEY_WARN_SECONDS=$((30*24*3600))  # warn when node key expires within 30 days
STATE_FILE=/var/lib/k3s-flannel-watchdog.state
TS_STATE_FILE=/var/lib/k3s-flannel-watchdog.ts.state

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [k3s-flannel-watchdog] $*"; }

last_restart=0
[[ -f "${STATE_FILE}" ]] && last_restart=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)
last_ts_restart=0
[[ -f "${TS_STATE_FILE}" ]] && last_ts_restart=$(cat "${TS_STATE_FILE}" 2>/dev/null || echo 0)
flannel_missing_since=0
ts_status_fail_count=0
ts_iface_missing_since=0
ts_offline_since=0
last_key_check=0
have_jq=1
command -v jq >/dev/null 2>&1 || have_jq=0

# Seconds a systemd unit has been active (0 if not active).
unit_uptime() {
    local unit=$1 active_since now_mono
    active_since=$(systemctl show -p ActiveEnterTimestampMonotonic --value "${unit}" 2>/dev/null || echo 0)
    [[ "${active_since}" == "0" ]] && { echo 0; return; }
    now_mono=$(awk '{print int($1)}' /proc/uptime)
    # ActiveEnterTimestampMonotonic is microseconds; /proc/uptime is seconds.
    echo $(( now_mono - active_since / 1000000 ))
}

restart_tailscaled() {  # $1 = reason; rate-limited
    local now; now=$(date +%s)
    local since=$(( now - last_ts_restart ))
    if (( since < TS_RESTART_COOLDOWN )); then
        log "tailscaled unhealthy ($1) but in cooldown (${since}s/${TS_RESTART_COOLDOWN}s); waiting"
        return 0
    fi
    log "restarting tailscaled: $1 (k3s follows via PartOf drop-in)"
    if systemctl restart tailscaled; then
        last_ts_restart=$now
        echo "${last_ts_restart}" > "${TS_STATE_FILE}"
        log "tailscaled restarted"
    else
        log "tailscaled restart FAILED"
    fi
    # reset all tailscaled symptom trackers either way
    ts_status_fail_count=0
    ts_iface_missing_since=0
    ts_offline_since=0
}

check_key_expiry() {  # $1 = status json; logs loudly when the node key is near expiry
    (( have_jq )) || return 0
    local expiry epoch now left
    expiry=$(printf '%s' "$1" | jq -r '.Self.KeyExpiry // empty' 2>/dev/null)
    [[ -n "$expiry" ]] || return 0
    epoch=$(date -d "$expiry" +%s 2>/dev/null) || return 0
    now=$(date +%s)
    left=$(( epoch - now ))
    if (( left <= 0 )); then
        log "CRITICAL: tailscale node key EXPIRED (${expiry}); this node is (about to be) off the tailnet. Re-auth with a fresh key and disable key expiry for this machine in the Tailscale admin console."
    elif (( left < KEY_WARN_SECONDS )); then
        log "WARNING: tailscale node key expires in $(( left / 86400 )) days (${expiry}). Disable key expiry for this machine in the Tailscale admin console (Machines -> ... -> Disable key expiry) or the node WILL silently drop off the tailnet."
    fi
}

check_tailscaled() {
    local now=$1

    # A stopped/failed unit is systemd's job (Restart=always drop-in); a fresh
    # one must not be judged yet.
    if ! systemctl is-active --quiet tailscaled; then
        ts_status_fail_count=0
        ts_offline_since=0
        return
    fi
    if (( $(unit_uptime tailscaled) < TS_MIN_UPTIME )); then
        ts_status_fail_count=0
        ts_iface_missing_since=0
        ts_offline_since=0
        return
    fi

    # 1. socket responsiveness (catches D-state hangs: unit active, socket dead)
    local status_json backend
    status_json=$(timeout 15 tailscale status --json 2>/dev/null)
    if [[ -z "$status_json" ]]; then
        ts_status_fail_count=$(( ts_status_fail_count + 1 ))
        log "tailscale status unresponsive (${ts_status_fail_count}/${TS_STATUS_FAIL_LIMIT})"
        if (( ts_status_fail_count >= TS_STATUS_FAIL_LIMIT )); then
            restart_tailscaled "status socket unresponsive ${ts_status_fail_count}x"
        fi
        return
    fi
    ts_status_fail_count=0

    # daily key-expiry check (needs a good status_json)
    if (( now - last_key_check > 86400 )); then
        last_key_check=$now
        check_key_expiry "$status_json"
    fi

    # 2. interface presence (daemon healthy but its interface is gone)
    if ! ip link show tailscale0 >/dev/null 2>&1; then
        if (( ts_iface_missing_since == 0 )); then
            ts_iface_missing_since=$now
            log "tailscale0 missing while tailscaled active; ${TS_IFACE_THRESHOLD}s grace"
        elif (( now - ts_iface_missing_since >= TS_IFACE_THRESHOLD )); then
            restart_tailscaled "tailscale0 missing for $(( now - ts_iface_missing_since ))s"
        fi
        return
    fi
    ts_iface_missing_since=0

    # 3. gray drop: logged in and "Running", but not online on the tailnet.
    (( have_jq )) || return 0
    backend=$(printf '%s' "$status_json" | jq -r '.BackendState // empty' 2>/dev/null)
    if [[ "$backend" == "Running" ]]; then
        local online
        online=$(printf '%s' "$status_json" | jq -r '.Self.Online // true' 2>/dev/null)
        if [[ "$online" == "false" ]]; then
            if (( ts_offline_since == 0 )); then
                ts_offline_since=$now
                log "backend Running but Self.Online=false; ${TS_OFFLINE_THRESHOLD}s grace"
            elif (( now - ts_offline_since >= TS_OFFLINE_THRESHOLD )); then
                restart_tailscaled "Running but offline for $(( now - ts_offline_since ))s"
            fi
            return
        fi
    fi
    ts_offline_since=0
}

check_flannel() {
    local now=$1

    [[ "${K3S_UNIT}" == "none" ]] && return
    if ! systemctl is-active --quiet "${K3S_UNIT}"; then
        flannel_missing_since=0
        return
    fi
    local k3s_up
    k3s_up=$(unit_uptime "${K3S_UNIT}")
    if (( k3s_up < MIN_K3S_UPTIME )); then
        flannel_missing_since=0
        return
    fi

    # tailscale0 must exist (otherwise flannel rightly cannot bring up flannel.1
    # and the issue is upstream; the tailscaled layer handles that first).
    if ! ip link show tailscale0 >/dev/null 2>&1; then
        flannel_missing_since=0
        return
    fi

    if ip link show flannel.1 >/dev/null 2>&1; then
        (( flannel_missing_since != 0 )) && log "flannel.1 recovered on its own"
        flannel_missing_since=0
        return
    fi

    if (( flannel_missing_since == 0 )); then
        flannel_missing_since=$now
        log "flannel.1 missing; starting ${MISSING_THRESHOLD}s grace window"
        return
    fi

    local missing_for=$(( now - flannel_missing_since ))
    (( missing_for < MISSING_THRESHOLD )) && return

    # Cooldown gate.
    local since_restart=$(( now - last_restart ))
    if (( since_restart < RESTART_COOLDOWN )); then
        log "flannel.1 missing for ${missing_for}s but in cooldown (${since_restart}s/${RESTART_COOLDOWN}s); skipping"
        return
    fi

    # Confirm flannel is actually stuck (the recreate-path bug logs this line
    # every 30s with two spaces between "interface" and "not"). If not stuck,
    # something else is going on; log and skip so we don't mask it.
    if ! journalctl -u "${K3S_UNIT}" --since "5 minutes ago" --no-pager 2>/dev/null \
           | grep -q "external interface .* not found"; then
        log "flannel.1 missing for ${missing_for}s but no 'external interface not found' in recent ${K3S_UNIT} log; not restarting"
        flannel_missing_since=0
        return
    fi

    log "flannel.1 missing for ${missing_for}s + recreate-path stuck - restarting ${K3S_UNIT}"
    if systemctl restart "${K3S_UNIT}"; then
        last_restart=$now
        echo "${last_restart}" > "${STATE_FILE}"
        log "${K3S_UNIT} restarted"
    else
        log "${K3S_UNIT} restart FAILED"
    fi
    flannel_missing_since=0
}

log "started for ${K3S_UNIT} (interval=${CHECK_INTERVAL}s, flannel-threshold=${MISSING_THRESHOLD}s, ts-status-limit=${TS_STATUS_FAIL_LIMIT}, ts-offline-threshold=${TS_OFFLINE_THRESHOLD}s, jq=${have_jq})"

while true; do
    sleep "${CHECK_INTERVAL}"
    now=$(date +%s)
    check_tailscaled "$now"
    check_flannel "$now"
done
EOF
  chmod +x "$WATCHDOG_SCRIPT"

  AFTER_UNITS="network.target tailscaled.service"
  [[ "$K3S_UNIT" != "none" ]] && AFTER_UNITS="network.target ${K3S_UNIT} tailscaled.service"
  if write_if_changed "$WATCHDOG_SERVICE_FILE" <<EOF
# Managed by node-setup flannel-watchdog.
[Unit]
Description=k3s flannel watchdog - auto-recover tailscale0/flannel.1 teardown, wedged tailscaled, and stuck flannel
After=${AFTER_UNITS}
Wants=tailscaled.service
# Never rate-limit restarts: the watchdog must always come back; an
# unsupervised data path is exactly the outage this exists to prevent.
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=30
# The watchdog itself must survive memory pressure too.
OOMScoreAdjust=-900
ExecStart=${WATCHDOG_SCRIPT} ${K3S_UNIT}

[Install]
WantedBy=multi-user.target
EOF
  then
    wd_changed=1
  fi

  if [[ $wd_changed -eq 1 ]]; then
    systemctl daemon-reload
    systemctl enable "$WATCHDOG_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$WATCHDOG_SERVICE"
    ok "installed + (re)started watchdog $WATCHDOG_SERVICE (guards $K3S_UNIT + tailscaled)"
  else
    systemctl enable "$WATCHDOG_SERVICE" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$WATCHDOG_SERVICE" || systemctl start "$WATCHDOG_SERVICE"
    ok "watchdog already current: $WATCHDOG_SERVICE (ensured enabled + running)"
  fi
fi

# Heal: recover now if the node is currently broken
need_heal=0
if [[ "$K3S_UNIT" != "none" ]]; then
if journalctl -u "$K3S_UNIT" --since "-5 min" 2>/dev/null \
     | grep -q "external interface .*not found"; then
  warn "detected active 'external interface not found' loop"
  need_heal=1
fi
if ! ip link show flannel.1 >/dev/null 2>&1; then
  warn "flannel.1 device is missing"
  # missing flannel.1 alone can mean 'not ready yet' on a fresh node, so it
  # only forces a heal when the log loop above also fired.
fi
[[ "${FIX_FORCE_HEAL:-0}" == "1" ]] && need_heal=1

if [[ "$need_heal" == "1" && "${FIX_NO_HEAL:-0}" == "1" ]]; then
  warn "broken state detected but FIX_NO_HEAL=1 - skipping restart"
  warn "recover manually with: systemctl restart $K3S_UNIT"
elif [[ "$need_heal" == "1" ]]; then
  warn "restarting $K3S_UNIT to recover the overlay now..."
  systemctl restart "$K3S_UNIT"
  for _ in $(seq 1 15); do
    systemctl is-active --quiet "$K3S_UNIT" && ip link show flannel.1 >/dev/null 2>&1 && break
    sleep 2
  done
  if ip link show flannel.1 >/dev/null 2>&1 && [[ "$(ip route show 2>/dev/null | grep -c flannel.1)" -gt 0 ]]; then
    ok "recovered: flannel.1 up, cross-node routes present"
  else
    warn "flannel.1 still not healthy after restart - investigate manually"
  fi
else
  ok "overlay looks healthy (no stuck-loop detected) - no restart needed"
fi
fi  # K3S_UNIT != none

# summary
echo
log "summary:"
if [[ "$K3S_UNIT" != "none" ]]; then
  printf '   flannel.1 device : %s\n' "$(ip link show flannel.1 >/dev/null 2>&1 && echo present || echo MISSING)"
  printf '   flannel routes   : %s\n' "$(ip route show 2>/dev/null | grep -c flannel.1)"
fi
if [[ $HAVE_TS -eq 1 ]]; then
  printf '   apt hold         : %s\n' "$(apt-mark showhold 2>/dev/null | grep -qx tailscale && echo yes || echo no)"
  if [[ "$K3S_UNIT" != "none" ]]; then
    printf '   k3s drop-in      : %s\n' "$([[ -f "/etc/systemd/system/${K3S_UNIT}.d/10-tailscale.conf" ]] && echo installed || echo missing)"
    printf '   boot-wait script : %s\n' "$([[ -x $WAIT_SCRIPT ]] && echo installed || echo missing)"
  fi
  printf '   tailscaled hard. : %s\n' "$([[ -f /etc/systemd/system/tailscaled.service.d/10-node-setup.conf ]] && echo installed || echo missing)"
  printf '   watchdog service : %s\n' "$(systemctl is-active "$WATCHDOG_SERVICE" 2>/dev/null || echo inactive)"
fi
