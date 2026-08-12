#!/usr/bin/env python3
"""
Patch trusteeconfig-attestation-policy-cpu to enforce initdata content validation
by adding an mr_config_id reference value check to the configuration block.

The default policy verifies that the initdata provided with the attestation request
is self-consistent with the TDX quote (MRCONFIGID binding check), but it does not
enforce that the initdata has specific expected content.  Without this patch, a pod
with different initdata — for example, one that omits the exec-deny policy — would
still pass the configuration check and receive the model key.

This patch adds a single line to the configuration block:
  input.tdx.quote.body.mr_config_id in query_reference_value("mr_config_id")

The mr_config_id reference value must be registered in RVPS (via 'make set-rvps-values')
before applying this patch, otherwise the configuration check will fail for every pod.

mr_config_id is computed from the initdata as:
  SHA256(initdata_toml_bytes) zero-padded to 48 bytes (96 hex chars)
"""
import sys
import json
import subprocess

NAMESPACE = "trustee-operator-system"
CONFIGMAP = "trusteeconfig-attestation-policy-cpu"

OLD_CHECK = '  input.tdx.quote.body.xfam in query_reference_value("xfam")\n}'

NEW_CHECK = (
    '  input.tdx.quote.body.xfam in query_reference_value("xfam")\n'
    '  # Bind attestation to the specific initdata (KBS URL, cert, namespace, exec-deny policy).\n'
    '  input.tdx.quote.body.mr_config_id in query_reference_value("mr_config_id")\n'
    '}'
)

result = subprocess.run(
    ["oc", "get", "configmap", CONFIGMAP, "-n", NAMESPACE, "-o", "json"],
    capture_output=True, text=True, check=True,
)
cm = json.loads(result.stdout)

rego = cm["data"]["default_cpu.rego"]
if OLD_CHECK not in rego:
    print(f"ERROR: expected configuration block not found in policy.", file=sys.stderr)
    print(f"  Looking for:\n{OLD_CHECK}", file=sys.stderr)
    print("The upstream policy may have changed — review and update this script.", file=sys.stderr)
    sys.exit(1)

if 'query_reference_value("mr_config_id")' in rego:
    print("INFO: mr_config_id check already present in policy — no change needed.", file=sys.stderr)
    print(json.dumps(cm))
    sys.exit(0)

cm["data"]["default_cpu.rego"] = rego.replace(OLD_CHECK, NEW_CHECK, 1)
print(json.dumps(cm))
