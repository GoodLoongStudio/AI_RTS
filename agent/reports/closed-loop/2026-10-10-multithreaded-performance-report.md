# 2026-10-10 性能续测

状态：needs-review。1000 单位 30 FPS 未达到。最高实测负载仍是 400 单位。没有改 `G:/AIRTS/打包版`，没有 commit / push，没有改 GitHub release。`project.godot` 的 `max_fps` 仍是 0。探针进程内临时 `max_fps=0`、VSync 关，不写回玩家路径。物理 60 Hz，阴影、体积雾、3D 缩放 1.0，避障和碰撞开着。

开发根：`G:/AIRTS/AI_RTS`  
引擎：`Godot_v4.7.1-stable_mono_win64_console.exe`（`G:/AIRTS/godot_mono_471/...`）  
产品文件：`source/match/units/traits/Movement.gd`  
本轮结束后的 SHA256：`6C1004F21A8FAD18DF3C05145AB9C6BDD5E5C8A8116339C155EFEA8AED9375E6`  
这个哈希比功能 champion `72EB73A060DD2F3AF04494CF04E543C717580B8F78D91C0A0E18BDE307B3BAC4` 多了诊断计数（只在 `AIRTS_MOV_DIAG=1` 时累加）。产品路径（diag 0）的推出、朝向、原点写法没有改。

## 已保留的 champion（本轮没有重测）

400 单位产品路径 `r2-spread400-product`：FPS 6.893，帧 p50 144.223 ms，p95 163.893 ms，物理 54.900 Hz，步/帧 p50 = 8，位移 1839.513 m。一步约 18.028 ms，仍高于 16.667 ms，所以追帧停在 8 步。没有跑 700 / 1000。

200 单位 `r2-spread200-product`：FPS 63.166，帧 p50 14.600 ms，步/帧 1。

移动探针 `r2-move`：同一移动命令 16.892 m，不是 0。  
朝向仍是先写、再写原点，缩放保留。窄缝日志变量仍是显式 String。

## 本轮产品探针（都已退回）

命令模板：

```text
python tools/dev/thread_perf_probe.py --out <目录> --count 400 --mode spread --seconds 8 --unlock 1 --diag 0 --threads default --timeout 180
```

`AIRTS_GODOT` 指向上面的 mono console。`--path` 为 `G:/AIRTS/AI_RTS`。

### r5 小函数跳过重推出：更慢，已退回

热点调用改成先走一个小函数，远障碍就不再进入 `_push_out_of_static_obstacles`。判定与原来的预剔除相同。

日志：`agent/runs/mtperf-2026-10-10/r5-spread400-product/tperf.out.log`  
采样 8.149 s，rc 0。FPS 6.258，帧 p50 156.24 ms，p95 216.666 ms，物理 50.066 Hz，步/帧 8，卡住 0，位移 2068.075 m，移动超过 0.5 m 的 401，movers 401，避障 400。阴影 true，体积雾 true，缩放 1.0，物理设置 60。

相对 champion 的 6.893 FPS / 144.223 ms，帧更慢。已删掉小函数，调用恢复为直接 `_push_out_of_static_obstacles`。

### r6 预剔除改平方距离：更慢，已退回

`_precull_needs_exact` 里用 `dx*dx+dz*dz` 代替 `Vector2` + `distance_to`，上界公式没变。

日志：`agent/runs/mtperf-2026-10-10/r6-spread400-product/tperf.out.log`  
采样 8.002 s，rc 0。FPS 6.249，帧 p50 158.266 ms，p95 199.002 ms，物理 50.115 Hz，步/帧 8，卡住 0，位移 1402.048 m，移动超过 0.5 m 的 398。

相对 champion 更慢。比较已改回 `distance_to`。

两刀的 400 单位位移都不是 0。没有另跑 2 单位的 16.892 m 探针，因为两刀都已退回，champion 的那次结果仍在 `r2-move`。

## 本轮定位（diag 开，不是产品分数）

`r7-spread400-locate`，`--diag 1`。日志：`agent/runs/mtperf-2026-10-10/r7-spread400-locate/tperf.out.log`  
采样 8.340 s。FPS 4.077，帧 p50 234.221 ms，物理 32.732 Hz，步/帧 8，物理步 273。这是诊断开销下的帧时间，不能拿来和 6.893 FPS 比。

按 span 272 步折成每步：

| 段 | 每步 |
|---|---|
| 脚本窗口 `inside_us` | 14.360 ms |
| 窗口之间 `outside_us` | 15.978 ms |
| `Movement._physics_process` | 6.420 ms |
| `_on_velocity_computed` | 7.576 ms |
| 其中 `_push_out_of_static_obstacles` | 2.266 ms |
| 其中 `_rotate_in_direction` | 2.260 ms |
| 其中原点写入 | 2.145 ms |
| `_repair_missing_path` | 1.268 ms |
| `_update_recovery` | 1.194 ms |
| `_snap_to_ground_height` | 0.799 ms |
| 单位之间的空隙 | 1.024 ms |
| Match 标记到第一辆 Movement | 1.971 ms |
| 最后一辆 Movement 结束到 `match_out` | 4.886 ms |
| 小地图物理 | 0.511 ms |
| 视野 | 0.082 ms |
| 索敌网格维护 | 0.674 ms |

脚本窗口能被上面几项加总盖住：6.420 + 1.024 + 1.971 + 4.886 = 14.301 ms，对上 14.360 ms。4.886 ms 还不是一个函数名。小地图、视野、索敌网格加起来不到 1.3 ms。

先前更接近产品帧率的诊断拆分（插值关闭之后、空缝跳过之前，`r1-spread400-split`）里，同样三个写入是推出 1.572 ms、转向 1.441 ms、原点 1.458 ms。本轮 r7 的绝对值更高，因为整段诊断只有 4.077 FPS。排序没有变：回调里的推出、转向、原点，加上脚本窗口末尾那截还没点名的 4.886 ms。

## 采矿日志

`r2-harvest/stdout.log` 在 t=32 被截断，不是跑完的 90 秒。已看到的部分：首次交付 8.3 s，累计 3 次 / 1500 矿，动作一直是 `AutoGatheringResources.gd`，日志里没有「指派工人」。不能把它写成完整采矿验收。

## 下一步

先把脚本窗口末尾那 4.886 ms（diag）点到具体函数，再决定能不能减大约 1.4 ms/步。减不到这一截之前，400 单位的步/帧回不到 1，不要跑 1000。

已经证伪、不要再试：把预剔除搬出大函数、把平方距离换进预剔除、跳过 `get_current_navigation_path` 的拷贝、把 hull 分配挪到预剔除之后。朝向和原点不能合成一次 `global_transform`。不能关避障、不能降物理频率、不能关碰撞。
