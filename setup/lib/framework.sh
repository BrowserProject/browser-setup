# shellcheck shell=bash
# framework.sh - step runner + helpers for node-setup.
#
# A step is three bash functions (check is optional, verify is recommended):
#   <step>::check    return 0 when the step's desired state already holds
#   <step>::apply    idempotently establish the desired state (fail-fast)
#   <step>::verify   read-only assertion that apply worked
# plus a description in STEP_DESC[<step>].
#
# The runner keeps a journal in $STATE_DIR/state/<step>.hash containing a hash
# of the step's function bodies + versions.env. A step is skipped only when the
# journal hash matches AND check() passes; editing a step definition or bumping
# versions.env therefore re-applies it, and drift (check fails) re-applies too.
# check() passing with no journal entry adopts pre-existing manual state.
#
# apply/verify/check run in subshells with `set -e`, so a failing command
# aborts the step even though the caller inspects the return code. Cross-step
# state (reboot requests, apt stamp) travels via files, never variables.

# --- paths (overridable for tests) -------------------------------------------
STATE_DIR="${NODE_SETUP_STATE_DIR:-/var/lib/node-setup}"
CONF_DIR="${NODE_SETUP_CONF_DIR:-/etc/node-setup}"
LOG_FILE="$STATE_DIR/setup.log"

# --- flags (set by the CLI) ---------------------------------------------------
DRY_RUN=0
DOCTOR=0
ASSUME_YES=0
INTERACTIVE=0
ONLY_STEPS=""
SKIP_STEPS=""

declare -A STEP_DESC

# --- output -------------------------------------------------------------------
if [[ -t 1 && "${NO_COLOR:-}" != "1" ]]; then
  C_BLUE=$'\033[0;34m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""; C_OFF=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_emit() { # $1=prefix-colored $2=message; mirrors to logfile without colors
  printf '%s %s\n' "$1" "$2"
  if [[ -d "$STATE_DIR" ]]; then
    printf '%s %s\n' "$(_ts)" "$2" >> "$LOG_FILE" 2>/dev/null || true
  fi
}
log()  { _emit "${C_BLUE}[setup]${C_OFF}" "$*"; }
ok()   { _emit "${C_GREEN}[ ok  ]${C_OFF}" "$*"; }
warn() { _emit "${C_YELLOW}[warn ]${C_OFF}" "$*"; }
err()  { _emit "${C_RED}[fail ]${C_OFF}" "$*" >&2; }
die()  { err "$*"; exit 1; }

confirm() { # confirm "question" -> 0 yes / 1 no; --yes and non-tty auto-accept
  local q="$1" reply
  [[ "$ASSUME_YES" == "1" ]] && return 0
  if [[ "$INTERACTIVE" != "1" ]]; then return 0; fi
  read -r -p "$q [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root"
}

# --- file helpers -------------------------------------------------------------
# write_if_changed <path> [mode]  (content on stdin) -> 0 if changed, 1 if same
write_if_changed() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; return 1
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  return 0
}

# ensure_line <file> <exact line>  -> appends if not present verbatim
ensure_line() {
  local file="$1" line="$2"
  grep -qxF -- "$line" "$file" 2>/dev/null && return 0
  printf '%s\n' "$line" >> "$file"
}

# replace_block <file> <marker> (content on stdin)
# Maintains a "# BEGIN <marker>" .. "# END <marker>" block; creates file if
# missing. Returns 0 if the file changed.
replace_block() {
  local file="$1" marker="$2" content tmp begin end
  content="$(cat)"
  begin="# BEGIN $marker"
  end="# END $marker"
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v b="$begin" -v e="$end" '
      $0 == b {inblock=1; next}
      $0 == e {inblock=0; next}
      !inblock {print}
    ' "$file" > "$tmp"
  fi
  {
    cat "$tmp"
    printf '%s\n%s\n%s\n' "$begin" "$content" "$end"
  } > "${tmp}.new"
  if [[ -f "$file" ]] && cmp -s "${tmp}.new" "$file"; then
    rm -f "$tmp" "${tmp}.new"; return 1
  fi
  # preserve existing permissions when the file exists
  if [[ -f "$file" ]]; then
    cat "${tmp}.new" > "$file"
  else
    install -D -m 0644 "${tmp}.new" "$file"
  fi
  rm -f "$tmp" "${tmp}.new"
  return 0
}

