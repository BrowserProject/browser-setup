#!/bin/bash
# profiles-detach.sh - installed as /usr/local/sbin/browser-profiles-detach and
# run as ExecStop of browser-profiles-detach.service (node-setup
# profile-share-units), i.e. at shutdown before docker stops and before the
# profile share is unmounted. Ends every saved-profile browser the way a close
# does (drain-profile, so its last writes are flushed), stops the sessions,
# unmounts every profile image and frees their loop devices, so no image is
# left attached to a vanished NFS client. Scratch directories are left to the
# edge's reconcile. No errexit: every step is attempted, within about 230 s.
set -uo pipefail

SHARE_IMAGES=/mnt/browser-profiles/images/
SELFTEST_IMAGES=/var/lib/browser-profile-scratch/.selftest/
MOUNT_ROOTS=(/run/browser-profiles/profile/ /run/browser-profiles/selftest/)
LAZY_AFTER_S=190
# The drains run in parallel; drain-profile bounds itself at 85 s.
DRAIN_LIMIT_S=95
# mirrored from containers/base/root/opt/scripts/drain-profile (its profile id rule). Keep in sync.
PROFILE_ID_RE='^[a-f0-9-]{16,64}$'

log() { logger -t browser-profiles-detach "$*"; }

# Runs a command and waits at most <seconds> for it, never blocking on one stuck in D state on
# a hung share (that one is left behind): 124 when the limit hit, else its exit status.
bounded() { # seconds command...
  local limit=$1 start=$SECONDS pid state
  shift
  "$@" &
  pid=$!
  while :; do
    state="$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null)"
    [[ -z "$state" || "$state" == Z ]] && break
    if (( SECONDS - start >= limit )); then
      kill -9 "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
  done
  wait "$pid"
}

containers=0 unmounted=0 lazy=0 loops=0

mapfile -t ids < <(timeout 10 docker ps -aq --filter label=browser.lol.profile.id 2>/dev/null)
if (( ${#ids[@]} > 0 )); then
  containers=${#ids[@]}
  log "draining $containers profile containers"
  for id in "${ids[@]}"; do
    profile="$(timeout 5 docker inspect -f '{{index .Config.Labels "browser.lol.profile.id"}}' "$id" 2>/dev/null)"
    [[ "$profile" =~ $PROFILE_ID_RE ]] || continue
    timeout -k 2 "$DRAIN_LIMIT_S" docker exec "$id" /opt/scripts/drain-profile "$profile" >/dev/null 2>&1 &
  done
  wait
  log "stopping $containers profile containers"
  timeout 30 docker stop -t 10 "${ids[@]}" >/dev/null 2>&1 || log "docker stop did not finish cleanly"
  timeout 20 docker rm -f "${ids[@]}" >/dev/null 2>&1 || log "docker rm did not finish cleanly"
fi

# deepest first, so a nested mount never pins its parent
mapfile -t mounts < <(awk '{ print $5 }' /proc/self/mountinfo | while read -r t; do
  for root in "${MOUNT_ROOTS[@]}"; do
    [[ "$t" == "$root"* ]] && printf '%s %s\n' "$(tr -cd / <<< "$t" | wc -c)" "$t"
  done
done | sort -rn | cut -d' ' -f2-)
for t in "${mounts[@]}"; do
  if (( SECONDS >= LAZY_AFTER_S )); then
    bounded 5 umount -l "$t" && lazy=$((lazy + 1))
    log "out of time: lazy unmount of $t"
    continue
  fi
  bounded 15 sync -f "$t" || log "sync of $t did not finish"
  if bounded 20 umount "$t"; then
    unmounted=$((unmounted + 1))
  else
    bounded 5 umount -l "$t" && lazy=$((lazy + 1))
    log "lazy unmount of $t"
  fi
done

for sys in /sys/block/loop*/loop/backing_file; do
  [[ -r "$sys" ]] || continue
  back="$(cat "$sys" 2>/dev/null)"
  [[ "$back" == "$SHARE_IMAGES"* || "$back" == "$SELFTEST_IMAGES"* ]] || continue
  dev="/dev/$(basename "$(dirname "$(dirname "$sys")")")"
  findmnt -rn -S "$dev" >/dev/null 2>&1 && continue
  losetup -d "$dev" 2>/dev/null && loops=$((loops + 1))
done

log "done in ${SECONDS}s: containers=$containers unmounted=$unmounted lazy=$lazy loops-freed=$loops"
exit 0
