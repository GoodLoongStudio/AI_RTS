# 评委体验版 test_demo 的版本与覆盖核验

核验日期：2026-10-08，北京时间。状态：只读来源核验完成；运行稳定性 needs-review。

## 结论

**更正：第一次统一尺寸发生在2026-09-27；当前GitHub游戏ZIP已经包含那次改动后的尺寸配置，不能当作“统一尺寸前的稳定版”。** 原核验只证明它不是10月修复中的开发版，未证明它早于9月27日的初始改动；将“9月旧包”理解成“尺寸修改前的包”是不成立的。本次通过原始对话、Git提交差异和成品内嵌配表补齐了时间线。

**仍然成立的结论：没有发现10月开发版本覆盖当前附件的证据。** 本地ZIP与此前读取的GitHub附件digest相同。但“未被近期覆盖”和“最初上传的内容就是尺寸修改前版本”是两件事。

**旧包身份不等于稳定性认证。** 本地有朋友针对同名v0.4的启动崩溃报告，需在干净目录和评审目标机器上单独验证。朋友报告没有提供可比对的EXE哈希，本轮不将其原因猜测当成已确证，也没有运行重现。

## 0. 补查：首次尺寸修改的准确日期

以下时间统一为北京时间（UTC+08:00），不使用文件mtime倒推用户发指令时间。

| 时间 | 证据与意义 |
|---|---|
| 2026-09-27 晚上 | 用户在9月29日晚的原始对话中说“我前天晚上让ai统一改了尺寸，这个你知道吗”，明确对应9月27日。首次发起指令的具体分钟尚未找到，不能把提交时间冒充指令时间。 |
| 2026-09-27 18:39:08 | 提交8956c1d372cbf0ba9b4a716a33802354dacbaeec，消息“小更新”；实际差异为Tank根scale新增2、CommandCenter根scale新增3、建筑footprint普遍放大、地图100扩大为208。尺寸改动至迟此时已经提交。 |
| 2026-09-27 20:45:54 | 当前游戏ZIP内EXE时间；晚于上述提交约2小时7分钟。这个时间单独不能证明源码内容，故另查内嵌配表。 |
| 2026-09-28 00:28:54 | 当前GitHub游戏附件上传完成时间；不是尺寸修改前的时间。 |
| 2026-09-29 22:38:45.996 | 原始对话记录的北京时间，原记录UTC为2026-09-29T14:38:45.996Z。 |

原始对话只读来源：[本任务9月29日会话记录](C:/Users/Administrator/.codex/sessions/2026/09/29/rollout-2026-09-29T22-37-55-01a0ed99-cdcc-7a52-859c-2f24f976cccb.jsonl)。独立历史报告也记载“昨天让AI改了一下单位尺寸”，见[9月28日排查报告](G:/AIRTS/AI_RTS/docs/程序文档/可玩性中断排查_地图地面偏移与放置门槛_2026-09-28.md:3)，并在第90行定位同一提交。

本次重新只读解析已与ZIP内EXE做过SHA-256比对的build EXE，读取其内嵌JSON。与提交前后逐项对照：

| 建筑 | 8956c1d之前footprint半径m | 8956c1d之后m | 评委EXE内实际值m |
|---|---|---|---|
| command_center | 2 | 7 | 7 |
| ore_refinery | 2 | 6 | 6 |
| vehicle_factory | 1.5 | 6.65 | 6.65 |
| aircraft_factory | 1.5 | 8 | 8 |
| anti_ground_turret | 0.6 | 2.2 | 2.2 |
| anti_air_turret | 0.6 | 2 | 2 |
| barracks | 1.5 | 6.25 | 6.25 |
| machine_gun_turret | 0.6 | 2 | 2 |

8项全部对应改动后数值。这是包内内容证据，不是凭tag、mtime或当前工作树猜测。包内JSON的SHA-256为6664aefde06f96491c263f8d8bc88c310db45589de50d0e355c415da84db1c02；内嵌路径config/balance/demo.balance.v1.json，18572字节，PCK条目未加密。

因此，不能继续把此包交接为“尺寸改动前的稳定包”。需要寻找真正修改前的归档成品，或从修改前源码隔离验证；8956c1d的直接父提交360799b2a362d71bcc0a161f0221e40548b68545（2026-09-26 20:48:08）只是一个源码候选，不代表已经验证稳定，也不代表能直接替换发布附件。本次未重建或更换任何成品。

## 1. GitHub Release 事实

