# Automated / burst provisioning

The Browser API adds temporary Hetzner workers when the fixed fleet runs out of
capacity, then reaps them when idle. It reuses **this repo unchanged** - burst is
just one caller of `node-setup`.

## Flow

1. The API detects sustained capacity pressure (genuine "no host had room"
   denials) and provisions **one** Hetzner server at a time.
2. The server boots a stock **Debian** image with a small cloud-init `user-data`
   that:
   - fetches this repo's tarball from GitHub,
   - writes an inline `/etc/node-setup/secrets.env` (`TS_AUTHKEY` + `K3S_TOKEN`),
   - runs `node-setup --role worker --yes --server <control-plane-ip>`.
3. `node-setup` installs tailscale -> docker -> k3s-agent and joins the cluster.
   The node's proxy then heartbeats it into the control plane and it becomes
   schedulable.
4. When the node has been idle, the API deletes the Hetzner server; the ephemeral
   Tailscale device auto-removes from the tailnet.

## The cloud-init user-data

Kept well under Hetzner's 32 KB user-data limit - it fetches the bundle rather
than embedding it:

```yaml
#cloud-config
write_files:
  - path: /opt/burst-join.sh
    permissions: '0700'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      mkdir -p /opt/node-setup /etc/node-setup
      curl -fsSL https://github.com/BrowserProject/browser-setup/archive/refs/heads/main.tar.gz \
        | tar -xz --strip-components=1 -C /opt/node-setup
      cat > /etc/node-setup/secrets.env <<'EOF'
      TS_AUTHKEY=<ephemeral, single-use, pre-authorized key>
      K3S_TOKEN=<cluster join token>
      EOF
      chmod 600 /etc/node-setup/secrets.env
      /opt/node-setup/setup/node-setup --role worker --yes --server <control-plane-ip>
runcmd:
  - /opt/burst-join.sh
```

`--strip-components=1` drops GitHub's `browser-setup-<ref>/` archive prefix, so
`node-setup` lands at `/opt/node-setup/setup/node-setup`.

## Notes

- **Pin the ref** for production: fetch a tag or commit SHA tarball
  (`.../archive/<sha>.tar.gz`) instead of `main` so a burst node's setup is
  reproducible and unaffected by an in-flight change to this repo.
- **Secrets inline.** The two join secrets ride the cloud-init user-data. That
  data is readable only via the Hetzner API token, which is itself a
  top-privilege secret, so this does not widen the blast radius; user-data can be
  wiped post-boot. The Tailscale key is ephemeral + single-use, so it self-limits.
- **No manifests.** Burst nodes are workers; they never need the services
  manifest, so nothing private is required to bring one up.
