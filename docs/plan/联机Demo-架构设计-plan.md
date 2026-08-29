# 联机 Demo 架构设计（供复核）

## Overview

给另一位 AI / 同事核对用的架构说明，不是操作手册。凭据不写在本文件；公网 IP 与端口见工作区根目录 `服务器信息.md`。

**产品口径（已冻结）：** 不发布的内测 Demo；目标是 **2–4 人** 打同一局遭遇战。不要按帧同步（lockstep）做这份 Godot 工程。

**网络口径（已冻结）：** **服务器权威 + 客户端画傀儡 + ENet UDP**。权威进程跑在腾讯云 Ubuntu 的一台无头 Godot 上；玩家用 Windows 客户端连公网 IP。

相关实现计划：`docs/plan/联机Demo-2到4人-plan.md`、`docs/plan/腾讯云内测部署-plan.md`。  
副官 LLM 网关是后一步，见 `docs/plan/服务器Agent与局服-yyp_test-plan.md`。本文件的联机层 **不依赖 Hermes、不依赖 Cursor MCP**。

## Current State Analysis

### 为什么不能 lockstep

现有单机模拟有三条不可跨机复现的事实：

1. 世界坐标是 `float`（`WorldPosition`），不是定点数。
2. `SimulationClock` 跟真实 `delta`，不是锁死的逻辑帧。
3. 地面/空中寻路走 Godot `NavigationServer3D`，各端各自烘焙、各自避让。

若只同步命令、各端自己跑 Match，几十秒内位置和交战会分叉。因此 Demo **不同步 lockstep**，也不做「只同步输入、各端重放」。

### 工程卡点（设计时必须面对）

- 玩法层原先几乎没有 `ENetMultiplayerPeer` / `@rpc`（仅编辑器插件）。
- `Match.gd` 曾断言全局最多 1 个 Human；HUD / `controlled_units` / 镜头 / 迷雾都绑这一个节点。
- `CommandRuntime` / `UnitCommandGateway` 已按 `issuerPlayer` 做所有权校验，适合作为「只在服务器执行」的入口。
- 图 `PlainAndSimple` 已是 4 人、50×50，正好当 Demo 图。战役（回声撤离）保持单机。
- 家宽 NAT/CGNAT 常见，**不要用某个人电脑当主机**。这台云主机的公网 IP 才是存在理由。

### 代码与部署进度（复核时请当「现状」而不是「愿景」）

| 项 | 状态 |
|---|---|
| 本机玩家身份、大厅、命令 RPC、10Hz 快照 | 代码已写在 `yyp_test` 工作区，**尚未双进程/公网验收** |
| 云上无头局服 | 已用 Godot 4.7.1 Mono `--headless -- --server` + systemd `airts-game` 拉起，进程在听 **UDP 24567** |
| 腾讯云安全组 UDP 24567 | **仍需人工在控制台放行**，否则外网连不上 |
| Linux `dedicated_server` 导出包 | 预设已加，**当前云上跑的是工程源码 + 编辑器无头**，不是导出可执行文件 |
| Windows 客户端 zip / nginx 分发 | 未做；测试同学暂用本机 Godot 打开工程 |
| Hermes Dashboard（TCP 80） | 同机另有服务，**与对局协议无关** |

## Implementation Strategy

### 拓扑

```text
玩家 Windows 客户端 × 2–4
  · 镜头、选中、本机 HUD、本机战争迷雾（只挡自己屏幕）
  · 不跑寻路 / 战斗 / 规则 AI / 施工推进
  · 点击 → RPC 命令到 peer 1
        │
        │  ENet  UDP  24567
        ▼
腾讯云 Ubuntu 无头 Godot（专用服，不占 Human 槽）
  · 权威 Match：生成单位、CommandRuntime、NavigationServer、经济、胜负
  · 约 10Hz 全量广播：单位 path、pos、yaw、hp；玩家 resource_a/b
  · 开局后出生/死亡：spawn / despawn RPC
  · 空槽：规则 AI（SimpleClairvoyantAI），只在服务器跑
```

