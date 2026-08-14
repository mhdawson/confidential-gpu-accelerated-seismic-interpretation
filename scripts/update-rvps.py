#!/usr/bin/env python3
"""
Upsert RVPS reference values for OSC 1.13+ (BoT 1.2 format).

For OSC 1.13+ (Red Hat build of Trustee 1.2), the configmap key reference_value
stores a JSON object where each measurement name maps to a base64-encoded entry:

  {"name": "mr_td", "expiration": "2099-12-31T00:00:00Z", "value": ["hex..."]}

Usage: update-rvps.py <current_json> <mr_config_id_value>
  current_json        - existing JSON content of the reference_value key ({} if empty)
  mr_config_id_value  - computed mr_config_id hex string for the current namespace/initdata

TDX hardware measurements are read from the environment:
  TDX_MR_TD   - OVMF firmware measurement
  TDX_RTMR_1  - kata kernel + initrd measurement
  TDX_RTMR_2  - additional boot measurement
  TDX_XFAM    - QEMU CPU feature mask

Values absent from the environment are silently skipped.
Each named entry is appended if new; existing entries gain the new value
only if not already present (safe to run repeatedly).

Prints the updated JSON to stdout.
"""
import base64
import json
import os
import sys

EXPIRATION = "2099-12-31T00:00:00Z"


def decode_entry(b64str):
    padding = (4 - len(b64str) % 4) % 4
    return json.loads(base64.b64decode(b64str + '=' * padding).decode())


def encode_entry(entry):
    return base64.b64encode(json.dumps(entry, separators=(',', ':')).encode()).decode()


def upsert(entries, name, value):
    if not value:
        return
    if name in entries:
        try:
            entry = decode_entry(entries[name])
        except Exception:
            entry = {"name": name, "expiration": EXPIRATION, "value": []}
        if value not in entry["value"]:
            entry["value"].append(value)
        entries[name] = encode_entry(entry)
    else:
        entry = {"name": name, "expiration": EXPIRATION, "value": [value]}
        entries[name] = encode_entry(entry)


if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <current_json> <mr_config_id_value>", file=sys.stderr)
    sys.exit(1)

current_json, mr_config_id = sys.argv[1], sys.argv[2]

entries = {}
if current_json.strip() and current_json.strip() != '{}':
    try:
        entries = json.loads(current_json)
    except Exception:
        entries = {}

upsert(entries, 'mr_config_id', mr_config_id)
upsert(entries, 'mr_td',        os.environ.get('TDX_MR_TD', ''))
upsert(entries, 'xfam',         os.environ.get('TDX_XFAM', ''))
upsert(entries, 'rtmr_0',       os.environ.get('TDX_RTMR_0', ''))
upsert(entries, 'rtmr_1',       os.environ.get('TDX_RTMR_1', ''))
upsert(entries, 'rtmr_2',       os.environ.get('TDX_RTMR_2', ''))
upsert(entries, 'rtmr_3',       os.environ.get('TDX_RTMR_3', ''))
upsert(entries, 'td_attributes', os.environ.get('TDX_TD_ATTRIBUTES', ''))
upsert(entries, 'mr_seam',      os.environ.get('TDX_MR_SEAM', ''))

print(json.dumps(entries))
