# -*- coding: utf-8 -*-
"""Generate the two bundled demo theme artworks procedurally.

Both images are 100% original program-generated art (no photos, no people),
so the public repository ships no likeness of any real person. Re-running this
script reproduces them bit-for-bit (fixed random seeds).

  python tools/generate-demo-art.py

Outputs:
  themes/aurora-veil/art.png  - night-sky aurora gradient with soft bokeh
  themes/ember-bloom/art.png  - warm geometric petals over cream light
"""
import math
import os
import random
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W, H = 1920, 1280


def save_png_atomic(image, path):
    """Write beside the destination, then atomically replace it on success."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    file_descriptor, temporary_path = tempfile.mkstemp(
        prefix=f".{os.path.basename(path)}.", suffix=".tmp", dir=os.path.dirname(path)
    )
    os.close(file_descriptor)
    try:
        image.save(temporary_path, "PNG", optimize=True)
        os.replace(temporary_path, path)
    finally:
        if os.path.exists(temporary_path):
            os.remove(temporary_path)


def vertical_gradient(size, stops):
    """stops: list of (t, (r,g,b)) with t in 0..1, sorted."""
    w, h = size
    ys = np.linspace(0.0, 1.0, h)
    channels = []
    ts = np.array([s[0] for s in stops])
    for c in range(3):
        vals = np.array([s[1][c] for s in stops], dtype=float)
        channels.append(np.interp(ys, ts, vals))
    grad = np.stack(channels, axis=-1).astype(np.uint8)
    return Image.fromarray(np.repeat(grad[:, None, :], w, axis=1))


def radial_glow(size, center, radius, color, peak_alpha):
    """Soft radial light spot as an RGBA layer."""
    w, h = size
    xs = np.arange(w)[None, :]
    ys = np.arange(h)[:, None]
    dist = np.sqrt((xs - center[0]) ** 2 + (ys - center[1]) ** 2)
    alpha = np.clip(1.0 - dist / radius, 0.0, 1.0) ** 2 * peak_alpha
    layer = np.zeros((h, w, 4), dtype=np.uint8)
    layer[..., 0], layer[..., 1], layer[..., 2] = color
    layer[..., 3] = alpha.astype(np.uint8)
    return Image.fromarray(layer)


def aurora_veil():
    rng = random.Random(20260716)
    img = vertical_gradient((W, H), [
        (0.00, (12, 10, 42)),
        (0.36, (26, 20, 74)),
        (0.62, (44, 34, 108)),
        (0.82, (58, 76, 134)),
        (1.00, (74, 110, 152)),
    ]).convert("RGBA")

    # Aurora curtains: translucent sine ribbons, heavily blurred.
    curtains = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(curtains)
    palettes = [
        ((64, 224, 190), 60),   # teal-green
        ((112, 146, 255), 46),  # periwinkle
        ((96, 232, 170), 52),   # mint
        ((168, 122, 255), 40),  # violet
        ((70, 210, 226), 44),   # cyan
    ]
    for band, (color, alpha) in enumerate(palettes):
        phase = rng.uniform(0, math.tau)
        base_y = 150 + band * 130 + rng.uniform(-40, 40)
        amp = rng.uniform(90, 170)
        thickness = rng.uniform(120, 210)
        # brighter towards the right side so the fullscreen focal area has interest
        for x in range(-40, W + 40, 6):
            t = x / W
            y = base_y + amp * math.sin(phase + t * math.tau * 1.4) + 90 * math.sin(phase * 2 + t * 9)
            local_alpha = int(alpha * (0.55 + 0.45 * t))
            draw.line(
                [(x, y - thickness * (0.5 + 0.3 * math.sin(t * 7 + phase))), (x + 4, y + thickness)],
                fill=color + (local_alpha,), width=9,
            )
    curtains = curtains.filter(ImageFilter.GaussianBlur(46))
    img.alpha_composite(curtains)

    # Focal glow cluster right-of-center (the hero/fullscreen crops look there).
    img.alpha_composite(radial_glow((W, H), (int(W * 0.74), int(H * 0.40)), 620, (120, 236, 214), 78))
    img.alpha_composite(radial_glow((W, H), (int(W * 0.86), int(H * 0.24)), 420, (150, 170, 255), 66))
    img.alpha_composite(radial_glow((W, H), (int(W * 0.62), int(H * 0.66)), 520, (92, 210, 240), 48))

    # Stars.
    stars = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(stars)
    for _ in range(420):
        x, y = rng.uniform(0, W), rng.uniform(0, H * 0.78)
        r = rng.uniform(0.6, 2.4)
        a = int(rng.uniform(70, 235))
        sdraw.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, a))
    for _ in range(14):  # a few cross twinkles
        x, y = rng.uniform(W * 0.3, W), rng.uniform(0, H * 0.5)
        length = rng.uniform(8, 20)
        sdraw.line([x - length, y, x + length, y], fill=(255, 255, 255, 130), width=1)
        sdraw.line([x, y - length, x, y + length], fill=(255, 255, 255, 130), width=1)
    img.alpha_composite(stars.filter(ImageFilter.GaussianBlur(0.6)))

    # Soft bokeh discs drifting bottom-right.
    bokeh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(bokeh)
    for _ in range(26):
        x, y = rng.uniform(W * 0.35, W * 1.02), rng.uniform(H * 0.30, H * 1.02)
        r = rng.uniform(16, 84)
        color = rng.choice([(140, 240, 216), (150, 176, 255), (208, 156, 255), (255, 255, 255)])
        a = int(rng.uniform(16, 52))
        bdraw.ellipse([x - r, y - r, x + r, y + r], fill=color + (a,))
    img.alpha_composite(bokeh.filter(ImageFilter.GaussianBlur(14)))

    return img.convert("RGB")


def petal(size, color, alpha):
    """One soft petal (teardrop-ish ellipse) on its own transparent tile."""
    pw, ph = size
    tile = Image.new("RGBA", (pw * 2, ph * 2), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tile)
    draw.ellipse([pw // 2, ph // 4, pw + pw // 2, ph + ph * 3 // 4], fill=color + (alpha,))
    draw.polygon([(pw, ph // 4 + 2), (pw - pw // 5, ph // 2), (pw + pw // 5, ph // 2)], fill=color + (alpha,))
    return tile


def ember_bloom():
    rng = random.Random(20260501)
    img = vertical_gradient((W, H), [
        (0.00, (255, 250, 242)),
        (0.42, (253, 240, 224)),
        (0.72, (250, 226, 203)),
        (1.00, (246, 210, 184)),
    ]).convert("RGBA")

    # Warm ambient glows.
    img.alpha_composite(radial_glow((W, H), (int(W * 0.78), int(H * 0.30)), 700, (255, 214, 150), 84))
    img.alpha_composite(radial_glow((W, H), (int(W * 0.20), int(H * 0.12)), 480, (255, 232, 190), 62))
    img.alpha_composite(radial_glow((W, H), (int(W * 0.58), int(H * 0.82)), 560, (250, 188, 148), 56))

    # Layered translucent petals; densest cluster right-of-center.
    petals = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    colors = [
        (232, 122, 84),   # ember coral
        (240, 156, 96),   # amber
        (226, 108, 118),  # rose
        (248, 186, 122),  # honey
        (214, 130, 156),  # mauve-pink
    ]
    for i in range(46):
        cluster = rng.random() < 0.62
        if cluster:
            cx = rng.uniform(W * 0.55, W * 0.98)
            cy = rng.uniform(H * 0.12, H * 0.72)
        else:
            cx = rng.uniform(-40, W * 0.55)
            cy = rng.uniform(H * 0.05, H * 1.0)
        scale = rng.uniform(0.5, 1.9)
        pw, ph = int(90 * scale), int(150 * scale)
        color = rng.choice(colors)
        alpha = int(rng.uniform(42, 96))
        tile = petal((pw, ph), color, alpha).rotate(rng.uniform(0, 360), expand=True, resample=Image.BICUBIC)
        tile = tile.filter(ImageFilter.GaussianBlur(rng.uniform(1.2, 5.5)))
        petals.alpha_composite(tile, (int(cx - tile.width / 2), int(cy - tile.height / 2)))
    img.alpha_composite(petals)

    # Fine golden speckles.
    sparks = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(sparks)
    for _ in range(220):
        x, y = rng.uniform(0, W), rng.uniform(0, H)
        r = rng.uniform(0.8, 3.0)
        a = int(rng.uniform(30, 110))
        sdraw.ellipse([x - r, y - r, x + r, y + r], fill=(255, 226, 168, a))
    img.alpha_composite(sparks.filter(ImageFilter.GaussianBlur(0.8)))

    # Gentle white veil top-left so hero text zones stay readable.
    img.alpha_composite(radial_glow((W, H), (int(W * 0.16), int(H * 0.30)), 760, (255, 250, 244), 70))

    return img.convert("RGB")


def main():
    targets = {
        os.path.join(ROOT, "themes", "aurora-veil", "art.png"): aurora_veil,
        os.path.join(ROOT, "themes", "ember-bloom", "art.png"): ember_bloom,
    }
    for path, builder in targets.items():
        image = builder()
        save_png_atomic(image, path)
        print(f"wrote {path} ({image.size[0]}x{image.size[1]})")


if __name__ == "__main__":
    main()
