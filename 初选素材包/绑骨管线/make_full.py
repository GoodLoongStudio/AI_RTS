# -*- coding: utf-8 -*-
import pathlib
src = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\quick_frames3.py")
c = src.read_text(encoding="utf-8")
c = c.replace('OUTD = Path(r"G:\\AIRTS\\AI_RTS\\初选素材包\\绑骨管线\\4006\\抽帧3")',
              'OUTD = Path(r"G:\\AIRTS\\AI_RTS\\初选素材包\\绑骨管线\\4006\\动画帧")')
c = c.replace('frames = [1, 15, 30, 45, 70, 80, 90, 110, 118, 134, 141, 150, 175, 190, 208]',
              'frames = list(range(1, 209))')
c = c.replace('("v%03d.png" % f)', '("f%03d.png" % f)')
dst = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\full_anim.py")
dst.write_text(c, encoding="utf-8")
print("full_anim.py written")
