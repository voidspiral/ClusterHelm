#!/usr/bin/env bash
# Full-core MPI test for a logical partition (default: test). Run on Slave gateway (cn1).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARTITION="${1:-test}"
DURATION="${2:-0}"
CPU_INTERVAL="${3:-2}"
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
if [[ "$DURATION" -gt 0 ]]; then
    echo "duration=${DURATION}s cpu_sample_interval=${CPU_INTERVAL}s"
fi

read_cpu_pct() {
    local u1 s1 u2 s2
    read u1 s1 < <(awk '/^cpu / {idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8; print total-idle, total; exit}' /proc/stat)
    sleep 1
    read u2 s2 < <(awk '/^cpu / {idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8; print total-idle, total; exit}' /proc/stat)
    if (( s2 > s1 )); then
        awk -v u1="$u1" -v s1="$s1" -v u2="$u2" -v s2="$s2" 'BEGIN {printf "%.1f", 100*(1-(u2-u1)/(s2-s1))}'
    else
        echo "0.0"
    fi
}

cpu_monitor_loop() {
    local host="$1" out="$2" dur="$3" interval="$4"
    local end=$((SECONDS + dur + 20))
    while (( SECONDS < end )); do
        if read -r pct < <(read_cpu_pct); then
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) host=$host cpu_pct=${pct:-?}"
        fi
        sleep "$interval"
    done >>"$out"
}

MON_PIDS=()
MON_FILES=()
CLEANUP_HOSTS=("${reachable[@]}")

cleanup_mpi() {
    local h
    echo "=== cleanup MPI processes ==="
    for h in "${CLEANUP_HOSTS[@]}"; do
        if [[ "$h" == "$me" ]]; then
            pkill -9 -f '[/]tests/mpi/fullcore_test' 2>/dev/null || true
            pkill -9 -f 'prterun' 2>/dev/null || true
            pkill -9 -f 'prted' 2>/dev/null || true
        else
            ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" \
                "pkill -9 -f '[/]tests/mpi/fullcore_test' 2>/dev/null || true; \
                 pkill -9 -f 'prted' 2>/dev/null || true" \
                2>/dev/null || true
        fi
    done
}

on_exit() {
    stop_cpu_monitors 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap on_exit EXIT

start_cpu_monitors() {
    local dur="$1" interval="$2"
    for h in "${reachable[@]}"; do
        local f="$tmpdir/cpu_${h}.log"
        MON_FILES+=("$f")
        : >"$f"
        if [[ "$h" == "$me" ]]; then
            cpu_monitor_loop "$h" "$f" "$dur" "$interval" &
            MON_PIDS+=($!)
        else
            ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" "bash -s" "$h" "$dur" "$interval" >>"$f" <<'REMOTE' &
read_cpu_pct() {
    local u1 s1 u2 s2
    read u1 s1 < <(awk '/^cpu / {idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8; print total-idle, total; exit}' /proc/stat)
    sleep 1
    read u2 s2 < <(awk '/^cpu / {idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8; print total-idle, total; exit}' /proc/stat)
    if (( s2 > s1 )); then
        awk -v u1="$u1" -v s1="$s1" -v u2="$u2" -v s2="$s2" 'BEGIN {printf "%.1f", 100*(1-(u2-u1)/(s2-s1))}'
    else
        echo "0.0"
    fi
}
host=$1; dur=$2; interval=$3
end=$((SECONDS + dur + 20))
while (( SECONDS < end )); do
    pct=$(read_cpu_pct)
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) host=${host} cpu_pct=${pct:-?}"
    sleep "$interval"
done
REMOTE
            MON_PIDS+=($!)
        fi
    done
}

stop_cpu_monitors() {
    local p
    for p in "${MON_PIDS[@]}"; do
        kill "$p" 2>/dev/null || true
    done
    wait "${MON_PIDS[@]}" 2>/dev/null || true
}

summarize_cpu() {
    echo "=== CPU samples during MPI (interval=${CPU_INTERVAL}s) ==="
    for h in "${reachable[@]}"; do
        local f="$tmpdir/cpu_${h}.log"
        [[ -f "$f" ]] || continue
        python3 - "$h" "$f" <<'PY'
import re, sys
host, path = sys.argv[1:3]
vals = []
for line in open(path):
    m = re.search(r"cpu_pct=([\d.]+)", line)
    if m:
        vals.append(float(m.group(1)))
if not vals:
    print(f"- {host}: no samples")
else:
    print(f"- {host}: n={len(vals)} avg={sum(vals)/len(vals):.1f}% min={min(vals):.1f}% max={max(vals):.1f}%")
PY
    done
}

mpicc -O2 -o "$BIN" "$SRC"
for h in "${reachable[@]}"; do
    if [[ "$h" != "$me" ]]; then
        ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" "mkdir -p $(dirname "$BIN")"
        scp -o ConnectTimeout=5 -o BatchMode=yes "$BIN" "$h:${BIN}.new"
        ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" "mv -f ${BIN}.new ${BIN}"
    fi
done

MPI_ARGS=()
if [[ "$DURATION" -gt 0 ]]; then
    MPI_ARGS=("$DURATION")
    start_cpu_monitors "$DURATION" "$CPU_INTERVAL"
fi

set +e
mpi_timeout=$((DURATION + 30))
[[ "$DURATION" -le 0 ]] && mpi_timeout=60
timeout "$mpi_timeout" mpirun -n "$NP" --allow-run-as-root -host "$HA" "$BIN" "${MPI_ARGS[@]}" \
    >"$tmpdir/mpirun.out" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 124 ]]; then
    echo "FAIL: mpirun timeout after ${mpi_timeout}s"
    cleanup_mpi
elif [[ "$rc" -ne 0 ]]; then
    cleanup_mpi
fi
cat "$tmpdir/mpirun.out"
if [[ "$DURATION" -gt 0 ]]; then
    stop_cpu_monitors
    summarize_cpu
fi
echo "=== exit $rc ==="
exit "$rc"
