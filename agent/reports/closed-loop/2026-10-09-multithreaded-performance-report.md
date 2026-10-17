# 多线程与主线程性能闭环

2026-10-10 续测没有改这份历史记录。新数字在 `agent/reports/closed-loop/2026-10-10-multithreaded-performance-report.md`。

日期：2026-10-09  
状态：**needs-review**。第四轮把移动余量拆到具体调用。合并 `global_transform` 让移动中的单位不转向，已改回先写朝向、再写原点。远障碍坐标快照保留。产品路径仍是 400 单位 6.75 FPS。编辑器 PID 39676 / 38140 仍开着，朝向修复还没在游戏里复测。没有达到 1000 单位、30 FPS。  
开发根：`G:/AIRTS/AI_RTS`  
Champion：`source/match/units/traits/Movement.gd`。预剔除落地时的 SHA256 是 `d28c258168d15a6f864dbc868ce3602b3e2e31fd469ecb1f1b58cab85dd1df19`，本轮又加了诊断分项打印和平地贴地快路径，那个哈希已经不是当前字节。  
优化前同一文件：`7be4324db193e9381a8497e49f0449d57f4d8d76cc0b4b8eb0352ee2e952b53f`  
证据目录：`agent/runs/mtperf-2026-10-09/`

没有修改 `G:/AIRTS/打包版`，没有发布或覆盖 GitHub release，没有 git commit / push。`project.godot` 字节未变。没有打开 `physics/3d/run_on_separate_thread`。没有关避障、关碰撞、降低物理刻度或降低画质来换帧率。探针进程内临时把 `Engine.max_fps` 设为 0、VSync 关掉，用来看容量；这不写回玩家配置。

## 测量方法

引擎 `4.7.1.stable.mono.official.a13da4feb`。命令行由 `tools/dev/thread_perf_probe.py` 启动：

```text
G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe
  --path G:\AIRTS\AI_RTS --audio-driver Dummy --position 80,80 --resolution 1280x720
  res://tests/automated/_ThreadPerfProbe.tscn -- --debugport <动态端口>
```

控制台用 `CREATE_NO_WINDOW` 隐藏。场景是 PlainAndSimple 上的分散编组：每个单位一个坐标，每 4 秒沿 X 平移约 36 m，旁边有 3 座已完工车厂。采样窗 12 秒（400 单位为 8 秒），预热和出生不计入分位数。长帧保留。物理设置仍是 60 Hz。

线程 CPU 用 Windows `GetThreadTimes`，在日志出现 `SAMPLE_START` / `SAMPLE_END` 之间每秒采样。WPR 10.0.26100 已安装且当时没有在录，这次没有做调用栈采样，栈归因标 unavailable。`OS.get_thread_caller_id()` 打印为 1，不是 Windows 线程号，所以“最热线程”是按 CPU 时间推断的主线程，线程名标 needs-review。

`AIRTS_MOV_DIAG=1` 时才累加脚本微秒。回调时间包含推出，推出包含 hull，不能相加。物理 `_physics_process` 不包含稍后的 `velocity_computed`。

## 优化前

| 负载 | FPS | p50 | p95 | p99 | 最长 | 实际物理 Hz | 步/帧 p50 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 100 分散，诊断开 | 37.7 | 19.0 ms | 74.2 ms | 102.8 ms | 128.6 ms | 60.1 | 1 |
| 200 分散，诊断开 | 4.43 | 218.8 ms | 284.7 ms | 287.9 ms | 291.6 ms | 35.5 | 8 |
| 200 分散，避障多线程关 | 4.78 | 199.0 ms | — | — | — | 38.3 | 8 |

200 单位默认配置，12.18 秒墙钟里：回调 6.88 s，其中 hull 5.41 s、推出 6.04 s（含 hull）、`_physics_process` 1.55 s。距离剔除 85968 次，精确 footprint 只有 835 次。剔除发生在骨骼采样之后。线程切片只有 1 条线程超过每秒 20 ms，CPU 约 1.06 s/s。关掉避障多线程没有变快。主线程在计算，不是在等 worker。24 核和 `avoidance_use_multiple_threads=true` 没有变成并行加速。

高优先级避障线程关闭（B2）没有单独测。

## 改了什么

`Movement.gd` 的 `_push_out_of_static_obstacles`：如果所有更大的静态障碍都远于

`obstacle_radius + own_radius + (own_radius + 3m) + 0.1m + obstacle_radius`

就不再采样骨骼，直接返回原落点。3 m 是个人半径之外的视觉上界，故意大于已知的约 0.35 m 模型超出碰撞圆的量。进入这个距离带的障碍仍走原来的 hull、footprint 和推出。碰撞形状、避障半径、速度、射程、视野都没有改。

诊断计数默认关闭。

## 优化后

诊断开，和优化前同一插桩：

| 负载 | FPS | p50 | p95 | 实际物理 Hz | 步/帧 p50 | hull |
|---|---:|---:|---:|---:|---:|---|
| 100 | 134.0 | 4.96 ms | 16.0 ms | 60.1 | 0（渲染快于 60 Hz，中位帧没有物理步） | 0.140 s，原先 4.44 s |
| 200 | 20.8 | 40.8 ms | 106.0 ms | 60.5 | 2 | 0.143 s，原先 5.41 s；`precull_n=144045`；`cap_exceeded_n=0`；采样到的最大 hull 半径 2.934 m |

