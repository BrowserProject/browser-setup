# postgres.sh - PostgreSQL for the db role (prod, PG18) and the dev box (PG17).
#
# Security posture (deliberate changes vs the old wiki instructions):
#  - auth method is scram-sha-256, never the plaintext-on-the-wire `password`
#  - pg_hba is scoped to the tailnet/private ranges, never 0.0.0.0/0
#  - the managed rules live in a marker block, local peer auth stays untouched
# shellcheck shell=bash

_pg_conf_dir() { echo "/etc/postgresql/${PG_MAJOR}/main"; }
_psql() { sudo -u postgres psql -X -v ON_ERROR_STOP=1 "$@"; }

STEP_DESC["pg-install"]="install pinned PostgreSQL major from apt.postgresql.org"
pg-install::check() {
  [[ -d "$(_pg_conf_dir)" ]] && systemctl is-active --quiet postgresql
}
pg-install::apply() {
  ensure_pkgs wget gnupg lsb-release
  if [[ ! -f /etc/apt/keyrings/pgdg.gpg ]]; then
    install -d -m 0755 /etc/apt/keyrings
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt-get update
  fi
  ensure_pkgs "postgresql-${PG_MAJOR}" "postgresql-contrib-${PG_MAJOR}"
  svc_enable_now postgresql
}
pg-install::verify() {
  systemctl is-active --quiet postgresql && _psql -tAc "SELECT 1" | grep -qx 1
}

STEP_DESC["pg-config"]="listen on all interfaces (ufw+hba gated), enforce scram-sha-256"
pg-config::apply() {
  local confd
  confd="$(_pg_conf_dir)/conf.d"
  mkdir -p "$confd"
  local changed=0
  # listen '*' rather than pinning the tailscale IP: tailscale0 may come up
  # after postgres at boot and a bind-to-missing-address only logs a warning
  # once, leaving the tailnet silently unreachable until a restart. Real
  # access control is pg_hba (scoped CIDRs, scram) + ufw (no public 5432).
  write_if_changed "$confd/90-node-setup.conf" <<'EOF' && changed=1
# Managed by node-setup.
listen_addresses = '*'
password_encryption = scram-sha-256
EOF
  chown postgres:postgres "$confd/90-node-setup.conf"

  local hba
  hba="$(_pg_conf_dir)/pg_hba.conf"
  local rules
  rules="$(printf '%s\n' "${PG_HBA_RULES[@]}")"
  replace_block "$hba" "node-setup managed client access" <<EOF && changed=1
# scram only; scoped sources; managed by node-setup (edit setup/cluster.env instead)
$rules
EOF

  if [[ "$changed" == "1" ]]; then
    systemctl restart postgresql
  fi
  return 0
}
pg-config::verify() {
  systemctl is-active --quiet postgresql || return 1
  [[ "$(_psql -tAc 'SHOW password_encryption')" == "scram-sha-256" ]] || return 1
  # the plaintext `password` method and world-open rules must never be active
  if grep -E '^\s*host' "$(_pg_conf_dir)/pg_hba.conf" | grep -qE '\s(password)\s*$'; then
    err "pg_hba.conf still contains a plaintext 'password' auth rule"
    return 1
  fi
  if grep -E '^\s*host' "$(_pg_conf_dir)/pg_hba.conf" | grep -q '0\.0\.0\.0/0'; then
    err "pg_hba.conf still contains a 0.0.0.0/0 rule"
    return 1
  fi
}

STEP_DESC["pg-databases"]="create roles + databases (idempotent, scram-hashed passwords)"
pg-databases::apply() {
  require_secrets PG_BROWSER_PASSWORD PG_GUARD_PASSWORD

  # roles: passwords go through psql variables (never argv/ps) and are hashed
  # server-side because password_encryption=scram-sha-256 (pg-config).
  # ALTER goes via stdin, not -c: psql skips :'var' interpolation in -c commands.
  if ! _psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='browser'" | grep -qx 1; then
    _psql -c "CREATE ROLE browser LOGIN SUPERUSER"
  fi
  _psql -v pw="$PG_BROWSER_PASSWORD" <<'SQL'
ALTER ROLE browser PASSWORD :'pw';
SQL

  if ! _psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='guard'" | grep -qx 1; then
    _psql -c "CREATE ROLE guard LOGIN"
  fi
  _psql -v pw="$PG_GUARD_PASSWORD" <<'SQL'
ALTER ROLE guard PASSWORD :'pw';
SQL

  # databases
  local db
  for db in "${PG_DATABASES[@]}"; do
    if ! _psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -qx 1; then
      _psql -c "CREATE DATABASE \"$db\""
    fi
  done
  if _psql -tAc "SELECT 1 FROM pg_database WHERE datname='guard_v6'" | grep -qx 1; then
    _psql -c "ALTER DATABASE guard_v6 OWNER TO guard"
  fi
}
pg-databases::verify() {
  local db
  for db in "${PG_DATABASES[@]}"; do
    _psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -qx 1 || return 1
  done
  _psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='browser' AND rolcanlogin" | grep -qx 1
}

STEP_DESC["pg-helpers"]="install db-dump / db-restore helper commands"
pg-helpers::apply() {
  write_if_changed /usr/local/bin/db-dump 0755 <<'EOF' || true
#!/usr/bin/env bash
# db-dump [dbname] [outfile] - custom-format dump of a local database.
set -euo pipefail
DB="${1:-browser_v7}"
OUT="${2:-/root/backup_$(date +%Y%m%d_%H%M%S).dump}"
sudo -u postgres pg_dump -d "$DB" -F c -f "$OUT"
echo "dumped $DB -> $OUT"
EOF
  write_if_changed /usr/local/bin/db-restore 0755 <<'EOF' || true
#!/usr/bin/env bash
# db-restore <dumpfile> [dbname] - restore a custom-format dump into a local
# database (drops+recreates objects; asks before touching anything).
set -euo pipefail
DUMP="${1:?usage: db-restore <dumpfile> [dbname]}"
DB="${2:-browser_v7}"
[[ -f "$DUMP" ]] || { echo "no such file: $DUMP" >&2; exit 1; }
read -r -p "Restore $DUMP into database '$DB' (existing objects are replaced)? [y/N] " a
[[ "$a" =~ ^[Yy] ]] || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$DUMP" "$TMP/restore.dump"; chmod 644 "$TMP/restore.dump"; chmod 755 "$TMP"
sudo -u postgres pg_restore --clean --if-exists --no-acl --no-owner -d "$DB" "$TMP/restore.dump"
echo "restored $DUMP -> $DB"
EOF
}
pg-helpers::verify() {
  [[ -x /usr/local/bin/db-dump && -x /usr/local/bin/db-restore ]]
}
