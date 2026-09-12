"""Multi-character batch bind: WW1, fantasy monsters, full sci-fi Characters set.

Mirrors the validated v3 single-character recipe (native_pipeline/build_native.py):
original Synty skeleton + weights preserved; motion retargeted from Soldier.glb
(Mixamo, 'A') and UAL mannequin ('C') into the target rest via world-rotation
deltas; 30fps; loop clips seam-closed; per-clip grounding.

Weapon layers:
- rifle  : two-hand grip IK (rifle_hold), assault/british/german configs.
- melee  : club/hammer rigid in the right hand (carry pose), Fire clip is the
           UAL 'Sword_Attack' performance instead of rifle recoil.
"""
import sys, pathlib, math, json, hashlib, argparse
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import bpy
from mathutils import Vector, Matrix, Quaternion
from baseline import bind, world_rest, apply_world_rotations, MAP, ROOT, stage

MODELS = ROOT.parent / '工程/预览渲染工程/assets'
PACKS = {
 'scifi': MODELS/'4006_科幻世界/PolygonSciFiWorlds/Models',
 'ww1': MODELS/'4019_战争地图/PolygonWarMap/Models',
 'monster': MODELS/'4017_幻想怪物/PolygonFantasyRivals/Models',
}
TEX = {
 'scifi': PACKS['scifi']/'PolygonScifiWorlds_Texture_01_A.png',
 'ww1': PACKS['ww1']/'PolygonWar_Map_Texture_01_A.png',
 'monster': MODELS/'4017_幻想怪物/PolygonFantasyRivals/Textures/FantasyRivals_Texture_01_A.png',
}
WEAPONS = {
 'assault': dict(pack='scifi', fbx='SM_Wep_Assault_01.fbx', kind='rifle', scale=.8,
   pos=(-.10,-.24,-.11), wrist_r=(-.060,.025,.018), wrist_l=(.11,-.29,-.025),
   carry=(-.048,.020,.0144)),
 'british': dict(pack='ww1', fbx='SM_Wep_British_Rifle_01.fbx', kind='rifle', scale=1.0,
   pos=(-.10,-.18,-.11), wrist_r=(-.06,.02,.01), wrist_l=(.11,-.24,-.02),
   carry=(-.16,.02,-.02)),
 'german': dict(pack='ww1', fbx='SM_Wep_German_Rifle_01.fbx', kind='rifle', scale=1.0,
   pos=(-.10,-.18,-.11), wrist_r=(-.06,.03,.01), wrist_l=(.11,-.26,-.02),
   carry=(-.16,.02,-.02)),
 'mech_club': dict(pack='monster', fbx='SM_Wep_MechanicalGolem_01.fbx', kind='melee',
   scale=1.0, grip_z=-.35, tilt=0.5236),
 'elem_club': dict(pack='monster', fbx='SM_Wep_ElementalGolem_01.fbx', kind='melee',
   scale=1.0, grip_z=-.35, tilt=0.5236),
 'fort_hammer': dict(pack='monster', fbx='SM_Wep_FortGolem_01.fbx', kind='melee',
   scale=1.0, grip_z=-.12, tilt=0.5236),
}
# out -> (pack, fbx, mesh, weapon)
CHARACTERS = [
 ('WW1_German','ww1','Characters_WW1.fbx','Character_German_WW1_01','german'),
 ('WW1_British','ww1','Characters_WW1.fbx','Character_British_WW1_01','british'),
 ('Monster_MechanicalGolem','monster','Characters_BR.fbx','Character_MechanicalGolem_01','mech_club'),
 ('Monster_ElementalGolem','monster','Characters_BR.fbx','Character_ElementalGolem_01','elem_club'),
 ('Monster_FortGolem','monster','Characters_BR.fbx','Character_FortGolem_01','fort_hammer'),
]
for suffix, mesh in [
 ('Soldier_Male_01','SM_Chr_ScifiWorlds_Soldier_Male_01'),('Soldier_Male_02','SM_Chr_ScifiWorlds_Soldier_Male_02'),
 ('Soldier_Female_02','SM_Chr_ScifiWorlds_Soldier_Female_02'),('Strider_Male_01','SM_Chr_ScifiWorlds_Strider_Male_01'),
 ('Female_01','SM_Chr_ScifiWorlds_Female_01'),('Male_01','SM_Chr_ScifiWorlds_Male_01'),
 ('Scavenger_01','SM_Chr_ScifiWorlds_Scavenger_01'),('Scavenger_02','SM_Chr_ScifiWorlds_Scavenger_02'),
 ('Scavenger_03','SM_Chr_ScifiWorlds_Scavenger_03'),('SpaceSuit_Male_01','SM_Chr_ScifiWorlds_SpaceSuit_Male_01'),
 ('SpaceSuit_Male_02','SM_Chr_ScifiWorlds_SpaceSuit_Male_02'),('SpaceSuit_Female_01','SM_Chr_ScifiWorlds_SpaceSuit_Female_01'),
 ('SpaceSuit_Female_02','SM_Chr_ScifiWorlds_SpaceSuit_Female_02'),('SpaceSuit_Alien_Male_01','SM_Chr_ScifiWorlds_SpaceSuit_Alien_Male_01'),
 ('SpaceSuit_Alien_Female_01','SM_Chr_ScifiWorlds_SpaceSuit_Alien_Female_01'),
]:
    CHARACTERS.append(('Scifi_'+suffix,'scifi','Characters.fbx',mesh,'assault'))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--chars', nargs='+', help='subset of output names')