诊断关，才是产品路径。200 单位一次：

- FPS **28.04**，p50 **33.38 ms**，p95 **61.2 ms**，p99 75.6 ms，最长 126.1 ms
- 实际物理 **60.2 Hz**（优化前 35.5 Hz），步/帧 p50 为 2
- 避障开启 200，位移合计 3808 m，卡住 <0.15 m 的单位 0
- 主视口渲染 CPU p50 **0.84 ms**，GPU p50 **3.34 ms**
- 约 10 个一秒切片：最热线程 CPU 合计 10.37 s，其余线程合计 2.98 s。稳态切片里其余线程往往只有 0.02–0.11 s；有几个切片突然有 15–22 条线程超过 20 ms，但最热线程仍约 1.0 s/s，说明 worker 是叠在主线程计算旁边，不是主线程在空等

插桩本身在 200 单位上大约值 7 FPS（20.8 → 28.0）。优化前的对照是带着插桩测的，所以 4.43 → 20.8 是同一口径；28.0 是关掉插桩后的产品读数，没有对应的优化前“诊断关”读数。

400 单位、诊断关、8 秒：FPS **4.54**，p50 **220 ms**，p95 252 ms，最长 283 ms，实际物理 **36.4 Hz**，步/帧 p50 **8**。渲染 GPU p50 只有 5.6 ms。没有出现 >2 s 的灾难帧，但已经重新掉进补步。700 和 1000 没有再跑。

## 行为与画面

- 推出等价：5959 项，0 失败，rc=0。日志 `agent/runs/mtperf-2026-10-09/movement-push-equivalence.log`
- navigation-stability、local-avoidance、movement-recovery：marker 均为 0 failure(s)，rc=0。恢复日志 `agent/runs/mtperf-2026-10-09/movement-recovery.log`
- 截图：`r1-spread200-precull/fog.png` 与 `full_vision.png` 已打开。能看到成群坦克/步兵、地面和建造界面，模型没有被藏起来。两张图的迷雾差异不明显。
- 探针读到的画面：阴影开、体积雾开、3D 缩放 1.0、MSAA 0。MSAA 是当时视口读数，不是这次为了提帧改的。环境雾 `fog_enabled` 读数为 false，体积雾为 true；这次没有去关体积雾。

## 没有做完的步骤

- 每档三次、30 秒稳态窗
- B2：`avoidance_use_high_priority_threads=false`
- 密集汇聚、建筑出口、窄口、交战、采矿/生产、副官回放
- 700 / 1000 单位
- 恢复玩家 VSync/30 FPS 上限后再测一趟。解锁后 200 单位已经只有约 28 FPS，把上限设回 30 不会让它变快
- WPR 调用栈
- 全量回归没有跑。movement-recovery 已单独通过（rc=0，0 failure）
- 密集场景和异常堆叠没有当这次的成绩

退出时探针日志里有粒子/网格 RID 泄漏，这是进程退出清理，不是这轮断言失败。

## 下一个瓶颈

400 单位的帧是 220 ms，GPU 只有约 6 ms，所以不是靠降画质能解释的主因，也不该靠关避障。200 单位诊断开时，hull 去掉之后剩下的脚本大头是 `_physics_process`（约 2.69 s / 12 s，其中寻路查询只有 0.05 s）和回调里剩下的推出、转向、写位置（合计约 2.0 s，hull 只剩 0.14 s）。主线程仍然吃满约 1 个核，避障 worker 在稳态只占零点几个核。

已经排除的说法：

- “关掉 avoidance 多线程就会好”：优化前 200 单位关与开都在 4.4–4.8 FPS
- “主线程主要在等 RVO worker”：最热线程 CPU 约等于墙钟
- “渲染/体积雾是 200 单位的 33 ms”：渲染 CPU 0.84 ms、GPU 3.3 ms
- “RVO 占 95%”：旧结论仍然不能用；这次墙钟里最大的已测脚本块是 hull，而且它在距离判断之前就做了

上面这条“下一刀”已经在第二轮做完，见下一节。预剔除没有回退。

## 第二轮：拆开计时，再改两刀

采样窗改为 8 秒，其余命令行、场景、分辨率、Dummy 音频、隐藏窗口与上一轮相同。诊断默认仍然关闭；下面标“诊断开”的数字才包含脚本计时。

### 拆开（诊断开，200 分散，预剔除仍在，尚未做本轮两刀）

日志 `agent/runs/mtperf-2026-10-09/r2h-spread200-inout/`。墙钟 8.029 s，FPS 25.41，p50 37.82 ms，p95 59.93 ms，实际物理 60.04 Hz，步/帧 p50 为 2。避障 200，卡住 0。导航监视器 p50 5.36 ms，物理监视器 p50 21.51 ms，处理监视器 p50 23.50 ms，主视口 GPU p50 3.46 ms。

脚本微秒（不能把包含关系相加）：

| 块 | 时间 | 占这 8.029 s |
|---|---:|---:|
| Match 物理脚本合计（inside） | 3.270 s | 40.7% |
| 两次 Match 物理脚本之间（outside） | 4.748 s | 59.1% |
| 其中贴地 snap | 0.759 s | 9.5% |
| 补路 repair | 0.243 s | 3.0% |
| 脱困恢复 | 0.145 s | 1.8% |
| 寻路查询 | 0.031 s | 0.4% |
| 回调合计 | 1.309 s | 16.3% |
| 回调里的推出 / 转向 / 写位置 | 0.479 / 0.294 / 0.386 s | |

