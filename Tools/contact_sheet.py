"""Tile review captures into one image:  python Tools/contact_sheet.py day_highway day_down ...
(names without .png, from Captures/). Writes Captures/_sheet.png, 2 columns."""
import os, sys
from PIL import Image
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "Captures"))
names = sys.argv[1:] or sorted(f[:-4] for f in os.listdir(ROOT) if f.endswith(".png") and not f.startswith("_"))
ims = [Image.open(os.path.join(ROOT, n + ".png")).convert("RGB") for n in names]
w, h = ims[0].size
cols = 2 if len(ims) > 1 else 1
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (w * cols, h * rows))
for i, im in enumerate(ims):
    sheet.paste(im.resize((w, h)), ((i % cols) * w, (i // cols) * h))
sheet.save(os.path.join(ROOT, "_sheet.png"))
print(os.path.join(ROOT, "_sheet.png"), sheet.size)
