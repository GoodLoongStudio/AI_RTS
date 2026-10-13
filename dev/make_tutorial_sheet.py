# -*- coding: utf-8 -*-
"""生成「教学 · 快捷键与操作」总览图（一张图，深色工业科幻风，配 SystemUIStyle 主题）。

键位来源（已对照真实程序，2026-09-27）：
- source/csharp/Application/Input/DefaultInputBindings.cs（对局内权威绑定表）
- source/match/IsometricCamera3D.gd（相机平移=方向键/边缘、R/E 旋转、中键、滚轮）
- source/match/hud/TraditionalUnitCommandHUD.gd（部队命令按钮文案）
注意：project.godot 里的 move_map_*（WASD）是无消费者的死绑定，不进教学图。
【2026-09-28 用户核对"这些不存在吧？"】legacy.* 系列里还有三条**绑定存在但处理链路
是死路**的键位，也不进教学图：
- F1（legacy.hero_focus）：处理代码要求 hero 模式（AICommandHUD.control_mode=="hero"），
  没有任何生产代码会设成 hero（campaign_hero 组只有战役烟雾测试在用）→ 按了被忽略；
- U/I/O/P、J/K（legacy.command_*）：处理走 _begin_command，只能指挥 legacy_ai_squad_1/2/3
  组里的单位，而这个组没有任何生产代码往里加单位（Unit.gd 只在死亡时移出；副官协调器
  graph/squads.py 声明不读不写）→ 按了永远回"还没有可控单位"。
- Enter（legacy.chat_focus）是真键位：副官聊天输入框活着，保留。

配色沿革（都是用户反馈驱动的迭代）：
- v1 深棕军风 →「和主题配不上」；
- v2 白底高对比 → 对比度是够了，但整个游戏是深色科幻 UI（SystemUIStyle：
  深蓝灰玻璃 + 青/琥珀），白图放进暂停菜单仍然「对不上」。
- v3（本版）直接取 SystemUIStyle 的色板：深玻璃面板 + 琥珀标题 + 青色分区条，
  键帽做成「深色键帽 + 亮描边 + 顶部高光」模拟真实键位层次——键帽填充比面板
  亮 ~40 色阶并加 2px 描边，避免 v1 那次「键帽糊进背景」（当时只差 ~25 色阶）。
  画布透明，页面自己的深底透出来，图在任意深色页面上都成立。
"""
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1680, 1400

# ---- SystemUIStyle 色板（source/ui/SystemUIStyle.gd，改主题要同步这里）----
BG_CLEAR = (0, 0, 0, 0)            # 画布=全透明，面板浮在页面深底上
PANEL = (11, 29, 39, 247)          # #0b1d27 近实心深玻璃（GLASS_DEEP 观感）
PANEL_LINE = (73, 104, 117)        # #496875 LINE_STRONG 外框
PANEL_LINE_IN = (34, 64, 77)       # #22404d LINE_SOFT 内衬
GLOW = (38, 201, 232)              # #26c9e8 CYAN 外发光
TITLE = (243, 199, 123)            # #f3c77b AMBER_HI 标题（主菜单标题同色）
SUB = (231, 241, 243)              # #e7f1f3 TEXT 分区标题
TEXT = (231, 241, 243)             # #e7f1f3 TEXT 正文（主题正文字色，别自作主张压暗：
                                   # 2026-09-28 用户反馈"字不要那么暗"）
MUTED = (142, 167, 173)            # #8ea7ad MUTED 角标
CYAN = (38, 201, 232)              # #26c9e8 分区装饰条（主菜单顶部信息行同色）
KEY_BG = (27, 66, 82)              # 键帽填充（比面板亮 ~40 色阶，键帽要「浮」出来）
KEY_BORDER = (74, 115, 134)        # 键帽描边
KEY_HI = (110, 151, 168)           # 键帽顶部 1px 高光（倒角感）
KEY_TEXT = (241, 248, 250)         # 键帽字
RULE = (53, 84, 99)                # #355463 标题下横线

FONT_PATH = r"C:\Windows\Fonts\msyh.ttc"
FONT_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"


def font(size, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_PATH, size)


img = Image.new("RGBA", (W, H), BG_CLEAR)

# 外发光：青色圆角矩形放大后高斯模糊，垫在面板下面（对齐 glass() 的青色内发光观感）
glow_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow_layer)
gd.rounded_rectangle((10, 10, W - 10, H - 10), radius=22, fill=GLOW + (56,))
glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(12))
img.alpha_composite(glow_layer)

d = ImageDraw.Draw(img)

# 面板：深玻璃 + 亮外框 + 暗内衬（metal_frame 的双框层次）
d.rounded_rectangle((18, 18, W - 18, H - 18), radius=18, fill=PANEL,
                    outline=PANEL_LINE, width=2)
d.rounded_rectangle((26, 26, W - 26, H - 26), radius=12,
                    outline=PANEL_LINE_IN, width=1)

