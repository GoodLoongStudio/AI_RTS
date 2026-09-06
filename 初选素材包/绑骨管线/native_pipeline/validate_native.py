"""Reimport the actual deliverable; check skin preservation, ground clearance and rig motion."""
import sys,pathlib,json,math,bpy
sys.path.insert(0,str(pathlib.Path(__file__).parent))
from mathutils import Vector
from baseline import OUT,bind

CLIPS=['Idle-loop','Run-loop','Fire','Hit','HitHeavy','Crawl-loop','Death']
failures=[]
def check(ok,message):
    print(('PASS ' if ok else 'FAIL ')+message,flush=True)
    if not ok:failures.append(message)

def measure(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps=30
    # Import helper widgets have no place in an asset validation scene.
    for o in list(bpy.data.objects):bpy.data.objects.remove(o,do_unlink=True)
    if path.suffix=='.blend':bpy.ops.wm.open_mainfile(filepath=str(path))
    else:bpy.ops.import_scene.gltf(filepath=str(path))
    arm=next(o for o in bpy.data.objects if o.type=='ARMATURE')
    meshes=[o for o in bpy.data.objects if o.type=='MESH' and o.name in ['InfantryBody','Rifle']]
    check(len(meshes)==2,path.suffix+' contains the body and complete rifle')
    check(len(arm.data.bones)==50,path.suffix+' keeps 50 native bones')
    if path.suffix=='.blend':
        src=json.loads((OUT/'source_integrity.json').read_text(encoding='utf8'))
        body=next(o for o in meshes if o.name=='InfantryBody')
        weights=[[[body.vertex_groups[g.group].name,round(g.weight,8)] for g in v.groups] for v in body.data.vertices]
        check(weights==src['weights'],'original body vertex weights are unchanged')
    result={};first_gun_local=None
    for name in CLIPS:
        act=bind(arm,name);rows=[]
        expected=json.loads((OUT/'native_build.json').read_text())[name]['duration']
        actual=(act.frame_range[1]-act.frame_range[0])/bpy.context.scene.render.fps
        check(abs(expected-actual)<.0001,f'{path.suffix} {name} duration {actual:.5f}s equals {expected:.5f}s')
        for f in range(round(act.frame_range[0]),round(act.frame_range[1])+1):
            bpy.context.scene.frame_set(f);bpy.context.view_layer.update()
            deps=bpy.context.evaluated_depsgraph_get()
            row={'joints':{n:list(arm.matrix_world@p.head) for n,p in arm.pose.bones.items()},
                 'quaternions':{p.name:list(p.rotation_quaternion) for p in arm.pose.bones},'bounds':{}}
            hand=arm.matrix_world@arm.pose.bones['Hand_R'].matrix
            for ob in meshes:
                eo=ob.evaluated_get(deps);em=eo.to_mesh();pts=[eo.matrix_world@v.co for v in em.vertices];eo.to_mesh_clear()
                row['bounds'][ob.name]=[min(p[i] for p in pts) for i in range(3)]+[max(p[i] for p in pts) for i in range(3)]
                if ob.name=='Rifle':
                    # Rotational attachment invariant, measured on actual deformed vertices.
                    local=[hand.to_quaternion().inverted()@(p-hand.translation) for p in pts]
                    if first_gun_local is None:first_gun_local=local
                    row['rigid_error']=max((a-b).length for a,b in zip(local,first_gun_local))
            rows.append(row)
        result[name]=rows
        z=min(r['bounds'][ob][2] for r in rows for ob in ['InfantryBody','Rifle'])
        rigid=max(r['rigid_error'] for r in rows)
        check(z>=-.0001,f'{path.suffix} {name} no mesh below ground: {z:.6f} m')
        check(rigid<.0002,f'{path.suffix} {name} rifle remains rigid on right hand: {rigid:.7f} m')
        h=[Vector(r['joints']['Hips']) for r in rows]
        horizontal=max(Vector((v.x-h[0].x,v.y-h[0].y,0)).length for v in h)
        if name=='HitHeavy':
            check(1.8<horizontal<2.5,f'{path.suffix} blast has deliberate backward travel: {horizontal:.3f} m')
            lift=max(v.z for v in h)-h[0].z
            check(lift>.4,f'{path.suffix} blast hip rises before falling: {lift:.3f} m')
            clearance=max(r['bounds']['InfantryBody'][2] for r in rows)
            check(clearance>.3,f'{path.suffix} blast whole body leaves the ground: {clearance:.3f} m')
            check(rows[-1]['joints']['Head'][2]<.45 and rows[-1]['joints']['Hips'][2]<.35,
                  f'{path.suffix} blast finishes lying dead')
            hold=max((Vector(r['joints'][n])-Vector(rows[-1]['joints'][n])).length for r in rows[-10:] for n in rows[-1]['joints'])
            check(hold<.0001,f'{path.suffix} blast terminal pose holds without standing up: {hold:.7f} m')
        else:
            check(horizontal<.0001,f'{path.suffix} {name} no horizontal root drift')
        if name=='Hit':
            from mathutils import Quaternion
            angles=[Quaternion(r['quaternions']['Spine_03']).rotation_difference(Quaternion(rows[0]['quaternions']['Spine_03'])).angle for r in rows]
            peak=max(range(len(angles)),key=angles.__getitem__)
            check(peak<=2 and max(angles)>.05,f'{path.suffix} bullet impact peaks within two frames: frame {peak}')
            check(angles[-1]<.0001,f'{path.suffix} bullet flinch recovers to the starting pose')
        if name.endswith('-loop'):
            seam=max((Vector(rows[0]['joints'][n])-Vector(rows[-1]['joints'][n])).length for n in rows[0]['joints'])
            check(seam<.0001,f'{path.suffix} {name} all joint positions close at loop seam: {seam:.7f} m')
            if name=='Crawl-loop':
                hip_step=max((h[i]-h[i-1]).length for i in range(1,len(h)))
                check(hip_step<.04,f'{path.suffix} Crawl no old 0.177 m root jump: max step {hip_step:.5f} m')
        movement=max((Vector(r['joints'][n])-Vector(rows[0]['joints'][n])).length for r in rows for n in rows[0]['joints'])
        check(movement>.0001,f'{path.suffix} {name} measured joint movement {movement:.5f} m')
    return result

a=measure(OUT/'Infantry_native_v3.blend');b=measure(OUT/'Infantry_native_v3.glb');summary={}
for name in CLIPS:
    check(len(a[name])==len(b[name]),name+' reimport preserves sample count')
    err=max((Vector(x['joints'][n])-Vector(y['joints'][n])).length for x,y in zip(a[name],b[name]) for n in x['joints'])
    bounds=max(abs(u-v) for x,y in zip(a[name],b[name]) for ob in x['bounds'] for u,v in zip(x['bounds'][ob],y['bounds'][ob]))
    check(err<.0001,name+f' exported joint error {err:.7f} m')
    check(bounds<.0002,name+f' exported skinned bounds error {bounds:.7f} m')
    summary[name]={'samples':len(b[name]),'joint_export_error_m':err,'mesh_bounds_export_error_m':bounds,
        'body_min_z_m':min(r['bounds']['InfantryBody'][2] for r in b[name]),
        'rifle_min_z_m':min(r['bounds']['Rifle'][2] for r in b[name]),
        'rigid_hand_error_m':max(r['rigid_error'] for r in b[name])}
(OUT/'validation.json').write_text(json.dumps({'passed':not failures,'failures':failures,'clips':summary},indent=2),encoding='utf8')
if failures:raise RuntimeError('Native animation validation failed: '+str(failures))
print('NATIVE_VALIDATION_PASS',flush=True)