同时只开 **一局**。没有房间列表、没有第二实例。

### 为什么是这套而不是常见替代

| 方案 | 结论 |
|---|---|
| 帧同步 / 只同步命令 | 否。float + 真 delta + NavigationServer 不可复现 |
| 某玩家 listen server | 否。家宽 NAT；Demo 正式测试一律连云 |
| Steam / 多房间 / 中途加入 / 重连 | 否。超出 Demo |
| 服务器只做中继、客户端仍模拟 | 否。仍会分叉 |
| 把 Cursor MCP / Hermes 当「联机通道」 | 否。MCP 是编辑器调试；Hermes 是后来装的 Agent 面板 |

### 职责切分：服务器有什么 / 本地有什么

#### 腾讯云（权威侧）

- 仓库：`/home/ubuntu/AI_RTS`，分支意图钉死 `yyp_test`。
- 进程：Godot 4.7.1 Mono 无头；systemd 单元 `airts-game`。
- 启动：`--headless --path … -- --server`（用户参数 `--server` 走 `NetSession.try_start_from_cmdline`）。
- 监听：UDP 24567（ENet）。专用服 **不占** Human 槽，`local_player_index = -1`，无 HUD。
- 运行时：完整 Match 场景树 + C# `CommandRuntime` / `EconomyRuntime` / `ProductionRuntime` + 两套 `NavigationRegion3D`。
- 同机其它东西（不要和局服搞混）：nginx、Hermes Dashboard（本机 9119，外网 80）、SSH 22。它们 **不参与** 单位移动和伤害。
- **没有：** 显示器上的游戏窗口、玩家键鼠、Forward Plus 出图、公网暴露的 Godot 编辑器 MCP。

#### 每个玩家的 Windows（表现 + 输入侧）

- Godot 4.7.1 Mono 打开同一工程（或以后的 Windows 导出包）。
- 主菜单 → **联机 Demo** → 填云 IP:24567 → 加入 → 准备。至少 2 人全部准备才开局。
- 本机职责：相机、框选、命令栏、把命令发给服务器、按快照改单位 Transform/HP/资源条、本机 FoW。
- 本机 **不** 作为权威：`NetSession.is_client_puppet()` 时吞掉 `Unit.action`、跳过 `Movement` 物理、跳过施工/生产推进、规则 AI `_ready` 早退。
- 单人战役 / 自定义战斗：**完全离线**，不连这台云。菜单仍只允许一个 Human，避免破坏单机。
- 开发自测可用「本机开房」（listen server，主机也是一个 Human）。**给朋友打不要用这个。**

### 会话与开局

1. 专用服启动即 `create_server`。最大客户端数 = 4（专用服自己不是玩家）。
2. 客户端连上后由服务器分配槽位 0..3，RPC 告知 `local_slot`。
3. 每人点准备；`connected_human_count ∈ [2, 4]` 且槽内全员准备 → 开局。
4. 开局后不接受新玩家（不重连、不中途加入）。注意代码现状与本条原表述有出入：`_on_peer_connected` 在 `_match_started` 后是**静默忽略**而非显式拒绝（复核 P1-3）；掉线也只是弹文案、对局事实继续（复核 Q9）。
5. 所有端用同一份 `MatchSettings`：前 N 个槽 Human，其余 SimpleClairvoyantAI；地图固定 `res://source/match/maps/PlainAndSimple.tscn`。
6. 各端 **各自** 走现有 `Loading.tscn` 实例化 Match（导航要烘焙）。用 Autoload `NetSession` 上的 `notify_match_ready` 握手；**全部 Human 端 Match 就绪后** 服务器才开始快照/出生死亡 RPC。  
   初始单位依赖「同一设置、同一生成顺序、同一节点路径」。开局之后的生产单位走 spawn RPC，不假设客户端自己造出来。  
   **握手必须升级**：`notify_match_ready` 目前只是个布尔，NodePath 错位时客户端 apply 端静默 `continue`（`NetSync.gd:109`），错了不报错。客户端 ready 时须上报初始单位相对路径清单哈希 + 版本串（git commit），服务器比对不一致就拒绝开局并打差异（复核 P0-1）。

