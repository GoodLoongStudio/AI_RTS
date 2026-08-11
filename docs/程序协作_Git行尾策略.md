# Git 行尾与 Godot 导入元数据策略

## 文档信息

- 事项 ID：DEV-20260811-007
- 状态：已实现，待 Pull Request 评审
- 日期：2026-08-11
- 适用范围：整个仓库

## 背景

Windows 环境中的 Git 默认启用了 `core.autocrlf=true`。仓库此前没有 `.gitattributes`，因此克隆时 Godot 文本文件可能以 CRLF 写入工作树。Godot 编辑器扫描资源后会把相邻的 `*.import` 元数据重新写为 LF，导致 Git 根据文件尺寸与时间戳把大量文件标记为修改。

诊断时共出现 386 个 `*.import` 修改状态。逐文件比较确认工作树 blob 与索引 blob 的哈希完全一致，`git diff` 也为空，因此这些状态不是资源导入参数的真实变化。

## 决策

- 仓库中的文本统一使用 LF，与开发者操作系统无关。
- 显式将 Godot 文本格式、`*.uid` 和 `*.import` 固定为 LF。
- 显式将常见图片、音频、模型和 Krita 文件标记为二进制，禁止行尾转换。
- 继续提交资源旁的 `*.import`，因为它们包含导入参数、UID 和目标缓存描述。
- 继续忽略 `.godot/` 和生成的 `*.translation`；这些内容由 Godot 在本地重建。

## 日常处理规则

1. 修改资源导入参数时，把源资源和对应 `*.import` 放在同一提交。
2. 升级 Godot 导致批量真实变化时，使用独立分支和独立提交，不与玩法代码混合。
3. 出现大批 `*.import` 状态时，先检查 `git diff`，不得直接批量提交或删除。
4. `git diff` 为空时，可在确认内容哈希一致后使用 `git add -u` 刷新索引状态；存在真实改动时禁止把该命令当作清理命令。
5. `.godot/imported/` 是本地转换缓存，不得加入版本控制。

## 验收标准

- `.gitattributes` 对 Godot 文本和 `*.import` 返回 `text: set`、`eol: lf`。
- 图片、音频、GLB 和 Krita 文件返回 `binary: set`。
- `git add --renormalize .` 不产生非预期内容差异。
- 新 worktree 的分支历史不包含尚未合并的 Godot MCP 提交。
