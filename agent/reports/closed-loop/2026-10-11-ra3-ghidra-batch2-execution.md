# RA3 Ghidra 批次2 执行报告（工具返工 R3/R4/R5）

- 日期：2026-10-11（运行窗口 18:06:15 – 18:06:51，Asia/Shanghai）
- 角色分工：本会话只负责**工具运行与事实性产物交付**；研究、算法判断与 AIRTS 设计由研究会话负责（依据 `2026-10-11-ra3-research-independent-review.md`「用户澄清后的分工与执行验收」）
- 新批次（本轮产物，唯一写入目标）：`D:\RA3_RE_Research\ghidra_batches\2026-10-11_batch2\`
- 旧批次（**保留未动**）：`G:\AIRTS\AI_RTS\agent\runs\2026-10-11-ra3-research\ghidra\`（v1 JSON + 171 个 .c + 日志原样保留）
- 本轮未修改：RA3 安装、AIRTS 游戏源码；未重新导入/重新分析；未占用桌面输入（隐藏进程）

## 1. 返工内容（对应独立复核 R3 / R4 / R5）

| 项 | 修复结果 |
|---|---|
| **R3 调用边分类** | `callees_of` 重写为 `edges_of`，按"真实指令 + Ghidra 函数边界"分类：`direct_call`（CALL 有解析目标）/ `tail_call`（JMP 目标 = 另一函数的入口）/ `internal_jump`（JMP 目标在同一函数 body 内 = CFG 边）/ `indirect_unresolved`（无解析目标的 CALL/JMP）+ `jump_unresolved`、`jump_into_foreign_body` 兜底。**JMP 未被整体删除**；旧 `callees` 字段不再输出 |
| **R4 指令计数** | 块级：`insn_count`（实为地址数）拆分为 `address_count` + `instruction_count`（InstructionIterator 实数）；函数级：新增 `body_address_count` / `body_instruction_count`。旧 `size_bytes` 更名为 `body_address_count`。迁移关系写入 `schema.changes_vs_v1`（4 条）：**v1 `insn_count` == v2 `address_count`**，不得直接与 `instruction_count` 比较 |
| **R5 范围显式化** | 新增 `extraction_scope`：锚点清单（10 个显式 VA + 6 张 vftable + 5 个字符串词）、扩展深度 =1、cap=120、candidates=385 / used=120 / **truncated=true**、`deferred_callers`（265 条，含截断原因）、`unresolved_edges`（225 条全量列出）、`decompile_failures`（0）、来源计数、全局 `edge_stats` |

脚本：`D:\RA3_RE_Research\ghidra_scripts\DumpAiControlFlow.py` **v2.0.0**，SHA-256 `C95ACDF01AE737DEFE10A92A6DAEBE8856FF6EDE7318050DDC0B1BA09B3D4982`（27,308 B）。
v1 原脚本备份：`DumpAiControlFlow_v1_backup.py`，SHA-256 `278F9068797D490EA9246CDC72D6351558FC7EA56781E258DEDF74C86AD0E879`。

## 2. 运行记录

| 项 | 值 |
|---|---|
| 工具 | Ghidra 11.0.3 PUBLIC（安装 zip SHA-256 `2462a2d0…6761`，与官方 release notes 一致） |
| 项目 | `D:\RA3_RE_Research\ghidra_projects\RA3_RE`（复用既有已分析项目，`-noanalysis`） |
| 程序 | `ra3_1.12.game`（sha256 `EC230C6A…C165`，与旧批次一致） |
| 命令 | `analyzeHeadless <PROJ> RA3_RE -process ra3_1.12.game -noanalysis -scriptPath D:\RA3_RE_Research\ghidra_scripts -postScript DumpAiControlFlow.py -log <batch>\ghidra_dump.log -scriptlog <batch>\ghidra_script.log` |
| 启动方式 | `Start-Process cmd.exe /c run_inner.cmd -WindowStyle Hidden`（非交互、无桌面输入） |
| 起止 / 耗时 | 18:06:15 → 18:06:51（36 s，脚本自报 `run.elapsed_s`） |
| 退出码 | `analyzeHeadless rc=0`；**stderr 为空**（无 Traceback；已按环境坑清单检查） |
| 日志 | `stdout.log` / `stderr.log` / `ghidra_dump.log` / `ghidra_script.log` / `verify.log`（均在批次目录） |
| 末尾清单 | `batch_meta.json`（脚本 hash、命令、时间、rc、日志与产物路径） |

## 3. 校验结果（`verify_report.json`，**16/16 通过**）

| # | 检查 | 结果 |
|---|---|---|
| 1 | JSON 记录 ↔ decomp .c 一一对应 | functions=171 / recorded=171 / files=171 / **orphans=0 / missing=0** |
| 2 | **内部跳转例 `0x8BAB9B -> 0x8BABA0`** | 唯一命中在 `008bab40`，`kind=internal_jump`，**不是** direct_call/tail_call |
| 3 | **跨函数尾调用例 `0x8D3320 -> 0x8ACF00`** | 命中在 `008d3300`，`kind=tail_call`，未被误删 |
| 4 | **`FUN_008D3300` 计数** | `body_address_count=37` / `body_instruction_count=12`；**独立 Capstone 线性反汇编原始字节** `0x8D3300..0x8D3324` = **37 字节、12 条指令**，末条结束于 `0x8D3325` |
| 5 | 本体 SHA-256 | 新批次 JSON 记录值 == `EC230C6AE1EAEE30B0B4FA6BA29D417C974ECAE46D6715DFBE786A815935C165` |
| 6 | 边聚合一致性 | 逐函数求和 == `extraction_scope.edge_stats` |
| 7 | **v1→v2 对账** | v1「有 to 的 callee」**1285** == v2 `direct_call 1065 + tail_call 44 + internal_jump 176`；v1 自标 JMP **176** == v2 `internal_jump` **176** |
| 8 | 失败/未解析显式 | `decompile_failure_count=0`（列表字段存在）；`unresolved_edges=225`（与 `indirect_unresolved` 相等，全量列出） |
| 9 | 截断显式 | `truncated=true`、`deferred=265`、`candidates=385`、`used=120` |
| 10 | v1↔v2 函数集合一致 | 171 == 171，对称差 0 |
| 11 | 脚本 hash / schema 版本记录 | `script_sha256` 已写入 JSON；`schema.version=2.0.0`，迁移说明 4 条 |

## 4. 提取范围与数字（全部由新产物计算）

- 函数 **171**（来源：`caller_of=120`、`vftable_slot=28`、`string_xref=18`、`explicit_va=5`）
- 调用边总计 **1510**：`direct_call=1065`（其中 external 目标 44）、`tail_call=44`、`internal_jump=176`、`indirect_unresolved=225`、`jump_unresolved=0`、`jump_into_foreign_body=0`
- **截断说明**：调用者扩展第 1 层候选 385，受 cap=120 限制；`deferred_callers` 共 265 条（**前 3 条恰为首轮"孤儿文件"对应的 `00abdd80`/`00abdda0`/`00abf400`，截断原因显式记录**——该三函数是 v1 早期轮次进入、后被挤出名额的函数，v2 不再产生无主文件）
- 未解析间接调用 **225** 条（如 `CALL EAX`/`CALL EDX`，vtable/寄存器分发，静态不可解析；全量列在 `unresolved_edges`）
- 反编译失败 **0**

## 5. 未提取范围（明确，等待研究会话指定）

1. `deferred_callers` 265 个函数（清单已含 entry 与来源；未反编译）；
2. 225 条间接调用目标（需动态或 vtable 归属分析才能解析）；
3. 显式锚点/表/字符串词集合之外的程序区域（本轮**未**扩大为全程序分析）。

## 6. 产物索引（AIRTS 侧）

- 本报告 + `agent/runs/2026-10-11-ra3-research/ghidra-batch2-index.json`（仅索引与校验摘要，**不含反编译实现**）
- 反编译产物（JSON + 171 个 .c + 全部日志）位于 `D:\RA3_RE_Research\ghidra_batches\2026-10-11_batch2\`