### 身份

- `MatchSettings.local_player_index`：联机 = 本 peer 槽位；专用服 = -1；单机 = 菜单里那个 Human 的下标（或唯一 Human 回退）。
- `Match.get_local_player()` 取代「全局唯一 Human」断言。
- `controlled_units` 只加给 `local_player` 的单位。其它 Human 的 `UnitActionsController` / 蓝图放置在 `Match.ready` 之后禁用，避免 4 个控制器都吃同一点击。
- 命令 RPC **不信任客户端自报槽位**，用 `multiplayer.get_remote_sender_id()` → `NetSession.slot_of`。

### 命令路径

```text
本地 HUD / UnitActionsController
    → NetSession.command_gateway_for(player)
        客户端：NetCommandProxy → NetSync.forward_command → rpc_id(1)
        服务器/单机：真正的 UnitCommandGateway
            → CommandRuntime / UnitCommandService（issuer 所有权校验）
```

生产队列在客户端 `produce()` 会转成 `"produce"` RPC，由服务器再走权威 `ProductionRuntime`。

建造蓝图目前仍是本机 `StructurePlacementHandler` 交互；**把蓝图变成服务器上的施工现场** 仍是薄弱点，复核时请单独看。

### 快照与实体生命周期

- 频率：每 6 个物理帧（默认 60Hz 物理 → 约 10Hz）。
- 通道：`@rpc("authority", "unreliable")` 全量 Array（单位字典 + 资源字典）。Demo 不做视野裁包、不做 delta。
- 带宽估算：一局 4 人、单位量级几十、10Hz 全量，大约 **1 Mbps**；云主机约 12 Mbps 只跑这一局够用。注意单个快照粗估 4–5KB，超 ENet MTU（约 1400B）会分片，任一片丢则整包丢；公网若见规律性卡顿，按单位分组拆 2–3 个 unreliable RPC（复核 P1-4）。
- 客户端 `apply_client_snapshot`：按 NodePath 写 `global_position`、`rotation.y`、`hp`，以及 `Player.apply_authoritative_resource_snapshot`。
- 开局后 `unit_spawned` / `tree_exited` → reliable spawn/despawn。单位网络 ID **暂用 Match 相对 NodePath**，不是稳定 GUID。
- 竞态：全员就绪握手完成（go-live）前服务器模拟已在跑，窗口期内的 spawn/despawn **不会补发**，客户端会永久漏/多单位；go-live 时服务器应广播一次全量单位清单，客户端释放多余、补 spawn 缺失（复核 P1-5）。快照先于 spawn 到达是安全的（apply 跳过未知路径）。

### 刻意砍掉（复核时不要建议「补成产品」除非指出 Demo 会坏）

Steam、房间列表、断线重连、中途加入、多房间、HTML5、战役联机、AI 副官联机、反作弊、锁帧、按迷雾过滤快照、家宽主机作为正式路径。

### 和「Agent 工具」的边界

策划文档里的 Agent = 副官 Observation / Intent / `RemoteLLMPolicy` / `QuerySourceKind.Agent`。  
那是局服本机回环上的后一步，**不是** 本联机 UDP，也 **不是** 已装的 Hermes。联机验收不需要 LLM。

## Implementation Steps

（实现勾选见 `联机Demo-2到4人-plan.md`。本文件只保留架构相关顺序。）

1. 身份改成 `local_player`（单机回归不能坏）。
2. 大厅：加入云服 / 开发用本机开房；2–4 人准备后开 `PlainAndSimple`。
3. 客户端命令只 RPC；服务器执行；10Hz 快照；开局后 spawn/despawn。
4. 云上无头进程 + 安全组只放行 **一个 UDP 游戏口**（另保留 SSH；80 是 Hermes/下载，与对局分离）。
5. 验收：先本机双进程能看见对方移动，再两台公网电脑打完一局。