`outside` 是上一拍 Match 脚本结束到下一拍 Match 脚本开始，里面包含空闲 `_process`、主视口之外的视口更新和导航服务器，不是纯 RVO 等待。导航监视器只有约 5.4 ms/帧。200 单位产品路径稍后测到最热线程 6.22 s、其余线程 0.67 s，主线程仍在算。

### 第一刀：平地高度缓存

`Match.gd` 的 `ground_height_at`。地形碰撞顶点全部同高、变换没有把平面掀斜、并且和一次真射线一致时，以后直接返回这个高度。斜坡或高台顶点高度不同，仍走原来的射线。PlainAndSimple 日志打出 `G4PERF flat_ground_y=0.0`。

诊断开、200 单位，`r3b-spread200-flat`：FPS 25.41 → **28.11**，p50 37.82 → **35.14 ms**，p95 58.22 ms，实际物理 **60.21 Hz**，步/帧 p50 仍为 2。snap 0.759 s → **0.382 s**。卡住 0，避障仍是 200。阴影、体积雾、3D 缩放 1.0 未改。

### 第二刀：迷雾视口不要每帧重画同一张图

`FogOfWar.gd`。迷雾圈本来就是 0.1 s 同步一次。变脏后用 `UPDATE_ALWAYS` 画满两帧（避开以前 `UPDATE_ONCE` 首帧全黑），然后停到下一拍。对照截图 `r3b-spread200-flat/fog.png` 与 `r3c-spread200-foghold/fog.png`：单位、地面、小地图蓝点都在，小地图没有变黑。

诊断开、200 单位，`r3c-spread200-foghold`：FPS 28.11 → **32.30**，p50 35.14 → **28.42 ms**，p95 48.15 ms，实际物理 **60.12 Hz**，步/帧 p50 为 2。这一趟末尾多了一次折返（commands=3），净位移很小的单位有 41 个；位移合计仍有 922 m。产品路径那一趟没有这个问题。

### 产品路径（诊断关、帧率解锁、物理 60 Hz、避障开）

| 负载 | FPS | p50 | p95 | 实际物理 Hz | 步/帧 p50 | 日志 |
|---|---:|---:|---:|---:|---:|---|
| 200，本轮之前 | 28.04 | 33.38 ms | 61.2 ms | 60.2 | 2 | `r1-spread200-nodiag` |
| 200，本轮之后 | **40.29** | **23.68 ms** | **45.06 ms** | **60.12** | **1** | `r3d-spread200-product` |
| 400，本轮之前 | 4.54 | 220.2 ms | 251.5 ms | 36.4 | 8 | `r1-spread400-nodiag` |
| 400，本轮之后 | **5.15** | **190.3 ms** | **224.2 ms** | **41.35** | **8** | `r3e-spread400-product` |

200 产品路径：避障 200，位移合计 922 m，卡住 <0.15 m 的单位 1，最热线程 6.22 s，其余线程 0.67 s。主视口 GPU p50 3.27 ms。阴影开，体积雾开，3D 缩放 1.0。p95 45.06 ms，贴着容量门的 45 ms，但单位数不是 1000。

400 产品路径：避障 400，位移合计 1260 m，卡住 8，移动超过 0.5 m 的 303/401。处理监视器 p50 **61.6 ms**，物理监视器 p50 41.0 ms，导航监视器 p50 8.4 ms，主视口 GPU p50 7.1 ms。最热线程 6.44 s，其余线程 0.28 s。模拟已经落后（41 Hz，不是 60 Hz），引擎用满每帧 8 步。没有跑 700 和 1000：400 已经在补步，再加倍会把机器打进更长的补步，而且这一帧的构成已经说明补不上 30 FPS。

### 回归

日志在 `agent/runs/mtperf-2026-10-09/r3-suites/`。headless，`--path G:/AIRTS/AI_RTS`，`--quit-after 200000`，隐藏控制台。

| 套件 | 结果 |
|---|---|
| movement-push-equivalence | rc=0，5959 checks，0 failure(s) |
| navigation-stability | rc=0，0 failure(s) |
| local-avoidance | rc=0，0 failure(s) |
| movement-recovery | rc=0，0 failure(s) |

### 为什么停

1000 单位、30 FPS 没有达到。这一轮实际测到的最高档是 **400**。产品路径下 400 单位是 5.15 FPS，不是 30 FPS。

400 单位这一帧 190 ms 里，已经测过的可安全削减块不够把每步从约 24 ms（190 ms / 8 步）打到能稳住 60 Hz 的水平，更不够再乘到 1000 单位。剩下最大的监视器是空闲处理 61.6 ms。迷雾视口停画已经针对“每帧重画同一张迷雾”做过，200 单位帧时间下来了，但处理监视器仍在 23 ms 左右，说明这 61.6 ms 不是那两张迷雾视口。

再削一刀会碰到硬约束：

