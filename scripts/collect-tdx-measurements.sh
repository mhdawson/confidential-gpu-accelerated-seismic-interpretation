#!/bin/bash
# Collect TDX hardware measurement values by launching a temporary kata-cc probe pod.
#
# mr_td, rtmr_1, rtmr_2, and xfam are stable for a given OSC version and must
# be registered in RVPS so the attestation policy produces affirming scores.
# Register them once; re-run only after an OSC upgrade that changes the kata
# firmware or kernel.
#
# Usage: collect-tdx-measurements.sh [NAMESPACE [KATA_RUNTIME_CLASS]]
#   NAMESPACE          defaults to seismic-interpretation
#   KATA_RUNTIME_CLASS defaults to kata-cc-nvidia-gpu
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=${1:-seismic-interpretation}
KATA_RUNTIME_CLASS=${2:-kata-cc-nvidia-gpu}
KBS_URL="https://kbs-service.trustee-operator-system.svc.cluster.local:8080"
PROBE_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest"
PROBE_POD="tdx-measure-$$"
POLICY_FILE="${SCRIPT_DIR}/../policies/policy-dev.rego"

# ── OSC version ───────────────────────────────────────────────────────────────

OSC_VERSION=$(oc get csv -n openshift-sandboxed-containers-operator \
  -o jsonpath='{.items[0].spec.version}' 2>/dev/null || true)

if [ -z "$OSC_VERSION" ]; then
  echo "WARNING: Could not determine OSC version (operator may not be installed)" >&2
  OSC_VERSION="unknown"
fi

echo "OpenShift Sandboxed Containers version: $OSC_VERSION"
echo ""
echo "NOTE: TDX measurements (mr_td, rtmr_1, rtmr_2, xfam) are stable for a given OSC"
echo "version. Re-run this script and update the Makefile whenever OSC is upgraded."
echo ""

# ── Cleanup trap ──────────────────────────────────────────────────────────────

EVIDENCE_FILE=$(mktemp /tmp/tdx-evidence.XXXXXX.json)

cleanup() {
  rm -f "$EVIDENCE_FILE"
  echo "Deleting probe pod $PROBE_POD..."
  oc delete pod "$PROBE_POD" -n "$NAMESPACE" \
    --grace-period=0 --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

# ── Build initdata ────────────────────────────────────────────────────────────
# Builds aa.toml + cdh.toml (no [image] section) + dev policy, gzip+base64
# encoded — matching the format of seismic-app-dev.yaml.

if ! oc get secret trusteeconfig-https-cert-secret \
       -n trustee-operator-system &>/dev/null; then
  echo "ERROR: trusteeconfig-https-cert-secret not found in trustee-operator-system." >&2
  echo "       Run 'make setup-trustee-in-cluster' before collecting measurements." >&2
  exit 1
fi

if [ ! -f "$POLICY_FILE" ]; then
  echo "ERROR: Dev policy not found: $POLICY_FILE" >&2
  exit 1
fi

KBS_CERT=$(oc get secret trusteeconfig-https-cert-secret \
  -n trustee-operator-system \
  -o jsonpath='{.data.certificate}' | base64 -d)

INITDATA=$(KBS_CERT="$KBS_CERT" KBS_URL="$KBS_URL" \
  python3 - "$POLICY_FILE" <<'PYTHON'
import base64, gzip, os, sys

kbs_url  = os.environ['KBS_URL']
kbs_cert = os.environ['KBS_CERT']

with open(sys.argv[1]) as f:
    policy_rego = f.read()

aa_toml = f"""\
[token_configs]
[token_configs.coco_as]
url = "{kbs_url}"

[token_configs.kbs]
url = "{kbs_url}"
cert = \"\"\"
{kbs_cert}
\"\"\""""

cdh_toml = f"""\
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = "cc_kbc"
url = "{kbs_url}"
kbs_cert = \"\"\"
{kbs_cert}
\"\"\""""

toml = f"""\
algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
{aa_toml}
'''

"cdh.toml" = '''
{cdh_toml}
'''

"policy.rego" = '''
{policy_rego}
'''
"""

print(base64.b64encode(gzip.compress(toml.encode())).decode(), end='')
PYTHON
)

if [ -z "$INITDATA" ]; then
  echo "ERROR: Failed to compute initdata blob." >&2
  exit 1
fi

echo "Initdata computed (${#INITDATA} chars)."

# ── Launch probe pod ──────────────────────────────────────────────────────────

echo "Launching temporary kata-cc probe pod: $PROBE_POD"

PROBE_MANIFEST=$(mktemp /tmp/tdx-probe-XXXXXX.yaml)
cat > "$PROBE_MANIFEST" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_POD}
  namespace: ${NAMESPACE}
  annotations:
    io.katacontainers.config.hypervisor.cc_init_data: "${INITDATA}"
    io.katacontainers.config.hypervisor.default_memory: "16384"
    io.katacontainers.config.hypervisor.kernel_params: "agent.guest_components_rest_api=all"
