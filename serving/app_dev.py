#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "gradio",
#   "matplotlib",
#   "numpy",
#   "pillow",
# ]
# ///
"""
Dev-mode UI preview — no model, no torch, no smp required.
Returns a random facies classification so you can inspect the Gradio layout
without building or pushing images.

Usage:
    make check-ui
"""
import io

import gradio as gr
import matplotlib
import matplotlib.colors as mcolors
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image

matplotlib.use("Agg")

PORT = 7860
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


def classify(npy_file, count: int):
    if npy_file is None:
        raise gr.Error("Please upload a .npy file.")

    section = np.load(npy_file.name if hasattr(npy_file, "name") else npy_file)
    if section.ndim != 2:
        raise gr.Error(f"Expected a 2-D array, got shape {section.shape}")

    pred = np.random.randint(0, NUM_CLASSES, section.shape)

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