# --- package helper -----------------------------------------------------------
# ensure_pkgs pkg... : installs any missing packages; runs `apt-get update` at
# most once per day (stamp file), so re-runs stay fast.
ensure_pkgs() {
  local missing=()
  local p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

apt_update_once() {
  local stamp="$STATE_DIR/.apt-stamp"
  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$(date +%Y%m%d)" ]]; then
    return 0
  fi
  apt-get update
  date +%Y%m%d > "$stamp"
}

# --- misc helpers ---------------------------------------------------------------
svc_enable_now() { # unit...
  systemctl daemon-reload
  local u
  for u in "$@"; do
    systemctl enable --now "$u"
  done
}

# retry <attempts> <delay-seconds> cmd...
retry() {
  local attempts="$1" delay="$2" i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    "$@" && return 0
    (( i < attempts )) && sleep "$delay"
  done
  return 1
}

# wait_for <timeout-s> <interval-s> cmd... : poll until cmd succeeds
wait_for() {
  local timeout="$1" interval="$2" waited=0
  shift 2
  until "$@"; do
    (( waited >= timeout )) && return 1
    sleep "$interval"
    (( waited += interval ))
  done
  return 0
}

ts_ip() { tailscale ip -4 2>/dev/null | head -n1; }

# --- secrets --------------------------------------------------------------------
# Secrets live in $CONF_DIR/secrets.env (0600, pushed by provision.sh, deleted
# on successful completion). require_secrets prompts interactively for missing
# keys; in non-interactive mode a missing key is fatal with a clear message.
load_secrets() {
  if [[ -f "$CONF_DIR/secrets.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$CONF_DIR/secrets.env"; set +a
  fi
}

require_secrets() {
  local key val
  for key in "$@"; do
    val="${!key:-}"
    if [[ -z "$val" ]]; then
      if [[ "$INTERACTIVE" == "1" ]]; then
        read -r -s -p "Enter value for $key: " val; echo
        [[ -n "$val" ]] || die "no value provided for $key"
        export "$key=$val"
        mkdir -p "$CONF_DIR"; touch "$CONF_DIR/secrets.env"; chmod 600 "$CONF_DIR/secrets.env"
        printf '%s=%q\n' "$key" "$val" >> "$CONF_DIR/secrets.env"
      else
        die "missing secret '$key' (expected in $CONF_DIR/secrets.env; push it with infra/provision.sh or add it manually)"
      fi
    fi
  done
}

# --- reboot handling --------------------------------------------------------------
# A step's apply calls `request_reboot "reason"`. The runner then (a) refuses to
# loop forever via a per-step reboot marker, (b) installs a oneshot resume unit
# pointing at this script, and (c) reboots. After the reboot the step's check()
# must pass, which adopts the step and marks it done.
REBOOT_FLAG_FILE="$STATE_DIR/reboot-requested"
request_reboot() {
  local reason="${1:-step requires a reboot}"
  printf '%s\n' "$reason" > "$REBOOT_FLAG_FILE"
}

# --- step runner --------------------------------------------------------------------
_step_hash() { # hash of the step's function bodies + versions.env + cluster.env
  local step="$1"
  {
    declare -f "${step}::check" 2>/dev/null || true
    declare -f "${step}::apply" 2>/dev/null || true
    declare -f "${step}::verify" 2>/dev/null || true
    [[ -n "${VERSIONS_FILE:-}" && -f "${VERSIONS_FILE:-}" ]] && cat "$VERSIONS_FILE"
    # config edits (hba rules, ports, server IP) must re-apply steps too
    [[ -n "${CLUSTER_ENV_FILE:-}" && -f "${CLUSTER_ENV_FILE:-}" ]] && cat "$CLUSTER_ENV_FILE"
  } | sha256sum | cut -d' ' -f1
}

_has_fn() { declare -F "$1" >/dev/null 2>&1; }

# Run a step function in a FRESH bash process with errexit. A plain subshell
# would not do: bash ignores `set -e` inside any function/subshell invoked from
# a conditional context (if/!/&&/||), and the runner has to call steps
# conditionally. A new process has its own errexit context, so a failing
# command inside apply() truly aborts the step. Shell state (vars, arrays,
# functions) is serialized in; results travel back via files, never variables.
_run_fn() {
  local fn="$1" script rc=0
  script="$(mktemp "$STATE_DIR/.step.XXXXXX")"
  {
    # exclude bash-special / readonly names; everything else (cluster env,
    # role arrays, secrets, framework globals) is re-declared in the child
    declare -p | grep -Ev '^declare -[[:alnum:]-]+ (BASH[A-Z_]*|BASH_[A-Za-z_]*|EUID|PPID|SHELLOPTS|UID|FUNCNAME|GROUPS|DIRSTACK|PIPESTATUS|RANDOM|SECONDS|LINENO|SRANDOM|EPOCHREALTIME|EPOCHSECONDS|OPTIND|OPTERR|HOSTNAME|HOSTTYPE|MACHTYPE|OSTYPE|IFS|SHELL|SHLVL|_)=?' || true
    declare -f
    printf 'set -eo pipefail\n%s\n' "$fn"
  } > "$script"
  bash "$script" || rc=$?
  rm -f "$script"
  return "$rc"
}

_step_selected() {
  local step="$1"
  if [[ -n "$ONLY_STEPS" ]]; then
    [[ ",$ONLY_STEPS," == *",$step,"* ]] || return 1
  fi
  [[ ",$SKIP_STEPS," == *",$step,"* ]] && return 1
  return 0
}

# run_steps step...  -> exit code 0 done, 3 reboot pending (already rebooting)
run_steps() {
  local step hash state_file
  mkdir -p "$STATE_DIR/state" "$STATE_DIR/rebooted-for"
  chmod 700 "$STATE_DIR"   # step scripts serialize secrets through here

  for step in "$@"; do
    _step_selected "$step" || { log "[$step] skipped (--only/--skip)"; continue; }
    _has_fn "${step}::apply" || die "[$step] no such step (missing ${step}::apply)"

    hash="$(_step_hash "$step")"
    state_file="$STATE_DIR/state/$step.hash"

    # up to date: journal hash matches and (if defined) check passes
    if [[ -f "$state_file" && "$(cat "$state_file")" == "$hash" ]]; then
      if ! _has_fn "${step}::check" || _run_fn "${step}::check"; then
        ok "[$step] up to date"
        continue
      fi
      warn "[$step] drift detected (check failed); re-applying"
    elif _has_fn "${step}::check" && _run_fn "${step}::check"; then
      # adopt state that already exists (manually set up or post-reboot)
      echo "$hash" > "$state_file"
      ok "[$step] already satisfied; adopted"
      continue
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      log "[$step] WOULD apply: ${STEP_DESC[$step]:-}"
      continue
    fi

    log "[$step] ${STEP_DESC[$step]:-applying}"
    rm -f "$REBOOT_FLAG_FILE"
    if ! _run_fn "${step}::apply"; then
      err "[$step] apply failed; fix the cause and re-run (completed steps are journaled and will be skipped)"
      return 1
    fi

    if [[ -f "$REBOOT_FLAG_FILE" ]]; then
      _handle_reboot "$step"   # exits 3 or dies
    fi

    if _has_fn "${step}::verify" && ! _run_fn "${step}::verify"; then
      err "[$step] verify failed after apply; investigate before re-running"
      return 1
    fi
    echo "$hash" > "$state_file"
    ok "[$step] done"
  done
  return 0
}

_handle_reboot() {
  local step="$1" reason
  reason="$(cat "$REBOOT_FLAG_FILE")"
  rm -f "$REBOOT_FLAG_FILE"
  if [[ -f "$STATE_DIR/rebooted-for/$step" ]]; then
    die "[$step] requested a reboot again after already rebooting for it; investigate manually"
  fi
  touch "$STATE_DIR/rebooted-for/$step"
  install_resume_unit
  warn "[$step] requires a reboot: $reason"
  warn "setup will continue automatically after the reboot (node-setup-resume.service)"
  if confirm "Reboot now?"; then
    log "rebooting..."
    systemctl reboot
    exit 3
  else
    warn "reboot skipped; run 'systemctl reboot' when ready - setup resumes on boot"
    exit 3
  fi
}

install_resume_unit() {
  local self
  self="$(readlink -f "${NODE_SETUP_BIN:-$0}")"
  write_if_changed /etc/systemd/system/node-setup-resume.service <<EOF || true
# Managed by node-setup: resumes a provisioning run interrupted by a reboot.
# Removed automatically when the run completes.
[Unit]
Description=Resume node-setup provisioning after reboot
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$self --resume
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable node-setup-resume.service >/dev/null 2>&1
}

remove_resume_unit() {
  if [[ -f /etc/systemd/system/node-setup-resume.service ]]; then
    systemctl disable node-setup-resume.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/node-setup-resume.service
    systemctl daemon-reload
  fi
  rm -rf "$STATE_DIR/rebooted-for"
}

# --- doctor ----------------------------------------------------------------------
# Read-only: for every step report journal presence, check() and verify().
doctor_steps() {
  local step rc_check rc_verify state fails=0
  mkdir -p "$STATE_DIR"
  printf '%-28s %-9s %-8s %-8s\n' "STEP" "JOURNAL" "CHECK" "VERIFY"
  for step in "$@"; do
    _step_selected "$step" || continue
    if [[ -f "$STATE_DIR/state/$step.hash" ]]; then
      if [[ "$(cat "$STATE_DIR/state/$step.hash")" == "$(_step_hash "$step")" ]]; then
        state="done"
      else
        state="outdated"
      fi
    else
      state="-"
    fi
    if _has_fn "${step}::check"; then
      if _run_fn "${step}::check" >/dev/null 2>&1; then rc_check="ok"; else rc_check="FAIL"; fails=1; fi
    else rc_check="-"; fi
    if _has_fn "${step}::verify"; then
      if _run_fn "${step}::verify" >/dev/null 2>&1; then rc_verify="ok"; else rc_verify="FAIL"; fails=1; fi
    else rc_verify="-"; fi
    printf '%-28s %-9s %-8s %-8s\n' "$step" "$state" "$rc_check" "$rc_verify"
  done
  return "$fails"
}