- 把阴影、体积雾、单位动画或网格拿掉，才可能再砍空闲处理。这是降画质。
- 把物理从 60 Hz 降下来，才能少跑补步。这是降模拟频率。
- 关掉避障或碰撞，才能去掉导航监视器那 8.4 ms 和单位碰撞的物理步。这被明确禁止。主线程 CPU 仍高于其余线程，不是在等避障 worker。

已经排除：渲染主视口是主因（200 单位 GPU 3.3 ms，400 单位 7.1 ms）；避障多线程开关是主因（上一轮关与开都在 4.4–4.8 FPS，这一轮其余线程 CPU 仍然远小于最热线程）；贴地射线是 400 单位补步的主因（拿掉平地射线后 400 单位仍是 8 步）。

上面「再削一刀会碰到硬约束」在第三轮测量之后不成立。空闲处理的主体不是阴影、体积雾或动画骨骼，见下一节。

## 第三轮：把 61.6 ms 和 41 ms 拆开

Godot 4.7.1 的 `TIME_PROCESS` / `TIME_PHYSICS_PROCESS` 是约一秒窗口里的**最大值**，不是典型帧的和，两块也不能相加。诊断开着的 400 单位分散（`r4s-spread400-msgxform`，8 秒，37 个空闲帧，296 个物理步）把空闲帧从 `_process` 结束拆到下一次 `physics_frame`：

| 段 | 平均 | 这一段是什么 |
|---|---:|---|
| 脚本 `_process` | 0.36 ms | 步兵动画驱动 0.95 ms/帧（含枪口 0.56 ms），迷雾逻辑 0.005 ms，摄像机 0.08 ms，小地图 0.03 ms，调试端 0.04 ms |
| `pre_idle` | 4.46 ms | 上一物理步在脚本之后的尾巴，加上固定步插值的第一遍 |
| `MessageQueue::flush` | **41.09 ms** | `_process` 之后、计时器之前的消息队列。变换通知刷新是 0 |
| 插值第二遍 + `NavigationServer3D::process` + `RenderingServer::sync` | 2.85 ms | 导航空闲 `process` 只调用烘焙器 sync |
| `RenderingServer::draw` | 4.76 ms | 主视口 GPU 在产品路径是 6.9–7.1 ms |

同一诊断档的物理步（平均值；监视器 43 ms 对得上单步脚本最大值 38.4 ms，不是每一步都这么慢）：

| 函数 | 平均 | 最大 |
|---|---:|---:|
| 对局物理脚本，从 `Match._physics_process` 到 `match_out` | 11.86 ms | 38.43 ms |
| 其中 `Movement._physics_process`（`r4b` 同场景） | 6.08 ms | — |
| 贴地 `snap` | 1.67 ms | — |
| 补路 `repair` | 1.06 ms | — |
| 脱困 `recovery` | 0.69 ms | — |
| `velocity_computed` | 5.73 ms | 9.10 ms |
| 其中推出 `push` | 1.76 ms | — |
| 转向 `rot` | 1.42 ms | — |
| 写原点 `write` | 1.44 ms | — |
| 物理服务器尾巴（导航回调之后到下一步） | 1.18 ms | 2.20 ms |
| 小地图物理 | 0.40 ms | — |
| 可见性 | 0.07 ms | — |

物理服务器本身不是 41 ms。导航监视器（含 RVO 和回调）的一秒最大是 11.9 ms。主线程在算，`r4i` 最热线程 7.61 s / 其余 0.45 s。

对照实验（都是 400 分散，不是产品路径，除非注明）：

- 关掉导航、关掉插值、隐藏网格、暂停动画、`top_level` 几何，消息队列这段仍在 40 ms 上下。
- 把单位移出场景树（`r4j`）后帧 p50 降到 0.89 ms，说明这段跟「单位还在树里」绑定。
- 产品路径把除碰撞体和 `NavigationAgent3D` 以外的子节点全部 `PROCESS_MODE_DISABLED`（`r5d`）：处理监视器从 61.6 ms 降到 **22.3 ms**，FPS 6.61，物理步监视器仍是 42 ms，步/帧仍是 8。
- 只停用 `actions/` 脚本（`r5e`，400 个 `WaitingForTargets`）：处理监视器 **22.9 ms**，FPS 6.09。索敌计时器就是那 40 ms 的主体。视锥外视觉停更只让处理监视器从 61.6 到 58.9，不是主体。

### 这一刀

`WaitingForTargets._get_units_to_attack`：场上只有一方单位时，每个渲染帧只数一次玩家归属，然后直接返回空结果。出现第二方或中立单位后仍走原来的网格索敌。另外视锥外 12 m 以外的几何、高亮、选择圈、血条和动画驱动停止 `_process`，碰撞和导航代理不停。预剔除、平地高度缓存、迷雾停画都还在。

产品路径（诊断关、帧率解锁、物理 60 Hz、阴影开、体积雾开、3D 缩放 1.0、避障开）：

| | 改前 `r3e-spread400-product` | 改后 `r6-spread400-product` |
|---|---:|---:|
| FPS | 5.153 | 6.212 |
| p50 / p95 | 190.3 / 224.2 ms | 159.3 / 193.5 ms |
| 实际物理 Hz | 41.35 | 49.82 |
| 步/帧 p50 | 8 | 8 |
| 处理监视器 p50 | 61.6 ms | 30.1 ms |
| 物理监视器 p50 | 41.0 ms | 44.4 ms |
| 最热 / 其余线程 | 6.44 s / 0.28 s | 6.33 s / 1.25 s |
| 位移 / 卡住 | 1260 m / 8 | 1587 m / 0 |

