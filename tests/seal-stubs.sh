# shellcheck shell=bash
# seal-stubs.sh - stubs for every command `node-setup seal` runs, sourced by
# both test files. seal_stubs <dir> writes them to <dir>/bin; <dir> must lie
# under NODE_SETUP_SEAL_ROOT. Files in <dir> switch the stubbed host state:
# ts-state (tailscale BackendState), k3s-active, k3s-enabled, containers,
# docker-down, apt-busy, dpkg-unfinished. Calls that would change the host are
# appended to <dir>/calls.

_seal_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/bin/$2"; chmod +x "$1/bin/$2"; }

seal_stubs() {
  local dir="$1" cmd
  mkdir -p "$dir/bin"
  _seal_stub "$dir" tailscale "echo \"{\\\"BackendState\\\": \\\"\$(cat '$dir/ts-state' 2>/dev/null || echo NeedsLogin)\\\"}\""
  _seal_stub "$dir" jq "sed -n 's/.*\"BackendState\": *\"\\([^\"]*\\)\".*/\\1/p'"
  _seal_stub "$dir" systemctl "case \"\$1\" in
  is-active)  [ -f '$dir/k3s-active' ] ;;
  is-enabled) if [ -f '$dir/k3s-enabled' ]; then echo enabled; else echo disabled; exit 1; fi ;;
  *)          echo \"systemctl \$*\" >> '$dir/calls' ;;
esac"
  _seal_stub "$dir" docker "case \"\$1\" in
  ps)    [ ! -f '$dir/docker-down' ] || exit 1; cat '$dir/containers' 2>/dev/null || true ;;
  image) printf 'srv.example/browser:beta\n<none>:<none>\n' ;;
esac"
  _seal_stub "$dir" ufw "case \"\$1\" in
  status) printf '%s\n' '[ 1] Anywhere on tailscale0     ALLOW IN    Anywhere                   # tailnet' \\
    '[ 2] 22/tcp                     ALLOW IN    203.0.113.7                # node-setup: provisioning ssh guard' \\
    '[ 3] 80/tcp                     ALLOW IN    Anywhere' ;;
  *)      echo \"ufw \$*\" >> '$dir/calls' ;;
esac"
  _seal_stub "$dir" pgrep "[ -f '$dir/apt-busy' ]"
  _seal_stub "$dir" dpkg "[ \"\$1\" = --audit ] || exit 1
[ ! -f '$dir/dpkg-unfinished' ] || echo 'The following packages are only half configured'"
  for cmd in apt-get journalctl cloud-init fstrim; do
    _seal_stub "$dir" "$cmd" "echo \"$cmd \$*\" >> '$dir/calls'"
  done
  _seal_stub "$dir" dpkg-query "echo 1.2.3"
  _seal_stub "$dir" k3s "echo 'k3s version v1.35.4+k3s1 (abc)'"
}
