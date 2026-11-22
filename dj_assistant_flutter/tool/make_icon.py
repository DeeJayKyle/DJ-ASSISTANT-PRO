"""Draws DJ Assistant's bento icon: four rounded tiles in the hub colours."""
# Run from dj_assistant_flutter: python3 tool/make_icon.py "$PWD"
import sys
from PIL import Image, ImageDraw, ImageFont

root = sys.argv[1]
S = 1024
img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

def grad_tile(box, c1, c2, r):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    tile = Image.new('RGBA', (w, h))
    td = ImageDraw.Draw(tile)
    for i in range(h + w):
        t = i / (h + w)
        col = tuple(int(c1[k] + (c2[k] - c1[k]) * t) for k in range(3)) + (255,)
        td.line([(i, 0), (0, i)], fill=col, width=2)
    mask = Image.new('L', (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], r, fill=255)
    img.paste(tile, (x0, y0), mask)

# background plate
d.rounded_rectangle([0, 0, S - 1, S - 1], 220, fill=(11, 17, 24, 255))
pad, gap = 92, 56
mid_x, mid_y = 590, 560
r = 96
# tiles: Library (cyan, wide), Analysis (violet), Crates (amber), Prep (rose, wide)
grad_tile((pad, pad, mid_x - gap // 2, mid_y - gap // 2), (56, 189, 248), (14, 116, 144), r)
grad_tile((mid_x + gap // 2, pad, S - pad, mid_y - gap // 2), (167, 139, 250), (109, 40, 217), r)
grad_tile((pad, mid_y + gap // 2, 434 - gap // 2, S - pad), (251, 191, 36), (217, 119, 6), r)
grad_tile((434 + gap // 2, mid_y + gap // 2, S - pad, S - pad), (251, 113, 133), (190, 18, 60), r)

# "DJ" on the big tile
font = ImageFont.truetype(f'{root}/assets/fonts/Inter-Bold.ttf', 300)
x0, y0, x1, y1 = pad, pad, mid_x - gap // 2, mid_y - gap // 2
bb = d.textbbox((0, 0), 'DJ', font=font)
tw, th = bb[2] - bb[0], bb[3] - bb[1]
d.text((x0 + (x1 - x0 - tw) / 2 - bb[0], y0 + (y1 - y0 - th) / 2 - bb[1]), 'DJ',
       font=font, fill=(255, 255, 255, 255))

# waveform bars on the rose tile
bx0, by0, bx1, by1 = 434 + gap // 2, mid_y + gap // 2, S - pad, S - pad
heights = [0.35, 0.7, 0.5, 0.95, 0.6, 0.8, 0.4]
n = len(heights); bw = 30; space = (bx1 - bx0 - 2 * 60 - n * bw) / (n - 1)
cy = (by0 + by1) / 2; hmax = (by1 - by0) - 110
for i, hgt in enumerate(heights):
    x = bx0 + 60 + i * (bw + space)
    h = hmax * hgt
    d.rounded_rectangle([x, cy - h / 2, x + bw, cy + h / 2], bw // 2, fill=(255, 255, 255, 240))

# a dot on the violet tile (analysis "pulse") and a crate line on amber
vx0, vy0, vx1, vy1 = mid_x + gap // 2, pad, S - pad, mid_y - gap // 2
cx, cyv = (vx0 + vx1) / 2, (vy0 + vy1) / 2
d.ellipse([cx - 52, cyv - 52, cx + 52, cyv + 52], fill=(255, 255, 255, 235))
ax0, ay0, ax1, ay1 = pad, mid_y + gap // 2, 434 - gap // 2, S - pad
for k in range(3):
    yy = ay0 + 95 + k * 70
    d.rounded_rectangle([ax0 + 70, yy, ax1 - 70, yy + 34], 17, fill=(255, 255, 255, 225))

img.save(f'{root}/windows/runner/resources/app_icon.ico',
         sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)])
img.resize((256, 256), Image.LANCZOS).save(f'{root}/assets/icon/app_icon_256.png')
print('ok')
