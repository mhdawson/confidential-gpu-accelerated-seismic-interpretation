# registry.access.redhat.com/ubi9/python-312 — UBI, freely redistributable, no Docker Hub
# The torch cu128 wheel bundles its own CUDA 12.8 runtime libs so no system
# CUDA toolkit is needed; the GPU is exposed by the node's NVIDIA device plugin.
FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0

RUN dnf install -y openssl && dnf clean all

USER 1001
WORKDIR /app

RUN pip install --no-cache-dir \
    torch torchvision \
    --index-url https://download.pytorch.org/whl/cu128

RUN pip install --no-cache-dir \
    "segmentation-models-pytorch>=0.3" timm "gradio>=4.0" matplotlib

COPY serving/app.py /app/app.py
COPY serving/decrypt.sh /app/decrypt.sh
COPY scripts/decode-ear-token.py /app/decode-ear-token.py

ENV MODEL_PATH=/models-cache/dutchf3_unet_final.pth
ENV PORT=7860

EXPOSE 7860

CMD ["python3", "/app/app.py"]
