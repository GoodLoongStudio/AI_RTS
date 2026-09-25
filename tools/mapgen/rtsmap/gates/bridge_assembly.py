"""G4 桥组合模块：用 4006 科幻世界同组桥素材拼装真实桥，替代程序生成的裸 BoxMesh 桥面/护栏。

用户认可形式（review/G4/bridge_assemblies/single_tier_ends/bridge_2.png）：
- SM_Bld_Bridge_01        沿桥轴重复拼接主桥面（标准段，优先重复、仅有限调长）。
- SM_Bld_Bridge_End_01    每岸仅一层收口，连接桥面与岸面（0.7m 高差的过渡坡）。
- SM_Bld_Bridge_Rail_01   两侧连续护栏。
不使用双层收口或间隔护栏。
2026-09-24：SM_Bld_Bridge_Rail_Pillar_01 桥端立柱按用户要求取消——它的内缘压在
可走净宽内，站在坡口行走线上（详见 build_bridge_assembly 内注释）。

模型实测尺寸（tools/godot/bridge_assemblies.gd 产出的 measurements.json，模型局部 AABB）：
  deck   SM_Bld_Bridge_01            w=10.049 h=0.926 l=10.0   顶面 y=0
  end    SM_Bld_Bridge_End_01        w=10.049 h=0.926 l=2.759  顶面 y=0（向岸侧下斜）
  rail   SM_Bld_Bridge_Rail_01       w=0.966  h=1.998 l=10.0
  pillar SM_Bld_Bridge_Rail_Pillar_01 w=1.5   h=2.269 l=1.5

校准原则（不照搬参考脚本的 AABB 归一化缩放作为生产）：
- 桥面顶面世界高度 deck_top = max(两岸岸面高) + DECK_ABOVE_SHORE(0.7)。
- 可见部件按模型实际路面（顶面 y=0）对齐：局部原点 y 置于 deck_top。
- 导航/碰撞可走面 = 端坡(岸面→deck_top) + 平桥面(deck_top)，宽度为净宽
  clear_width = deck_width - 2*rail_width（护栏侵占计入通行净宽）。
- 桥下水体保持连续：不抬高高度场桥格、不用隐藏平面穿水造假连通。
"""
import math

# 模型实测 AABB（宽 w / 高 h / 长 l），顶面在局部 y=0
DECK = dict(w=10.049, h=0.926, l=10.0)
END = dict(w=10.049, h=0.926, l=2.759)
RAIL = dict(w=0.966, h=1.998, l=10.0)
PILLAR = dict(w=1.5, h=2.269, l=1.5)

DECK_ABOVE_SHORE = 0.7      # 样桥桥面比岸面高 0.7m
RAIL_WIDTH = 0.65           # 护栏可视/侵占宽度（认可样桥取值）
END_RAMP_STEPS = 3          # 端坡离散为 3 级可走板（每级 <=0.3m，climb 可越）
WALK_THICK = 1.0            # 可走板厚度（与地形高度板一致）

PART_RES = {
    "deck": "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/SM_Bld_Bridge_01.fbx",
    "end": "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/SM_Bld_Bridge_End_01.fbx",
    "rail": "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/SM_Bld_Bridge_Rail_01.fbx",
    "pillar": "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/SM_Bld_Bridge_Rail_Pillar_01.fbx",
}
ATLAS = "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/PolygonScifiWorlds_Texture_01_A.png"


def fmt_scaled(x, y, z, yaw_deg, sx, sy, sz):
    """roty(yaw) * 非均匀缩放 的 Transform3D 文本（列=缩放后的局部轴）。"""
    a = math.radians(yaw_deg)
    c, s = math.cos(a), math.sin(a)
    return (f"Transform3D({sx * c:.4f}, 0, {sz * s:.4f}, 0, {sy:.4f}, 0, "
            f"{-sx * s:.4f}, 0, {sz * c:.4f}, {x:.3f}, {y:.3f}, {z:.3f})")


