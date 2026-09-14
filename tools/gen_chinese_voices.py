# -*- coding: utf-8 -*-
"""生成全中文战斗播报配音（edge-tts 免费合成）。

用法:
  C:/Users/Lenovo/.workbuddy/binaries/python/envs/default/Scripts/python.exe tools/gen_chinese_voices.py [--only key1,key2]

输出:
  assets/voice/chinese/narrator_*.mp3        全局旁白（指挥 AI）
  assets/voice/chinese/unit_<id>_*.mp3       各单位专属选中/确认语音
  assets/voice/chinese/structure_<id>.mp3    建筑选中语音

改台词/音色直接改下面两张表再重跑（--only 可只重生成指定 key）。
"""

import asyncio
import pathlib
import sys

import edge_tts

OUT_DIR = pathlib.Path(__file__).resolve().parent.parent / "assets" / "voice" / "chinese"

# ── 全局旁白（指挥 AI · 冷静女声 Xiaomo）──────────────────────────────
NARRATOR = {
    "narrator_battle_control_online": ("战斗指挥系统上线，等待你的命令。", "zh-CN-XiaoxiaoNeural"),
    "narrator_battle_control_offline": ("战斗指挥系统离线。", "zh-CN-XiaoxiaoNeural"),
    "narrator_victory": ("胜利属于我们！干得漂亮！", "zh-CN-XiaoxiaoNeural"),
    "narrator_defeat": ("我们失败了……部队正在撤退。", "zh-CN-XiaoxiaoNeural"),
    "narrator_base_under_attack": ("警告！基地遭到攻击！", "zh-CN-XiaoxiaoNeural"),
    "narrator_unit_under_attack": ("我方单位受到攻击！", "zh-CN-XiaoxiaoNeural"),
    "narrator_unit_lost": ("我方单位损失。", "zh-CN-XiaoxiaoNeural"),
    "narrator_training": ("正在生产作战单位。", "zh-CN-XiaoxiaoNeural"),
    "narrator_unit_ready": ("新单位已就绪。", "zh-CN-XiaoxiaoNeural"),
    "narrator_construction_complete": ("建造完成。", "zh-CN-XiaoxiaoNeural"),
    "narrator_not_enough_resources": ("资源不足，无法执行。", "zh-CN-XiaoxiaoNeural"),
}

# ── 各单位专属语音（音色+台词全部独特）───────────────────────────────
UNIT_VOICES = {
    "soldier": {  # 步兵 · 阳光男声
        "hello": ("步兵就位！随时可以战斗！", "zh-CN-YunxiNeural"),
        "ack1": ("收到！", "zh-CN-YunxiNeural"),
        "ack2": ("马上行动！", "zh-CN-YunxiNeural"),
    },
    "sniper": {  # 狙击兵 · 低沉冷峻男声
        "hello": ("狙击手就位，一枪一个。", "zh-CN-YunjianNeural"),
        "ack1": ("明白，进入阵地。", "zh-CN-YunjianNeural"),
        "ack2": ("保持静默，锁定目标。", "zh-CN-YunjianNeural"),
    },
    "rocketeer": {  # 炮兵 · 激情男声
        "hello": ("火箭炮兵，火力就绪！", "zh-CN-YunyangNeural"),
        "ack1": ("火箭上膛！", "zh-CN-YunyangNeural"),
        "ack2": ("覆盖射击，收到！", "zh-CN-YunyangNeural"),
    },
    "worker": {  # 工人 · 活泼女声
        "hello": ("工人报到！修建造样样在行！", "zh-CN-XiaoyiNeural"),
        "ack1": ("马上去干活！", "zh-CN-XiaoyiNeural"),
        "ack2": ("建造任务交给我！", "zh-CN-XiaoyiNeural"),
    },
    "drone": {  # 无人机 · 清脆少年声
        "hello": ("无人机系统启动！", "zh-CN-YunxiaNeural"),
        "ack1": ("收到指令。", "zh-CN-YunxiaNeural"),
        "ack2": ("前往目标区域。", "zh-CN-YunxiaNeural"),
    },
    "transport_truck": {  # 运输车 · 稳重男声
        "hello": ("运输车就绪，货厢已清空！", "zh-CN-liaoning-XiaobeiNeural"),
        "ack1": ("收到，马上装车！", "zh-CN-liaoning-XiaobeiNeural"),
        "ack2": ("物资运输，正在赶路。", "zh-CN-liaoning-XiaobeiNeural"),
    },
    "apc": {  # 装甲车 · 沉稳男声
        "hello": ("装甲运兵车待命！", "zh-TW-YunJheNeural"),
        "ack1": ("部队上车，出发！", "zh-TW-YunJheNeural"),
        "ack2": ("全速前进！", "zh-TW-YunJheNeural"),
    },
    "tank": {  # 坦克 · 浑厚男声
        "hello": ("坦克就位，随时开火！", "zh-CN-YunjianNeural", "-5Hz"),
        "ack1": ("目标确认，开炮！", "zh-CN-YunjianNeural", "-5Hz"),
        "ack2": ("履带前进，碾过去！", "zh-CN-YunjianNeural", "-5Hz"),
    },
    "heavy_tank": {  # 重型坦克 · 威严男声（东北腔 Xiaobei 太跳，用低沉稳男 Yunye 风格由 Yunyang 区分）
        "hello": ("重型坦克入场，钢铁洪流！", "zh-CN-YunyangNeural", "-15Hz"),
        "ack1": ("主炮瞄准，准备齐射。", "zh-CN-YunyangNeural", "-15Hz"),
        "ack2": ("正面突击，势不可挡！", "zh-CN-YunyangNeural", "-15Hz"),
    },
    "helicopter": {  # 直升机 · 干练女声
        "hello": ("直升机旋翼就绪，请求起飞！", "zh-CN-XiaoxiaoNeural", "+10Hz"),
        "ack1": ("起飞，占领空域！", "zh-CN-XiaoxiaoNeural", "+10Hz"),
        "ack2": ("空中支援，马上到！", "zh-CN-XiaoxiaoNeural", "+10Hz"),
    },
}

