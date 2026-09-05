# -*- coding: utf-8 -*-
# 约束重定向 -> 视觉烘焙 -> 导出带动画 GLB (Godot 4.7 AnimationPlayer) —— v2 三源整合
#
# 源 A  Soldier.glb (mixamo 真人动捕, 面朝 +Y) -> Idle / Walk / Run
#       每骨 COPY_LOCATION+COPY_ROTATION (人形同比例, 位置拷贝不撕裂)
# 源 C  UAL Mannequin (Quaternius CC0 通用骨架, 经 Godot GLTFDocument 转出)
#       -> Attack / Fire / Gather / Build / Hit / Death
#       UAL 以空物体层级导入 (无蒙皮), 约束直接以空物体为 target;
#       **非根骨只拷 COPY_ROTATION**: 体形差异下拷绝对位置会把骨链撕开
#       (前任 GIF 的 Death 压扁 / Robot Punch 蒙皮拉扯同根因)
#
# 原地化: 每段以首帧 hips 世界位为锚扣除水平漂移 (RTS 单位移动由导航负责), 保留竖直
# 烘焙:   逐帧记录 4006 臂空间矩阵 -> 删约束 -> 按父->子回放 + keyframe_insert
#         关键帧打段内局部帧 1..N (glTF 导出器把绝对帧号当时间, 绝对帧会错排时间轴)
#         只烘焙映射骨 (HeadTop_End/ToeBase 零长度连接骨的 matrix 分解是垃圾,
#         Godot 无连接锁, 导出会把头骨甩出 2m 撕裂蒙皮)
import bpy, pathlib, math
from mathutils import Vector

MOCAP = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\mocap"
UAL_GLB = MOCAP + r"\ual_extract\UAL_Mannequin_skinned.glb"
FBX = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\Characters\Chr_SM_Chr_ScifiWorlds_Soldier_Male_01_rigged.fbx"
OUT_DIR = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006")
OUT_GLB = str(OUT_DIR / "Infantry_anim_v2.glb")
OUT_BLEND = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\retargeted_baked.blend"
RENDER_VERIFY = True   # 每段抽 a/b/c 三帧渲染到 动画帧v4/, 供逐张目检
FPS_UP = 30.0 / 24.0   # UAL 动作按 30fps 编排, 24fps 输出按 1.25 倍取帧保持原速

bpy.ops.wm.read_factory_settings(use_empty=True)

# ---- 源 A: Soldier ----
bpy.ops.import_scene.gltf(filepath=MOCAP + r"\Soldier.glb")
srcA = next(o for o in bpy.data.objects if o.type == "ARMATURE")
for o in list(bpy.data.objects):
    if o.type == "MESH":
        bpy.data.objects.remove(o, do_unlink=True)

# ---- 目标: 4006 士兵 ----
bpy.ops.import_scene.fbx(filepath=FBX)
dst_arm = next(o for o in bpy.data.objects if o.type == "ARMATURE" and o is not srcA)

# ---- 源 C: UAL Mannequin (自建带蒙皮 glTF -> Blender 转成标准骨架) ----
pre_obj_names = set(o.name for o in bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=UAL_GLB)
ual_new_names = set(o.name for o in bpy.data.objects if o.name not in pre_obj_names)
for o in [o for o in bpy.data.objects if o.name in ual_new_names and o.type == "MESH"]:
    bpy.data.objects.remove(o, do_unlink=True)
srcC = next(o for o in bpy.data.objects
            if o.name in ual_new_names and o.type == "ARMATURE")
print("UAL_ARM", srcC.name, "bones", len(srcC.data.bones))
from mathutils import Quaternion as _Q
srcC.rotation_quaternion = (_Q((0.0, 0.0, 1.0), math.pi) @ srcC.rotation_quaternion)  # UAL 源面朝 -Y, 绕世界 Z 转 180° (glTF 导入为四元数模式, 改 euler 无效)

sc = bpy.context.scene
sc.render.fps = 24
sc.render.fps_base = 1.0
sc.frame_set(1)
bpy.context.view_layer.update()
source_action_names = set(a.name for a in bpy.data.actions)

# ---- 约束 ----
dpb = dst_arm.pose.bones

