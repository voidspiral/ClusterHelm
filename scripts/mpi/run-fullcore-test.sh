#!/usr/bin/env bash
# Full-core MPI test for a logical partition (default: test). Run on Slave gateway (cn1).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARTITION="${1:-test}"
SRC="$ROOT/tests/mpi/fullcore_test.c"
BIN="$ROOT/tests/mpi/fullcore_test"
JOBS_DIR="$ROOT/scripts/jobs"

if [[ "$(hostname -s)" != cn1 ]]; then
    echo "skip: MPI launcher runs on cn1 gateway"
    exit 0
fi

command -v mpicc >/dev/null || { echo "FAIL: mpicc not found"; exit 1; }
command -v mpirun >/dev/null || { echo "FAIL: mpirun not found"; exit 1; }
[[ -f "$SRC" ]] || { echo "FAIL: missing $SRC"; exit 1; }

NODESET="$("$JOBS_DIR/resolve-partition.py" "$PARTITION")"
mapfile -t HOSTS < <(python3 - "$NODESET" <<'PY'
import re, sys
expr = sys.argv[1]
m = re.match(r"^([a-zA-Z]+)\[(.+)\]$", expr)
if not m:
    print(expr)
    raise SystemExit
prefix, inner = m.group(1), m.group(2)
for part in inner.split(","):
    part = part.strip()
    if "-" in part:
        a, b = part.split("-", 1)
        for i in range(int(a), int(b) + 1):
            print(f"{prefix}{i}")
    else:
        print(f"{prefix}{part}")
PY
)

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

me="$(hostname -s)"
for h in "${HOSTS[@]}"; do
    if [[ "$h" == "$me" ]]; then
        echo "$h" >"$tmpdir/$h"
    else
        (
            ping -c1 -W1 "$h" >/dev/null 2>&1 \
                && ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" true >/dev/null 2>&1 \
                && echo "$h" >"$tmpdir/$h"
        ) &
    fi
done
wait

mapfile -t reachable < <(ls "$tmpdir" 2>/dev/null | sort -V)

NP=0
HA=""
for h in "${reachable[@]}"; do
    if [[ "$h" == "$me" ]]; then
        slots="$(nproc)"
    else
        slots="$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" nproc)"
    fi
    NP=$((NP + slots))
    HA="${HA},${h}:${slots}"
done
HA="${HA#,}"

if [[ ${#reachable[@]} -eq 0 || "$NP" -eq 0 ]]; then
    echo "FAIL: no reachable hosts in partition $PARTITION ($NODESET)"
    exit 1
fi

echo "=== fullcore MPI test: partition=$PARTITION nodeset=$NODESET ==="
echo "reachable: ${reachable[*]}"
echo "np=$NP host=$HA"

mpicc -O2 -o "$BIN" "$SRC"
for h in "${reachable[@]}"; do
    if [[ "$h" != "$me" ]]; then
        ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" "mkdir -p $(dirname "$BIN")"
        scp -o ConnectTimeout=5 -o BatchMode=yes "$BIN" "$h:$BIN"
    fi
done

mpirun -n "$NP" --allow-run-as-root -host "$HA" "$BIN"
rc=$?
echo "=== exit $rc ==="
exit "$rc"
