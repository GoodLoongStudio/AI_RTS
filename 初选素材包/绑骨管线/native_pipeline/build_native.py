"""Native Synty skeleton animation baseline. Sources and bind weights are preserved."""
import sys,pathlib,math,json,hashlib,argparse
sys.path.insert(0,str(pathlib.Path(__file__).parent))
import bpy
from mathutils import Vector,Matrix,Quaternion
from baseline import setup,bind,world_rest,apply_world_rotations,MAP,OUT,ROOT,ASSETS,stage
from weapon_layer import load_weapon,rifle_hold,curl_fingers
from reaction_layer import HIT_SECONDS,BLAST_SECONDS,bullet_flinch,blast_source_time,blast_death

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--review',action='store_true',help='Render selected frames after baking')
args=parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
src,dst,body=setup();sc=bpy.context.scene;sc.render.fps=30
source_integrity={
 'vertices':len(body.data.vertices),'bones':len(dst.data.bones),
 'weights':[[[body.vertex_groups[g.group].name,round(g.weight,8)] for g in v.groups] for v in body.data.vertices],
 'source_sha256':hashlib.sha256((ASSETS/'Characters.fbx').read_bytes()).hexdigest()}
for a in bpy.data.actions:a.name='A::'+a.name
before=set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=str(ROOT/'mocap/ual_extract/UAL_Mannequin_skinned.glb'))
c=next(o for o in bpy.data.objects if o not in before and o.type=='ARMATURE')
for o in list(bpy.data.objects):
    if o not in before and o.type=='MESH':bpy.data.objects.remove(o,do_unlink=True)
cm={'Hips':'Hips','Spine':'Spine_01','Chest':'Spine_02','UpperChest':'Spine_03','Neck':'Neck','Head':'Head',
'LeftShoulder':'Clavicle_L','LeftUpperArm':'Shoulder_L','LeftLowerArm':'Elbow_L','LeftHand':'Hand_L',
'RightShoulder':'Clavicle_R','RightUpperArm':'Shoulder_R','RightLowerArm':'Elbow_R','RightHand':'Hand_R',
'LeftUpperLeg':'UpperLeg_L','LeftLowerLeg':'LowerLeg_L','LeftFoot':'Ankle_L','LeftToes':'Ball_L',
'RightUpperLeg':'UpperLeg_R','RightLowerLeg':'LowerLeg_R','RightFoot':'Ankle_R','RightToes':'Ball_R'}
rest=world_rest(dst);sc.render.fps=30
sources={}
for key,arm,mapping,reference in [('A',src,{'mixamorig:'+k:v for k,v in MAP.items()},'A::TPose'),('C',c,cm,'A_Tpose')]:
    bind(arm,reference);sc.frame_set(0);bpy.context.view_layer.update()
    ref={k:arm.matrix_world@arm.pose.bones[k].matrix for k in mapping}
    left=next(k for k in mapping if mapping[k]=='Shoulder_L')
    align=Quaternion((0,0,1),math.pi if ref[left].translation.x*rest['Shoulder_L'].translation.x<0 else 0)
    sources[key]=(arm,mapping,ref,align)
gun=load_weapon(body.data.materials[0]);source_actions=set(bpy.data.actions)
# FBX import may overwrite scene FPS; output timing is an explicit contract.
sc.render.fps=30;sc.render.fps_base=1.0

def evaluate(key,action,time_s):
    arm,mapping,ref,align=sources[key];bind(arm,action)
    frame=time_s*30;sc.frame_set(int(frame),subframe=frame-int(frame));bpy.context.view_layer.update()
    rots={v:(align@(arm.matrix_world@arm.pose.bones[k].matrix).to_quaternion()@ref[k].to_quaternion().inverted()@align.inverted())@rest[v].to_quaternion() for k,v in mapping.items()}
    h=next(k for k,v in mapping.items() if v=='Hips')
    current=(arm.matrix_world@arm.pose.bones[h].matrix).translation
    hip=rest['Hips'].translation.copy()
    hip.z+=(current.z-ref[h].translation.z)*rest['Hips'].translation.z/ref[h].translation.z
    apply_world_rotations(dst,rots,hip)
    return rots,hip

