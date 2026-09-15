"""Parse RA2 .map INI files extracted from MIX: IsoMapPack5 (LZO), OverlayPack (LCW/Format80),
Waypoints, Preview. Produce per-map stats JSON + orthographic top-down PNG renders.
Temporary analysis tool; lives outside the repo.
"""
import base64, os, struct, json, math, sys, glob
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(__file__)
EXTRACT = os.path.join(ROOT, "extract")
OUTDIR = os.path.join(ROOT, "mapstats")
os.makedirs(OUTDIR, exist_ok=True)

# ---------------- INI -----------------

def parse_ini(text):
    sections = {}
    order = []
    cur = None
    for line in text.splitlines():
        line = line.split(";", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith("["):
            name = line.strip()[1:].split("]")[0]
            cur = sections.setdefault(name, {})
            order.append(name)
            continue
        if cur is None or "=" not in line:
            continue
        k, v = line.split("=", 1)
        cur[k.strip()] = v.strip()
    return sections, order


def pack_bytes(section):
    """Concatenate base64 lines of a *Pack section (keys are 1..N)."""
    keys = sorted(section.keys(), key=lambda k: int(k))
    return base64.b64decode("".join(section[k] for k in keys))

# ---------------- LZO1X -----------------

def lzo1x_decompress(src, dst_len):
    out = bytearray()
    ip = 0
    n = len(src)

    def copy_match(m_pos, cnt):
        for _ in range(cnt):
            out.append(out[m_pos])
            m_pos += 1

    t = src[ip]
    state = None
    if t > 17:
        ip += 1
        t -= 17
        if t < 4:
            state = "match_next"
        else:
            out += src[ip:ip + t]
            ip += t
            state = "first_literal_run"
    else:
        state = "loop"

    while True:
        if state == "loop":
            if ip >= n:
                break
            t = src[ip]; ip += 1
            if t >= 16:
                state = "match"; continue
            if t == 0:
                while src[ip] == 0:
                    t += 255; ip += 1
                t += 15 + src[ip]; ip += 1
            out += src[ip:ip + t + 3]; ip += t + 3
            state = "first_literal_run"; continue
        if state == "first_literal_run":
            t = src[ip]; ip += 1
            if t >= 16:
                state = "match"; continue
            m_pos = len(out) - (1 + 0x0800)
            m_pos -= t >> 2
            m_pos -= src[ip] << 2; ip += 1
            copy_match(m_pos, 3)
            state = "match_done"; continue
        if state == "match":
            if t >= 64:
                m_pos = len(out) - 1
                m_pos -= (t >> 2) & 7
                m_pos -= src[ip] << 3; ip += 1
                t = (t >> 5) - 1
                copy_match(m_pos, t + 2)
                state = "match_done"; continue
            elif t >= 32:
                t &= 31
                if t == 0:
                    while src[ip] == 0:
                        t += 255; ip += 1
                    t += 31 + src[ip]; ip += 1
                m_pos = len(out) - 1
                m_pos -= (src[ip] >> 2) + (src[ip + 1] << 6); ip += 2
                copy_match(m_pos, t + 2)
                state = "match_done"; continue
            elif t >= 16:
                m_pos = len(out)
                m_pos -= (t & 8) << 11
                t &= 7
                if t == 0:
                    while src[ip] == 0:
                        t += 255; ip += 1
                    t += 7 + src[ip]; ip += 1
                m_pos -= (src[ip] >> 2) + (src[ip + 1] << 6); ip += 2
                if m_pos == len(out):
                    break  # EOF marker
                m_pos -= 0x4000
                copy_match(m_pos, t + 2)
                state = "match_done"; continue
            else:
                m_pos = len(out) - 1
                m_pos -= t >> 2
                m_pos -= src[ip] << 2; ip += 1
                copy_match(m_pos, 2)
                state = "match_done"; continue
        if state == "match_done":
            t = src[ip - 2] & 3
            if t == 0:
                state = "loop"; continue
            state = "match_next"; continue
        if state == "match_next":
            out += src[ip:ip + t]; ip += t
            t = src[ip]; ip += 1
            state = "match"; continue
    return bytes(out)


def decode_isomappack5(blob):
    pos = 0
    out = bytearray()
    while pos + 4 <= len(blob):
        csize, usize = struct.unpack_from("<HH", blob, pos)
        pos += 4
        chunk = blob[pos:pos + csize]
        pos += csize
        out += lzo1x_decompress(chunk, usize)
    return bytes(out)

# ---------------- Format80 / LCW -----------------

def lcw_decompress(src):
    out = bytearray()
    ip = 0
    n = len(src)
    while ip < n:
        cmd = src[ip]; ip += 1
        if cmd & 0x80 == 0:
            cnt = (cmd >> 4) + 3
            rel = ((cmd & 0x0F) << 8) | src[ip]; ip += 1
            p = len(out) - rel
            for _ in range(cnt):
                out.append(out[p]); p += 1
        elif cmd & 0x40 == 0:
            cnt = cmd & 0x3F
            if cnt == 0:
                break
            out += src[ip:ip + cnt]; ip += cnt
        else:
            cnt = cmd & 0x3F
            if cnt < 0x3E:
                pos = struct.unpack_from("<H", src, ip)[0]; ip += 2
                for i in range(cnt + 3):
                    out.append(out[pos + i])
            elif cnt == 0x3E:
                cnt = struct.unpack_from("<H", src, ip)[0]; ip += 2
                val = src[ip]; ip += 1
                out += bytes([val]) * cnt
            else:
                cnt = struct.unpack_from("<H", src, ip)[0]; ip += 2
                pos = struct.unpack_from("<H", src, ip)[0]; ip += 2
                for i in range(cnt):
                    out.append(out[pos + i])
    return bytes(out)


def decode_lcw_chunks(blob):
    pos = 0
    out = bytearray()
    while pos + 4 <= len(blob):
        csize, usize = struct.unpack_from("<HH", blob, pos)
        pos += 4
        out += lcw_decompress(blob[pos:pos + csize])
        pos += csize
    return bytes(out)

# ---------------- Map -----------------

ORE_RANGE = range(102, 122)   # ORE01..ORE20 (recalled from rules.ini; not verifiable locally)
GEM_RANGE = range(27, 39)     # GEM01..GEM12


def parse_map(path):
    raw = open(path, "rb").read()
    text = raw.decode("latin-1")
    sec, order = parse_ini(text)
    info = {"file": os.path.basename(path)}
    basic = sec.get("Basic", {})
    info["name"] = basic.get("Name")
    info["min_player"] = basic.get("MinPlayer")
    info["max_player"] = basic.get("MaxPlayer")
    info["official"] = basic.get("Official")
    mp = sec.get("Map", {})
    info["theater"] = mp.get("Theater")
    size = [int(v) for v in mp.get("Size", "0,0,0,0").split(",")]
    lsize = [int(v) for v in mp.get("LocalSize", "0,0,0,0").split(",")]
    info["size"] = size
    info["local_size"] = lsize
    W, H = size[2], size[3]
    # waypoints
    wps = {}
    for k, v in sec.get("Waypoints", {}).items():
        try:
            num = int(v)
            wps[int(k)] = (num % 1000, num // 1000)  # (X, Y)
        except ValueError:
            pass
    starts = [wps[i] for i in range(8) if i in wps]
    hdr = sec.get("Header", {})
    if hdr.get("NumberStartingPoints"):
        nsp = int(hdr["NumberStartingPoints"])
        starts = starts[:nsp] if starts else starts
        info["header_num_start"] = nsp
    info["starts"] = starts
    # cells
    cells = None
    levels = None
    if "IsoMapPack5" in sec:
        data = decode_isomappack5(pack_bytes(sec["IsoMapPack5"]))
        ncell = len(data) // 11
        arr = np.frombuffer(data[:ncell * 11], dtype=np.uint8).reshape(ncell, 11)
        X = arr[:, 0:2].copy().view("<u2").ravel()
        Y = arr[:, 2:4].copy().view("<u2").ravel()
        tile = arr[:, 4:8].copy().view("<i4").ravel()
        sub = arr[:, 8]
        lvl = arr[:, 9]
        keep = (X > 0) | (Y > 0)
        cells = dict(X=X[keep], Y=Y[keep], tile=tile[keep], sub=sub[keep], level=lvl[keep])
        info["num_cells"] = int(keep.sum())
        info["level_hist"] = {int(k): int(v) for k, v in zip(*np.unique(lvl[keep], return_counts=True))}
        info["iso_extent"] = dict(xmin=int(X[keep].min()), xmax=int(X[keep].max()), ymin=int(Y[keep].min()),
                                  ymax=int(Y[keep].max()))
        # level lookup grid
        gs = W + H + 2
        grid_lvl = np.full((gs, gs), -1, dtype=np.int16)
        grid_lvl[cells["Y"], cells["X"]] = cells["level"]
        levels = grid_lvl
    # overlays
    ore_cells = []
    gem_cells = []
    if "OverlayPack" in sec:
        ov = decode_lcw_chunks(pack_bytes(sec["OverlayPack"]))
        ovd = decode_lcw_chunks(pack_bytes(sec["OverlayDataPack"])) if "OverlayDataPack" in sec else None
        info["overlay_bytes"] = len(ov)
        ov = np.frombuffer(ov, dtype=np.uint8)
        idx = np.nonzero(ov != 0xFF)[0]
        info["overlay_cells"] = int(len(idx))
        xs = idx % 512
        ys = idx // 512
        vals = ov[idx]
        ore_mask = (vals >= 102) & (vals <= 121)
        gem_mask = (vals >= 27) & (vals <= 38)
        ore_cells = list(zip(xs[ore_mask].tolist(), ys[ore_mask].tolist()))
        gem_cells = list(zip(xs[gem_mask].tolist(), ys[gem_mask].tolist()))
        info["ore_cells"] = len(ore_cells)
        info["gem_cells"] = len(gem_cells)
        ov_hist = {int(k): int(v) for k, v in zip(*np.unique(vals, return_counts=True))}
        info["overlay_hist_top"] = dict(sorted(ov_hist.items(), key=lambda kv: -kv[1])[:12])
    # objects
    for s in ("Structures", "Units", "Infantry", "Aircraft", "Terrain", "Smudge"):
        info[f"n_{s.lower()}"] = len(sec.get(s, {}))
    structs = sec.get("Structures", {})
    tech = {}
    for v in structs.values():
        parts = v.split(",")
        if len(parts) > 1 and parts[0].strip().lower() == "neutral":
            tech[parts[1]] = tech.get(parts[1], 0) + 1
    info["neutral_structures"] = tech
    # preview
    prev = sec.get("Preview", {})
    info["preview_size"] = prev.get("Size")
    preview_img = None
    if "PreviewPack" in sec and prev.get("Size"):
        ps = [int(v) for v in prev["Size"].split(",")]
        pw, ph = ps[2], ps[3]
        pdata = decode_isomappack5(pack_bytes(sec["PreviewPack"]))  # RA2 PreviewPack is LZO chunks (verified: LCW fails, LZO literal-run header fits)
        need = pw * ph * 3
        if len(pdata) >= need:
            arr = np.frombuffer(pdata[:need], dtype=np.uint8).reshape(ph, pw, 3)
            preview_img = Image.fromarray(arr[:, :, ::-1].copy(), "RGB")  # BGR->RGB
        info["preview_bytes"] = len(pdata)
    # distances
    if len(starts) >= 2:
        d = []
        for i in range(len(starts)):
            for j in range(i + 1, len(starts)):
                dx = starts[i][0] - starts[j][0]
                dy = starts[i][1] - starts[j][1]
                d.append(math.hypot(dx, dy))
        info["start_pair_min"] = round(min(d), 1)
        info["start_pair_max"] = round(max(d), 1)
        info["start_pair_mean"] = round(sum(d) / len(d), 1)
        # map diagonal in iso cells: the playable diamond spans roughly W+H on each iso axis
        diag = math.hypot(lsize[2] * 1.0, lsize[3] * 2.0)  # local size in (x, y/2) screen cells -> iso approx
        info["start_pair_min_over_local_diag"] = round(min(d) / diag, 3) if diag else None
    if starts and levels is not None:
        info["start_levels"] = [int(levels[y, x]) for (x, y) in starts if 0 <= y < levels.shape[0] and 0 <= x < levels.shape[1]]
    if starts and ore_cells:
        # nearest ore distance per start and ore within radius counts
        oc = np.array(ore_cells, dtype=float)
        per = []
        for (sx, sy) in starts:
            dd = np.hypot(oc[:, 0] - sx, oc[:, 1] - sy)
            per.append(dict(nearest=round(float(dd.min()), 1), within_10=int((dd <= 10).sum()),
                            within_15=int((dd <= 15).sum()), within_25=int((dd <= 25).sum())))
        info["ore_per_start"] = per
        # ore not owned (far from every start)
        allmin = np.full(len(oc), 1e9)
        for (sx, sy) in starts:
            allmin = np.minimum(allmin, np.hypot(oc[:, 0] - sx, oc[:, 1] - sy))
        info["ore_far_from_all_starts_gt25"] = int((allmin > 25).sum())
    return info, cells, ore_cells, gem_cells, starts, preview_img, sec


def render_ortho(info, cells, ore_cells, gem_cells, starts, size_px=1024):
    """True top-down orthographic render of the iso grid rotated 45deg into screen space.
    Screen: sx = X - Y, sy = (X + Y) / 2  (standard RA2 iso -> 2D map projection, no perspective).
    """
    if cells is None:
        return None
    X = cells["X"].astype(float); Y = cells["Y"].astype(float); L = cells["level"].astype(float)
    sx = X - Y; sy = (X + Y) / 2.0
    xmin, xmax, ymin, ymax = sx.min(), sx.max(), sy.min(), sy.max()
    w_units, h_units = xmax - xmin + 1, ymax - ymin + 1
    scale = size_px / max(w_units, h_units)
    W = int(math.ceil(w_units * scale)); H = int(math.ceil(h_units * scale))
    img = Image.new("RGB", (W, H), (12, 12, 16))
    px = np.zeros((H, W, 3), dtype=np.uint8) + np.array([12, 12, 16], dtype=np.uint8)
    lmax = max(1.0, L.max())
    # height ramp colour: low = dark sand, high = light
    for x, y, l in zip(sx, sy, L):
        px_x = int((x - xmin) * scale); px_y = int((y - ymin) * scale)
        t = l / lmax
        col = (int(70 + 150 * t), int(60 + 130 * t), int(45 + 100 * t))
        s = max(1, int(scale))
        px[px_y:px_y + s, px_x:px_x + max(1, int(scale * 2)), :] = col
    img = Image.fromarray(px)
    dr = ImageDraw.Draw(img)

    def to_px(cx, cy):
        return ((cx - cy - xmin) * scale, ((cx + cy) / 2.0 - ymin) * scale)

    for (ox, oy) in ore_cells:
        p = to_px(ox, oy)
        dr.rectangle([p[0], p[1], p[0] + scale * 2, p[1] + scale], fill=(230, 190, 40))
    for (gx, gy) in gem_cells:
        p = to_px(gx, gy)
        dr.rectangle([p[0], p[1], p[0] + scale * 2, p[1] + scale], fill=(90, 200, 230))
    for i, (sx0, sy0) in enumerate(starts):
        p = to_px(sx0, sy0)
        r = max(6, scale * 4)
        dr.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], outline=(255, 60, 60), width=3)
        dr.text((p[0] + r + 2, p[1] - r), f"P{i}", fill=(255, 255, 255))
    # pairwise min-distance line
    if len(starts) >= 2:
        best = None
        for i in range(len(starts)):
            for j in range(i + 1, len(starts)):
                d = math.hypot(starts[i][0] - starts[j][0], starts[i][1] - starts[j][1])
                if best is None or d < best[0]:
                    best = (d, i, j)
        a = to_px(*starts[best[1]]); b = to_px(*starts[best[2]])
        dr.line([a, b], fill=(255, 120, 120), width=2)
        dr.text(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2), f"min {best[0]:.1f} cells", fill=(255, 200, 200))
    title = f"{info['file']}  {info.get('name')}  {info.get('theater')}  size={info['size']}  starts={len(starts)}  ore={len(ore_cells)} gem={len(gem_cells)}"
    dr.rectangle([0, 0, W, 14], fill=(0, 0, 0))
    dr.text((4, 2), title[:160], fill=(255, 255, 255))
    return img