def add_copy(pb, target, subtarget, with_location=True):
    c1 = None
    if with_location:
        c1 = pb.constraints.new("COPY_LOCATION")
        c1.target = target
        c1.subtarget = subtarget
    c2 = pb.constraints.new("COPY_ROTATION")
    c2.target = target
    c2.subtarget = subtarget
    return c1, c2

con_a, con_c = {}, {}
for b in ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
          "LeftShoulder", "RightShoulder", "LeftArm", "RightArm",
          "LeftForeArm", "RightForeArm", "LeftHand", "RightHand",
          "LeftUpLeg", "RightUpLeg", "LeftLeg", "RightLeg",
          "LeftFoot", "RightFoot"]:
    snA = "mixamorig:" + b
    if snA in srcA.pose.bones and b in dpb:
        con_a[b] = add_copy(dpb[b], srcA, snA)
# UAL -> 4006: 同为 Blender 骨架约定 (沿骨轴), 与 Soldier 同规则拷贝;
# 体形仍有差异 (肩宽/盆宽), 仅 Hips 拷位置防撕裂, 其余只拷旋转;
# Spine2 无 UAL 对应骨, 复用 UpperChest 朝向
U_MAP = {"Hips": "Hips", "Chest": "Spine", "UpperChest": "Spine1",
         "Neck": "Neck", "Head": "Head",
         "LeftShoulder": "LeftShoulder", "RightShoulder": "RightShoulder",
         "LeftUpperArm": "LeftArm", "RightUpperArm": "RightArm",
         "LeftLowerArm": "LeftForeArm", "RightLowerArm": "RightForeArm",
         "LeftHand": "LeftHand", "RightHand": "RightHand",
         "LeftUpperLeg": "LeftUpLeg", "RightUpperLeg": "RightUpLeg",
         "LeftLowerLeg": "LeftLeg", "RightLowerLeg": "RightLeg",
         "LeftFoot": "LeftFoot", "RightFoot": "RightFoot"}
cpbC = srcC.pose.bones
for uname, dname in U_MAP.items():
    if uname not in cpbC or dname not in dpb:
        print("U_MAP_SKIP", uname, "->", dname)
        continue
    con_c[dname] = add_copy(dpb[dname], srcC, uname,
                            with_location=(dname == "Hips"))
if "UpperChest" in cpbC and "Spine2" in dpb:
    con_c["Spine2"] = add_copy(dpb["Spine2"], srcC, "UpperChest",
                               with_location=False)
# ---- UAL->Soldier 约定校正 (修关节扭转) ----
# UAL 骨架经手工 glTF 导入, 骨骼 roll 约定与 Mixamo 家族(4006/Soldier)不同;
# 世界拷贝会把 UAL 的 roll 原样带给 4006 => 膝/肩等关节在动画中绕骨轴扭转。
# 修复: 两个源的 rest 都是 T-pose (同族 rest pose), 做标准 rest-delta 校正
#   R_target(f) = R_S(f) · R_S_rest⁻¹ · R_So_rest   (右乘常量四元数)
# 把 UAL 帧规范到 Soldier 约定 (Soldier->4006 已由验收过的管线保证)。
q_corr = {}
cpbA = srcA.pose.bones
for uname, dname in list(U_MAP.items()) + [("UpperChest", "Spine2")]:
    so_name = "mixamorig:" + dname
    if uname not in cpbC or dname not in dpb or so_name not in cpbA:
        continue
    mS = srcC.matrix_world @ srcC.data.bones[uname].matrix_local
    mSo = srcA.matrix_world @ srcA.data.bones[so_name].matrix_local
    q_corr[dname] = mS.to_quaternion().inverted() @ mSo.to_quaternion()
print("q_corr bones:", len(q_corr))
for c1, c2 in con_a.values():
    c1.influence, c2.influence = 1.0, 1.0
for c1, c2 in con_c.values():
    if c1:
        c1.influence = 0.0
    c2.influence = 0.0
print("conA:", len(con_a), "conC:", len(con_c))

adA = srcA.animation_data or srcA.animation_data_create()
adC = srcC.animation_data or srcC.animation_data_create()

def bind_a(act_name):
    act = bpy.data.actions.get(act_name)
    if not act:
        raise RuntimeError("action missing: " + act_name)
    adA.action = act
    if hasattr(act, "slots") and act.slots:
        adA.action_slot = act.slots[0]

