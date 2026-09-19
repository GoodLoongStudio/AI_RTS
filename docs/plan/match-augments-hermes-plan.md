# 对局肉鸽加成（海克斯式）+ Hermes 推荐 Implementation Plan

## Overview
整局固定 2–3 次海克斯式三选一。玩家必选；Hermes 只对已抽出的三张牌排序、标星、写带 evidence 的理由；超时采用其首选（无 Hermes 则用规则地板）。Godot 权威结算数值。岚只把已选加成当观测事实。Hermes 仍不能下 `adjutant_intent` 或点单位。

## Current State Analysis
- 岚负责局内指挥；Hermes 原入口是战报 `read_for_hermes()` 与 `GrowthStore` 画像。`ProductionCatalog.hermes_advice()` 已有实时建议槽，但没有三选一玩法。
- 单机 `get_tree().paused` 会冻结 `SimulationClock`；联机不能真暂停（`Menu.gd` 已写明）。
- 经济权威在 C# `EconomyRuntime`；采集交货在 `CollectingResourcesSequentially`；血量/伤害/视野在 `Unit.gd`。
- 局外成长树与局内加成必须分开，牌 id 前缀 `aug_`。

## Implementation Strategy
Godot `AugmentRuntime` 按模拟时钟开轮、种子抽牌、倒计时落选。覆盖层立即出牌，推荐异步到达。Python runner 看到 offer 后只回 `op=augment_recommend`，从不代点。效果由 `AugmentModifiers` 改数值；副官不重算采集倍率。

## Implementation Steps
1. 本计划与架构画布「局内加成」格
2. JSON 牌库 + Catalog / PauseGate / Runtime
3. V1 效果挂钩（赠予、采集、伤害、血量、视野）
4. 三卡覆盖层 + 快捷键 + 托盘
5. 规则地板排序 + PydanticAI Hermes 窄契约
6. fast_state / 战报 / 岚读取 / 冒烟

## Timeline
本轮一次做完 V1（单机完整；联机不冻世界，权威端结算）。生产加速（CompletedWork 倍率）留 V1.1。

## Risk Assessment
- 联机暂停幻觉 → 覆盖层写明战局仍在打，且不冻模拟
- Hermes 慢 → 牌先出、星后到；超时不堵死
- 倍率叠乘 → 同 tag / 同 effect type 每局最多一张
- 菜单与选牌同时暂停 → PauseGate 引用计数

## Success Criteria
- 单机能弹出三轮；点选与超时都生效，托盘可见
- 采集/伤害类可用数字前后对照
- 无 Hermes 时仍开牌，UI 不假装有模型建议
- 战报含 offer/pick/source；岚能读 `augments`；Hermes 不因加成下单位命令

## Progress Tracking
- ✅ 仓库计划与架构画布小格
- ✅ Catalog / Runtime / PauseGate
- ✅ 效果挂钩
- ✅ 覆盖层与托盘
- ✅ Hermes 排序
- ✅ 观测、战报、冒烟

## Implementation Notes
- `resource_grant` 必须等 C# `EconomyRuntime` 账户就绪再 `add_resources`；否则 Player 会 assert。冒烟在开牌前等待 snapshot 非空。
- `hp_mult` / `damage_mult` 有 `scope=structure|unit`。炮塔是建筑，不能拿来验作战单位牌；冒烟按范围分别对照指挥中心与坦克。
- PauseGate 冻世界口径是 `not should_forward_commands()`（权威端可冻），不是 `not is_networked()`（单机 listen 也会联网）。

## Related Files
- `config/match_augments.json`
- `source/match/augments/`
- `source/match/hud/augments/`
- `source/match/Match.gd` / `Match.tscn` / `Menu.gd` / `FeatureFlags.gd`
- `source/net/DebugControlServer.gd`
- `source/history/MatchReportSchema.gd` / `MatchReportStore.gd`
- `source/adjutant_coordinator/graph/augment_rank.py`
- `source/adjutant_coordinator/deploy/agent_runner.py`
- `tests/automated/MatchAugmentSmokeTest.gd`
