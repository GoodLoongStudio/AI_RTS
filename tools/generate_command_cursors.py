"""生成 AI_RTS 命令光标图标（红警式目标指定模式的自定义鼠标图标）。

用法（本机 Python 3.13）：
    "C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe" \
        tools/generate_command_cursors.py

输出：assets/ui/cursors/cursor_repair.png、cursor_sell.png（48x48，4x 超采样抗锯齿）

设计约定（与红警3 的习惯对齐）：
- 维修 = 橙色开口扳手；出售 = 金币 + $。
- 每个图标都是「白色外描边 → 深色内描边 → 主体色」三层，
  保证在浅色沙地、深色岩体、水面等任意地形上都清晰可辨。
- 热点取图标中心（见 CommandCursor.gd 的 CURSOR_HOTSPOT）。
"""

import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SS = 4  # 超采样倍数
SIZE = 48  # 最终尺寸（像素）
S = SIZE * SS  # 工作画布

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "ui", "cursors")

WHITE = (255, 255, 255, 242)
BLACK = (18, 18, 20, 255)
REPAIR_BODY = (245, 166, 35, 255)  # 橙：维修
SELL_BODY = (255, 202, 40, 255)  # 金：出售

WHITE_EDGE_RADIUS = 8
BLACK_EDGE_RADIUS = 4


def dilate(mask: Image.Image, radius: int) -> Image.Image:
    return mask.filter(ImageFilter.MaxFilter(radius * 2 + 1))


def compose(mask: Image.Image, body: Image.Image) -> Image.Image:
    """白外描边 → 深色内描边 → 主体，得到任意地形都看得清的光标。"""
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(Image.new("RGBA", (S, S), WHITE), mask=dilate(mask, WHITE_EDGE_RADIUS))
    out.paste(Image.new("RGBA", (S, S), BLACK), mask=dilate(mask, BLACK_EDGE_RADIUS))
    out.paste(body, mask=mask)
    return out.resize((SIZE, SIZE), Image.LANCZOS)


def build_repair_mask() -> Image.Image:
    """开口扳手：圆环头 + 左上开口 + 右下手柄。"""
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)

    cx, cy = 0.295 * S, 0.295 * S
    outer_r, inner_r = 0.238 * S, 0.112 * S
    d.ellipse([cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r], fill=255)
    d.ellipse([cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r], fill=0)

    # 开口朝左上（屏幕坐标 y 向下，225° 即左上）
    ang = math.radians(225.0)
    half = math.radians(23.0)
    big = S * 1.5
    d.polygon(
        [
            (cx, cy),
            (cx + big * math.cos(ang - half), cy + big * math.sin(ang - half)),
            (cx + big * math.cos(ang + half), cy + big * math.sin(ang + half)),
        ],
        fill=0,
    )

    # 手柄：从环的右下方（45°）伸出，圆头收尾
    hw = 0.112 * S
    hx, hy = cx + outer_r * 0.78, cy + outer_r * 0.78
    ex, ey = 0.855 * S, 0.855 * S
    d.line([(hx, hy), (ex, ey)], fill=255, width=int(round(hw * 2)))
    d.ellipse([hx - hw, hy - hw, hx + hw, hy + hw], fill=255)
    d.ellipse([ex - hw, ey - hw, ex + hw, ey + hw], fill=255)
    return mask


def build_sell_mask() -> Image.Image:
    """金币：外圆 + 内圈细环 + 中央 $（镂空透出深色描边）。"""
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    c = S * 0.5
    r = 0.44 * S
    d.ellipse([c - r, c - r, c + r, c + r], fill=255)
    # 内圈细环（镂空）
    d.ellipse([c - r * 0.86, c - r * 0.86, c + r * 0.86, c + r * 0.86], fill=0)
    d.ellipse([c - r * 0.78, c - r * 0.78, c + r * 0.78, c + r * 0.78], fill=255)

    glyph = Image.new("L", (S, S), 0)
    font = _load_font(int(S * 0.62))
    ImageDraw.Draw(glyph).text((c, c), "$", font=font, fill=255, anchor="mm")
    return ImageChops.subtract(mask, glyph)


def _load_font(size: int) -> ImageFont.FreeTypeFont:
    for name in ("arialbd.ttf", "arial.ttf", "seguisb.ttf", "segoeuib.ttf"):
        path = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", name)
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    raise RuntimeError("找不到可用的粗体字体（arialbd/arial/segoe）")


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)

    targets = [
        ("cursor_repair.png", build_repair_mask(), REPAIR_BODY),
        ("cursor_sell.png", build_sell_mask(), SELL_BODY),
    ]
    for filename, mask, body in targets:
        image = compose(mask, Image.new("RGBA", (S, S), body))
        path = os.path.join(OUT_DIR, filename)
        image.save(path)
        print("wrote %s (%dx%d)" % (path, image.width, image.height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
