# AIRTS 开发工程与交付成品分区验收

日期：2026-10-07。状态：complete（工程定位与目录维护范围）。

## 结果

本机默认游戏开发根固定为 **`G:/AIRTS/AI_RTS`**；交付成品区为 **`G:/AIRTS/打包版`**。原本两者已物理分开，问题是工作区内还有独立地图工具、多个旧 Godot 工程及备份，而且旧 Cursor 规则指向不存在的 `godot-open-rts` 并写着 4.3。现已补齐目录身份、技能入口和只读路径检查，原位保留现有开发与打包布局。

`build` 从清单的纯临时目录分类移入混合用途分类；`build/adjutant_runtime` 单独列为受保护本地依赖。现有导出位置、游戏代码、启动器和模型路径不变。

## 改动位置

| 文件 | 作用 |
|---|---|
| `G:/AIRTS/AGENTS.md` | 工作区入口与开发/成品/独立工具/历史参考分区表 |
| `G:/AIRTS/AI_RTS/AGENTS.md`、`agent/README.md`、`skills/目录.md` | 将工程定位技能接入仓库必读入口 |
| `G:/AIRTS/AI_RTS/skills/airts-workspace-boundaries/SKILL.md` | 完整定位流程、源码验收、打包与模型保护规则 |
| `G:/AIRTS/AI_RTS/agent/manifest.json` | 权威目录声明、主工程绝对路径与检查命令 |
| `G:/AIRTS/AI_RTS/tools/check_workspace_target.py` | 只读分类和开发目标检查，校验自身工程与 Git 根 |
| `G:/AIRTS/.codebuddy/skills/airts-workspace-boundaries/SKILL.md` | CodeBuddy 技能入口，转到完整权威技能 |
| 工作区与主工程的 `.cursor/rules/airts-workspace-boundaries.mdc` | 两种打开方式均应用工程定位规则 |
| `G:/AIRTS/skill.md` | 历史上下文顶部增加当前工程定位与优先关系 |
| `G:/AIRTS/.cursor/rules/godot-dotnet.mdc`、`tier2-modular-terrain.mdc` | 纠正旧主工程路径；引擎示例与现有 4.7 / 4.7.1 Mono 口径一致 |
| `G:/AIRTS/打包版/AGENTS.md` | 明确成品区默认只读，修游戏进入主工程 |
| `agent/plans/2026-10-07-workspace-boundaries-plan.md`、`agent/prompts/2026-10-07-workspace-boundaries-prompt.md` | 本任务计划与可复用执行提示词 |

## 实测与返回码

原始证据：`G:/AIRTS/AI_RTS/agent/runs/2026-10-07-workspace-boundaries/baseline.json`、`verification.json`；前者包含 SHA-256/mtime 基线，后者记录每个 CLI 命令、工作目录、期望与实际返回码。

| 验收项 | 结果 |
|---|---|
| 主工程根、源码目录/文件、将创建的文件、含空格路径、大小写与正确相对路径 | 8/8 放行，rc=0 |
| 工作区错误 cwd、成品/归档/成品 cwd、build、模型目录、Godot 缓存、Git 元数据、证据目录、备份、临时/日志旧工程、地图工具、引擎目录、相似前缀、`..` 越界、外部目录 | 17/17 拒绝，预期 rc=2 |
| inspect 成品和模型目录 | 2/2，rc=0，明确返回 inspect-only 且不授予开发写权限 |
| 从副本启动复制的检查器 | 1/1 拒绝，预期 rc=1，不把所在副本自动认作主工程 |
| 源码范围链接到备份、产物范围链接回源码 | 2/2 拒绝，rc=2；同时核验原始与解析路径 |
| 全部 CLI 案例 | **30/30**；矩阵验收进程 rc=0 |
| Python `ast.parse` 与 manifest JSON 解析 | 通过，校验进程 rc=0 |
| 主工程与 CodeBuddy 的技能格式 | `python -X utf8 C:/Users/Administrator/.codex/skills/.system/skill-creator/scripts/quick_validate.py <skill目录>`，两次均 rc=0 / Skill is valid |

日常入口示例：

```powershell
python G:/AIRTS/AI_RTS/tools/check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS/source
```

临时目录链接和复制检查器夹具已移除，保留 JSON 证据。检查器没有接入游戏、构建或启动链路，不增加游戏运行开销。

## 保全核验

