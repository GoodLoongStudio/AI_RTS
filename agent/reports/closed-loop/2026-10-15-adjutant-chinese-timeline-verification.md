# 副官输出中文对照：闭环验证记录

交付：[374 条中文时间表与完整原文](<G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-chinese-timeline.md>)、[可筛选中文阅读页](<G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-chinese-timeline.html>)。本轮中文展示与原文完整性验证通过，原观察运行仍维持 needs-review、18/20、rc=2。

## 用户问题与结果

用户指出原始结构化输出缺中文，并询问语言模型这样输出是否合适。本轮把全部 374 条记录转换为四栏：调用时间、当时输入事实、决策中文与模型原话、程序结果与对照提示。原始输出及完整程序对象仍嵌入 Markdown 每条附录，HTML 可展开查看。

| 验收项 | 之前 | 现在 |
|---|---|---|
| 逐条中文含义 | 原 JSON 为主 | 374/374 条提供中文说明 |
| 战略理由 | rationale 混在对象内 | 单独原样引用；为空时标记未记录 |
| GAT/W1/R14/P5/D12 | 要自行查缩写 | 翻译采集、执行者成员、当次实际资源与坐标、参数和进攻路线 |
| 空意图 | 仅见 intents=[] | 251 条逐条说明与现任务相同、程序不重复生成意图 |
| 格式与决策 | 容易把封装成功等同有效决策 | 列出无计划却维持、输出截止帧与输入帧比较、失败任务仍维持等对照 |
| 原文与异常 | 完整保留 | 39 战略原文、333 成功战术文件、3 次失败仍全部保留 |

中文说明只来自本次 context、result、HTTP 和返回记录。没有把跨调用的引用表混用。战术没有保存自然语言理由时写“未记录”，不代写推理。置信分数不当作成功概率，解码 accepted 不当作游戏命令已执行。

## 对输出格式的判断

真实请求主动约束战略只输出 StrategicPlan/JSON，因此没有长篇聊天式说明是接口要求。语言模型可以输出结构化决策；格式合法不能证明战略合理。

本样本已证明存在可观察问题：strategy-0008 请求允许 1280 completion token，实际只生成 512 且 finish_reason=length，响应截断；模型配置 num_predict=512。strategy-0001 无当前计划却要求维持。strategy-0028 输入帧 9557、计划截止帧 4480、矿场任务失败和完工/交货为 0，却声称计划仍有效。这些可复查，不能归因于“没翻译”而忽略。

战略亲自复制的身份编号、规则哈希和时间字段可以作为精简接口的候选；中文由日志程序生成即可。下一步若优化，建议测“精简决策 + 短理由 + 可核验依据/重规划条件，程序补元数据”的方案。它尚未实施或 A/B，不能宣称必然提高小模型能力，也不能把长篇自然语言当作更好战略的证明。

## 新增文件与范围

开发根 `G:/AIRTS/AI_RTS`，Git 根核验一致，所有新目标路径检查 rc=0。新增[导出工具](<G:/AIRTS/AI_RTS/tools/dev/export_adjutant_chinese_timeline.py>)、[任务计划](<G:/AIRTS/AI_RTS/agent/plans/2026-10-15-adjutant-chinese-timeline.md>)、[重放提示词](<G:/AIRTS/AI_RTS/agent/prompts/2026-10-15-adjutant-chinese-timeline.md>)、中文 Markdown/HTML/[来源清单](<G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-chinese-timeline.manifest.json>)与本报告。原英文键名完整时间表和原始证据保持原状。

共享工作区已有其他会话改动，本轮只新增自身文件及更新自身新计划，没有重置、清理或覆盖它们。游戏、模型提示词和参数没有改；产品 champion 与连续未提升轮数不变。中文导出作为文档产物接受，不晋级游戏候选。

## 验证与 rc

导出真实运行 rc=0：

```text
D:/software/anaconda3/python.exe -B G:/AIRTS/AI_RTS/tools/dev/export_adjutant_chinese_timeline.py --run C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02 --output G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-chinese-timeline.md
```

不导入导出器的独立核验 27/27、rc=0：[详细 JSON](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/chinese-timeline-independent-verification.json>)。逐条核对 374 个 ID、完成时间顺序、39 条战略字符串、333 战术原文件、全部已保存理由、371 份对象中文字段可逆映射、动作/实体/位置/路线、空意图与异常、HTML 与 Markdown 中文一致、原文附录以及 828 个来源 SHA-256 不变。1,197 个原件链接引用全部有效。

```text
D:/software/anaconda3/python.exe -B C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/verify_chinese_timeline.py
node --check C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/chinese-timeline-browser-script.js
```

JavaScript 静态检查 rc=0。Edge 实际打开页面，验证 13/13、rc=0：[浏览器结果](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/chinese-timeline-browser-verification.json>)。覆盖全部 374 行、战略 39、失败 3、中文搜索、ID 搜索、时间筛选、重置、引用翻译、无理由标注、展开原文、截断原文和页面无错误。第一次浏览器检查只有一项原文对比失败：浏览器按 HTML 规范把源文件的 68 个 CRLF 规范为 LF；原件没有少内容。改为明确规范化换行后比较，字节与字段完整性仍由独立文件校验负责，未放松产品判据。

```text
node C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/verify_chinese_timeline_browser.cjs
```

新截图已实际打开查看：[全表中文入口](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/chinese-timeline-all.png>)、[战略 0028 事实与原话对照](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/chinese-timeline-strategy-0028.png>)、[战术 0004 中文动作与空意图解释](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/chinese-timeline-tactics-0004.png>)。肉眼确认各栏可读，模型理由与程序提示以不同区块展示，R14 与 ResourceA7/坐标同时保留，空意图解释与未记录理由标注清楚。测试浏览器已关闭。

## 未验证项

按工程 RSI 文档类例外，本轮没有新开真实 Match、没有修改产品或跑游戏回归，没有验证任何优化方案的实际收益。来源是已经完成的 600 秒观察，含收尾返回，不拼接中断局。原观察的 runner 收尾与游戏 stderr 门禁仍未通过，见[原观察报告](<G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-observation-10min.md>)。Codex 打开请求已提交，工具返回 queued；实际视觉核验使用已打开的 HTML 阅读页，不据此声称直接验收了 Codex 的大 Markdown 渲染。
