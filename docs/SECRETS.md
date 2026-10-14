# Secrets contract

This repository is **public and contains no credentials**. Secrets are supplied
at provisioning time and only ever exist on the node in a transient
`/etc/node-setup/secrets.env` (mode 0600) that `node-setup` **shreds on
completion**.

## What each role needs

| Secret | Roles | Purpose |
|--------|-------|---------|
| `TS_AUTHKEY` | worker, gateway, control-plane, db | Tailscale join key (expires; pass one per run) |
| `K3S_TOKEN` | worker, gateway, control-plane | k3s cluster join token |
| `REGISTRY_SERVER` `REGISTRY_USER` `REGISTRY_PASSWORD` `REGISTRY_EMAIL` | control-plane | private image registry pull secret |
| `REGISTRY_SERVER` `REGISTRY_USER` `REGISTRY_PASSWORD`, `BAKE_IMAGES` | worker `--prepare` | pull-only registry key and the image list of a browser image bake (`browser-images-prefetch`); `BAKE_IMAGES` is not secret |
| `PG_BROWSER_PASSWORD` `PG_GUARD_PASSWORD` | db | PostgreSQL role passwords |

A `--prepare` run (disk image bake) needs no `TS_AUTHKEY` and no `K3S_TOKEN`:
the steps that use them run when a node boots from the image. `node-setup seal`
refuses to seal a disk that still holds `secrets.env`, a registry login or any
file outside the bundle assigning `REGISTRY_PASSWORD`, `TS_AUTHKEY` or
`K3S_TOKEN`.

`TS_AUTHKEY` is deliberately never stored anywhere at rest - generate one per run
at <https://login.tailscale.com/admin/settings/keys> (or mint an ephemeral key
via the Tailscale API for automation).

## Supplying them

`provision.sh` assembles `secrets.env` on the node from any combination of:

```bash
--tailscale-key tskey-auth-...      # -> TS_AUTHKEY=...
--k3s-token <token>                 # -> K3S_TOKEN=...
--secrets-file ./secrets.env        # a KEY=VALUE file, merged verbatim
--secrets-stdin                     # the same KEY=VALUE content on stdin
```

`secrets.env` format is plain shell assignments:

```
K3S_TOKEN=...
REGISTRY_SERVER=registry.example.com
REGISTRY_USER=...
REGISTRY_PASSWORD=...
REGISTRY_EMAIL=ops@example.com
```

### Keeping secrets in an encrypted store

Keep the real values in whatever private store you like (an age-encrypted file,
a vault, your monorepo). Decrypt and pipe them in - nothing lands on disk:

```bash
my-secret-tool show prod | ./provision.sh root@1.2.3.4 --role control-plane \
  --secrets-stdin --tailscale-key tskey-auth-... --manifests /path/to/manifests
```

If you supply nothing, `node-setup` prompts interactively on the node for each
secret a step needs - fine for a one-off, not for automation.

## Why it is safe to keep this repo public

The setup logic references secrets only by **name** (`require_secrets K3S_TOKEN`)
and reads them at run time. No values, keys, or tokens are committed. The only
cluster-identifying data here is topology in `setup/cluster.env` (control-plane
Tailscale IP, DB names, UFW sources), which is intentionally published.