来源：[评委体验版 Release](https://github.com/GoodLoongStudio/AI_RTS/releases/tag/test_demo)，以及只读命令：

```powershell
gh api repos/GoodLoongStudio/AI_RTS/releases/tags/test_demo
gh api repos/GoodLoongStudio/AI_RTS/git/ref/tags/test_demo
```

两次独立读取Release元数据，游戏asset id/digest/更新时间一致。

| 项 | 核验值 |
|---|---|
| Release ID | 394346680 |
| tag | test_demo |
| tag当前提交 | 19dc54caad1370d83e6afcfb40090ee0af157404 |
| 提交时间 | 2026-09-26 16:37:43 +08:00 |
| 游戏附件 | AI_RTS_Game_v0.4.zip |
| 游戏asset ID | 593298867 |
| 大小 | 700230204字节，约667.8MiB |
| 游戏开始上传 | 2026-09-28 00:26:08 +08:00 |
| 游戏附件updated_at | 2026-09-28 00:28:54 +08:00 |
| Release updated_at | 同上 |
| immutable | false |
| draft / prerelease | false / false |

注意：页面原始发布日期早于附件最后更新时间，不能只看页面“9月23日发布”。附件在9月28日零点有过更新；本轮确认的是当前附件，不声称自最初发布以来从未替换。

tag指向9月26日提交，而附件EXE在9月27日导出，ZIP内副官文件有9月28日零点的时间。缺少签名构建清单，不能将tag提交当成整个ZIP的确切源码版本，也不能拿Source code.zip代替评委游戏附件。

## 2. 字节级身份验证

游戏ZIP的GitHub digest与本地 `G:/AIRTS/打包版/AI_RTS_Game_v0.4.zip` 实测SHA-256完全相同：

```text
5d5a0aab0c5a4c87d7dafcc1472834bea9a6a21d2e6352c11b68f8a51d222d40
```

本地ZIP外部mtime是10月7日，但该时间不能证明重新打包。字节哈希显示它仍等同于9月28日上传的附件。本轮未下载或上传700MB远端文件，使用GitHub公布digest与本地全文件哈希对比。

只读打开ZIP，360个条目，其中：

| 文件 | ZIP内时间（+08:00） | 字节数 |
|---|---|---|
| AI_RTS_Demo.exe | 2026-09-27 20:45:54 | 851886008 |
| data_OpenRTS_windows_x86_64/OpenRTS.dll | 2026-09-27 20:45:56 | 293376 |
| adjutant_runtime/.env.local | 2026-09-28 00:14:30 | 4522 |

没有读取或输出.env内容。

ZIP中EXE流的SHA-256与 `G:/AIRTS/AI_RTS/build/AI_RTS_Demo.exe` 全文件SHA-256一致：

```text
61a1a391da85728fd856938b369aacd0ac70a71472430c1afff46ebfb7916f23
```

因此可以只读检查该build EXE的内嵌资源，而不是用当前source代替成品。未执行该EXE，未解压到成品目录。

说明文本 `00-READ-ME-FIRST.txt` 的本地哈希也与远端相同。4个模型分卷的远端时间仍在9月27日，本轮没有逐个读取6GB以上的本地分卷校验，不能声称分卷本地字节一致或模型已经运行通过。

## 3. 包内配表不是当前尺寸修复版

本节“不是当前修复版”仅指不含后续开发修改，不能据此认定早于9月27日初始统一尺寸；初始改动已包含在成品中的证据见第0节。

按[Godot官方PCK读取实现](https://raw.githubusercontent.com/godotengine/godot/a13da4feb/core/io/file_access_pack.cpp)只读解析内嵌目录：PCK version=4，engine=4.7.1，flags=2，11501文件，起点109357568。

实际读取包内 `config/balance/demo.balance.v1.json`，例如：

| 单位 | 包内速度m/s | 包内视野m |
|---|---|---|
| tank | 2.75 | 8 |
| heavy_tank | 2.2 | 10 |

当前开发Tank场景速度为5.5，已移除root scale并迁移Geometry缩放。`git diff`显示Tank和CommandCenter的根缩放/碰撞/逻辑口径改动仍与9月底Git基线不同。这些晚期开发改动没有替换远端已校验的ZIP。

包内Tank和CommandCenter场景被导出为二进制.scn，通过.tscn.remap对应；本轮读取了映射，没有声称解码并测量了每一个包内模型的世界尺寸。结论是成品身份/时间/旧配表一致，不是逐单位玩法验收。

## 4. 独立风险：旧包也有启动崩溃反馈

参考：[朋友的v0.4崩溃排查报告](G:/AIRTS/打包版/朋友的测试/AI_RTS_崩溃排查报告1006.md)。报告声称有0xC0000005启动退出；本轮未独立重现，原始运行日志/进程转储/朋友EXE哈希不在此核验中。

本轮从真实ZIP/内嵌资源确认的打包问题：

- ZIP本身包含31个 `*~RF*.TMP` 条目，不只是朋友解压后产生的文件。因此“重解压就让这些文件消失”的建议不成立；干净重解压仍会复制ZIP中已有条目。
- 包含OpenRTS.pdb和AI_RTS.Core.pdb。符号本身不证明崩溃原因。
- 内嵌资源目录包含264个 `addons/godot_ai/` 和70个 `addons/godot_mcp/` 文件。只证明资源存在，不证明全都启动或造成原生崩溃；与朋友报告所写的276/80计数不同。

不能因为用户担心尺寸更新，就把启动故障归给尺寸；也不能因为旧包没有被覆盖，就保证评审机器可以运行。

评审前最有价值的下一步是：在独立干净目录用这一哈希锁定的旧包做启动、开局、建造、产兵、移动、交火、采矿、副官和退局重开的可见烟测，并在评审硬件核对。若修旧版打包，必须从旧版来源隔离处理，不能顺手把当前未修好的工作树导出覆盖test_demo。

## 5. 未来覆盖风险真实存在，但本轮没有发生

远端 `immutable=false`，当前Release未启用不可变保护。本地 [upload.py:153](G:/AIRTS/AI_RTS/tools/release/upload.py:153) 默认目标仍是test_demo：同名文件大小相同会跳过，大小不同会删除旧asset后重传。只比大小也不是内容身份验证。

[pack.ps1](G:/AIRTS/AI_RTS/tools/release/pack.ps1) 默认会写成品目录、替换同名游戏ZIP。因此后续AI若实际执行默认打包+上传，有覆盖评委附件的可能；本次API/哈希证明截至核验时尚未被10月版覆盖。

现有本地3个工作流主要是构建/审计与手动LFS迁移，未见Release上传步骤；GitHub默认分支也列出同名3个workflow文件。本轮未审计所有远端脚本或外部自动化，也不能通过没有CI发布工作流排除本地Agent持令牌手动上传。

建议评审前冻结test_demo和对应成品哈希；后续测试新版本用新的tag和输出目录。启用远端不可变/改发布脚本/文件只读权限需要实际实施，本轮未更改这些状态，不能声称已被技术保护。

## 6. 当前附件指纹表

| 名称 | asset ID | 字节数 | SHA-256 |
|---|---|---|---|
| 00-READ-ME-FIRST.txt | 592715900 | 2158 | 773755e25be55bdb318b13c805092e7a5f400a23a20119f90a07220a4dfa5a51 |
| AI_RTS_Game_v0.4.zip | 593298867 | 700230204 | 5d5a0aab0c5a4c87d7dafcc1472834bea9a6a21d2e6352c11b68f8a51d222d40 |
| AI_RTS_Adjutant_Runtime.7z.001 | 592570808 | 1992294400 | 25290bb8af0793d221bb0b1cb4548a4bf3f369c59c79af7abf42b26da7facadf |
| AI_RTS_Adjutant_Runtime.7z.002 | 592581276 | 1992294400 | 4a04ad55f505b11da0fd2aff9f1a41acd584ff69cf39fb493a06f599b641c611 |
| AI_RTS_Adjutant_Runtime.7z.003 | 592591608 | 1992294400 | 00cb42954c2620e0adeef98bcb9f256d6b9ca8e35d1b784d51a64a6115aa8d04 |
| AI_RTS_Adjutant_Runtime.7z.004 | 592601016 | 562054958 | a64a838ebb0d46978cefc9800c199c8885bee4c4d78b9e932224672d89a724f1 |

上表分卷为GitHub API公布digest；只有游戏ZIP、说明文本和ZIP内对应EXE做了本地实算。API当前实际附件为6项；页面Assets8包含两个自动源码归档，不等于8个手传文件。

## 7. 验证与边界

只新增本报告、[计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-08-judge-release-provenance-audit.md) 和 [保全交接提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-08-judge-release-preservation.md)。

- Git根与成品inspect检查rc=0，报告develop目标检查rc=0。
- GitHub Release/tag读取、ZIP哈希、EXE双哈希与只读PCK解析rc=0。
- 一次辅助rg使用Windows不支持的路径通配符返回rc=1，随后改用目录+glob检索；不用于版本结论。
- 新文档静态检查rc=0。
- 补查原始用户消息、Git首次尺寸提交/父提交和包内8项footprint对照，均rc=0；报告、计划、提示词实际目标的develop检查均rc=0。
- 没有截图、新游戏性能数值、编译/回归或稳定性通过记录。
- 没有运行pack/upload/clear_assets，没有修改GitHub Release、tag、成品、启动器、游戏源码或权限，没有结束任何实例。

共享源码有大量在途改动；本次结论以成品哈希而非工作树状态为依据。没有建立产品candidate/champion；本任务完成的是身份审计，不是评审稳定性修复。
