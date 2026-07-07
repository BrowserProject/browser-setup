# docker.sh - Docker engine for browser workspace nodes (worker, dev).
# Installed from the official apt repo (NOT snap - conflicts with k3s), then
# apt-held so nothing can restart dockerd behind our back.
# shellcheck shell=bash

STEP_DESC["docker-install"]="install docker-ce from download.docker.com and hold the packages"
docker-install::check() {
  command -v docker >/dev/null \
    && [[ -f /etc/apt/sources.list.d/docker.list ]] \
    && apt-mark showhold 2>/dev/null | grep -qx docker-ce
}
docker-install::apply() {
  if snap list docker >/dev/null 2>&1; then
    die "docker is installed via snap on this host; remove it first (snap remove docker) - snap docker conflicts with k3s"
  fi
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    local codename arch distro
    codename="$(lsb_release -cs)"
    arch="$(dpkg --print-architecture)"
    # docker-ce has separate apt repos per distro (linux/ubuntu vs linux/debian);
    # the ubuntu repo has no candidate for a Debian codename. Derive from
    # os-release so this works on Ubuntu workers AND Debian.
    distro="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
    case "$distro" in ubuntu|debian) ;; *) distro="ubuntu" ;; esac
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
  fi
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  if [[ -n "${DOCKER_CE_VERSION:-}" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      "docker-ce=${DOCKER_CE_VERSION}" "docker-ce-cli=${DOCKER_CE_VERSION}" \
      containerd.io docker-buildx-plugin docker-compose-plugin
  else
    ensure_pkgs "${pkgs[@]}"
  fi
  apt-mark hold docker-ce docker-ce-cli containerd.io >/dev/null
  svc_enable_now docker
}
docker-install::verify() {
  docker info >/dev/null 2>&1
}

STEP_DESC["docker-daemon-config"]="cap container logs + live-restore (dockerd restart must not kill workspaces)"
docker-daemon-config::check() {
  [[ -f /etc/docker/daemon.json ]] \
    && jq -e '."log-opts"."max-size" == "10m" and ."live-restore" == true' /etc/docker/daemon.json >/dev/null 2>&1
}
docker-daemon-config::apply() {
  mkdir -p /etc/docker
  # - log caps: a chatty workspace can never fill the disk with json logs
  # - live-restore: dockerd restarts (deliberate upgrades) keep containers up
  # (heredoc on a simple command, not `if cmd <<EOF; then` - declare -f in the
  # step runner cannot re-serialize that construct; see lib/framework.sh)
  local rc=0
  write_if_changed /etc/docker/daemon.json <<'EOF' || rc=$?
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "1" },
  "live-restore": true
}
EOF
  if [[ "$rc" -eq 0 ]]; then
    local running
    running="$(docker ps -q 2>/dev/null | wc -l)"
    if [[ "$running" -gt 0 ]]; then
      warn "docker restart needed for daemon.json; $running containers running (live-restore keeps them up after this restart)"
      confirm "Restart docker now?" || { warn "skipped docker restart; config applies on next docker restart"; return 0; }
    fi
    systemctl restart docker
  fi
}
docker-daemon-config::verify() {
  [[ -f /etc/docker/daemon.json ]] && jq -e . /etc/docker/daemon.json >/dev/null
}
