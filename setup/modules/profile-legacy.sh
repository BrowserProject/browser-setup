# profile-legacy.sh - removes what the retired saved-profile engine (nydus
# layers, then S3 snapshots on an XFS prjquota root) left on a worker: its
# rshared root unit, its node bundle, its env file with the bucket credentials,
# the root's mount and fstab line, and the migration's work directory in the
# scratch. Data is never deleted: a non-empty root, the XFS image or a
# non-empty work directory is reported and left for a human.
# shellcheck shell=bash

PROFILE_LEGACY_UNIT=browser-profile-root.service
PROFILE_LEGACY_UNIT_DIR=/etc/systemd/system
PROFILE_LEGACY_ROOT=/var/lib/browser-profiles
PROFILE_LEGACY_IMG=/var/lib/browser-profiles.img
PROFILE_LEGACY_INFRA=/opt/browser-infra
PROFILE_LEGACY_ENV=/etc/browser-profile-storage.env
PROFILE_LEGACY_MIGRATE=/var/lib/browser-profile-scratch/.migrate
PROFILE_LEGACY_FSTAB=/etc/fstab

_pl_mounts() { # every mount at or below the root
  awk -v r="$PROFILE_LEGACY_ROOT" '$5 == r || index($5, r "/") == 1 { print $5 }' /proc/self/mountinfo
}
_pl_fstab_lines() {
  awk -v r="$PROFILE_LEGACY_ROOT" '$1 !~ /^#/ && $2 == r' "$PROFILE_LEGACY_FSTAB" 2>/dev/null
}
_pl_empty_dir() {
  [[ -d "$1" && ! -L "$1" && -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}
_pl_env_files() {
  local f
  for f in "$PROFILE_LEGACY_ENV" "$PROFILE_LEGACY_ENV".bak-*; do
    if [[ -e "$f" || -L "$f" ]]; then echo "$f"; fi
  done
}
_pl_unit_present() {
  local unit="$PROFILE_LEGACY_UNIT_DIR/$PROFILE_LEGACY_UNIT"
  [[ -e "$unit" || -L "$unit" || -e "$unit.d" ]] \
    || [[ -n "$(find "$PROFILE_LEGACY_UNIT_DIR" -mindepth 2 -maxdepth 2 -path '*.wants/*' -name "$PROFILE_LEGACY_UNIT" -print -quit 2>/dev/null)" ]] \
    || systemctl is-active --quiet "$PROFILE_LEGACY_UNIT"
}

# What apply removes, one line each.
_pl_removable() {
  _pl_unit_present && echo "unit $PROFILE_LEGACY_UNIT"
  [[ -e "$PROFILE_LEGACY_INFRA/profile-storage" ]] && echo "$PROFILE_LEGACY_INFRA/profile-storage"
  _pl_empty_dir "$PROFILE_LEGACY_INFRA" && echo "empty $PROFILE_LEGACY_INFRA"
  _pl_env_files
  [[ -n "$(_pl_fstab_lines)" ]] && echo "fstab line for $PROFILE_LEGACY_ROOT"
  [[ -z "$(_pl_mounts)" ]] && _pl_empty_dir "$PROFILE_LEGACY_ROOT" && echo "empty $PROFILE_LEGACY_ROOT"
  _pl_empty_dir "$PROFILE_LEGACY_MIGRATE" && echo "empty $PROFILE_LEGACY_MIGRATE"
  return 0
}

# What holds data or is busy and stays for a human, one line each.
_pl_kept() {
  local m
  while read -r m; do
    [[ -n "$m" ]] && echo "$m is still mounted"
  done < <(_pl_mounts)
  if [[ -z "$(_pl_mounts)" && -e "$PROFILE_LEGACY_ROOT" ]] && ! _pl_empty_dir "$PROFILE_LEGACY_ROOT"; then
    echo "$PROFILE_LEGACY_ROOT is not empty"
  fi
  [[ -e "$PROFILE_LEGACY_IMG" ]] && echo "$PROFILE_LEGACY_IMG still exists"
  if [[ -e "$PROFILE_LEGACY_MIGRATE" ]] && ! _pl_empty_dir "$PROFILE_LEGACY_MIGRATE"; then
    echo "$PROFILE_LEGACY_MIGRATE is not empty"
  fi
  return 0
}

STEP_DESC["profile-legacy-cleanup"]="remove the retired saved-profile engine (root unit, bundle, S3 env file, XFS root mount); report what holds data"
profile-legacy-cleanup::check() {
  [[ -z "$(_pl_removable)" && -z "$(_pl_kept)" ]]
}
profile-legacy-cleanup::apply() {
  local root="$PROFILE_LEGACY_ROOT" unit="$PROFILE_LEGACY_UNIT_DIR/$PROFILE_LEGACY_UNIT" f tmp i what

  if _pl_unit_present; then
    # its stop refuses, and keeps the bind, while anything is mounted below the root
    if systemctl is-active --quiet "$PROFILE_LEGACY_UNIT"; then
      systemctl stop "$PROFILE_LEGACY_UNIT" || warn "stopping $PROFILE_LEGACY_UNIT failed; removing it anyway"
    fi
    systemctl disable "$PROFILE_LEGACY_UNIT" >/dev/null 2>&1 || true
    find "$PROFILE_LEGACY_UNIT_DIR" -mindepth 2 -maxdepth 2 -path '*.wants/*' -name "$PROFILE_LEGACY_UNIT" -delete
    rm -rf "$unit" "$unit.d"
    systemctl daemon-reload
    systemctl reset-failed "$PROFILE_LEGACY_UNIT" >/dev/null 2>&1 || true
  fi

  # the unit's bind and the XFS stack at the root; mounts below it belong to a human
  if [[ "$(_pl_mounts | grep -cvxF "$root")" != 0 ]]; then
    warn "mounts remain below $root; leaving $root mounted"
  else
    for i in 1 2 3 4; do
      [[ -n "$(_pl_mounts)" ]] || break
      umount "$root" || { warn "unmounting $root failed (attempt $i)"; break; }
    done
  fi

  if [[ -n "$(_pl_fstab_lines)" ]]; then
    tmp="$(mktemp)"
    awk -v r="$root" '$1 ~ /^#/ || $2 != r' "$PROFILE_LEGACY_FSTAB" > "$tmp"
    cat "$tmp" > "$PROFILE_LEGACY_FSTAB"
    rm -f "$tmp"
    systemctl daemon-reload
  fi
  if [[ -z "$(_pl_mounts)" ]] && _pl_empty_dir "$root"; then
    rmdir "$root"
  fi

  rm -rf "${PROFILE_LEGACY_INFRA:?}/profile-storage"
  if _pl_empty_dir "$PROFILE_LEGACY_INFRA"; then
    rmdir "$PROFILE_LEGACY_INFRA"
  fi
  # the env file held the bucket credentials
  while read -r f; do
    if [[ -f "$f" && ! -L "$f" ]]; then
      shred -u "$f" 2>/dev/null || rm -f "$f"
    else
      rm -rf "$f"
    fi
  done < <(_pl_env_files)
  if _pl_empty_dir "$PROFILE_LEGACY_MIGRATE"; then
    rmdir "$PROFILE_LEGACY_MIGRATE"
  fi

  while read -r what; do
    warn "old profile engine: $what; left in place for a human"
  done < <(_pl_kept)
}
profile-legacy-cleanup::verify() {
  [[ -z "$(_pl_removable)" ]]
}
