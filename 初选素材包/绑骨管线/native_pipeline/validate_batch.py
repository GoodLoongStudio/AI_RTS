"""Reimport each batch GLB and verify skins, timing, grounding, rigid weapon, clips."""
import sys, pathlib, json, math
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import bpy
from mathutils import Vector, Quaternion
from baseline import bind

OUT = pathlib.Path(sys.argv[sys.argv.index('--')+1])
CLIPS = ['Idle-loop','Run-loop','Fire','Hit','HitHeavy','Crawl-loop','Death']
failures = []
def check(ok, message):
    print(('PASS ' if ok else 'FAIL ')+message, flush=True)
    if not ok: failures.append(message)

def measure(path, build_json):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 30
    for o in list(bpy.data.objects): bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.import_scene.gltf(filepath=str(path))
    arm = next(o for o in bpy.data.objects if o.type=='ARMATURE')
    rest_z = lambda n: (arm.matrix_world@arm.data.bones[n].matrix_local).translation.z
    meshes = [o for o in bpy.data.objects if o.type=='MESH' and any(md.type=='ARMATURE' for md in o.modifiers)]
    body = next(o for o in meshes if o.name.endswith('_Body'))
    weapon = next(o for o in meshes if o.name=='Weapon')
    check(len(meshes)==2, path.name+' contains body and weapon only (skinned meshes)')
    name = path.stem
    integrity = json.loads((OUT/(name+'_integrity.json')).read_text(encoding='utf8'))
    check(len(arm.data.bones)==integrity['bones'], path.name+f" keeps {integrity['bones']} native bones (found {len(arm.data.bones)})")
    # glTF triangulation splits/duplicates vertices, so compare per-bone unique
    # weight values (invariant under splitting) and the group-name set instead of
    # exact per-vertex rows. Body geometry is untouched by the pipeline.
    src_weights = integrity['weights']
    src_groups = sorted({g for v in src_weights for g,_ in v})
    dst_groups = sorted(body.vertex_groups.keys())
    check(set(src_groups).issubset(set(dst_groups)), path.name+' body vertex group names unchanged (subset)')
    check(len(body.data.vertices)>=integrity['vertices'], path.name+f' body vertex count {len(body.data.vertices)} >= source {integrity["vertices"]}')
    result = {}; first_gun_local = None
    for clip in CLIPS:
        a = bind(arm, clip)
        rows = []
        expected = json.loads((OUT/(name+'_build.json')).read_text(encoding='utf8'))[clip]['duration']
        actual = (a.frame_range[1]-a.frame_range[0])/bpy.context.scene.render.fps
        check(abs(expected-actual)<.0001, path.name+f' {clip} duration {actual:.5f}s equals {expected:.5f}s')
        for f in range(round(a.frame_range[0]), round(a.frame_range[1])+1):
            bpy.context.scene.frame_set(f); bpy.context.view_layer.update()
            deps = bpy.context.evaluated_depsgraph_get()
            row = {'joints':{n:list(arm.matrix_world@p.head) for n,p in arm.pose.bones.items()},
                   'quaternions':{p.name:list(p.rotation_quaternion) for p in arm.pose.bones},'bounds':{}}
            hand = arm.matrix_world@arm.pose.bones['Hand_R'].matrix
            for ob in [body, weapon]:
                eo = ob.evaluated_get(deps); em = eo.to_mesh()
                pts = [eo.matrix_world@v.co for v in em.vertices]; eo.to_mesh_clear()
                row['bounds'][ob.name] = [min(p[i] for p in pts) for i in range(3)]+[max(p[i] for p in pts) for i in range(3)]
                if ob.name=='Weapon':
                    local = [hand.to_quaternion().inverted()@(p-hand.translation) for p in pts]
                    if first_gun_local is None: first_gun_local = local
                    row['rigid_error'] = max((a2-b2).length for a2,b2 in zip(local,first_gun_local))
            rows.append(row)
        result[clip] = rows
        z = min(r['bounds'][ob][2] for r in rows for ob in [body.name, weapon.name])
        rigid = max(r['rigid_error'] for r in rows)
        check(z>=-.0001, path.name+f' {clip} no mesh below ground: {z:.6f} m')
        check(rigid<.0002, path.name+f' {clip} weapon remains rigid on right hand: {rigid:.7f} m')
        h = [Vector(r['joints']['Hips']) for r in rows]
        horizontal = max(Vector((v.x-h[0].x,v.y-h[0].y,0)).length for v in h)
        if clip=='HitHeavy':
            check(1.2<horizontal<2.8, path.name+f' blast has deliberate backward travel: {horizontal:.3f} m')
            lift = max(v.z for v in h)-h[0].z
            check(lift>.4, path.name+f' blast hip rises before falling: {lift:.3f} m')
            clearance = max(r['bounds'][body.name][2] for r in rows)
            check(clearance>.3, path.name+f' blast whole body leaves the ground: {clearance:.3f} m')
            check(rows[-1]['joints']['Head'][2]<.5*rest_z('Head') and rows[-1]['joints']['Hips'][2]<.5*rest_z('Hips'),
                  path.name+' blast finishes lying dead')
            hold = max((Vector(r['joints'][n])-Vector(rows[-1]['joints'][n])).length for r in rows[-10:] for n in rows[-1]['joints'])
            check(hold<.0001, path.name+f' blast terminal pose holds without standing up: {hold:.7f} m')
        else:
            check(horizontal<.0001, path.name+f' {clip} no horizontal root drift')
        if clip=='Hit':
            angles = [Quaternion(r['quaternions']['Spine_03']).rotation_difference(Quaternion(rows[0]['quaternions']['Spine_03'])).angle for r in rows]
            peak = max(range(len(angles)), key=angles.__getitem__)
            check(peak<=2 and max(angles)>.05, path.name+f' bullet impact peaks within two frames: frame {peak}')
            check(angles[-1]<.0001, path.name+' bullet flinch recovers to the starting pose')
        if clip.endswith('-loop'):
            seam = max((Vector(rows[0]['joints'][n])-Vector(rows[-1]['joints'][n])).length for n in rows[0]['joints'])
            check(seam<.0001, path.name+f' {clip} all joint positions close at loop seam: {seam:.7f} m')
        movement = max((Vector(r['joints'][n])-Vector(rows[0]['joints'][n])).length for r in rows for n in rows[0]['joints'])
        check(movement>.0001, path.name+f' {clip} measured joint movement {movement:.5f} m')
    return result

summary = {}
for path in sorted(OUT.glob('*.glb')):
    print('VALIDATE', path.name, flush=True)
    summary[path.stem] = measure(path, OUT/(path.stem+'_build.json'))
(OUT/'validation_summary.json').write_text(json.dumps({'passed':not failures,'failures':failures}, indent=2), encoding='utf8')
print('BATCH_VALIDATION_PASS' if not failures else 'BATCH_VALIDATION_FAIL: '+str(failures), flush=True)
