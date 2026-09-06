# AI_RTS 项目笔记（长期）

## 项目概况
- Godot 4.7.1 Mono + .NET 8 的 RTS 游戏（基于开源 OpenRTS 改造），目标做"AI 副官/LLM 军官"即时战略。
- 架构：双轨 —— Legacy GDScript（source/，match/net/campaign 等）+ 新 C# 分层（source/csharp/Domain|Application|GodotAdapter，AI_RTS.Core.csproj 独立 Core 程序集，101 纯 C# 测试 + 31 Godot 自动场景）。
- 当前分支 yyp_test（origin/yyp_test），规范文件：docs/项目统一规范.md（Canonical，最高优先级）。docs/plan/ 下 30+ 单功能 plan 文档（✅/⏳ 标进度）。
- Git 提交信息中文（"功能: xxx""修复: xxx"）。**并行会话（Codex 等）同时改此 repo，动手前先 git status/diff 确认文件没被外部改过。**

## 铁律：所有新功能必须覆盖全部模式（自定义战斗/联机/战役）
- 三者共用 Match→RA3Sidebar→balance/manifest（联机走 NetSession._start_loading + NetSync 转发 produce/place_structure，AI 在专用服/主机侧跑）。
- 新增单位/建筑同步 5 处：unitTypes/constructions/productions（config/balance/demo.balance.v1.json）、demo.assets.v1.json（manifest：scenePath+blueprint）、DemoBalanceRequirements 白名单（BalanceCatalogContracts.cs）、RA3Sidebar 页签、对应测试。改完跑 Godot 自动测试 + 真实联机双端验证。

## 当前状态（2026-09-06 交接，详见 .workbuddy/memory/HANDOFF-2026-09-06.md）
- ✅ 已完成：科幻换模全套（步兵 GLB 动画版/坦克/工厂/兵营/炮台）、步兵期1+2（生产/部署/交战/AI出兵）、阵营色区分（team_tint.gdshader 去饱和+阵营色）、主基地换模（Pod_Research_05 穹顶）、开局=主基地+1无人机+2工人、联机大厅三连修（准备后开局/房主判定v3/本机开房按钮）、联机 NORMAL AI 降速（2分钟发育+编组2×5）、测试经济就绪轮询。
- ⏳ 待办见 HANDOFF 文档（云服部署、Aggression 测试挂起排查、NetInfantry E2E、Push）。

## 关键坑（实测教训）
- Godot CLI 加 `--log-file 本地路径` 规避 AppData 沙箱拒绝；timeout 杀进程丢 stdout 缓冲，断言看 --log-file。
- GDScript `const X := preload(...)` 若推断为 String 会 parse error，Shader 资源要显式 `const X: Shader = preload(...)`；项目把 Variant 推断警告当错误（`var x := dict.get(...)` 不行，要显式类型）。
- FBX 节点局部 transform 相乘量 AABB 不可信（旋转/缩放中间节点），必须入场景树后用 global_transform 量；skinned mesh AABB 差百倍。
- 生产者节点部署时会被 Match 改名 Unit_N，测试按产品脚本过滤而非节点名。
- 权威经济账户（_economy_runtime）在 Match 就绪后异步配置，测试注入资源前必须轮询等待，否则偶发"resource account must be configured"。
- 客户端进程拿不到专用服的 _slots/_slot_kinds（不同步），大厅归属判定用 last_lobby_slots 广播快照。
- git 国内拉取已配 HTTP/1.1+500MB 缓冲；僵尸 Godot 进程会占 GPU 致新实例分配崩溃，先 tasklist 查。
