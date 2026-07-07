#!/usr/bin/env bash
# Kill MPI fullcore test processes on gateway and compute nodes (timeout/error cleanup).
set -euo pipefail

me="$(hostname -s)"

cleanup_local() {
    pkill -9 -f '[/]tests/mpi/fullcore_test' 2>/dev/null || true
    pkill -9 -f 'prterun' 2>/dev/null || true
    pkill -9 -f 'prted' 2>/dev/null || true
    pkill -9 -f 'orted' 2>/dev/null || true
}

cleanup_remote() {
    local h="$1"
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" \
        "pkill -9 -f '[/]tests/mpi/fullcore_test' 2>/dev/null || true; \
         pkill -9 -f 'prted' 2>/dev/null || true; \
         pkill -9 -f 'orted' 2>/dev/null || true" \
        2>/dev/null || true
}

if [[ $# -eq 0 ]]; then
    cleanup_local
    exit 0
fi

for h in "$@"; do
    if [[ "$h" == "$me" ]]; then
        cleanup_local
    else
        cleanup_remote "$h"
    fi
done
