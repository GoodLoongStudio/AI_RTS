#!/usr/bin/env python3
"""用 Edge TTS 生成中文正式旁白与单位应答（项目自产，不取其他游戏语音）。"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys

NARRATOR = "zh-CN-XiaoyiNeural"
UNIT = "zh-CN-YunjianNeural"
OUTPUT_ROOT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets",
    "voice",
    "zh-CN",
)

LINES = [
    ("narrator", "battle_control_online.mp3", NARRATOR, "作战控制系统已上线。"),
    ("narrator", "battle_control_offline.mp3", NARRATOR, "作战控制系统已离线。"),
    ("narrator", "you_are_victorious.mp3", NARRATOR, "胜利。"),
    ("narrator", "you_have_lost.mp3", NARRATOR, "战败。"),
    ("narrator", "your_base_is_under_attack.mp3", NARRATOR, "基地遭到攻击。"),
    ("narrator", "unit_under_attack.mp3", NARRATOR, "部队遭到攻击。"),
    ("narrator", "unit_lost.mp3", NARRATOR, "单位损失。"),
    ("narrator", "training.mp3", NARRATOR, "开始训练。"),
    ("narrator", "unit_ready.mp3", NARRATOR, "单位已就绪。"),
    ("narrator", "construction_complete.mp3", NARRATOR, "建造完成。"),
    ("narrator", "not_enough_resources.mp3", NARRATOR, "资源不足。"),
    ("unit", "sir.mp3", UNIT, "长官。"),
    ("unit", "yes_sir.mp3", UNIT, "是，长官。"),
    ("unit", "acknowledged.mp3", UNIT, "收到。"),
]


async def synthesize(communicate_cls, folder: str, filename: str, voice: str, text: str) -> None:
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, filename)
    communicate = communicate_cls(text, voice, rate="-8%", volume="+4%")
    await communicate.save(path)
    print("wrote", path)


async def generate_all() -> None:
    try:
        import edge_tts
    except ImportError:
        print("missing edge-tts; install with: python -m pip install edge-tts", file=sys.stderr)
        raise
    tasks = [
        synthesize(
            edge_tts.Communicate,
            os.path.join(OUTPUT_ROOT, folder),
            filename,
            voice,
            text,
        )
        for folder, filename, voice, text in LINES
    ]
    for task in tasks:
        await task


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.parse_args()
    asyncio.run(generate_all())


if __name__ == "__main__":
    main()
