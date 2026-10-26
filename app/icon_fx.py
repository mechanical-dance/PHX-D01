"""Rough up the rendered icon: low resolution, film grain, PS1-style 15-bit colour with ordered dither, hard pixels.

    uv run --with pillow --with numpy python app/icon_fx.py in-1024.png out-1024.png
"""
import sys
import numpy as np
from PIL import Image

LOW = 192                      # working resolution; each pixel becomes a hard block at 1024
BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) / 16 - 0.5

src = Image.open(sys.argv[1]).convert('RGBA')
small = np.asarray(src.resize((LOW, LOW), Image.BOX)).astype(np.float32)
rgb, alpha = small[..., :3], small[..., 3:]
rng = np.random.default_rng(7)
rgb += rng.normal(0, 7, rgb.shape[:2])[..., None] + rng.normal(0, 3, rgb.shape)   # luma grain plus a little chroma
step = 255 / 31                                                                    # 5 bits per channel
dither = np.tile(BAYER, (LOW // 4, LOW // 4))[..., None] * step
rgb = np.clip(np.round((rgb + dither) / step) * step, 0, 255)
alpha = np.where(alpha > 128, 255, 0)
out = Image.fromarray(np.concatenate([rgb, alpha], -1).astype(np.uint8), 'RGBA').resize((1024, 1024), Image.NEAREST)
out.save(sys.argv[2])