200 单位产品路径 `r6-spread200-product`：FPS **61.47**，p50 14.04 ms，p95 30.79 ms，物理 60.10 Hz，步/帧 1，卡住 1。没有退回 40 FPS 以下。

命令行与上一节相同，`--diag 0 --unlock 1 --count 400|200 --mode spread --seconds 8`。场景 `res://tests/automated/_ThreadPerfProbe.tscn`，地图 PlainAndSimple。日志：

- `agent/runs/mtperf-2026-10-09/r4s-spread400-msgxform/`（空闲分段）
- `agent/runs/mtperf-2026-10-09/r4b-spread400-split/`（移动函数分段）
- `agent/runs/mtperf-2026-10-09/r5e-spread400-product-noactions/`（只关索敌的对照）
- `agent/runs/mtperf-2026-10-09/r6-spread400-product/`
- `agent/runs/mtperf-2026-10-09/r6-spread200-product/`

没有测 700 和 1000。400 单位产品路径步/帧仍是 8，按任务要求不在补步时硬跑 1000。

### 回归

日志在 `agent/runs/mtperf-2026-10-09/r6-suites/`。headless，`--path G:/AIRTS/AI_RTS`，`--quit-after 200000`，隐藏控制台。`movement-push-equivalence` 另加 `-- --debugport 0`。

| 套件 | 结果 |
|---|---|
| movement-push-equivalence | rc=0，5959 checks，0 failure(s) |
| navigation-stability | rc=0，0 failure(s) |
| local-avoidance | rc=0，0 failure(s) |
| movement-recovery | rc=0，0 failure(s) |

headless 小地图读迷雾纹理时的 `Parameter "t" is null` 在第二轮 `r3-suites` 里已经有，套件标记仍是 0 failure。

### 还没到 30 FPS

1000 单位 30 FPS **没有**达到。实际测到的最高档仍是 400，产品路径 6.21 FPS。

剩下的主线程热点是物理步，不是画质。`r6` 的物理监视器 p50 44.4 ms 是一秒内最慢的那一步。`r4s` 里这一步的脚本最大是 38.4 ms（`Match._physics_process` 到单位脚本结束），平均 11.9 ms；`velocity_computed` 平均 5.7 ms（推出 1.8、转向 1.4、写原点 1.4），物理服务器尾巴最大 2.2 ms。按 `r6` 的帧时间粗算，八步的平均一步约 (159−30)/8 ≈ 16 ms，仍顶着 8 步上限。

下一刀**没有**被证明必须关碰撞、关避障、降物理频率或降画质。推出和写原点还在物理步里，但贴地、补路和索敌以外的单位脚本还没有逐个削完。不能把「再大的一刀会降画质」写成停止理由。

上面把 41 ms 标成 `MessageQueue::flush` 不准确。探针的 `ProcEnd` 优先级是 -1000000，Godot 里更小的优先级先跑，所以这段量到的是它之后其余节点的 `_process`，包括 `WaitingForTargets` 的 Timer。变换刷新仍然是 0。

## 继续削空闲和贴地

单方战场只留一个哨兵计时器，其余 `WaitingForTargets` 计时器停掉；出现第二方后再按原相位启动。平地且没有水域占用时，`Movement._snap_to_ground_height` 直接用 `Match` 已经算好的高度，Y 已经对齐就不再走 `has_method` 和射线。补路改成每 5 帧才查一次的试验（`r9-spread400-product`）FPS 6.68、卡住 2，没有比下面的 `r8` 更好，已经撤回。

诊断 400 单位、改完之后（`r8-spread400-split`，408 个物理步，51 个空闲帧）：

| 函数 | 每步平均 | 最大 |
|---|---:|---:|
| 对局物理脚本 | 9.58 ms | 41.7 ms |
| `Movement._physics_process` | 4.83 ms | — |
| 贴地 `snap` | 0.66 ms | — |
| 补路 `repair` | 1.01 ms | — |
| 脱困 `recovery` | 0.66 ms | — |
| `get_next_path_position` | 0.13 ms | — |
| 流场 `flow` | 0.21 ms | — |
| `set_velocity` | 0.04 ms | — |
| 上面没单列的移动函数体 | 2.12 ms | — |
| `velocity_computed` | 5.04 ms | 8.72 ms |
| 推出 `push` | 1.70 ms | — |
| 转向 `rot` | 1.34 ms | — |
| 写原点 `write` | 1.37 ms | — |
| 物理服务器尾巴 | 0.97 ms | 2.01 ms |
| 索敌网格维护 | 0.45 ms | — |
| 小地图物理 | 0.38 ms | — |

空闲帧：节点 `_process` 平均 5.79 ms（最大 17.4），其中视锥剔除 1.18 ms；插值第一遍 4.11 ms；绘制 4.42 ms；导航 `process` + 渲染同步 1.51 ms。索敌网格 `query_calls=0`，单方早退仍然有效。

产品路径（诊断关）：

