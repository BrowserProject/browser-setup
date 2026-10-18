# memory.sh - keeps a worker reachable when its browser sessions use up its
# RAM. Without swap the kernel, short of memory, evicts the program code of
# k3s, containerd, tailscaled and sshd faster than it kills anything, and the
# node freezes for many minutes (beta-w3, 2026-10-17).
#   memory-slice    browser.slice: one cap for every browser container
#   memory-protect  reserved memory for the daemons that keep the node in the
#                   cluster, earlier background reclaim
#   memory-oomd     systemd-oomd ends the session that stalls the slice
# The edge places the browser containers in the slice (Docker cgroup parent).
# Sizes follow MemTotal when applied; a RAM change fails the check and
# re-applies.
# shellcheck shell=bash

BROWSER_SLICE="browser.slice"
_MEM_SYSTEMD_DIR="/etc/systemd/system"
_MEM_SYSCTL_FILE="/etc/sysctl.d/93-node-setup-memory.conf"
# Kept outside the slice for the system: max(2.5 GiB, 8 % of RAM). A beta
# worker without sessions measured 1.1 GiB in use plus 0.75 GiB of hot code
# and page cache; with a 1.5 GiB reserve and a full slice the node stalled.
_MEM_RESERVE_MIN_MIB=2560
_MEM_RESERVE_PCT=8
# The slice's MemoryHigh, as a share of its MemoryMax.
_MEM_HIGH_PCT=95
# "unit MemoryMin MemoryLow" in MiB: about the working set each needs to keep
# the node in the cluster and reachable. system.slice gets the sums, since a
# child's protection never exceeds its parent's.
_MEM_PROTECTED=("k3s-agent 384 768" "containerd 128 256" "docker 128 256" "tailscaled 64 128" "ssh 16 32" "systemd-oomd 64 64")
# Background reclaim starts earlier: min_free_kbytes 1 % of RAM within
# 64-256 MiB, watermark gaps 1 % of RAM (kernel default 0.1 %).
_MEM_MIN_FREE_FLOOR_KB=65536
_MEM_MIN_FREE_CAP_KB=262144
_MEM_WATERMARK_SCALE=100
# Without swap, a full slice does not end in an OOM kill: below MemoryMax the
# browsers evict and re-read their own code and stall (on beta 35 % full
# pressure for minutes, nothing killed). systemd-oomd then kills the browser
# container with the most reclaim; a single container at its own limit stays
# with the kernel, which ends only its biggest process (measured below 2 %).
_MEM_OOMD_LIMIT="20%"
_MEM_OOMD_DURATION="20s"
_MEM_OOMD_DROPIN_NAME="50-oomd.conf"
_MEM_OOMD_CONF="/etc/systemd/oomd.conf.d/50-node-setup.conf"

_mem_total_kb() { awk '/^MemTotal:/ {print $2}' /proc/meminfo; }

# A container store on tmpfs (deadssd) pins its images in RAM outside the
# slice: whole GiB in use, plus one.
_mem_tmpfs_store_mib() {
  local used
  if [[ "$(findmnt -n -o FSTYPE /var/lib/containerd 2>/dev/null)" != tmpfs ]]; then echo 0; return; fi
  used="$(df -B1G --output=used /var/lib/containerd | tail -1 | tr -dc 0-9)"
  echo $(( (used + 1) * 1024 ))
}

_mem_slice_max_mib() {
  local total reserve
  total=$(( $(_mem_total_kb) / 1024 ))
  reserve=$(( total * _MEM_RESERVE_PCT / 100 ))
  if (( reserve < _MEM_RESERVE_MIN_MIB )); then reserve=$_MEM_RESERVE_MIN_MIB; fi
  echo $(( total - reserve - $(_mem_tmpfs_store_mib) ))
}

_mem_slice_high_mib() { echo $(( $(_mem_slice_max_mib) * _MEM_HIGH_PCT / 100 )); }

_mem_slice_unit() {
  local max
  max="$(_mem_slice_max_mib)"
  cat <<EOF
# Managed by node-setup (memory-slice): every browser container runs in this
# slice, so together they can never take the memory the node itself needs.
# Sized from MemTotal ($(( $(_mem_total_kb) / 1024 )) MiB) when applied.
[Unit]
Description=Browser session containers

[Slice]
MemoryAccounting=yes
MemoryHigh=$(_mem_slice_high_mib)M
MemoryMax=${max}M
EOF
}

_mem_protect_dropin() { # <min MiB> <low MiB>
  cat <<EOF
# Managed by node-setup (memory-protect): kept in RAM while browser sessions
# press on the node's memory.
[Service]
MemoryMin=$1M
MemoryLow=$2M
EOF
}

_mem_system_slice_dropin() {
  local entry unit min low min_sum=0 low_sum=0
  for entry in "${_MEM_PROTECTED[@]}"; do
    read -r unit min low <<< "$entry"
    min_sum=$(( min_sum + min )); low_sum=$(( low_sum + low ))
  done
  cat <<EOF
# Managed by node-setup (memory-protect): the sums of the protected services,
# whose protection cannot exceed their parent's.
[Slice]
MemoryMin=${min_sum}M
MemoryLow=${low_sum}M
EOF
}