def build_bridge_assembly(br, sample_h, deck_width=None):
    """由桥端点/跨距/方向/岸面高度确定模块数量与变换。

    sample_h(x, z) -> 岸面/地面高度（同源高度场）。
    返回 dict(parts=可见部件, walk=导航可走板, rails=护栏碰撞, meta=...)。
    """
    ax, az = float(br["a"][0]), float(br["a"][1])
    bx, bz = float(br["b"][0]), float(br["b"][1])
    dx, dz = bx - ax, bz - az
    span = math.hypot(dx, dz)
    if span <= 1e-6:
        raise ValueError("桥端点重合，无法生成桥组合")
    ux, uz = dx / span, dz / span
    yaw = math.degrees(math.atan2(ux, uz))     # 局部 +Z 对齐桥轴 a→b
    W = float(deck_width if deck_width is not None else br.get("width", 8.0))
    bank_a = float(sample_h(ax, az))
    bank_b = float(sample_h(bx, bz))
    deck_top = max(bank_a, bank_b) + DECK_ABOVE_SHORE

    # 端收口用原生长度（不变形）；中段桥面重复标准段并仅有限调长
    end_len = END["l"]
    deck_span = max(span - 2.0 * end_len, DECK["l"] * 0.5)
    n_seg = max(1, int(round(deck_span / DECK["l"])))
    seg_len = deck_span / n_seg
    # 宽度统一缩放到桥宽；高度保持原生（避免变形）
    sx_w = W / DECK["w"]
    rail_sx = RAIL_WIDTH / RAIL["w"]
    clear_w = W - 2.0 * RAIL_WIDTH

    parts = []

    def along(t, lateral=0.0):
        # 桥轴 t 处 + 横向偏移（垂直于轴）的世界 XZ
        px, pz = -uz, ux                      # 垂直于轴的单位向量
        return ax + ux * t + px * lateral, az + uz * t + pz * lateral

    # 主桥面：重复标准段
    for i in range(n_seg):
        t0 = end_len + i * seg_len
        x, z = along(t0)
        parts.append(dict(kind="deck", res=PART_RES["deck"],
                          transform=fmt_scaled(x, deck_top, z, yaw, sx_w, 1.0, seg_len / DECK["l"])))
    # 每岸一层收口（连接桥面与岸面）。End 模型低(岸)端在局部 +z：
    # end_a 置于 t=end_len 并翻转→覆盖 [0,end_len]（岸a低→桥面高）；
    # end_b 置于 t=span-end_len 不翻转→覆盖 [span-end_len,span]（桥面高→岸b低）。
    for tag, t0, flip in (("end_a", end_len, True), ("end_b", end_len + deck_span, False)):
        x, z = along(t0)
        eyaw = yaw + (180.0 if flip else 0.0)
        parts.append(dict(kind="end", res=PART_RES["end"],
                          transform=fmt_scaled(x, deck_top, z, eyaw, sx_w, 1.0, 1.0)))
    # 两侧连续护栏（整跨一条，按跨距有限调长）
    rail_len = span
    for side in (-1, 1):
        lat = side * (W / 2.0 - RAIL_WIDTH / 2.0)
        x, z = along(0.0, lat)
        parts.append(dict(kind="rail", res=PART_RES["rail"],
                          transform=fmt_scaled(x, deck_top, z, yaw,
                                               rail_sx, 1.0, rail_len / RAIL["l"])))
    # 【2026-09-24 用户反馈"桥两端那 2 个柱子不方便寻路"】桥端立柱已移除。
    # 原因：立柱放在 t=0.4 / span-0.4、lat=±(W/2-RAIL_WIDTH/2)，而可走净宽是
    # ±(W/2-RAIL_WIDTH)——立柱宽 1.5m，内缘正好压在净宽边界内约 0.43m，
    # 于是每岸两根柱子站在坡口行走线上：单位明明能过（立柱无碰撞体）却从柱子里
    # 穿过去，观感就是"桥口被堵、点不上去"。净宽外侧只剩 0.65m 甲板，挪不出去，
    # 故直接取消；护栏本身已围出桥缘，收口件（End）负责岸面过渡。
    # 如需桥头立柱，可放到岸侧（t<0 / t>span、lat 超出甲板半宽）另做一轮。

    # 导航/碰撞可走板：端坡(岸→deck_top) + 平桥面，宽度=净宽
    walk = []

    def ramp_slabs(t_start, t_end, h0, h1):
        n = END_RAMP_STEPS
        seg = (t_end - t_start) / n
        for k in range(n):
            ta = t_start + k * seg
            tc = ta + seg / 2.0
            h = h0 + (h1 - h0) * ((k + 0.5) / n)
            x, z = along(tc)
            walk.append(dict(x=x, z=z, yaw=yaw, length=seg + 0.05, width=clear_w, top=h))

    ramp_slabs(0.0, end_len, bank_a, deck_top)
    xc, zc = along(end_len + deck_span / 2.0)
    walk.append(dict(x=xc, z=zc, yaw=yaw, length=deck_span, width=clear_w, top=deck_top))
    ramp_slabs(end_len + deck_span, span, deck_top, bank_b)

    # 护栏碰撞（物理阻挡，不进导航组；导航靠净宽留洞）
    rails = []
    for side in (-1, 1):
        lat = side * (W / 2.0 - RAIL_WIDTH / 2.0)
        x, z = along(span / 2.0, lat)
        rails.append(dict(x=x, z=z, yaw=yaw, length=span, width=RAIL_WIDTH,
                          top=deck_top + 0.6))

    meta = dict(span=round(span, 3), yaw=round(yaw, 3), deck_top=round(deck_top, 3),
                bank_a=round(bank_a, 3), bank_b=round(bank_b, 3),
                n_seg=n_seg, seg_len=round(seg_len, 3), end_len=round(end_len, 3),
                deck_width=W, clear_width=round(clear_w, 3), rail_width=RAIL_WIDTH)
    return dict(parts=parts, walk=walk, rails=rails, meta=meta)
