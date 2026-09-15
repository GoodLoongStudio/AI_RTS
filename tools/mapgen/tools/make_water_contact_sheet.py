"""Build a compact comparison sheet from verified G2 water-combination previews."""
from pathlib import Path

from PIL import Image, ImageDraw
from rtsmap.viz.canvas import font


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "review/G2/water_combos"
ITEMS = [
    ("CROSSED RIVERS", "../highlands_release_seed16", "approved baseline, no lake"),
    ("SINGLE RIVER + LAKE", "single_lake", "one meandering river, one lake"),
    ("SINGLE RIVER + 2 LAKES", "single_two_lakes", "one meandering river, two lakes"),
    ("CROSSED RIVERS + LAKE", "crossed_lake_seed35", "intersecting rivers, one lake"),
    ("SEPARATE RIVERS + LAKE", "separate_lake", "two independent rivers, one lake"),
    ("2-LAKE BASIN", "two_lakes", "two lakes, no river"),
]


def main():
    tile_w, tile_h = 620, 700
    sheet = Image.new("RGB", (tile_w * 2, tile_h * 3), "white")
    draw = ImageDraw.Draw(sheet)
    for index, (title, folder, detail) in enumerate(ITEMS):
        image_path = OUT / folder / "overview.png"
        image = Image.open(image_path).convert("RGB")
        image.thumbnail((tile_w - 24, tile_h - 74), Image.Resampling.LANCZOS)
        x = (index % 2) * tile_w + (tile_w - image.width) // 2
        y = (index // 2) * tile_h + 50
        sheet.paste(image, (x, y))
        tx = (index % 2) * tile_w + 14
        ty = (index // 2) * tile_h + 12
        draw.text((tx, ty), title, fill=(30, 30, 30), font=font(24, bold=True))
        draw.text((tx, ty + 28), detail, fill=(90, 90, 90), font=font(18))
    sheet.save(OUT / "contact_sheet.png", optimize=True)


if __name__ == "__main__":
    main()
