#!/bin/bash
# Creates the cert-manager Issuer and Certificates that the Trustee operator
# requires before TrusteeConfig can be applied.  Mirrors the sequence in
# coco-infra/common/configure-trustee.sh.
#
# Usage: apply-kbs-certs.sh [route-hostname]
#   route-hostname defaults to kbs-service-trustee-operator-system.<cluster-domain>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${1:-}" ]; then
    ROUTE_HOST="$1"
else
    CLUSTER_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
    ROUTE_HOST="kbs-route-trustee-operator-system.${CLUSTER_DOMAIN}"
fi
echo "KBS Route hostname: ${ROUTE_HOST}"
TEMPLATES="${SCRIPT_DIR}/../helm/trustee/templates"

oc apply -f "${TEMPLATES}/kbs-cert-issuer.yaml"

oc apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kbs-https
  namespace: trustee-operator-system
spec:
  commonName: kbs-trustee-operator-system
  subject:
    organizations:
    - trustee-operator-system
  dnsNames:
  - ${ROUTE_HOST}
  - kbs-service.trustee-operator-system.svc
  - kbs-service.trustee-operator-system.svc.cluster.local
  privateKey:
    algorithm: RSA
    encoding: PKCS1
    size: 2048
  duration: 8760h
  renewBefore: 360h
  secretName: trustee-tls-cert
  issuerRef:
    name: kbs-issuer
    kind: Issuer
EOF

oc apply -f "${TEMPLATES}/kbs-token-cert.yaml"

echo "Waiting for trustee-tls-cert to be issued (up to 2 min)..."
DEADLINE=$(( $(date +%s) + 120 ))
until oc get certificate kbs-https -n trustee-operator-system \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
        | grep -q True; do
    if [ $(date +%s) -ge $DEADLINE ]; then
        echo "ERROR: kbs-https Certificate not Ready after 2 min."
        echo "       Run: oc describe certificate kbs-https -n trustee-operator-system"
        exit 1
    fi
    sleep 5
done
echo "trustee-tls-cert issued by cert-manager."