parser.add_argument('--out', default=str(ROOT/'批量绑定_v1'))
args = parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])

OUT = pathlib.Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
from reaction_layer import HIT_SECONDS, BLAST_SECONDS, bullet_flinch, blast_source_time, blast_death

cm = {'Hips':'Hips','Spine':'Spine_01','Chest':'Spine_02','UpperChest':'Spine_03','Neck':'Neck','Head':'Head',
 'LeftShoulder':'Clavicle_L','LeftUpperArm':'Shoulder_L','LeftLowerArm':'Elbow_L','LeftHand':'Hand_L',
 'RightShoulder':'Clavicle_R','RightUpperArm':'Shoulder_R','RightLowerArm':'Elbow_R','RightHand':'Hand_R',
 'LeftUpperLeg':'UpperLeg_L','LeftLowerLeg':'LowerLeg_L','LeftFoot':'Ankle_L','LeftToes':'Ball_L',
 'RightUpperLeg':'UpperLeg_R','RightLowerLeg':'LowerLeg_R','RightFoot':'Ankle_R','RightToes':'Ball_R'}

def curl_fingers(dst, sides=('R','L')):
    rest = world_rest(dst)
    for side in sides:
        suffix = '.001' if side == 'R' else ''
        for prefix in ['Finger','IndexFinger','Thumb']:
            for i in range(1,5):
                n = f'{prefix}_{i:02d}'+suffix
                if n not in dst.pose.bones: continue
                pb = dst.pose.bones[n]
                angle = math.radians((45 if prefix=='Thumb' else 55) if i==1 else (50 if i<4 else 15))
                axis = rest[n].to_quaternion().inverted()@Vector((0,1 if side=='L' else -1,0))
                pb.rotation_quaternion = Quaternion(axis, angle)
    bpy.context.view_layer.update()

def arm_ik(dst, rots, side, wrist, pole):
    names = ['Shoulder_'+side,'Elbow_'+side,'Hand_'+side]; rest = world_rest(dst)
    a = dst.matrix_world@dst.pose.bones[names[0]].head
    ab = rest[names[1]].translation-rest[names[0]].translation; bc = rest[names[2]].translation-rest[names[1]].translation
    l1, l2 = ab.length, bc.length; v = wrist-a; distance = v.length
    if distance > l1+l2-.002: raise ValueError('Unreachable wrist '+side+': '+str(distance))
    direction = v.normalized(); dist = max(abs(l1-l2)+.001, min(distance, l1+l2-.002))
    along = (l1*l1-l2*l2+dist*dist)/(2*dist)
    pd = pole-a; normal = (pd-direction*pd.dot(direction)).normalized()
    elbow = a+direction*along+normal*math.sqrt(max(0,l1*l1-along*along))
    for n, restvec, newvec in [(names[0],ab,elbow-a),(names[1],bc,wrist-elbow)]:
        q = rots[n]; old = q@rest[n].to_quaternion().inverted()@restvec
        rots[n] = old.rotation_difference(newvec)@q

