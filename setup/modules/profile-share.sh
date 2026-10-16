# profile-share.sh - saved-profile storage on premium workers: the region's NFS
# share at /mnt/browser-profiles (one ext4 image per profile, attached by the
# edge's tool container), the kernel settings that turn a lost NFS lock into
# EIO instead of a silent re-grant, and a fixed node-wide scratch filesystem
# for the browser caches. profile-share-server.sh adds the beta export.
#
# Inputs (cluster.env, so doctor and later runs see the same values):
#   PROFILE_SHARE_EXPORT      <10.x.y.z|127.0.0.1>:/<path>
#   PROFILE_SHARE_DOMAIN      (prod|beta)-location-<Locations.id>
#   PROFILE_SCRATCH_GIB       4-256, default 24
#   PROFILE_SHARE_SERVER_GIB  8-1024, default 40 (profile-share-server only)
# The paths are fixed, not settings: the edge and the profile tool mirror them.
# shellcheck shell=bash

PROFILE_SHARE_MOUNT=/mnt/browser-profiles
PROFILE_SHARE_MARKER=.browser-profile-share.json
PROFILE_SHARE_DISK_FLOOR_GIB=20
PROFILE_SCRATCH_IMG=/var/lib/browser-profile-scratch.img
PROFILE_SCRATCH_DIR=/var/lib/browser-profile-scratch
PROFILE_SHARE_EXPORT_RE='^(10(\.[0-9]{1,3}){3}|127\.0\.0\.1):/[A-Za-z0-9/._-]{1,200}$'
PROFILE_SHARE_DOMAIN_RE='^(prod|beta)-location-[1-9][0-9]{0,9}$'
PROFILE_SHARE_GIB_BYTES=1073741824
PROFILE_SHARE_SERVER=0

# --- configuration (node-setup load_environment) -------------------------------------
_ps_int_in() { # value min max
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

# 10/8 outside the k3s pod and service ranges, or loopback.
_share_ip_in_range() {
  local ip="$1" a b c d o
  [[ "$ip" == 127.0.0.1 ]] && return 0
  IFS=. read -r a b c d <<< "$ip"
  [[ "$a" == 10 ]] || return 1
  for o in "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] && (( 10#$o <= 255 )) || return 1
  done
  [[ "$b" != 42 && "$b" != 43 ]]
}

# profile_share_configure <with-server 0|1> <disk gate: off|warn|die>
profile_share_configure() {
  local server="$1" gate="$2"
  PROFILE_SHARE_SERVER="$server"
  PROFILE_SHARE_EXPORT="${PROFILE_SHARE_EXPORT:-}"
  PROFILE_SHARE_DOMAIN="${PROFILE_SHARE_DOMAIN:-}"
  PROFILE_SCRATCH_GIB="${PROFILE_SCRATCH_GIB:-24}"
  PROFILE_SHARE_SERVER_GIB="${PROFILE_SHARE_SERVER_GIB:-40}"
  [[ "$PROFILE_SHARE_EXPORT" =~ $PROFILE_SHARE_EXPORT_RE ]] \
    || die "profile-share: PROFILE_SHARE_EXPORT '$PROFILE_SHARE_EXPORT' must be <10.x.y.z|127.0.0.1>:/<path> (set it in cluster.env)"
  _share_ip_in_range "${PROFILE_SHARE_EXPORT%%:*}" \
    || die "profile-share: the share address ${PROFILE_SHARE_EXPORT%%:*} must be in 10.0.0.0/8 outside 10.42.0.0/16 and 10.43.0.0/16, or 127.0.0.1"
  [[ "$PROFILE_SHARE_DOMAIN" =~ $PROFILE_SHARE_DOMAIN_RE ]] \
    || die "profile-share: PROFILE_SHARE_DOMAIN '$PROFILE_SHARE_DOMAIN' must match (prod|beta)-location-<id> (set it in cluster.env)"
  _ps_int_in "$PROFILE_SCRATCH_GIB" 4 256 \
    || die "profile-share: PROFILE_SCRATCH_GIB '$PROFILE_SCRATCH_GIB' must be an integer from 4 to 256"
  if [[ "$server" == 1 ]]; then
    _ps_int_in "$PROFILE_SHARE_SERVER_GIB" 8 1024 \
      || die "profile-share-server: PROFILE_SHARE_SERVER_GIB '$PROFILE_SHARE_SERVER_GIB' must be an integer from 8 to 1024"
    [[ "$PROFILE_SHARE_EXPORT" == "$PROFILE_SHARE_SERVER_EXPORT" ]] \
      || die "profile-share-server: PROFILE_SHARE_EXPORT must be $PROFILE_SHARE_SERVER_EXPORT"
  elif [[ "$PROFILE_SHARE_EXPORT" == 127.0.0.1:* ]]; then
    die "profile-share: a 127.0.0.1 export needs the profile-share-server module"
  fi
  case "$gate" in
    off) ;;
    warn) _profile_disk_gate || warn "dry-run: the disk gate would refuse this run" ;;
    *) _profile_disk_gate || die "profile-share: not enough free disk for the profile images" ;;
  esac
}

