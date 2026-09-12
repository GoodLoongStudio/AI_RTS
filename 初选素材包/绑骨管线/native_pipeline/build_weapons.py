"""Full weapon library from every 初选素材包 weapon pack.

Auto-discovers SM_Wep_*.fbx in the five asset packs (4006 sci-fi, 4017 fantasy
monsters, 4019 WW1, 4041 western, 463 apocalypse), excludes mod parts, scopes
and loose ammo, and exports each as a standalone GLB: single mesh, no skeleton,
atlas material, in-game scale baked where the game build defined one. The six
weapons used by the character batch keep their grip-point origin and attach
config; everything else keeps the source FBX pivot (documented per weapon).
Renders two previews per weapon and validates every export by re-import.
Resumable: completed GLBs (matching sha) are skipped via .meta sidecars.
"""
import sys, pathlib, json, hashlib, math, re, shutil
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import bpy
from mathutils import Vector, Matrix

from build_batch import CHARACTERS
from baseline import ROOT

def load_fbx_weapon(fbx_path, mat):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(fbx_path))
    parts = [o for o in bpy.data.objects if o not in before and o.type == 'MESH']
    transforms = {o: o.matrix_world.copy() for o in parts}
    for ob in parts:
        ob.parent = None; ob.data.transform(transforms[ob]); ob.matrix_world = Matrix.Identity(4)
    bpy.ops.object.select_all(action='DESELECT')
    for ob in parts: ob.select_set(True)
    ob = parts[0]; bpy.context.view_layer.objects.active = ob; bpy.ops.object.join(); ob.name = 'Weapon'
    ob.data.materials.clear(); ob.data.materials.append(mat)
    for p in ob.data.polygons: p.material_index = 0
    return ob

ASSETS = ROOT.parent/'工程/预览渲染工程/assets'
OUT = ROOT/'批量绑定_v1/武器库'
PACKS_LIB = {
 '4006': dict(dir=ASSETS/'4006_科幻世界/PolygonSciFiWorlds/Models',
   tex=ASSETS/'4006_科幻世界/PolygonSciFiWorlds/Models/PolygonScifiWorlds_Texture_01_A.png',
   folder='科幻_4006', name='科幻战争 4006'),
 '4017': dict(dir=ASSETS/'4017_幻想怪物/PolygonFantasyRivals/Models',
   tex=ASSETS/'4017_幻想怪物/PolygonFantasyRivals/Textures/FantasyRivals_Texture_01_A.png',
   folder='怪物_4017', name='幻想怪物 4017'),
 # 4019 一战 / 4041 西部：按需求移出武器库（角色 GLB 内仍内嵌其步枪）
 '463': dict(dir=ASSETS/'463_末日废墟/PolygonApocalypse/Models',
   tex=ASSETS/'463_末日废墟/PolygonApocalypse/Models/PolygonApocalypse_Texture_01_A.png',
   folder='末日_463', name='幸存者与僵尸 463'),
}
EXCLUDE = re.compile(r'Mod_|Scope_|_Shell|Harpoon_Ammo|Saw_Launcher_Ammo|Missile|Rocket_Fireworks|Rocket_IED|Gun_Spear')
# 游戏内已知握把/缩放（与 build_batch.py WEAPONS 一致），键=源文件名
GRIP = {
 'SM_Wep_Assault_01.fbx': dict(kind='rifle', scale=.8, grip=(-.060,.025,.018),
   config=dict(pos=(-.10,-.24,-.11), wrist_r=(-.060,.025,.018), wrist_l=(.11,-.29,-.025), carry=(-.048,.020,.0144)),
   recipe='build_batch.py rifle_hold（双手持枪 IK）/ detached_rifle（匍匐、死亡单手拖枪）'),
 'SM_Wep_British_Rifle_01.fbx': dict(kind='rifle', scale=1.0, grip=(-.06,.02,.01),
   config=dict(pos=(-.10,-.18,-.11), wrist_r=(-.06,.02,.01), wrist_l=(.11,-.24,-.02), carry=(-.16,.02,-.02)),
   recipe='build_batch.py rifle_hold / detached_rifle'),
 'SM_Wep_German_Rifle_01.fbx': dict(kind='rifle', scale=1.0, grip=(-.06,.03,.01),
   config=dict(pos=(-.10,-.18,-.11), wrist_r=(-.06,.03,.01), wrist_l=(.11,-.26,-.02), carry=(-.16,.02,-.02)),
   recipe='build_batch.py rifle_hold / detached_rifle'),
 'SM_Wep_MechanicalGolem_01.fbx': dict(kind='melee', scale=1.0, grip_z=-.35, tilt=0.5236),
 'SM_Wep_ElementalGolem_01.fbx': dict(kind='melee', scale=1.0, grip_z=-.35, tilt=0.5236),
 'SM_Wep_FortGolem_01.fbx': dict(kind='melee', scale=1.0, grip_z=-.12, tilt=0.5236),
}
MELEE_MATRIX = lambda cfg: (Matrix.Translation(Vector((-cfg['grip_z']*math.sin(cfg['tilt']), .02+cfg['grip_z']*math.cos(cfg['tilt']), 0)))
   @ Matrix.Rotation(cfg['tilt'], 4, 'Z') @ Matrix.Rotation(math.radians(90), 4, 'X'))

