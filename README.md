# browser-setup

One-command, idempotent provisioning for the Browser / Guard cluster nodes.

Everything needed to turn a fresh Ubuntu/Debian box into a working cluster node
(k3s + Tailscale + Docker, role-specific hardening and services) lives here. It
is the single source of truth for node setup, used both for **manual**
provisioning and by the API's **automated burst-capacity** provisioner.

```bash
# a fresh prod worker (run from a checkout of this repo)
./provision.sh root@1.2.3.4 --role worker --tailscale-key tskey-auth-...

# gateway / control-plane / db node
./provision.sh root@1.2.3.4 --role gateway       --tailscale-key tskey-auth-...
./provision.sh root@1.2.3.4 --role control-plane --tailscale-key tskey-auth-... --manifests /path/to/k8s-manifests
./provision.sh root@1.2.3.4 --role db            --secrets-file ./secrets.env

# worker with optional modules (Hetzner iGPU, dying-disk tmpfs mitigation)
./provision.sh root@1.2.3.4 --role worker --modules gpu-intel,deadssd --tailscale-key ...

# fully guided (prompts for role/modules/secrets on the node)
./provision.sh root@1.2.3.4
```

Roles: `worker` `gateway` `control-plane` `db`.

> **Secrets live outside this repo.** This repository is public and ships **no
> credentials**. You supply the join token, registry credentials, and DB
> passwords at run time (see [Secrets](#secrets)). Auth keys and tokens are never
> committed here.

---

## Repository layout

```
provision.sh            one-command SSH provisioner (bundles setup/ + runs node-setup)
fleet.sh                run a command / node-setup doctor across every cluster node
setup/
  node-setup            the on-node CLI: check -> apply -> verify, journaled + resumable
  cluster.env           cluster-wide configuration (control-plane IP, DNS, exit-node, DB, UFW)
  versions.env          pinned versions (k3s exactly; docker/tailscale apt-held after install)
  lib/framework.sh      the step framework (idempotency, journal, reboot-resume, secrets)
  roles/                role step lists: worker.sh, gateway.sh, control-plane.sh, db.sh
  modules/              one file per capability (tailscale, docker, k3s-agent, ufw, ...)
  payloads/             scripts installed onto the node (watchdogs, exit-node routing)
tests/                  shell tests for the framework and role wiring
docs/                   deeper docs (architecture, secrets, automated provisioning)
```

## How it works

`provision.sh` streams `setup/` to the target over SSH, writes any secrets you
passed to `/etc/node-setup/secrets.env` (0600), and runs `node-setup`.

`node-setup` runs the role's ordered list of **steps**. Each step is a
`check` / `apply` / `verify` triple:

- **Idempotent + journaled.** Completed steps are recorded under
  `/var/lib/node-setup/state/`; re-running skips them. Editing a step or bumping
  `setup/versions.env` re-applies exactly the affected steps. Existing manual
  state is *adopted* (check passes -> marked done, nothing re-applied), so you
  can point it at a hand-built node without churn.
- **Reboot-resume.** Steps that need a reboot (e.g. `gpu-intel`) install a
  oneshot systemd unit; the run continues automatically after boot and cleans up
  after itself. A reboot-loop guard aborts instead of boot-cycling forever.
- **Fail fast, resume cheap.** A failing command aborts its step (each step runs
  under its own errexit); fix the cause and re-run to resume where it stopped.
- **Non-interactive by default in automation.** `--role worker --yes --server <ip>`
  skips every prompt; missing secrets are read from `/etc/node-setup/secrets.env`.

Verbs beyond provisioning:

```bash
node-setup doctor        # re-run every check/verify read-only, print a drift table
node-setup status        # identity (role/modules/server) + step journal
node-setup --dry-run     # print the plan without changing anything
./fleet.sh doctor        # node-setup doctor across the whole cluster
./fleet.sh list          # nodes with IPs, labels, status
```

## Roles

| Role | What it becomes | Notable steps |
|------|-----------------|---------------|
| `worker` | k3s agent running browser workspaces via Docker | tailscale, docker, k3s-agent, ufw (80/443), flannel-watchdog, oom-guards, exit-node routing |
| `gateway` | public-facing k3s agent | as worker, public 80/443 |
| `control-plane` | k3s server (single-node sqlite datastore) + services | k3s-server, registry secret, applies the services manifest (`--manifests`) |
| `db` | PostgreSQL host | postgres (databases + roles + pg_hba), ufw |

Role step lists are plain arrays in `setup/roles/*.sh`; modules are defined once
in `setup/modules/` and reused across roles. See [docs/ROLES.md](docs/ROLES.md).

## Configuration: `setup/cluster.env`

Cluster-wide settings sourced by `node-setup` before roles/modules run: the
default control-plane Tailscale IP (`--server` overrides it per run), the k3s
datastore + secrets-encryption flags, CoreDNS DaemonSet, worker exit-node
routing, the DB major version + database list, and UFW trusted sources / public
ports per role.

This repo ships **`setup/cluster.env.example`** (a template with placeholder IPs
and generic defaults), not a real `cluster.env` - per-deployment specifics stay
out of a public repo. Provide your real config one of two ways:

- `provision.sh --cluster-env /path/to/cluster.env` ships it into the bundle, or
- copy `setup/cluster.env.example` to `setup/cluster.env` and fill it in.

If neither is present, `node-setup` falls back to the template so a bare checkout
still runs; placeholder values only fail a step that actually uses them (e.g. a
control-plane run needs the real `K3S_SERVER_IP`, but a worker with `--server`
does not).

## Secrets

Supply secrets at run time - never commit them here. `provision.sh` accepts:

| Flag | Use |
|------|-----|
| `--tailscale-key tskey-...` | sets `TS_AUTHKEY` (tailscale join; expires, pass per run) |
| `--k3s-token <token>` | sets `K3S_TOKEN` (cluster join token) |
| `--secrets-file <path>` | a `KEY=VALUE` file merged into `secrets.env` |
| `--secrets-stdin` | read the same `KEY=VALUE` content from stdin |
| *(none)* | `node-setup` prompts on the node for what each step needs |

Which secrets each role needs:

- **worker / gateway:** `TS_AUTHKEY`, `K3S_TOKEN`
- **control-plane:** `K3S_TOKEN`, `REGISTRY_SERVER/USER/PASSWORD/EMAIL`
- **db:** `PG_BROWSER_PASSWORD`, `PG_GUARD_PASSWORD`

`node-setup` reads `/etc/node-setup/secrets.env` and **shreds it on completion**.
If you keep secrets in an encrypted store, pipe them in:

```bash
my-secret-tool show prod | ./provision.sh root@1.2.3.4 --role worker \
  --secrets-stdin --tailscale-key tskey-auth-...
```

See [docs/SECRETS.md](docs/SECRETS.md) for the full contract.

## Automated / burst provisioning

The Browser API provisions temporary Hetzner workers on capacity spikes by
booting a stock Debian image whose **cloud-init fetches this repo's tarball**,
writes an inline `secrets.env`, and runs `node-setup --role worker --yes`. The
node then self-registers with the control plane. Nothing about this repo is
burst-specific - burst is just one caller of the same `node-setup`. See
[docs/AUTOMATED-PROVISIONING.md](docs/AUTOMATED-PROVISIONING.md).

## Durability / failure-mode coverage

- **Pinned versions.** `setup/versions.env` pins k3s exactly; docker + tailscale
  are apt-held after install so unattended upgrades can never restart them (a
  tailscaled restart wedges flannel; a dockerd restart kills workspaces).
  Upgrades are deliberate: bump the pin / unhold, re-run.
- **flannel-watchdog.** The historical "tailscale restarted and the k3s network
  died" outage is covered end to end (`setup/payloads/flannel-watchdog.sh`).
- **oom-guards / hw-watchdog / disk-guard.** Keep a node up under memory
  pressure, hardware faults, and dying disks (`deadssd` module for tmpfs
  mitigation).

## Tests

```bash
tests/test-framework.sh   # step framework: idempotency, journal, resume
tests/test-roles.sh       # role wiring: every role's steps resolve to modules
```

## License

Internal tooling, published for transparency and reuse. No warranty.