spec:
  runtimeClassName: ${KATA_RUNTIME_CLASS}
  restartPolicy: Never
  containers:
  - name: probe
    image: ${PROBE_IMAGE}
    command: ["sleep", "120"]
EOF
oc apply -f "$PROBE_MANIFEST"
rm -f "$PROBE_MANIFEST"

echo "Waiting for probe pod to be ready (kata VMs can take up to 2 minutes)..."
oc wait pod "$PROBE_POD" -n "$NAMESPACE" \
  --for=condition=Ready --timeout=120s

# ── Fetch the attestation evidence ───────────────────────────────────────────

echo "Querying attestation agent evidence endpoint..."

RUNTIME_DATA=$(printf '%s' "collect-tdx-measurements" | base64 | tr -d '=')

CDH_STATUS=$(oc exec -n "$NAMESPACE" "$PROBE_POD" -c probe -- \
  curl -s -o /dev/null -w "%{http_code}" \
  "http://127.0.0.1:8006/aa/evidence?runtime_data=$RUNTIME_DATA" \
  2>/dev/null || echo "unreachable")

if [ "$CDH_STATUS" = "200" ]; then
  oc exec -n "$NAMESPACE" "$PROBE_POD" -c probe -- \
    curl -sf "http://127.0.0.1:8006/aa/evidence?runtime_data=$RUNTIME_DATA" \
    > "$EVIDENCE_FILE" 2>/dev/null
else
  echo "ERROR: /aa/evidence returned HTTP $CDH_STATUS." >&2
  echo "" >&2
  if [ "$CDH_STATUS" = "unreachable" ]; then
    echo "  CDH is not listening on port 8006 — it may not have started." >&2
    echo "  Check that Trustee is installed and the initdata annotation was set." >&2
  elif [ "$CDH_STATUS" = "404" ] || [ "$CDH_STATUS" = "405" ]; then
    echo "  The /aa/evidence endpoint is not implemented in this CDH version." >&2
    echo "  It was added in a later release; OSC 1.3.1 does not include it." >&2
    echo "  If your Makefile already has TDX_MR_TD values for your OSC version," >&2
    echo "  no further action is needed — the values are already correct." >&2
  fi
  echo "" >&2
  echo "  Fallback — enable AS debug logging, trigger an attestation, and parse the logs:" >&2
  echo "    oc set env deployment/trustee-deployment -n trustee-operator-system \\" >&2
  echo "      RUST_LOG=attestation_service=debug" >&2
  echo "    oc rollout status deployment/trustee-deployment \\" >&2
  echo "      -n trustee-operator-system --timeout=2m" >&2
  echo "    # From inside a running kata pod, trigger CDH to contact KBS:" >&2
  echo "    #   curl -s http://127.0.0.1:8006/cdh/resource/\$NAMESPACE/conf-seismic-model-key/key" >&2
  echo "    oc logs -n trustee-operator-system -l app=trustee --since=60s \\" >&2
  echo "      | grep -E '\"mr_td\"|\"rtmr_1\"|\"rtmr_2\"|\"xfam\"'" >&2
  exit 1
fi

# ── Parse the TDX quote and extract measurements ──────────────────────────────

python3 - "$EVIDENCE_FILE" "$OSC_VERSION" <<'PYTHON'
import sys, json, base64

evidence_file = sys.argv[1]
osc_version   = sys.argv[2]
with open(evidence_file) as f:
    raw = f.read().strip()

