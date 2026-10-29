"""Draws Attic's app icon (the Roofline design, Terracotta) and writes AppIcon.icns.
Mirrors AppIcon.svg. Run: python3 Resources/make_icon.py  (needs Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw

S = 4                      # supersample, then scale down for smooth edges
BG, FG = "#C4553A", "#FFF4E8"
here = Path(__file__).resolve().parent

def p(*xy): return [v * S for v in xy]

def stroke(d, pts, w):
    pts = [(x * S, y * S) for x, y in pts]
    d.line(pts, fill=FG, width=w * S, joint="curve")
    r = w * S / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=FG)

img = Image.new("RGBA", (1024 * S, 1024 * S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle(p(100, 100, 924, 924), radius=185 * S, fill=BG)
stroke(d, [(250, 470), (512, 250), (774, 470)], 64)
# envelope outline: stroke centred on the 300,530 424x290 rect, like the SVG
d.rounded_rectangle(p(276, 506, 748, 844), radius=60 * S, fill=FG)
d.rounded_rectangle(p(324, 554, 700, 796), radius=12 * S, fill=BG)
stroke(d, [(322, 556), (512, 694), (702, 556)], 48)

icon = img.resize((1024, 1024), Image.LANCZOS)
icon.save(here / "AppIcon-1024.png")
icon.save(here / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("wrote", here / "AppIcon.icns")