def bind_c(act_name):
    act = bpy.data.actions.get(act_name)
    if not act:
        raise RuntimeError("UAL action missing: " + act_name)
    adC.action = act
    if hasattr(act, "slots") and act.slots:
        adC.action_slot = act.slots[0]

def set_influences(wa: float, wc: float):
    for c1, c2 in con_a.values():
        c1.influence, c2.influence = wa, wa
    for c1, c2 in con_c.values():
        if c1:
            c1.influence = wc
        c2.influence = wc

# ---- 段表: 启动时按源动作长度计算边界 ----
# 规格: (源键, 源动作, 输出名, 循环规格, 原地化)  循环规格=(源周期帧, 遍数) 或 None=单发
SEG_SPEC = [
    ("A", "Idle", "Idle-loop", (48, 2), True),
    ("A", "Walk", "Walk-loop", (25, 2), True),
    ("A", "Run", "Run-loop", (17, 2), True),
    ("C", "Sword_Attack_Standing", "Attack", None, True),
    ("C", "Pistol_Shoot", "Fire", None, True),
    ("C", "PickUp_Kneeling", "Gather-loop", (46, 2), True),
    ("C", "Fixing_Kneeling", "Build-loop", (124, 1), True),
    ("C", "Hit_Stomach", "Hit", None, True),
    ("C", "Death01", "Death", None, True),
]
SEG = []
_cursor = 1
for sk, sa, on, cyc, ip in SEG_SPEC:
    f0 = _cursor
    if sk == "A":
        period, loops = cyc
        n = period * loops
        fmap = (lambda P, f0: (lambda f: (f - f0) % P))(period, f0)
    elif cyc is not None:
        period, loops = cyc
        n = int(period * loops / FPS_UP)
        fmap = (lambda P, f0: (lambda f: int((f - f0) * FPS_UP) % P))(period, f0)
    else:
        src_len = bpy.data.actions[sa].frame_range[1]
        n = int(math.ceil(src_len / FPS_UP))
        fmap = (lambda L, f0: (lambda f: int(min((f - f0) * FPS_UP, L - 0.001))))(src_len, f0)
    f1 = f0 + n - 1
    SEG.append((f0, f1, sk, sa, on, fmap, ip))
    _cursor = f1 + 1
    print("SEG", on, f0, "-", f1, sa)

# 骨骼按父->子排序 (回放 pb.matrix 必须先父后子)
def bone_depth(name):
    d, p = 0, dst_arm.data.bones[name]
    while p.parent:
        d += 1
        p = p.parent
    return d
ordered_bones = sorted(dpb.keys(), key=bone_depth)

F_LAST = SEG[-1][1]

# ---- Pass 1: 逐帧求值 ----
pose_store = {}
hips_world = {}
for f in range(1, F_LAST + 1):
    f0, f1, sk, sa, on, fmap, ip = next(x for x in SEG if x[0] <= f <= x[1])
    if sk == "A":
        bind_a(sa)
        set_influences(1.0, 0.0)
    else:
        bind_c(sa)
        set_influences(0.0, 1.0)
    sc.frame_set(int(fmap(f)))
    bpy.context.view_layer.update()
    hips_world[f] = (dst_arm.matrix_world @ dpb["Hips"].matrix).to_translation().copy()
    pose_store[f] = {n: dpb[n].matrix.copy() for n in ordered_bones}
    if fmap(f) in (0,) and f <= 500:
        pass
    if f in (1, 97, 147, SEG[3][0], SEG[4][0], SEG[5][0], SEG[6][0], SEG[7][0], SEG[8][0], F_LAST):
        print("HIPS_W f=%d z=%.3f (%.3f, %.3f)" % (f, hips_world[f].z, hips_world[f].x, hips_world[f].y))
print("PASS1_DONE")

# 原地化偏移 (水平扣漂移, 保留竖直)
offset_world = {}
for f0, f1, sk, sa, on, fmap, ip in SEG:
    anchor = hips_world[f0]
    for f in range(f0, f1 + 1):
        if ip:
            p = hips_world[f]
            offset_world[f] = Vector((anchor.x - p.x, anchor.y - p.y, 0.0))
        else:
            offset_world[f] = Vector((0.0, 0.0, 0.0))