## Timeline

| 阶段 | 可玩标准 |
|---|---|
| 架构冻结（本文） | 复核 AI 无否决项，或否决项被设计师拍板 |
| 本机双进程 | 两窗口互相看见移动 |
| 云上 2 人 | 安全组已放行；两台不同网络电脑打完 Plain & Simple |
| 3–4 人 | 空槽 AI 或空着；掉线即结束 |

## Risk Assessment

| 风险 | 设计选择 / 已知债 |
|---|---|
| 各端各自实例化 Match，NodePath 对不上 | 同一设置 + 生成顺序；握手后再快照；开局后单位改 spawn RPC。仍脆弱，见下方复核问题 1 |
| 客户端漏网本地模拟 | `is_client_puppet` 吞 action、停 Movement、停 C# Advance、停规则 AI。遗漏的 `_process` 仍可能改血 |
| 快照无插值 | 10Hz 会顿。Demo 可接受；要顺可以后加 |
| 施工蓝图只在本机存在 | 建造联机可能坏；移动/攻击是第一验收 |
| 全量快照含迷雾外敌军位置 | 有意：服务器全知，客户端自己算 FoW。会让开雾软件更容易，Demo 不防 |
| 掉线 | 已扶正（2026-08-29）：掉线者单位由服务器清空、对局继续、歼灭规则自然结算（掉线算负）；全员掉线专用服自动退出等 systemd 重启。不做重连 |
| NodePath 静默分叉 | apply 端对未知路径 `continue` 不报错（`NetSync.gd:109`），公网上无法排查；握手清单校验已实施兜底（P0-1） |
| 无头剥掉导航 | 当前跑的是完整工程 headless，不是剥渲染的 dedicated 导出；导出后必须再验寻路 |
| `global.json` 钉 8.0.423 | 仓库提交里是 `rollForward: "disable"`；本地未提交改成了 `latestFeature`——**不够**：rollForward 只向上滚、永不向下，服务器 8.0.130 怎么都满足不了 8.0.423。且 Godot 编 C# 走的就是 dotnet CLI，「靠 Godot 自己编」绕不开。修法三选一（复核 P0-3）：pin 降到 `8.0.100`+`latestFeature`（最省事，本机 8.0.423 / 服务器 8.0.130 都过）／服务器装 ≥8.0.423 SDK／预编译 DLL 随部署走。改完必须 commit+push。先上服务器跑 `dotnet --list-sdks` 确认程序集来源——「进程在听」说明它现在有来源，但不可复现 |
| 安全组未放行 UDP | 进程在听不代表外网能进 |
| 同机 Hermes 占 80 | 不要把游戏改成走 TCP 80；对局保持 UDP |

## Success Criteria

- 架构被接受的标志：复核方同意「云上权威 + 客户端傀儡 + ENet」，且不把 lockstep / 家宽主机 / Hermes 当联机方案。
- 玩法标志：2 人 Windows 连云，在 Plain & Simple 能看见对方单位移动（攻击能打上更好）。
- 单机战役与自定义战斗入口仍可离线玩。
- 不宣称可发布。

## Progress Tracking

- ✅ 架构决策写进本文（待外部 AI 复核）
- ✅ 代码按此架构落地（身份 / 大厅 / RPC / 快照）
- ✅ 云上无头进程已在听 UDP 24567
- ✅ 外部 AI 复核意见吸收（2026-08-29：总评「有条件同意」，P0×3，见文末复核结论）
- ✅ 复核 P0/P1 代码实施 + 上云部署（2026-08-29：服务器 HEAD `5be8a3d`，`dotnet --version` 解析 8.0.130 通过，UDP 24567 监听中；本地 push GitHub 待人工凭据，部署走 git bundle：`/tmp/airts-net-fix.bundle`，服务器旧工作树已 stash 为 `pre-deploy-backup-20260829`）
- ⏳ 本机双进程验收
- ⏳ 安全组 UDP 24567
- ⏳ 2 人公网试玩

