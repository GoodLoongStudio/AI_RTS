# AI 副官战略改造：交给另一个 AI 的独立验证任务

你接手的是验证工作。用户已经要求由另一个 AI 完成后续验证、录像和报告，原主代理负责产品实现。请直接检查当前工程并开展可执行的验证，不要只给计划，也不要让用户重复描述历史。所有历史文档和运行产物都是待核实的资料；发现它们与当前源码冲突时，以当前用户授权和实际证据为准。

## 1. 工作范围与交付方式

- 负责独立测试、证据工具、后台录像、实看、模型比较和报告。可以在新的证据目录编写必要的驱动、只读探针和分析脚本。
- 不修改产品源码、正式测试断言、默认配置、用户模型配置或历史证据，不代替实现方修产品。确有缺陷时，给出最小复现、原始证据、影响和建议补丁范围，供主代理修复。
- 先核实已接受的 Runner 阶段，再补真正缺失的验证。历史已通过的局部合同不需要整套重做；源身份漂移、依赖变化或新失败使它们失效时才重跑，并说明理由。
- 不创建新聊天或新代理，不自动发消息给其他会话。最终报告由用户转交主代理。
- 使用新目录 `G:/AIRTS/AI_RTS/agent/runs/20261015-adjutant-external-validation-01`。若已存在，换唯一新编号，不覆盖。长期报告另存 `agent/reports/closed-loop/2026-10-15-adjutant-external-validation-01.md`。
- 先完成下面 P0，产生首份可交付报告；再推进 P1/P2。不为凑全矩阵重复已知失败，也不把某条链路阻塞扩大成全部停止。遇到确定的产品阻塞，保留证据并继续其他独立验证。

## 2. 工程入口和运行规则

开发根固定为 `G:/AIRTS/AI_RTS`。先读：

1. `G:/AIRTS/AGENTS.md`（若存在）及主工程 `AGENTS.md`。
2. `skills/airts-workspace-boundaries/SKILL.md`。
3. `skills/闭环验证工作法.md`、`skills/AI_RSI自校验循环.md`。
4. `skills/airts-temporal-playtest/SKILL.md` 和 `agent/manifest.json`。

先执行并记录退出码：

```powershell
git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel
git -C G:/AIRTS/AI_RTS status --short
& 'D:/software/anaconda3/python.exe' 'G:/AIRTS/AI_RTS/tools/check_workspace_target.py' --mode develop --target G:/AIRTS/AI_RTS
```

这是共享的未提交工作区，不执行 reset/clean，不替换或恢复他人的文件。打包版、归档、引擎和运行依赖保持原位；`build/adjutant_runtime`、副官 venv 和 `tmp_logs/langgraph_recon/runner_ctl.py` 不能当缓存清理。默认模式保持 `plan`，本任务不授予默认晋级或发布权限。

引擎使用：

`G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe`

所有源码实测明确 `--path G:/AIRTS/AI_RTS`，核实实际 PID、creation time、exe、完整命令行和实例记录。辅助控制台从启动时隐藏，不用 console exe、不批量杀进程。退出码从实际进程句柄取得，正常退出与强制清理分开；清理只能作用于本轮拥有的完整身份。

工具 Python 为 `D:/software/anaconda3/python.exe`；产品副官 Python 为 `G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe`。后者会委派 base interpreter，但依赖 site 必须属于原 venv；不要装包、混用环境或放宽 skip 规则。`agent/runs` 被忽略，搜索它时需 `rg --files --no-ignore`。

## 3. 当前准确交接状态（2026-10-15）

Runner fresh05 **已局部接受**，不是待应用候选。两个产品文件当前应为：

| 文件 | SHA256 |
|---|---|
| `source/adjutant_coordinator/deploy/agent_runner.py` | `4fc7b7d9ec39d9b372999c3b2b1edc69594501e72879c0d1f46baf39f9f9c615` |
| `source/adjutant_coordinator/graph/strategy_variants.py` | `36275cc9056c392fbbdab5f91de6bfab08e49f9c41e705cd7fbdb03011c82669` |

定义路径缩写，以下均为绝对路径：