def rifle_hold(dst, rots, hip, gun, cfg, t, kind):
    rest = world_rest(dst)
    chest = dst.matrix_world@dst.pose.bones['Spine_03'].matrix
    delta = chest.to_quaternion()@rest['Spine_03'].to_quaternion().inverted()
    if kind == 'Fire':
        forward = delta@Vector((0,-1,0)); delta = Quaternion((0,0,1), math.atan2(forward.x,-forward.y))
    pitch = math.radians(22 if kind!='Fire' else 0)
    yaw = math.radians(25 if kind!='Fire' else 0)
    kick = 0 if kind!='Fire' else math.exp(-t*18)*math.sin(min(t/.08,1)*math.pi/2)
    q = delta@Quaternion((0,0,1),yaw)@Quaternion((1,0,0),pitch-math.radians(3)*kick)
    pos = chest.translation+delta@Vector(cfg['pos']); s = cfg['scale']
    pos += q@Vector((0,.025*kick*s,0))
    gun.matrix_world = Matrix.LocRotScale(pos, q, Vector((s,s,s)))
    wrists = {'R':gun.matrix_world@Vector(cfg['wrist_r']), 'L':gun.matrix_world@Vector(cfg['wrist_l'])}
    for side in ['R','L']:
        sign = -1 if side=='R' else 1
        pole = chest.translation+delta@Vector((sign*.55,-.05,-.38))
        arm_ik(dst, rots, side, wrists[side], pole)
        turn = Quaternion((0,1,0), math.radians(-90 if side=='R' else 180))
        rots['Hand_'+side] = q@turn@rest['Hand_'+side].to_quaternion()
    apply_world_rotations(dst, rots, hip)
    curl_fingers(dst)

def detached_rifle(dst, rots, hip, gun, cfg, crawl=False):
    hand = dst.matrix_world@dst.pose.bones['Hand_R'].matrix
    q = hand.to_quaternion()@world_rest(dst)['Hand_R'].to_quaternion().inverted()@Quaternion((0,1,0),math.pi/2)
    if crawl: q = Quaternion((0,0,1),0)
    rots['Hand_R'] = q@Quaternion((0,1,0),-math.pi/2)@world_rest(dst)['Hand_R'].to_quaternion()
    apply_world_rotations(dst, rots, hip)
    curl_fingers(dst, ('R',))
    wrist = dst.matrix_world@dst.pose.bones['Hand_R'].head
    s = cfg['scale']
    gun.matrix_world = Matrix.LocRotScale(wrist-q@Vector(cfg['carry']), q, Vector((s,s,s)))

def rigid(m):
    return Matrix.LocRotScale(m.translation, m.to_quaternion(), Vector((1,1,1)))

def melee_carry(dst, rots, hip, gun, cfg, lying=False):
    # One-hand carry: the club handle sits in the right palm. Standing clips keep
    # the shaft tilted outward (cfg['tilt']). Lying clips (crawl/death/blast)
    # override the hand rotation so the shaft lies flat on the world +Y axis,
    # keeping the corpse grounded and the club out of the floor.
    g = cfg['grip_z']
    psi = cfg['tilt']
    m = (Matrix.Translation(Vector((-g*math.sin(psi), .02+g*math.cos(psi), 0)))
         @ Matrix.Rotation(psi, 4, 'Z') @ Matrix.Rotation(math.radians(90), 4, 'X'))
    if lying:
        q_club = Vector((0, 0, 1)).rotation_difference(Vector((0, 1, 0)))
        rots['Hand_R'] = q_club@m.to_quaternion().inverted()
    apply_world_rotations(dst, rots, hip)
    curl_fingers(dst, ('R',))
    hand = rigid(dst.matrix_world@dst.pose.bones['Hand_R'].matrix)
    gun.matrix_world = hand@m