## Related Files

- `source/net/NetSession.gd` — 大厅、槽位、专用服、`local_slot`、握手
- `source/net/NetSync.gd` — 命令 RPC、快照、spawn/despawn
- `source/net/NetCommandProxy.gd` — 客户端 Gateway 外形
- `source/main-menu/Online.gd` / `Online.tscn` — 联机 Demo 菜单
- `source/match/Match.gd` — `get_local_player()`
- `source/data-model/MatchSettings.gd` — `local_player_index`
- `source/csharp/GodotAdapter/Input/UnitCommandGateway.cs`
- `source/csharp/GodotAdapter/Composition/CommandRuntime.cs`
- `source/match/units/Unit.gd`、`traits/Movement.gd`
- `docs/plan/联机Demo-2到4人-plan.md`
- `docs/plan/腾讯云内测部署-plan.md`

---

## 给复核 AI 的说明（请直接评对错，不要扩成产品需求）

你在审一份 **2–4 人、不发布、Godot 4.7.1 Mono、已有大量单机 C#+GDScript** 的 Demo 联机方案。请重点回答下面问题；若某条「可以以后再做」，请标明是否会让 **第一局两人互相看见移动** 失败。

1. **各端各自 Loading 出一份 Match，用 NodePath 当网络 ID**，是否可接受？是否必须改成「只在服务器生成、客户端全靠 spawn」？
2. **10Hz 不可靠全量快照、客户端不插值**，两人互看移动是否够？要不要一上来就 delta / 插值？
3. **战争迷雾只在本机算、快照不裁敌军**，和策划「雾外真值不给 Agent」是否冲突？（联机第一期副官不开。）
4. **空槽填规则 AI（只在服务器跑）** 是否比空着更合适？
5. **当前云上用编辑器无头跑工程**，而不是 `dedicated_server` 导出，对 Demo 是否可接受？
6. 大厅 RPC 放在 Autoload `NetSession`、对局 RPC 放在 Match 下动态节点 `NetSync`，Godot 4 多玩家路径一致性有没有坑？
7. 专用服不占 Human 槽、`call_local` 开局，是否合理？
8. 建造/生产相对移动，哪些必须进第一期，哪些可以坏着？
9. 掉线即整局结束，有没有 Demo 级的更小补丁值得做（例如该玩家单位停手但局继续）？
10. 有没有 **否决项**：不改就会在公网第一局必然失败？

请用「同意 / 有条件同意 / 否决」给总评，并列出按优先级排序的修改建议。不要建议改回 lockstep，除非能证明现有 NavigationServer + float 能确定性重放。

---

## 复核结论（2026-08-29，已对照 yyp_test 实际代码）

**总评：有条件同意。** 架构方向（云上权威 + 客户端傀儡 + ENet UDP）正确，拒绝 lockstep 的论证成立（float + 真 delta + NavigationServer 三处不可复现，无法确定性重放，不再讨论）。无架构级否决项。复核时逐行对了 `NetSession.gd` / `NetSync.gd` / `Match.gd:59-85` / `Player.gd:38` / `global.json`（含 git 未提交改动），不是只评文档。

### P0（公网第一局前必须落地，缺一会挂或挂了没法查）

