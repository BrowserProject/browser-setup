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
tailscale-install tailscale-up[boot]
docker-install docker-daemon-config
ufw-rules session-isolation
k3s-agent-preinstall[bake] k3s-agent-install[boot]
flannel-watchdog oom-guards net-limits hw-watchdog disk-guard
browser-images-prefetch[bake]
[exitnode-routing]          # when EXITNODE_ROUTING=1 in cluster.env
```

Optional modules: `deadssd` (tmpfs mitigation for a dying disk), `direct-egress` (worker
sessions leave through the node's own address: replaces `exitnode-routing`,
keeps its sysctl tuning, clears any exit node).

Node labels come from `WORKER_NODE_LABELS` in `cluster.env` (empty by default);
k3s applies them when the worker registers, so a later edit does not relabel a
worker that already joined.

### Disk images (`--prepare`, `seal`)

The worker is the one preparable role (`ROLE_PREPARABLE=1`). A step marked
`boot` needs a secret or the node's identity, a step marked `bake` exists only
to build an image; unmarked steps run in both phases.

```bash
# on a fresh VM, with the bundle and cluster.env the nodes will boot with
node-setup --role worker --prepare --yes --server <control-plane-ip> [--modules ...]
node-setup seal --poweroff        # then snapshot the stopped disk

# on a node booted from the snapshot: the usual command
node-setup --role worker --yes --server <control-plane-ip> [--modules ...]
```

- `--prepare` skips `tailscale-up` and `k3s-agent-install` and runs the bake
  steps. `k3s-agent-preinstall` caches `get.k3s.io` at
  `/usr/local/lib/node-setup/k3s-install.sh` and installs the pinned binary
  with a disabled `k3s-agent` unit and no join value, so `flannel-watchdog`
  and `oom-guards` put their k3s-agent drop-ins into the image.
  `browser-images-prefetch` pulls `BAKE_IMAGES` (see below); without
  `BAKE_IMAGES` it pulls nothing.
- Every step a prepare run applies is journaled with the same hash a later
  normal run computes, as long as the bundle, `versions.env`, `cluster.env`
  and `--server` are the same. A node booted from the image then applies
  `tailscale-up` and `k3s-agent-install` (which reuses the cached installer
  and binary), re-applies whatever drifted (`base-time` before NTP syncs,
  `base-ssh-harden` where cloud-init restricts the root key) and skips the
  rest. With another bundle or `cluster.env`, steps with a `check` adopt and
  steps without one re-apply; the image still saves the downloads.
- `seal` refuses, changing nothing, while the disk holds an identity or a
  secret: tailscale logged in, `k3s-agent` active or enabled or registered, a
  join token in its env file, any container, `secrets.env`, a registry login,
  a `/opt/burst-*.sh` script, a file under `/etc/node-setup`, `/root` or `/opt`
  (the bundle aside) assigning `REGISTRY_PASSWORD`, `TS_AUTHKEY` or
  `K3S_TOKEN`, an unfinished run, a package `dpkg --audit` lists, or a
  prepare step missing from the journal. Then it stops the apt timers and
  `unattended-upgrades`, waits until apt and dpkg are idle (still busy after
  10 minutes: it stops, nothing removed), writes
  `/etc/node-setup/image.env`, wipes the tailscale state, the
  docker engine id, SSH host keys, authorized keys, shell history, apt lists,
  rotated logs, the journal's transient files (keeping `state/*.hash`) and the
  ufw SSH lockout guard rules, and runs `cloud-init clean --logs --seed
  --machine-id`, so each clone gets its own machine id, keys and tailnet node.
- `seal` takes no flag but `--poweroff`: it cannot be previewed (`--dry-run`
  would still seal) or narrowed (`--only`/`--skip`), and acts on the role
  and journal the prepare run left.

`BAKE_IMAGES` (in `secrets.env`, space separated) names each image by the
reference the edge uses: the environment's browser catalog and the helper
images its edge pulls. A reference with a registry host must name
`REGISTRY_SERVER` or a mirror of it (the same repositories, keys of its own);
it is pulled through `REGISTRY_SERVER` with `REGISTRY_USER`/`REGISTRY_PASSWORD`
and, for a mirror, tagged back to the reference. Docker cannot tag a digest,
so a digest reference works only on `REGISTRY_SERVER` itself; the step
refuses any other. Public images go in as host-less Docker Hub references
(`curlimages/curl:8.22.0`), pulled anonymously. The login lives on tmpfs for
the pulls only, like the scripts every step runs from.

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
- `STEP_PHASE["step"]=boot|bake` for a step that belongs to one phase (see
  [Disk images](#disk-images---prepare-seal)); unset runs in both.

Steps must be **idempotent**: `check` returns 0 when the desired state already
holds (so a hand-built node is adopted without re-applying), `apply` makes it so,
`verify` confirms it after `apply`.

A step runs in a fresh bash process that receives every variable and function
of the run; results travel back through files. Its journal hash covers the
text of its `check`, `apply` and `verify`, `versions.env` and `cluster.env`, not
helper functions or payload files: a change there re-applies only through a
failing `check`.