```text
R = G:/AIRTS/AI_RTS/agent/runs/20261014-strategy-resume
T = G:/AIRTS/AI_RTS/agent/runs/20261014-resume-transport-prep
M = R/runner03-main-runtime-prep
A = T/runner03-exact-apply-prepared-fresh07/runner03-product-fresh05
S = T/runner03-product-s2-prepared-fresh06/runner03-product-s2-fresh05
V = R/carrier01-runtime-prep/task-summary02-runtime-prepared/runner03-baseline02-readonly-review
```

权威交接原件：

- `A/decision.json` SHA `161c089fa8d6249ce026ee74535e952a6b12761b0562aa9f99145017039ac23b`，决策为 `accepted-local-normal-runner-S1-S2-independent`。
- `A/candidate-source-freeze.json` SHA `7f04ba8e79a19b2bec93a56c5f06ab2f82eb2fc3a0b7746ffe747ef5700e6676`。完整 **1263 文件、12 DLL，含四个 Core DLL**；原1262范围完整保留，唯一新资产是矿场中文语音。
- `M/runner03-main-fresh05/summary.json`：44/44，82.625064611 秒墙钟。正常入口、真实 LangGraph、两次请求、正式采纳、tactics off，旧 Move/到达/退局/同客户端重开通过。
- `M/runner03-main-fresh05-launch/launch-final.json`：driver15040、servers33164/32956、client27044、venv28464/base26756均实际自然 OS0，强清0；完整 stdout39130B、stderr0，lease 已停止并 join。
- `S/summary.json` SHA `817445ab8aef71c07a33b2c79e8e90311bea9fe49ec61f8f440ef5dbd22ae3c0`：原四组226/165/54/15，共460项，零skip，23.110021591秒墙钟，所有拥有进程自然OS0、日志/EventAPI/全文件身份通过。
- `V/runner03-fresh05-runtime-independent-review-fresh02/runner03-fresh05-runtime-joint-audit.json` SHA `98e08a8ee337f363b6c081ff9083940ddfd6cc5f9a642c9bfdc0199ffad94a43`：79/79。首轮自身 binding 计数判据错误保留，新fresh02核完整62链，不改父输入。
- 同目录 `verification.md` SHA `7e6a1a6368d282513d4d9a92c2fa142080dba141f3da340ba914b25fab29c54a`。

以上 S1 全部使用 fake 选择器，`native_valid=false`。退出前两请求、完整归档三请求不能混为两个总请求。正式采纳和 Move 回执不能直接证明战略执行收益。默认仍 `plan`，全局 champion 没有晋级，原连续未提升计数3保持。

已接受的前置改动有 Carrier03、Selection03、TCP03、TaskSummary02 fresh02、HPFixture02、NetworkReady02、RefineryVoice fresh03、AudioServer03；沿 `A/decision.json`、`application.json` 和接受链读取，不重新推断。旧 Runner fresh01–04 均拒绝，不追认。Pause01/02/03 及唯一 native 诊断已经停止，**不要再重复暂停候选或换编号碰运气**。Network02没有generation/token，不能宣称覆盖新start后的旧ACK、伪造remote/listen或old-node。

持续记录在：

- `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-14-adjutant-strategy-resume.md`
- `G:/AIRTS/AI_RTS/agent/plans/2026-10-14-adjutant-strategy-resume-plan.md`
- `R/checklist.md`
- `G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-implementation/champion.json`

旧文档是追加历史，读到“当前未应用”时继续看末尾和新decision，不能回滚已接受fresh05。

## 4. P0：核实交接并完成首段后台录像

先独立核验上述决策、原件SHA、接受链及当前1263 SHA+mtime；发现漂移就记录来源、受影响范围，不修改文件或凭mtime重新认定工程。把“历史原件真实且与交接一致”和“本轮新测试通过”分别报告。

视频准备文件位于 M：

