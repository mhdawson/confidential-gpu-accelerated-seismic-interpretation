#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "playwright",
#   "pillow",
# ]
# ///
"""
End-to-end UI smoke test for the seismic-app Gradio UI.

Runs two classification cycles to also exercise the Clear button between
them: uploads a sample .npy seismic section, submits it, waits for the
resulting image(s) to render, validates their pixel content (not
blank/solid-color, not suspiciously tiny), and saves a screenshot. Then
clicks Clear, uploads a second (different) sample, and repeats. Exits
non-zero on any failure in either cycle.

Usage:
    uv run test/scripts/test-ui-e2e.py \\
        --url https://<route-host> \\
        --sample samples/f3_inline_019.npy --screenshot test/results/seismic-ui-result.png \\
        --sample2 samples/f3_inline_038.npy --screenshot2 test/results/seismic-ui-result-2.png
"""
import argparse
import base64
import io
import os
import sys

from PIL import Image
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError


def load_image_bytes(page, src):
    if src.startswith("data:image"):
        _, b64data = src.split(",", 1)
        return base64.b64decode(b64data)
    resp = page.request.get(src)
    return resp.body()


def validate_image_content(page, src):
    """Returns (ok, description) for a single rendered <img> src."""
    img_bytes = load_image_bytes(page, src)
    image = Image.open(io.BytesIO(img_bytes)).convert("RGB")
    width, height = image.size
    extrema = image.getextrema()
    is_blank = all(mn == mx for mn, mx in extrema)
    colors = image.getcolors(maxcolors=1_000_000)
    num_colors = len(colors) if colors else 0
    info = f"{width}x{height}px, {num_colors} distinct colors"

    if width < 10 or height < 10:
        return False, f"{info} — too small"
    if is_blank:
        return False, f"{info} — blank/solid color"
    return True, info


def run_classification(page, sample_path, screenshot_path, timeout, label):
    """Uploads sample_path, submits, validates the new result image(s), and
    saves a screenshot. Returns True on success, False on any failure."""
    if not os.path.isfile(sample_path):
        print(f"ERROR [{label}]: sample file not found: {sample_path}", file=sys.stderr)
        return False

    print(f"[{label}] Uploading {sample_path} ...")
    file_input = page.locator('input[type="file"]').first
    file_input.wait_for(state="attached", timeout=60000)
    file_input.set_input_files(sample_path)

    # Record which images are already fully loaded before submitting, so we
    # can detect the result(s) by "new loaded image(s) appeared" rather than
    # guessing at Gradio's alt-text/label markup or holding an element
    # handle that may go stale if Gradio replaces the <img> node instead of
    # updating it in place.
    baseline_srcs = page.eval_on_selector_all(
        "img",
        "imgs => imgs.filter(img => img.complete && img.naturalWidth > 0).map(img => img.src)",
    )

    print(f"[{label}] Clicking Submit ...")
    page.get_by_role("button", name="Submit").click()

    print(f"[{label}] Waiting up to {timeout / 1000:.0f}s for new result image(s) ...")
    try:
        page.wait_for_function(
            """(baseline) => {
                const loaded = Array.from(document.querySelectorAll('img'))
                    .filter(img => img.complete && img.naturalWidth > 0)
                    .map(img => img.src);
                return loaded.some(src => !baseline.includes(src));
            }""",
            arg=baseline_srcs,
            timeout=timeout,
        )
    except PlaywrightTimeoutError as e:
        failure_path = os.path.splitext(screenshot_path)[0] + "-failure.png"
        page.screenshot(path=failure_path, full_page=True)
        print(f"ERROR [{label}]: {e} — saved failure screenshot to {failure_path}", file=sys.stderr)
        return False

    new_srcs = page.evaluate(
        """(baseline) => Array.from(document.querySelectorAll('img'))
            .filter(img => img.complete && img.naturalWidth > 0)
            .map(img => img.src)
            .filter(src => !baseline.includes(src))""",
        baseline_srcs,
    )

    if not new_srcs:
        print(f"ERROR [{label}]: no new image detected after Submit.", file=sys.stderr)
        page.screenshot(path=os.path.splitext(screenshot_path)[0] + "-failure.png", full_page=True)
        return False

    print(f"[{label}] Found {len(new_srcs)} new image(s) — validating content...")
    all_ok = True
    for idx, src in enumerate(new_srcs, start=1):
        try:
            ok, info = validate_image_content(page, src)
        except Exception as e:
            ok, info = False, f"could not load/decode image ({e})"
        print(f"  [{label} {idx}/{len(new_srcs)}] {info} -> {'OK' if ok else 'FAILED'}")
        all_ok = all_ok and ok

    page.screenshot(path=screenshot_path, full_page=True)
    print(f"[{label}] Screenshot saved to {screenshot_path}")

    if not all_ok:
        print(f"ERROR [{label}]: one or more result images failed content validation.", file=sys.stderr)
        return False
    return True


def click_clear(page):
    print("Clicking Clear ...")
    # Gradio renders two elements matching role=button/name=Clear: a small
    # built-in "icon-button" (the inline x on the file-upload widget) and
    # the actual gr.ClearButton(value="Clear") from app.py. We want the
    # latter — exclude the icon-button class rather than guess at DOM order.
    clear_button = page.locator('button:not(.icon-button)').filter(has_text="Clear")
    clear_button.first.click()
    print("Waiting for the file input to reset...")
    page.wait_for_function(
        """() => {
            const input = document.querySelector('input[type="file"]');
            return !input || input.files.length === 0;
        }""",
        timeout=30000,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", required=True, help="App URL, e.g. https://seismic-app-ns.apps.example.com")
    parser.add_argument("--sample", required=True, help="Path to the first .npy file to upload")
    parser.add_argument("--screenshot", required=True, help="Path to save the first run's result screenshot")
    parser.add_argument("--sample2", required=True, help="Path to a second, different .npy file to upload after Clear")
    parser.add_argument("--screenshot2", required=True, help="Path to save the second run's result screenshot")
    parser.add_argument("--timeout", type=int, default=300000, help="Milliseconds to wait for each result (default 300000 = 5min)")
    args = parser.parse_args()

    os.makedirs(os.path.dirname(args.screenshot) or ".", exist_ok=True)
    os.makedirs(os.path.dirname(args.screenshot2) or ".", exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        context = browser.new_context(ignore_https_errors=True)
        page = context.new_page()

        try:
            print(f"Navigating to {args.url} ...")
            # Gradio keeps a persistent WebSocket open for its queue/status
            # updates, so the network never goes idle — "networkidle" would
            # always time out here. Wait for the initial HTML load instead.
            page.goto(args.url, wait_until="domcontentloaded", timeout=60000)

            if not run_classification(page, args.sample, args.screenshot, args.timeout, label="run1"):
                return 1

            click_clear(page)

            if not run_classification(page, args.sample2, args.screenshot2, args.timeout, label="run2"):
                return 1

            return 0

        except PlaywrightTimeoutError as e:
            failure_path = os.path.splitext(args.screenshot)[0] + "-failure.png"
            try:
                page.screenshot(path=failure_path, full_page=True)
                print(f"FAILED — saved failure screenshot to {failure_path}", file=sys.stderr)
            except Exception:
                pass
            print(f"ERROR: {e}", file=sys.stderr)
            return 1
        finally:
            browser.close()


if __name__ == "__main__":
    sys.exit(main())
