# 打包目录维护提示词

按 `agent/plans/2026-10-07-package-archive-plan.md` 执行，并先读 `skills/airts-workspace-boundaries/SKILL.md` 和 `agent/manifest.json`。

主工程及 build 运行依赖原位保留。只对已核验不参与当前开发的四个历史打包目录做同卷归档，保留所有原文件及绝对数据链接，不跟随 junction 搬动其目标。先统一主工程发布工具的默认路径，再移动，避免下次生成旧目录。

只读 dry-run 不能发送 HTTP、读取/打印 token、启动压缩或结束任何进程。完成后验证整棵归档树的文件身份/mtime/大小与链接，核验本轮新基线里的开发/启动文件，更新技能、入口与闭环报告。不得把已区分目录说成整个工作区已全面清理。