_mem_sysctl() {
  local kb
  kb=$(( $(_mem_total_kb) / 100 ))
  if (( kb < _MEM_MIN_FREE_FLOOR_KB )); then kb=$_MEM_MIN_FREE_FLOOR_KB; fi
  if (( kb > _MEM_MIN_FREE_CAP_KB )); then kb=$_MEM_MIN_FREE_CAP_KB; fi
  cat <<EOF
# Managed by node-setup (memory-protect): kswapd starts reclaiming earlier, so
# allocations stall less often in direct reclaim.
vm.min_free_kbytes = $kb
vm.watermark_scale_factor = $_MEM_WATERMARK_SCALE
EOF
}

_mem_file_is() { # <path> <generator...>: the file holds exactly what the generator prints
  [[ -f "$1" ]] && cmp -s "$1" <("${@:2}")
}

STEP_DESC["memory-slice"]="browser.slice: one memory cap for all browser containers (RAM - max(2.5 GiB, 8 %))"
memory-slice::check() {
  _mem_file_is "$_MEM_SYSTEMD_DIR/$BROWSER_SLICE" _mem_slice_unit
}
memory-slice::apply() {
  _mem_slice_unit | write_if_changed "$_MEM_SYSTEMD_DIR/$BROWSER_SLICE" || true
  # applies new limits to a running slice too
  systemctl daemon-reload
}
memory-slice::verify() {
  [[ "$(systemctl show -p MemoryMax --value "$BROWSER_SLICE")" == "$(( $(_mem_slice_max_mib) * 1048576 ))" ]] \
    && [[ "$(systemctl show -p MemoryHigh --value "$BROWSER_SLICE")" == "$(( $(_mem_slice_high_mib) * 1048576 ))" ]]
}

_mem_protect_ok() {
  local entry unit min low
  for entry in "${_MEM_PROTECTED[@]}"; do
    read -r unit min low <<< "$entry"
    _mem_file_is "$_MEM_SYSTEMD_DIR/${unit}.service.d/90-memory.conf" _mem_protect_dropin "$min" "$low" || return 1
  done
  _mem_file_is "$_MEM_SYSTEMD_DIR/system.slice.d/90-memory.conf" _mem_system_slice_dropin \
    && _mem_file_is "$_MEM_SYSCTL_FILE" _mem_sysctl
}

STEP_DESC["memory-protect"]="MemoryMin/Low for k3s-agent, containerd, docker, tailscaled, ssh; earlier background reclaim"
memory-protect::check() {
  _mem_protect_ok
}
memory-protect::apply() {
  local entry unit min low
  # Written for every unit, present or not: a unit installed later (ssh is
  # socket activated) starts protected.
  for entry in "${_MEM_PROTECTED[@]}"; do
    read -r unit min low <<< "$entry"
    _mem_protect_dropin "$min" "$low" | write_if_changed "$_MEM_SYSTEMD_DIR/${unit}.service.d/90-memory.conf" || true
  done
  _mem_system_slice_dropin | write_if_changed "$_MEM_SYSTEMD_DIR/system.slice.d/90-memory.conf" || true
  # applies to the running units without restarting them
  systemctl daemon-reload
  _mem_sysctl | write_if_changed "$_MEM_SYSCTL_FILE" || true
  sysctl -p "$_MEM_SYSCTL_FILE" >/dev/null
}
memory-protect::verify() {
  _mem_protect_ok \
    && [[ "$(sysctl -n vm.watermark_scale_factor)" == "$_MEM_WATERMARK_SCALE" ]] \
    && [[ "$(systemctl show -p MemoryMin --value system.slice)" != "0" ]]
}

_mem_oomd_slice_dropin() {
  cat <<EOF2
# Managed by node-setup (memory-oomd): systemd-oomd kills the browser
# container with the most reclaim once the slice stalls.
[Slice]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=$_MEM_OOMD_LIMIT
EOF2
}

_mem_oomd_conf() {
  cat <<EOF2
# Managed by node-setup (memory-oomd): how long the slice must stay above its
# limit before systemd-oomd acts (systemd 255 has no per-unit setting).
[OOM]
DefaultMemoryPressureDurationSec=$_MEM_OOMD_DURATION
EOF2
}

STEP_DESC["memory-oomd"]="systemd-oomd kills the browser container that stalls browser.slice ($_MEM_OOMD_LIMIT full pressure for $_MEM_OOMD_DURATION)"
memory-oomd::check() {
  dpkg -s systemd-oomd >/dev/null 2>&1 \
    && _mem_file_is "$_MEM_SYSTEMD_DIR/$BROWSER_SLICE.d/$_MEM_OOMD_DROPIN_NAME" _mem_oomd_slice_dropin \
    && _mem_file_is "$_MEM_OOMD_CONF" _mem_oomd_conf \
    && systemctl is-active --quiet systemd-oomd.service
}
memory-oomd::apply() {
  ensure_pkgs systemd-oomd
  _mem_oomd_slice_dropin | write_if_changed "$_MEM_SYSTEMD_DIR/$BROWSER_SLICE.d/$_MEM_OOMD_DROPIN_NAME" || true
  local rc=0
  _mem_oomd_conf | write_if_changed "$_MEM_OOMD_CONF" || rc=$?
  svc_enable_now systemd-oomd.service
  # oomd reads its configuration only at start
  [[ "$rc" -eq 0 ]] && systemctl restart systemd-oomd.service
  return 0
}
memory-oomd::verify() {
  systemctl is-active --quiet systemd-oomd.service \
    && [[ "$(systemctl show -p ManagedOOMMemoryPressure --value "$BROWSER_SLICE")" == "kill" ]]
}