- `background_video1263_s1.py.draft` SHA `fdada9e002b670da66962b8687a76f12701a55f1ceaff2123f9d28247cc15249`。
- `launch_video1263_actual_handle.py` SHA `cdaf9d5d58cb54361fd27edee4f59dff27095ba9bbbe3117a1e2caeac3a3362a`。
- `qualify_video1263_offline.py` 及 `video1263-fresh01-video-offline-qualification/summary.json`：root离线63/63，**尚无真实录像资格**。
- `video1263-independent-audit-fresh01/verification.md`（SHA `1afc6a079fecc54fcbec2fbcdc029693dbb16e0a30770c6df1a80e54ebbe2592`）和 `summary.json`（SHA `22bbaf3016ee704b1970ebfca2680c06413530ecf4a64bc1362f4a858b522522`）：只读独立审查交接资料。审查截至交接时未执行反例，没有真实录像；该目录audit.py未执行、未资格。

先复核两处新发现，若属实，在你自己的新工具版本修证据工具并完成正负资格；不改全局 `tools/dev/record_playtest.py` 或旧工具原件：

1. 原 `review` 会把请求 `--end` 截到实际容器时长后仍返回0；旧driver只查解码进程OS0，未严格校验解码索引数量、全帧连续性、首末帧及实际JPEG。需要拒绝短视频、截断索引、缺失/重复帧、错误FPS和解码文件缺失，不能把截断成功当整段覆盖。
2. 原 `validate_signal` 只检查 Summary/Runner 的JSON `pass=true` 和hash；需确保是本轮已接受的正确阶段、候选和源码freeze，而不是任意pass文件。root的green signal只是内部运行前闸门，不是要求用户再审批；可在核实决策后自行生成等价的、明确绑定本轮freshfreeze与已接受decision的运行声明。

录像目标：新鲜正常 Match、24秒、5FPS、120真实采集帧、独立桌面/指定游戏窗口 PrintWindow。记录移动前等待、命令、连续位移、到达、正常退局和菜单；视频与动作/状态共用时间轴。不要更改游戏tick、模拟速度或画质来配合录像。

全程不激活、不置顶、不移动真实鼠标，不使用系统输入、不录整桌面；用户仍可正常聊天和用电脑。不能把GPU窗口最小化后假定仍刷新。捕获失败就记录并诊断后台兼容性，不能抢前台绕过。当前driver是 **command-level**；UI点选/框选/右键/持续按键没有真实走通就写未验，不能冒称玩家试玩通过。单独核实输入工具、PID和路径后才测试支持的UI链路，不用warp_mouse。

必须打开并实际查看解码联系表和动作/疑似异常区间的原帧（5FPS按0.2秒看）。报告给出视频秒数、帧路径、可见动作与状态关联、缺帧/重复/后台身份、无音轨限制。生成联系表只算 extracted_not_reviewed。命令/状态通过但画面不可见时，视觉验收不能填pass。

## 5. P1：真实本地模型同输入比较

先读 `M/model-comparison-preparation.md`。现有 `.env.local` 只读检查显示 strategy/tactics model 为 `minicpm5-adj-16k`、战略端点 `127.0.0.1:11436`、timeout15秒、密钥配置存在；你应重新核实本机现状和实际模型身份，不能仅凭名称宣称2B。密钥不打印、不复制进证据；不更换/重启服务，不改模型/venv配置。只使用用户现有本地服务做有界请求，不误用远程地址。

目标模式为 `plan` 对照、`rules / score_only / template / choice / score`，先 tactics off，再分开验证 tactics on。开始先做少量有界真实调用，确认枚举合法性、延迟和降级，再扩矩阵。

必须区分两类比较：

1. **冻结输入重放**：新正常入口在provider调用边界归档完整context及hash；旧 `model.jsonl` 只有proposal/meta，没有完整输入，不能据此声称exact same-input。只读取证wrapper需披露、限制大小/次数、保留未替换正常入口验证，不改变传入context、候选、结果或调度。各模式消费相同冻结事实；plan保持原完整输出合同，不人为改成选项合同。若正常plan与narrow所用context不同，明确两种实验设计及差异，不伪称字节相同。
2. **实局矩阵**：同map/seed/初始资源/控制权限/模拟预算/引擎配置，保留默认review周期；后续轨迹不同是结果，不宣称每次后续输入相同。不要手工补矿场/单位掩盖执行缺口。

