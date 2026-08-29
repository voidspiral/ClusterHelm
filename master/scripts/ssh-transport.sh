#!/usr/bin/env bash
# Shared Master→gateway SSH: ControlMaster reuse, stale-socket rebuild,
# bounded cold-connect concurrency, and a no-mux fallback.
set -euo pipefail

_clusterhelm_transport_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

_clusterhelm_conf_file() {
  if [[ -n "${CLUSTERHELM_MASTER_CONF:-}" && -f "${CLUSTERHELM_MASTER_CONF}" ]]; then
    echo "$CLUSTERHELM_MASTER_CONF"
    return
  fi
  local here
  here="$(_clusterhelm_transport_dir)"
  echo "$here/../config/master.conf"
}

_clusterhelm_conf_get() {
  local key="$1" fallback="$2" conf val
  conf="$(_clusterhelm_conf_file)"
  if [[ -f "$conf" ]]; then
    val=$(grep -E "^${key}[[:space:]]" "$conf" | awk '{print $2}' | head -1)
    [[ -n "$val" ]] && { echo "$val"; return; }
  fi
  echo "$fallback"
}

clusterhelm_ssh_control_dir() {
  echo "${CLUSTERHELM_SSH_CONTROL_DIR:-$HOME/.ssh/clusterhelm-cm}"
}

clusterhelm_ssh_control_path() {
  local host="$1"
  echo "$(clusterhelm_ssh_control_dir)/${host}"
}

clusterhelm_ssh_bin() {
  echo "${CLUSTERHELM_SSH_BIN:-ssh}"
}

clusterhelm_ssh_cold_limit() {
  echo "${CLUSTERHELM_SSH_COLD_LIMIT:-$(_clusterhelm_conf_get ssh_cold_connect_limit 2)}"
}

clusterhelm_ssh_connect_timeout() {
  echo "${CLUSTERHELM_SSH_CONNECT_TIMEOUT:-$(_clusterhelm_conf_get ssh_connect_timeout 15)}"
}

clusterhelm_ssh_control_persist() {
  echo "${CLUSTERHELM_SSH_CONTROL_PERSIST:-$(_clusterhelm_conf_get ssh_control_persist 60)}"
}

clusterhelm_ssh_alive_interval() {
  echo "${CLUSTERHELM_SSH_ALIVE_INTERVAL:-$(_clusterhelm_conf_get ssh_server_alive_interval 30)}"
}

clusterhelm_ssh_alive_count() {
  echo "${CLUSTERHELM_SSH_ALIVE_COUNT:-$(_clusterhelm_conf_get ssh_server_alive_count_max 3)}"
}

clusterhelm_ssh_multiplex_enabled() {
  [[ "${CLUSTERHELM_SSH_MULTIPLEX:-1}" != "0" ]]
}

clusterhelm_ssh_opts_list() {
  local host="$1" mux="${2:-auto}"
  printf '%s\n' "BatchMode=yes"
  printf '%s\n' "ConnectTimeout=$(clusterhelm_ssh_connect_timeout)"
  printf '%s\n' "ServerAliveInterval=$(clusterhelm_ssh_alive_interval)"
  printf '%s\n' "ServerAliveCountMax=$(clusterhelm_ssh_alive_count)"
  printf '%s\n' "StrictHostKeyChecking=accept-new"
  if [[ "$mux" == "no" ]] || ! clusterhelm_ssh_multiplex_enabled; then
    printf '%s\n' "ControlMaster=no"
    printf '%s\n' "ControlPath=none"
    return
  fi
  printf '%s\n' "ControlMaster=auto"
  printf '%s\n' "ControlPersist=$(clusterhelm_ssh_control_persist)"
  printf '%s\n' "ControlPath=$(clusterhelm_ssh_control_path "$host")"
}

clusterhelm_ssh_print_opts() {
  clusterhelm_ssh_opts_list "$1"
}

clusterhelm_mux_is_live() {
  local host="$1" path
  path="$(clusterhelm_ssh_control_path "$host")"
  [[ -e "$path" ]] || return 1
  "$(clusterhelm_ssh_bin)" -O check \
    -o "ControlPath=$path" \
    -o ControlMaster=no \
    "$host" >/dev/null 2>&1
}