def load_weapon(mat, cfg):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(PACKS[cfg['pack']]/cfg['fbx']))
    parts = [o for o in bpy.data.objects if o not in before and o.type=='MESH']
    transforms = {o: o.matrix_world.copy() for o in parts}
    for ob in parts:
        ob.parent=None; ob.data.transform(transforms[ob]); ob.matrix_world=Matrix.Identity(4)
    bpy.ops.object.select_all(action='DESELECT')
    for ob in parts: ob.select_set(True)
    ob = parts[0]; bpy.context.view_layer.objects.active = ob; bpy.ops.object.join(); ob.name='Weapon'
    ob.data.materials.clear(); ob.data.materials.append(mat)
    for p in ob.data.polygons: p.material_index = 0
    return ob

def setup_character(fbx_path, mesh_name, tex_path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene; sc.render.fps = 30
    bpy.ops.import_scene.fbx(filepath=str(fbx_path))
    dst = next(o for o in bpy.data.objects if o.type=='ARMATURE')
    body = next(o for o in bpy.data.objects if o.type=='MESH' and o.name==mesh_name)
    for o in list(bpy.data.objects):
        if o.type=='MESH' and o!=body: bpy.data.objects.remove(o, do_unlink=True)
    dst.animation_data_clear()
    for pb in dst.pose.bones: pb.matrix_basis = Matrix.Identity(4)
    mat = bpy.data.materials.new('Atlas'); mat.use_nodes = True
    tex = mat.node_tree.nodes.new('ShaderNodeTexImage'); tex.image = bpy.data.images.load(str(tex_path)); tex.image.pack()
    bs = mat.node_tree.nodes.get('Principled BSDF'); mat.node_tree.links.new(tex.outputs['Color'], bs.inputs['Base Color'])
    bs.inputs['Roughness'].default_value = .85
    body.data.materials.clear(); body.data.materials.append(mat)
    for p in body.data.polygons: p.material_index = 0
    bpy.context.view_layer.update()
    return dst, body

def build(name, pack, fbx, mesh, weapon):
    dst, body = setup_character(PACKS[pack]/fbx, mesh, TEX[pack])
    source_integrity = {
     'vertices': len(body.data.vertices), 'bones': len(dst.data.bones),
     'weights': [[[body.vertex_groups[g.group].name, round(g.weight,8)] for g in v.groups] for v in body.data.vertices],
     'source_sha256': hashlib.sha256((PACKS[pack]/fbx).read_bytes()).hexdigest()}
    for a in bpy.data.actions: a.name = 'A::'+a.name
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(ROOT/'mocap/Soldier.glb'))
    src = next(o for o in bpy.data.objects if o not in before and o.type=='ARMATURE')
    for o in list(bpy.data.objects):
        if o not in [src, dst, body] and o.type=='MESH': bpy.data.objects.remove(o, do_unlink=True)
    soldier_actions = [a for a in bpy.data.actions if not a.name.startswith('A::')]
    for a in soldier_actions: a.name = 'A::'+a.name
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(ROOT/'mocap/ual_extract/UAL_Mannequin_skinned.glb'))
    c = next(o for o in bpy.data.objects if o not in before and o.type=='ARMATURE')
    for o in list(bpy.data.objects):
        if o not in [src, dst, body, c] and o.type=='MESH': bpy.data.objects.remove(o, do_unlink=True)
    cfg = WEAPONS[weapon]; kind = cfg['kind']
    rest = world_rest(dst); sc = bpy.context.scene; sc.render.fps = 30
    sources = {}
    for key, arm, mapping, reference in [('A',src,{'mixamorig:'+k:v for k,v in MAP.items()},'A::TPose'),('C',c,cm,'A_Tpose')]:
        bind(arm, reference); sc.frame_set(0); bpy.context.view_layer.update()
        ref = {k: arm.matrix_world@arm.pose.bones[k].matrix for k in mapping}
        left = next(k for k in mapping if mapping[k]=='Shoulder_L')
        align = Quaternion((0,0,1), math.pi if ref[left].translation.x*rest['Shoulder_L'].translation.x<0 else 0)
        sources[key] = (arm, mapping, ref, align)
    gun = load_weapon(body.data.materials[0], cfg); source_actions = set(bpy.data.actions)
    sc.render.fps = 30; sc.render.fps_base = 1.0

    def evaluate(key, action, time_s):
        arm, mapping, ref, align = sources[key]; bind(arm, action)
        frame = time_s*30; sc.frame_set(int(frame), subframe=frame-int(frame)); bpy.context.view_layer.update()
        rots = {v:(align@(arm.matrix_world@arm.pose.bones[k].matrix).to_quaternion()@ref[k].to_quaternion().inverted()@align.inverted())@rest[v].to_quaternion() for k,v in mapping.items()}
        h = next(k for k,v in mapping.items() if v=='Hips')
        current = (arm.matrix_world@arm.pose.bones[h].matrix).translation
        hip = rest['Hips'].translation.copy()
        hip.z += (current.z-ref[h].translation.z)*rest['Hips'].translation.z/ref[h].translation.z
        apply_world_rotations(dst, rots, hip)
        return rots, hip

    def min_z(objects):
        dg = bpy.context.evaluated_depsgraph_get(); z = 999
        for ob in objects:
            eo = ob.evaluated_get(dg); me = eo.to_mesh()
            z = min(z, min((eo.matrix_world@v.co).z for v in me.vertices)); eo.to_mesh_clear()
        return z

    idle_rots, idle_hip = evaluate('A','A::Idle',20/30)
    if kind=='rifle': rifle_hold(dst, idle_rots, idle_hip, gun, cfg, 0, 'Idle')
    else: melee_carry(dst, idle_rots, idle_hip, gun, cfg)
    idle_rots = {n:(dst.matrix_world@dst.pose.bones[n].matrix).to_quaternion() for n in idle_rots}

    specs = [('Idle-loop','A','A::Idle',1.966666667),('Run-loop','A','A::Run',.7),
             ('Fire',('A' if kind=='rifle' else 'C'),('A::Idle' if kind=='rifle' else 'Sword_Attack'),(.6 if kind=='rifle' else None)),
             ('Hit','A','A::Idle',HIT_SECONDS),('HitHeavy','C','Death01',BLAST_SECONDS),
             ('Crawl-loop','C','Crawl_Fwd',None),('Death','C','Death01',None)]
    poses = {}; stats = {}; ground_target = .004
    for active, key, action, duration in specs:
        if duration is None: duration = float(bpy.data.actions[action].frame_range[1])/30
        count = round(duration*30); frames = []
        for i in range(count+1):
            t = i/30
            sample = t if active in ['Idle-loop','Run-loop','Crawl-loop','Death','Fire'] and not (active=='Fire' and kind=='rifle') else 20/30
            if active=='Fire' and kind=='rifle': sample = 20/30
            if active=='HitHeavy': sample = blast_source_time(t)
            rots, hip = evaluate(key, action, sample)
            if active=='Hit':
                bullet_flinch(rots, t); apply_world_rotations(dst, rots, hip)
            if active=='HitHeavy':
                rots, hip = blast_death(rots, hip, idle_rots, idle_hip, t)
                apply_world_rotations(dst, rots, hip)
            if kind=='rifle':
                if active in ['Crawl-loop','Death','HitHeavy']: detached_rifle(dst, rots, hip, gun, cfg, crawl=(active=='Crawl-loop'))
                else: rifle_hold(dst, rots, hip, gun, cfg, t, active.replace('-loop',''))
            else:
                melee_carry(dst, rots, hip, gun, cfg, lying=active in ['Crawl-loop','Death','HitHeavy'])
            z = min_z([body]); all_z = min_z([body, gun])
            frames.append({'basis':{p.name:p.matrix_basis.copy() for p in dst.pose.bones},'gun':gun.matrix_world.copy(),'min_z':z,'all_min_z':all_z})
        base = ground_target-min(f['min_z'] for f in frames)
        base_all = ground_target-min(f['all_min_z'] for f in frames)
        lying = active in ['Crawl-loop','Death','HitHeavy']
        for f in frames:
            if lying: dz = max(ground_target-f['all_min_z'], 0)
            elif kind=='rifle': dz = base
            else: dz = max(base, base_all)
            for pb in dst.pose.bones: pb.matrix_basis = f['basis'][pb.name]
            bpy.context.view_layer.update()
            hipworld = dst.matrix_world@dst.pose.bones['Hips'].matrix
            hipworld.translation.z += dz
            dst.pose.bones['Hips'].matrix = dst.matrix_world.inverted()@hipworld; bpy.context.view_layer.update()
            f['basis'] = {p.name:p.matrix_basis.copy() for p in dst.pose.bones}
            f['gun'].translation.z += dz
        if active.endswith('-loop'): frames[-1] = {'basis':{n:m.copy() for n,m in frames[0]['basis'].items()},'gun':frames[0]['gun'].copy(),'min_z':frames[0]['min_z'],'all_min_z':frames[0]['all_min_z']}
        poses[active] = frames
        stats[active] = {'duration':count/30,'samples':len(frames),'source':action,'ground_offset':base,
           'pose_layer':'authored rifle recoil' if active=='Fire' and kind=='rifle' else 'UAL Sword_Attack melee swing' if active=='Fire' else 'fast bullet impact and recovery' if active=='Hit' else 'blast launch, airborne fall, landing and terminal dead hold' if active=='HitHeavy' else 'two-hand rifle grip IK' if kind=='rifle' and active in ['Idle-loop','Run-loop'] else 'right hand melee carry' if kind=='melee' else 'right hand rifle carry',
           'loop':active.endswith('-loop')}
        print('SAMPLED',name,active,stats[active],flush=True)

    for ob in [src,c]: bpy.data.objects.remove(ob, do_unlink=True)
    for act in source_actions:
        if act.name in bpy.data.actions: bpy.data.actions.remove(act)
    dst.name='Skeleton'; body.name=name+'_Body'
    ad = dst.animation_data_create()
    for name_a, frames in poses.items():
        act = bpy.data.actions.new(name_a); act.use_fake_user=True; ad.action=act
        for i, frame in enumerate(frames):
            for pb in dst.pose.bones:
                pb.matrix_basis = frame['basis'][pb.name]
                pb.keyframe_insert('rotation_quaternion', frame=i, group=pb.name)
                if pb.name=='Hips': pb.keyframe_insert('location', frame=i, group=pb.name)
        for fc in act.layers[0].strips[0].channelbag(act.slots[0]).fcurves:
            for k in fc.keyframe_points: k.interpolation='LINEAR'
        print('BAKED',name,name_a,flush=True)

    frame = poses['Idle-loop'][0]
    bind(dst,'Idle-loop'); sc.frame_set(0); bpy.context.view_layer.update()
    hand_pose = rigid(dst.matrix_world@dst.pose.bones['Hand_R'].matrix)
    for pb in dst.pose.bones: pb.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()
    hand_rest = rigid(dst.matrix_world@dst.pose.bones['Hand_R'].matrix)
    gun.data.transform(hand_rest@hand_pose.inverted()@frame['gun'])
    gun.matrix_world = Matrix.Identity(4)
    group = gun.vertex_groups.new(name='Hand_R'); group.add(list(range(len(gun.data.vertices))),1.0,'REPLACE')
    mod = gun.modifiers.new('RigidHandAttachment','ARMATURE'); mod.object=dst
    bpy.context.view_layer.update()
    for ob in list(bpy.data.objects):
        if ob not in [dst, body, gun]: bpy.data.objects.remove(ob, do_unlink=True)
    for ob in bpy.context.selected_objects: ob.select_set(False)
    for ob in [dst, body, gun]: ob.select_set(True)
    bpy.context.view_layer.objects.active = dst
    bpy.ops.export_scene.gltf(filepath=str(OUT/(name+'.glb')), export_format='GLB', use_selection=True,
        export_animation_mode='ACTIONS', export_animations=True, export_skins=True, export_yup=True)
    (OUT/(name+'_build.json')).write_text(json.dumps(stats, indent=2), encoding='utf8')
    (OUT/(name+'_integrity.json')).write_text(json.dumps(source_integrity, separators=(',',':'))+'\n', encoding='utf8')
    return stats

if __name__ == '__main__':
    selected = CHARACTERS
    if args.chars:
        wanted = set(args.chars); selected = [c for c in CHARACTERS if c[0] in wanted]
    report = {}
    for out, pack, fbx, mesh, weapon in selected:
        print('BUILD_START', out, flush=True)
        report[out] = build(out, pack, fbx, mesh, weapon)
    (OUT/'build_report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf8')
    print('BATCH_BUILD_DONE', list(report), flush=True)