1. **握手加「初始实体清单 + 版本串」校验**（对应 Q1）。NodePath 方案的失败模式是**静默**：`NetSync.gd:109` 对未知路径 `continue`，表现为"部分单位永远不动/隐形"。修法：客户端 ready 时上报初始单位相对路径清单哈希 + git commit；服务器比对不一致拒绝开局并打差异。约 20 行，把静默分叉变成启动期明示错误。（✅ 已实施并上云 2026-08-29：各端 match_started 时上报排序路径清单，服务器比对，不一致 `_rpc_abort` + 拒绝 go-live）
2. **安全组放行 UDP 24567**（已在清单，纯人工）。（⏳ 待人工在腾讯云控制台操作）
3. **global.json 改 pin 并推送**。rollForward 只向上不向下，服务器 8.0.130 永远满足不了 8.0.423（本地未提交的 `latestFeature` 改动救不了）；且 Godot 编 C# 走 dotnet CLI，绕不开。推荐 pin 降到 `"8.0.100"` + `latestFeature`（两端都过），改完 commit+push，服务器上 `dotnet --list-sdks` + 试跑一次 `dotnet build` 确认。（✅ 已实施并上云：pin 8.0.100+latestFeature，服务器 `dotnet --version` 解析 8.0.130 通过）

### 逐条回答

**Q1（各端各自实例化 + NodePath 当 ID）：有条件同意。** 不必改成"只在服务器生成、客户端全靠 spawn"——初始实体全走 spawn RPC 只是把风险从"树不一致"换成"启动期大量 spawn RPC 的时序"，工作量更大。真正软肋是错了不报错，P0-1 补上后方案成立。后续优化（P2）：快照键换整型 net id（开局按生成顺序编号，spawn RPC 带 id），顺带砍掉快照里最大带宽项（路径字符串）。

**Q2（10Hz 不可靠全量、不插值）：同意，但建议演示前加插值。** 正确性够，"互相看见移动"成立。两个观感事实：① 10Hz 直接写 transform = 单位每秒瞬移 10 次，移动多的 RTS 看起来像坏了；~20 行两快照线性插值（渲染落后 100–150ms）可解，不阻塞双进程验收，阻塞"拿去演示"。② 自己下的命令要等 RTT+最多 100ms 才看到自己单位动——无客户端预测的固有延迟，RTS 可接受，**不要**为此上预测。顺带：快照应带服务器帧号——`NetSync.gd:124` 传给 `apply_authoritative_resource_snapshot` 的 version 是客户端本地 `_frame`（客户端恒为 0，`Player.gd:39` 的版本去重防线形同虚设；当前无害，因为 0 永不触发 `<` 拦截，但这是个死参数）。

**Q3（FoW 本机算、快照不裁敌军）：同意。** 与「雾外真值不给 Agent」不冲突：副官走服务器侧数据源，雾过滤在服务器侧做；第一期副官不开。客户端收全图是已声明的 Demo 取舍，风险表已如实记录，保留。

**Q4（空槽填规则 AI）：有条件同意。** 比空着好：2 人局在 4 人图上有 AI 更像正式对局。条件：做成大厅可选项（默认填）——2 人想纯 1v1 时两个 AI 是干扰。

**Q5（编辑器无头 vs dedicated 导出）：有条件同意。** 进程已在听，Demo 可接受。条件就是 P0-3：C# 程序集来源必须可复现。附带代价：进程更重、跑的是源码工程（分支钉死 yyp_test，文档已写）。换 dedicated 导出后「重验导航」保留——预设剥离内容后导航烘焙要重新确认。

**Q6（大厅 Autoload / 对局 Match 下 NetSync）：同意，无结构性坑。** Godot 4 RPC 按接收端节点绝对路径寻址，坑全在路径一致性：① 现状所有端统一走 `_start_loading` 换场景 + `Match.gd:61-63` 统一 `add_child(NetSync)`，路径一致，成立；② 握手日志里打出 `NetSync.get_path()`，公网首连人工核对一次（路径错位的症状是 RPC 静默不到达，极难查）；③ 对局结束 Match 销毁前，服务器先 `_live=false`，否则向已释放路径发 RPC 刷错误。

**Q7（专用服不占槽 + call_local 开局）：同意。** `local_player_index=-1` + `visible_player=0` 回退已正确处理（`Match.gd:73-75`）；HUD/相机在 `_is_dedicated_or_headless()` 下已跳过（`Match.gd:81`）。实现期 checklist 保留：服务器上 `get_local_player()` 返回 null 的所有调用点必须早退。