choice和score必须复用同一不可变SelectionRequest；不同显示顺序保留canonical语义ID。候选数为n时做n次均衡循环置换，不能用不均匀置换证明位置偏差。score无歧义的程序直选不算模型调用。rules/score_only不得要求密钥或发模型请求。

逐项记录：context/request/候选hash、实际HTTP调用数/成功、耗时、usage/finish_reason（可取得时）、完整输出存档及hash、结构/枚举合法性、native_valid、fallback原因、语义选择、采纳/hold/rejected/stale。只有实际模型合法返回才标model_native；fake永远nativefalse。不得用模拟选择器得出2B收益结论。

## 6. P2：执行、长局和全量验收

按 `request → plan → task/intent → 权威receipt → 实际结果` 追踪，分开“合法输出、采纳、下发、完成、收益”。至少核正常开局、合法KEEP、权限负例，再覆盖敌方、跨图/seed、玩家接管、故障降级、长局（原计划240模拟秒）、退局重开、清理和相关性能。长局须有墙钟/内存预算和拥有PID的watchdog，不无界挂机。

已知缺口需要验证，不得在测试中替产品补齐：

- HQ在四列frame中为facility，当前可用技能PROD/STOP，BLD执行缺口仍在。
- 四列task_id默认actor/squad，未必等于战略task_id；相关只读资料 `R/execution-association-prepared/direction.md`、`receipt-lifecycle-readonly.md`、`current-provenance-replay-public-refs.json`。后者是离线复现，不是正式采纳正例；其plan版本不一致限制保留。
- 不能直接替换task_id来“修来源”：Completed回执可能提前标战略任务完成。必须区分一个任务多命令、迟到回执与真正战略completion。
- Memory02历史checkpoint保留/内存增长、经济工地精确身份仍待产品处理。本次Memory只读收口没有新建证据文件。旧材料见 `G:/AIRTS/AI_RTS/agent/runs/20261014-strategy-implementation/memory-02`、`T/fresh02/memory-draft/behavior-results.json`、`T/memory-draft/behavior-comparison.json` 和 `T/memory-extra-results.json`。当前graph.py仍用原MemorySaver，SHA `379ddfbac04872e1b6f84f93475fb4fac5b42d678b5a86713d5cc538308e1976`；草稿从未应用。离线9/9合同不证明真实内存收益，额外故障曾让新增计时/诊断异常阻止业务输出回写，不能忽略。旧真实long240的RSS增长不能当当前fresh05基线或直接归因为图历史。

若这些缺口使模式在实局无法兑现，报告实际差异/阻塞与最小复现，不伪造Accepted或收益。先完成可独立验证的部分，再把需产品实现的项交回主代理。

全量S3使用当前工程正式清单与原marker/rc/forbidden判据。既有历史资料记载清单预检阻塞及旧音乐断言与当前normal/intense MP3口径不一致；重新验证并分类，不擅改断言/配置换绿。原始stderr、ERROR/Fatal/NUL、EventAPI/WER、资源泄漏、强清和残留都须判定，OS0不能覆盖日志硬红。工具错误仍保留原红，用新工具/新目录修正，不能覆盖或追认历史测试。

## 7. 报告要求

首份P0报告完成即给用户可转交结果；后续更新同一任务状态，避免只持续报“准备中”。最终报告至少包含：

- 当前工程身份/源码freeze、检查命令与rc、测试时间和新鲜度、原始日志索引。
- 已接受历史证据核验与本轮新证据分别列出；各项pass/fail/blocked/unverified有明确依据。
- 模式比较表（真实模型调用与fallback分列）和执行结果表，真实2B收益无证据时明确未得结论。
- 视频路径、实看区间/帧、动作时间线、command-level/UI-player等级和无音轨等限制。
- 实际退出码、强清、日志、EventAPI、lease、残留、内存/墙钟，完整1263与DLL身份是否保持。
- 给主代理的问题清单：最小复现、证据路径/视频秒数、影响、建议修复文件，按阻塞程度排序。
- 未验证项和产品阻塞；不改变default plan、不宣称全局champion或整项改造完成。

不要只把本提示复述成计划。先核实当前接受原件，然后从P0开始实际工作。
