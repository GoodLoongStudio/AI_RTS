"""G4 真实地形几何：从 G2/G3 权威通道构造连续高程场、网格与表面查询。

数据同源约定（主计划阶段C）：
- 逻辑 1m 格网 height 通道只有四个分类值：地面 0.6 / 水 -2.4 / 台地顶 3.6 / 坡口 2.1。
- 显示高程场 hf（1m 间距，与逻辑格网对齐）在此基础上生成：
  * 台地顶面、地面主体保持精确分类值（平顶台地不是噪声山地）；
  * 崖壁外侧生成连续坡脚（talus），从崖顶 3.6 平滑降到地面，不产生可爬崖壁；
  * 坡口沿其方向/范围生成连续坡面（地面 0.6 → 台地顶 3.6），不是一格台阶；
  * 水岸生成连续岸坡（地面 0.6 → 水床 -2.4），水床在水面下连续，桥下不断水；
  * 桥面格保持 0.6 平台，与两岸无缝衔接。
- 视觉网格、碰撞（Terrain trimesh）、导航（烘焙自碰撞）与高度查询共用同一 hf。

hf 与 Godot 的约定：顶点 (i,j) 位于世界坐标 (x=i, z=j)，i∈[0,GRID_W]、j∈[0,GRID_H]，
即 257×257 顶点覆盖 [0,256]×[0,256]；格 (i,j) 的高度作用于其四角顶点（双线性等价）。
"""
import numpy as np

from ..contract import GRID_H, GRID_W
from ..pathing import cell_of, dilate8


def _dist_bands(mask, n):
    """mask 外第 1..n 圈膨胀带（切比雪夫距离），返回 [band1..bandn]。"""
    bands = []
    cur = mask.copy()
    for _ in range(n):
        nxt = dilate8(cur)
        bands.append(nxt & ~cur)
        cur = nxt
    return bands


def classify(grid, params, plateaus=()):
    """从权威通道 + mapspec 台地轮廓派生 G4 需要的语义掩码。

    台地区域以 G2 mapspec 的 outline 为准（= region = interior+ring）；
    height 通道只能区分顶面/坡口，无法标识 blocking 的悬崖环。"""
    from .g2_landforms import polygon_mask
    height = grid.get("height")
    blocking = grid.get("blocking")
    water_fp = grid.get("water_footprint").astype(bool)
    open_ = blocking == 0
    water = water_fp
    bridge = water & open_                       # 桥面/可走水面格（height=0.6）
    region = np.zeros((GRID_H, GRID_W), dtype=bool)
    for pl in plateaus:
        region |= polygon_mask(np.asarray(pl["outline"], dtype=float))
    if not region.any():                         # 兼容：无轮廓时用 height 通道回退
        region = open_ & (height >= params["plateau_level"] - 1e-3)
        region |= open_ & (np.abs(height - (params["ground_level"] + params["plateau_level"]) / 2.0) < 1e-3)
    ramp = open_ & (np.abs(height - (params["ground_level"] + params["plateau_level"]) / 2.0) < 1e-3)
    plateau_top = region & open_ & ~ramp         # 可走顶面（blocking 的内部岩体不算）
    return dict(water=water, bridge=bridge, plateau_top=plateau_top, ramp=ramp,
                plateau_region=region, open_=open_)