| | `r3e` 改前 | `r6` 只做早退 | `r8` 哨兵 + 平地贴地 |
|---|---:|---:|---:|
| FPS | 5.153 | 6.212 | 6.748 |
| p50 / p95 | 190.3 / 224.2 ms | 159.3 / 193.5 ms | 145.7 / 178.3 ms |
| 实际物理 Hz | 41.35 | 49.82 | 53.61 |
| 步/帧 p50 | 8 | 8 | 8 |
| 处理监视器 | 61.6 ms | 30.1 ms | 21.5 ms |
| 物理监视器 | 41.0 ms | 44.4 ms | 39.5 ms |
| 导航监视器 | 8.4 ms | 10.1 ms | 11.0 ms |
| 主视口 GPU | 7.1 ms | 6.9 ms | 6.83 ms |
| 最热 / 其余线程 | 6.44 / 0.28 s | 6.33 / 1.25 s | 7.67 / 1.17 s |
| 位移 / 移动超过 0.5 m / 卡住 | 1260 m / 303 / 8 | 1587 m / 340 / 0 | 1898 m / 357 / 0 |

200 单位产品路径 `r8-spread200-product`：FPS **78.05**，p50 12.44 ms，p95 24.24 ms，物理 60.19 Hz，步/帧 1，卡住 1。没有退回 40 FPS 以下。

阴影、体积雾、3D 缩放 1.0 在 `r8` 的 presentation 里仍是开。`fog_enabled=false` 是环境距离雾，不是体积雾，探针没有改它。

命令行：

```text
python tools/dev/thread_perf_probe.py --out G:/AIRTS/AI_RTS/agent/runs/mtperf-2026-10-09/<目录>
  --count 400|200 --mode spread --seconds 8 --unlock 1 --diag 0|1 --threads default --timeout 180
```

场景 `res://tests/automated/_ThreadPerfProbe.tscn`，地图 PlainAndSimple。引擎是 `Godot_v4.7.1-stable_mono_win64_console.exe`，`--path G:/AIRTS/AI_RTS`。

日志：`r8-spread400-product/`、`r8-spread400-split/`、`r8-spread200-product/`。关避障的对照 `r8b-spread400-avoidoff/` 不是产品结果：FPS 52.6、步/帧 1，但位移只有 13.9 m，401 个里 400 个卡住，回调合计 8 ms。单位停了，不能当成避障可关的证据。

没有测 700 和 1000。400 单位产品路径步/帧仍是 8。

### 回归（哨兵和平地贴地之后）

日志在 `agent/runs/mtperf-2026-10-09/r8-suites/`。headless，`--path G:/AIRTS/AI_RTS`，`--quit-after 200000`。

| 套件 | 结果 |
|---|---|
| movement-push-equivalence | rc=0，5959 checks，0 failure(s) |
| navigation-stability | rc=0，0 failure(s) |
| local-avoidance | 第一次 rc=1，1 failure：集结终态 Arrived/Unreachable。同一套件立刻重跑 `local-avoidance-retry.log` rc=0，0 failure(s)。夹具自己写过集结时间随相位波动 |
| movement-recovery | rc=0，0 failure(s) |

### 函数级拆分（诊断开，400 单位，spread）

`r8-spread400-split` 里「移动函数体剩余 2.12 ms」和「`velocity_computed` 剩余约 0.6 ms」在 `r10c-spread400-split` 拆开。诊断开，384 个物理步，数字是合计微秒除以 384，单位 ms/步。这一轮的诊断计时本身留在未归入子桶的余量里，产品路径（诊断关）不付这部分。

| 调用 | ms/步 |
|---|---:|
| `Movement._physics_process` | 5.091 |
| 贴地 `snap` | 0.664 |
| 补路 `repair`（`get_current_navigation_path`） | 1.023 |
| 脱困 `recovery` | 0.694 |
| `get_next_path_position` | 0.138 |
| 流场 `flow` | 0.222 |
| `set_velocity` | 0.035 |
| 涉水钳制 `_clamp_through_water` | 0.475 |
| 寻路点归一化 `seek` | 0.138 |
| 上面八项合计 | 3.389 |
| 函数体里没落到这些调用的余量 | 1.702 |

这 1.702 ms 是每个子桶前后的 `Time.get_ticks_usec`。子桶已经把原来的 2.12 ms 拆成钳制 0.475、寻路归一化 0.138，其余是诊断戳，不是产品工作。

`_on_velocity_computed` 5.421 ms：推出 1.732、转向 1.478、写原点 1.426，三项合计 4.636，剩余 **0.785**。其中方向整理（`cb_prep` 1.677 减去转向 1.478）0.199，原点读取加 `limit_length`（`cb_step`）0.238，还剩 **0.348** 是写原点之前的 `origin_before` 读取和诊断戳。`get_euler` 只有 0.153，转向的大头是 `global_transform` 写入。`get_nodes_in_group` 0.221，骨骼 hull 0.232。`precull_n=153117`，大约 384×400 次推出里几乎全部在远障碍预剔除处返回。推出剩余的大约 1.3 ms 是每个单位再读一遍障碍的 `global_position`。

