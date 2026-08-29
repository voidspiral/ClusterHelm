#!/usr/bin/env bash
# Deploy Slave agent, deterministic workflows, and their runtime scripts.
# partitions.conf is copied from Master SoT (master/config/) — Slave does not own slaves.conf.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SLAVE_DIR="$ROOT/slave"
MASTER_CONFIG="$ROOT/master/config"
MASTER_CONF="$MASTER_CONFIG/master.conf"
GATEWAY="cn1"
NODESTATUS_BINARY="${NODESTATUS_BINARY:-}"
NODESTATUS_CONFIG="${NODESTATUS_GATEWAY_CONFIG:-}"
NODESTATUS_KEY_FILE="${NODESTATUS_KEY_FILE:-}"
REMOTE_PROJECT_OVERRIDE=""
PRINT_CONFIG=0

read_master_default() {
  local key="$1" fallback="$2"
  if [[ -f "$MASTER_CONF" ]]; then
    local v
    v=$(awk -v key="$key" '{ sub(/\r$/, "") } $1 == key { print $2; exit }' "$MASTER_CONF")
    [[ -n "$v" ]] && { echo "$v"; return; }
  fi
  echo "$fallback"
}

if [[ $# -gt 0 && "$1" != --* ]]; then
  GATEWAY="$1"
  shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodestatus-binary) NODESTATUS_BINARY="$2"; shift 2 ;;
    --nodestatus-config) NODESTATUS_CONFIG="$2"; shift 2 ;;
    --nodestatus-key-file) NODESTATUS_KEY_FILE="$2"; shift 2 ;;
    --remote-project) REMOTE_PROJECT_OVERRIDE="$2"; shift 2 ;;
    --print-config) PRINT_CONFIG=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Deploy root on the gateway: master.conf remote_project (same key submit/poll-wait use).
if [[ -n "$REMOTE_PROJECT_OVERRIDE" ]]; then
  REMOTE_PROJECT="$REMOTE_PROJECT_OVERRIDE"
else
  REMOTE_PROJECT="$(read_master_default remote_project "")"
fi
[[ -n "$REMOTE_PROJECT" ]] || {
  echo "ERROR: set remote_project in $MASTER_CONF" >&2
  exit 1
}
REMOTE_JOB_DIR="$REMOTE_PROJECT/var/agent-jobs"

if [[ "$PRINT_CONFIG" -eq 1 ]]; then
  echo "gateway=$GATEWAY"
  echo "remote_project=$REMOTE_PROJECT"
  echo "remote_job_dir=$REMOTE_JOB_DIR"
  exit 0
fi
NODESTATUS_SKILL="$SLAVE_DIR/.opencode/skills/nodestatus"
SLAVE_AGENT="$SLAVE_DIR/.opencode/agents/slave-agent.md"

conf_value() {
  awk -v key="$1" '{ sub(/\r$/, "") } $1 == key {print $2; exit}' \
    "$SLAVE_DIR/config/slave.conf"
}

require_file() {
  [[ -s "$1" ]] || {
    echo "Required Slave asset is missing or empty: $1" >&2
    exit 2
  }
}

require_skill_field() {
  local key="$1" expected="$2"
  awk -v key="$key" -v expected="$expected" \
    '{ sub(/\r$/, "") } $1 == key && $2 == expected { found=1 } END { exit !found }' \
    "$NODESTATUS_SKILL/SKILL.md" || {
      echo "nodestatus SKILL.md missing '$key $expected'" >&2
      exit 2
    }
}

echo "== Validate Slave OpenCode bundle =="
for file in SKILL.md SKILL.zh.md reference.md README.zh.md; do
  require_file "$NODESTATUS_SKILL/$file"
done
require_file "$SLAVE_AGENT"
require_skill_field "name:" "nodestatus"
require_skill_field "compatibility:" "opencode"
require_skill_field "role:" "slave"
require_skill_field "deploy:" "deploy-slave.sh"
awk '{ sub(/\r$/, "") } $1 == "nodestatus:" && $2 == "allow" { found=1 } END { exit !found }' \
  "$SLAVE_AGENT" || {
    echo "slave-agent.md does not grant 'nodestatus: allow'" >&2
    exit 2
  }

