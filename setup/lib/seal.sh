# shellcheck shell=bash
# seal.sh - `node-setup seal`: turn a prepared disk into an image many nodes
# boot from. It refuses while the disk carries a node identity or a secret,
# then removes what every clone must create for itself (tailscale and docker
# identity, SSH host keys and authorized keys, machine id, cloud-init instance
# state) and keeps the step journal, which lets a clone skip the prepared steps.
#
# Every absolute path is under SEAL_ROOT, so the tests can run it in a sandbox.
# It needs the modules sourced (k3s-agent.sh).

SEAL_ROOT="${NODE_SETUP_SEAL_ROOT:-}"
# The keys an image must never carry; the bundle's own docs and scripts name
# them, so the scan leaves the bundle out.
SEAL_SECRET_KEYS="REGISTRY_PASSWORD|TS_AUTHKEY|K3S_TOKEN"
# What seal runs that changes the host; a sandboxed seal finds each as a stub
# under SEAL_ROOT or refuses.
SEAL_HOST_COMMANDS=(systemctl ufw apt-get journalctl cloud-init fstrim)
# Package activity a fresh cloud VM starts on its own; it must neither hold the
# apt locks during the cleanup nor be cut off by the poweroff.
SEAL_APT_UNITS=(apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service)
SEAL_APT_WAIT_S=600

_apt_idle() { ! pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null; }
_dpkg_unfinished() { [[ -n "$(dpkg --audit 2>/dev/null)" ]]; }

