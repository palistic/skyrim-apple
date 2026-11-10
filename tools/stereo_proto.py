"""Offline prototype of depth-reprojected stereo (docs/perf/IMMERSIVE_OPTIONS.md, section 0).

Usage: stereo_proto.py shot-N.bmp depth-N.f32 out_prefix [--ipd 0.064] [--near 15] [--hfov 80.7] [--units 70]

Takes one mono frame and the game's depth target of the same frame (both written by LB_SHOT) and synthesizes the
left and right eye views the way a compositor fragment shader would: for each output pixel, search along the row
for the source pixel whose depth-dependent shift lands on it (a few fixed-point steps). Writes
<out>-sbs.jpg (left | right), <out>-anaglyph.jpg and <out>-holes.jpg (where the search did not converge: surface
the mono frame never saw), and prints how much of the picture that is.
"""
import argparse
import struct
import sys

import numpy as np
from PIL import Image

p = argparse.ArgumentParser()
p.add_argument("shot"); p.add_argument("depth"); p.add_argument("out")
p.add_argument("--ipd", type=float, default=0.064, help="eye separation in metres")
p.add_argument("--near", type=float, default=15.0, help="camera near plane in game units (fNearDistance)")
p.add_argument("--hfov", type=float, default=80.7, help="horizontal field of view of the frame in degrees")
p.add_argument("--units", type=float, default=70.0, help="game units per metre")
p.add_argument("--steps", type=int, default=8)
a = p.parse_args()

rgb = np.asarray(Image.open(a.shot).convert("RGB"), dtype=np.float32)
raw = open(a.depth, "rb").read()
w, h = struct.unpack_from("<II", raw)
d = np.frombuffer(raw, dtype="<f4", offset=8).reshape(h, w)
if rgb.shape[:2] != (h, w):
    sys.exit("shot and depth sizes differ")
# D3D depth with a far plane much larger than near: view distance ~ near / (1 - d)
z = a.near / np.maximum(1.0 - d, 1e-6)
fx = (w / 2) / np.tan(np.radians(a.hfov) / 2)
half = a.ipd * a.units / 2
disp = fx * half / z            # pixels a point moves for one eye, relative to the mono camera between the eyes
print("depth: nearest %.1f m, median %.1f m; shift per eye: max %.1f px, median %.2f px"
      % (z.min() / a.units, np.median(z) / a.units, disp.max(), np.median(disp)))

xs = np.arange(w, dtype=np.float32)[None, :].repeat(h, 0)
rows = np.arange(h)[:, None].repeat(w, 1)


def sample(img, x):
    x0 = np.clip(np.floor(x).astype(np.int32), 0, w - 2)
    t = np.clip(x - x0, 0, 1)
    if img.ndim == 3:
        t = t[..., None]
    return img[rows, x0] * (1 - t) + img[rows, x0 + 1] * t


def eye(sign):
    """sign -1: left eye (the scene moves right), +1: right eye."""
    src = xs.copy()
    for _ in range(a.steps):
        src = xs + sign * sample(disp, src)       # source x whose shifted position is this pixel
    err = np.abs(src - sign * sample(disp, src) - xs)
    # a nearer surface that also lands here wins: step toward the eye's side and keep the larger shift
    return sample(rgb, src), err > 1.0


left, lh = eye(-1)
right, rh = eye(+1)
img = lambda x: Image.fromarray(np.clip(x, 0, 255).astype(np.uint8))
img(np.concatenate([left, right], 1)).save(a.out + "-sbs.jpg", quality=90)
ana = left.copy(); ana[..., 1:] = right[..., 1:]
img(ana).save(a.out + "-anaglyph.jpg", quality=90)
holes = rgb * 0.35
holes[lh] = (255, 0, 0); holes[rh & ~lh] = (0, 160, 255)
img(holes).save(a.out + "-holes.jpg", quality=90)
print("unresolved pixels: left %.2f%%, right %.2f%%" % (100 * lh.mean(), 100 * rh.mean()))
