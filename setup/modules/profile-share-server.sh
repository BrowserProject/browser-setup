# profile-share-server.sh - beta only (beta-w1): serves the saved-profile share
# from a fixed, fully allocated local ext4 image over loopback NFSv4.1/4.2, so
# the node's own profile-share mount behaves like the OVH share in prod.
# Requires the profile-share module (helpers and inputs live there).
# shellcheck shell=bash

PROFILE_SHARE_SERVER_IMG=/var/lib/browser-profile-share.img
PROFILE_SHARE_SERVER_DIR=/srv/browser-profile-share
PROFILE_SHARE_SERVER_EXPORT="127.0.0.1:$PROFILE_SHARE_SERVER_DIR"

_ps_fstab_export() {
  echo "$PROFILE_SHARE_SERVER_IMG $PROFILE_SHARE_SERVER_DIR ext4 loop,nosuid,nodev,noatime,nofail,X-fstrim.notrim 0 2"
}
_ps_nfsd_conf() {
  printf '# Managed by node-setup (profile-share-export): NFSv4.1+ on loopback only.\n'
  printf '[nfsd]\nhost=127.0.0.1\nvers3=n\nvers4.0=n\nvers4.1=y\nvers4.2=y\nlease-time=90\ngrace-time=90\n'
}
_ps_nfsd_dropin() {
  printf '# Managed by node-setup (profile-share-export): export only the mounted image; stop after the client unmounts.\n'
  printf '[Unit]\nRequiresMountsFor=%s\nBefore=remote-fs-pre.target\n' "$PROFILE_SHARE_SERVER_DIR"
}
_ps_exports_line() {
  echo "$PROFILE_SHARE_SERVER_DIR 127.0.0.1(rw,sync,no_subtree_check,no_root_squash,sec=sys)"
}
# shellcheck disable=SC2153 # PROFILE_SHARE_SERVER_GIB is set by profile_share_configure
_ps_export_ok() {
  local exported listeners
  _ps_block_is /etc/fstab "node-setup profile-share-export" "$(_ps_fstab_export)" \
    && _ps_block_is /etc/exports "node-setup profile-share-export" "$(_ps_exports_line)" \
    && cmp -s <(_ps_nfsd_conf) /etc/nfs.conf.d/browser-profile-share.conf \
    && cmp -s <(_ps_nfsd_dropin) /etc/systemd/system/nfs-server.service.d/browser.conf \
    && _ps_image_ok "$PROFILE_SHARE_SERVER_IMG" "$PROFILE_SHARE_SERVER_GIB" "$PROFILE_SHARE_SERVER_DIR" \
    && systemctl is-active --quiet nfs-server \
    && [[ "$(nfsconf --get nfsd lease-time)" == 90 ]] \
    && [[ "$(cat /proc/fs/nfsd/nfsv4leasetime 2>/dev/null)" == 90 ]] \
    || return 1
  exported="$(exportfs -s | awk -v d="$PROFILE_SHARE_SERVER_DIR" '$1 == d {print $2}')"
  [[ "$exported" == "127.0.0.1("*")" && "$exported" == *[\(,]rw[,\)]* && "$exported" == *no_root_squash* ]] || return 1
  listeners="$(ss -ltnH 'sport = :2049' | awk '{print $4}' | sort -u)"
  [[ "$listeners" == 127.0.0.1:2049 ]]
}

STEP_DESC["profile-share-export"]="serve the profile share from a fixed local image over loopback NFSv4.1/4.2 (beta)"
profile-share-export::check() {
  _ps_export_ok
}
profile-share-export::apply() {
  local restart=0
  # configured before the package install starts nfsd for the first time
  _ps_nfsd_conf | write_if_changed /etc/nfs.conf.d/browser-profile-share.conf && restart=1
  ensure_pkgs nfs-kernel-server
  _ps_image "$PROFILE_SHARE_SERVER_IMG" "$PROFILE_SHARE_SERVER_GIB" brl-share
  _ps_mount_point "$PROFILE_SHARE_SERVER_DIR"
  _ps_fstab_export | replace_block /etc/fstab "node-setup profile-share-export" || true
  systemctl daemon-reload
  [[ -n "$(_ps_mountinfo "$PROFILE_SHARE_SERVER_DIR")" ]] || mount "$PROFILE_SHARE_SERVER_DIR"
  _ps_image_ok "$PROFILE_SHARE_SERVER_IMG" "$PROFILE_SHARE_SERVER_GIB" "$PROFILE_SHARE_SERVER_DIR" \
    || die "$PROFILE_SHARE_SERVER_DIR is mounted from something other than $PROFILE_SHARE_SERVER_IMG; unmount it first"
  chmod 0711 "$PROFILE_SHARE_SERVER_DIR"
  _ps_nfsd_dropin | write_if_changed /etc/systemd/system/nfs-server.service.d/browser.conf && restart=1
  _ps_exports_line | replace_block /etc/exports "node-setup profile-share-export" || true
  svc_enable_now nfs-server
  # nfsd takes its lease and grace time only when it starts
  [[ "$restart" == 1 ]] && systemctl restart nfs-server
  exportfs -ra
}
profile-share-export::verify() {
  _ps_export_ok
}