def build_heightfield(grid, params, plateaus, bridges):
    """构造连续显示高程场 hf（(GRID_H+1, GRID_W+1) float32，顶点=世界整数坐标）。

    返回 (hf, meta)；meta 记录各过渡带掩码供校验与可视化。
    """
    m = classify(grid, params, plateaus)
    ground = float(params["ground_level"])
    water_level = float(params["water_level"])
    top = float(params["plateau_level"])

    h = np.full((GRID_H, GRID_W), ground, dtype=np.float64)
    h[m["water"]] = water_level
    h[m["plateau_top"]] = top
    h[m["ramp"]] = top                           # 坡口格先置顶高，步骤 2 重写为连续坡
    h[m["bridge"]] = ground
    # 悬崖环（region 内 blocking）保持顶高：崖壁从环上垂直下切，环顶与顶面齐平
    h[(m["plateau_region"] & ~m["open_"]) & ~m["water"]] = top

    region = m["plateau_region"]
    ramp = m["ramp"]

    # 逐步追踪（诊断用）：`G4_TERRAIN_TRACE="i,j"`（语义格坐标）时打印该点在
    # 每个步骤后的高度 —— 用来定位"某处高度被哪一步改掉了"，比读代码猜可靠。
    import os as _os
    _tr = _os.environ.get("G4_TERRAIN_TRACE")

    def _tp(tag):
        if not _tr:
            return
        try:
            ti, tj = (int(v) for v in _tr.split(","))
        except ValueError:
            return
        print(f"  [terrain-trace] {tag:24s} h({tj},{ti}) = {h[ti, tj]:7.3f}")

    _tp("init")

    # ---- 1. 崖脚连续坡（talus）：region 外 n 圈从崖顶平滑降到地面 ----
    apron_n = int(params.get("apron_cells", 4))
    apron = np.zeros((GRID_H, GRID_W), dtype=bool)
    bands = _dist_bands(region, apron_n)
    for k, band in enumerate(bands):
        band = band & ~region                    # 只处理台地外圈
        t = (k + 1) / (apron_n + 1.0)
        s = t * t * (3.0 - 2.0 * t)              # smoothstep：上端贴崖、下端贴地
        h[band] = np.minimum(h[band], top - (top - ground) * s)
        apron |= band
    _tp("after_apron")
    # 崖缘倒角：悬崖环（region 内 blocking 格）外侧逐步下降
    # 2026-09-14（用户指出"这里有凹陷"）：原来是 top-0.5 / top-1.2，等于在每座台地
    # 边缘内侧压出一圈 2~5 世界米深的台阶，低角度看就是 Rim 内的一条凹槽；
    # 叠加"矩形坡道带"的切槽后更明显。现压到 0.15/0.35（0.6/1.4 世界米）——
    # 仍能削掉顶面直角，但不再读作凹。
    interior = m["plateau_top"]
    ring = region & ~interior
    d1 = ring & dilate8(interior)
    d2 = ring & ~d1
    h[d1] = top - 0.15
    h[d2] = top - 0.35
    _tp("after_chamfer")

    # ---- 2. 坡口连续坡面：沿坡口方向把穿越崖壁的通道压回平滑斜坡 ----
    ramp_blend = np.zeros((GRID_H, GRID_W), dtype=bool)
    ramp_top = top                               # 与顶面无缝（平顶保持精确 3.6）
    region_d1 = dilate8(region)
    blocking = grid.get("blocking") > 0
    for pl in plateaus:
        center_xy = np.array(pl["center"], dtype=float)
        for rc, rdir in zip(pl["ramp_centers"], pl["ramp_dirs"]):
            # 实测约定：ramp_dirs 指向台地内部（dot(rc-center, dir) < 0）；
            # 用点积稳健判向，防止约定变化时坡面反向。
            inward = np.array(rdir, dtype=float)
            if float(np.dot(np.array(rc, dtype=float) - center_xy, inward)) > 0:
                inward = -inward
            ramp_mask = _ramp_band_mask(pl, rc, inward, params)
            if not ramp_mask.any():
                continue
            # 坡脚锚在 band 内最外侧台地格，坡长固定向内切 ramp_run_m。
            # 禁止再把坡面铺到沙地上（g132 顶窄脚宽扇形 = 崖壁乳头锥）。
            # 沙地最多外扩 1 格对接崖脚；台顶用 U 形湾切开，不要矩形带方槽。
            rim_band = region & ramp_mask
            ii, jj = np.nonzero(rim_band)
            if len(ii) == 0:
                continue
            ax_r = ((jj + 0.5 - rc[0]) * inward[0]
                    + (ii + 0.5 - rc[1]) * inward[1])
            t_out = float(ax_r.min()) - 0.5
            run = float(params.get("ramp_run_m", 15.0))
            t_in = t_out + run
            apply_mask = (region | dilate8(region)) & ramp_mask & ~m["water"]
            ri, rj = np.nonzero(apply_mask)
            ax = (rj + 0.5 - rc[0]) * inward[0] + (ri + 0.5 - rc[1]) * inward[1]
            keep = (ax <= t_in) & (ax >= t_out)
            ri, rj, ax = ri[keep], rj[keep], ax[keep]
            if len(ri) == 0:
                continue
            frac = np.clip((ax - t_out) / max(t_in - t_out, 1e-6), 0.0, 1.0)
            h_ramp = ground + (ramp_top - ground) * frac
            # U 形湾：外口宽、内端略收，两侧羽化回崖壁。不是尖扇也不是方槽。
            lateral = np.array([-inward[1], inward[0]])
            lat_off = np.abs((rj + 0.5 - rc[0]) * lateral[0]
                             + (ri + 0.5 - rc[1]) * lateral[1])
            half_mouth = float(params.get("plateau_ramp_width", 8.0)) / 2.0 + 3.5
            half_back = max(half_mouth * 0.62, 3.5)
            half_w = half_mouth + (half_back - half_mouth) * frac
            feather = 3.5
            w_lat = np.clip((half_w - lat_off) / feather, 0.0, 1.0)
            w_lat = w_lat * w_lat * (3.0 - 2.0 * w_lat)
            h[ri, rj] = h[ri, rj] + (h_ramp - h[ri, rj]) * w_lat
            ramp_blend[ri, rj] = w_lat > 0.05
    # 坡口带内的崖脚/岸坡修正不得残留：坡面即最终高度（已在赋值中覆盖）

    _tp("after_ramp")
    # ---- 3. 连续岸坡：水边陆地格下切到水面以下，形成自然岸线 ----
    shore_n = int(params.get("shore_cells", 3))
    water_no_bridge = m["water"] & ~m["bridge"]
    shore = np.zeros((GRID_H, GRID_W), dtype=bool)
    land = ~m["water"]
    bands = _dist_bands(water_no_bridge, shore_n)
    for k, band in enumerate(bands):
        band = band & land & ~ramp_blend
        # 从水床到岸顶的【线性】斜线（近水低、远水高）。
        # 旧式 (1-t)^2 让落差全挤在一格 -> 水边垂直断崖 + 上采样后成"平台+陡壁"
        # 的重复条带（近看锯齿/木纹，实测剖面 -2.4 直接跳到 0.77）。
        t = (k + 1) / (shore_n + 1.0)
        bank = water_level + (ground - water_level) * t
        h[band] = np.minimum(h[band], bank)
        shore |= band

    # ---- 4. 桥面平台：桥格及外扩 1 格保持地面高度（与两岸无缝） ----
    bridge_bank = dilate8(m["bridge"]) & ~water_no_bridge
    h[m["bridge"]] = ground
    h[bridge_bank] = np.maximum(h[bridge_bank], ground)
    _tp("after_bridge")

    # ---- 5. 顶点化：格高度 → 角点顶点（4 邻格均值） ----
    pad = np.pad(h, 1, mode="edge")
    hf = (pad[:-1, :-1] + pad[:-1, 1:] + pad[1:, :-1] + pad[1:, 1:]) / 4.0
    # 精确锚点：平坦内部格（3×3 同分类）的四角顶点钉回分类值，
    # 保证台地顶面/地面/水床的平坦区精确保持 3.6 / 0.6 / -2.4。
    interior_flat = _interior_flat_mask(h, m)
    anchor = np.pad(h, 1, mode="edge")          # (H+2, W+2)
    corners = np.zeros(hf.shape, dtype=bool)    # (H+1, W+1)
    corners[1:, 1:] |= interior_flat            # 顶点(i,j) 是格(i,j)的左上角
    corners[:-1, 1:] |= interior_flat           # 格(i, j-1) 的右上角
    corners[1:, :-1] |= interior_flat           # 格(i-1, j) 的左下角
    corners[:-1, :-1] |= interior_flat          # 格(i-1, j-1) 的右下角
    hf[corners] = anchor[1:, 1:][corners]

    # ---- 6. 山体：G2 rock 掩码 -> 权威山体增量（游戏内不可通行自然阻挡）----
    # 单一事实源：rtsmap.g4_terrain_mountains.mountain_addon（review 渲染与
    # 游戏内高度同源）。山与台地/水/坡道在 G2 语义互斥，此处仍做保护屏蔽：
    # 水面/桥面/坡道带/岸坡带上的山体增量清零，避免盖掉通行动线。
    from .g4_terrain_mountains import mountain_addon, vertex_rock_fields
    rock_v, rd_v, ro_v = vertex_rock_fields(
        grid.get("blocking") > 0, region, water_no_bridge)
    lane_core_v = np.pad(grid.get("lane_core") > 0, ((0, 1), (0, 1)), mode='edge')
    vi = np.arange(hf.shape[0], dtype=np.float64)
    vx, vz = np.meshgrid(vi, vi)
    addon = mountain_addon(vx.ravel(), vz.ravel(), rd_v.ravel(), ro_v.ravel(),
                           lane_core=lane_core_v.ravel())
    addon = addon.reshape(hf.shape)
    # 屏蔽带：**羽化**而不是二值清零（2026-09-14 修用户实测指出的凹陷）
    # 原来 `addon[shield_v] = 0` 把坡道带/岸带完全排除在山体加成之外，而紧邻的岩体
    # 照加 → 坡道两侧形成垂直沟槽。实测：19 条坡道**全部**有 19~28 世界米深的沟槽壁
    # （tools/probe_ramp_trench.py，5.6~7.1 语义米）。
    # 改为「到带距离 → 权重」：带内及紧邻 1 格权重 1（保住可走），向外 2 格线性衰减到 0，
    # 山体在坡道/岸带附近平滑收平，既不留硬边也不把带子顶起来。
    from scipy import ndimage as _ndi_shield
    shield_raw = water_no_bridge | m["bridge"] | ramp_blend | shore
    _d_shield = _ndi_shield.distance_transform_edt(~shield_raw)
    w512 = np.clip(1.0 - (_d_shield - 1.0) / 2.0, 0.0, 1.0)
    pr_s = np.pad(w512, 1, mode='edge')
    # 顶点口径取 4 邻角最大值（保守：只要相邻格被屏蔽就衰减）
    shield_v = np.maximum(np.maximum(pr_s[:-1, :-1], pr_s[:-1, 1:]),
                          np.maximum(pr_s[1:, :-1], pr_s[1:, 1:]))
    addon *= (1.0 - shield_v)
    hf += addon
    _tp("after_addon")
    mountain_max = float(addon.max())

    hf32 = np.ascontiguousarray(hf.astype(np.float32))
    meta = dict(apron=apron, shore=shore, ramp_blend=ramp_blend,
                bridge=m["bridge"], water=water_no_bridge,
                blocking=grid.get("blocking") > 0, plateau_region=region,
                mountain_addon_max_m=mountain_max)
    trans = apron | shore | ramp_blend | dilate8(m["bridge"]) | (region & ~m["open_"])
    near = dilate8(dilate8(trans))
    ii, jj = np.nonzero(m["plateau_top"] & ~near)
    if len(ii):
        hf32[ii, jj] = top
        hf32[ii + 1, jj] = top
        hf32[ii, jj + 1] = top
        hf32[ii + 1, jj + 1] = top
    meta["top_anchored_cells"] = int(len(ii))
    _tp("after_flatten")

    # ---- 距离场（语义米，512 格域）：供共享 shader 的着色掩码 ----
    # 与 review 渲染器传给 showcase_land 的 UV/UV2 同口径：
    # plateau_d/shore_d/lake_d = 到台地/水域/湖的 EDT 距离；
    # cls = +rock 强度（0..1，EDT 驱动）/ -ramp 强度 / 0 其他。
    from scipy import ndimage as _ndi
    sem_cell = 2000.0 / (m["plateau_region"].shape[0])
    water_m = m["water"]
    plateau_m = m["plateau_region"] & ~m["open_"]
    ramp_m2 = m.get("ramp_blend")
    if ramp_m2 is None:
        ramp_m2 = np.zeros_like(water_m)
    lake_m = m.get("lake")
    if lake_m is None:
        lake_m = np.zeros_like(water_m)
    # plateau/lake 为【带符号】距离（shader 口径：内部为负，外部为正）
    p_out = _ndi.distance_transform_edt(~plateau_m) * sem_cell
    p_in = _ndi.distance_transform_edt(plateau_m) * sem_cell
    meta["dist_plateau_d"] = np.where(plateau_m, -p_in, p_out)
    # water 也走【带符号】：内部为负（到岸距离），外部为正。
    # 陆地上的用法不受影响 —— water 内部原本就是 0（EDT(~water) 在水内=0），
    # smoothstep(0, bank_w, ·) / step(8, ·) 在 0 与负值上取同一结果；
    # 而水面 shader（showcase_water 的 mask_from_tex 通路）需要它取 -g 才能
    # 得到"到岸距离/浅滩"，否则水内全是 0 → ALPHA=0 → 水面整体透明（静默失败）。
    s_out = _ndi.distance_transform_edt(~water_m) * sem_cell
    s_in = _ndi.distance_transform_edt(water_m) * sem_cell
    meta["dist_shore_d"] = np.where(water_m, -s_in, s_out)
    l_out = _ndi.distance_transform_edt(~lake_m) * sem_cell
    l_in = _ndi.distance_transform_edt(lake_m) * sem_cell
    meta["dist_lake_d"] = np.where(lake_m, -l_in, l_out)
    # rock 掩码（语义格）—— blocking 在 grid 上（m 是语义 mask dict）
    rock_m = (grid.get("blocking") > 0) & ~water_m
    rock_d = _ndi.distance_transform_edt(rock_m.astype(bool)).astype(np.float64)
    rock_core = np.clip((rock_d.max() - rock_d) / 30.0, 0.0, 1.0) * rock_m.astype(np.float64)
    cls_f = np.where(rock_m.astype(bool), rock_core, np.where(ramp_m2 > 0, -1.0, 0.0))
    meta["dist_cls"] = cls_f
    return hf32, meta


