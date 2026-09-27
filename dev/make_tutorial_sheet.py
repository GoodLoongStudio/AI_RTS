# -*- coding: utf-8 -*-
"""生成「教学 · 快捷键与操作」总览图（一张图，暗色军风，配游戏 UI）。

键位来源（已对照真实程序，2026-09-27）：
- source/csharp/Application/Input/DefaultInputBindings.cs（对局内权威绑定表）
- source/match/IsometricCamera3D.gd（相机平移=方向键/边缘、R/E 旋转、中键、滚轮）
- source/match/hud/TraditionalUnitCommandHUD.gd（部队命令按钮文案）
注意：project.godot 里的 move_map_*（WASD）是无消费者的死绑定，不进教学图。
"""
from PIL import Image, ImageDraw, ImageFont

W, H = 1680, 1400
# 2026-09-27 用户反馈"教学页面有点暗，和主题配不上"：
# 从深棕换成游戏主题的深蓝灰 + 金（对齐暂停菜单/侧栏观感），整体提亮一档，
# 正文与键帽对比度拉高。
BG = (21, 24, 31, 255)
PANEL = (41, 46, 57, 255)
HEADER = (232, 196, 122)
TEXT = (246, 244, 238)
DIM = (205, 210, 219)
KEY_BG = (66, 73, 88, 255)
KEY_BORDER = (150, 158, 174)
ACCENT = (235, 150, 84)

FONT_PATH = r"C:\Windows\Fonts\msyh.ttc"
FONT_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"


def font(size, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_PATH, size)


img = Image.new("RGBA", (W, H), BG)
d = ImageDraw.Draw(img)

# 外框面板
d.rounded_rectangle((18, 18, W - 18, H - 18), radius=18, fill=PANEL,
                    outline=(108, 116, 134), width=3)

# 标题
d.text((W // 2, 74), "教 学 · 快捷键与操作", font=font(52, True),
       fill=HEADER, anchor="mm")
d.line((120, 120, W - 120, 120), fill=(108, 116, 134), width=2)

COL = [95, W // 2 + 30]      # 两栏左边缘
COL_W = W // 2 - 135
ROW_H = 46


def section(x, y, title):
    d.rounded_rectangle((x, y + 4, x + 10, y + 34), radius=3, fill=ACCENT)
    d.text((x + 22, y + 19), title, font=font(34, True), fill=HEADER, anchor="lm")
    return y + 58


def row(x, y, keys, desc, key_font_size=24):
    kx = x + 6
    for k in keys.split("  "):
        if not k:
            continue
        tw = d.textlength(k, font=font(key_font_size, True))
        d.rounded_rectangle((kx, y + 2, kx + tw + 22, y + 38), radius=8,
                            fill=KEY_BG, outline=KEY_BORDER, width=2)
        d.text((kx + 11 + tw / 2, y + 20), k, font=font(key_font_size, True),
               fill=TEXT, anchor="mm")
        kx += tw + 34
    d.text((x + 250, y + 20), desc, font=font(26), fill=DIM, anchor="lm")
    return y + ROW_H


y1 = section(COL[0], 150, "鼠 标")
for keys, desc in [
    ("左键", "选中单位 / 建筑"),
    ("左键拖拽", "框选多个单位"),
    ("Shift+左键", "追加选中"),
    ("右键", "移动 / 攻击 / 采集"),
    ("滚轮", "镜头缩放"),
]:
    y1 = row(COL[0], y1, keys, desc)

y1 = section(COL[0], y1 + 26, "镜 头")
for keys, desc in [
    ("↑ ↓ ← →", "平移镜头"),
    ("屏幕边缘", "滚屏（设置中可开关）"),
    ("R / E", "旋转镜头"),
    ("中键拖拽", "自由旋转视角"),
    ("中键双击", "复位视角"),
    ("空格", "跳到最近战况事件"),
]:
    y1 = row(COL[0], y1, keys, desc)

y1 = section(COL[0], y1 + 26, "编 队")
for keys, desc in [
    ("1 ~ 9", "选择编队"),
    ("Ctrl+1 ~ 9", "把当前选中设为编队"),
]:
    y1 = row(COL[0], y1, keys, desc)

y2 = section(COL[1], 150, "部队命令（选中后）")
for keys, desc in [
    ("A", "移动并攻击"),
    ("S", "停止"),
    ("C", "强制移动"),
    ("X", "强制攻击"),
    ("Z", "战术后退"),
    ("T", "侵略姿态"),
    ("Y", "警戒姿态"),
    ("G", "固守姿态"),
    ("V", "撤回基地"),
    ("H", "停火 / 自由开火"),
    ("B", "清除集结点"),
]:
    y2 = row(COL[1], y2, keys, desc)

y2 = section(COL[1], y2 + 26, "建 造")
for keys, desc in [
    ("R", "放置时旋转建筑朝向"),
]:
    y2 = row(COL[1], y2, keys, desc)

y2 = section(COL[1], y2 + 26, "系 统")
for keys, desc in [
    ("ESC", "取消 / 返回 / 暂停菜单"),
    ("F10", "暂停菜单"),
    ("TAB", "显示 / 隐藏 AI 副官面板"),
]:
    y2 = row(COL[1], y2, keys, desc)

y2 = section(COL[1], y2 + 26, "AI 副官「岚」")
for keys, desc in [
    ("F1", "镜头锁定英雄"),
    ("Enter", "打开副官聊天"),
    ("U / I / O / P", "移动 / 攻击 / 防守 / 侦察"),
    ("J / K", "撤退 / 停止"),
]:
    y2 = row(COL[1], y2, keys, desc)

out = r"G:\AIRTS\AI_RTS\assets\ui\tutorial\hotkeys_sheet.png"
import os
os.makedirs(os.path.dirname(out), exist_ok=True)
img.convert("RGB").save(out)
print("saved:", out, img.size)