下列 **9 个文件的 SHA-256、大小与 mtime** 与修改前完全一致：`project.godot`、`export_presets.cfg`、`tools/build_windows.ps1`、`source/ui/AdjutantModelService.gd`、`source/main-menu/MatchSetupPage.gd`、`source/main-menu/MatchSetupPage.tscn`、`build/启动AI_RTS.bat`、`build/诊断.bat`、`build/.gdignore`。

成品区原有 **7 个文件的大小与 mtime** 完全一致：已有说明文件、发行说明、游戏 zip、4 个模型分卷。没有解包或重新导出成品，只新增该目录的 AGENTS 说明。模型运行时根目录保持原位、mtime 未变；未逐个散列大型模型文件。

没有移动/改名任何既有目录，没有启动 Godot、导入、构建、打包、结束已有实例，也没有 git reset/clean/add/commit。共享工作区本来存在大量未提交工作，采用精确补丁保留原状。

## 验收范围与限制

- 本任务验证目录路由、技能格式和离线工具，不改变游戏行为；真实 Match、画面截图与游戏全量回归不适用于此次目录维护，未执行。此结论不代表游戏玩法或战略副官功能已验收。
- 已验证文件入口可读、技能格式有效；没有在其他 AI 客户端中实际触发一次完整自动选技能。规则需由执行 AI 读取，检查器并非系统权限隔离，不能保证忽略规则的 AI 无法误写。
- 本机路径清单有意固定当前开发根。用户明确指定其他工程/worktree 时按已授权范围核验；未来真正迁移工程时应同步更新清单与入口。
- 本轮候选通过目录门禁，接受为本任务 champion；连续未提升轮数 0。

## 用户追问：实际位置是否已经移动好

再次逐项检查实目录、Git 根、压缩包内部文件列表、启动/导出路径和运行进程。结论是**主工程与正式交付包已经分目录，但本任务没有执行目录搬迁，也没有完成所有历史产物的统一归档**。

| 内容 | 当前实际位置 | 搬迁状态 |
|---|---|---|
| 开发工程 | `G:/AIRTS/AI_RTS` | 原位保留；Git 根一致 |
| 正式游戏包、4 个模型分卷及发行说明 | `G:/AIRTS/打包版` | 已位于成品区，均为本任务之前就存在的文件 |
| 本机导出 exe 与配套数据 | `G:/AIRTS/AI_RTS/build` | 未移动；现有导出配置输出至这里 |
| 开发用小模型运行时 | `G:/AIRTS/AI_RTS/build/adjutant_runtime` | 未移动；源码和 build 启动脚本直接引用此布局 |
| 历史打包材料 | `G:/AIRTS/临时文件夹/release_assets`、`release_build`、`demopkg`、`demopkg2` | 未统一迁入成品区 |
| 旧工程、备份和素材 | 原临时/备份目录 | 未移动，规则已标明不是当前默认工程 |

只读检查游戏 zip 的目录表，确认它含已导出的游戏程序与启动脚本，而不是另一个 `project.godot` 源码工程。当前有使用 `--path G:/AIRTS/AI_RTS` 的 Godot 实例；另有使用相对 `--path .` 的实例，仅凭命令行不能确认其工作目录，未将这些实例纳入主工程身份结论，也没有停止任何实例。

本次复查的 5 个目标路径判断符合预期；8 个受保护文件仍保持原哈希/mtime，7 个原有交付文件大小/mtime 仍保持原状。聚合保全检查 rc=1：`source/main-menu/MatchSetupPage.gd` 在前次基线后发生修改（26089 → 26112 字节），本轮没有编辑此文件，保留当前开发改动，未回滚。路径位置检查本身通过，不能将聚合保全检查写成 rc=0。证据：`G:/AIRTS/AI_RTS/agent/runs/2026-10-07-workspace-boundaries/location-recheck.json`。

“目录分区与防误改规则完成”不能写成“全部位置都搬迁完成”。若继续做实体归档，需要先分别核验历史产物的引用和使用状态；本次核查保持现有开发、模型与启动布局。

后续进展：四套历史打包目录现已实际归入 `G:/AIRTS/打包版/历史归档/2026-09-初版`，并修正当前发布工具的默认路径。新的归档结果与完整保全核验见 `agent/reports/closed-loop/2026-10-07-package-archive.md`；本节“未归档”描述仅对应之前的只读复查时点。
