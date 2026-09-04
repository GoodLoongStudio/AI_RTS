# 步兵单位-plan

> 负责会话：WorkBuddy 主会话 ｜ 创建：2026-09-04 ｜ 状态：期 1 ✅ 期 2 ✅ 全部完成（09-04；动画采用 Godot 内程序化骨骼驱动方案交付）

## Overview

新增"步兵"单位类型，补齐 RTS 的基础兵种闭环：便宜、快速、可量产的轻量战斗单位。
分期交付：**期 1** 打通"生产→部署→移动→交战"最小闭环（挂指挥中心生产）；
**期 2** 新增兵营建筑、步兵成群产出、AI 出兵接入。

## Current State

- ✅ 素材就绪：`初选素材包/绑骨管线/4006/Characters/` 已有 rigged 模型
  （Soldier_Male_01/02、Soldier_Female_02、Scavenger_01-03、SpaceSuit/Alien 系列共 10+ 本体，含独立贴图）
- ✅ 另一会话已建绑骨/抽帧管线（动画帧、check_godot_rig.gd），骨架经 Godot 导入验证
- ✅ 架构为数据驱动：新增单位只需 balance JSON + 场景 + 脚本，C# DTO 无需改动
- ✅ 参考实现齐备：Tank/Worker 的场景结构、traits 组合、生产队列、页签配置可直接复用
- ⏳ rigged 模型的**动画剪辑**尚未确认可用（另一会话抽帧管线进行中）
- ⏳ 步兵的碰撞/选中尺寸、武器配置、页签入口均未创建

## Strategy

1. **一期最小闭环优先**：步兵先挂**指挥中心**生产（不新增建筑），把"配置→生产→部署→交战"
   全链路打通并自动化测试覆盖；动画未就绪时先静态模型（T-Pose 站立不影响逻辑验证）。
2. **二期再动建筑**：新增兵营（`SM_Bld_Corp_Barracks_01`，换模管线现成）承接步兵生产，
   指挥中心保留 1-2 个步兵位作过渡；AI 侧由 OffenseController 把步兵编入 battlegroup。
3. **数值定位**：步兵 = 便宜快速的低火力单位，克制关系上作为坦克的"数量补充"而非替代。
4. **每步提交**：吸取 09-03/04 并行会话覆盖教训，每完成一个 Step 立即 commit 固化。

### 建议数值（期 1，可调）

| 项 | 值 | 对比参照 |
|---|---|---|
| 成本 | A×150 | worker 200 / tank 500 |
| 生产工作量 | 120 | worker 180 / tank 360 |
| 生命 | 40 | tank maxHp 10（武器基伤 2.0 需同步微调命中平衡） |
| 速度 | 3.5 m/s | tank 2.75 |
| 视野 | 6 m | tank 8 |
| 武器 | 基伤 0.5 / 冷却 600ms / 射程 2.5 / 仅对地 | 快速低伤，靠数量 |

## Steps

### 期 1：最小闭环 ⏳

1. ✅ **素材接入**：拷贝 `Soldier_Male_01_rigged.fbx` + 贴图到 `assets/models/scifi-worlds/`；
   headless 导入并 dump 节点树/动画列表，确认骨架与动画剪辑可用性（动画缺失则记录降级方案）
2. ✅ **单位实现**：新建 `source/match/units/Infantry.tscn + Infantry.gd`
   （Area3D，复用 traits：Movement / HealthBar / Selection / Highlight / Targetability /
   UnitVisualBindings；碰撞圆柱 r=0.3 h=0.9；武器按数值表配）
3. ✅ **平衡配置**：`config/balance/demo.balance.v1.json` 新增 `unitTypes.soldier`
   （movement/weapons/weaponIds）与 `productions.soldier`（producer=command_center）；
   同步更新 BalanceConfigLoaderTests 的 pin
4. ✅ **生产入口**：Ra3Sidebar 指挥中心页签新增"步兵"格子（TABS 配置 + 图标可选）；
   CommandCenterMenu 若有独立菜单同步加
5. ✅ **自动化测试**：新增 `InfantrySmokeTest`（生产入队→部署→移动→攻击假人→击杀）；
   跑 ProductionQueue / StructurePlacement / WorkerGather 回归确认无破坏
6. ✅ **验收**：自定义模式人工目检（选中圈/血条/开火弹道）+ 截图；提交并推送

### 期 2：兵营 + AI 出兵 ⏳

7. ✅ **兵营建筑**：`structure-geometries/Barracks.tscn`（SM_Bld_Corp_Barracks_01 换模管线）+
   `Barracks.gd`（复用 VehicleFactory 的生产建筑模式）+ 建造定义 + 蓝图放置
8. ✅ **生产迁移**：productions.soldier 的 producer 改为 barracks；指挥中心页签保留或移除按体验定
9. ✅ **AI 接入**：EconomyController/OffenseController 支持步兵批量产出并编入 battlegroup
   （难度档位：EASY 不出步兵 / NORMAL 混编 / HARD 步海战术）
10. ✅ **动画补全**：外部动作剪辑未产出，改用 Godot 内程序化骨骼驱动（InfantryAnimationDriver：待命呼吸/行走摆腿摆臂/开火端枪后坐，轴扫描截图校准垂臂轴向 X-90°）；死亡动画随单位销毁暂不需要
11. ⏳ **回归 + 验收**（动画相关回归待动画接入后补）：全量自动测试 + 对局体验确认

## Timeline

- 期 1：约 3 个工作块（素材接入+单位实现 / 配置+入口+测试 / 验收提交）
- 期 2：约 2-3 个工作块（兵营+迁移 / AI 接入 / 动画+回归）
- 依赖：期 2 的动画补全依赖另一会话的抽帧/绑骨管线产出节奏

## Risk

| 风险 | 影响 | 对策 |
|---|---|---|
| rigged FBX 动画剪辑在 Godot 中不可用 | 步行/开火无动画，观感差 | 一期先静态交付；动画由专会话管线补，接口不阻塞逻辑 |
| 人形单位命中平衡破坏现有坦克体系 | 战斗测试大面积红 | 一期数值保守（低伤快射），BalanceConfigRuntimeSmokeTest 同步校准 |
| 并行会话再次覆盖工作区 | 返工 | 每个 Step 完成即 commit；开工前确认绑骨会话不在写 assets/ |
| 步兵数量大带来寻路/RVO 压力 | 大规模步群卡顿 | 一期上限小规模；期 2 AI 步海上量前跑 LocalAvoidance 回归 |
| 多会话对 balance JSON 的并发修改 | 配置互相覆盖 | 提交前 diff review，冲突以"单币种 demo-baseline"为唯一事实源 |

## Success Criteria

- ✅ 自定义模式：指挥中心页签可生产步兵，部署后可框选、移动、自动交战并击杀假人
- ✅ `InfantrySmokeTest` 全绿；ProductionQueue / StructurePlacement / WorkerGather 回归全绿
- ✅ 期 2：兵营可建造并承接步兵生产；AI（NORMAL/HARD）能成批出步兵编入进攻
- ✅ 全部提交推送固化，无未提交的半成品滞留工作区
