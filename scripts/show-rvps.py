#!/usr/bin/env python3
"""
Decode and pretty-print RVPS reference values — both what 'make set-rvps-values'
would register and what is currently stored in the trustee ConfigMap.

Shows all known TDX attestation fields with a clear indicator of whether each
will be registered or not, and why.

Usage: show-rvps.py <pcr8_value> [<current_configmap_json>]
  pcr8_value           - hex PCR8 computed from current initdata (pass '-' to skip)
  current_configmap_json - JSON from the reference_value configmap key (optional)

TDX hardware measurements are read from environment variables:
  TDX_MR_TD         TDVF guest firmware measurement
  TDX_XFAM          CPU extended feature mask
  TDX_RTMR_0        TDVF boot handoff measurement
  TDX_RTMR_1        kata guest kernel + command line
  TDX_RTMR_2        kata guest initrd (kata-agent, CDH, AA)
  TDX_RTMR_3        post-boot guest measurements
  TDX_TD_ATTRIBUTES TD attribute flags (debug bit)
  TDX_MR_SEAM       Intel TDX module measurement
"""
import base64
import json
import os
import sys

# All known TDX/RVPS fields in display order.
# env_key:  environment variable that supplies the value (None = not from env)
# note:     shown when no value is available; explains what to do
# changes:  what triggers this value to change
# action:   what to do when it changes
FIELDS = [
    {
        "name":    "tdx_pcr08",
        "desc":    "initdata configuration binding",
        "detail":  "SHA256(zeroes32 || SHA256(initdata_toml_bytes))",
        "env_key": None,
        "note":    None,
        "changes": "KBS TLS cert rotates (cert-manager); namespace changes; policy mode "
                   "changes; KBS URL changes",
        "action":  "make set-rvps-values — re-run whenever 'make install' would produce "
                   "a different initdata blob",
    },
    {
        "name":    "mr_td",
        "desc":    "TDVF guest firmware (OVMF)",
        "detail":  "measurement of the OVMF firmware pages loaded into the TD at creation",
        "env_key": "TDX_MR_TD",
        "note":    "export TDX_MR_TD from scripts/collect-tdx-measurements.sh",
        "changes": "OSC upgrade that updates the kata TDVF/OVMF binary",
        "action":  "make collect-tdx-measurements, then make set-rvps-values",
    },
    {
        "name":    "xfam",
        "desc":    "CPU extended feature mask",
        "detail":  "QEMU CPU feature flags exposed to the TD (AVX, AMX, etc.)",
        "env_key": "TDX_XFAM",
        "note":    "export TDX_XFAM from scripts/collect-tdx-measurements.sh",
        "changes": "very rarely — only if QEMU CPU model or OSC QEMU config changes",
        "action":  "make collect-tdx-measurements, then make set-rvps-values",
    },
    {
        "name":    "rtmr_0",
        "desc":    "TDVF boot handoff measurement",
        "detail":  "extended by TDVF before handing off to the bootloader/kernel",
        "env_key": "TDX_RTMR_0",
        "note":    "export TDX_RTMR_0 from scripts/collect-tdx-measurements.sh",
        "changes": "OSC upgrade that updates TDVF; same cadence as mr_td",
        "action":  "make collect-tdx-measurements, then make set-rvps-values",
    },
    {
        "name":    "rtmr_1",
        "desc":    "kata guest kernel + command line",
        "detail":  "extended by the bootloader with the kernel image and cmdline",
        "env_key": "TDX_RTMR_1",
        "note":    "export TDX_RTMR_1 from scripts/collect-tdx-measurements.sh",
        "changes": "OSC upgrade that updates the kata guest kernel",
        "action":  "make collect-tdx-measurements, then make set-rvps-values",
    },
    {
        "name":    "rtmr_2",
        "desc":    "kata guest initrd (kata-agent, CDH, AA)",
        "detail":  "extended with the initrd containing the kata guest components",
        "env_key": "TDX_RTMR_2",
        "note":    "export TDX_RTMR_2 from scripts/collect-tdx-measurements.sh",
        "changes": "OSC upgrade that updates kata-agent, CDH, or AA in the initrd",
        "action":  "make collect-tdx-measurements, then make set-rvps-values",
    },
    {
        "name":    "rtmr_3",
        "desc":    "post-boot guest measurements",
        "detail":  "reserved for guest OS runtime use; typically all-zeros in kata-cc",
        "env_key": "TDX_RTMR_3",
        "note":    "export TDX_RTMR_3 from scripts/collect-tdx-measurements.sh",
        "changes": "only if kata-cc begins using RTMR[3] for runtime measurements",
        "action":  "make collect-tdx-measurements, then make set-rvps-values",
    },
    {
        "name":    "td_attributes",
        "desc":    "TD attribute flags",
        "detail":  "bit 0 = debug mode — must be 0 for a confidential production workload",
        "env_key": "TDX_TD_ATTRIBUTES",
        "note":    "export TDX_TD_ATTRIBUTES from scripts/collect-tdx-measurements.sh",
        "changes": "only if QEMU/kata configuration enables or disables debug mode",
        "action":  "make collect-tdx-measurements, then make set-rvps-values; "
                   "verify bit 0 is 0 before registering",
    },
    {
        "name":    "mr_seam",
        "desc":    "Intel TDX module version",
        "detail":  "measurement of the Intel TDX module running on the host CPU",
        "env_key": "TDX_MR_SEAM",
        "note":    "export TDX_MR_SEAM from scripts/collect-tdx-measurements.sh",
        "changes": "host firmware update that upgrades the Intel TDX module "
                   "(independent of OSC upgrades)",
        "action":  "make collect-tdx-measurements, then make set-rvps-values",
    },
]

