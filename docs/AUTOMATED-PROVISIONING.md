# Automated / burst provisioning

The Zesiger.net Backend (module `burst`) adds temporary workers to a cluster
when its fixed fleet runs out of capacity and removes them when they are idle.
It creates the servers at OVH Public Cloud or Hetzner Cloud from the
provider's stock Ubuntu 24.04 image, and every server runs **this repo's
`node-setup`** from scratch: burst is one caller of the same worker role,
nothing here is burst-specific.

## Pinned bundle and cluster.env

- The bundle is a commit tarball,
  `https://github.com/BrowserProject/browser-setup/archive/<40-hex sha>.tar.gz`,
  never a branch: a node's setup must not change under it.
- The cloud-init writes `setup/cluster.env` from `cluster.env.example` plus
  the environment's overrides (exit-node routing, public ports, trusted
  sources, `WORKER_NODE_LABELS`).

## Joining a node

```yaml
#cloud-config
hostname: burst-beta-1792000000000
fqdn: burst-beta-1792000000000
preserve_hostname: false
prefer_fqdn_over_hostname: false
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
      (
      umask 077
      cat > /etc/node-setup/secrets.env <<'ENV'
      TS_AUTHKEY=<ephemeral, single-use key for this server>
      K3S_TOKEN=<cluster join token>
      ENV
      )
      attempt=0
      until /opt/node-setup/setup/node-setup --role worker --yes --server <control-plane-ip> --modules direct-egress; do
        attempt=$((attempt + 1)); [ "$attempt" -ge 3 ] && exit 1; sleep 60
      done
      rm -f /opt/burst-join.sh
runcmd:
  - /opt/burst-join.sh
```

`--strip-components=1` drops GitHub's `browser-setup-<sha>/` prefix, so
`node-setup` lands at `/opt/node-setup/setup/node-setup`. The `umask 077`
stays in a subshell so only `secrets.env` is private; the `--modules` list is
the environment's own setting. The run installs everything and joins the
tailnet and the cluster; `node-setup` shreds `secrets.env` when it is done.

## Premium workers

The Backend's premium lane runs the same join with
`--modules direct-egress,profile-share` and appends the region's share to
`cluster.env`:

```
PROFILE_SHARE_EXPORT="<the region's export, 10.x.y.z:/path>"
PROFILE_SHARE_DOMAIN="<prod|beta>-location-<Locations.id>"
```

The domain comes from the platform's burst state unchanged; `PROFILE_SCRATCH_GIB`
keeps its default unless the lane sets it. The node then mounts the share,
checks its marker and arms the shutdown detach before the k3s agent joins
([ROLES.md](ROLES.md#saved-profile-share-profile-share-profile-share-server)).

## Notes

- **Secrets in user data.** The provider API returns user data to anyone with
  read access to the project's servers, so the join token is exposed to every
  principal of that project. The Tailscale key is ephemeral and single-use.
- **No manifests.** Burst nodes are workers; they never need the services
  manifest.