for f0, f1, sk, sa, on, fmap, ip in SEG:
    pts = [hips_world[f] for f in range(f0, f1 + 1)]
    dx = max(p.x for p in pts) - min(p.x for p in pts)
    dy = max(p.y for p in pts) - min(p.y for p in pts)
    print("DRIFT %s x=%.3f y=%.3f" % (on, dx, dy))

inv_arm_rot = dst_arm.matrix_world.inverted().to_3x3()

# ---- 渲染自检: 每段 a/b/c 三帧, ±Y 标记块判朝向 ----
if RENDER_VERIFY:
    import bmesh as _bm
    from mathutils import Matrix
    vdir = OUT_DIR / "动画帧v4"
    vdir.mkdir(parents=True, exist_ok=True)
    sc.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in dir(bpy.types) else "BLENDER_EEVEE"
    sc.render.resolution_x, sc.render.resolution_y = 400, 520
    w = bpy.data.worlds.new("W"); w.color = (0.78, 0.78, 0.80); sc.world = w
    for lname, loc, energy in (("K1", (3, -3, 4), 800), ("K2", (-4, 2, 3), 400), ("K3", (0, 3, 5), 300)):
        ld = bpy.data.lights.new(lname, "POINT"); ld.energy = energy
        lo = bpy.data.objects.new(lname, ld); sc.collection.objects.link(lo); lo.location = loc
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    sc.collection.objects.link(cam); sc.camera = cam
    gm = bpy.data.meshes.new("Ground"); go = bpy.data.objects.new("Ground", gm)
    sc.collection.objects.link(go)
    bm = _bm.new(); _bm.ops.create_grid(bm, x_segments=1, y_segments=1, size=8.0); bm.to_mesh(gm); bm.free()
    gmat = bpy.data.materials.new("GroundMat"); gmat.use_nodes = True
    next(n for n in gmat.node_tree.nodes if n.type == "BSDF_PRINCIPLED").inputs["Base Color"].default_value = (0.62, 0.60, 0.57, 1)
    go.data.materials.append(gmat)
    for tag, yy, col in (("+Y", 0.9, (0.9, 0.15, 0.15, 1)), ("-Y", -0.9, (0.15, 0.2, 0.9, 1))):
        mm = bpy.data.meshes.new("M" + tag); mo = bpy.data.objects.new("M" + tag, mm)
        sc.collection.objects.link(mo)
        bm2 = _bm.new(); _bm.ops.create_cube(bm2, size=1, matrix=Matrix.Translation((0, yy, 0.15)))
        bm2.to_mesh(mm); bm2.free()
        mmat = bpy.data.materials.new("Mat" + tag); mmat.use_nodes = True
        next(n for n in mmat.node_tree.nodes if n.type == "BSDF_PRINCIPLED").inputs["Base Color"].default_value = col
        mo.data.materials.append(mmat)
    ang = math.radians(126)
    for f0, f1, sk, sa, on, fmap, ip in SEG:
        for tag, ff in (("a", f0), ("b", (f0 + f1) // 2), ("c", f1)):
            s = next(x for x in SEG if x[0] <= ff <= x[1])
            if s[2] == "A":
                bind_a(s[3]); set_influences(1.0, 0.0)
            else:
                bind_c(s[3]); set_influences(0.0, 1.0)
            sc.frame_set(int(s[5](ff)))
            bpy.context.view_layer.update()
            hip = (dst_arm.matrix_world @ dpb["Hips"].matrix).to_translation()
            dist = 4.5 if "Death" in s[4] else 3.0
            cam.location = (hip.x + dist * math.cos(ang), hip.y + dist * math.sin(ang),
                            max(hip.z + 0.3, 1.1))
            cam.rotation_euler = (Vector((hip.x, hip.y, hip.z)) - cam.location).to_track_quat("-Z", "Y").to_euler()
            sc.render.filepath = str(vdir / ("%s_%s.png" % (s[4], tag)))
            bpy.ops.render.render(write_still=True)
        print("RENDERED", on)
    sc.render.filepath = ""
    for oname in ("Cam", "Ground", "M+Y", "M-Y", "K1", "K2", "K3"):
        if oname in bpy.data.objects:
            bpy.data.objects.remove(bpy.data.objects[oname], do_unlink=True)
    sc.world = None

# Pass 1 已结束: 删掉全部源动作 (避免烘焙撞名 / 导出垃圾剪辑)
for a in [a for a in bpy.data.actions if a.name in source_action_names]:
    bpy.data.actions.remove(a)

# ---- 删约束, 回放矩阵并烘焙关键帧 ----
for pb in dpb:
    for c in list(pb.constraints):
        pb.constraints.remove(c)
bpy.context.view_layer.update()

mapped_bones = set(con_a.keys()) | set(con_c.keys())
keyframe_bones = [n for n in ordered_bones if n in mapped_bones]
ad_dst = dst_arm.animation_data or dst_arm.animation_data_create()

def count_keys(act):
    try:
        bag = act.layers[0].strips[0].channelbag(act.slots[0])
        return len(bag.fcurves)
    except Exception as e:
        print("COUNT_KEYS_FALLBACK", e)
        return -1

for f0, f1, sk, sa, on, fmap, ip in SEG:
    act = bpy.data.actions.new(on)
    act.use_fake_user = True
    ad_dst.action = act
    if hasattr(act, "slots") and act.slots:
        ad_dst.action_slot = act.slots[0]
    for f in range(f0, f1 + 1):
        off_obj = inv_arm_rot @ offset_world[f]
        targets = {}
        for n in keyframe_bones:
            m = pose_store[f][n].copy()
            if sk == "C" and n in q_corr:
                # UAL 帧规范到 Soldier 约定: 旋转部分右乘常量校正, 平移保留
                rot = m.to_3x3() @ q_corr[n].to_matrix()
                t = m.translation
                m = rot.to_4x4()
                m.translation = t
            m.translation += off_obj
            targets[n] = m
        # 收敛循环: pb.matrix 的 setter 依据父骨骼"当前求值位姿"分解本地 basis,
        # 而父骨骼的求值要等 depsgraph 更新才刷新 —— 单次设置会让骨架从深到浅
        # 逐层晚一帧收敛, 每段开头 3~4 帧烘进垃圾关键帧 (Godot 里就是开头闪烁)。
        # 循环设置+校验(只比旋转, 平移受连接骨锁定影响不比), 直到整体到位。
        for _attempt in range(8):
            for n in keyframe_bones:
                dpb[n].matrix = targets[n]
            bpy.context.view_layer.update()
            max_err = 0.0
            for n in keyframe_bones:
                qa = dpb[n].matrix.to_quaternion()
                qb = targets[n].to_quaternion()
                err = abs(qa.rotation_difference(qb).angle)
                if err > max_err:
                    max_err = err
            if max_err < 0.0005:
                break
        if max_err >= 0.0005:
            print("WARN_NOT_CONVERGED", on, "f", f, "err", round(max_err, 5))
        fbake = f - f0 + 1  # 段内局部帧: glTF 导出器把绝对帧号当时间
        for n in keyframe_bones:
            pb = dpb[n]
            pb.keyframe_insert("location", frame=fbake)
            pb.keyframe_insert("rotation_quaternion", frame=fbake)
            s = pb.scale
            if abs(s.x - 1) > 0.01 or abs(s.y - 1) > 0.01 or abs(s.z - 1) > 0.01:
                pb.keyframe_insert("scale", frame=fbake)
                print("WARN_NONUNIT_SCALE", f, n, tuple(round(v, 3) for v in s))
    track = ad_dst.nla_tracks.new()
    track.name = on
    strip = track.strips.new(on, int(f0), act)
    strip.name = on
    ad_dst.action = None
    print("BAKED", on, f0, "-", f1, "keys_fcurves=", count_keys(act))

# ---- 导出 GLB (仅 4006: 移除全部动捕源对象) ----
for o in list(bpy.data.objects):
    if o in (srcA, srcC):
        bpy.data.objects.remove(o, do_unlink=True)
bpy.context.view_layer.update()
print("REMAINING_ACTIONS", [a.name for a in bpy.data.actions])
print("REMAINING_OBJS", [(o.name, o.type) for o in bpy.data.objects])

bpy.ops.export_scene.gltf(
    filepath=OUT_GLB,
    export_format="GLB",
    export_animations=True,
    export_animation_mode="ACTIONS",
    export_yup=True,
    export_skins=True,
    export_apply=False,
)
print("GLB_SIZE_KB", pathlib.Path(OUT_GLB).stat().st_size // 1024)

bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
print("BAKE_EXPORT_DONE")