if not raw:
    print("ERROR: Empty response from AA evidence endpoint", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print(f"ERROR: Non-JSON response from AA:\n{raw[:500]}", file=sys.stderr)
    sys.exit(1)

# Locate the quote — different AA versions use different key names
quote_b64 = None
for key in ['quote', 'b64_quote', 'tee-evidence', 'evidence', 'raw-evidence']:
    if key in data:
        quote_b64 = data[key]
        break

if quote_b64 is None:
    print(f"ERROR: No quote field in response. Keys: {list(data.keys())}", file=sys.stderr)
    print(json.dumps(data, indent=2), file=sys.stderr)
    sys.exit(1)

# Try standard then URL-safe base64
try:
    quote = base64.b64decode(quote_b64 + '==')
except Exception:
    try:
        quote = base64.urlsafe_b64decode(quote_b64 + '==')
    except Exception as e:
        print(f"ERROR: Cannot base64-decode quote: {e}", file=sys.stderr)
        sys.exit(1)

# Minimum length: header(48) + TCB_SVN(16) + MR_SEAM(48) + MR_SIGNER_SEAM(48)
#   + SEAM_ATTRS(8) + TD_ATTRS(8) + XFAM(8) + MRTD(48)
#   + MR_CONFIG_ID(48) + MR_OWNER(48) + MR_OWNER_CONFIG(48)
#   + RTMR[0](48) + RTMR[1](48) + RTMR[2](48) + RTMR[3](48)
MIN_LEN = 48 + 16 + 48 + 48 + 8 + 8 + 8 + 48 + 48 + 48 + 48 + 48 + 48 + 48 + 48
if len(quote) < MIN_LEN:
    print(f"ERROR: Quote too short ({len(quote)} bytes, need >= {MIN_LEN})", file=sys.stderr)
    sys.exit(1)

# TDX DCAP v4 quote layout:
#   Header (48 bytes) followed by TD10 Report Body:
#     TEE_TCB_SVN       16 bytes
#     MR_SEAM           48 bytes   ← mr_seam
#     MR_SIGNER_SEAM    48 bytes
#     SEAM_ATTRIBUTES    8 bytes
#     TD_ATTRIBUTES      8 bytes   ← td_attributes
#     XFAM               8 bytes   ← xfam
#     MRTD              48 bytes   ← mr_td
#     MR_CONFIG_ID      48 bytes
#     MR_OWNER          48 bytes
#     MR_OWNER_CONFIG   48 bytes
#     RTMR[0]           48 bytes   ← rtmr_0
#     RTMR[1]           48 bytes   ← rtmr_1
#     RTMR[2]           48 bytes   ← rtmr_2
#     RTMR[3]           48 bytes   ← rtmr_3
#     REPORT_DATA       64 bytes
o = 48 + 16                         # skip header and TEE_TCB_SVN
mr_seam   = quote[o:o+48]; o += 48  # MR_SEAM
o += 48                             # skip MR_SIGNER_SEAM
o += 8                              # skip SEAM_ATTRIBUTES
td_attrs  = quote[o:o+8];  o += 8   # TD_ATTRIBUTES
xfam      = quote[o:o+8];  o += 8   # XFAM
mr_td     = quote[o:o+48]; o += 48  # MRTD
o += 48 + 48 + 48                   # skip MR_CONFIG_ID, MR_OWNER, MR_OWNER_CONFIG
rtmr0     = quote[o:o+48]; o += 48  # RTMR[0]
rtmr1     = quote[o:o+48]; o += 48  # RTMR[1]
rtmr2     = quote[o:o+48]; o += 48  # RTMR[2]
rtmr3     = quote[o:o+48]           # RTMR[3]

debug_bit = td_attrs[0] & 0x01
td_debug_note = "← DEBUG MODE ON — not truly confidential!" if debug_bit else "← debug bit clear (production OK)"

print("TDX measurements:")
print(f"  mr_seam:       {mr_seam.hex()}")
print(f"  td_attributes: {td_attrs.hex()}  {td_debug_note}")
print(f"  mr_td:         {mr_td.hex()}")
print(f"  xfam:          {xfam.hex()}")
print(f"  rtmr_0:        {rtmr0.hex()}")
print(f"  rtmr_1:        {rtmr1.hex()}")
print(f"  rtmr_2:        {rtmr2.hex()}")
print(f"  rtmr_3:        {rtmr3.hex()}")
print()
print(f"# ── Makefile variables (OSC {osc_version}) ──────────────────────────────────────")
print(f"# Paste into Makefile; re-run this script and update after an OSC upgrade.")
print(f"TDX_MR_SEAM      ?= {mr_seam.hex()}")
print(f"TDX_TD_ATTRIBUTES ?= {td_attrs.hex()}")
print(f"TDX_MR_TD        ?= {mr_td.hex()}")
print(f"TDX_XFAM         ?= {xfam.hex()}")
print(f"TDX_RTMR_0       ?= {rtmr0.hex()}")
print(f"TDX_RTMR_1       ?= {rtmr1.hex()}")
print(f"TDX_RTMR_2       ?= {rtmr2.hex()}")
print(f"TDX_RTMR_3       ?= {rtmr3.hex()}")
print()
print(f"# ── Environment exports for 'make setup-attestation' ────────────────────")
print(f"export TDX_MR_SEAM={mr_seam.hex()}")
print(f"export TDX_TD_ATTRIBUTES={td_attrs.hex()}")
print(f"export TDX_MR_TD={mr_td.hex()}")
print(f"export TDX_XFAM={xfam.hex()}")
print(f"export TDX_RTMR_0={rtmr0.hex()}")
print(f"export TDX_RTMR_1={rtmr1.hex()}")
print(f"export TDX_RTMR_2={rtmr2.hex()}")
print(f"export TDX_RTMR_3={rtmr3.hex()}")
PYTHON