clusterhelm_prepare_mux() {
  local host="$1" dir path
  dir="$(clusterhelm_ssh_control_dir)"
  mkdir -p -m 0700 "$dir"
  chmod 0700 "$dir" 2>/dev/null || true
  clusterhelm_ssh_multiplex_enabled || return 0
  path="$(clusterhelm_ssh_control_path "$host")"
  if [[ -e "$path" ]] && ! clusterhelm_mux_is_live "$host"; then
    "$(clusterhelm_ssh_bin)" -O exit \
      -o "ControlPath=$path" \
      -o ControlMaster=no \
      "$host" >/dev/null 2>&1 || true
    rm -f "$path"
  fi
}

_clusterhelm_build_ssh_cmd() {
  local host="$1" mux="$2"
  local -n _cmd=$3
  local opt
  _cmd=("$(clusterhelm_ssh_bin)")
  while IFS= read -r opt; do
    [[ -n "$opt" ]] || continue
    _cmd+=(-o "$opt")
  done < <(clusterhelm_ssh_opts_list "$host" "$mux")
  _cmd+=("$host")
}

_clusterhelm_with_cold_lock() {
  local host="$1"
  shift
  local dir limit i lock fd
  dir="$(clusterhelm_ssh_control_dir)"
  limit="$(clusterhelm_ssh_cold_limit)"
  mkdir -p -m 0700 "$dir"
  for i in $(seq 1 "$limit"); do
    lock="$dir/cold.${host}.${i}.lock"
    exec {fd}>"$lock"
    if flock -n "$fd"; then
      local rc=0
      "$@" && rc=0 || rc=$?
      eval "exec ${fd}>&-"
      return "$rc"
    fi
    eval "exec ${fd}>&-"
  done
  lock="$dir/cold.${host}.1.lock"
  exec {fd}>"$lock"
  flock "$fd"
  local rc=0
  "$@" && rc=0 || rc=$?
  eval "exec ${fd}>&-"
  return "$rc"
}

_clusterhelm_run_ssh() {
  local -a cmd
  _clusterhelm_build_ssh_cmd "$1" "$2" cmd
  shift 2
  cmd+=("$@")
  "${cmd[@]}"
}

clusterhelm_ssh() {
  local host="$1"
  shift
  local remote="$*"
  local rc=0
  clusterhelm_prepare_mux "$host"
  if clusterhelm_ssh_multiplex_enabled && clusterhelm_mux_is_live "$host"; then
    _clusterhelm_run_ssh "$host" auto "$remote" || rc=$?
  else
    _clusterhelm_with_cold_lock "$host" \
      _clusterhelm_run_ssh "$host" auto "$remote" || rc=$?
  fi
  if [[ "$rc" -eq 255 ]] && clusterhelm_ssh_multiplex_enabled; then
    _clusterhelm_run_ssh "$host" no "$remote" || rc=$?
  fi
  return "$rc"
}

clusterhelm_parse_follow_output() {
  # stdin: submit lines, CLUSTERHELM_JOB_JSON marker, then wait JSON
  # stdout: JSON; stderr unused; prints job_id to fd 3 if open
  local job_id="" line json=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == job_id=* && -z "$job_id" ]]; then
      job_id="${line#job_id=}"
      continue
    fi
    if [[ "$line" == "CLUSTERHELM_JOB_JSON" ]]; then
      json=$(cat)
      break
    fi
  done
  if [[ -n "$job_id" && -e /dev/fd/3 ]]; then
    printf '%s\n' "$job_id" >&3
  fi
  printf '%s\n' "$json"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    print-opts) clusterhelm_ssh_print_opts "${1:?host}" ;;
    prepare) clusterhelm_prepare_mux "${1:?host}" ;;
    ssh)
      host="${1:?host}"
      shift
      clusterhelm_ssh "$host" "$@"
      ;;
    *)
      echo "Usage: $0 print-opts HOST | prepare HOST | ssh HOST CMD" >&2
      exit 1
      ;;
  esac
fi
