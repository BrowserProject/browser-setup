# Automated / burst provisioning

The Zesiger.net Backend (module `burst`) adds temporary workers to a cluster
when its fixed fleet runs out of capacity and removes them when they are idle.
It creates the servers at OVH Public Cloud or Hetzner Cloud, on Ubuntu 24.04,
and every server runs **this repo's `node-setup`**: burst is one caller of the
same worker role, nothing here is burst-specific.

A node boots either the provider's stock Ubuntu image or a **golden image**
the Backend baked from it with `node-setup --prepare` and `node-setup seal`.
The cloud-init that joins the node is the same for both; on a golden image the
journal already holds every step except the join.

## Pinned bundle and cluster.env

- The bundle is a commit tarball,
  `https://github.com/BrowserProject/browser-setup/archive/<40-hex sha>.tar.gz`,
  never a branch: a node's setup must not change under it.
- The cloud-init writes `setup/cluster.env` from `cluster.env.example` plus
  the environment's overrides (exit-node routing, public ports, trusted
  sources, `WORKER_NODE_LABELS`), byte for byte the same for the bake and for
  every node, because the file is part of every step hash.
- A golden image matches one bundle commit, one `cluster.env`, one `--server`
  and one `--modules` list. Change any of them and the Backend boots stock
  Ubuntu until it has baked a new image.

## Joining a node

```yaml
#cloud-config
hostname: burst-beta-1792000000000
fqdn: burst-beta-1792000000000
preserve_hostname: false
write_files:
  - path: /opt/burst-join.sh
    permissions: '0700'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      mkdir -p /opt/node-setup /etc/node-setup
      curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors '<bundle tarball>' \
        | tar -xz --strip-components=1 -C /opt/node-setup
      cat /opt/node-setup/setup/cluster.env.example > /opt/node-setup/setup/cluster.env
      cat >> /opt/node-setup/setup/cluster.env <<'ENV'
      WORKER_NODE_LABELS=(browser.lol/burst=true)
      ENV
      umask 077
      cat > /etc/node-setup/secrets.env <<'ENV'
      TS_AUTHKEY=<ephemeral, single-use key for this server>
      K3S_TOKEN=<cluster join token>
      ENV
      attempt=0
      until /opt/node-setup/setup/node-setup --role worker --yes --server <control-plane-ip>; do
        attempt=$((attempt + 1)); [ "$attempt" -ge 3 ] && exit 1; sleep 60
      done
      rm -f /opt/burst-join.sh
runcmd:
  - /opt/burst-join.sh
```

`--strip-components=1` drops GitHub's `browser-setup-<sha>/` prefix, so
`node-setup` lands at `/opt/node-setup/setup/node-setup`. On stock Ubuntu the
run installs everything; on a golden image it applies `tailscale-up` and
`k3s-agent-install`, which reuses the k3s installer and binary of the image,
plus any step that drifted. `node-setup` shreds `secrets.env` when it is done.

## Baking a golden image

The Backend creates a bake VM from the stock image with the same bundle,
`cluster.env`, `--server` and `--modules`, waits until it has powered off,
snapshots its disk and deletes it:

```bash
# /opt/burst-bake.sh, run by cloud-init on the bake VM
mkdir -p /opt/node-setup /etc/node-setup
curl -fsSL ... | tar -xz --strip-components=1 -C /opt/node-setup   # same bundle
# same cluster.env as the nodes
umask 077
cat > /etc/node-setup/secrets.env <<'ENV'
REGISTRY_SERVER=<registry host>
REGISTRY_USER=<pull-only key>
REGISTRY_PASSWORD=<its secret>
BAKE_IMAGES="<catalog and helper image references, space separated>"
ENV
/opt/node-setup/setup/node-setup --role worker --prepare --yes --server <control-plane-ip>
rm -f /opt/burst-bake.sh /etc/node-setup/secrets.env
/opt/node-setup/setup/node-setup seal --poweroff
```

- `--prepare` installs and journals every step except the join, pre-installs
  k3s, and pulls `BAKE_IMAGES` (prefetch images). Without `BAKE_IMAGES` the
  image holds no browser image (slim). A digest-pinned image on a registry
  other than `REGISTRY_SERVER` cannot be baked under its name, so the Backend
  leaves it out and the edge pulls it on first use.
- The registry key is only in `secrets.env`, which `node-setup` shreds, and
  in a docker login on tmpfs for the duration of the pulls.
- `seal` refuses while any secret or identity is left (including the bake
  script itself and any `write_files` target assigning a secret), so the
  snapshot cannot capture the registry key, a join token or a tailnet node.
  See [ROLES.md](ROLES.md#disk-images---prepare-seal) for both lists.
- Browser images age with the image: the edge reports the node ready at once
  and refreshes the catalog's moving tags in the background, so a node may
  serve a bake-time build until that refresh lands. The Backend re-bakes
  prefetch images before they get old.

## Notes

- **Snapshots are regional** at OVH: an image is used in the region it was
  made in, or copied there.
- **Secrets in user data.** The provider API returns user data to anyone with
  read access to the project's servers, so the join token is exposed to every
  principal of that project. The Tailscale key is ephemeral and single-use.
- **No manifests.** Burst nodes are workers; they never need the services
  manifest.
