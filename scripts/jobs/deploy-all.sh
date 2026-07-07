#!/usr/bin/env bash
# Deploy Master (local) + Slave gateway(s).
set -euo pipefail

JOBS_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY="${1:-cn1}"
MASTER_TARGET="${2:-local}"

echo "== Deploy all: master=$MASTER_TARGET slave=$GATEWAY =="
"$JOBS_DIR/deploy-master.sh" "$MASTER_TARGET"
"$JOBS_DIR/deploy-slave.sh" "$GATEWAY"
echo "== All deployments complete =="
