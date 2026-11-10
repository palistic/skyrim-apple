#!/usr/bin/env python3
"""Offline preview of the immersive screen's depth-displaced grid (apple/Sources/App/ImmersiveScreen.swift).

Builds the same grid as the vertex shader from a Mac capture (LB_SHOT writes shot-N.bmp and depth-N.f32), then
renders it from each eye of a viewer sitting where the headset user does, so depth settings can be tuned without
the headset.

Usage: immersive_preview.py shot-N.bmp depth-N.f32 out_prefix [--scale 0.25] [--eye-back 3.0] [--viewer-x 0] [--dilate]
Writes out_prefix-sbs.png (left | right) and out_prefix-anaglyph.png (red left, cyan right).
"""
import argparse

DIST_DEFAULT = 3.0
import struct

import numpy as np
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("shot")
ap.add_argument("depth")
ap.add_argument("out")
ap.add_argument("--scale", type=float, default=0.25, help="LB_IMMERSIVE_DEPTH_SCALE")
ap.add_argument("--screen-m", type=float, default=3.0, help="LB_IMMERSIVE_DEPTH_SCREEN_M")
ap.add_argument("--near", type=float, default=15.0, help="LB_IMMERSIVE_DEPTH_NEAR")
ap.add_argument("--units", type=float, default=70.0, help="LB_IMMERSIVE_DEPTH_UNITS_PER_M")
ap.add_argument("--near-clamp", type=float, default=-0.15, help="lower clamp of 'behind'")
ap.add_argument("--dilate", action="store_true", help="nearest depth over half a grid cell, as the shader now does")
ap.add_argument("--tear", type=float, default=0.05, help="LB_IMMERSIVE_DEPTH_TEAR_M; 0 = never tear")
ap.add_argument("--ipd", type=float, default=0.064)
ap.add_argument("--eye-back", type=float, default=DIST_DEFAULT, help="ray origin in front of the screen, meters")
ap.add_argument("--viewer-x", type=float, default=0.0, help="head moved sideways, meters")
args = ap.parse_args()

WIDTH, DIST = 2.8, 3.0                     # screen width and distance, meters
GX, GY = 321, 181                          # grid vertices
OUT_W, OUT_H, OUT_HFOV = 1280, 720, 70.0   # preview camera

raw = open(args.depth, "rb").read()
w, h = struct.unpack_from("<II", raw)
depth = np.frombuffer(raw, dtype="<f4", count=w * h, offset=8).reshape(h, w)
image = np.asarray(Image.open(args.shot).convert("RGB").resize((w, h)), dtype=np.uint8)

half = np.array([WIDTH / 2, WIDTH / 2 * h / w])
eye_back = args.eye_back


def nearest(uv):
    x = np.clip((uv[..., 0] * w).astype(int), 0, w - 1)
    y = np.clip((uv[..., 1] * h).astype(int), 0, h - 1)
    return depth[y, x]


# Grid vertices, as the vertex shader places them.
u, v = np.meshgrid(np.arange(GX) / (GX - 1), np.arange(GY) / (GY - 1))
uv = np.stack([u, v], -1)
d = nearest(uv)
if args.dilate:
    cell = 0.5 / np.array([GX - 1, GY - 1])
    for off in ([-cell[0], 0], [cell[0], 0], [0, -cell[1]], [0, cell[1]]):
        d = np.minimum(d, nearest(uv + np.array(off)))
meters = (args.near / np.maximum(1 - d, 1e-6)) / args.units
behind = 1 - args.screen_m / np.maximum(meters, 0.05)
edge = np.minimum(np.minimum(u, 1 - u), np.minimum(v, 1 - v))
fade = np.clip(edge / 0.04, 0, 1); fade = fade * fade * (3 - 2 * fade)   # smoothstep, as the shader
t = 1 + args.scale * np.clip(behind, args.near_clamp, 1.0)   # tear test on this, unfaded
on_screen = np.stack([(u * 2 - 1) * half[0], (1 - v * 2) * half[1], np.zeros_like(u)], -1)
cam = np.array([0, 0, eye_back])
verts = cam + (on_screen - cam) * (1 + (t - 1) * fade)[..., None]

# Sample the mesh surface densely (bilinear across each cell, like the triangles) and splat it with a z-buffer.
SS = 2
fx = np.linspace(0, GX - 1, w * SS)
fy = np.linspace(0, GY - 1, h * SS)
X, Y = np.meshgrid(fx, fy)
x0 = np.minimum(X.astype(int), GX - 2)
y0 = np.minimum(Y.astype(int), GY - 2)
ax, ay = (X - x0)[..., None], (Y - y0)[..., None]
P = ((verts[y0, x0] * (1 - ax) + verts[y0, x0 + 1] * ax) * (1 - ay) +
     (verts[y0 + 1, x0] * (1 - ax) + verts[y0 + 1, x0 + 1] * ax) * ay).reshape(-1, 3)
col = image[np.clip((Y / (GY - 1) * h).astype(int), 0, h - 1),
            np.clip((X / (GX - 1) * w).astype(int), 0, w - 1)].reshape(-1, 3)
if args.tear > 0:
    # Cells whose corners' displacements differ by more than --tear are dropped (the shader does it per triangle).
    span = np.max([t[:-1, :-1], t[1:, :-1], t[:-1, 1:], t[1:, 1:]], 0) - np.min([t[:-1, :-1], t[1:, :-1], t[:-1, 1:], t[1:, 1:]], 0)
    keep = (span * eye_back <= args.tear)[y0, x0].reshape(-1)
    # Backplate: the image pushed to the farthest depth, behind everything, shows through.
    BP = (cam + (on_screen - cam) * (1 + args.scale * fade)[..., None])
    BPd = ((BP[y0, x0] * (1 - ax) + BP[y0, x0 + 1] * ax) * (1 - ay) +
           (BP[y0 + 1, x0] * (1 - ax) + BP[y0 + 1, x0 + 1] * ax) * ay).reshape(-1, 3)
    P = np.concatenate([P[keep], BPd])
    col = np.concatenate([col[keep], col])


def render(eye_x):
    e = np.array([args.viewer_x + eye_x, 0, DIST])
    rel = P - e
    z = -rel[:, 2]
    f = (OUT_W / 2) / np.tan(np.radians(OUT_HFOV / 2))
    px = (rel[:, 0] / z * f + OUT_W / 2).astype(int)
    py = (-rel[:, 1] / z * f + OUT_H / 2).astype(int)
    ok = (z > 0.05) & (px >= 0) & (px < OUT_W) & (py >= 0) & (py < OUT_H)
    px, py, z, c = px[ok], py[ok], z[ok], col[ok]
    order = np.argsort(-z)                      # far first, near overwrites
    out = np.zeros((OUT_H, OUT_W, 3), np.uint8)
    out[py[order], px[order]] = c[order]
    return out


left, right = render(-args.ipd / 2), render(args.ipd / 2)
Image.fromarray(np.concatenate([left, right], 1)).save(args.out + "-sbs.png")
ana = np.stack([left[..., 0], right[..., 1], right[..., 2]], -1)
Image.fromarray(ana).save(args.out + "-anaglyph.png")
far = np.clip(behind, args.near_clamp, 1).max() * args.scale * eye_back
print(f"scale {args.scale}: farthest point {far:.2f} m behind the screen; depth range "
      f"{meters.min():.2f}-{meters.max():.0f} m")
