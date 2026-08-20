#!/bin/bash
# Repeatedly installs and uninstalls to validate consistent start/stop
# behavior. Each cycle: make install -> wait for a Running 1/1 seismic-app pod
# -> pause -> make uninstall -> wait for no seismic-app pods left. Stops
# immediately on the first cycle that fails either wait, rather than
# continuing to loop.
#
# Usage:
#   ./test/scripts/soak-install-uninstall.sh <namespace> [max_runs]
#
# Env overrides:
#   INSTALL_TIMEOUT   seconds to wait for the pod to become Running 1/1 (default 600)
#   UNINSTALL_TIMEOUT seconds to wait for all seismic-app pods to disappear (default 300)
#   POLL_INTERVAL     seconds between polls (default 5)
#   POST_INSTALL_DELAY seconds to wait after install completes before uninstalling (default 30)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

NAMESPACE="${1:-}"
MAX_RUNS="${2:-100}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-600}"
UNINSTALL_TIMEOUT="${UNINSTALL_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
POST_INSTALL_DELAY="${POST_INSTALL_DELAY:-30}"

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace> [max_runs]"
    exit 1
fi

wait_for_pod_ready() {
    local deadline=$(( $(date +%s) + INSTALL_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local line
        line=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep '^seismic-app' | head -1)
        if [ -n "$line" ]; then
            local ready status
            ready=$(echo "$line" | awk '{print $2}')
            status=$(echo "$line" | awk '{print $3}')
            local ready_count total_count
            ready_count="${ready%%/*}"
            total_count="${ready#*/}"
            if [ "$status" = "Running" ] && [ -n "$ready_count" ] && [ "$ready_count" = "$total_count" ]; then
                return 0
            fi
        fi
        sleep "$POLL_INTERVAL"
    done
    return 1
}

wait_for_no_pods() {
    local deadline=$(( $(date +%s) + UNINSTALL_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local count
        count=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c '^seismic-app')
        if [ "$count" -eq 0 ]; then
            return 0
        fi
        sleep "$POLL_INTERVAL"
    done
    return 1
}

echo "=== Soak test: up to $MAX_RUNS install/uninstall cycles in namespace '$NAMESPACE' ==="

for i in $(seq 1 "$MAX_RUNS"); do
    START=$(date +%s)
    echo ""
    echo "=== Run $i/$MAX_RUNS: make install NAMESPACE=$NAMESPACE ==="
    INSTALL_START=$(date +%s)
    if ! make install NAMESPACE="$NAMESPACE"; then
        echo "FAILED (run $i): 'make install' itself returned an error."
        exit 1
    fi

    echo "Waiting up to ${INSTALL_TIMEOUT}s for a seismic-app pod to reach Running with all containers ready..."
    if ! wait_for_pod_ready; then
        echo "FAILED (run $i): no seismic-app pod reached Running/Ready within ${INSTALL_TIMEOUT}s."
        oc get pods -n "$NAMESPACE"
        exit 1
    fi
    INSTALL_ELAPSED=$(( $(date +%s) - INSTALL_START ))
    echo "Run $i: install complete (${INSTALL_ELAPSED}s)."

    echo "Waiting ${POST_INSTALL_DELAY}s before uninstalling..."
    sleep "$POST_INSTALL_DELAY"

    echo "=== Run $i/$MAX_RUNS: make uninstall NAMESPACE=$NAMESPACE ==="
    UNINSTALL_START=$(date +%s)
    if ! make uninstall NAMESPACE="$NAMESPACE"; then
        echo "FAILED (run $i): 'make uninstall' itself returned an error."
        exit 1
    fi

    echo "Waiting up to ${UNINSTALL_TIMEOUT}s for all seismic-app pods to disappear..."
    if ! wait_for_no_pods; then
        echo "FAILED (run $i): seismic-app pod(s) did not stop within ${UNINSTALL_TIMEOUT}s."
        oc get pods -n "$NAMESPACE"
        exit 1
    fi
    UNINSTALL_ELAPSED=$(( $(date +%s) - UNINSTALL_START ))
    echo "Run $i: uninstall complete (${UNINSTALL_ELAPSED}s)."

    ELAPSED=$(( $(date +%s) - START ))
    echo "Run $i: cycle complete (install ${INSTALL_ELAPSED}s + uninstall ${UNINSTALL_ELAPSED}s = ${ELAPSED}s total)."
done

echo ""
echo "=== Done: all $MAX_RUNS install/uninstall cycles completed successfully ==="
