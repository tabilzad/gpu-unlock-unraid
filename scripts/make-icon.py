#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Generate ca/gpu-unlock.png, the plugin's icon for Community Applications.

An open padlock on a rounded dark tile, in the style of the other tabilzad
plugins' icons. Drawn with a tiny built-in PNG encoder (4x4 supersampling for
smooth edges), so no imaging library is needed. Not NVIDIA's logo or colours,
not animated, 256x256 RGBA.

    python3 scripts/make-icon.py [OUT]
"""
import struct
import sys
import zlib

SIZE = 256
SAMPLES = 4                 # per axis, per pixel
TILE = (36, 41, 54)         # the tile, as in the Claude Code icon
LOCK = (255, 255, 255)      # body and shackle
ACCENT = (240, 160, 48)     # keyhole
TILE_RADIUS = 48

BODY = (46, 124, 158, 214)  # x0, y0, x1, y1 of the padlock body
BODY_RADIUS = 18
SHACKLE_CX, SHACKLE_CY = 166, 86   # centre of the shackle's arc
SHACKLE_R = 34                     # radius of the stroke's centre line
STROKE = 20
FREE_LEG_END = 108                 # the raised (open) leg stops above the body
KEY_CX, KEY_CY, KEY_R = 102, 160, 13
KEY_SLOT = (96, 108, 186)          # x0, x1, y1 of the slot below the hole


def in_rounded_rect(x, y, x0, y0, x1, y1, r):
    if not (x0 <= x <= x1 and y0 <= y <= y1):
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_shackle(x, y):
    half = STROKE / 2.0
    # upper half of a ring
    if y <= SHACKLE_CY:
        d = ((x - SHACKLE_CX) ** 2 + (y - SHACKLE_CY) ** 2) ** 0.5
        if abs(d - SHACKLE_R) <= half:
            return True
    left = SHACKLE_CX - SHACKLE_R
    right = SHACKLE_CX + SHACKLE_R
    # the left leg runs into the body
    if abs(x - left) <= half and SHACKLE_CY <= y <= BODY[1] + 4:
        return True
    # the right leg is lifted out, with a rounded end
    if abs(x - right) <= half and SHACKLE_CY <= y <= FREE_LEG_END:
        return True
    return (x - right) ** 2 + (y - FREE_LEG_END) ** 2 <= half * half


def in_keyhole(x, y):
    if (x - KEY_CX) ** 2 + (y - KEY_CY) ** 2 <= KEY_R * KEY_R:
        return True
    x0, x1, y1 = KEY_SLOT
    return x0 <= x <= x1 and KEY_CY <= y <= y1


def colour(x, y):
    """The colour at a sample point, or None outside the tile."""
    if not in_rounded_rect(x, y, 0, 0, SIZE, SIZE, TILE_RADIUS):
        return None
    if in_rounded_rect(x, y, *BODY, BODY_RADIUS):
        return ACCENT if in_keyhole(x, y) else LOCK
    if in_shackle(x, y):
        return LOCK
    return TILE


def pixel(px, py):
    r = g = b = a = 0
    for sy in range(SAMPLES):
        for sx in range(SAMPLES):
            c = colour(px + (sx + 0.5) / SAMPLES, py + (sy + 0.5) / SAMPLES)
            if c is not None:
                r += c[0]
                g += c[1]
                b += c[2]
                a += 1
    if a == 0:
        return (0, 0, 0, 0)
    n = SAMPLES * SAMPLES
    return (round(r / a), round(g / a), round(b / a), round(255 * a / n))


def png(width, height, rows):
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b''.join(b'\x00' + bytes(row) for row in rows)
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'ca/gpu-unlock.png'
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            row.extend(pixel(x, y))
        rows.append(row)
    with open(out, 'wb') as f:
        f.write(png(SIZE, SIZE, rows))
    print(out)


if __name__ == '__main__':
    main()
