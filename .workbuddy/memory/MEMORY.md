# AI_RTS 项目笔记（长期）

## 项目概况
- Godot 4.7.1 Mono + .NET 8 的 RTS 游戏（基于开源 OpenRTS 改造），目标做"AI 副官/LLM 军官"即时战略。
- 架构：双轨 —— Legacy GDScript（source/，match/net/campaign 等）+ 新 C# 分层（source/csharp/Domain|Application|GodotAdapter，AI_RTS.Core.csproj 独立 Core 程序集，101 纯 C# 测试 + 31 Godot 自动场景）。
- 当前分支 yyp_test（有远端 origin/yyp_test），main 是唯一正式交付基线。规范文件：docs/项目统一规范.md（Canonical，最高优先级）。
- 两条主线：① 2–4 人联机 Demo（服务器权威 ENet，腾讯云 headless Godot 专用服，包1–3 已完成，专用服已上云，剩防火墙 UDP 24567 放行+大厅填AI开关）；② 规则 AI 智能化改造（独立立项）。美术侧在做科幻载具换模（POLYGON Sci-Fi Worlds 替换 Kenney 外观，未开始拷贝）。
- docs/plan/ 下 30+ 个单功能 plan 文档，格式固定：Overview / Current State / Strategy / Steps / Timeline / Risk / Success Criteria，用 ✅/⏳ 标进度。
- Git 提交信息用中文，格式如"功能: xxx""修复: xxx"。
- 工作区根目录有"服务器信息.md"放云服务器凭据（不进仓库）。
- 近期提交：素材包上传、RA3 风格对局 UI 侧栏、联机大厅超时修复、AI QueueFull 退避等。
