# k3s-server.sh - k3s control plane: datastore prep, pinned install, sqlite
# vacuum timer, registry pull secret, services manifest, CoreDNS DaemonSet.
# shellcheck shell=bash

K3S_DB_DIR="/var/lib/rancher/k3s/server/db"
K3S_SQLITE_DB="$K3S_DB_DIR/state.db"

_k3s_server_fresh() {
  # no datastore yet = fresh install (safe for one-shot flags like
  # --secrets-encryption that cannot simply be added to a live cluster)
  [[ ! -e "$K3S_SQLITE_DB" && ! -d "$K3S_DB_DIR/etcd" ]]
}

STEP_DESC["k3s-sqlite-init"]="pre-create the k3s sqlite datastore with auto_vacuum=INCREMENTAL"
k3s-sqlite-init::check() {
  [[ -f "$K3S_SQLITE_DB" ]] \
    && [[ "$(sqlite3 "$K3S_SQLITE_DB" 'PRAGMA auto_vacuum;' 2>/dev/null)" == "2" ]]
}
k3s-sqlite-init::apply() {
  ensure_pkgs sqlite3
  if [[ -f "$K3S_SQLITE_DB" ]]; then
    # existing datastore: auto_vacuum can only be changed with an offline
    # VACUUM; do not touch a live cluster db here.
    if systemctl is-active --quiet k3s; then
      warn "k3s datastore already exists and k3s is running; skipping auto_vacuum init (change requires an offline VACUUM)"
      return 0
    fi
    sqlite3 "$K3S_SQLITE_DB" "PRAGMA auto_vacuum = INCREMENTAL; VACUUM;"
  else
    mkdir -p "$K3S_DB_DIR"
    sqlite3 "$K3S_SQLITE_DB" "PRAGMA auto_vacuum = INCREMENTAL; VACUUM;"
  fi
}
k3s-sqlite-init::verify() {
  [[ "$(sqlite3 "$K3S_SQLITE_DB" 'PRAGMA auto_vacuum;')" == "2" ]]
}

STEP_DESC["k3s-server-install"]="install pinned k3s server bound to the tailnet"
k3s-server-install::check() {
  systemctl is-active --quiet k3s \
    && [[ "$(_k3s_installed_version)" == "$K3S_VERSION" ]]
}
k3s-server-install::apply() {
  require_secrets K3S_TOKEN
  local ip
  ip="$(ts_ip)"
  [[ -n "$ip" ]] || die "no tailscale IP; tailscale-up must run first"

  local exec_args=(server
    "--node-ip=${ip}"
    "--advertise-address=${ip}"
    "--tls-san=${ip}"
    --flannel-backend=vxlan
    --flannel-iface=tailscale0
    --disable local-storage
    --disable traefik
  )
  exec_args+=("${K3S_SERVER_EXTRA_ARGS[@]}")
  if [[ "${K3S_SECRETS_ENCRYPTION:-0}" == "1" ]]; then
    if _k3s_server_fresh; then
      exec_args+=(--secrets-encryption)
    else
      warn "K3S_SECRETS_ENCRYPTION=1 but datastore already exists; NOT adding the flag (use the 'k3s secrets-encrypt' rotation flow to enable on a live cluster)"
    fi
  fi

  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    K3S_TOKEN="$K3S_TOKEN" \
    INSTALL_K3S_EXEC="${exec_args[*]}" \
    sh -
}
k3s-server-install::verify() {
  systemctl is-active --quiet k3s || return 1
  wait_for 180 5 _k3s_node_ready || {
    err "k3s is active but the node never went Ready; check: journalctl -u k3s"
    return 1
  }
}
_k3s_node_ready() {
  # not `| grep -q`: kubectl streams rows and grep -q's early exit EPIPEs it,
  # which pipefail in the step subshell turns into a false failure. grep -c
  # consumes the whole stream.
  [[ "$(k3s kubectl get node "$(hostname | tr '[:upper:]' '[:lower:]')" 2>/dev/null | grep -c ' Ready')" -gt 0 ]]
}

