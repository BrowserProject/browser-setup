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
keeps its sysctl tuning, clears any exit node).

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