最慢脚本步：`r10c` 的 `max_script` **38.533 ms**，物理标记帧 **877**。这一步 `Movement._physics_process` 合计只有 **8.413 ms**，整个样本里最慢的单个单位也只有 **8.318 ms**。所以这一步大约 30 ms 不在移动函数里。`r12-spread400-split`（钳制早退和原点缓存之后，推出快照之前）把步间空隙也记了：最慢脚本步 **42.911 ms**（帧 775），这一步移动合计 10.295 ms，单位与单位之间的空隙合计只有 **1.207 ms**，样本里最大的单段空隙 **0.206 ms**。从 Match 物理开始到第一个移动脚本，平均 0.238 ms，最大 **11.530 ms**。空隙和这段前缀都盖不住那 30 ms，剩下的时间在最后一个移动脚本之后、`match_out` 之前。`r12` 还没有把这一帧的前缀和后缀分开记下；这个打印已经补进诊断，但带这个打印的探针还没跑成。

`r12` 是诊断开，FPS 5.702 不能拿来和产品路径 6.75 比。钳制桶从 0.475 ms 降到 0.234 ms，这是诊断里的桶，不是产品帧时间。

### 还没到 30 FPS

1000 单位 30 FPS **没有**达到。产品路径实际测到的最高档仍是 400，**6.75 FPS**（`r8-spread400-product`）。200 单位产品路径 78.05 FPS。没有测 700 和 1000。

### 未测的代码差异（`Movement.gd`，保留，未回退）

相对 `r12` 诊断时的源码，又多了两处，都还没有产品路径数字：

1. **远障碍坐标快照。** 新增 `_refresh_obstacle_precull` / `_precull_needs_exact`。每个物理步、每个障碍组只调用一次 `get_nodes_in_group`，把半径、实例号和 XZ 写进 `PackedFloat32Array` / `PackedInt64Array`。每个单位的预剔除改读这份快照，距离判据与原来相同。快照判定需要精确推出时，仍对活节点走原来的推出循环。障碍组是建筑/资源，不是单位。这一处不写朝向，保留。
2. **合并 `global_transform` 已撤回（转向回归）。** 见下一节。

平地涉水钳制早退和 `step_origin` 只读一次仍在。补路仍是每步查询，没有改回每 5 帧查一次。

### 转向回归（无人机不转）

用户在正在运行的对局里看到选中的无人机不朝移动方向转。飞机和地面单位走同一条 `_on_velocity_computed`。无人机 `domain = 0`（空域），`_physics_process_air_move` 算出平面方向后调用这个回调；地面单位由避障回调进入同一函数。视锥外视觉停更只关 `Geometry` 等子节点的 `_process`，不写根节点 `basis`。截图里无人机在画面内，不是这条造成的。

根因是回调里把转向改成延迟写入：`_rotate_in_direction(direction, true)` 只把 `Basis(Vector3.UP, new_yaw)` 放进 `_pending_basis`，最后用 `Transform3D(_pending_basis, next_origin)` 和位移合成一次 `global_transform`。改动前是先 `_unit.global_transform = Transform3D(Basis(Vector3.UP, new_yaw), origin)`，再单独写 `global_transform.origin`。合成一次写入时，物理插值只把原点记进插值状态，朝向留在出生值，单位平移但不转。`face_towards` 没有走延迟路径，所以站定转向不受影响；移动转向受影响。

修复：删掉 `_pending_basis` / `defer_write`。`_rotate_in_direction` 恢复为立刻写朝向，随后仍单独写原点。远障碍坐标快照、骨骼预剔除、平地高度缓存、迷雾脏了才重画、哨兵计时器、视锥外视觉停更、平地贴地都保留。

18:33 复核时编辑器仍在（PID 39676 父进程 explorer，子进程 38140，`--path G:/AIRTS/AI_RTS`）。没有再开第二个 Godot，四套移动测试和朝向探针都没跑。用户需要重新运行当前这局才能看到修复；已经开着的那局不会热更新这份脚本。

### 测量被编辑器挡住（2026-10-09 18:19 复核）

`tools/dev/thread_perf_probe.py` 在启动前枚举进程名含 `godot` 的进程。只要列表非空且没有 `--allow-parallel`，打印 `REFUSING: other Godot processes are running` 并以 rc=4 退出。官方数字不用 `--allow-parallel`。同一个工程目录再开 Godot 会和编辑器抢 `.godot` / 导入缓存，所以编辑器还开着时不启动第二个实例。

当时仍在的进程（没有结束）：

| PID | 父进程 | 命令行 |
|---|---|---|
| 39676 | 14448 `explorer.exe` | `"G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe"` |
| 38140 | 39676 | `G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe --path G:/AIRTS/AI_RTS` |

工程路径是 `G:/AIRTS/AI_RTS`。这是用户从资源管理器打开的编辑器，不是本轮探针。产品路径 400/200、四套回归、700、1000 都没有跑。需要用户关掉这个编辑器之后才能继续测量。

下一刀没有被证明必须关避障、关碰撞、降物理频率或降画质。上面这一刀还没量。主线程仍在算：`r12` 六个切片最热线程 CPU 6.594 s，其余线程 0.375 s。按 `r12`（快照之前）每步仍在主线程上的大块是推出 1.820 ms、转向 1.595 ms、写原点 1.467 ms、补路 1.058 ms。

### 玩家实际开局掉帧（不是 400 单位压力）

截图左上角 FPS 30 是帧率上限（`PerformanceGovernor` 锁 30，垂直同步开），不是 400 单位那档的 6.75 FPS。这一节只测正常开局规模。项目管理器进程 39676 还在，但窗口是项目选择器，命令行没有 `--path`，没有结束它。对局用控制台引擎另开，没有抢正在编辑的工程。