**Q8（建造/生产哪些进第一期）：** 第一期门槛 = 移动/攻击/资源快照/生产 spawn。建造的命令路径其实已在（`_rpc_command` 覆盖 `construct`/`cancel_construct`），蓝图 ghost 保持本机没问题；验收要盯的是服务器端施工现场实体是否经 spawn RPC 出现在其他端、施工 hp 是否同步——通了建造就基本可用，不通也只是表现缺失，不阻塞移动/攻击验收。「建造联机可能坏」的判断维持。

**Q9（掉线）：有更小的补丁，且现状代码已在事实执行它。** `_on_peer_disconnected` 只弹「本局结束」文案（`_rpc_abort` 只设状态字串），对局实际在继续；掉线者槽位被 erase 后其命令天然被拒（`slot_of` 返回 -1 → `NetSync.gd:163` 拦掉），单位停手。建议扶正这个事实行为：文案改「XX 已掉线，单位停手，对局继续」，胜利判定把掉线者算负。比「整局结束」省掉公网测试最烦的重开成本，也比实现真结束（回大厅、释放 Match）省代码。3–4 人阶段前做完，不阻塞双进程。

**Q10（否决项）：无。** P0 三条是「不改公网第一局大概率挂或挂了没法查」；P1 是体验与健壮性；「刻意砍掉」清单维持，尤其不要回 lockstep。

### P1（双进程能跑，公网前建议做）

1. 客户端两快照插值（Q2）。（✅ 已实施 2026-08-29）
2. 掉线处理扶正（Q9）。（✅ 已实施 2026-08-29，实现取"清空该玩家单位"而非"停手"：歼灭规则 `LastSurvivingSideRule` 依赖 combatant 退出事件，清单位才能让"掉线算负"真正触发结算；2 人局掉线即刻分出胜负，3–4 人局其余人继续）
3. 开局后新连接显式拒绝：`_on_peer_connected` 在 `_match_started` 时静默 return，后来者挂在大厅死等；补 `_rpc_reject` + `disconnect_peer` 两行。（✅ 已实施 2026-08-29）
4. 快照 4–5KB 超 ENet MTU 分片问题，必要时按单位组拆包（见「快照与实体生命周期」节）。（⏸ 未实施，公网观察到规律性卡顿再做）
5. go-live 对账：窗口期 spawn/despawn 不补发，服务器 go-live 时广播全量单位清单，客户端释放多余、补 spawn 缺失（2 人快连概率低，机器慢/人多时上升）。（✅ 已实施 2026-08-29：`_rpc_reconcile`，路径不符的单位生成后校验并移除）

### P2（可以以后）

- 整型 net id 取代 NodePath 键（Q1）。
- 快照带服务器帧号，修活资源版本去重（Q2）。
- `resources_payload` 的 `slot` 用 players 组遍历顺序当索引（`NetSync.gd:143` 服务器端 / `:121` 客户端）——两端树一致所以碰巧正确，建议显式带玩家下标。
- `NetSession.gd:193` `dedicated_server = dedicated_server` 是有意的自保（重置时保留专用服标记），但长得像 bug，迟早被人"修"成 `= false` 搞坏服务器重开——加行注释。
- dedicated_server 导出替换编辑器无头（之后必须重验导航）。

### 本次复核改动本文档的位置及理由

- 「会话与开局」第 4 条：原表述（拒绝新连接 / 掉线整局结束）与代码不符，按代码现状改写并指向修法。
- 「会话与开局」第 6 条：补握手清单校验要求（原握手只有布尔，静默分叉不报错）。
- 「快照与实体生命周期」：补 MTU 分片与 go-live 竞态两条（原节未覆盖）。
- 风险表：global.json 行按事实重写（原行把修法当开放问题；实际 rollForward 不向下滚，只有降 pin／装新 SDK／带 DLL 三条路，且本地改动未提交）；新增「掉线名不副实」「NodePath 静默分叉」两行。