# 标题（琥珀金，同主菜单 Title）
d.text((W // 2, 78), "教 学 · 快捷键与操作", font=font(52, True),
       fill=TITLE, anchor="mm")
# 标题下横线：常规线 + 中央琥珀菱形，压住「光秃秃一条线」的廉价感
d.line((120, 126, W // 2 - 26, 126), fill=RULE, width=2)
d.line((W // 2 + 26, 126, W - 120, 126), fill=RULE, width=2)
d.polygon([(W // 2, 118), (W // 2 + 8, 126), (W // 2, 134), (W // 2 - 8, 126)],
          fill=TITLE)

# 左上角系统行（主菜单 "HERMES COMMAND // LOCAL" 同款青色小字），右下角版本角标
d.text((44, 40), "HERMES COMMAND // TUTORIAL", font=font(17),
       fill=CYAN, anchor="la")
d.text((W - 44, H - 40), "BUILD 0.1  •  快捷键速查", font=font(16),
       fill=MUTED, anchor="rd")

COL = [95, W // 2 + 30]      # 两栏左边缘
COL_W = W // 2 - 135
ROW_H = 46


def section(x, y, title_parts):
    """分区标题：青色装饰条 + 亮字。title_parts 可给 (text, color) 分段着色。"""
    d.rounded_rectangle((x, y + 4, x + 10, y + 34), radius=3, fill=CYAN)
    tx = x + 22
    for text, color in title_parts:
        d.text((tx, y + 19), text, font=font(34, True), fill=color, anchor="lm")
        tx += d.textlength(text, font=font(34, True))
    return y + 58


def row(x, y, keys, desc, key_font_size=24):
    kx = x + 6
    for k in keys.split("  "):
        if not k:
            continue
        tw = d.textlength(k, font=font(key_font_size, True))
        box = (kx, y + 2, kx + tw + 22, y + 38)
        d.rounded_rectangle(box, radius=8, fill=KEY_BG + (255,),
                            outline=KEY_BORDER, width=2)
        # 顶部内高光：键帽倒角（只画上边缘一条，别整圈）
        d.line((kx + 6, y + 4, kx + tw + 16, y + 4), fill=KEY_HI, width=1)
        d.text((kx + 11 + tw / 2, y + 20), k, font=font(key_font_size, True),
               fill=KEY_TEXT, anchor="mm")
        kx += tw + 34
    d.text((x + 250, y + 20), desc, font=font(26), fill=TEXT, anchor="lm")
    return y + ROW_H


y1 = section(COL[0], 168, [("鼠 标", SUB)])
for keys, desc in [
    ("左键", "选中单位 / 建筑"),
    ("左键拖拽", "框选多个单位"),
    ("Shift+左键", "追加选中"),
    ("右键", "移动 / 攻击 / 采集"),
    ("滚轮", "镜头缩放"),
]:
    y1 = row(COL[0], y1, keys, desc)

y1 = section(COL[0], y1 + 26, [("镜 头", SUB)])
for keys, desc in [
    ("↑ ↓ ← →", "平移镜头"),
    ("屏幕边缘", "滚屏（设置中可开关）"),
    ("R / E", "旋转镜头"),
    ("中键拖拽", "自由旋转视角"),
    ("中键双击", "复位视角"),
    ("空格", "跳到最近战况事件"),
]:
    y1 = row(COL[0], y1, keys, desc)

y1 = section(COL[0], y1 + 26, [("编 队", SUB)])
for keys, desc in [
    ("1 ~ 9", "选择编队"),
    ("Ctrl+1 ~ 9", "把当前选中设为编队"),
]:
    y1 = row(COL[0], y1, keys, desc)

y2 = section(COL[1], 168, [("部队命令（选中后）", SUB)])
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

y2 = section(COL[1], y2 + 26, [("建 造", SUB)])
for keys, desc in [
    ("R", "放置时旋转建筑朝向"),
]:
    y2 = row(COL[1], y2, keys, desc)

y2 = section(COL[1], y2 + 26, [("系 统", SUB)])
for keys, desc in [
    ("ESC", "取消 / 返回 / 暂停菜单"),
    ("F10", "暂停菜单"),
    ("TAB", "显示 / 隐藏 AI 副官面板"),
]:
    y2 = row(COL[1], y2, keys, desc)

y2 = section(COL[1], y2 + 26, [("AI 副官", SUB), ("「岚」", TITLE)])
for keys, desc in [
    ("Enter", "打开副官聊天"),
]:
    y2 = row(COL[1], y2, keys, desc)

out = r"G:\AIRTS\AI_RTS\assets\ui\tutorial\hotkeys_sheet.png"
import os
os.makedirs(os.path.dirname(out), exist_ok=True)
img.save(out)  # 保留 alpha：页面深底从面板四周透出
print("saved:", out, img.size)
