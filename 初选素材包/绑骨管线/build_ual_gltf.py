# -*- coding: utf-8 -*-
# 从 Godot dump 的 JSON (骨架 rest + UAL 动作轨道) 自建带蒙皮的 glTF/GLB。
# 背景: Godot GLTFDocument 导出 skins=0 (不带动画也一样), Blender 只能收到
# 裸节点层级 -> 空物体, 其旋转约定与 Blender 骨骼不同, 直接拷会肢体乱折。
# 自建 glTF 带上 skin 后, Blender 按标准流程转成臂空间骨架 (与 Soldier.glb 同路径)。
import json, struct

DUMP = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\mocap\ual_extract\ual_dump.json"
OUT = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\mocap\ual_extract\UAL_Mannequin_skinned.glb"

data = json.load(open(DUMP, encoding="utf-8"))
bones = data["bones"]
anims = data["anims"]
N = len(bones)
bone_index = {b["name"]: i for i, b in enumerate(bones)}
print("bones", N, "anims", len(anims))

# ---- glTF 矩阵工具 (列主序) ----
def mat_from_trs(px, py, pz, qx, qy, qz, qw, sx, sy, sz):
    # 行主序 3x3 旋转 (单位四元数标准公式)
    x2, y2, z2 = qx + qx, qy + qy, qz + qz
    xx, xy, xz = qx * x2, qx * y2, qx * z2
    yy, yz, zz = qy * y2, qy * z2, qz * z2
    wx, wy, wz = qw * x2, qw * y2, qw * z2
    rot = [1 - (yy + zz), xy - wz, xz + wy,
           xy + wz, 1 - (xx + zz), yz - wx,
           xz - wy, yz + wx, 1 - (xx + yy)]
    # 列主序 4x4, M = R * S (scale 作用在各列), 平移为第 4 列
    m = [0.0] * 16
    for col in range(3):
        s = (sx, sy, sz)[col]
        for row in range(3):
            m[col * 4 + row] = rot[row * 3 + col] * s
    m[12], m[13], m[14], m[15] = px, py, pz, 1.0
    return m

def mat_mul(a, b):
    return [sum(a[k * 4 + row] * b[c * 4 + k] for k in range(4))
            for c in range(4) for row in range(4)]

def mat_inv(m):
    inv = [0.0] * 16
    a, b, c, d = m[0], m[1], m[2], m[3]
    e, f, g, h = m[4], m[5], m[6], m[7]
    i, j, k, l = m[8], m[9], m[10], m[11]
    mm, n, o, p = m[12], m[13], m[14], m[15]
    inv[0] = f * (k * p - l * o) - j * (g * p - h * o) + n * (g * l - h * k)
    inv[4] = -(e * (k * p - l * o) - i * (g * p - h * o) + mm * (g * l - h * k))
    inv[8] = e * (j * p - l * n) - i * (f * p - h * n) + mm * (f * l - h * j)
    inv[12] = -(e * (j * o - k * n) - i * (f * o - g * n) + mm * (f * k - g * j))
    inv[1] = -(b * (k * p - l * o) - j * (c * p - d * o) + n * (c * l - d * k))
    inv[5] = a * (k * p - l * o) - i * (c * p - d * o) + mm * (c * l - d * k)
    inv[9] = -(a * (j * p - l * n) - i * (b * p - d * n) + mm * (b * l - d * j))
    inv[13] = a * (j * o - k * n) - i * (b * o - c * n) + mm * (b * k - c * j)
    inv[2] = b * (g * p - h * o) - f * (c * p - d * o) + n * (c * h - d * g)
    inv[6] = -(a * (g * p - h * o) - e * (c * p - d * o) + mm * (c * h - d * g))
    inv[10] = a * (f * p - h * n) - e * (b * p - d * n) + mm * (b * h - d * f)
    inv[14] = -(a * (f * o - g * n) - e * (b * o - c * n) + mm * (b * g - c * f))
    inv[3] = -(b * (g * l - h * k) - f * (c * l - d * k) + j * (c * h - d * g))
    inv[7] = a * (g * l - h * k) - e * (c * l - d * k) + i * (c * h - d * g)
    inv[11] = -(a * (f * l - h * j) - e * (b * l - d * j) + i * (b * h - d * f))
    inv[15] = a * (f * k - g * j) - e * (b * k - c * j) + i * (b * g - c * f)
    det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
    return [v / det for v in inv]

global_mats = [None] * N
for i, b in enumerate(bones):
    local = mat_from_trs(*b["pos"], *b["rot"], *b["scl"])
    global_mats[i] = mat_mul(global_mats[b["parent"]], local) if b["parent"] >= 0 else local
ibms = [mat_inv(m) for m in global_mats]

# ---- buffer/视图/访问器 ----
bin_data = bytearray()
views, accessors = [], []
F32, U8, U16 = 5126, 5121, 5123

def add_view(blob, align=4):
    while len(bin_data) % align:
        bin_data.append(0)
    off = len(bin_data)
    bin_data.extend(blob)
    views.append({"buffer": 0, "byteOffset": off, "byteLength": len(blob)})
    return len(views) - 1

def add_acc(view, comp, count, ctype):
    accessors.append({"bufferView": view, "componentType": comp, "count": count, "type": ctype})
    return len(accessors) - 1