def _interior_flat_mask(h, m):
    """格与其 8 邻同一分类（全地面 / 全台地顶 / 全水）→ 平坦内部格。"""
    def all8(cls):
        p = np.pad(cls.astype(np.uint8), 1, mode="constant")
        acc = np.zeros_like(cls, dtype=np.uint16)
        for di in (0, 1, 2):
            for dj in (0, 1, 2):
                acc += p[di:di + cls.shape[0], dj:dj + cls.shape[1]]
        return acc == 9
    flat_ground = all8((h > 0.55) & (h < 0.65) & ~m["water"])
    flat_top = all8(h > 3.55)
    flat_water = all8(m["water"] & ~m["bridge"])
    return flat_ground | flat_top | flat_water


def _ramp_band_mask(pl, rc, inward, params):
    """单条坡口的作用带：以 rc（崖缘点）为原点、inward（指向台地内部）为轴。

    轴向符号：inward 指向台地内部，故 ax>0 为崖内（顶面侧）、ax<0 为崖外（地面侧）。
    坡面从 t_out（崖外地面端）连续升到 t_in（崖内顶面端），t_out = t_in - ramp_run_m，
    t_in ∈ [0, ~ramp_run_m]，故作用带必须覆盖 ax ∈ [-ramp_run_m, +ramp_run_m] 才能
    含整条崖外展开段；旧下界 -2.0 把崖外缓坡截断，只剩顶部 1m 被平滑，崖外仍是
    陡崖脚 talus（≈37°），导致导航高度板在坡底出现 0.5~1.0m 台阶而无法连通。
    横向 ≤ 坡口宽/2 + 2（含 G2 地面侧喇叭口）。
    """
    width = float(params.get("plateau_ramp_width", 8.0))
    lateral = np.array([-inward[1], inward[0]])
    ii, jj = np.mgrid[0:GRID_H, 0:GRID_W]
    dx = (jj + 0.5) - rc[0]
    dz = (ii + 0.5) - rc[1]
    ax = dx * inward[0] + dz * inward[1]
    lat = np.abs(dx * lateral[0] + dz * lateral[1])
    run = float(params.get("ramp_run_m", 15.0))
    # 覆盖「外缘向内 run」的 U 形湾，外口略宽。
    u = np.clip(ax / max(run, 1e-6), 0.0, 1.0)
    half = (width / 2.0 + 5.0) * (1.0 - 0.30 * u)
    band = (ax >= -2.0) & (ax <= run + 1.0) & (lat <= half)
    return band


