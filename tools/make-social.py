#!/usr/bin/env python3
"""Compose docs/social.png from film frames: a title, a line, and two stills.

Usage: make-social.py <film-dir> <out.png>

Picks a quiet frame (both mascots pacing, readings settled) and a frame with
the touch panel open. Frame numbers follow the script in RenderFilm (main.m):
the panel is open from 7.5s to ~11s at 15 fps. Needs Pillow.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

film, out = sys.argv[1], sys.argv[2]
W, H = 1280, 640
BG = (0, 0, 0)
card = Image.new("RGB", (W, H), BG)
draw = ImageDraw.Draw(card)


def font(name, size):
    for path in (f"/System/Library/Fonts/{name}", f"/Library/Fonts/{name}"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


title = font("Menlo.ttc", 44)
body = font("Helvetica.ttc", 22)
small = font("Helvetica.ttc", 18)

draw.text((72, 96), "claude-chatgpt-usage-touchbar", font=title, fill=(255, 255, 255))
draw.text((72, 168), "Your live Claude Code and Codex usage on the Touch Bar.", font=body, fill=(200, 200, 200))
draw.text((72, 204), "Two pixel creatures pace under a night sky; touch a bar for the details.", font=body, fill=(200, 200, 200))


def still(index, y, caption):
    frame = Image.open(os.path.join(film, f"f{index:04d}.png")).convert("RGB")
    # Frames are 2x (1200x60). Show the bar at 1136pt wide, nearest-neighbour.
    frame = frame.resize((1136, 57), Image.NEAREST)
    card.paste(frame, (72, y))
    draw.text((72, y + 66), caption, font=small, fill=(150, 150, 150))


still(int(6.0 * 15), 300, "walks, tires, panics — and answers a tap")
still(int(8.6 * 15), 440, "touch a bar: what is left, when it resets, how far through the window you are")

card.save(out)
print(out)
