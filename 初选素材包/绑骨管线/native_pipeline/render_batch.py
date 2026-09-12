"""Render sampled frames from each batch GLB for visual review.

Each GLB renders in a fresh factory scene: cross-character action-name
collisions (Idle-loop.001 etc.) would silently bind the wrong clip."""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import bpy
from mathutils import Vector
from baseline import bind, stage

OUT = pathlib.Path(sys.argv[sys.argv.index('--')+1])
REVIEW = OUT/'review_frames'
CLIPS = ['Idle-loop','Run-loop','Fire','Hit','HitHeavy','Crawl-loop','Death']
for glb in sorted(OUT.glob('*.glb')):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for o in list(bpy.data.objects): bpy.data.objects.remove(o, do_unlink=True)
    sc = bpy.context.scene
    sc.render.fps = 30; sc.render.resolution_x = 360; sc.render.resolution_y = 420
    bpy.ops.import_scene.gltf(filepath=str(glb))
    arm = next(o for o in bpy.data.objects if o.type=='ARMATURE')
    cam = stage()
    for name in CLIPS:
        target = Vector((0,1.05,1.0)) if name=='HitHeavy' else Vector((0,0,.85))
        cam.location = target+Vector((2.6,-4.6,1.35))
        cam.rotation_euler = (target-cam.location).to_track_quat('-Z','Y').to_euler()
        cam.data.ortho_scale = 3.5 if name=='HitHeavy' else 2.4
        act = bind(arm, name)
        folder = REVIEW/glb.stem/name; folder.mkdir(parents=True, exist_ok=True)
        for old in folder.glob('*.png'):
            if old.stem.isdecimal(): old.unlink()
        rng = act.frame_range
        for i in range(5):
            f = round(rng[0] + (rng[1]-rng[0])*i/4)
            sc.frame_set(f); bpy.context.view_layer.update()
            sc.render.filepath = str(folder/f'{f:03d}.png')
            bpy.ops.render.render(write_still=True)
        print('REVIEWED', glb.stem, name, flush=True)
print('BATCH_RENDER_DONE', flush=True)
