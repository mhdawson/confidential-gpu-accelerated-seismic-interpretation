#!/usr/bin/env python3
"""Print required node labels for the kata-cc-nvidia-gpu runtimeClass."""
import json, sys

data = json.load(sys.stdin)
labels = data['metadata']['labels']
node_name = data['metadata']['name']

required = [
    ('feature.node.kubernetes.io/runtime.kata',          'Base Kata label'),
    ('nvidia.com/gpu.present',                           'GPU present'),
    ('nvidia.com/gpu.deploy.vfio-manager',               'vfio-manager deployed'),
    ('nvidia.com/gpu.deploy.kata-sandbox-device-plugin', 'Sandbox device plugin deployed'),
    ('nvidia.com/cc.mode.state',                         'CC mode state (must be: on)'),
    ('nvidia.com/cc.ready.state',                        'CC mode ready (must be: true)'),
    ('nvidia.com/gpu.deploy.cc-manager',                 'CC manager deployed'),
]
tee_labels = [
    ('intel.feature.node.kubernetes.io/tdx', 'Intel TDX'),
    ('amd.feature.node.kubernetes.io/snp',   'AMD SEV-SNP'),
]

print(f'Node: {node_name}')
print('Required labels:')
for k, desc in required:
    v = labels.get(k, '(MISSING)')
    mark = '✓' if v != '(MISSING)' else '✗'
    print(f'  {mark} {k}: {v}  [{desc}]')
print('TEE label (one required):')
for k, desc in tee_labels:
    v = labels.get(k, '(absent)')
    mark = '✓' if v != '(absent)' else ' '
    print(f'  {mark} {k}: {v}  [{desc}]')
