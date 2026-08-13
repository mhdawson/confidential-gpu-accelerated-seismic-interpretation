#!/usr/bin/env python3
"""
Seismic Facies Classification — Gradio web UI.

At startup, loads the plaintext model weights from MODEL_PATH (decrypted by
the model-decrypt init container via KBS/CDH attestation), then serves a
file-upload interface where users upload a .npy seismic section and receive
a colour-coded facies classification PNG.
"""
import io
import math
import os

import gradio as gr
import matplotlib
import matplotlib.colors as mcolors
import matplotlib.pyplot as plt
import numpy as np
import segmentation_models_pytorch as smp
import torch
from PIL import Image

matplotlib.use("Agg")

MODEL_PATH = "/models-cache/dutchf3_unet_final.pth"
PORT = int(os.getenv("PORT", "7860"))
NUM_CLASSES = 6

FACIES_COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b"]
FACIES_NAMES = [
    "Upper North Sea Group",
    "Middle North Sea Group",
    "Lower North Sea Group",
    "Rijnland / Chalk Group",
    "Scruff Group",
    "Zechstein Group",
]
CMAP = mcolors.ListedColormap(FACIES_COLORS)
NORM = mcolors.BoundaryNorm(boundaries=range(NUM_CLASSES + 1), ncolors=NUM_CLASSES)


def _swatch(hex_color: str, label: str) -> str:
    style = (
        f"background:{hex_color};display:inline-block;width:14px;height:14px;"
        "border-radius:2px;vertical-align:middle;margin-right:6px;"
        "border:1px solid rgba(0,0,0,0.15);"
    )
    return f'<span style="{style}"></span>{label}'


DESCRIPTION = """
<div style="font-size: 1.5em;">

Upload a 2-D seismic section as a `.npy` file (**shape: depth × crossline, float32**)
and the model will classify each pixel into one of six North Sea rock types.

Sample `.npy` files from the Dutch F3 dataset are included in the `samples/`
directory of the quickstart repository.

</div>
"""

TABLE_DESCRIPTION = f"""
| Class | Formation | Colour |
|---|---|---|
| 0 | Upper North Sea Group | {_swatch("#1f77b4", "Blue")} |
| 1 | Middle North Sea Group | {_swatch("#ff7f0e", "Orange")} |
| 2 | Lower North Sea Group | {_swatch("#2ca02c", "Green")} |
| 3 | Rijnland / Chalk Group | {_swatch("#d62728", "Red")} |
| 4 | Scruff Group | {_swatch("#9467bd", "Purple")} |
| 5 | Zechstein Group | {_swatch("#8c564b", "Brown")} |
"""

MODEL = None
DEVICE = None


def _load_model(device: torch.device) -> smp.Unet:
    print(f"Loading model from {MODEL_PATH} ...")
    state = torch.load(MODEL_PATH, map_location=device, weights_only=False)
    if "model_state_dict" in state:
        state = state["model_state_dict"]
    model = smp.Unet(
        encoder_name="resnet50",
        encoder_weights=None,
        in_channels=1,
        classes=NUM_CLASSES,
    ).to(device)
    model.load_state_dict(state)
    model.eval()
    print("Model ready.")
    return model


def _pad32(arr: np.ndarray):
    h, w = arr.shape
    ph = (math.ceil(h / 32) * 32) - h
    pw = (math.ceil(w / 32) * 32) - w
    return np.pad(arr, ((0, ph), (0, pw)), mode="reflect"), h, w


def _infer(section: np.ndarray) -> np.ndarray:
    padded, oh, ow = _pad32(section.astype(np.float32))
    normed = (padded - padded.mean()) / (padded.std() + 1e-8)
    x = torch.from_numpy(normed).unsqueeze(0).unsqueeze(0).to(DEVICE)
    with torch.no_grad():
        return MODEL(x).argmax(dim=1).squeeze(0).cpu().numpy()[:oh, :ow]


def classify(npy_file, count: int):
    if npy_file is None:
        raise gr.Error("Please upload a .npy file.")
    section = np.load(npy_file.name if hasattr(npy_file, "name") else npy_file)
    if section.ndim != 2:
        raise gr.Error(f"Expected a 2-D array, got shape {section.shape}")

    pred = _infer(section)

    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    axes[0].imshow(section, cmap="gray", aspect="auto")
    axes[0].set_title("Seismic Input", fontsize=13)
    axes[0].axis("off")
    axes[1].imshow(pred, cmap=CMAP, norm=NORM, aspect="auto", interpolation="nearest")
    axes[1].set_title("Predicted Facies", fontsize=13)
    axes[1].axis("off")
    patches = [plt.Rectangle((0, 0), 1, 1, color=FACIES_COLORS[i]) for i in range(NUM_CLASSES)]
    fig.legend(patches, FACIES_NAMES, loc="lower center", ncol=3,
               fontsize=10, frameon=True, bbox_to_anchor=(0.5, -0.05))
    plt.tight_layout()

    buf = io.BytesIO()
    plt.savefig(buf, format="png", dpi=150, bbox_inches="tight")
    plt.close()
    buf.seek(0)

    new_count = count + 1
    label = f'<span style="font-size: 1.5em;">Classifications requested: {new_count}</span>'
    return Image.open(buf), new_count, label


def main():
    global MODEL, DEVICE

    DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Device: {DEVICE}")
    MODEL = _load_model(DEVICE)

    css = "footer { display: none !important; } .built-with { display: none !important; }"

    with gr.Blocks(title="Seismic Facies Classification") as demo:
        gr.Markdown("# Seismic Facies Classification")
        gr.Markdown(DESCRIPTION)
        npy_input = gr.File(label="Seismic section (.npy)", file_types=[".npy"])
        with gr.Row():
            clear_btn = gr.ClearButton(components=[npy_input], value="Clear")
            submit_btn = gr.Button("Submit", variant="primary")
        count_state = gr.State(value=0)
        counter = gr.Markdown(value='<span style="font-size: 1.5em;">Classifications requested: 0</span>')
        output_image = gr.Image(label="Facies classification", type="pil")
        gr.Markdown(TABLE_DESCRIPTION)
        submit_btn.click(
            fn=classify,
            inputs=[npy_input, count_state],
            outputs=[output_image, count_state, counter],
        )

    demo.launch(server_name="0.0.0.0", server_port=PORT, css=css)


if __name__ == "__main__":
    main()
