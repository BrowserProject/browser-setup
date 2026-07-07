# deadssd.sh - optional stop-gap for workers with dying disks: move Docker's
# containerd storage (images + writable layers) to tmpfs. See wiki/DEADSSD.md
# for the full rationale, caveats and rollback. Opt-in per node, never a
# fleet default.
# shellcheck shell=bash

STEP_DESC["deadssd-tmpfs"]="containerd store on tmpfs (dying-disk mitigation; kills running workspaces once)"
deadssd-tmpfs::check() {
  [[ "$(findmnt -no FSTYPE /var/lib/containerd 2>/dev/null)" == "tmpfs" ]] \
    && grep -q '/var/lib/containerd ' /etc/fstab
}
deadssd-tmpfs::apply() {
  # topology guard: docker must use the SYSTEM containerd, not k3s's, or we
  # would tmpfs the wrong runtime
  local dk
  # shellcheck disable=SC2009 # need full args to read the --containerd= flag
  dk="$(ps -eo args | grep '[d]ockerd' | grep -oE 'containerd=[^ ]+' | head -1 || true)"
  case "$dk" in
    *k3s*|"") die "topology guard: dockerd containerd socket is '$dk' (expected the system containerd); DEADSSD does not apply here" ;;
  esac
  [[ -d /run/k3s/containerd ]] || die "topology guard: no k3s containerd at /run/k3s/containerd; unexpected node layout"

  local running
  running="$(docker ps -q 2>/dev/null | wc -l)"
  if [[ "$running" -gt 0 ]]; then
    warn "switching the container store to tmpfs kills all $running running workspaces on this node"
    confirm "Proceed (drain first if this node serves users)?" || die "aborted; drain the node and re-run"
  fi

  ensure_line /etc/fstab 'tmpfs /var/lib/containerd tmpfs rw,size=50%,mode=0711 0 0'

  systemctl stop docker docker.socket
  systemctl stop containerd
  mountpoint -q /var/lib/containerd || mount /var/lib/containerd
  systemctl start containerd
  systemctl start docker

  # the RAM store starts empty; the edge agent re-pulls all images on restart
  # (it has the registry creds). On a fresh node there is no edge pod yet and
  # the first pod start does this on its own.
  if command -v crictl >/dev/null 2>&1; then
    local edge
    edge="$(crictl ps --name edge -q 2>/dev/null | head -1 || true)"
    if [[ -n "$edge" ]]; then
      crictl stop "$edge" || true
      log "edge pod restarted; node reports images_ready=false until the re-pull (~90s) finishes"
    fi
  fi
}
deadssd-tmpfs::verify() {
  [[ "$(findmnt -no FSTYPE /var/lib/containerd)" == "tmpfs" ]]
}