def min_z(objects):
    dg=bpy.context.evaluated_depsgraph_get();z=999
    for ob in objects:
        eo=ob.evaluated_get(dg);me=eo.to_mesh()
        z=min(z,min((eo.matrix_world@v.co).z for v in me.vertices));eo.to_mesh_clear()
    return z

def detached_hand_weapon(rots,hip):
    # Carry rifle in right hand during prone locomotion and death; it stays a rigid prop.
    hand=dst.matrix_world@dst.pose.bones['Hand_R'].matrix
    q=hand.to_quaternion()@rest['Hand_R'].to_quaternion().inverted()@Quaternion((0,1,0),math.pi/2)
    # Prone carry points muzzle forward with the body's horizontal heading.
    if active=='Crawl-loop':q=Quaternion((0,0,1),0)
    rots['Hand_R']=q@Quaternion((0,1,0),-math.pi/2)@rest['Hand_R'].to_quaternion()
    apply_world_rotations(dst,rots,hip);curl_fingers(dst,('R',))
    wrist=dst.matrix_world@dst.pose.bones['Hand_R'].head
    gun.matrix_world=Matrix.LocRotScale(wrist-q@Vector((-.048,.020,.0144)),q,Vector((.8,.8,.8)))

idle_rots,idle_hip=evaluate('A','A::Idle',20/30)
rifle_hold(dst,idle_rots,idle_hip,gun,0,'Idle')
idle_rots={n:(dst.matrix_world@dst.pose.bones[n].matrix).to_quaternion() for n in idle_rots}

specs=[('Idle-loop','A','A::Idle',1.966666667),('Run-loop','A','A::Run',.7),
       ('Fire','A','A::Idle',.6),('Hit','A','A::Idle',HIT_SECONDS),('HitHeavy','C','Death01',BLAST_SECONDS),
       ('Crawl-loop','C','Crawl_Fwd',None),('Death','C','Death01',None)]
poses={};stats={};ground_target=.004
for active,key,action,duration in specs:
    if duration is None:duration=float(bpy.data.actions[action].frame_range[1])/30
    count=round(duration*30);frames=[]
    for i in range(count+1):
        t=i/30
        sample=t if active in ['Idle-loop','Run-loop','Crawl-loop','Death'] else 20/30
        if active=='HitHeavy':sample=blast_source_time(t)
        rots,hip=evaluate(key,action,sample)
        if active=='Hit':
            bullet_flinch(rots,t)
            apply_world_rotations(dst,rots,hip)
        if active=='HitHeavy':
            rots,hip=blast_death(rots,hip,idle_rots,idle_hip,t)
            apply_world_rotations(dst,rots,hip)
        if active in ['Crawl-loop','Death','HitHeavy']:
            detached_hand_weapon(rots,hip)
        else:rifle_hold(dst,rots,hip,gun,t,active.replace('-loop',''))
        # The body controls grounding. Weapon clearance is recorded independently.
        z=min_z([body]);all_z=min_z([body,gun])
        frames.append({'basis':{p.name:p.matrix_basis.copy() for p in dst.pose.bones},'gun':gun.matrix_world.copy(),'min_z':z,'all_min_z':all_z})
    # Constant height correction on standing/running preserves the flight phase.
    base=ground_target-min(f['min_z'] for f in frames)
    for f in frames:
        dz=base if active not in ['Crawl-loop','Death','HitHeavy'] else max(ground_target-f['all_min_z'],0)
        for pb in dst.pose.bones:pb.matrix_basis=f['basis'][pb.name]
        bpy.context.view_layer.update()
        hipworld=dst.matrix_world@dst.pose.bones['Hips'].matrix
        hipworld.translation.z+=dz
        dst.pose.bones['Hips'].matrix=dst.matrix_world.inverted()@hipworld;bpy.context.view_layer.update()
        f['basis']={p.name:p.matrix_basis.copy() for p in dst.pose.bones}
        f['gun'].translation.z+=dz
    if active.endswith('-loop'):frames[-1]={'basis':{n:m.copy() for n,m in frames[0]['basis'].items()},'gun':frames[0]['gun'].copy(),'min_z':frames[0]['min_z'],'all_min_z':frames[0]['all_min_z']}
    poses[active]=frames
    stats[active]={'duration':count/30,'samples':len(frames),'source':action,'ground_offset':base,
       'pose_layer':'authored rifle recoil' if active=='Fire' else 'fast bullet impact and recovery' if active=='Hit' else 'blast launch, airborne fall, landing and terminal dead hold' if active=='HitHeavy' else 'rifle grip IK' if active in ['Idle-loop','Run-loop'] else 'right hand rifle carry',
       'loop':active.endswith('-loop')}
    print('SAMPLED',active,stats[active],flush=True)