# seal_refusals step... -> one reason per line, nothing when the disk may be
# sealed. The steps are the role's plan; each one the prepare phase runs must
# carry the journal hash of this bundle and cluster.env.
seal_refusals() {
  local r="$SEAL_ROOT" state step f containers missing=() dirs=()

  state="$(tailscale status --json 2>/dev/null | jq -r .BackendState 2>/dev/null || true)"
  if [[ "$state" == "Running" || "$state" == "Starting" ]]; then
    echo "tailscale is logged in (BackendState $state); the image would share its node key"
  fi
  _k3s_agent_joined "$r" && echo "k3s-agent has joined a cluster (it runs, or $r/etc/rancher/node/password exists)"
  [[ "$(systemctl is-enabled k3s-agent 2>/dev/null || true)" == enabled* ]] && echo "k3s-agent is enabled"
  grep -qs '^K3S_TOKEN=' "$r/etc/systemd/system/k3s-agent.service.env" \
    && echo "$r/etc/systemd/system/k3s-agent.service.env holds K3S_TOKEN"
  if ! containers="$(docker ps -aq 2>/dev/null)"; then
    echo "cannot list docker containers"
  elif [[ -n "$containers" ]]; then
    echo "containers exist: $(paste -sd' ' <<< "$containers")"
  fi
  [[ -e "$CONF_DIR/secrets.env" ]] && echo "$CONF_DIR/secrets.env exists"
  [[ -e "$r/root/.docker/config.json" ]] && echo "$r/root/.docker/config.json exists (registry login)"
  for f in "$r"/opt/burst-*.sh; do
    [[ -e "$f" ]] && echo "$f exists (a provisioning script with secrets)"
  done
  [[ -e "$r/etc/systemd/system/node-setup-resume.service" ]] && echo "a node-setup run is unfinished (node-setup-resume.service)"
  _dpkg_unfinished && echo "dpkg --audit lists packages that are not fully installed"

  for f in "$CONF_DIR" "$r/root" "$r/opt"; do
    [[ -d "$f" ]] && dirs+=("$f")
  done
  if [[ ${#dirs[@]} -gt 0 ]]; then
    while IFS= read -r f; do
      echo "$f assigns a secret (${SEAL_SECRET_KEYS//|/, })"
    done < <(find "${dirs[@]}" -path "$BUNDLE_DIR" -prune -o -type f -print0 2>/dev/null \
      | xargs -0 -r grep -lsIE "^[[:space:]]*(export[[:space:]]+)?(${SEAL_SECRET_KEYS})=" || true)
  fi

  for step in "$@"; do
    [[ -z "$(_phase_skip_reason "$step")" ]] || continue
    [[ "$(cat "$STATE_DIR/state/$step.hash" 2>/dev/null)" == "$(_step_hash "$step")" ]] || missing+=("$step")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "not prepared with this bundle and cluster.env: ${missing[*]}"
  fi
  return 0
}

seal_image() {
  local r="$SEAL_ROOT" n images path

  if [[ -n "$r" ]]; then
    for n in "${SEAL_HOST_COMMANDS[@]}"; do
      path="$(command -v "$n" || true)"
      [[ "$path" == "$r"/* ]] || die "NODE_SETUP_SEAL_ROOT is set, but $n is no stub under it (${path:-missing}); refusing to seal this host"
    done
  fi

  for n in "${SEAL_APT_UNITS[@]}"; do
    systemctl stop "$n" >/dev/null 2>&1 || true
  done
  wait_for "$SEAL_APT_WAIT_S" 5 _apt_idle \
    || die "apt or dpkg still runs after ${SEAL_APT_WAIT_S}s; nothing was removed, run seal again"
  ! _dpkg_unfinished || die "dpkg --audit lists packages that are not fully installed; nothing was removed"

  images="$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | sort | paste -sd' ' || true)"
  mkdir -p "$CONF_DIR"
  {
    echo "# Written by node-setup seal: the disk image this node booted from."
    printf 'IMAGE_SEALED_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'IMAGE_ROLE=%q\n' "${ROLE:-}"
    printf 'IMAGE_MODULES=%q\n' "${EXTRA_MODULES:-}"
    printf 'IMAGE_CLUSTER_ENV_SHA256=%q\n' "$(sha256sum "$CLUSTER_ENV_FILE" | cut -d' ' -f1)"
    printf 'IMAGE_K3S=%q\n' "$(k3s --version 2>/dev/null | head -n1 || true)"
    printf 'IMAGE_DOCKER=%q\n' "$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)"
    printf 'IMAGE_TAILSCALE=%q\n' "$(dpkg-query -W -f='${Version}' tailscale 2>/dev/null || true)"
    printf 'IMAGE_DOCKER_IMAGES=%q\n' "$images"
  } > "$CONF_DIR/image.env"

  log "stopping the services that hold node identity"
  for n in k3s-flannel-watchdog docker-tailscale-routing tailscaled docker docker.socket containerd; do
    systemctl stop "$n" >/dev/null 2>&1 || true
  done

  # tailscale node key, docker engine id, watchdog state: each clone makes its own
  find "$r/var/lib/tailscale" -mindepth 1 -delete 2>/dev/null || true
  rm -f "$r/var/lib/docker/engine-id" "$r"/var/lib/k3s-flannel-watchdog*.state

  # transient journal state; state/*.hash stays and is the point of the image
  rm -rf "$STATE_DIR/.apt-stamp" "$REBOOT_FLAG_FILE" "$STATE_DIR/rebooted-for"
  : > "$LOG_FILE"

  # the lockout guard ufw-rules pins for the SSH client of the bake, by its comment
  for n in $(ufw status numbered 2>/dev/null | sed -n 's/^\[ *\([0-9][0-9]*\)\].*# node-setup: provisioning ssh guard$/\1/p' | sort -rn); do
    ufw --force delete "$n" >/dev/null
  done

  rm -f "$r"/etc/ssh/ssh_host_* "$r/root/.ssh/authorized_keys" "$r"/home/*/.ssh/authorized_keys \
    "$r/root/.bash_history" "$r"/home/*/.bash_history

  apt-get clean
  find "$r/var/lib/apt/lists" -mindepth 1 -delete 2>/dev/null || true
  journalctl --rotate >/dev/null 2>&1 || true
  journalctl --vacuum-time=1s >/dev/null 2>&1 || true
  find "$r/var/log" -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete 2>/dev/null || true

  # cloud-init runs again on the clone's first boot and creates a new machine id
  if command -v cloud-init >/dev/null 2>&1; then
    cloud-init clean --logs --seed --machine-id
  else
    : > "$r/etc/machine-id"
    rm -f "$r/var/lib/dbus/machine-id"
  fi
  rm -f "$r/var/lib/systemd/random-seed"

  sync
  fstrim -av >/dev/null 2>&1 || true
}
