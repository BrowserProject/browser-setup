#!/usr/bin/env bash
#
# fleet.sh - run commands across the cluster's nodes over SSH (tailnet IPs).
#
#   fleet.sh list                          # nodes with IPs, labels, status
#   fleet.sh run [-l k=v] -- <cmd...>      # run a command on nodes (label filter)
#   fleet.sh run --hosts ip1,ip2 -- <cmd>  # explicit hosts (e.g. the DB node)
#   fleet.sh doctor [-l k=v]               # node-setup doctor everywhere
#
# Uses the current kubeconfig (run on the control plane or a box with one).
# SSH is root@<node InternalIP>, i.e. over the tailnet.
set -euo pipefail

die() { echo "fleet: $*" >&2; exit 1; }

KUBECTL="kubectl"
command -v kubectl >/dev/null || { command -v k3s >/dev/null && KUBECTL="k3s kubectl"; }

JSONPATH="jsonpath={range .items[*]}{.metadata.name} {.status.addresses[?(@.type=='InternalIP')].address}{'\n'}{end}"
nodes() { # [label-selector] -> "name ip" lines
  local sel="${1:-}"
  if [[ -n "$sel" ]]; then
    $KUBECTL get nodes -l "$sel" -o "$JSONPATH"
  else
    $KUBECTL get nodes -o "$JSONPATH"
  fi
}

cmd_list() {
  $KUBECTL get nodes -o wide -L type,gpu
}

cmd_run() {
  local sel="" hosts="" fail=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l) sel="$2"; shift 2 ;;
      --hosts) hosts="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [[ $# -gt 0 ]] || die "no command given (use: fleet.sh run [-l k=v] -- cmd...)"

  local list=()
  if [[ -n "$hosts" ]]; then
    local IFS=','
    for h in $hosts; do list+=("$h $h"); done
    unset IFS
  else
    mapfile -t list < <(nodes "$sel")
  fi
  [[ ${#list[@]} -gt 0 ]] || die "no nodes matched"

  local entry name ip
  for entry in "${list[@]}"; do
    name="${entry%% *}"; ip="${entry##* }"
    echo "===== $name ($ip) ====="
    ssh -o ConnectTimeout=8 -o BatchMode=yes "root@$ip" "$@" || { echo "!!! $name failed (rc=$?)"; fail=1; }
  done
  exit "$fail"
}

case "${1:-}" in
  list)   cmd_list ;;
  run)    shift; cmd_run "$@" ;;
  doctor) shift; cmd_run "$@" -- "command -v node-setup >/dev/null && node-setup doctor || echo 'node-setup not installed'" ;;
  *) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