def sample_height(hf, x, z):
    """世界坐标处的表面高度（双线性；hf 顶点位于整数坐标）。"""
    xi = float(np.clip(x, 0.0, GRID_W - 1.001))
    zj = float(np.clip(z, 0.0, GRID_H - 1.001))
    i0, j0 = int(np.floor(xi)), int(np.floor(zj))
    fx, fz = xi - i0, zj - j0
    v00 = float(hf[j0, i0]); v10 = float(hf[j0, i0 + 1])
    v01 = float(hf[j0 + 1, i0]); v11 = float(hf[j0 + 1, i0 + 1])
    return (v00 * (1 - fx) * (1 - fz) + v10 * fx * (1 - fz)
            + v01 * (1 - fx) * fz + v11 * fx * fz)


def mesh_arrays(hf):
    """顶点/法线/索引（Godot ArrayMesh 约定；由 GeneratedTerrain.gd 在运行时组装）。"""
    vh, vw = hf.shape
    verts = np.zeros((vh, vw, 3), dtype=np.float32)
    verts[:, :, 0] = np.arange(vw, dtype=np.float32)[None, :]
    verts[:, :, 1] = hf
    verts[:, :, 2] = np.arange(vh, dtype=np.float32)[:, None]
    # 解析法线：n = (-dh/dx, 1, -dh/dz)（中心差分，边界前向/后向）
    dx = np.gradient(hf.astype(np.float64), axis=1)
    dz = np.gradient(hf.astype(np.float64), axis=0)
    normals = np.stack([-dx, np.ones_like(dx), -dz], axis=-1)
    normals /= np.linalg.norm(normals, axis=-1, keepdims=True)
    # 注：索引绕序已在 mesh_arrays 中按 Godot 前向面（顶视可见）校正。
    idx = np.zeros(((vh - 1) * (vw - 1) * 6,), dtype=np.int32)
    r = np.arange(vh - 1)[:, None]
    c = np.arange(vw - 1)[None, :]
    v00 = (r * vw + c).ravel()
    v10 = v00 + 1
    v01 = v00 + vw
    v11 = v01 + 1
    k = 0
    idx[k::6] = v00; idx[k + 1::6] = v01; idx[k + 2::6] = v10
    idx[k + 3::6] = v10; idx[k + 4::6] = v01; idx[k + 5::6] = v11
    return verts.reshape(-1, 3), normals.astype(np.float32).reshape(-1, 3), idx


