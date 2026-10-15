#!/bin/bash
# profiles-detach.sh - installed as /usr/local/sbin/browser-profiles-detach and
# run as ExecStop of browser-profiles-detach.service (node-setup
# profile-share-units), i.e. at shutdown before docker stops and before the
# profile share is unmounted. Stops every saved-profile session, flushes and
# unmounts every profile image, and frees their loop devices, so no image is
# left attached to a vanished NFS client. Scratch directories are left to the
# edge's reconcile. No errexit: every step is attempted, within about 120 s.
set -uo pipefail

SHARE_IMAGES=/mnt/browser-profiles/images/
SELFTEST_IMAGES=/var/lib/browser-profile-scratch/.selftest/
MOUNT_ROOTS=(/run/browser-profiles/profile/ /run/browser-profiles/selftest/)
LAZY_AFTER_S=100

log() { logger -t browser-profiles-detach "$*"; }

containers=0 unmounted=0 lazy=0 loops=0

mapfile -t ids < <(timeout 10 docker ps -aq --filter label=browser.lol.profile.id 2>/dev/null)
if (( ${#ids[@]} > 0 )); then
  containers=${#ids[@]}
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
    umount -l "$t" && lazy=$((lazy + 1))
    log "out of time: lazy unmount of $t"
    continue
  fi
  timeout -k 2 15 sync -f "$t" || log "sync of $t did not finish"
  if timeout -k 2 20 umount "$t"; then
    unmounted=$((unmounted + 1))
  else
    umount -l "$t" && lazy=$((lazy + 1))
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
