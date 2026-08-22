# base.sh - baseline OS state shared by every role.
# shellcheck shell=bash

STEP_DESC["base-packages"]="install baseline packages + full upgrade on first run"
base-packages::apply() {
  apt_update_once
  # Full upgrade once at provision time; afterwards unattended-upgrades applies
  # security updates only (see base-unattended).
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  ensure_pkgs curl jq ca-certificates gnupg lsb-release htop ufw
}
base-packages::verify() {
  command -v curl >/dev/null && command -v jq >/dev/null && command -v ufw >/dev/null
}

STEP_DESC["base-time"]="enable NTP time sync (TLS and cluster auth need correct clocks)"
base-time::check() {
  timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes
}
base-time::apply() {
  ensure_pkgs systemd-timesyncd
  svc_enable_now systemd-timesyncd
  timedatectl set-ntp true
}
base-time::verify() {
  systemctl is-active --quiet systemd-timesyncd
}

STEP_DESC["base-journald"]="cap journald disk usage so logs can never fill the disk"
base-journald::apply() {
  mkdir -p /etc/systemd/journald.conf.d
  # heredoc on a simple command, not `if cmd <<EOF; then` - the step runner
  # re-serializes functions with `declare -f`, which reorders that construct
  # into invalid shell (see _run_fn in lib/framework.sh).
  local rc=0
  write_if_changed /etc/systemd/journald.conf.d/90-node-setup.conf <<'EOF' || rc=$?
# Managed by node-setup: bound journal growth on long-lived nodes.
[Journal]
SystemMaxUse=500M
MaxRetentionSec=1month
EOF
  [[ "$rc" -eq 0 ]] && systemctl restart systemd-journald
  return 0
}
base-journald::verify() {
  [[ -f /etc/systemd/journald.conf.d/90-node-setup.conf ]]
}

STEP_DESC["base-unattended"]="unattended security upgrades; hold packages whose auto-restart breaks the node"
base-unattended::apply() {
  ensure_pkgs unattended-upgrades
  write_if_changed /etc/apt/apt.conf.d/20auto-upgrades <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  # Security-only, and never touch the packages whose postinst restarts a
  # service this fleet cannot afford to have restarted unsupervised:
  #  - tailscale: restart recreates tailscale0 and wedges flannel (also apt-held)
  #  - docker/containerd: restart kills every running browser workspace
  #  - postgresql: restart drops live DB connections; apply those deliberately
  write_if_changed /etc/apt/apt.conf.d/52-node-setup-unattended <<'EOF' || true
// Managed by node-setup.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "tailscale";
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
    "postgresql-";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  svc_enable_now unattended-upgrades
}
base-unattended::verify() {
  [[ -f /etc/apt/apt.conf.d/52-node-setup-unattended ]] \
    && systemctl is-enabled --quiet unattended-upgrades
}

STEP_DESC["base-ssh-harden"]="disable SSH password auth (only when key auth is proven present)"
base-ssh-harden::check() {
  [[ -f /etc/ssh/sshd_config.d/90-node-setup.conf ]]
}
base-ssh-harden::apply() {
  # Lockout guard: never disable password auth unless a root authorized_key
  # exists. Provisioning happens over SSH; cutting the branch we sit on is the
  # one mistake this file must be incapable of.
  if ! grep -qE '^(ssh|ecdsa)' /root/.ssh/authorized_keys 2>/dev/null; then
    warn "no key in /root/.ssh/authorized_keys; leaving SSH password auth untouched"
    return 0
  fi
  write_if_changed /etc/ssh/sshd_config.d/90-node-setup.conf <<'EOF' || return 0
# Managed by node-setup: key-only SSH.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 5
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 5
EOF
  # validate before reloading: a broken sshd config must never go live.
  # /run/sshd can be absent right after an openssh upgrade; sshd -t needs it.
  mkdir -p /run/sshd
  local sshd_err
  if ! sshd_err="$(sshd -t 2>&1)"; then
    rm -f /etc/ssh/sshd_config.d/90-node-setup.conf
    die "sshd -t rejected the hardening drop-in; removed it (sshd untouched): ${sshd_err}"
  fi
  # base-packages may have just upgraded openssh; a reload racing that restart
  # fails transiently. Retry, and never die here: the drop-in is validated and
  # in place, and socket-activated sshd re-reads config per connection anyway.
  if ! retry 3 2 systemctl reload ssh 2>/dev/null && ! systemctl reload sshd 2>/dev/null; then
    warn "ssh reload failed; hardening takes effect on the next ssh reload/restart"
  fi
  return 0
}
base-ssh-harden::verify() {
  # /run/sshd is absent on a fresh image until sshd first starts; sshd -t needs it.
  mkdir -p /run/sshd
  sshd -t 2>/dev/null
}

STEP_DESC["swap-disable"]="disable swap (kubelet requirement on cluster nodes)"
swap-disable::check() {
  [[ -z "$(swapon --noheadings --show 2>/dev/null)" ]] && ! grep -qE '^[^#].*\sswap\s' /etc/fstab
}
swap-disable::apply() {
  swapoff -a
  sed -i '/\sswap\s/d' /etc/fstab
}
swap-disable::verify() {
  [[ -z "$(swapon --noheadings --show 2>/dev/null)" ]]
}