def write_height_data(path, hf, upsample: int = 2):
    """G4 高程二进制：int32 w, int32 h, float32[h*w]（行主序，little-endian）。

    upsample=2：513 -> 1025 顶点（2m 顶点距）。4m 网格会把河岸/崖壁曲线
    量化成折线（近看锯齿），双线性上采样让运行时网格与 review(1025) 同分辨率。
    """
    if upsample and upsample > 1:
        from scipy import ndimage as _ndi
        target = (hf.shape[0] - 1) * upsample + 1
        hf = _ndi.zoom(hf, (target - 1) / (hf.shape[0] - 1), order=1)
        hf = hf[:target, :target]
    vh, vw = hf.shape
    header = np.array([vw, vh], dtype=np.int32)
    with open(path, "wb") as f:
        f.write(header.tobytes())
        f.write(np.ascontiguousarray(hf, dtype=np.float32).tobytes())


def heightfield_report(hf, meta, params):
    """自检：平顶精度、可走区坡面连续性、崖壁陡坎定位。

    口径：与崖壁结构（blocking 格或台地 region 格）相邻的顶点边允许陡坎
    （不可爬，导航由碰撞盒/坡度排除）；其余可走边的步高必须 ≤ 1.0m（45°，
    导航 cell 0.3m 内插后每步 ≈0.3m，在 agent_max_climb=0.5 与 walkable slope 内）。"""
    ground = float(params["ground_level"]); top = float(params["plateau_level"])
    hf64 = hf.astype(np.float64)
    step_z = np.abs(np.diff(hf64, axis=0))   # (H, W+1)
    step_x = np.abs(np.diff(hf64, axis=1))   # (H+1, W)
    cliff = _cliff_edge_mask(meta)
    free_z = step_z[~cliff["z"]]
    free_x = step_x[~cliff["x"]]
    max_free = float(max(free_z.max(initial=0.0), free_x.max(initial=0.0)))
    return dict(
        vertex_shape=list(hf.shape),
        min_height=round(float(hf.min()), 3),
        max_height=round(float(hf.max()), 3),
        max_step_all_m=round(float(max(step_z.max(), step_x.max())), 3),
        max_step_walkable_m=round(max_free, 3),
        walkable_slope_step_ok=bool(max_free <= 1.0 + 1e-6),
        plateau_level=top, ground_level=ground, water_level=float(params["water_level"]),
    )


