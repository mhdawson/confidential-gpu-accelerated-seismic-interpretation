#!/bin/bash
# Force-removes pods stuck in Terminating state.
# For kata pods, uses crictl stopp to stop the sandbox through the kata-runtime
# so that VFIO GPU bindings and device plugin accounting are released cleanly.
# Reports failure rather than falling back to pkill.
#
# Usage:
#   ./scripts/cleanup-terminating-pods.sh                        # all namespaces
#   ./scripts/cleanup-terminating-pods.sh seismic-interpretation # specific namespace

set -euo pipefail

NAMESPACE="${1:-}"

if [ -n "$NAMESPACE" ]; then
    NS_ARG="-n $NAMESPACE"
    NS_LABEL="namespace $NAMESPACE"
else
    NS_ARG="-A"
    NS_LABEL="all namespaces"
fi

echo "=== Scanning for Terminating pods ($NS_LABEL) ==="

PODS=$(oc get pods $NS_ARG -o json 2>/dev/null | jq -r '
    .items[] |
    select(.metadata.deletionTimestamp != null) |
    [
        .metadata.namespace,
        .metadata.name,
        (.spec.nodeName // ""),
        (.spec.runtimeClassName // "")
    ] | @tsv
')

FAILED_STOPS=()
declare -A NODE_SANDBOXES   # node -> space-separated "ns/pod/sandbox_id" triples
declare -A SKIP_DELETE       # "ns/pod" -> 1 for pods whose sandbox stop failed
HAS_SANDBOXES=0

if [ -z "$PODS" ]; then
    echo "No Terminating pods found."
else

echo ""
printf "%-30s %-45s %-35s %-20s\n" "NAMESPACE" "POD" "NODE" "RUNTIME"
printf "%-30s %-45s %-35s %-20s\n" "---------" "---" "----" "-------"
while IFS=$'\t' read -r ns pod node runtime; do
    printf "%-30s %-45s %-35s %-20s\n" "$ns" "$pod" "${node:-unknown}" "${runtime:-default}"
done <<< "$PODS"

# --- Collect sandbox IDs for kata pods BEFORE deleting their records ---
# The sandbox ID is needed to stop the runtime sandbox on the node.
# It must be collected before force-deleting the pod record.

while IFS=$'\t' read -r ns pod node runtime; do
    [[ "$runtime" != *kata* ]] && continue
    [ -z "$node" ] && continue

    echo ""
    echo "Collecting sandbox ID for kata pod $ns/$pod on $node..."
    SID=$(oc debug node/"$node" -- chroot /host \
        crictl pods --namespace "$ns" --name "$pod" --no-trunc -q 2>/dev/null \
        | head -1 || true)

    if [ -n "$SID" ]; then
        echo "  Sandbox ID: $SID"
        NODE_SANDBOXES["$node"]="${NODE_SANDBOXES[$node]:-} $ns/$pod/$SID"
        HAS_SANDBOXES=1
    else
        echo "  WARNING: could not get sandbox ID for $ns/$pod (may have already exited)"
    fi
done <<< "$PODS"

# --- Stop kata sandboxes via crictl before removing pod records ---
# crictl stopp goes through the kata-runtime shutdown sequence so the VM
# exits cleanly, VFIO GPU bindings are released, and the device plugin
# accounting is updated correctly.
if [ "$HAS_SANDBOXES" -eq 1 ]; then
    echo ""
    echo "=== Stopping kata sandboxes via crictl ==="

    for node in "${!NODE_SANDBOXES[@]}"; do
        for entry in ${NODE_SANDBOXES[$node]}; do
            ns=$(echo "$entry" | cut -d/ -f1)
            pod=$(echo "$entry" | cut -d/ -f2)
            SID=$(echo "$entry" | cut -d/ -f3)

            echo ""
            echo "  Stopping sandbox $SID ($ns/$pod) on $node..."
            if oc debug node/"$node" -- chroot /host \
                crictl stopp "$SID" 2>/dev/null; then
                echo "  ✓ sandbox stopped cleanly via kata-runtime"
            else
                echo "  ✗ crictl stopp timed out — waiting 30s for background shutdown..."
                sleep 30
                # The ACPI powerdown may still be in flight; check if sandbox is actually gone
                SANDBOX_STATE=$(oc debug node/"$node" -- chroot /host \
                    crictl inspectp "$SID" 2>/dev/null \
                    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',{}).get('state',''))" \
                    2>/dev/null || echo "GONE")
                if [ "$SANDBOX_STATE" = "SANDBOX_NOTREADY" ] || [ "$SANDBOX_STATE" = "GONE" ]; then
                    echo "  ✓ sandbox stopped (state: ${SANDBOX_STATE}) — background shutdown completed"
                else
                    echo "  ✗ sandbox still running (state: ${SANDBOX_STATE}) — retrying with crictl rmp --force..."
                    if oc debug node/"$node" -- chroot /host \
                        crictl rmp --force "$SID" 2>/dev/null; then
                        echo "  ✓ sandbox removed via CRI-O force"
                    else
                        echo "  ✗ crictl rmp --force also failed"
                    fi
                    # Kill QEMU directly as final backup to release GPU iommufd bindings.
                    # Filter by comm=qemu-kvm to avoid matching transient shim processes
                    # that also carry the sandbox ID in their cmdline.
                    echo "  Killing QEMU process for sandbox $SID..."
                    KILL_RESULT=$(oc debug node/"$node" -- chroot /host sh -c \
                        "pid=\$(ps -C qemu-kvm -o pid=,args= | grep 'sandbox-${SID}' | awk '{print \$1}' | head -1); \
                         if [ -n \"\$pid\" ]; then \
                             kill -9 \"\$pid\" 2>/dev/null && echo \"KILLED:\$pid\" || echo KILL_FAILED; \
                         else echo ALREADY_GONE; fi" 2>/dev/null || echo KILL_FAILED)
                    case "$KILL_RESULT" in
                        KILLED:*)
                            echo "  ✓ QEMU PID ${KILL_RESULT#KILLED:} killed — GPU iommufd bindings released"
                            ;;
                        ALREADY_GONE)
                            echo "  ✓ QEMU process already gone — GPU already released"
                            ;;
                        *)
                            echo "  ✗ Could not kill QEMU process — pod record will NOT be deleted"
                            echo ""
                            echo "  --- Diagnosing why QEMU is unkillable on $node ---"
                            DIAG_PID=$(oc debug node/"$node" -- chroot /host sh -c \
                                "ps -C qemu-kvm -o pid=,args= | grep 'sandbox-${SID}' | awk '{print \$1}' | head -1" \
                                2>/dev/null || true)
                            if [ -z "$DIAG_PID" ]; then
                                echo "  pgrep found no process — QEMU may have exited (delayed) or sandbox ID pattern changed"
                            else
                                echo "  QEMU PID: $DIAG_PID"
                                echo ""
                                echo "  Process status (State: D = uninterruptible sleep):"
                                oc debug node/"$node" -- chroot /host sh -c \
                                    "cat /proc/$DIAG_PID/status" 2>/dev/null \
                                    || echo "  (could not read status)"
                                echo ""
                                echo "  Blocking kernel call (wchan):"
                                oc debug node/"$node" -- chroot /host sh -c \
                                    "cat /proc/$DIAG_PID/wchan && echo" 2>/dev/null \
                                    || echo "  (could not read wchan)"
                                echo ""
                                echo "  Kernel stack:"
                                oc debug node/"$node" -- chroot /host sh -c \
                                    "cat /proc/$DIAG_PID/stack" 2>/dev/null \
                                    || echo "  (could not read stack — may require elevated privileges)"
                                echo ""
                                echo "  Open device fds (vfio/iommu/kvm):"
                                oc debug node/"$node" -- chroot /host sh -c \
                                    "ls -la /proc/$DIAG_PID/fd 2>/dev/null | grep -E 'vfio|iommu|kvm|dev' || echo '    (none matching vfio/iommu/kvm/dev)'" \
                                    2>/dev/null || echo "  (could not list fds)"
                            fi
                            echo ""
                            echo "  Recent kernel messages (vfio/iommu/kata/qemu):"
                            oc debug node/"$node" -- chroot /host sh -c \
                                "dmesg | grep -iE 'vfio|iommu|kata|qemu' | tail -30" 2>/dev/null \
                                || echo "  (could not read dmesg)"
                            echo "  ---"
                            echo ""
                            FAILED_STOPS+=("$node / $ns/$pod / $SID")
                            SKIP_DELETE["$ns/$pod"]=1
                            ;;
                    esac
                fi
            fi
        done
    done
fi

# --- Force-delete the pod records from Kubernetes ---
echo ""
echo "=== Force-deleting pod records ==="

while IFS=$'\t' read -r ns pod node runtime; do
    if [ -n "${SKIP_DELETE[$ns/$pod]:-}" ]; then
        echo "  Skipping $ns/$pod — sandbox stop failed, pod record preserved"
    else
        echo "  Deleting $ns/$pod..."
        oc delete pod "$pod" -n "$ns" --force --grace-period=0 2>/dev/null || true
    fi
done <<< "$PODS"

fi  # end of terminating-pods block

# --- GPU status check (always runs) ---
echo ""
echo "=== GPU status (processes holding /dev/iommu) ==="

GPU_NODES=$(oc get nodes -o json 2>/dev/null | jq -r '
    .items[] |
    select(.status.capacity["nvidia.com/pgpu"] != null) |
    .metadata.name' 2>/dev/null || true)

if [ -z "$GPU_NODES" ]; then
    echo "  No nodes with nvidia.com/pgpu capacity found."
else
    while IFS= read -r node; do
        echo ""
        echo "  Node: $node"
        GPU_HOLDERS=$(oc debug node/"$node" -- chroot /host lsof /dev/iommu 2>/dev/null \
            | grep -v COMMAND || true)
        if [ -z "$GPU_HOLDERS" ]; then
            echo "  ✓ /dev/iommu — no QEMU processes holding GPUs"
        else
            echo "  ✗ /dev/iommu — GPU still held by:"
            echo "$GPU_HOLDERS" | while read -r line; do
                echo "    $line"
            done
        fi
    done <<< "$GPU_NODES"
fi

# --- Report any sandboxes that could not be stopped ---
echo ""
if [ ${#FAILED_STOPS[@]} -eq 0 ]; then
    echo "=== Done — all kata sandboxes stopped cleanly ==="
else
    echo "=== WARNING: the following sandboxes could not be stopped cleanly ==="
    echo ""
    echo "  Pod records have been PRESERVED in Kubernetes. The kata VM may still"
    echo "  be running on the node, holding the GPU."
    echo ""
    for entry in "${FAILED_STOPS[@]}"; do
        node=$(echo "$entry" | cut -d/ -f1 | xargs)
        pod=$(echo "$entry"  | cut -d/ -f2,3 | xargs)
        SID=$(echo "$entry"  | cut -d/ -f4 | xargs)
        echo "  Node: $node   Pod: $pod   Sandbox: $SID"
        echo "    Check:  oc debug node/$node -- chroot /host crictl pods"
        echo "    Retry:  oc debug node/$node -- chroot /host crictl stopp $SID"
    done
    echo ""
    echo "  If crictl stopp continues to fail, contact your cluster admin to"
    echo "  investigate the node. A node drain/reboot will fully clear the GPU."
    exit 1
fi
