#!/usr/bin/env python3
"""
Patch trusteeconfig-attestation-policy-cpu to replace the UpToDate TCB status
check with a minimum TCB date check.

The default policy requires input.tdx.tcb_status == "UpToDate" before setting
the hardware trustworthiness claim to affirming. In practice, Intel issues TCB
Recovery events on an irregular schedule, so a platform that was up to date when
this quickstart was written may report OutOfDate once a newer TCB is published.

This patch replaces that single check with a minimum acceptable TCB date. The
rest of the policy is left exactly as-is.

Available TCB dates:
  curl -s https://api.trustedservices.intel.com/tdx/certification/v4/tcbevaluationdatanumbers | jq
"""
import sys
import json
import subprocess

NAMESPACE = "trustee-operator-system"
CONFIGMAP = "trusteeconfig-attestation-policy-cpu"
MIN_TCB_DATE = "2026-02-11T00:00:00Z"

OLD_CHECK = '  input.tdx.tcb_status == "UpToDate"'

NEW_CHECK = (
    f'  # Minimum TCB date replaces tcb_status == "UpToDate".\n'
    f'  # Allows OutOfDate platforms certified to {MIN_TCB_DATE} or newer.\n'
    f'  min_tcb_date := "{MIN_TCB_DATE}"\n'
    f'  attester_tcb_date_ns := time.parse_rfc3339_ns(input.tdx.tcb_date)\n'
    f'  min_tcb_date_ns := time.parse_rfc3339_ns(min_tcb_date)\n'
    f'  attester_tcb_date_ns >= min_tcb_date_ns'
)

result = subprocess.run(
    ["oc", "get", "configmap", CONFIGMAP, "-n", NAMESPACE, "-o", "json"],
    capture_output=True, text=True, check=True,
)
cm = json.loads(result.stdout)

rego = cm["data"]["default_cpu.rego"]
if OLD_CHECK not in rego:
    print(f"ERROR: expected line not found in policy:\n  {OLD_CHECK}", file=sys.stderr)
    print("The upstream policy may have changed — review and update this script.", file=sys.stderr)
    sys.exit(1)

cm["data"]["default_cpu.rego"] = rego.replace(OLD_CHECK, NEW_CHECK, 1)
print(json.dumps(cm))