# Delete source objects/actions before producing the deliverable.
for ob in [src,c]:bpy.data.objects.remove(ob,do_unlink=True)
for act in source_actions:
    if act.name in bpy.data.actions:bpy.data.actions.remove(act)
dst.name='InfantrySkeleton';body.name='InfantryBody'
ad=dst.animation_data_create()
for name,frames in poses.items():
    act=bpy.data.actions.new(name);act.use_fake_user=True;ad.action=act
    for i,frame in enumerate(frames):
        for pb in dst.pose.bones:
            pb.matrix_basis=frame['basis'][pb.name]
            pb.keyframe_insert('rotation_quaternion',frame=i,group=pb.name)
            if pb.name=='Hips':pb.keyframe_insert('location',frame=i,group=pb.name)
    for fc in act.layers[0].strips[0].channelbag(act.slots[0]).fcurves:
        for k in fc.keyframe_points:k.interpolation='LINEAR'
    print('BAKED',name,flush=True)

# Rigid prop uses one hand weight: exact attachment without bone-parent export sampling.
frame=poses['Idle-loop'][0]
bind(dst,'Idle-loop');sc.frame_set(0);bpy.context.view_layer.update()
hand_pose=dst.matrix_world@dst.pose.bones['Hand_R'].matrix
hand_rest=dst.matrix_world@dst.data.bones['Hand_R'].matrix_local
gun.data.transform(hand_rest@hand_pose.inverted()@frame['gun'])
gun.matrix_world=Matrix.Identity(4)
group=gun.vertex_groups.new(name='Hand_R');group.add(list(range(len(gun.data.vertices))),1.0,'REPLACE')
mod=gun.modifiers.new('RigidHandAttachment','ARMATURE');mod.object=dst
bpy.context.view_layer.update()
for ob in list(bpy.data.objects):
    if ob not in [dst,body,gun]:bpy.data.objects.remove(ob,do_unlink=True)

for ob in bpy.context.selected_objects:ob.select_set(False)
for ob in [dst,body,gun]:ob.select_set(True)
bpy.context.view_layer.objects.active=dst
glb=OUT/'Infantry_native_v3.glb'
bpy.ops.export_scene.gltf(filepath=str(glb),export_format='GLB',use_selection=True,export_animation_mode='ACTIONS',export_animations=True,export_skins=True,export_yup=True)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'Infantry_native_v3.blend'))
(OUT/'native_build.json').write_text(json.dumps(stats,indent=2),encoding='utf8')
(OUT/'source_integrity.json').write_text(json.dumps(source_integrity,separators=(',',':'))+'\n',encoding='utf8')

if args.review:
    cam=stage()
    for name,frames in poses.items():
        bind(dst,name)
        for i in sorted(set([0,len(frames)//4,len(frames)//2,3*len(frames)//4,len(frames)-1])):
            sc.frame_set(i);bpy.context.view_layer.update()
            sc.render.filepath=str(OUT/f'v3_{name}_{i+1:03}.png');bpy.ops.render.render(write_still=True)
print('NATIVE_BUILD_DONE',flush=True)