命令行（隐藏窗口，`--audio-driver Dummy`，1280x720）：

```text
G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe
  --path G:\AIRTS\AI_RTS
  res://tests/automated/_ThreadPerfProbe.tscn
```

地图 `PlainAndSimple`。`AIRTS_TPERF_UNLOCK=0`，所以 `max_fps=30`、vsync=1，阴影开，体积雾开，3D 缩放 1.0，物理 60 Hz，避障开。音频是 Dummy，听不到音乐解码。日志：

- 少量单位：`agent/runs/mtperf-2026-10-09/open-few-locked/`（开局 2 个单位：主基地和无人机；探针再放了 3 座完工工厂，移动采样时 movers=2）
- 中等规模：`agent/runs/mtperf-2026-10-09/open-40-locked/`（采样时 45 个单位，movers=41，避障 40）

两局 rc=0。无人机 `Unit_1` 朝向都是 −3.142 → 第一次移动后 −1.571 → 采样结束 1.571，转向修复还在，没有再把朝向和位移合成一次 `global_transform`。

| | 开局 2 单位 | 再加 40 个地面单位 |
|---|---:|---:|
| 进场 6 秒 p50 / p95 / p99 / 最长 | 31.30 / 47.29 / 80.28 / **179.41 ms** | 31.24 / 47.69 / 68.78 / **163.49 ms** |
| 最长帧出现在进场后 | 644.7 ms | 604.8 ms |
| 进场另一帧 | 196.5 ms 处 116.2 ms；物理监视器 55.6，处理监视器 111.2 | 165.1 ms 处 96.3 ms |
| 第一次移动后 2 秒最长帧 | 48.35 ms | 54.74 ms |
| 稳态 8 秒 FPS | 30.02 | 30.00 |
| 稳态 p50 / p95 / p99 / 最长 | 31.44 / 47.27 / 48.33 / 56.24 ms | 31.58 / 51.20 / 53.52 / 54.40 ms |
| 稳态超过 100 ms 的帧 | 0 | 0 |
| 实际物理 | 60.15 Hz，步/帧 2 | 60.24 Hz，步/帧 2 |
| 稳态物理 / 处理 / 导航监视器 p50 | 6.63 / 3.12 / 0.36 ms | 5.64 / 4.72 / 1.36 ms |
| 稳态 GPU p50 | 5.41 ms | 5.89 ms |
| 位移 / 卡住 | 15.57 m / 0 | 197.08 m / 0 |

p50 约 31 ms、p95 约 47 ms 是锁 30 帧再加垂直同步的节拍，平均仍是 30 FPS。玩家能感觉到的卡，是进场第一秒里那两帧：大约 0.2 秒时 96–116 ms，大约 0.6 秒时 163–179 ms。这两帧发生在单位还只有 2 个的时候，导航监视器只有 0.5–0.8 ms。179 ms 那一帧的物理监视器是 1.3 ms，处理监视器是 174.4 ms（含场景 `_process` 和渲染同步/绘制，是一秒窗口里的最大值，和这帧长度同一量级）。主线程在画第一批画面，不是在等避障线程，也不是 400 单位的移动脚本。第一次下令移动和之后 8 秒稳态都没有超过 100 ms 的帧。

没有为这次卡顿改玩法或画质。着色器首帧编译和侧栏/迷雾第一张画面叠在进场那一帧上，缩阴影或关体积雾才可能削掉它，那是降画质，这一轮不做。

### 取消玩家路径上的 30 帧上限

上面那一节的 30 FPS 是当时的帧率上限。2026-10-09 按玩家要求把这个上限从正常启动路径拿掉，不是只改探针的临时解锁。

原来两处会把对局锁在 30：

- `project.godot` 第 20 行 `run/max_fps=30`，现为 `run/max_fps=0`。
- `source/PerformanceGovernor.gd` 原第 32 行 `const DEFAULT_MAX_FPS := 30`。开局 `_ready` 始终执行 `Engine.max_fps = int(max_fps)`。`_load_config` 还用 `mini(loaded_fps, DEFAULT_MAX_FPS)` 把 `user://performance.cfg` 里的值夹回 30 并写回。现默认是 0。读到旧的 30 或 60 会改成 0 再写回，避免下次启动又锁上。本机 `app_userdata` 里当时没有这份配置。

垂直同步没有关。`project.godot` 里没有 vsync 项，引擎默认仍是开。物理 tick 没有改，仍是 60 Hz。`Movement.gd` 仍是先写朝向再写原点。

短测没有走探针的解锁（`AIRTS_TPERF_UNLOCK=0`；该探针在变量缺省时会自己把 `max_fps` 设成 0 并关掉垂直同步）。场景 `res://tests/automated/_ThreadPerfProbe.tscn`，隐藏窗口，日志 `agent/runs/uncap-fps-2026-10-09/`。rc=0。日志里是 `max_fps=0`、`vsync=1`、`physics_hz=60`。4 秒稳态：FPS 1025.36，帧时间 p50 0.896 ms、p95 1.508 ms、最长 6.462 ms，实际物理 60.24 Hz。这是隐藏窗口，没有落在显示器刷新率上；正常可见窗口开着垂直同步时，帧率会跟刷新率走。项目管理器进程 39676 没有 `--path`，没有结束它。


