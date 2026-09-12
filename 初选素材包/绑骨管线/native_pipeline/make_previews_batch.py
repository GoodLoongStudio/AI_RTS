"""Assemble per-character contact sheets and clip GIFs from review frames."""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent.parent/'批量绑定_v1'
REVIEW = OUT/'review_frames'
SHEET = OUT/'动画审核'; SHEET.mkdir(exist_ok=True)
CLIPS = ['Idle-loop','Run-loop','Fire','Hit','HitHeavy','Crawl-loop','Death']
labels = ['待命','跑步','射击','子弹命中','爆炸击飞死亡','匍匐','死亡']
font = ImageFont.truetype(r'C:\Windows\Fonts\msyh.ttc', 20)

for glb in sorted(OUT.glob('*.glb')):
    name = glb.stem
    try:
        specs = json.loads((OUT/(name+'_build.json')).read_text(encoding='utf8'))
    except Exception:
        continue
    sheet = Image.new('RGB',(360*4,420*2+80),(27,31,38)); dr = ImageDraw.Draw(sheet)
    for index,(clip,label) in enumerate(zip(CLIPS,labels)):
        folder = REVIEW/name/clip
        files = sorted(folder.glob('*.png'))
        if not files:
            continue
        frames = [Image.open(f).convert('RGB') for f in files]
        strip = Image.new('RGB',(360*5,420+40),(27,31,38)); sd = ImageDraw.Draw(strip)
        for i in range(5):
            k = min(i, len(frames)-1)
            strip.paste(frames[k].resize((360,420)),(i*360,40))
            sd.text((i*360+5,0),files[k].stem,fill='white',font=font)
        strip.save(SHEET/(name+'_'+clip+'.png'))
        sample = Image.new('RGB',(180*len(frames),210))
        for i,f in enumerate(frames): sample.paste(f.resize((180,210)),(180*i,0))
        palette = sample.quantize(colors=256)
        quantized = [f.quantize(palette=palette,dither=Image.Dither.NONE) for f in frames]
        ticks = [round(int(f.stem)/30*100) for f in files]
        end = round(specs[clip]['duration']*100)
        durations = [max(10,(b-a)*10) for a,b in zip(ticks,ticks[1:]+[end])]
        if not clip.endswith('-loop'): durations[-1]=650
        quantized[0].save(SHEET/(name+'_'+clip+'.gif'),save_all=True,append_images=quantized[1:],duration=durations,loop=0,optimize=False)
        x=index%4*360; y=index//4*420
        sheet.paste(frames[len(frames)//2],(x,y+40)); dr.text((x+12,y+5),label+' / '+clip.replace('-loop',''),font=font,fill='white')
    sheet.save(SHEET/(name+'_七段索引.png'))
    print('SHEET', name, flush=True)
print('PREVIEWS_BATCH_COMPLETE', SHEET)
