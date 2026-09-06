import bpy, pathlib, math, json
from mathutils import Vector, Quaternion, Matrix

ROOT=pathlib.Path(__file__).resolve().parent.parent
ASSETS=ROOT.parent/'工程/预览渲染工程/assets/4006_科幻世界/PolygonSciFiWorlds/Models'
OUT=ROOT/'4006/原厂骨架_v3'
OUT.mkdir(parents=True,exist_ok=True)
MAP={'Hips':'Hips','Spine':'Spine_01','Spine1':'Spine_02','Spine2':'Spine_03','Neck':'Neck','Head':'Head',
 'LeftShoulder':'Clavicle_L','LeftArm':'Shoulder_L','LeftForeArm':'Elbow_L','LeftHand':'Hand_L',
 'RightShoulder':'Clavicle_R','RightArm':'Shoulder_R','RightForeArm':'Elbow_R','RightHand':'Hand_R',
 'LeftUpLeg':'UpperLeg_L','LeftLeg':'LowerLeg_L','LeftFoot':'Ankle_L','LeftToeBase':'Ball_L',
 'RightUpLeg':'UpperLeg_R','RightLeg':'LowerLeg_R','RightFoot':'Ankle_R','RightToeBase':'Ball_R'}

def bind(arm,act):
    ad=arm.animation_data or arm.animation_data_create()
    for t in ad.nla_tracks:t.mute=True
    ad.action=bpy.data.actions[act]
    if ad.action.slots:ad.action_slot=ad.action.slots[0]
    return ad.action

def setup():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc=bpy.context.scene; sc.render.fps=30
    bpy.ops.import_scene.gltf(filepath=str(ROOT/'mocap/Soldier.glb'))
    src=next(o for o in bpy.data.objects if o.type=='ARMATURE')
    for o in list(bpy.data.objects):
        if o.type=='MESH':bpy.data.objects.remove(o,do_unlink=True)
    bpy.ops.import_scene.fbx(filepath=str(ASSETS/'Characters.fbx'))
    dst=next(o for o in bpy.data.objects if o.type=='ARMATURE' and o!=src)
    mesh=next(o for o in bpy.data.objects if o.type=='MESH' and 'Soldier_Male_01' in o.name)
    for o in list(bpy.data.objects):
        if o.type=='MESH' and o!=mesh:bpy.data.objects.remove(o,do_unlink=True)
    dst.animation_data_clear()
    for pb in dst.pose.bones:pb.matrix_basis=Matrix.Identity(4)
    mat=bpy.data.materials.new('SoldierAtlas');mat.use_nodes=True
    tex=mat.node_tree.nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(ASSETS/'PolygonScifiWorlds_Texture_01_A.png'));tex.image.pack()
    bs=mat.node_tree.nodes.get('Principled BSDF');mat.node_tree.links.new(tex.outputs['Color'],bs.inputs['Base Color']);bs.inputs['Roughness'].default_value=.85
    mesh.data.materials.clear();mesh.data.materials.append(mat)
    for p in mesh.data.polygons:p.material_index=0
    bpy.context.view_layer.update()
    return src,dst,mesh

def stage():
    sc=bpy.context.scene;sc.render.engine='BLENDER_EEVEE';sc.render.resolution_x=480;sc.render.resolution_y=560;sc.render.resolution_percentage=100
    sc.render.image_settings.file_format='PNG';sc.render.film_transparent=False
    sc.world=bpy.data.worlds.new('AuditWorld');sc.world.use_nodes=True;sc.world.node_tree.nodes['Background'].inputs[0].default_value=(.18,.20,.23,1)
    sc.world.node_tree.nodes['Background'].inputs[1].default_value=.4
    for loc,energy,size in [((3,-4,6),700,4),((-3,1,4),450,3)]:
        data=bpy.data.lights.new('Softbox','AREA');data.energy=energy;data.shape='DISK';data.size=size
        ob=bpy.data.objects.new('Softbox',data);sc.collection.objects.link(ob);ob.location=loc;ob.rotation_euler=(Vector((0,0,1))-ob.location).to_track_quat('-Z','Y').to_euler()
    bpy.ops.mesh.primitive_plane_add(size=200);ground=bpy.context.object;ground.name='AuditGround'
    mat=bpy.data.materials.new('Ground');mat.diffuse_color=(.18,.20,.23,1);ground.data.materials.append(mat)
    cam=bpy.data.objects.new('AuditCamera',bpy.data.cameras.new('AuditCamera'));sc.collection.objects.link(cam);sc.camera=cam
    cam.data.type='ORTHO';cam.data.ortho_scale=2.4
    cam.location=(2.6,-4.6,2.2);cam.rotation_euler=(Vector((0,0,.85))-cam.location).to_track_quat('-Z','Y').to_euler()
    return cam

def world_rest(arm):return {b.name:arm.matrix_world@b.matrix_local for b in arm.data.bones}

def apply_world_rotations(dst,rots,hip_pos):
    # Solve only rotational channels; each joint keeps its own bind offset.
    rest=world_rest(dst); rw=dst.matrix_world.to_quaternion()
    solved={}
    for pb in dst.pose.bones:
        n=pb.name;p=pb.parent.name if pb.parent else None
        rp=rest[p].to_quaternion() if p else rw
        rq=rp.inverted()@rest[n].to_quaternion()
        pq=solved[p] if p else rw
        q=rots.get(n,pq@rq)
        pb.rotation_mode='QUATERNION';pb.rotation_quaternion=rq.inverted()@pq.inverted()@q
        pb.location=(0,0,0);pb.scale=(1,1,1);solved[n]=q
    bpy.context.view_layer.update()
    hip=dst.pose.bones['Hips']
    mw=dst.matrix_world@hip.matrix
    off=hip_pos-mw.translation
    parent=dst.matrix_world@hip.parent.matrix if hip.parent else dst.matrix_world
    restrel=hip.parent.bone.matrix_local.inverted()@hip.bone.matrix_local if hip.parent else hip.bone.matrix_local
    hip.location=(parent@restrel).to_3x3().inverted()@off
    bpy.context.view_layer.update()
