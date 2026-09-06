"""Render final imported GLB, never the intermediate pose solver."""
import sys,pathlib,bpy
sys.path.insert(0,str(pathlib.Path(__file__).parent))
from baseline import OUT,bind,stage
from mathutils import Vector
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.render.fps=30
for o in list(bpy.data.objects):bpy.data.objects.remove(o,do_unlink=True)
bpy.ops.import_scene.gltf(filepath=str(OUT/'Infantry_native_v3.glb'))
arm=next(o for o in bpy.data.objects if o.type=='ARMATURE')
cam=stage();sc=bpy.context.scene
for name in ['Idle-loop','Run-loop','Fire','Hit','HitHeavy','Crawl-loop','Death']:
    act=bind(arm,name);folder=OUT/'review_frames'/name;folder.mkdir(parents=True,exist_ok=True)
    # Clear this generator's previous numbered frames so old sample grids cannot mix.
    assert folder.resolve().is_relative_to((OUT/'review_frames').resolve())
    for old in folder.glob('*.png'):
        if old.stem.isdecimal():old.unlink()
    for f in range(round(act.frame_range[0]),round(act.frame_range[1])+1,2):
        sc.frame_set(f);bpy.context.view_layer.update()
        sc.render.filepath=str(folder/f'{f:03d}.png');bpy.ops.render.render(write_still=True)
    print('RENDERED_FINAL_GLB',name,flush=True)
