# 音频系统 Implementation Plan

## Overview
把音频做成表现层服务：Core 只发已经发生的事件，Godot 负责播什么、叠多少、走哪条总线。先补总线和音量，再补最小战斗/UI 音效，BGM 和完整语音库后置。

## Current State Analysis
- 已有：`VoiceNarratorController`（战况旁白，带优先级）和 `UnitVoicesController`（选中/应答），共用 `MatchConstants.EVENT_TO_ASSET_MAPPING` 预加载英文 TTS ogg。
- 没有：`default_bus_layout`、设置里的音量、开火/命中/死亡 SFX、循环 BGM、3D 衰减、同类音效限流。
- 分层约束已写明：投射物模型、音效和特效属于 Godot asset manifest，**不进入** `demo.balance.v1.json`。
- 迁移原则：HUD、动画和音频订阅 Domain Event / MatchSignals，不在 Domain 里播声音。
- 已知坑：场景卸载时必须停流并清空 `stream`，否则音频线程会泄漏（QA-007）。

## Implementation Strategy
1. **音频永不进 Core。** `AI_RTS.Core` 继续只产出伤害、死亡、生产、技能结算等事实；播放器只在 GodotAdapter / match 场景。
2. **一张资源清单，不写进平衡表。** 例如 `config/presentation/audio.manifest.v1.json` 或 Godot `.tres`：事件 ID → 路径、总线、冷却、最大同时播放数。换皮换语言只改清单。
3. **一个导演，多条总线。** `Master / Music / Sfx / Voice`。旁白继续走 Voice；新音效走 Sfx；以后 BGM 走 Music。设置只调总线 dB。
4. **RTS 必须限流。** 十辆坦克齐射不能播十个完整炮声。同类 cue 设 `maxVoices` + 最短间隔；远处用 3D 衰减或直接丢弃。
5. **复用现有旁白，不重写。** 第一期只把 Voice 接到 Voice 总线，并修「选中/应答共用旁白资源表」的耦合。

不推荐：每个单位场景各挂一个 `AudioStreamPlayer3D` 自己乱播；也不推荐把 `playSound` 做成技能数值效果进 Catalog。

## Implementation Steps
1. ✅ 总线与设置：`default_bus_layout.tres` + Options 主音量/音效/语音（音乐滑条可先占位）
2. ✅ 表现清单与 `AudioDirector`：池化播放、卸载停流、按 cue 限流
3. ✅ Demo 最小 cue：UI 点击、选中、开火、命中、单位死亡、建造完成（自制合成 WAV）
4. ✅ 接到现有信号：炮弹/火箭发射与命中、`unit_died`、命令栏与主菜单点击
5. ✅ 旁白改走 Voice 总线
6. ✅ 菜单/对局循环 BGM（已去掉交火脉冲抬音与军鼓循环）
7. ✅ 中文旁白与单位应答替换英文 TTS

## Timeline
- 第 1 步可当天完成，立刻能调音量。
- 第 2–5 步是「听得见打仗」的最小闭环，建议一次做完再验收。
- 第 6–7 步已用自制循环乐与项目生成中文语音落地；真人录音可后换路径。

## Risk Assessment
- 自动测试无声环境：播放器必须在无设备/无资源时静默跳过，不能 assert 失败。
- 叠音与泄漏：必须沿用 QA-007 的停流释放。
- 版权：占位音必须可商用或自制；现有 TTS 目录名已标明来源，新资源要进美术审计。
- 联机：只播本地玩家该听的（己方旁白、可见单位的 3D 音效），不要按主机全图播。

## Success Criteria
- 设置里能独立静音 Voice 而不静音 SFX。
- 坦克对打能听到发射和命中，十辆齐射不会糊成一片。
- 退出对局后无音频 RID / 流残留。
- Core 测试不出现 Godot 音频类型。

## Progress Tracking
✅ 总线与设置
✅ AudioDirector 与清单
✅ Demo 最小 cue 接线
✅ 旁白走 Voice 总线
✅ 进对局肉耳验收
✅ BGM
✅ 正式语音资源
⏳ 进对局听中文旁白与菜单/战斗音乐切换

## Related Files
- `tools/generate_demo_sfx.py`
- `tools/generate_demo_bgm.py`
- `tools/generate_zh_voice.py`
- `assets/audio/sfx/`
- `assets/audio/music/`
- `assets/voice/zh-CN/`
- `config/presentation/audio.manifest.v1.json`
- `source/match/audio/AudioDirector.gd`
- `default_bus_layout.tres`
- `source/Globals.gd`
- `source/main-menu/Options.gd`
- `source/match/units/projectiles/CannonShell.gd`
- `source/match/units/projectiles/Rocket.gd`
- `source/match/players/human/Human.tscn`
- `docs/程序文档/程序重构_强类型数值配置接口评审稿.md`
- `docs/程序文档/程序重构_生产旁白调度记录.md`
