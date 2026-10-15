# Roles and modules

A **role** is an ordered list of **steps**; a **module** defines one or more
steps (`check` / `apply` / `verify`). Roles live in `setup/roles/*.sh` as plain
arrays; modules live in `setup/modules/*.sh`. `node-setup` runs the role's steps
in order, skipping any already recorded as done in `/var/lib/node-setup/state/`.

## Adding to a role

Append the step name to the role's `ROLE_STEPS` array (and, for a new
capability, add a `setup/modules/<name>.sh` defining
`STEP_DESC["x"]`, `x::check`, `x::apply`, `x::verify`). Optional per-run modules
are opted in with `--modules a,b`.

## worker

k3s agent that runs browser workspaces via Docker.

```
base-packages base-time base-journald base-unattended base-ssh-harden
swap-disable session-limits
tailscale-install tailscale-up
docker-install docker-daemon-config
ufw-rules session-isolation
k3s-agent-install
flannel-watchdog oom-guards net-limits hw-watchdog disk-guard
[exitnode-routing]          # when EXITNODE_ROUTING=1 in cluster.env
```

Optional modules: `deadssd` (tmpfs mitigation for a dying disk), `direct-egress` (worker
sessions leave through the node's own address: replaces `exitnode-routing`,
keeps its sysctl tuning, clears any exit node), `alt-tailscale-port` (tailscaled on UDP
41700 instead of 41641, right after `tailscale-up`, for providers whose DDoS filter drops
WireGuard on 41641; ZAP-Hosting does), `profile-share` (premium workers: the
saved-profile share, see below) and `profile-share-server` (beta-w1 only, needs
`profile-share`).

With `profile-share`, these steps run before `k3s-agent-install`, so the edge
never starts on a node without its share:

```
profile-share-kernel profile-share-scratch [profile-share-export] profile-share-mount profile-share-units
```

Node labels come from `WORKER_NODE_LABELS` in `cluster.env` (empty by default);
k3s applies them when the worker registers, so a later edit does not relabel a
worker that already joined.

### Saved-profile share (`profile-share`, `profile-share-server`)

Premium workers keep every saved profile of their region as one ext4 image on
the region's NFS share; the edge attaches an image through its tool container
on the node that runs the session. The module prepares the node for that.

mirrored from infra/profile-share/README.md#contract. Keep in sync.
(The contract lives in the platform repository; this is the node part.)