# ---- 蒙皮网格: 单三角形, 全权重绑定 joint 0 ----
mesh_pos = [[0.0, 1.2, 0.0], [0.0, 0.0, 0.05], [0.05, 0.0, 0.0]]
pacc = add_acc(add_view(struct.pack("<9f", *[v for p in mesh_pos for v in p])), F32, 3, "VEC3")
iacc = add_acc(add_view(struct.pack("<3H", 0, 1, 2), 2), U16, 3, "SCALAR")
jacc = add_acc(add_view(struct.pack("<12B", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), 1), U8, 3, "VEC4")
wacc = add_acc(add_view(struct.pack("<12f", *([1.0, 0.0, 0.0, 0.0] * 3))), F32, 3, "VEC4")
ibm_acc = add_acc(add_view(struct.pack("<%df" % (N * 16), *[v for m in ibms for v in m])), F32, N, "MAT4")

# ---- 动画 ----
def as_vec(v, kind):
    # 兜底: 真·标量键展开成中性值
    if isinstance(v, list):
        return v
    if kind == "rot":
        return [0.0, 0.0, 0.0, 1.0]
    if kind == "scl":
        return [1.0, 1.0, 1.0]
    return [0.0, 0.0, 0.0]

def parse_key(k, kind):
    # dump 的 JSON 把向量展平进了时间数组: rot=[t,x,y,z,w], pos/scl=[t,x,y,z]
    if len(k) == 2 and isinstance(k[1], list):
        return k[0], k[1]
    if kind == "rot" and len(k) == 5:
        return k[0], k[1:5]
    if kind in ("pos", "scl") and len(k) == 4:
        return k[0], k[1:4]
    return k[0], as_vec(k[1] if len(k) > 1 else None, kind)

anims_json = []
for a in anims:
    samplers, channels = [], []
    for tr in a["tracks"]:
        if tr["bone"] not in bone_index:
            continue
        keys = [parse_key(k, tr["kind"]) for k in tr["keys"]]
        times = [k[0] for k in keys]
        if not times:
            continue
        tacc = add_acc(add_view(struct.pack("<%df" % len(times), *times)), F32, len(times), "SCALAR")
        if tr["kind"] == "rot":
            vals = [as_vec(k[1], "rot") for k in keys]
            vacc = add_acc(add_view(struct.pack("<%df" % (len(vals) * 4), *[x for v in vals for x in v])), F32, len(vals), "VEC4")
            path = "rotation"
        else:
            vals = [as_vec(k[1], tr["kind"]) for k in keys]
            vacc = add_acc(add_view(struct.pack("<%df" % (len(vals) * 3), *[x for v in vals for x in v])), F32, len(vals), "VEC3")
            path = "translation" if tr["kind"] == "pos" else "scale"
        samplers.append({"input": tacc, "output": vacc, "interpolation": "LINEAR"})
        channels.append({"sampler": len(samplers) - 1,
                         "target": {"node": bone_index[tr["bone"]], "path": path}})
    if channels:
        anims_json.append({"name": a["name"], "samplers": samplers, "channels": channels})
print("anims_written", len(anims_json))

# ---- 节点/蒙皮/场景 ----
nodes = []
children = [[] for _ in range(N)]
for i, b in enumerate(bones):
    if b["parent"] >= 0:
        children[b["parent"]].append(i)
for i, b in enumerate(bones):
    nodes.append({"name": b["name"], "rotation": b["rot"], "translation": b["pos"],
                  "scale": b["scl"],
                  **({"children": children[i]} if children[i] else {})})
mesh_node_idx = N
skin_node_idx = N + 1
nodes.append({"name": "MeshProxy", "skin": 0, "mesh": 0})
skin = {"inverseBindMatrices": ibm_acc, "joints": list(range(N)), "name": "UALSkin"}
roots = [i for i, b in enumerate(bones) if b["parent"] < 0]

gltf = {
    "asset": {"version": "2.0", "generator": "ual_dump_to_gltf"},
    "scene": 0,
    "scenes": [{"nodes": roots + [mesh_node_idx]}],
    "nodes": nodes,
    "skins": [skin],
    "meshes": [{"primitives": [{"attributes": {"POSITION": pacc, "JOINTS_0": jacc, "WEIGHTS_0": wacc},
                                "indices": iacc, "mode": 4}]}],
    "animations": anims_json,
    "accessors": accessors,
    "bufferViews": views,
    "buffers": [{"byteLength": 0}],
}

# ---- GLB 封装 ----
json_blob = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
while len(json_blob) % 4:
    json_blob += b" "
bin_blob = bytes(bin_data)
while len(bin_blob) % 4:
    bin_blob += b"\0"
gltf["buffers"][0]["byteLength"] = len(bin_blob)
json_blob = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
while len(json_blob) % 4:
    json_blob += b" "

total = 12 + 8 + len(json_blob) + 8 + len(bin_blob)
with open(OUT, "wb") as f:
    f.write(struct.pack("<III", 0x46546C67, 2, total))
    f.write(struct.pack("<II", len(json_blob), 0x4E4F534A))
    f.write(json_blob)
    f.write(struct.pack("<II", len(bin_blob), 0x004E4942))
    f.write(bin_blob)
import os
print("GLB_WRITTEN", os.path.getsize(OUT) // 1024, "KB")
