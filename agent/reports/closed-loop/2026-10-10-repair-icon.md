# 建筑维修状态图标闭环报告

日期：2026-10-10  
开发根：`G:/AIRTS/AI_RTS`  
任务状态：**功能候选通过；全局工作区 needs-review**

## 需求澄清

用户说的是“建筑正在维修时没有状态图标”，不是维修侧栏按钮，也不是鼠标扳手光标。侧栏和 `CommandCursor.gd` 没有作为本次修复目标。

## 根因

`source/match/units/Structure.gd` 原有 `set_repairing()` 只改变 `_repairing` 和经济/回血流程；满血、缺钱和出售停止时也没有任何状态表现。现有 `cursor_repair.png` 只用于原生鼠标光标，因此建筑本体没有维修标志。联机快照此前只发送位置、HP、动作等字段，也没有 `repairing` 表现字段。

## 本轮改动

- `source/match/units/Structure.gd`
  - 复用 `assets/ui/cursors/cursor_repair.png`，第一次进入实际维修时懒创建 `RepairStatusIcon` `Sprite3D`。
  - 图标独立挂在建筑逻辑根节点，billboard、无光照、无深度测试、无阴影，锚点根据 Geometry/HealthBar 上缘测量并留间距，不继承模型或血条缩放。
  - `set_repairing()`、满血自动停止、资金不足自动停止和出售统一驱动显隐；离开维修指定模式不会误停维修。
  - 不改变 HP 恢复、资源扣除、选择、建造、碰撞或建筑尺寸。
  - 图标加 `exclude_from_geometry_measurements` 元数据。
- `source/net/NetSync.gd`
  - 权威快照加入 `repairing`；客户端只调用 `present_repairing()`，不在客户端回血或扣钱。
- `source/match/utils/UnitPlacementUtils.gd`、`source/match/units/traits/ProductionQueue.gd`
  - 生产出生点/模型外缘读取跳过维修图标，避免将状态 UI 误算成建筑模型而改变出生点。

## 证据与结果

### 基线

`baseline-status-gpu/launch.json`：真实 `Match` 正常启动、维修可回血扣钱，但 `RepairStatusIcon` 缺失；旧探针的 30 physics-frame 回血断言过短，保留为诊断失败，不作为产品回归结论。

### 候选功能闸门

`candidate-status-gpu-r4/launch.json`：

- Godot 源码路径明确为 `G:/AIRTS/AI_RTS`；GPU 独立后台窗口；`rc=0`、完成标记存在、`engine_errors=[]`、`cleanup_ok=true`、`passed=true`。
- `candidate-status-gpu-r4/repairing-without-targeting.png` 已实际打开：未选中、已退出维修指定模式，建筑上方仍显示扳手。
- `candidate-status-gpu-r4/all-buildings-repairing.png` 已实际打开：主基地、矿场、车厂、兵营、机场和三种炮塔均有清晰扳手，未压住模型/血条。
- `candidate-status-gpu-r4/stopped.png` 已实际打开：停止维修后图标消失。
- 真实 Match 断言全部通过：维修回血/扣钱、取消目标后仍维修、再次点击停止、满血停止、缺钱停止、死亡/出售清理、隐藏建筑隐藏图标、八类建筑懒创建和复用、图标不改变生产模型外缘、快照显示不回血不扣钱。

### 相关回归

- `r4-command-cursor`：功能 marker 通过，rc=0，日志干净。
- `r4-structure-repair-sell`、`r4-presentation-sync`、`r4-spawn-point-gpu`：功能 marker/断言通过；严格 runner 判为失败的原因是本工作区已有 Godot 资源/RID/ObjectDB 退出泄漏和渲染清理错误，不是本补丁断言失败。`r4-spawn-point-gpu/stdout.log` 明确显示 Infantry 6.55m、赠送矿车 11.03m、缩放 2/3 出生比例 1.49，全部 PASS。
- `candidate-status-headless-r3`：功能 marker 和全部新断言通过；严格日志另有既存 Minimap dummy texture 的 `Parameter "t" is null`，所以不能称日志干净。
- 独立复核：`agent/runs/20261010-repair-icon/independent-review.md`。独立检查无阻断性问题，确认无每帧全局扫描、客户端不执行经济逻辑、迷雾和死亡清理正常。

## 未验证项与现有阻塞

- 未做真实双端网络连接；本轮在真实单进程 Match 调用了 NetSync 的实际消费入口。
- `dotnet build OpenRTS.sln --no-restore --nologo` 当前被其他会话已有的 `source/csharp/Application/Combat/WarheadDamageResolver.cs` CS0136（`dx`、`dz`、`combinedRadius` 重名）阻塞，本轮未修改该文件。
- 完整回归没有执行；多条既有套件存在退出资源泄漏，不能把 marker 通过写成全局干净通过。
- 用户仍需自行开新局确认主观观感；本轮没有操作或结束用户窗口，也没有覆盖打包版。

## 决策

维修图标候选从本功能 champion 角度通过；不因无关 C# 编译错误或已有退出泄漏继续扩大补丁范围。全局状态保持 `needs-review`，不能宣称整个工程回归全部通过。