| Item | Value |
|------|-------|
| Inputs | `PROFILE_SHARE_EXPORT` `^(10(\.[0-9]{1,3}){3}\|127\.0\.0\.1):/[A-Za-z0-9/._-]{1,200}$`, outside 10.42/16 and 10.43/16; `PROFILE_SHARE_DOMAIN` `^(prod\|beta)-location-[1-9][0-9]{0,9}$` (formatted only by the API); `PROFILE_SCRATCH_GIB` 4-256, default 24; `PROFILE_SHARE_SERVER_GIB` 8-1024, default 40 (server only). Validated before any step, `--dry-run` included. Keep them in `cluster.env` |
| Share | Mounted at `/mnt/browser-profiles` (fixed). fstab: `<export> /mnt/browser-profiles nfs4 vers=4.2,hard,proto=tcp,timeo=600,retrans=2,rsize=1048576,wsize=1048576,nosuid,nodev,noexec,_netdev,nofail,x-systemd.mount-timeout=120s 0 0`. No `noresvport`, no `nconnect`. The empty mount point is `chattr +i` |
| Marker | `/mnt/browser-profiles/.browser-profile-share.json`, 0644, `{"domain","createdAt","createdBy"}`. Written once by this module on an empty share (O_EXCL), then re-read; a share with another domain, or a non-empty share without a marker, stops the run |
| Layout | `images/<id>.img` (0700 dir), `probe/` (0700) |
| Kernel | `/etc/modprobe.d/browser-profiles.conf` `options nfs recover_lost_locks=0 nfs4_unique_id=<machine-id>`, verified live in `/sys/module/nfs/parameters/`; `/etc/modules-load.d/browser-profiles.conf` `loop`, `nfs`; `kernel.hung_task_panic=0`; `/run` propagation `shared`; kernel >= 5.8; tmpfiles `/run/browser-profiles/{profile,selftest}` 0700 |
| Scratch | `/var/lib/browser-profile-scratch.img`, `PROFILE_SCRATCH_GIB`, fully allocated, `mkfs.ext4 -F -q -m 0 -L brl-scratch -E nodiscard`; fstab `/var/lib/browser-profile-scratch.img /var/lib/browser-profile-scratch ext4 loop,nosuid,nodev,noatime,nofail,X-fstrim.notrim,x-systemd.before=docker.service 0 2`; root 0700. Node-wide bound for browser caches |
| Server (beta) | `/var/lib/browser-profile-share.img`, `PROFILE_SHARE_SERVER_GIB`, fully allocated, label `brl-share`, fstab `... /srv/browser-profile-share ext4 loop,nosuid,nodev,noatime,nofail,X-fstrim.notrim 0 2`; export `/srv/browser-profile-share 127.0.0.1(rw,sync,no_subtree_check,no_root_squash,sec=sys)`; `[nfsd] host=127.0.0.1 vers3=n vers4.0=n vers4.1=y vers4.2=y lease-time=90 grace-time=90`. Requires `PROFILE_SHARE_EXPORT=127.0.0.1:/srv/browser-profile-share` |
| Disk gate | `df -B1G --output=avail /var/lib` >= the images still to create + 20 GiB, before any image is created (a dry run only warns). Images are fixed: a size change is refused, resizing is manual |
| Units | `browser-profile-share-mount.timer` (30 s after boot, then every 60 s) mounts a missing share; `browser-profiles-detach.service` stops the profile containers, unmounts every profile and frees its loop at shutdown, before the share goes (`TimeoutStopSec=150`) |

`verify` also asserts the network: a 10/8 share is not reached through the
default-route device, and the NIC that reaches it has no default route; a
loopback share stays on `lo`.

**Trust boundary.** Root on any premium node of a region can read and write
every image of that region. Containers cannot reach the share (the session
isolation denies 10/8 and 127/8). The kernel's own checks at mount, and
`e2fsck` when the superblock records errors, are the only checks on an image
another node wrote.

## gateway

Public-facing agent; same shape as `worker` with public 80/443.

## control-plane

k3s **server** (single-node sqlite datastore) plus cluster services.

```
base-* swap-disable tailscale-install tailscale-up docker-install ...
k3s-server-install
k3s-registry-secret         # creates the registry pull secret + credentials
apply-services-manifest     # from the bundle's manifests/ (pass --manifests <dir>)
```

The services manifest is **not** in this repo (it carries app secrets); pass it
with `provision.sh --manifests <dir>` for a control-plane run.

## db

PostgreSQL host.

```
base-* tailscale-install tailscale-up
postgres-install            # PG_MAJOR from cluster.env
postgres-databases          # PG_DATABASES + roles, pg_hba (scram-sha-256, tailnet/private only)
ufw-rules
```

## The step framework (`lib/framework.sh`)

Helpers available to every module:

- `require_secrets NAME...` - fail (or prompt, interactively) if a secret is
  missing from `/etc/node-setup/secrets.env`.
- `svc_enable_now <unit>` - enable + start a systemd unit.
- `retry <n> <delay> cmd...`, `wait_for <timeout> <interval> cmd...`.
- `ts_ip` - this node's Tailscale IP (workers join k3s on it).
- `log` / `warn` / `err` / `die`, and `STEP_DESC["step"]="..."` for the plan.

Steps must be **idempotent**: `check` returns 0 when the desired state already
holds (so a hand-built node is adopted without re-applying), `apply` makes it so,
`verify` confirms it after `apply`.

A step runs in a fresh bash process that receives every variable and function
of the run; results travel back through files. Its journal hash covers the
text of its `check`, `apply` and `verify`, `versions.env` and `cluster.env`, not
helper functions or payload files: a change there re-applies only through a
failing `check`.