def atlas_material(tex):
    mat = bpy.data.materials.new('Atlas'); mat.use_nodes = True
    bs = next(n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
    t = mat.node_tree.nodes.new('ShaderNodeTexImage')
    t.image = bpy.data.images.load(str(tex)); t.image.pack()
    mat.node_tree.links.new(t.outputs['Color'], bs.inputs['Base Color'])
    bs.inputs['Roughness'].default_value = .85
    return mat

def mesh_stats(ob):
    xs = [v.co for v in ob.data.vertices]
    lo = Vector((min(v.x for v in xs), min(v.y for v in xs), min(v.z for v in xs)))
    hi = Vector((max(v.x for v in xs), max(v.y for v in xs), max(v.z for v in xs)))
    return lo, hi, sum(len(p.vertices)-2 for p in ob.data.polygons)

def render_preview(ob, path, dims):
    sc = bpy.context.scene
    sc.render.engine = 'BLENDER_EEVEE'; sc.render.resolution_x = 480; sc.render.resolution_y = 560
    sc.render.image_settings.file_format = 'PNG'
    sc.world = bpy.data.worlds.new('W'); sc.world.use_nodes = True
    nt = sc.world.node_tree
    bg = next((n for n in nt.nodes if n.type == 'BACKGROUND'), None)
    if bg is None:
        bg = nt.nodes.new('ShaderNodeBackground')
        o = next((n for n in nt.nodes if n.type == 'OUTPUT_WORLD'), None) or nt.nodes.new('ShaderNodeOutputWorld')
        nt.links.new(bg.outputs[0], o.inputs['Surface'])
    bg.inputs[0].default_value = (.18,.20,.23,1); bg.inputs[1].default_value = .4
    center = (Vector(ob.bound_box[0])+Vector(ob.bound_box[6]))/2
    size = max(dims)
    for loc, energy in [((3,-4,6),700),((-3,1,4),450)]:
        data = bpy.data.lights.new('Softbox','AREA'); data.energy = energy*(size/0.8)
        data.shape = 'DISK'; data.size = 4
        li = bpy.data.objects.new('Softbox', data); sc.collection.objects.link(li)
        li.location = center+Vector(loc)*(size/0.8)*0.7
        li.rotation_euler = (center-li.location).to_track_quat('-Z','Y').to_euler()
    cam = bpy.data.objects.new('Cam', bpy.data.cameras.new('Cam')); sc.collection.objects.link(cam)
    sc.camera = cam; cam.data.type = 'ORTHO'; cam.data.ortho_scale = size*1.6+.05
    for tag, direction in [('四分之三', Vector((1.2,-2.0,0.75))), ('正视', Vector((0,-1,0.18)))]:
        cam.location = center+direction.normalized()*(size*3.5+.8)
        cam.rotation_euler = (center-cam.location).to_track_quat('-Z','Y').to_euler()
        sc.render.filepath = str(path.parent/(path.stem+'_'+tag+'.png'))
        bpy.ops.render.render(write_still=True)

META = OUT/'.meta'; META.mkdir(parents=True, exist_ok=True)
for legacy in ['科幻','一战','怪物']:
    shutil.rmtree(OUT/legacy, ignore_errors=True)
(OUT/'武器库总览.png').unlink(missing_ok=True)

def build_weapon(pack_id, fbx_path):
    base = fbx_path.name; stem = base[:-4].replace('SM_Wep_','')
    cfg = GRIP.get(base); folder = OUT/PACKS_LIB[pack_id]['folder']
    stem_out = stem
    glb = folder/(stem_out+'.glb')
    png34 = folder/(stem_out+'_四分之三.png'); pngfr = folder/(stem_out+'_正视.png')
    sha = hashlib.sha256(fbx_path.read_bytes()).hexdigest()
    side = META/(pack_id+'_'+stem_out+'.json')
    if glb.exists() and png34.exists() and pngfr.exists() and side.exists():
        old = json.loads(side.read_text(encoding='utf8'))
        if old.get('source_sha256') == sha: return old
    bpy.ops.wm.read_factory_settings(use_empty=True)
    mat = atlas_material(PACKS_LIB[pack_id]['tex'])
    gun = load_fbx_weapon(fbx_path, mat)
    src_lo, src_hi, tris = mesh_stats(gun); src_dims = src_hi-src_lo
    s = cfg['scale'] if cfg else 1.0
    if cfg and cfg['kind'] == 'rifle':
        grip = Vector(cfg['grip'])
        attach = {'mode': 'grip_origin_game_config', 'scale_in_game': s,
          'config_source_space': cfg['config'], 'recipe': cfg['recipe'],
          'note': '原点=游戏握把点；配置数值在源空间（源原点=库内 +source_origin_offset_in_library）'}
    elif cfg:
        m = MELEE_MATRIX(cfg); grip = m.inverted().translation.copy()
        attach = {'mode': 'grip_origin_game_config', 'scale_in_game': s, 'bone': 'Hand_R',
          'matrix_hand_local': [round(c, 8) for row in (m @ Matrix.Translation(grip) @ Matrix.Scale(1.0/s, 4)).transposed() for c in row],
          'note': '将本 GLB 作为 Hand_R 子节点并应用 matrix_hand_local（列主序 4x4），任意同源 Synty 骨架复现游戏内持握'}
    else:
        grip = Vector((0,0,0))
        attach = {'mode': 'source_pivot', 'scale_in_game': s,
          'note': '原点=源 FBX 轴心（未平移）；朝向与尺寸见预览图，挂载角度自行调整'}
    if grip.length > 0: gun.data.transform(Matrix.Translation(-grip))
    if s != 1.0: gun.data.transform(Matrix.Scale(s, 4))
    bpy.context.view_layer.update()
    lo, hi, tris = mesh_stats(gun)
    folder.mkdir(parents=True, exist_ok=True)
    for ob in bpy.data.objects:
        if ob is not gun: ob.select_set(False)
    gun.name = 'Weapon'; gun.select_set(True); bpy.context.view_layer.objects.active = gun
    bpy.ops.export_scene.gltf(filepath=str(glb), export_format='GLB', use_selection=True,
        export_animations=False, export_skins=False, export_yup=True)
    render_preview(gun, folder/stem_out, hi-lo)
    used_by = [c[0] for c in CHARACTERS if c[4] == base[:-4]]
    entry = {
     'file': str(glb.relative_to(OUT)), 'pack': pack_id, 'pack_name': PACKS_LIB[pack_id]['name'],
     'source_fbx': str(fbx_path.relative_to(ASSETS)), 'source_sha256': sha,
     'texture': PACKS_LIB[pack_id]['tex'].name, 'kind_hint': 'gun' if re.search(r'Rifle|Pistol|Shotgun|SMG|Sniper|Gun|Launcher|Launcher|Cross|Flame|Nail|Revolver', stem) else 'melee' if re.search(r'Axe|Sword|Dagger|Club|Hammer|Bat|Knife|Katana|Machete|Spear|Crowbar|Wrench|Pipe|Spade|Shovel|Pick|Cleaver|Butcher|Trimmer|Plank|Crutch|Sign|Cross_]', stem) else 'other',
     'scale_applied': s,
     'source_dims_m': [round(v, 4) for v in src_dims],
     'dims_m': [round(v, 4) for v in hi-lo],
     'bbox_min': [round(v, 4) for v in lo], 'bbox_max': [round(v, 4) for v in hi],
     'grip_at_origin': [round(v, 4) for v in grip],
     'source_origin_offset_in_library': [round(v, 4) for v in grip*s],
     'vertices': len(gun.data.vertices), 'triangles': tris,
     'used_by': used_by, 'attach': attach,
    }
    side.write_text(json.dumps(entry, ensure_ascii=False, indent=1), encoding='utf8')
    return entry

results = {}
for pack_id, pk in PACKS_LIB.items():
    files = sorted(f for f in pk['dir'].glob('SM_Wep_*.fbx') if not EXCLUDE.search(f.stem))
    print('PACK', pack_id, len(files), 'weapons', flush=True)
    for f in files:
        entry = build_weapon(pack_id, f)
        results[pack_id+'/'+f.name[:-4].replace('SM_Wep_','')] = entry
        print('WEAPON', pack_id, entry['file'], 'dims', entry['dims_m'], 'verts', entry['vertices'], flush=True)

manifest = {
 'generated': '2026-09-09',
 'source_root': str(ASSETS),
 'convention': '单网格无骨架无蒙皮，内嵌图集贴图；游戏已知 6 件原点=握把点，其余原点=源 FBX 轴心；export_yup',
 'excluded': 'Mod_* 改枪配件、Scope_* 瞄准镜、弹壳/弹药（*_Shell、*_Spear、Harpoon_Ammo、Saw_Launcher_Ammo）、纯弹药（Missile、Rocket_Fireworks、Rocket_IED）',
 'packs': {k: {'folder': v['folder'], 'name': v['name'], 'texture': v['tex'].name} for k, v in PACKS_LIB.items()},
 'weapons': results,
}
(OUT/'武器库清单.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding='utf8')

ok = True
for key, entry in results.items():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(OUT/entry['file']))
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    n_arm = len([o for o in bpy.data.objects if o.type == 'ARMATURE']) + len(bpy.data.armatures)
    lo = Vector((1e9,)*3); hi = Vector((-1e9,)*3)
    dg = bpy.context.evaluated_depsgraph_get()
    for ob in meshes:
        eo = ob.evaluated_get(dg); me = eo.to_mesh()
        for v in me.vertices:
            w = eo.matrix_world@v.co
            lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
        eo.to_mesh_clear()
    dims = hi-lo; ref = Vector(entry['dims_m'])
    tex_ok = bool(meshes) and bool(meshes[0].data.materials) and any(n.type == 'TEX_IMAGE' for n in meshes[0].data.materials[0].node_tree.nodes)
    suspicious = max(dims) > 5 or max(dims) < 0.03
    good = n_arm == 0 and len(meshes) == 1 and all(abs(a-b) < .002 for a, b in zip(dims, ref)) and tex_ok and not suspicious
    ok &= good
    if not good:
        print('VALIDATE', key, 'FAIL dims', [round(v,4) for v in dims], 'meshes', len(meshes), 'arm', n_arm, 'suspicious', suspicious, flush=True)
print('WEAPON_LIB_BUILT', len(results), 'VALIDATION', 'ALL_PASS' if ok else 'HAS_FAILURES', flush=True)
