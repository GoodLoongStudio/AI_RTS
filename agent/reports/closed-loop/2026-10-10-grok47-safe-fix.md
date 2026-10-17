# Grok 4.7 安全修复闭环

日期：2026-10-10（北京时间）  
状态：**needs-review**。两刀已经过独立无头真实 Match。没有全量回归，没有另一个会话复核，不能写“已修好”。

开发根：`G:/AIRTS/AI_RTS`。路径检查 rc=0。引擎 `G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`，版本 `4.7.1.stable.mono.official.a13da4feb`。

## 改了什么

| 文件 | 改动 | 补丁后 SHA256 |
|---|---|---|
| `source/match/units/traits/Movement.gd` | 窄缝交还日志的变量改成显式 `String`，脚本才能加载 | `E0E9842D7AFFAA2DDDE6D89703C465B7DD62370079EF9CF1C9FF1B2F5A83A3E2` |
| `source/match/units/OreRefinery.gd` | 赠车立刻自选采集；接管只认空闲车 | `69AFE76D7312D966272874F8BADCB568EE4C09868DEBF9F24BF8CA396B6FEEA4` |

HEAD 仍是 `9a2e6d449185760f9219854c538f3b672a027bf2`。没有 commit，没有 push。没有改 `G:/AIRTS/打包版`，没有动 GitHub release。没有改 `MovingToUnit.gd`。两刀都是 GDScript，没有重编 `OpenRTS.dll`。

## 第 1 刀：移动脚本能挂上

- 假设：`Movement.gd:2609` 的 `:=` 被当成错误，单位上的 Movement 没有脚本，移动令位移为 0。
- 基线 Match：`--headless --path G:/AIRTS/AI_RTS res://agent/runs/2026-10-10-grok47-safe-fix/s0_match_probe.tscn -- --debugport 25993`
  - 启动器 PID 42892，游戏 PID 45872，11:00:51–11:01:03，退出码 5
  - 单位 2，资源点 16，`movement_script_valid=false`，下令后位移 0
  - 日志 `s0-match-c.stdout.log` / `s0-match-c.stderr.log`
- 补丁后新局：同一场景，`--debugport 25994`
  - 启动器 PID 36912，游戏 PID 37144，11:03:13–11:03:25，退出码 0
  - 脚本挂上，空闲 1.5 秒位移 0，下令后位移 16.892 米，单位仍是 2，资源点仍是 16
  - physics 457 tick，60 Hz，墙钟 7.993 秒
  - 结果 `round-01/match_result.json`，mtime 11:03:24
- 套件：navigation-stability 0 失败；local-avoidance 0 失败；movement-recovery 2 失败（插建筑后误差 11.71 米）；movement-push-equivalence 5959 条里 1 条 `mutated near push`。后两条不归因于这一行类型标注。没有回滚这一行，也没有在它上面再改移动算法。

## 第 2 刀：不要抢走正在采的矿车

- 探索（改之前）：`--debugport 25998`，PID 44112，11:09:16–11:11:19，退出码 0。t=2 出现指派，动作变成 `Moving.gd`。首次交付 11.5 秒，之后仍能交付。
- 补丁后新局：`--headless --path G:/AIRTS/AI_RTS --quit-after 20000 res://tools/probe_harvest_loop_gen.tscn -- --debugport 25999`
  - 启动器 PID 27864，游戏 PID 38840，实例 `grok47-r2`，11:13:59–11:16:00，退出码 0，未超时
  - 没有「指派工人」，没有 `act=Moving.gd`
  - t=3 开始采集，dOre=2.68；首次交付 8.3 秒；累计 7 次 / 3500 矿
  - 退出 tick 2043，探针采样到 t=89 秒、450 个点，墙钟约 121 秒
  - stderr 没有 SCRIPT ERROR。实例登记退出后已删除
  - 日志 `round-02/match.stdout.log`，mtime 11:15:59
- 旧功能重放：PlainAndSimple 移动局，PID 33984，11:17:01，退出码 0，位移仍是 16.892 米，空闲位移 0。`round-02/move_result.json`
- 相关套件：`Refinery free miner smoke test completed: 0 failure(s)`，PID 44576，退出码 0，mtime 11:17:20

## 没做

- 布局 36 矿车停在矿外：本会话没有复现，没有改移动钳制。
- `MovingToUnit.gd` 落点：布局 47 上补丁前已经能贴到约 1.76 米并连续交付，没有把落点改动叠进去。
- `OreRefinerySmokeTest`（超时预算 420 秒）和全量回归没跑。
- 没有另一个会话做独立复核。
- 没有可见窗口，也没有截图。这两刀不改模型、红色幽灵或特效。
- movement-recovery 与 movement-push 的失败还开着。

## 回滚

只撤回自己的行，不要 `git checkout` 整文件。

- `Movement.gd` 把 `var who: String = str(_unit.name) if _unit != null else "?"` 改回原来的 `:=` 行。那样脚本会再次加载失败。
- `OreRefinery.gd` 删掉 `call_deferred("request_legacy_start_auto_gather")` 和 `CLAIMABLE_ACTIONS`，`_is_claimable` 改回 `return action_name in GATHERING_ACTIONS`。

## 下一步

从现在这两份文件的哈希继续。先复现布局 36 的停短，再决定要不要动 `Movement.gd` 的目标高度。不要在 recovery / push 的红套件上直接加例外。
