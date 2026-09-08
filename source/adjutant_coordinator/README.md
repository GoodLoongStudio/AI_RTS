# 副官协调器核心（第一阶段）

对应 `docs/ai-adjutant-dual-layer/architecture.md` 的宿主协调器职责。
第二阶段接真实双模型时只替换 `StrategyModel` / `TacticsModel` 实现。

## 模块

- `protocol.py`：命令包/计划契约与校验（必填、身份、版本、过期、快照时效）。
- `state.py`：`PlanStore`（采纳代际，旧输出不能覆盖）、`TaskTracker`（任务状态机，
  与命令 Accepted 分离）、`ControlLease`（控制租约与玩家优先权）。
- `events.py`：有界事件总线，窗口内同键合并，断线恢复走新快照。
- `persistence.py`：按 `(match_id, player_id)` 目录隔离；独立临时文件（pid+uuid）
  + `os.replace` 原子写；`writer.lock` 单写入者（陈旧锁 pid 回收）。
- `coordinator.py`：`AdjutantCoordinator` 主循环（tick 驱动、请求代际、重试退避、
  逐条批次、资源预留约束）与 `FakeStrategyModel`/`FakeTacticsModel`（确定性协议测试专用）。

## 测试

```powershell
cd G:\AIRTS\AI_RTS\source\adjutant_coordinator
$env:PYTHONUTF8="1"
python -m unittest discover -s tests          # 26 项确定性测试
python e2e_dual_layer.py --run-id <run_id>    # 本地双进程 E2E（独立测试配置）
```

## 游戏侧入口（权威校验在游戏内）

- `op=rules` / `op=tactical` / `op=strategic` / `op=adjutant_command` / `op=adjutant_batch`
- 复核：`op=commands` + `command_id`（副官账本优先，兼容旧展示历史）
- 端口约定：本地 E2E 固定 24569/24570/24572，不触碰线上局服。
