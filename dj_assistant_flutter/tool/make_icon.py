"""Draws DJ Assistant's icon: a waveform rising out of an amber crate.
Run from dj_assistant_flutter: python3 tool/make_icon.py "$PWD"
Writes the Windows .ico, the in-app logo and a 1024 px master."""
import sys
from PIL import Image, ImageDraw

root = sys.argv[1]
S = 2048  # drawn at 2x, scaled down for smooth edges
TEAL, VIOLET = (94, 234, 212), (167, 139, 250)
AMBER, AMBER2 = (251, 191, 36), (217, 119, 6)
TOP, BOTTOM = (26, 28, 32), (13, 14, 17)

img = Image.new('RGBA', (S, S), (0, 0, 0, 0))


def paste_rounded(tile, box, r):
    x0, y0, x1, y1 = [int(v) for v in box]
    m = Image.new('L', (x1 - x0, y1 - y0), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, x1 - x0 - 1, y1 - y0 - 1], r, fill=255)
    img.paste(tile.resize((x1 - x0, y1 - y0)), (x0, y0), m)


def gradient(w, h, c1, c2, diagonal):
    t = Image.new('RGBA', (w, h))
    d = ImageDraw.Draw(t)
    n = w + h if diagonal else h
    for i in range(n):
        f = i / n
        c = tuple(int(c1[k] + (c2[k] - c1[k]) * f) for k in range(3)) + (255,)
        if diagonal:
            d.line([(i, 0), (0, i)], fill=c, width=3)
        else:
            d.line([(0, i), (w, i)], fill=c)
    return t


# graphite plate with a faint edge
paste_rounded(gradient(S, S, TOP, BOTTOM, False), (0, 0, S, S), 440)
ImageDraw.Draw(img).rounded_rectangle([3, 3, S - 4, S - 4], 437,
                                      outline=(255, 255, 255, 28), width=6)

# waveform bars, teal to violet, rising out of the crate
heights = [220, 420, 640, 860, 560, 760, 400, 250]
w, gap = 110, 50
x = S / 2 - (len(heights) * w + (len(heights) - 1) * gap) / 2
for i, h in enumerate(heights):
    f = i / (len(heights) - 1)
    c = tuple(int(TEAL[k] + (VIOLET[k] - TEAL[k]) * f) for k in range(3))
    paste_rounded(gradient(w, 10, c, c, False), (x, 1180 - h, x + w, 1250), 55)
    x += w + gap

# the crate, with its handle slot
paste_rounded(gradient(S - 600, 610, AMBER, AMBER2, True), (300, 1150, S - 300, 1760), 130)
ImageDraw.Draw(img).rounded_rectangle([780, 1300, 1268, 1380], 40, fill=(60, 34, 0, 200))

master = img.resize((1024, 1024), Image.LANCZOS)
master.save(f'{root}/assets/icon/app_icon_1024.png')
master.save(f'{root}/windows/runner/resources/app_icon.ico',
            sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)])
master.resize((256, 256), Image.LANCZOS).save(f'{root}/assets/icon/app_icon_256.png')
print('ok')
