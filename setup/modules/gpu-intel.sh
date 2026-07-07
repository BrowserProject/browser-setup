# gpu-intel.sh - optional module for Hetzner nodes with an Intel iGPU that the
# Hetzner image blacklists. Unblacklists i915, installs firmware, reboots.
# shellcheck shell=bash

STEP_DESC["gpu-intel"]="enable Intel iGPU (un-blacklist i915, firmware, reboot)"
gpu-intel::check() {
  # satisfied when no active i915 blacklist remains AND a render node exists
  ! grep -rqE '^blacklist i915' /etc/modprobe.d/ 2>/dev/null \
    && ls /dev/dri/renderD* >/dev/null 2>&1
}
gpu-intel::apply() {
  if ! grep -rqE '^blacklist i915' /etc/modprobe.d/ 2>/dev/null; then
    # blacklist already removed but still no /dev/dri: rebooting again will not
    # help; this box most likely has no (enabled) iGPU.
    if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
      die "i915 is not blacklisted but /dev/dri has no render node; this host may lack an iGPU (drop the gpu-intel module for it)"
    fi
    return 0
  fi
  local f
  grep -rlE '^blacklist i915' /etc/modprobe.d/ | while read -r f; do
    sed -i '/^blacklist i915/s/^/# /' "$f"
    log "commented i915 blacklist in $f"
  done
  ensure_pkgs linux-firmware intel-gpu-tools
  update-initramfs -u
  request_reboot "i915 unblacklisted; reboot loads the iGPU driver"
}
gpu-intel::verify() {
  ls /dev/dri/renderD* >/dev/null 2>&1
}
