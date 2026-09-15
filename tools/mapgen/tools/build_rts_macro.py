"""Build four low-frequency macro albedo fallbacks when the official Image API is unavailable.
The output is deliberately non-tiled and mapped once over the 2 km G4 world.
"""
from __future__ import annotations
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets/terrain_pbr"
SIZE = 2048
SEED = 4257

def low_field(rng, knots: int, angle: float = 0.0) -> np.ndarray:
    small = rng.random((knots, knots), dtype=np.float32)
    im = Image.fromarray(np.uint8(np.clip(small, 0, 1) * 255)).resize((SIZE, SIZE), Image.Resampling.BICUBIC)
    arr = np.asarray(im, dtype=np.float32) / 255.0
    if angle:
        im = Image.fromarray(np.uint8(np.clip(arr, 0, 1) * 255)).rotate(angle, resample=Image.Resampling.BICUBIC, expand=False)
        arr = np.asarray(im, dtype=np.float32) / 255.0
    return np.clip(arr, 0, 1)

def broad_regions(rng):
    a = low_field(rng, 8, 17)
    b = low_field(rng, 13, -29)
    c = low_field(rng, 21, 41)
    return np.clip(a * .52 + b * .31 + c * .17, 0, 1)

def write(name: str, image: np.ndarray) -> None:
    image = np.uint8(np.clip(image, 0, 1) * 255)
    Image.fromarray(image, "RGB").save(ASSETS / name, format="PNG", compress_level=6)

def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    region = broad_regions(rng)
    drift = low_field(rng, 10, 63)
    patch = low_field(rng, 26, -11)
    fine = low_field(rng, 64, 23)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    x = xx / SIZE; y = yy / SIZE
    # Broad irregular depositional fans, used only as albedo colour fields.
    fan1 = np.exp(-(((x-.20)/.34)**2 + ((y-.73)/.23)**2))
    fan2 = np.exp(-(((x-.76)/.28)**2 + ((y-.27)/.36)**2))
    fan = np.clip((fan1*.72 + fan2*.64) * (.65 + .35*drift), 0, 1)
    # 1. Warm grey-beige sand with dusty rose undertones.
    sand_base = np.array([.60, .505, .405], np.float32)
    sand_shift = (.90 + region*.15 + (patch-.5)*.10 + fan*.06)[...,None]
    sand = sand_base * sand_shift
    sand += np.stack([fan*.035, fan*.012, fan*.004], axis=-1)
    write("image25_macro_sand.png", sand)
    # 2. Grey-red gravel and sediment, large calm fields rather than speckles.
    gravel_base = np.array([.39, .355, .315], np.float32)
    gravel = gravel_base * (.86 + region[...,None]*.24 + (patch-.5)[...,None]*.10)
    gravel += np.stack([region*.045 + fan*.025, region*.028, region*.018], axis=-1)
    write("image25_macro_gravel.png", gravel)
    # 3. Layered red-brown rock wall albedo; broad strata without periodic striping.
    rock_base = np.array([.27, .205, .17], np.float32)
    strata = np.clip(.5 + .5*np.sin((y*7.2 + drift*.8 + patch*.45) * np.pi), 0, 1)
    rock = rock_base * (.76 + region[...,None]*.20 + strata[...,None]*.12)
    rock += np.stack([strata*.035, strata*.016, strata*.006], axis=-1)
    write("image25_macro_rock.png", rock)
    # 4. Wet shore mud and alluvial fan, desaturated cool taupe with teal-adjacent shadow.
    wet_base = np.array([.34, .345, .31], np.float32)
    wet = wet_base * (.82 + region[...,None]*.16 + fan[...,None]*.18)
    wet += np.stack([fan*.016, fan*.012, fan*.004], axis=-1)
    write("image25_macro_wet_shore.png", wet)
    manifest = {
      "size": [SIZE, SIZE], "world_size_m": [2000, 2000], "tiling": "single world-aligned 0..1; no texture repetition",
      "seed": SEED, "assets": ["image25_macro_sand.png", "image25_macro_gravel.png", "image25_macro_rock.png", "image25_macro_wet_shore.png"],
      "regions_m": [150, 250, 400], "generated_with_image_api": False,
      "fallback": "low-frequency procedural albedo after official OpenAI API timeout",
      "notes": "Fallback is flat albedo only; no normal, perspective, horizon, objects, text, grid, or regular tiles."
    }
    (ASSETS / "image25_macro_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print("WROTE", json.dumps(manifest))

if __name__ == "__main__":
    main()