STEP_DESC["k3s-vacuum-timer"]="daily incremental vacuum of the k3s sqlite datastore"
k3s-vacuum-timer::apply() {
  write_if_changed /etc/systemd/system/k3s-vacuum.service <<'EOF' || true
# Managed by node-setup.
[Unit]
Description=k3s SQLite incremental vacuum
After=k3s.service
Requires=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/bin/sqlite3 /var/lib/rancher/k3s/server/db/state.db "PRAGMA incremental_vacuum;"
EOF
  write_if_changed /etc/systemd/system/k3s-vacuum.timer <<'EOF' || true
# Managed by node-setup.
[Unit]
Description=Daily k3s SQLite incremental vacuum

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
EOF
  svc_enable_now k3s-vacuum.timer
}
k3s-vacuum-timer::verify() {
  systemctl is-active --quiet k3s-vacuum.timer
}

STEP_DESC["k3s-registry-secret"]="browser-system namespace + registry pull secret"
k3s-registry-secret::apply() {
  require_secrets REGISTRY_SERVER REGISTRY_USER REGISTRY_PASSWORD REGISTRY_EMAIL
  k3s kubectl create namespace browser-system --dry-run=client -o yaml | k3s kubectl apply -f -
  k3s kubectl create secret docker-registry registry-secret \
    --docker-server="$REGISTRY_SERVER" \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASSWORD" \
    --docker-email="$REGISTRY_EMAIL" \
    -n browser-system --dry-run=client -o yaml | k3s kubectl apply -f -
  # plain-keys twin of the pull secret, so deployments that need the registry
  # credentials as env vars (edge) can use secretKeyRef instead of an inline
  # value in the services manifest
  k3s kubectl create secret generic registry-credentials \
    --from-literal=server="$REGISTRY_SERVER" \
    --from-literal=username="$REGISTRY_USER" \
    --from-literal=password="$REGISTRY_PASSWORD" \
    -n browser-system --dry-run=client -o yaml | k3s kubectl apply -f -
}
k3s-registry-secret::verify() {
  k3s kubectl get secret registry-secret -n browser-system >/dev/null 2>&1 \
    && k3s kubectl get secret registry-credentials -n browser-system >/dev/null 2>&1
}

STEP_DESC["k3s-services"]="apply the browser services manifest from the bundle"
k3s-services::apply() {
  local manifest="$MANIFEST_DIR/$SERVICES_MANIFEST"
  [[ -f "$manifest" ]] || die "manifest not found: $manifest (bundle incomplete?)"
  k3s kubectl apply -f "$manifest"
}
k3s-services::verify() {
  local manifest="$MANIFEST_DIR/$SERVICES_MANIFEST"
  k3s kubectl get -f "$manifest" >/dev/null || return 1
  # Workloads may still be pulling images; report rather than block provisioning.
  log "services applied; watch rollout with: k3s kubectl get pods -n browser-system -w"
}

STEP_DESC["k3s-coredns"]="replace stock CoreDNS with per-node DaemonSet + NodeLocal DNSCache"
k3s-coredns::check() {
  [[ -f /var/lib/rancher/k3s/server/manifests/coredns.yaml.skip ]] \
    && k3s kubectl -n kube-system get daemonset coredns >/dev/null 2>&1 \
    && k3s kubectl -n kube-system get daemonset node-local-dns >/dev/null 2>&1
}
k3s-coredns::apply() {
  [[ -f "$MANIFEST_DIR/coredns.yaml" && -f "$MANIFEST_DIR/node-local-dns.yaml" ]] \
    || die "coredns manifests missing from bundle: $MANIFEST_DIR"
  # sentinel: stop k3s from re-deploying its own CoreDNS
  touch /var/lib/rancher/k3s/server/manifests/coredns.yaml.skip
  k3s kubectl delete deployment -n kube-system coredns --ignore-not-found
  k3s kubectl delete configmap -n kube-system coredns --ignore-not-found
  k3s kubectl apply -f "$MANIFEST_DIR/coredns.yaml"
  k3s kubectl apply -f "$MANIFEST_DIR/node-local-dns.yaml"
  k3s kubectl -n kube-system rollout status daemonset/coredns --timeout=180s
  k3s kubectl -n kube-system rollout status daemonset/node-local-dns --timeout=180s
}
k3s-coredns::verify() {
  # grep -c, not grep -q: -q's early exit EPIPEs the streaming kubectl under
  # the step subshell's pipefail (observed on the 21-pod prod DaemonSet)
  [[ "$(k3s kubectl -n kube-system get pods -l k8s-app=kube-dns 2>/dev/null | grep -c Running)" -gt 0 ]]
}