def _cliff_edge_mask(meta):
    """崖壁边：顶点 2×2 邻域内存在结构格（blocking/region/崖脚/岸坡/桥）时，
    该顶点参与的陡坎合法（崖壁不可爬，导航由碰撞盒/坡度排除）。顶点高度受
    4 邻格均值影响，故排除口径用顶点 2×2 格邻域而非仅边的两侧格。"""
    blocking = meta.get("blocking")
    if blocking is None:
        blocking = np.zeros((GRID_H, GRID_W), dtype=bool)
    struct = blocking.copy()
    for key in ("plateau_region", "apron", "bridge"):
        m = meta.get(key)
        if m is not None:
            struct |= m
    # 注：岸坡/坡面带不计入“崖壁排除”：它们必须可走，步高由 ≤1.0m 阈值把关。
    pad = np.pad(struct, 1, mode="constant", constant_values=False)
    # vertex_near[j, i] = 顶点 (j,i) 的 2×2 格邻域（(j-1..j, i-1..i)）任一结构格
    vertex_near = np.zeros((GRID_H + 1, GRID_W + 1), dtype=bool)
    for dj in (0, 1):
        for di in (0, 1):
            vertex_near |= pad[dj:dj + GRID_H + 1, di:di + GRID_W + 1]
    cz = vertex_near[:-1, :] | vertex_near[1:, :]     # step_z (H, W+1)
    cx = vertex_near[:, :-1] | vertex_near[:, 1:]     # step_x (H+1, W)
    return dict(z=cz, x=cx)
