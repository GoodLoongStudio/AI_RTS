# AIRTS 工程定位与目录维护提示词

先读 `G:/AIRTS/AGENTS.md`、`G:/AIRTS/AI_RTS/AGENTS.md`、`G:/AIRTS/AI_RTS/skills/airts-workspace-boundaries/SKILL.md` 和 `G:/AIRTS/AI_RTS/agent/manifest.json`。计划见 `agent/plans/2026-10-07-workspace-boundaries-plan.md`。

默认游戏开发只在 `G:/AIRTS/AI_RTS`。`G:/AIRTS/打包版` 是已打包交付物；`临时文件夹`、`AIRTS_restore_backup` 和 `tmp_logs` 是素材/历史/测试参考；`RTS_Map_Tool` 是独立工具工程。不得靠扫描到的第一个 `project.godot`、最近修改时间或同名 exe 选择开发工程。

代码编辑前运行主工程的 `tools/check_workspace_target.py --mode develop --target <实际编辑目标>`，核对项目根与 Git 根。测试源码时明确使用主工程绝对 `--path`，不要用旧打包 exe 验收新代码。普通开发不覆盖成品；明确要求打包时，才走现有导出流程。

维护入口规则时只改必要文档与工具。不得移动/改名工程、修改导出路径、清空 `build`、移动 `build/adjutant_runtime`、杀死已有实例或回滚其他人的改动。技能和清单保持同一口径；检查工具只读、不接入游戏启动链路。

交付前实际验证正确/错误目录、技能格式和 JSON，复核受保护文件与成品保持原状，把命令、rc 和适用范围写入闭环报告。本任务不要求游戏画面验收，不得把目录检查通过写成玩法验收通过。
