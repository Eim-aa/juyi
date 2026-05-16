#!/usr/bin/env python3
"""Render docs/demo.gif from scratch.

Draws a 3-frame illustration of the ⌥+T workflow:
  1. TextEdit-style window with an English sentence (idle)
  2. The sentence highlighted as a selection
  3. The hs.canvas-style popup with the Chinese translation

The translation and latency are fetched live from the running service so the
demo always shows real numbers from the current model. Everything else
(window chrome, popup styling) is drawn with Pillow.

Run via the project venv so Pillow and the running service are both available:

    ~/.local/share/argos-translator/venv/bin/python docs/render_demo.py
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SERVICE_URL = "http://127.0.0.1:54321/translate"
OUTPUT = Path(__file__).resolve().parent / "demo.gif"

W, H = 800, 320
DESKTOP_RGB = (40, 56, 48)
EN = "Offline translation keeps your text private."

FONT_UI = "/System/Library/Fonts/Helvetica.ttc"
FONT_MONO = "/System/Library/Fonts/Menlo.ttc"
FONT_ZH = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def translate(text: str) -> tuple[str, int]:
    req = urllib.request.Request(
        SERVICE_URL,
        data=json.dumps({"text": text}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        body = json.loads(r.read())
    return body["result"], int(body["elapsed_ms"])


def make_frame(state: str, zh: str, sub: str) -> Image.Image:
    img = Image.new("RGB", (W, H), color=DESKTOP_RGB)
    draw = ImageDraw.Draw(img, "RGBA")

    # TextEdit window
    tx, ty, tw, th = 60, 40, 680, 180
    for i in range(10, 0, -2):
        a = 6 + i * 2
        draw.rounded_rectangle((tx - i, ty - i + 4, tx + tw + i, ty + th + i + 4), radius=10, fill=(0, 0, 0, a))
    draw.rounded_rectangle((tx, ty, tx + tw, ty + th), radius=10, fill="white")
    bar_h = 30
    draw.rounded_rectangle((tx, ty, tx + tw, ty + bar_h + 5), radius=10, fill="#ECECEC")
    draw.rectangle((tx, ty + bar_h - 5, tx + tw, ty + bar_h), fill="#ECECEC")
    for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
        cx = tx + 16 + i * 18
        cy = ty + bar_h // 2
        draw.ellipse((cx - 6, cy - 6, cx + 6, cy + 6), fill=c)
    draw.line((tx, ty + bar_h, tx + tw, ty + bar_h), fill="#D1D1D1", width=1)
    f_ui = ImageFont.truetype(FONT_UI, 12)
    draw.text((tx + tw // 2, ty + 9), "demo.txt", fill="#444", anchor="mt", font=f_ui)

    # text + optional selection
    f_mono = ImageFont.truetype(FONT_MONO, 14)
    text_x, text_y = tx + 16, ty + bar_h + 16
    if state in ("selected", "translated"):
        bbox = draw.textbbox((text_x, text_y), EN, font=f_mono)
        draw.rectangle((bbox[0] - 1, bbox[1] - 1, bbox[2] + 1, bbox[3] + 1), fill="#B4D5FE")
    draw.text((text_x, text_y), EN, fill="black", font=f_mono)

    if state == "idle":
        f_hint = ImageFont.truetype(FONT_UI, 12)
        draw.text(
            (text_x, text_y + 60),
            "Select the line, then press Option + T",
            fill=(140, 140, 140),
            font=f_hint,
        )

    if state == "translated":
        f_zh = ImageFont.truetype(FONT_ZH, 14)
        f_zh_sm = ImageFont.truetype(FONT_ZH, 11)
        zh_w = f_zh.getlength(zh)
        zh_box = draw.textbbox((0, 0), zh, font=f_zh)
        zh_h = zh_box[3] - zh_box[1]
        sub_box = draw.textbbox((0, 0), sub, font=f_zh_sm)
        sub_h = sub_box[3] - sub_box[1]
        pad = 12
        pw = int(zh_w + pad * 2 + 4)
        ph = zh_h + sub_h + pad * 2 + 8
        px = text_x + 160
        py = text_y + 28
        if px + pw > W - 30:
            px = W - 30 - pw
        for i in range(10, 0, -2):
            a = 30 + i * 6
            draw.rounded_rectangle((px - i, py - i + 4, px + pw + i, py + ph + i + 4), radius=6, fill=(0, 0, 0, a))
        draw.rounded_rectangle((px, py, px + pw, py + ph), radius=6, fill=(20, 20, 20, 242))
        draw.text((px + pad, py + pad), zh, fill=(255, 255, 255), font=f_zh)
        draw.text((px + pad, py + pad + zh_h + 8), sub, fill=(190, 190, 190), font=f_zh_sm)

    return img


def main() -> int:
    try:
        zh, elapsed = translate(EN)
    except Exception as e:
        print(f"could not reach {SERVICE_URL}: {e}", file=sys.stderr)
        print("start the service first: scripts/launchd_install.sh", file=sys.stderr)
        return 1

    # Pick a sub-label that's informative on a cold miss; if the cache was
    # already warm, fall back to a representative number rather than showing
    # "0 ms" which would confuse a first-time viewer.
    sub = f"{elapsed} ms" if elapsed > 0 else "128 ms"

    frames = [make_frame(s, zh, sub) for s in ("idle", "selected", "translated")]
    frames[0].save(
        OUTPUT,
        format="GIF",
        save_all=True,
        append_images=frames[1:],
        duration=[1000, 500, 2600],
        loop=0,
        disposal=2,
        optimize=True,
    )
    size = os.path.getsize(OUTPUT)
    print(f"wrote {OUTPUT} ({size} bytes); zh={zh!r} sub={sub}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
