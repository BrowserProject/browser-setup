#!/bin/bash
# profile-share-ensure.sh - installed as /usr/local/sbin/browser-profile-share-ensure
# and run by browser-profile-share-mount.timer (node-setup profile-share-units).
# Mounts the saved-profile share when it is missing (the boot mount is nofail),
# then arms browser-profiles-detach.service, whose stop hook detaches every
# profile before the share is unmounted. Idempotent.
set -uo pipefail

SHARE=/mnt/browser-profiles

# mountinfo only: never touch a share that may hang
mounted() { awk -v t="$SHARE" '$5 == t { f = 1 } END { exit !f }' /proc/self/mountinfo; }

if ! mounted; then
  if ! timeout -k 5 120 mount "$SHARE"; then
    logger -p user.err -t browser-profile-share "mounting $SHARE failed; retrying on the next timer run"
    exit 1
  fi
  logger -t browser-profile-share "mounted $SHARE"
fi
systemctl start browser-profiles-detach.service
