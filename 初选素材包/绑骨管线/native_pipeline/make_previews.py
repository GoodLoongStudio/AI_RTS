"""Assemble GIFs and contact sheets from the final-GLB rendered frames."""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont

OUT=Path(__file__).resolve().parent.parent/'4006/原厂骨架_v3'
REVIEW=OUT/'动画审核';REVIEW.mkdir(exist_ok=True)
CLIPS=['Idle-loop','Run-loop','Fire','Hit','HitHeavy','Crawl-loop','Death']
font=ImageFont.truetype(r'C:\Windows\Fonts\msyh.ttc',22)
labels=['待命','跑步','射击','轻受击','重受击','匍匐','死亡']
sheet=Image.new('RGB',(480*4,600*2),(27,31,38));dr=ImageDraw.Draw(sheet)
for index,(clip,label) in enumerate(zip(CLIPS,labels)):
    files=sorted((OUT/'review_frames'/clip).glob('*.png'))
    frames=[Image.open(f).convert('RGB') for f in files]
    strip=Image.new('RGB',(240*5,304),(27,31,38));sd=ImageDraw.Draw(strip)
    for i in range(5):
        k=round((len(frames)-1)*i/4);strip.paste(frames[k].resize((240,280)),(i*240,24))
        sd.text((i*240+5,0),files[k].stem,fill='white')
    strip.save(REVIEW/(clip+'.png'))
    sample=Image.new('RGB',(120*len(frames),140))
    for i,f in enumerate(frames):sample.paste(f.resize((120,140)),(120*i,0))
    palette=sample.quantize(colors=256)
    quantized=[f.quantize(palette=palette,dither=Image.Dither.NONE) for f in frames]
    # GIF has 10 ms timing resolution: 70/60/70 ms repeats to approximate 15 fps.
    durations=[70 if i%3!=1 else 60 for i in range(len(frames))]
    if not clip.endswith('-loop'):durations[-1]=650
    quantized[0].save(REVIEW/(clip+'.gif'),save_all=True,append_images=quantized[1:],duration=durations,loop=0,optimize=False)
    x=index%4*480;y=index//4*600
    sheet.paste(frames[len(frames)//2],(x,y+40));dr.text((x+12,y+5),label+' / '+clip.replace('-loop',''),font=font,fill='white')
sheet.save(REVIEW/'七段索引.png')
print('PREVIEWS_COMPLETE',REVIEW)
