# -*- coding: utf-8 -*-
# 胶片条生成: 每段均匀抽 10 帧排成序列图 (带帧号), 供逐段目检动作弧线
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\审核帧"
OUT = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\动画审核\胶片条"
os.makedirs(OUT, exist_ok=True)
CLIPS = ["Idle", "Walk", "Run", "Attack", "Fire", "Gather", "Build", "Hit", "Death"]
TILE_W, TILE_H = 200, 260

def font(size):
    try:
        return ImageFont.truetype(r"C:\Windows\Fonts\consola.ttf", size)
    except Exception:
        return ImageFont.load_default()

fnt = font(16)
for clip in CLIPS:
    fdir = os.path.join(ROOT, clip)
    files = sorted(f for f in os.listdir(fdir) if f.endswith(".png"))
    n = len(files)
    picks = [files[int(i * (n - 1) / 9)] for i in range(10)]
    sheet = Image.new("RGB", (TILE_W * 10, TILE_H + 24), (15, 15, 18))
    dr = ImageDraw.Draw(sheet)
    for i, fname in enumerate(picks):
        img = Image.open(os.path.join(fdir, fname)).convert("RGB").resize((TILE_W, TILE_H))
        sheet.paste(img, (i * TILE_W, 24))
        dr.text((i * TILE_W + 6, 4), "%s" % fname[1:4], fill=(120, 220, 255), font=fnt)
    sheet.save(os.path.join(OUT, "%s.png" % clip))
    print("STRIP", clip, n, "frames")
print("STRIPS_DONE")
