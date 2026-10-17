# 开发工程与打包目录整理：实际归档完成

日期：2026-10-07。状态：complete（开发/打包分区及已核验的历史打包材料归档）。

## 当前布局

```text
G:/AIRTS/
  AI_RTS/                         当前游戏源码 / Git 工程
    build/                        当前导出暂存、启动器、本地模型运行依赖
      adjutant_runtime/           正在使用的运行时，原位保留
  打包版/                         当前正式游戏 zip、完整模型分卷、发行说明
    历史归档/
      2026-09-初版/
        release_assets/           初版交付压缩包与发行说明
        release_build/            初版打包暂存与旧运行时
        demopkg/                  初版 exe
        demopkg2/                 初版 exe 与公共数据链接
```

四个历史目录已从 `G:/AIRTS/临时文件夹` **实际同卷移动**到上述归档路径；原四个目录已不存在。没有复制、删除、合并或重新压缩其文件，约 5.06 GiB 文件原样保留。主工程位置、正式交付文件及活动小模型保持原位。

独立地图工具、素材和旧源码备份依旧按各自用途保留，不属于当前开发工程；本任务没有做整个工作区的全面清理。

## 为后续 AI 修正的入口

- 完整规则：`skills/airts-workspace-boundaries/SKILL.md`。工作区 `AGENTS.md`、`skill.md`、成品与历史归档 `AGENTS.md` 已同步新位置。
- `agent/manifest.json` 增加 `historical_packaging_root`；开发根和当前成品根保持原口径。
- `tools/release/pack.ps1` 默认输出从 manifest 读取，替换失效的 `release_v4`；源仍是主工程 `build`。新增 `-DryRun`，去掉按进程名批量结束 7z 的行为。
- `tools/release/upload.py` 默认成品目录从 manifest 读取，替换已不存在的 `release_assets_gpu`，修正显式 token 被误当目录的解析；新增 `--dry-run`，排除 AGENTS 规则文件，历史归档子目录不会上传。
- `tools/release/update_body.py` 默认读取当前 `打包版/RELEASE_NOTES_v4.md`，替换被归档的临时路径；新增 `--dry-run`。远端发布行为、tag 等未在本任务中验证，未执行上传。

三个 dry-run 都在压缩、网络访问或 token 读取之前返回。没有运行实际打包、发布、Godot 导入或构建，没有停止用户实例，没有 git reset/clean/add/commit。

## 核验

证据目录：`G:/AIRTS/AI_RTS/agent/runs/2026-10-07-package-archive/`。

| 项目 | 实测结果 |
|---|---|
| 四目录的搬迁边界 | 使用 PowerShell 原生 `Move-Item -LiteralPath`，移动前校验源在指定临时目录、目标在指定打包目录、无根 junction、目标不存在、无引用候选目录的活动进程；rc=0 |
| 移动前后整棵目录树 | **23465 个条目**逐项对比 NTFS 文件身份、类型、大小、mtime、链接目标；全部一致，原位置不存在 |
| 旧导出数据 junction | 6 个链接仍有效，目标 `G:/AIRTS/临时文件夹/pub_sc` 原位保留；未跟随链接搬动公共数据 |
| 当前开发/启动链路 | 新基线的 9 个文件 SHA-256/mtime 一致：project、导出预设、Windows 构建脚本、两个副官服务脚本、MatchSetupPage 脚本/场景、两个 build 启动/诊断 bat |
| 当前正式交付文件 | 7 个原有文件的文件身份、大小、mtime 一致；成品区 AGENTS.md 是计划内入口修改，单独记录 |
| 活动模型运行时根 | 位置、文件身份、mtime 保持不变 |
| 发布工具 dry-run | 默认 pack/upload/notes 和显式归档 upload/notes，5/5；每条 rc=0，输出目标符合预期 |
| 上传 dry-run 兼容旧 CLI | 两个带假 token 占位参数的 dry-run 正确解析目录、不会把 token 当路径或打印；2/2，rc=0 |
| 开发目标检查 | 当前源码放行 rc=0；正式成品、历史交付、旧 exe 目录、小模型运行时均拒绝 rc=2；5/5 符合预期 |
| 格式校验 | 两个修改的 Python 脚本 AST 通过；manifest JSON 通过；skill-creator quick_validate 对更新的完整技能 rc=0 |

共 12 个路径/dry-run 案例通过。`baseline.json` 保存本轮新基线与全部移动条目，`verification.json` 保存移动核验与每个 CLI 命令/结果，三个发布工具的修改前副本仅保存在本任务证据目录。

第一次聚合检查 rc=1：它把计划内修改的成品 AGENTS.md 也列为“交付产物必须原样”，导致规则文件一项失败，四个移动目录、9 个工程文件和7个实际交付产物当时均通过。保留 `verification-initial.json`；按实际任务范围单列该入口修改后，最终聚合检查 rc=0。没有修改或放宽任何交付文件、目录或链接的保全判据。

本任务不涉及游戏行为/画面变化，未运行 Match 或游戏回归，不用目录检查代替玩法验收。共享工作区有并行开发改动，采用本轮新基线，未回滚上一轮之后的开发。

本轮候选通过归档、路径和保全门禁，接受为本任务 champion；连续未提升轮数 0。
