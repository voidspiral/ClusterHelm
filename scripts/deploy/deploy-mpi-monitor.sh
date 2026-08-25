#!/usr/bin/env bash
# Deploy mpi-monitor CLI to the Slave gateway (not part of deploy-slave.sh).
# Compute nodes cn2–cnN do not need this package; wrap sends an inline payload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${MPI_MONITOR_SRC:-/home/voidspiral/code/mpi-monitor}"
MASTER_CONF="$ROOT/master/config/master.conf"
GATEWAY="${1:-cn1}"
WITH_PLOT="${MPI_MONITOR_PLOT:-0}"

REMOTE_PROJECT="$(
  awk '{ sub(/\r$/, "") } $1 == "remote_project" { print $2; exit }' "$MASTER_CONF" 2>/dev/null \
    || true
)"
[[ -n "$REMOTE_PROJECT" ]] || {
  echo "ERROR: set remote_project in $MASTER_CONF" >&2
  exit 1
}
REMOTE_DEST="$REMOTE_PROJECT/vendor/mpi-monitor"

[[ -f "$SRC/pyproject.toml" ]] || {
  echo "ERROR: mpi-monitor source not found: $SRC (set MPI_MONITOR_SRC)" >&2
  exit 1
}

echo "== Deploy mpi-monitor CLI to $GATEWAY =="
echo "  src:  $SRC"
echo "  dest: $GATEWAY:$REMOTE_DEST"

ssh -o ConnectTimeout=15 "$GATEWAY" "mkdir -p '$REMOTE_DEST'"

tar -C "$SRC" \
  --exclude=.git \
  --exclude=runs \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude=.cursor \
  -cf - . \
| ssh -o ConnectTimeout=15 "$GATEWAY" "tar -C '$REMOTE_DEST' -xf -"

PIP_EXTRA=""
if [[ "$WITH_PLOT" == "1" || "$WITH_PLOT" == "true" ]]; then
  PIP_EXTRA='[plot]'
fi

ssh -o ConnectTimeout=15 "$GATEWAY" "
  set -euo pipefail
  dest='$REMOTE_DEST'
  extra='$PIP_EXTRA'
  if python3 -m venv \"\$dest/.venv\"; then
    \"\$dest/.venv/bin/pip\" install -e \"\${dest}\${extra}\"
    \"\$dest/.venv/bin/python\" -c 'import mpi_monitor; print(\"import_ok\", mpi_monitor.__version__)'
    \"\$dest/.venv/bin/mpi-monitor\" --help >/dev/null
    echo 'cli_ok' \"\$dest/.venv/bin/mpi-monitor\"
  else
    echo 'venv unavailable; falling back to PYTHONPATH src' >&2
    PYTHONPATH=\"\$dest/src\${PYTHONPATH:+:\$PYTHONPATH}\" python3 -c 'import mpi_monitor; print(\"import_ok\", mpi_monitor.__version__)'
    PYTHONPATH=\"\$dest/src\${PYTHONPATH:+:\$PYTHONPATH}\" python3 -m mpi_monitor --help >/dev/null
    echo 'cli_ok PYTHONPATH='\"\$dest/src\"' python3 -m mpi_monitor'
  fi
"

echo "== Done =="
echo "  CLI tree: $GATEWAY:$REMOTE_DEST"
echo "  Note:     cn2–cnN need no package; wrap uses SSH inline payload"
echo "  Skill:    ./scripts/deploy/deploy-slave.sh $GATEWAY"