W = 72

def rule(char="─"):
    return char * W

def header(title):
    return f"── {title} {'─' * max(0, W - len(title) - 4)}"

def decode_entry(b64str):
    padding = (4 - len(b64str) % 4) % 4
    return json.loads(base64.b64decode(b64str + '=' * padding).decode())

def wrap(text, indent, width=W):
    words = text.split()
    lines, cur = [], ""
    for w in words:
        if cur and len(cur) + 1 + len(w) > width - len(indent):
            lines.append(indent + cur)
            cur = w
        else:
            cur = (cur + " " + w).strip()
    if cur:
        lines.append(indent + cur)
    return "\n".join(lines)

# ── Collect computed values ───────────────────────────────────────────────────

pcr8         = sys.argv[1] if len(sys.argv) > 1 else "-"
current_json = sys.argv[2] if len(sys.argv) > 2 else "{}"

computed = {}
if pcr8 and pcr8 != "-":
    computed["tdx_pcr08"] = pcr8
for f in FIELDS:
    if f["env_key"]:
        val = os.environ.get(f["env_key"], "").strip()
        if val:
            computed[f["name"]] = val

# ── Decode current configmap ──────────────────────────────────────────────────

current = {}
if current_json and current_json.strip() not in ("", "{}"):
    try:
        raw = json.loads(current_json)
        for name, b64 in raw.items():
            try:
                current[name] = decode_entry(b64)
            except Exception:
                current[name] = {"name": name, "value": [], "expiration": "?"}
    except Exception as e:
        print(f"WARNING: could not parse configmap JSON: {e}", file=sys.stderr)

# ── Print ─────────────────────────────────────────────────────────────────────

print()
print(rule("═"))
print(" RVPS REFERENCE VALUES")
print(rule("═"))
print()

known_names = {f["name"] for f in FIELDS}
IND = "                   "   # indent for wrapped continuation lines

# ── Would be registered ───────────────────────────────────────────────────────

print(header("Would be registered by 'make set-rvps-values'"))
print()

for f in FIELDS:
    name  = f["name"]
    value = computed.get(name)

    if value:
        print(f"  ✓  {name:<14}  {f['desc']}")
    else:
        print(f"  ✗  {name:<14}  {f['desc']}")

    print(f"{IND}{f['detail']}")
    print(wrap(f"changes: {f['changes']}", IND))
    print(wrap(f"action:  {f['action']}",  IND))

    if value:
        print(f"{IND}{value}")
    else:
        if f["note"]:
            print(f"{IND}NOTE: {f['note']}")

    print()

# Show anything computed that isn't in our known list
for name, value in computed.items():
    if name not in known_names:
        print(f"  ✓  {name:<14}  (unknown field)")
        print(f"{IND}{value}")
        print()

# ── Currently registered ──────────────────────────────────────────────────────

print()
print(header("Currently registered in trustee-operator-system"))
print()

ordered = [f["name"] for f in FIELDS] + [k for k in current if k not in known_names]

if not current:
    print("  (configmap is empty — nothing registered yet)")
    print()
else:
    for name in ordered:
        desc = next((f["desc"] for f in FIELDS if f["name"] == name), "")
        if name not in current:
            print(f"  ✗  {name:<14}  {desc}")
            print(f"{IND}not registered in configmap")
            print()
            continue
        entry  = current[name]
        values = entry.get("value", [])
        exp    = entry.get("expiration", "?")
        count  = len(values)
        print(f"  ✓  {name:<14}  {desc}")
        print(f"{IND}{count} value{'s' if count != 1 else ''}  expires {exp}")
        for i, v in enumerate(values, 1):
            match = ""
            if name in computed:
                match = "  ✓ matches computed" if v == computed[name] else "  ✗ differs from computed"
            print(f"    [{i}]  {v}{match}")
        print()

print(rule("═"))
print()