def main(limit=None, render_all=False):
    files = sorted(glob.glob(os.path.join(EXTRACT, "MULTI", "*")))
    files += sorted(glob.glob(os.path.join(EXTRACT, "Maps01", "*.map-ini")))
    files += sorted(glob.glob(os.path.join(EXTRACT, "Maps02", "*.map-ini")))
    if limit:
        files = files[:limit]
    stats = []
    for i, f in enumerate(files):
        try:
            info, cells, ore, gem, starts, preview, sec = parse_map(f)
        except Exception as ex:
            print("ERR", f, repr(ex))
            stats.append({"file": os.path.basename(f), "error": repr(ex)})
            continue
        stats.append(info)
        base = os.path.splitext(os.path.basename(f))[0]
        print(f"[{i}] {base:18s} {str(info.get('name')):28s} th={info.get('theater')} size={info['size']} starts={len(starts)} minD={info.get('start_pair_min')} ore={info.get('ore_cells')} gem={info.get('gem_cells')} lv={sorted(info.get('level_hist', {}).keys())[-1] if info.get('level_hist') else None} neutral={sum(info.get('neutral_structures', {}).values())}")
        if preview is not None:
            preview.save(os.path.join(OUTDIR, f"{base}_preview.png"))
        if render_all or i < 12:
            img = render_ortho(info, cells, ore, gem, starts)
            if img:
                img.save(os.path.join(OUTDIR, f"{base}_ortho.png"))
    with open(os.path.join(OUTDIR, "stats.json"), "w", encoding="utf-8") as fo:
        json.dump(stats, fo, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    lim = int(sys.argv[1]) if len(sys.argv) > 1 else None
    main(lim, render_all="--all" in sys.argv)
