#!/usr/bin/env python3
"""Draw the app icon: an iPad beside a wider monitor carrying two windows.

Run once and commit the PNG; SideStore fetches it by URL from the repo.

Usage: make_icon.py <output.png>
"""

import sys

from PIL import Image, ImageDraw

SIZE = 512
BG_TOP = (18, 22, 40)
BG_BOTTOM = (32, 40, 68)
IPAD = (86, 96, 134)
MONITOR_FRAME = (120, 214, 205)
WINDOW_A = (250, 194, 74)
WINDOW_B = (114, 209, 200)


def main() -> None:
    out = sys.argv[1]
    image = Image.new("RGB", (SIZE, SIZE), BG_TOP)
    draw = ImageDraw.Draw(image)

    # Vertical gradient ground.
    for y in range(SIZE):
        t = y / (SIZE - 1)
        draw.line(
            [(0, y), (SIZE, y)],
            fill=tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)),
        )

    # The iPad, standing on the left.
    draw.rounded_rectangle([62, 168, 186, 384], radius=14, fill=IPAD)
    draw.rounded_rectangle([74, 182, 174, 370], radius=8, fill=(24, 30, 52))

    # The monitor, wider, on the right — the point of the whole app.
    draw.rounded_rectangle([206, 140, 452, 330], radius=18, outline=MONITOR_FRAME, width=7)
    draw.rounded_rectangle([218, 152, 440, 318], radius=10, fill=(22, 28, 48))
    draw.rectangle([314, 330, 344, 372], fill=MONITOR_FRAME)
    draw.rounded_rectangle([272, 366, 386, 384], radius=9, fill=MONITOR_FRAME)

    # Two windows on that monitor, tiled side by side.
    draw.rounded_rectangle([232, 166, 322, 302], radius=7, fill=WINDOW_A)
    draw.rounded_rectangle([232, 166, 322, 186], radius=7, fill=(215, 160, 48))
    draw.rounded_rectangle([334, 166, 426, 302], radius=7, fill=WINDOW_B)
    draw.rounded_rectangle([334, 166, 426, 186], radius=7, fill=(78, 170, 162))

    image.save(out, "PNG")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
