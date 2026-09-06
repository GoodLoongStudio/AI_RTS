import bpy, math
from mathutils import Vector, Quaternion, Matrix
from baseline import ASSETS, world_rest, apply_world_rotations

def load_weapon(mat):
    before=set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(ASSETS/'SM_Wep_Assault_01.fbx'))
    parts=[o for o in bpy.data.objects if o not in before and o.type=='MESH']
    transforms={o:o.matrix_world.copy() for o in parts}
    for ob in parts:
        ob.parent=None;ob.data.transform(transforms[ob]);ob.matrix_world=Matrix.Identity(4)
    bpy.ops.object.select_all(action='DESELECT')
    for ob in parts:ob.select_set(True)
    ob=parts[0];bpy.context.view_layer.objects.active=ob;bpy.ops.object.join();ob.name='Rifle'
    ob.data.materials.clear();ob.data.materials.append(mat)
    for p in ob.data.polygons:p.material_index=0
    return ob

def arm_ik(dst,rots,side,wrist,pole):
    names=['Shoulder_'+side,'Elbow_'+side,'Hand_'+side];rest=world_rest(dst)
    a=dst.matrix_world@dst.pose.bones[names[0]].head
    ab=rest[names[1]].translation-rest[names[0]].translation;bc=rest[names[2]].translation-rest[names[1]].translation
    l1,l2=ab.length,bc.length;v=wrist-a;distance=v.length
    if distance>l1+l2-.002:raise ValueError('Unreachable wrist '+side+': '+str(distance))
    direction=v.normalized();dist=max(abs(l1-l2)+.001,min(distance,l1+l2-.002))
    along=(l1*l1-l2*l2+dist*dist)/(2*dist)
    pd=pole-a;normal=(pd-direction*pd.dot(direction)).normalized()
    elbow=a+direction*along+normal*math.sqrt(max(0,l1*l1-along*along))
    for n,restvec,newvec in [(names[0],ab,elbow-a),(names[1],bc,wrist-elbow)]:
        q=rots[n];old=q@rest[n].to_quaternion().inverted()@restvec
        rots[n]=old.rotation_difference(newvec)@q
    return distance

def rifle_hold(dst,rots,hip,gun,t,kind):
    rest=world_rest(dst)
    chest=dst.matrix_world@dst.pose.bones['Spine_03'].matrix
    delta=chest.to_quaternion()@rest['Spine_03'].to_quaternion().inverted()
    if kind=='Fire':
        forward=delta@Vector((0,-1,0));delta=Quaternion((0,0,1),math.atan2(forward.x,-forward.y))
    pitch=math.radians(22 if kind!='Fire' else 0)
    yaw=math.radians(25 if kind!='Fire' else 0)
    kick=0 if kind!='Fire' else math.exp(-t*18)*math.sin(min(t/.08,1)*math.pi/2)
    q=delta@Quaternion((0,0,1),yaw)@Quaternion((1,0,0),pitch-math.radians(3)*kick)
    pos=chest.translation+delta@Vector((-.10,-.24,-.11 if kind!='Fire' else .10))
    pos+=q@Vector((0,.025*kick,0))
    gun.matrix_world=Matrix.LocRotScale(pos,q,Vector((.8,.8,.8)))
    wrists={'R':gun.matrix_world@Vector((-.060,.025,.018)), 'L':gun.matrix_world@Vector((.11,-.29,-.025))}
    for side in ['R','L']:
        sign=-1 if side=='R' else 1
        pole=chest.translation+delta@Vector((sign*.55,-.05,-.38))
        arm_ik(dst,rots,side,wrists[side],pole)
        turn=Quaternion((0,1,0),math.radians(-90 if side=='R' else 180))
        rots['Hand_'+side]=q@turn@rest['Hand_'+side].to_quaternion()
    apply_world_rotations(dst,rots,hip)
    curl_fingers(dst)
    return wrists

def curl_fingers(dst,sides=('R','L')):
    rest=world_rest(dst)
    # Curl each phalanx around the palm's transverse axis; handedness comes from the bind frame.
    for side in sides:
        suffix='.001' if side=='R' else ''
        hand='Hand_'+side
        for prefix in ['Finger','IndexFinger','Thumb']:
            for i in range(1,5):
                n=f'{prefix}_{i:02d}'+suffix
                if n not in dst.pose.bones:continue
                pb=dst.pose.bones[n]
                angle=math.radians((45 if prefix=='Thumb' else 55) if i==1 else (50 if i<4 else 15))
                axis=rest[n].to_quaternion().inverted()@Vector((0,1 if side=='L' else -1,0))
                pb.rotation_quaternion=Quaternion(axis,angle)
    bpy.context.view_layer.update()
