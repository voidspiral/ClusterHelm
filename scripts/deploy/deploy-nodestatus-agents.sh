#!/usr/bin/env bash
# Deploy the standalone nodestatus node role to one configured partition.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SLAVES_CONF="$ROOT/master/config/slaves.conf"
SLAVE_CONF="$ROOT/slave/config/slave.conf"
PARTITION=""
BINARY=""
KEY_FILE=""
BATCH_SIZE=25
DRY_RUN=false
ACTION=install

usage() {
  echo "Usage: $0 --partition NAME [--binary FILE --key-file FILE] [--batch-size N] [--dry-run|--verify|--uninstall]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --partition) PARTITION="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --key-file) KEY_FILE="$2"; shift 2 ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verify) ACTION=verify; shift ;;
    --uninstall) ACTION=uninstall; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$PARTITION" && "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]] || usage
read -r GATEWAY _ NODESET < <(
  awk -v partition="$PARTITION" '$2 == partition {print $1, $2, $3; exit}' "$SLAVES_CONF"
)
[[ -n "${GATEWAY:-}" && -n "${NODESET:-}" ]] || {
  echo "Unknown partition: $PARTITION" >&2
  exit 2
}
if [[ "$ACTION" == install && "$DRY_RUN" == false ]]; then
  [[ -f "$BINARY" && -f "$KEY_FILE" ]] || {
    echo "--binary and --key-file are required for install" >&2
    exit 2
  }
fi

mapfile -t HOSTS < <(python3 - "$NODESET" <<'PY'
import re, sys
expr = sys.argv[1]
match = re.fullmatch(r"([A-Za-z]+)\[(.+)]", expr)
if not match:
    print(expr)
    raise SystemExit
prefix, body = match.groups()
for item in body.split(","):
    if "-" in item:
        raw_start, raw_end = item.split("-", 1)
        start, end = map(int, (raw_start, raw_end))
        width = len(raw_start)
        for number in range(start, end + 1):
            print(f"{prefix}{number:0{width}d}")
    else:
        print(f"{prefix}{item.strip()}")
PY
)

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cat >"$tmp_dir/agent.conf" <<EOF
partition $PARTITION
gateway_url http://$GATEWAY:$(awk '$1 == "nodestatus_listen" {n=split($2, a, ":"); print a[n]; exit}' "$SLAVE_CONF")
interval 20s
jitter 5s
key_id current
auth_key_file /etc/nodestatus/partition.key
EOF
cat >"$tmp_dir/nodestatus-agent.service" <<'EOF'
[Unit]
Description=nodestatus node agent
After=network-online.target

[Service]
ExecStart=/home/smt/agents/bin/nodestatus serve --role node --config /etc/nodestatus/agent.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

run_host() {
  local host="$1"
  if [[ "$DRY_RUN" == true ]]; then
    echo "$ACTION $PARTITION $host"
    return
  fi
  case "$ACTION" in
    verify)
      ssh -o ConnectTimeout=10 "$host" \
        "systemctl is-active --quiet nodestatus-agent.service && /home/smt/agents/bin/nodestatus --version"
      ;;
    uninstall)
      ssh -o ConnectTimeout=10 "$host" \
        "sudo systemctl disable --now nodestatus-agent.service 2>/dev/null || true;
         sudo rm -f /etc/systemd/system/nodestatus-agent.service /etc/nodestatus/agent.conf /etc/nodestatus/partition.key /home/smt/agents/bin/nodestatus;
         sudo systemctl daemon-reload"
      ;;
    install)
      scp -o ConnectTimeout=10 "$BINARY" "$tmp_dir/agent.conf" \
        "$tmp_dir/nodestatus-agent.service" "$KEY_FILE" "$host:/tmp/"
      ssh -o ConnectTimeout=10 "$host" \
        "sudo install -D -m 0755 '/tmp/$(basename "$BINARY")' /home/smt/agents/bin/nodestatus &&
         sudo install -D -m 0644 /tmp/agent.conf /etc/nodestatus/agent.conf &&
         sudo install -D -m 0600 '/tmp/$(basename "$KEY_FILE")' /etc/nodestatus/partition.key &&
         sudo install -m 0644 /tmp/nodestatus-agent.service /etc/systemd/system/nodestatus-agent.service &&
         sudo systemctl daemon-reload &&
         sudo systemctl enable --now nodestatus-agent.service"
      ;;
  esac
}

fail=0
for ((offset=0; offset<${#HOSTS[@]}; offset+=BATCH_SIZE)); do
  pids=()
  for host in "${HOSTS[@]:offset:BATCH_SIZE}"; do
    run_host "$host" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail=$((fail + 1))
  done
done
echo "$ACTION complete: partition=$PARTITION nodes=${#HOSTS[@]} failures=$fail"
[[ "$fail" -eq 0 ]]