for key in \
  nodestatus_enabled \
  nodestatus_bin \
  nodestatus_gateway_config \
  nodestatus_query_timeout \
  nodestatus_unix_socket \
  nodestatus_listen \
  nodestatus_freshness \
  nodestatus_heartbeat_timeout \
  nodestatus_key_file \
  agent_opencode_bin; do
  [[ -n "$(conf_value "$key")" ]] || {
    echo "slave.conf missing required value: $key" >&2
    exit 2
  }
done

if [[ -z "$NODESTATUS_CONFIG" ]]; then
  NODESTATUS_CONFIG="$(conf_value nodestatus_gateway_config)"
fi
NODESTATUS_KEY_PATH="$(conf_value nodestatus_key_file)"
NODESTATUS_BIN_PATH="$(conf_value nodestatus_bin)"
OPENCODE_BIN_PATH="$(conf_value agent_opencode_bin)"
NODESTATUS_ENABLED="$(conf_value nodestatus_enabled)"
echo "  nodestatus skill, permission, and config: valid"

echo "opencode src: $SLAVE_DIR/.opencode"
echo "remote_project (master.conf): $REMOTE_PROJECT"
echo "opencode dest: $GATEWAY:$REMOTE_PROJECT/.opencode"

echo "== Deploy slave agent to $GATEWAY ($REMOTE_PROJECT) =="

# Keep host-specific OpenCode path if the repo default is not installed on the gateway.
EXISTING_OPENCODE_BIN="$(
  ssh -o ConnectTimeout=15 "$GATEWAY" \
    "awk '\$1==\"agent_opencode_bin\"{print \$2; exit}' '$REMOTE_PROJECT/config/slave.conf' 2>/dev/null || true"
)"

ssh -o ConnectTimeout=15 "$GATEWAY" \
  "mkdir -p '$REMOTE_JOB_DIR' \
    '$REMOTE_PROJECT/scripts/monitor' \
    '$REMOTE_PROJECT/scripts/mpi' \
    '$REMOTE_PROJECT/tests/mpi'"

# Sync the whole slave/ tree to remote_project. Do not touch var/ (job store).
echo "  Syncing slave/ → $GATEWAY:$REMOTE_PROJECT/"
tar -C "$SLAVE_DIR" \
  --exclude=var \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude=.git \
  -cf - . \
| ssh -o ConnectTimeout=15 "$GATEWAY" "tar -C '$REMOTE_PROJECT' -xf -"
echo "  Slave tree:  $GATEWAY:$REMOTE_PROJECT/"

