"""Render final imported GLB, never the intermediate pose solver."""
import sys,pathlib,bpy,argparse
sys.path.insert(0,str(pathlib.Path(__file__).parent))
from baseline import OUT,bind,stage
from mathutils import Vector
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.render.fps=30
for o in list(bpy.data.objects):bpy.data.objects.remove(o,do_unlink=True)
bpy.ops.import_scene.gltf(filepath=str(OUT/'Infantry_native_v3.glb'))
arm=next(o for o in bpy.data.objects if o.type=='ARMATURE')
cam=stage();sc=bpy.context.scene
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--clips',nargs='+',default=['Idle-loop','Run-loop','Fire','Hit','HitHeavy','Crawl-loop','Death'])
args=parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
for name in args.clips:
    target=Vector((0,1.05,1.0)) if name=='HitHeavy' else Vector((0,0,.85))
    cam.location=target+Vector((2.6,-4.6,1.35))
    cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
    cam.data.ortho_scale=3.5 if name=='HitHeavy' else 2.4
    act=bind(arm,name);folder=OUT/'review_frames'/name;folder.mkdir(parents=True,exist_ok=True)
    # Clear this generator's previous numbered frames so old sample grids cannot mix.
    assert folder.resolve().is_relative_to((OUT/'review_frames').resolve())
    for old in folder.glob('*.png'):
        if old.stem.isdecimal():old.unlink()
    step=1 if name=='Hit' else 2
    for f in range(round(act.frame_range[0]),round(act.frame_range[1])+1,step):
        sc.frame_set(f);bpy.context.view_layer.update()
        sc.render.filepath=str(folder/f'{f:03d}.png');bpy.ops.render.render(write_still=True)
    print('RENDERED_FINAL_GLB',name,flush=True)