# Free space on /var/lib must cover every image still to create plus a floor.
_profile_disk_gate() {
  local need=0 avail
  [[ -e "$PROFILE_SCRATCH_IMG" ]] || (( need += 10#$PROFILE_SCRATCH_GIB ))
  if [[ "$PROFILE_SHARE_SERVER" == 1 && ! -e "$PROFILE_SHARE_SERVER_IMG" ]]; then
    (( need += 10#$PROFILE_SHARE_SERVER_GIB ))
  fi
  (( need > 0 )) || return 0
  avail="$(df -B1G --output=avail /var/lib | tail -n1 | tr -dc '0-9')"
  if (( ${avail:-0} < need + PROFILE_SHARE_DISK_FLOOR_GIB )); then
    err "disk gate: /var/lib has ${avail:-0} GiB free; the new images need $need GiB plus a $PROFILE_SHARE_DISK_FLOOR_GIB GiB floor"
    return 1
  fi
}

# --- shared helpers -------------------------------------------------------------------
# "<fstype> <source> <mount and super options>" of the topmost mount at a path,
# read from mountinfo so a hung share is never touched.
_ps_mountinfo() {
  awk -v t="$1" '$5 == t { for (i = 7; $i != "-"; i++); r = $(i+1) " " $(i+2) " " $6 "," $(i+3) } END { if (r != "") print r }' /proc/self/mountinfo
}

_ps_block_is() { # file marker expected-content
  [[ "$(awk -v b="# BEGIN $2" -v e="# END $2" '$0 == e {f = 0} f {print} $0 == b {f = 1}' "$1" 2>/dev/null)" == "$3" ]]
}

# The empty mount point is immutable while unmounted, so nothing can write
# into the root filesystem in its place.
_ps_mount_point() {
  local dir="$1"
  mkdir -p "$dir"
  [[ -z "$(_ps_mountinfo "$dir")" ]] || return 0
  [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die "$dir is not mounted but not empty; move its contents away and re-run"
  chattr +i "$dir"
}

# Fixed-size, fully allocated ext4 image. An existing image is never recreated;
# fallocate re-allocates anything a trim punched out.
_ps_image() { # path gib label
  local img="$1" gib="$2" label="$3" size
  if [[ -e "$img" ]]; then
    size="$(stat -c %s "$img")"
    (( size == gib * PROFILE_SHARE_GIB_BYTES )) \
      || die "$img is $(( size / PROFILE_SHARE_GIB_BYTES )) GiB, the configuration says $gib GiB; resizing is manual"
    [[ "$(blkid -p -s TYPE -o value "$img" 2>/dev/null)" == ext4 ]] || die "$img is not an ext4 image"
    fallocate -l "$(( gib * PROFILE_SHARE_GIB_BYTES ))" "$img"
    return 0
  fi
  _profile_disk_gate || die "not enough free disk for $img"
  rm -f "$img.tmp"
  fallocate -l "$(( gib * PROFILE_SHARE_GIB_BYTES ))" "$img.tmp"
  chmod 0600 "$img.tmp"
  mkfs.ext4 -F -q -m 0 -L "$label" -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$img.tmp"
  mv "$img.tmp" "$img"
}

_ps_image_ok() { # path gib mountpoint
  local img="$1" gib="$2" dir="$3" info loop blocks bsize size
  info="$(_ps_mountinfo "$dir")"
  [[ "${info%% *}" == ext4 ]] || return 1
  loop="$(cut -d' ' -f2 <<< "$info")"
  [[ "$loop" == /dev/loop* && "$(cat "/sys/block/${loop#/dev/}/loop/backing_file" 2>/dev/null)" == "$img" ]] || return 1
  read -r blocks bsize size < <(stat -c '%b %B %s' "$img")
  (( size == gib * PROFILE_SHARE_GIB_BYTES && blocks * bsize >= size ))
}

_ps_fstab_scratch() {
  echo "$PROFILE_SCRATCH_IMG $PROFILE_SCRATCH_DIR ext4 loop,nosuid,nodev,noatime,nofail,X-fstrim.notrim,x-systemd.before=docker.service 0 2"
}
_ps_fstab_share() {
  echo "$PROFILE_SHARE_EXPORT $PROFILE_SHARE_MOUNT nfs4 vers=4.2,hard,proto=tcp,timeo=600,retrans=2,rsize=1048576,wsize=1048576,nosuid,nodev,noexec,_netdev,nofail,x-systemd.mount-timeout=120s 0 0"
}

# --- profile-share-kernel ----------------------------------------------------------
_ps_machine_id() {
  local id
  id="$(tr -d '\n' < /etc/machine-id)"
  [[ "$id" =~ ^[0-9a-f]{32}$ ]] || die "/etc/machine-id is not 32 hex characters"
  echo "$id"
}
_ps_modprobe_conf() {
  printf '# Managed by node-setup (profile-share-kernel): a lost NFS lock ends in EIO, the client id is stable.\n'
  printf 'options nfs recover_lost_locks=0 nfs4_unique_id=%s\n' "$1"
}
_ps_modules_conf() {
  printf '# Managed by node-setup (profile-share-kernel).\nloop\nnfs\n'
}
_ps_sysctl_conf() {
  printf '# Managed by node-setup (profile-share-kernel): a task stalled on the share never panics the node.\nkernel.hung_task_panic = 0\n'
}
_ps_tmpfiles_conf() {
  printf '# Managed by node-setup (profile-share-kernel).\nd /run/browser-profiles 0700 root root -\nd /run/browser-profiles/profile 0700 root root -\nd /run/browser-profiles/selftest 0700 root root -\n'
}
_ps_nfs_params_live() { # machine-id
  [[ "$(cat /sys/module/nfs/parameters/recover_lost_locks 2>/dev/null)" == N ]] \
    && [[ "$(cat /sys/module/nfs/parameters/nfs4_unique_id 2>/dev/null)" == "$1" ]]
}
_ps_kernel_ok() {
  local mid
  mid="$(_ps_machine_id)" || return 1
  cmp -s <(_ps_modprobe_conf "$mid") /etc/modprobe.d/browser-profiles.conf \
    && cmp -s <(_ps_modules_conf) /etc/modules-load.d/browser-profiles.conf \
    && cmp -s <(_ps_sysctl_conf) /etc/sysctl.d/93-node-setup-profile-share.conf \
    && cmp -s <(_ps_tmpfiles_conf) /etc/tmpfiles.d/browser-profiles.conf \
    && _ps_nfs_params_live "$mid" \
    && [[ -e /dev/loop-control && -d /run/browser-profiles/profile && -d /run/browser-profiles/selftest ]] \
    && [[ "$(findmnt -no PROPAGATION /run)" == shared ]] \
    && [[ "$(sysctl -n kernel.hung_task_panic)" == 0 ]]
}

STEP_DESC["profile-share-kernel"]="NFS client options (recover_lost_locks=0, stable client id), loop + nfs modules, no hung-task panic"
profile-share-kernel::check() {
  _ps_kernel_ok
}
profile-share-kernel::apply() {
  local maj min mid
  IFS=.- read -r maj min _ <<< "$(uname -r)"
  (( maj > 5 || (maj == 5 && min >= 8) )) || die "kernel $(uname -r) is older than 5.8 (no LOOP_CONFIGURE)"
  [[ "$(findmnt -no PROPAGATION /run)" == shared ]] || die "/run is not a shared mount; profile mounts would not reach dockerd"
  mid="$(_ps_machine_id)"

  _ps_modules_conf | write_if_changed /etc/modules-load.d/browser-profiles.conf || true
  _ps_modprobe_conf "$mid" | write_if_changed /etc/modprobe.d/browser-profiles.conf || true
  modprobe loop
  [[ -e /dev/loop-control ]] || die "/dev/loop-control missing after modprobe loop"
  modprobe nfs
  if ! _ps_nfs_params_live "$mid"; then
    [[ -z "$(awk '{ for (i = 7; $i != "-"; i++); if ($(i+1) == "nfs4") print }' /proc/self/mountinfo)" ]] \
      || die "nfs4 mounts exist with other live nfs parameters; reboot first"
    printf 'N' > /sys/module/nfs/parameters/recover_lost_locks
    printf '%s' "$mid" > /sys/module/nfs/parameters/nfs4_unique_id
  fi

  _ps_sysctl_conf | write_if_changed /etc/sysctl.d/93-node-setup-profile-share.conf || true
  sysctl -p /etc/sysctl.d/93-node-setup-profile-share.conf >/dev/null
  _ps_tmpfiles_conf | write_if_changed /etc/tmpfiles.d/browser-profiles.conf || true
  systemd-tmpfiles --create /etc/tmpfiles.d/browser-profiles.conf
}
profile-share-kernel::verify() {
  _ps_kernel_ok
}

# --- profile-share-scratch ---------------------------------------------------------
STEP_DESC["profile-share-scratch"]="fixed, fully allocated scratch filesystem for browser caches ($PROFILE_SCRATCH_IMG)"
profile-share-scratch::check() {
  _ps_block_is /etc/fstab "node-setup profile-share-scratch" "$(_ps_fstab_scratch)" \
    && _ps_image_ok "$PROFILE_SCRATCH_IMG" "$PROFILE_SCRATCH_GIB" "$PROFILE_SCRATCH_DIR" \
    && [[ "$(stat -c '%U:%G %a' "$PROFILE_SCRATCH_DIR")" == "root:root 700" ]]
}
profile-share-scratch::apply() {
  _ps_image "$PROFILE_SCRATCH_IMG" "$PROFILE_SCRATCH_GIB" brl-scratch
  _ps_mount_point "$PROFILE_SCRATCH_DIR"
  _ps_fstab_scratch | replace_block /etc/fstab "node-setup profile-share-scratch" || true
  systemctl daemon-reload
  [[ -n "$(_ps_mountinfo "$PROFILE_SCRATCH_DIR")" ]] || mount "$PROFILE_SCRATCH_DIR"
  _ps_image_ok "$PROFILE_SCRATCH_IMG" "$PROFILE_SCRATCH_GIB" "$PROFILE_SCRATCH_DIR" \
    || die "$PROFILE_SCRATCH_DIR is mounted from something other than $PROFILE_SCRATCH_IMG; unmount it first"
  chown root:root "$PROFILE_SCRATCH_DIR"
  chmod 0700 "$PROFILE_SCRATCH_DIR"
}
profile-share-scratch::verify() {
  profile-share-scratch::check
}

# --- profile-share-mount -----------------------------------------------------------
# A 10/8 share is reached over the private NIC: not through the default-route
# device, and that NIC carries no default route. A loopback share stays on lo.
_share_ip_ok() {
  local ip="$1" dev
  _share_ip_in_range "$ip" || return 1
  dev="$(ip -o route get "$ip" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
  if [[ "$ip" == 127.0.0.1 ]]; then
    [[ "$dev" == lo ]]
    return
  fi
  [[ -n "$dev" ]] || return 1
  ! ip -o route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | grep -qxF "$dev"
}

_ps_marker_domain() {
  timeout -k 5 20 jq -er '.domain | strings' "$PROFILE_SHARE_MOUNT/$PROFILE_SHARE_MARKER" 2>/dev/null
}

_ps_share_mounted_ok() {
  local info opts
  info="$(_ps_mountinfo "$PROFILE_SHARE_MOUNT")"
  [[ "$(cut -d' ' -f1,2 <<< "$info")" == "nfs4 $PROFILE_SHARE_EXPORT" ]] || return 1
  opts=",$(cut -d' ' -f3 <<< "$info"),"
  [[ "$opts" == *,vers=4.2,* && "$opts" == *,hard,* && "$opts" == *,nosuid,* && "$opts" == *,nodev,* && "$opts" == *,noexec,* ]]
}

_ps_share_ok() {
  _ps_block_is /etc/fstab "node-setup profile-share" "$(_ps_fstab_share)" \
    && _ps_share_mounted_ok \
    && [[ "$(_ps_marker_domain)" == "$PROFILE_SHARE_DOMAIN" ]] \
    && timeout -k 5 20 test -d "$PROFILE_SHARE_MOUNT/images" -a -d "$PROFILE_SHARE_MOUNT/probe"
}

# Claims an empty share with an exclusive create (noclobber is O_EXCL), so two
# nodes racing on a fresh share end up with one marker. A marker this run
# created but did not finish is removed again, so no node is left with an
# empty one.
_ps_write_marker() {
  local marker="$PROFILE_SHARE_MOUNT/$PROFILE_SHARE_MARKER" out rc=0
  # shellcheck disable=SC2016 # expanded by the inner bash and jq
  out="$(timeout -k 5 30 bash -c 'set -o noclobber; jq -cn --arg d "$1" --arg c "$2" --arg h "$3" "{domain:\$d,createdAt:\$c,createdBy:\$h}" > "$4"' \
    _ "$PROFILE_SHARE_DOMAIN" "$(date -u +%FT%TZ)" "$(hostname)" "$marker" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    [[ "$out" == *"Permission denied"* ]] && die "root squash on the share: root cannot create $marker"
    [[ "$out" == *"cannot overwrite existing file"* ]] && return 0
    timeout -k 5 20 rm -f "$marker" || true
    die "writing $marker failed (exit $rc): $out"
  fi
  timeout -k 5 20 chmod 0644 "$marker"
}

STEP_DESC["profile-share-mount"]="mount the region's profile share at $PROFILE_SHARE_MOUNT (NFSv4.2, hard), check its marker and layout"
profile-share-mount::check() {
  _ps_share_ok
}
profile-share-mount::apply() {
  local m="$PROFILE_SHARE_MOUNT" info domain entries host rc=0
  ensure_pkgs nfs-common
  _ps_mount_point "$m"
  _ps_fstab_share | replace_block /etc/fstab "node-setup profile-share" || true
  systemctl daemon-reload

  info="$(_ps_mountinfo "$m")"
  if [[ -z "$info" ]]; then
    retry 3 10 timeout -k 5 120 mount "$m" || die "mounting $PROFILE_SHARE_EXPORT at $m failed"
  fi
  _ps_share_mounted_ok \
    || die "$m is mounted from '$(_ps_mountinfo "$m")', not $PROFILE_SHARE_EXPORT with the fstab options; detach every profile and unmount it first"

  timeout -k 5 20 test -e "$m/$PROFILE_SHARE_MARKER" || rc=$?
  (( rc <= 1 )) || die "the share does not answer"
  if (( rc == 1 )); then
    entries="$(timeout -k 5 30 find "$m" -mindepth 1 -maxdepth 1 ! -name lost+found ! -name .snapshot -print -quit)" \
      || die "listing the share failed"
    [[ -z "$entries" ]] || die "the share has no $PROFILE_SHARE_MARKER but is not empty; refusing to claim it"
    _ps_write_marker
  fi
  domain="$(retry 3 5 _ps_marker_domain)" || die "$m/$PROFILE_SHARE_MARKER is not JSON with a domain"
  [[ "$domain" == "$PROFILE_SHARE_DOMAIN" ]] \
    || die "the share belongs to '$domain', this node is configured for '$PROFILE_SHARE_DOMAIN'"
  timeout -k 5 30 install -d -m 0700 "$m/images" "$m/probe"

  host="$(hostname)"
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "hostname '$host' is not usable in a probe path"
  # shellcheck disable=SC2016 # expanded by the inner bash
  timeout -k 5 30 bash -c 'dd if=/dev/zero of="$1" bs=4096 count=1 conv=fsync status=none && flock -n "$1" true && rm -f "$1"' \
    _ "$m/probe/.setup-$host" || die "the write, fsync and flock probe on the share failed"
}
profile-share-mount::verify() {
  _ps_share_ok && _share_ip_ok "${PROFILE_SHARE_EXPORT%%:*}"
}

# --- profile-share-units -----------------------------------------------------------
_ps_mount_service() {
  cat <<'EOF'
# Managed by node-setup (profile-share-units).
[Unit]
Description=Mount the saved-profile share when it is missing
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/browser-profile-share-ensure
EOF
}
_ps_mount_timer() {
  cat <<'EOF'
# Managed by node-setup (profile-share-units).
[Unit]
Description=Retry the saved-profile share mount

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}
_ps_detach_service() {
  cat <<'EOF'
# Managed by node-setup (profile-share-units): at shutdown every profile is
# detached before the share is unmounted.
[Unit]
Description=Detach saved profiles before the share goes away
After=docker.service remote-fs.target network-online.target
Wants=network-online.target
RequiresMountsFor=/mnt/browser-profiles

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/sbin/browser-profiles-detach
TimeoutStopSec=240

[Install]
WantedBy=multi-user.target
EOF
}
_ps_units_ok() {
  cmp -s "$PAYLOAD_DIR/profile-share-ensure.sh" /usr/local/sbin/browser-profile-share-ensure \
    && cmp -s "$PAYLOAD_DIR/profiles-detach.sh" /usr/local/sbin/browser-profiles-detach \
    && cmp -s <(_ps_mount_service) /etc/systemd/system/browser-profile-share-mount.service \
    && cmp -s <(_ps_mount_timer) /etc/systemd/system/browser-profile-share-mount.timer \
    && cmp -s <(_ps_detach_service) /etc/systemd/system/browser-profiles-detach.service \
    && systemctl is-enabled --quiet browser-profile-share-mount.timer \
    && systemctl is-active --quiet browser-profile-share-mount.timer \
    && systemctl is-enabled --quiet browser-profiles-detach.service
}

STEP_DESC["profile-share-units"]="share mount retry timer + shutdown unit that detaches every profile first"
profile-share-units::check() {
  _ps_units_ok && systemctl is-active --quiet browser-profiles-detach.service
}
profile-share-units::apply() {
  install -m 0755 "$PAYLOAD_DIR/profile-share-ensure.sh" /usr/local/sbin/browser-profile-share-ensure
  install -m 0755 "$PAYLOAD_DIR/profiles-detach.sh" /usr/local/sbin/browser-profiles-detach
  _ps_mount_service | write_if_changed /etc/systemd/system/browser-profile-share-mount.service || true
  _ps_mount_timer | write_if_changed /etc/systemd/system/browser-profile-share-mount.timer || true
  _ps_detach_service | write_if_changed /etc/systemd/system/browser-profiles-detach.service || true
  systemctl daemon-reload
  systemctl enable browser-profiles-detach.service >/dev/null
  # mount and arm the stop hook before the timer can race this run
  /usr/local/sbin/browser-profile-share-ensure
  systemctl enable --now browser-profile-share-mount.timer >/dev/null
}
profile-share-units::verify() {
  _ps_units_ok
}
