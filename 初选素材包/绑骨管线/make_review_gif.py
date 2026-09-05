# -*- coding: utf-8 -*-
# 审核素材组装: 逐段 GIF + 九段合并预览 GIF + 索引图
# 输入: 4006/审核帧/<剪辑名>/f###.png (render_review.py 产物)
# 输出: 4006/动画审核/{01_Idle.gif ... 09_Death.gif, 九段合并预览.gif, 九段索引.png}
# 调色板: 全部帧共用一张全局调色板 + 无抖动 —— 逐帧独立量化会让地面渐变
# 逐帧变色, 表现为全画面闪烁
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006"
FRAMES = os.path.join(ROOT, "审核帧")
OUT = os.path.join(ROOT, "动画审核")
os.makedirs(OUT, exist_ok=True)

CLIPS = ["Idle", "Walk", "Run", "Attack", "Fire", "Gather", "Build", "Hit", "Death"]
FPS = 24
DUR = int(1000 / FPS)

def load_frames(clip):
    d = os.path.join(FRAMES, clip)
    files = sorted(f for f in os.listdir(d) if f.endswith(".png"))
    return [Image.open(os.path.join(d, f)).convert("RGB") for f in files]

def font(size):
    for path in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\msyhbd.ttc"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()

# ---- 全局调色板: 抽样 12 帧拼图量化一次, 全部帧共用, 消除逐帧变色 ----
sample_pool = []
for clip in CLIPS:
    frames = load_frames(clip)
    step = max(1, len(frames) // 4)
    sample_pool.extend(frames[::step][:4])
sw, sh = 100, 130
mosaic = Image.new("RGB", (sw * len(sample_pool), sh))
for i, f in enumerate(sample_pool):
    mosaic.paste(f.resize((sw, sh)), (i * sw, 0))
global_pal = mosaic.quantize(colors=128)

def to_p(frame):
    return frame.quantize(palette=global_pal, dither=Image.Dither.NONE)

# ---- 逐段 GIF ----
for idx, clip in enumerate(CLIPS, 1):
    frames = load_frames(clip)
    out = os.path.join(OUT, "%02d_%s.gif" % (idx, clip))
    palette = [to_p(f) for f in frames]
    palette[0].save(out, save_all=True, append_images=palette[1:],
                    duration=DUR, loop=0, optimize=False)
    print("GIF", os.path.basename(out), len(frames), "frames",
          os.path.getsize(out) // 1024, "KB")

# ---- 九段合并预览 (每段前插 0.8s 黑底标题卡) ----
title_font = font(44)
all_frames, all_durs = [], []
for idx, clip in enumerate(CLIPS, 1):
    card = Image.new("RGB", (400, 520), (18, 18, 22))
    d = ImageDraw.Draw(card)
    label = "%02d  %s" % (idx, clip)
    bbox = d.textbbox((0, 0), label, font=title_font)
    d.text(((400 - bbox[2] + bbox[0]) / 2, 240), label, fill=(255, 200, 60), font=title_font)
    all_frames.append(card)
    all_durs.append(800)
    all_frames.extend(load_frames(clip))
    all_durs.extend([DUR] * (len(all_frames) - len(all_durs)))
palette_frames = [to_p(f) for f in all_frames]
combined = os.path.join(OUT, "九段合并预览.gif")
palette_frames[0].save(combined, save_all=True, append_images=palette_frames[1:],
                       duration=all_durs, loop=0, optimize=False)
print("GIF 九段合并预览.gif", len(palette_frames), "frames",
      os.path.getsize(combined) // 1024, "KB")

# ---- 索引图 (3x3, 每段中帧) ----
W, H = 400, 520
sheet = Image.new("RGB", (W * 3, (H + 44) * 3), (18, 18, 22))
d = ImageDraw.Draw(sheet)
label_font = font(28)
for idx, clip in enumerate(CLIPS, 1):
    frames = load_frames(clip)
    mid = frames[len(frames) // 2].resize((W, H))
    col, row = (idx - 1) % 3, (idx - 1) // 3
    x, y = col * W, row * (H + 44)
    sheet.paste(mid, (x, y + 44))
    d.text((x + 10, y + 8), "%02d  %s" % (idx, clip), fill=(255, 200, 60), font=label_font)
index = os.path.join(OUT, "九段索引.png")
sheet.save(index)
print("INDEX", os.path.getsize(index) // 1024, "KB")
print("REVIEW_ASSETS_DONE")
