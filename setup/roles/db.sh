# role: db - standalone PostgreSQL node (prod: PG18 with browser_v7 + guard_v6).
# Not part of the k3s cluster (the flannel-watchdog payload runs in its
# tailscaled-only mode here: a dead tailnet takes the DB offline for the whole
# product just the same). Reachable over the tailnet / private net only;
# 5432 is never public and pg_hba is scram-only with scoped sources.
# shellcheck shell=bash

UFW_PUBLIC_TCP=("${DB_PUBLIC_TCP[@]}")
UFW_PUBLIC_UDP=("${DB_PUBLIC_UDP[@]}")

ROLE_STEPS=(
  base-packages
  base-time
  base-journald
  base-unattended
  base-ssh-harden
  swap-disable
  tailscale-install
  tailscale-up
  ufw-rules
  pg-install
  pg-config
  pg-databases
  pg-helpers
  flannel-watchdog
  oom-guards
  net-limits
  hw-watchdog
  disk-guard
)