if [[ -d "$SLAVE_DIR/.opencode" ]]; then
  ssh -o ConnectTimeout=15 "$GATEWAY" "
    set -e
    for file in SKILL.md SKILL.zh.md reference.md README.zh.md; do
      path='$REMOTE_PROJECT/.opencode/skills/nodestatus/'\"\$file\"
      if [[ ! -s \"\$path\" ]]; then
        echo \"Remote nodestatus skill asset is missing or empty: \$path\" >&2
        exit 2
      fi
    done
    agent='$REMOTE_PROJECT/.opencode/agents/slave-agent.md'
    if [[ ! -s \"\$agent\" ]]; then
      echo \"Remote Slave agent is missing or empty: \$agent\" >&2
      exit 2
    fi
    awk '{ sub(/\\r\$/, \"\") } \$1 == \"nodestatus:\" && \$2 == \"allow\" { found=1 } END { exit !found }' \
      \"\$agent\" || {
        echo \"Remote Slave agent does not grant nodestatus: allow\" >&2
        exit 2
      }
  "
  echo "  OpenCode validation: remote bundle complete"
fi

# Master SoT overlay: partitions.conf (slave.conf already came from slave/)
scp -o ConnectTimeout=15 \
  "$MASTER_CONFIG/partitions.conf" \
  "$GATEWAY:$REMOTE_PROJECT/config/partitions.conf"

# Workflow implementations live under repo scripts/, not slave/.
scp -o ConnectTimeout=15 \
  "$ROOT/scripts/monitor/mem-api.sh" \
  "$ROOT/scripts/monitor/memmon.py" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/monitor/"

scp -o ConnectTimeout=15 \
  "$ROOT/scripts/mpi/run-fullcore-test.sh" \
  "$ROOT/scripts/mpi/cleanup-mpi.sh" \
  "$GATEWAY:$REMOTE_PROJECT/scripts/mpi/"

scp -o ConnectTimeout=15 \
  "$ROOT/tests/mpi/fullcore_test.c" \
  "$GATEWAY:$REMOTE_PROJECT/tests/mpi/"

check_nodestatus_binary=true
[[ -n "$NODESTATUS_BINARY" ]] && check_nodestatus_binary=false
ssh -o ConnectTimeout=15 "$GATEWAY" "
  set -e
  conf='$REMOTE_PROJECT/config/slave.conf'
  want='$OPENCODE_BIN_PATH'
  existing='${EXISTING_OPENCODE_BIN:-}'
  if [[ -x \"\$want\" ]]; then
    :
  elif [[ -n \"\$existing\" && -x \"\$existing\" ]]; then
    tmp=\$(mktemp)
    awk -v bin=\"\$existing\" '
      \$1==\"agent_opencode_bin\" { print \"agent_opencode_bin \" bin; next }
      { print }
    ' \"\$conf\" > \"\$tmp\" && cat \"\$tmp\" > \"\$conf\" && rm -f \"\$tmp\"
    echo \"  Preserved gateway OpenCode: \$existing\" >&2
  else
    echo \"Configured OpenCode binary is not executable: \$want\" >&2
    exit 2
  fi
  if [[ '$NODESTATUS_ENABLED' =~ ^(1|true|yes|on)$ ]] && $check_nodestatus_binary; then
    test -x '$NODESTATUS_BIN_PATH' || {
      echo 'Configured nodestatus binary is not executable: $NODESTATUS_BIN_PATH' >&2
      exit 2
    }
  fi
  chmod +x \
    '$REMOTE_PROJECT/scripts/run-slave.sh' \
    '$REMOTE_PROJECT/scripts/job_complete.py' \
    '$REMOTE_PROJECT/scripts/resolve-partition.py' \
    '$REMOTE_PROJECT/scripts/preflight/job_preflight.py' \
    '$REMOTE_PROJECT/scripts/preflight/node_exclude.py' \
    '$REMOTE_PROJECT/scripts/preflight/nodestatus_client.py' \
    '$REMOTE_PROJECT/scripts/workflows/workflow_runner.py' \
    '$REMOTE_PROJECT/scripts/monitor/mem-api.sh' \
    '$REMOTE_PROJECT/scripts/monitor/memmon.py' \
    '$REMOTE_PROJECT/scripts/mpi/run-fullcore-test.sh' \
    '$REMOTE_PROJECT/scripts/mpi/cleanup-mpi.sh'
  owner=\$(stat -c %U:%G '$REMOTE_PROJECT' 2>/dev/null || true)
  if [[ -n \"\$owner\" && \"\$owner\" != *unknown* ]]; then
    find '$REMOTE_PROJECT' -mindepth 1 -maxdepth 1 ! -name var -exec chown -R \"\$owner\" {} +
  fi
"
echo "  Runtime binaries: configured paths are executable"
echo "  $REMOTE_JOB_DIR left intact (job store not overwritten)"

# --- nodestatus gateway config/service (binary and key may already exist) ---
if [[ "$NODESTATUS_ENABLED" =~ ^(1|true|yes|on)$ ]]; then
  read -r _ partition registry_nodeset < <(
    awk -v gateway="$GATEWAY" '$1 == gateway { print $1, $2, $3; exit }' \
      "$MASTER_CONFIG/slaves.conf"
  )
  [[ -n "${partition:-}" && -n "${registry_nodeset:-}" ]] || {
    echo "No slaves.conf entry for gateway $GATEWAY" >&2
    exit 2
  }
  nodeset="$(
    awk -v partition="$partition" \
      '$1 == partition { print $2; exit }' "$MASTER_CONFIG/partitions.conf"
  )"
  [[ -n "$nodeset" ]] || {
    echo "No partitions.conf entry for partition $partition" >&2
    exit 2
  }
  [[ "$registry_nodeset" == "$nodeset" ]] || {
    echo "nodeset mismatch for $partition: slaves.conf=$registry_nodeset partitions.conf=$nodeset" >&2
    exit 2
  }
  [[ -z "$NODESTATUS_BINARY" || -f "$NODESTATUS_BINARY" ]] || {
    echo "nodestatus binary not found: $NODESTATUS_BINARY" >&2
    exit 2
  }
  [[ -z "$NODESTATUS_KEY_FILE" || -f "$NODESTATUS_KEY_FILE" ]] || {
    echo "nodestatus key file not found: $NODESTATUS_KEY_FILE" >&2
    exit 2
  }

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  cat >"$tmp_dir/gateway.conf" <<EOF
partition $partition
nodeset $nodeset
socket_path $(conf_value nodestatus_unix_socket)
listen $(conf_value nodestatus_listen)
store_path $REMOTE_JOB_DIR/node-status.json
exclusion_store_path $REMOTE_JOB_DIR/node-status-exclusions.json
legacy_exclusion_path $REMOTE_JOB_DIR/node-exclusions.json
freshness $(conf_value nodestatus_freshness)
heartbeat_timeout $(conf_value nodestatus_heartbeat_timeout)
auth_key_file $NODESTATUS_KEY_PATH
key_id current
auto_recover true
auto_recover_threshold 3
EOF
  cat >"$tmp_dir/nodestatus-gateway.service" <<EOF
[Unit]
Description=nodestatus partition gateway
After=network-online.target

[Service]
ExecStart=$NODESTATUS_BIN_PATH serve --role gateway --config $NODESTATUS_CONFIG
Restart=on-failure
RuntimeDirectory=nodestatus
StateDirectory=nodestatus
ProtectSystem=strict
ReadWritePaths=/run/nodestatus /var/lib/nodestatus $REMOTE_JOB_DIR

[Install]
WantedBy=multi-user.target
EOF
  scp -o ConnectTimeout=15 "$tmp_dir/gateway.conf" "$GATEWAY:/tmp/gateway.conf"
  scp -o ConnectTimeout=15 "$tmp_dir/nodestatus-gateway.service" \
    "$GATEWAY:/tmp/nodestatus-gateway.service"
  install_binary=false
  install_key=false
  if [[ -n "$NODESTATUS_BINARY" ]]; then
    scp -o ConnectTimeout=15 "$NODESTATUS_BINARY" "$GATEWAY:/tmp/nodestatus"
    install_binary=true
  fi
  if [[ -n "$NODESTATUS_KEY_FILE" ]]; then
    scp -o ConnectTimeout=15 "$NODESTATUS_KEY_FILE" "$GATEWAY:/tmp/partition.key"
    install_key=true
  fi
  ssh "$GATEWAY" "
    set -e
    if $install_binary; then
      sudo install -D -m 0755 /tmp/nodestatus '$NODESTATUS_BIN_PATH'
    else
      test -x '$NODESTATUS_BIN_PATH'
    fi
    if $install_key; then
      sudo install -D -m 0600 /tmp/partition.key '$NODESTATUS_KEY_PATH'
    else
      sudo test -s '$NODESTATUS_KEY_PATH'
    fi
    sudo install -D -m 0600 /tmp/gateway.conf '$NODESTATUS_CONFIG'
    sudo install -m 0644 /tmp/nodestatus-gateway.service /etc/systemd/system/nodestatus-gateway.service
    sudo mkdir -p /var/lib/nodestatus
    sudo systemctl daemon-reload
    sudo systemctl enable --now nodestatus-gateway.service
    sudo systemctl restart nodestatus-gateway.service
  "
  echo "  nodestatus:  $GATEWAY:$NODESTATUS_BIN_PATH ($partition $nodeset)"
fi

echo "== Done =="
echo "  OpenCode:    $GATEWAY:$REMOTE_PROJECT/.opencode/ (agents + skills)"
echo "  Job runner:  $GATEWAY:$REMOTE_PROJECT/scripts/run-slave.sh"
echo "  Workflows:   $GATEWAY:$REMOTE_PROJECT/workflows/"
echo "  Preflight:   $GATEWAY:$REMOTE_PROJECT/scripts/preflight/"
echo "  Config:      $GATEWAY:$REMOTE_PROJECT/config/{slave,partitions}.conf"
echo "  Job store:   $GATEWAY:$REMOTE_JOB_DIR/"