# ── 建筑选中语音（各自独特）──────────────────────────────────────────
STRUCTURE_VOICES = {
    "command_center": ("主基地在线，指挥中枢运转正常。", "zh-CN-XiaoxiaoNeural"),
    "barracks": ("兵营运作正常，新兵随时开训。", "zh-TW-HsiaoChenNeural"),
    "vehicle_factory": ("战车工厂运转中，随时可以开工。", "zh-CN-YunjianNeural", "+8Hz"),
    "aircraft_factory": ("航空工厂就绪，战机生产线上待命。", "zh-TW-HsiaoYuNeural"),
    "anti_ground_turret": ("对地炮台就位，地面目标进入射程即开火。", "zh-CN-YunyangNeural"),
    "anti_air_turret": ("防空炮台展开，天空交给我们。", "zh-CN-shaanxi-XiaoniNeural"),
    "machine_gun_turret": ("机枪塔上弹完毕，火力网覆盖中。", "zh-CN-YunxiaNeural", "-10Hz"),
}


async def synth(key: str, text: str, voice: str, pitch: str = "") -> str:
    out = OUT_DIR / f"{key}.mp3"
    tmp = out.with_suffix(".part")
    kwargs = {"rate": "+8%"}
    if pitch:
        kwargs["pitch"] = pitch
    tts = edge_tts.Communicate(text, voice, **kwargs)
    await tts.save(str(tmp))
    tmp.replace(out)
    return key


async def main() -> None:
    only = None
    for arg in sys.argv[1:]:
        if arg.startswith("--only="):
            only = set(arg.split("=", 1)[1].split(","))

    def want(key) -> bool:
        if only is not None and key not in only:
            return False
        f = OUT_DIR / f"{key}.mp3"
        return not (f.exists() and f.stat().st_size > 3000)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    specs = {}
    specs.update(NARRATOR)
    for uid, parts in UNIT_VOICES.items():
        for slot, spec in parts.items():
            specs[f"unit_{uid}_{slot}"] = tuple(spec)
    for sid, spec in STRUCTURE_VOICES.items():
        specs[f"structure_{sid}"] = tuple(spec)
    keys_todo = [k for k in specs if want(k)]
    SYNTH_SPECS = specs
    results = []

    async def guarded(key: str):
        for attempt in range(3):
            try:
                # 每次尝试都新建协程对象（协程不可复用 await）
                spec = SYNTH_SPECS[key]
                return await asyncio.wait_for(
                    synth(key, spec[0], spec[1], spec[2] if len(spec) > 2 else ""), timeout=20
                )
            except Exception as exc:
                print("  attempt %d: %s (%s: %s)" % (attempt + 1, key, type(exc).__name__, str(exc)[:120]))
                await asyncio.sleep([8, 20, 40][attempt])
        return None

    ok = failed = 0
    for i, key in enumerate(keys_todo, 1):
        got = await guarded(key)
        if got:
            ok += 1
            print("[%02d/%02d] %s" % (i, len(keys_todo), key))
        else:
            failed += 1
            print("[%02d/%02d] FAILED %s" % (i, len(keys_todo), key))
        await asyncio.sleep(1.5)
    print("ALL DONE: %d ok, %d failed" % (ok, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    asyncio.run(main())
