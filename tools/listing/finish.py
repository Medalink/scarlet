"""Turns tools/listing/out/ (from render.mjs) into the files that ship.

    python tools/listing/finish.py

Writes listing/images/logo-*.png, banner, and addon/Scarlet/Media/Icon.tga (64x64, 32-bit, uncompressed,
bottom-left origin, the format the client loads for ## IconTexture). Re-saves the screenshots with PNG optimisation.
"""
import sys
from pathlib import Path

from PIL import Image

repo = Path(__file__).resolve().parents[2]
out = repo / "tools" / "listing" / "out"
images = repo / "listing" / "images"
shots = repo / "listing" / "screenshots"
images.mkdir(parents=True, exist_ok=True)


def save_png(im, path):
    im.save(path, "PNG", optimize=True)
    print(f"{path.relative_to(repo)}  {im.width}x{im.height}  {path.stat().st_size} bytes")


logo = Image.open(out / "logo-1024.png").convert("RGB")
save_png(logo, images / "logo-1024x1024.png")
for size in (512, 400):
    save_png(logo.resize((size, size), Image.LANCZOS), images / f"logo-{size}x{size}.png")
save_png(Image.open(out / "banner-1500x500.png").convert("RGB"), images / "banner-1500x500.png")

# In-game icon. 64x64 keeps the mark crisp at the 16 to 32 px the AddOn list and the compartment draw.
icon = Image.open(out / "icon-256.png").convert("RGBA").resize((64, 64), Image.LANCZOS)
tga = repo / "addon" / "Scarlet" / "Media" / "Icon.tga"
icon.save(tga, "TGA", rle=False, orientation=-1)  # Pillow: -1 writes the bottom-left origin (flag 0x20 clear)
back = Image.open(tga).convert("RGBA")
head = tga.read_bytes()[:18]
bits, flags = head[16], head[17]
assert (back.width, back.height) == (64, 64) and bits == 32, (back.size, bits)
assert flags & 0x20 == 0, "expected bottom-left origin"
assert head[2] == 2, "expected uncompressed true-colour"
# The dot sits top right and the curve starts bottom left: a flipped file would swap them.
px = back.load()
assert px[51, 16][0] > 200 and px[51, 16][3] == 255, "dot is not at the top right"
assert px[0, 0][3] == 0, "corner should be transparent"
print(f"{tga.relative_to(repo)}  64x64  {tga.stat().st_size} bytes  header {bits}-bit flags {flags:#04x}")
sheet = Image.new("RGBA", (64 + 32 + 16 + 24, 64), (60, 60, 66, 255))
sheet.alpha_composite(back, (0, 0))
sheet.alpha_composite(back.resize((32, 32), Image.LANCZOS), (72, 0))
sheet.alpha_composite(back.resize((16, 16), Image.LANCZOS), (112, 0))
sheet.resize((sheet.width * 4, sheet.height * 4), Image.NEAREST).save(out / "icon-preview.png")

for p in sorted(shots.glob("*.png")):
    im = Image.open(p).convert("RGB")
    save_png(im, p)
sys.exit(0)
