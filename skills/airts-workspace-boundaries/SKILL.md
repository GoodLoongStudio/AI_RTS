---
name: airts-workspace-boundaries
description: AIRTS 工程定位与开发/打包边界。进入 AIRTS 工作区、编辑游戏、选择 Godot 测试实例、处理导出成品或整理目录时使用，防止把打包版、备份、临时副本或独立地图工具当作当前主工程，并保护 build 内的本地模型运行时。
---

# 先确定正在修改和验收哪一个工程

本机默认开发根是 `G:/AIRTS/AI_RTS`。权威目录声明在该工程的 `agent/manifest.json` → `workspace_layout`；只读检查工具是 `tools/check_workspace_target.py`。进入本任务后先读工作区/仓库 `AGENTS.md`，再读相关开发技能。

## 目录身份

| 目录 | 用途与边界 |
|---|---|
| `G:/AIRTS/AI_RTS` | 当前游戏 Git 仓库，包含 `project.godot`、`OpenRTS.sln`、`source`、`assets`、`config`、`tests`；默认游戏修改目标 |
| `G:/AIRTS/打包版` | 已交付游戏 zip、模型运行时分卷、发行说明；默认只读，不在这里解包后继续开发 |
| `G:/AIRTS/打包版/历史归档/2026-09-初版` | 初版成品、打包暂存与旧导出工程；由原临时目录中的 `release_assets`、`release_build`、`demopkg`、`demopkg2` 原样归档，不能当成当前游戏工程 |
| `AI_RTS/build` | 现有导出暂存和本机运行依赖；`build/adjutant_runtime` 含小模型服务/模型文件，不能清空、迁出或当作可再生缓存 |
| `G:/AIRTS/RTS_Map_Tool` | 独立地图工具，不是游戏主工程；明确涉及它时读取其自身规则 |
| `G:/AIRTS/工作区归档` | 原恢复备份、历史文档、设计输入、旧测试记录与完整旧规则；具体旧/新路径见该目录 `整理说明.md`。默认只读参考，不作为游戏工程 |
| `临时文件夹`、工作区/工程的 `tmp_logs` | 混合素材、虚拟环境、模型/训练数据、控制脚本和参考工程；其中即使有 `project.godot` 也不能作为默认编辑工程，也不能整目录当垃圾清空 |
| `.godot`、`.git`、`.test-results`、`agent/runs` | 导入缓存、Git 元数据和运行证据，不能作为游戏源码修改位置；证据按既有流程正常写入 `agent/runs` |
| `Godot`、`godot_mono_471` | 引擎安装；保留现有路径和版本，不因工程定位问题升级/降级 |

## 编辑前的定位流程

1. 输出本次的开发根、实际编辑目标和验证入口。默认限定搜索在主工程；其他目录按需要读取参考，不做全盘批量替换。
2. 执行：

   ```powershell
   git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel
   git -C G:/AIRTS/AI_RTS status --short
   python G:/AIRTS/AI_RTS/tools/check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS/source
   ```

   将 `--target` 换成实际文件/目录。不存在但将要创建的源码路径也可以检查。检查 rc=0 才符合本机默认开发边界；rc=2 表示目标不属于源码范围，rc=1 表示检查器/清单/Git 身份有误。
3. 核验目标文件 mtime 和已有改动。保留其他 Agent 工作，不执行 reset/clean、不覆盖暂存区，不为得到“干净工程”改去备份目录。
4. 只读盘点成品、运行时或参考目录时用 `--mode inspect`；此模式不授予写权限。明确授权的打包、启动器维护、证据写入按实际任务执行，不必把它们伪装成源码修改。

检查器同时检查原始路径和解析后的真实路径，防止 `..`、相似目录前缀及指向其他目录的链接误导。必须调用主工程里的检查器；从备份复制来的检查器不能把其所在副本自行认定为主工程。检查器不是系统权限隔离，Agent 仍需执行本技能规则。

用户明确指定另一个工程或已登记 worktree 时，核验该工程的 Git 根、来源、自己的规则和任务范围，记录此次例外；不要修改本机默认定位来绕过检查。迁移主工程只在用户确实要求迁移时处理，并同步更新清单和入口。

## 运行与打包

- 清理先查引用、活动进程、Git worktree 和文件身份，不以目录名或修改时间判定无用。`临时文件夹/airts_agent_venv`、`tmp_logs/langgraph_recon/runner_ctl.py` 正在用于副官任务，保持路径；`.venv_rts`、引擎用户数据和编辑器/AI 隐藏配置同样保留。
- `临时文件夹/airts_ab_pre` 是登记中的 worktree，不能手动剪切或当重复源码删除；其他 worktree 先以实际 `git worktree list` 为准。
- 根旧 `skill.md` 完整保存在 `工作区归档/规则历史`，当前根入口只做导航；历史冻结/分支/任务焦点不覆盖当前用户目标。根原 docs、恢复备份、UI 资料、辅助工具、旧测试记录/缓存已集中归档。
- 保留设计可作为当前任务输入：主工程 `tools/gen_growth_icons.py --dry-run` 只检查；实际生成时先用 `--output <证据目录>` 验证。归档里的旧绝对路径脚本仅供历史参考，不能自动执行。

- 验收源码用 Godot .NET，明确 `--path G:/AIRTS/AI_RTS`；场景路径属于这个工程。运行前核对进程命令行、实例/日志身份和证据时间，不能仅凭窗口标题“Open RTS”判断版本。
- 改源码后只启动旧 zip 里的 exe，不能证明新代码生效；测试成品则记录成品绝对路径、版本、mtime 和构建来源。
- `tools/build_windows.ps1` 与 `export_presets.cfg` 的现有 `build` 输出路径保持原样。明确要求打包时才执行导出/交付流程，记录来源；普通修复不自动覆盖 `打包版` 中的已交付归档。
- `tools/release/pack.ps1`、`upload.py`、`update_body.py` 的默认成品目录从 manifest 读取；不再默认写入 `release_v4`、`release_assets_gpu` 或读取临时目录的旧发行说明。检查配置分别使用 `-DryRun`、`--dry-run`，这些模式不压缩、不上传、不读取 token；历史脚本仅作参考，不作为当前发布入口。
- 历史 `demopkg2` 的数据链接依赖 `G:/AIRTS/临时文件夹/pub_sc`，该公共数据原位保留，不跟随 junction 清理或移动。
- 不移动/改名 `AI_RTS`、`打包版`、`build/adjutant_runtime`；不改启动器路径，不清理不明目录，不按 Godot/ollama 映像名批量结束进程。定位错误先纠正目标。
- 历史 `godot-open-rts`、`release_v4`、临时测试工程和旧引擎路径仅作历史参考；引擎口径核对当前 `project.godot`、仓库清单和实际已有安装。

## 交付证据

报告写明开发根、实际改动目标、验证入口、路径检查 rc 和未验证项。目录维护应核验受保护配置/启动文件和成品保持原状；玩法任务继续执行仓库闭环规则，不能用路径检查代替游戏验证。
