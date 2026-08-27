# 基础功能一致性审核 Implementation Plan

## Overview

依据 `docs/AI_RTS_基础功能一致性审核矩阵.xlsx`，对当前仓库做一次代码级功能排查：核对表格快照是否仍成立，标出必须项中的冲突 / 缺失 / 部分一致，并确定后续修复优先级。本轮以对照代码与权威策划文档为主，不改玩法实现。

## Current State Analysis

项目是 Godot 4.7 Mono + C# 的战役型 RTS Demo。权威架构为：

```text
Godot 场景 / Legacy GDScript / Human / Rule AI
  → GodotAdapter / Runtime
  → Application
  → Domain
```

当前 Demo 目标是战斗、指挥、情报、AI 副官和战役流程成立；资源 / 建造 / 生产已有能力但标记为暂缓。

审核矩阵快照：总 98 项，必须 74，一致 57，部分一致 19，冲突 14，缺失 8，需处理合计 41。

## Implementation Strategy

1. 以矩阵「一致性矩阵」工作表为检查清单，汇总表为优先级参考。
2. 对每条必须项核对：默认输入、Human HUD、AI HUD、C# 命令入口、战役控制器、时间源。
3. 只记录代码证据，不把历史重构文档当成当前实现。
4. 发现表格过时时单独标注「表格需更新」，不静默改 Excel。

## Implementation Steps

1. ✅ 解析审核矩阵并熟悉仓库结构
2. ✅ 对冲突 / 缺失 / 部分一致项做首轮代码核验
3. ✅ 按冲突 / 缺失 / 部分一致项完成代码复核
4. ✅ 输出完善清单：`docs/plan/基础功能完善清单.md`
5. ✅ 矩阵第 4 项「单位快捷键」已验收
6. ✅ 矩阵第 5 项「Tab 切换 AI HUD」已验收
7. ✅ 矩阵第 7 项「F10 暂停菜单」已验收
8. ✅ 矩阵第 23 项「停止移动」已验收
9. ⏳ AI 副官相关项按你的要求暂缓
10. ✅ 矩阵第 6 项「Space 最近战场事件」已验收
11. ✅ 矩阵第 19 项「强制移动」已验收
12. ✅ 矩阵第 21 项「战术撤退」已验收
13. ✅ 矩阵第 25 项「命令生命周期」已验收
14. ✅ 矩阵第 27 项「基础寻路」已验收
15. ✅ 矩阵第 29 项「局部避让」已验收
16. ✅ 矩阵第 30 项「不可达反馈」已验收
17. ✅ 矩阵第 36/88 项「攻击间隔 / 攻击时间」已验收
18. ✅ 矩阵第 43 项「单位死亡」已验收
19. ✅ 矩阵第 44 项「死亡后引用清理」已验收
20. ⏳ AI 副官相关项按你的要求暂缓
21. ✅ 矩阵第 81 项「战役胜利」已验收
22. ✅ 矩阵第 82 项「战役失败」已验收
23. ✅ 矩阵第 83 项「结果锁定」已验收
24. ✅ 矩阵第 84 项「战役结算」已验收
25. ✅ 矩阵第 85 项「重开」已验收
26. ✅ 矩阵第 87/88/89 项「战局暂停 / 攻击时间 / 战役计时」已验收

## Timeline

- 本轮：完成熟悉与首轮对照
- 下一轮：按确认后的 P0 项逐个落地

## Risk Assessment

- 策划文档之间对 `F` 键存在「停止」与「停止移动」表述差异，改输入前需先对齐权威语义
- AI 副官与战役仍大量依赖 Legacy 脚本，替换时容易破坏第一战役演示
- 时间源从墙钟改模拟时间会牵动攻击间隔、战役计时和暂停

## Success Criteria

- 每条必须项都有「一致 / 部分一致 / 冲突 / 缺失」结论和代码位置
- P0 九项有明确修复入口，不与暂缓系统混做
- 后续改动可按矩阵项验收

## Progress Tracking

- ✅ 解析 `AI_RTS_基础功能一致性审核矩阵.xlsx`
- ✅ 首轮代码核验（输入、HUD、AI 副官、战役、时间源）
- ✅ 输出 `docs/plan/基础功能完善清单.md`
- ⏳ 开始按工作包对着矩阵完善（待确认）

## Related Files

- `docs/AI_RTS_基础功能一致性审核矩阵.xlsx`
- `docs/策划文档/策划文档_RTS基础功能基线.md`
- `docs/策划文档/策划文档_基础交互逻辑文档.md`
- `docs/策划文档/策划文档_UI交互说明.md`
- `source/csharp/Application/Input/DefaultInputBindings.cs`
- `source/match/Menu.gd`
- `source/match/Match.gd`
- `source/match/hud/AICommandHUD.gd`
- `source/match/hud/TraditionalUnitCommandHUD.gd`
- `source/match/players/human/UnitActionsController.gd`
- `source/campaign/CampaignController.gd`
- `source/match/units/actions/AttackingWhileInRange.gd`
- `docs/plan/基础功能完善清单.md`
