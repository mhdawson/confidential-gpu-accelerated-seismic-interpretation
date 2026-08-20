#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "playwright",
# ]
# ///
"""
End-to-end UI smoke test for the seismic-app Gradio UI.

Uploads a sample .npy seismic section, submits it, waits for the facies
classification result to render, and saves a screenshot. Exits non-zero on
any failure (page not reachable, upload/submit controls not found, result
never appears).

Usage:
    uv run scripts/test-ui-e2e.py --url https://<route-host> --sample samples/f3_inline_019.npy --screenshot test-results/seismic-ui-result.png
"""
import argparse
import os
import sys

from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="App URL, e.g. https://seismic-app-ns.apps.example.com")
    parser.add_argument("--sample", required=True, help="Path to a .npy file to upload")
    parser.add_argument("--screenshot", required=True, help="Path to save the result screenshot")
    parser.add_argument("--timeout", type=int, default=300000, help="Milliseconds to wait for the result image (default 300000 = 5min)")
    args = parser.parse_args()

    if not os.path.isfile(args.sample):
        print(f"ERROR: sample file not found: {args.sample}", file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(args.screenshot) or ".", exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        context = browser.new_context(ignore_https_errors=True)
        page = context.new_page()

        try:
            print(f"Navigating to {args.url} ...")
            page.goto(args.url, wait_until="networkidle", timeout=60000)

            print(f"Uploading {args.sample} ...")
            page.locator('input[type="file"]').first.set_input_files(args.sample)

            print("Clicking Submit ...")
            page.get_by_role("button", name="Submit").click()

            print(f"Waiting up to {args.timeout / 1000:.0f}s for the classification result ...")
            result_img = page.locator('img[alt*="Facies classification" i]').first
            result_img.wait_for(state="visible", timeout=args.timeout)
            page.wait_for_function(
                """(img) => img.src && img.src.length > 0 && img.complete && img.naturalWidth > 0""",
                arg=result_img.element_handle(),
                timeout=args.timeout,
            )

            page.screenshot(path=args.screenshot, full_page=True)
            print(f"Result screenshot saved to {args.screenshot}")
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
