#!/bin/bash
set -euo pipefail

ENC_PATH=/models-cache/dutchf3_unet_final.pth.enc
PT_PATH=/models-cache/dutchf3_unet_final.pth
TOKEN_URL=http://127.0.0.1:8006/aa/token?token_type=kbs
KEY_URL=http://127.0.0.1:8006/cdh/resource/default/${KBS_NAMESPACE}/model-key

# Phase 1: wait for CDH REST API to be up, then log attestation report.
# Uses the token endpoint as the readiness check — it returns valid JSON once
# CDH has completed its initial attestation with the AS, regardless of whether
# KBS will release the key. This means attestation failures appear in logs even
# when the key fetch below never succeeds.
echo "Waiting for CDH to be ready..."
until TOKEN_RESPONSE=$(curl -s --max-time 10 "$TOKEN_URL") \
    && echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; do
    echo "--- CDH not ready yet, retrying in 5s ---"
    sleep 5
done

echo ""
echo "=== Attestation Report ==="
echo "$TOKEN_RESPONSE" | python3 /app/decode-ear-token.py || echo "(attestation token decode failed)"
echo "=========================="
echo ""

# Phase 2: fetch the model key. This only succeeds if the KBS resource policy
# allows key release (i.e. attestation claims are affirming).
echo "Fetching model key from KBS via CDH (URL: $KEY_URL)..."
until curl -sf "$KEY_URL" -o /tmp/model.key; do
    echo "--- Key fetch failed, retrying in 5s ---"
    curl -v "$KEY_URL" -o /dev/null 2>&1 | tail -20 || true
    sleep 5
done
echo "Key received from KBS via CDH"

openssl enc -d -aes-256-cbc -pbkdf2 \
    -in  "$ENC_PATH" \
    -out "$PT_PATH"  \
    -pass file:/tmp/model.key

rm -f /tmp/model.key
echo "Model decrypted to $PT_PATH"
