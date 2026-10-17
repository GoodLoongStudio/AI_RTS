# 副官完整输出时间表：导出闭环验证

本轮交付是用户要求的逐条完整输出表：[Markdown 正文](<G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-full-output-timeline.md>)、[可筛选 HTML](<G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-full-output-timeline.html>)。证据导出与阅读页验证通过；原对局采集的整体状态仍为 needs-review，审计仍为 18/20、rc=2，没有追认全绿。

用户指出原交付只有总结、调用索引及原件链接，无法直接按时间看完模型输出。新交付正文直接嵌入全部 374 次调用的输出或异常，按结束时间排序并保留开始时间，战略原文与程序解析结果分列。

## 基线与结果

| 项目 | 原交付 | 本轮交付 |
|---|---|---|
| 单一时间表中完整展开的调用 | 无完整统一表 | 374 条，39 战略 + 335 战术 |
| 战略可见原文 | 链接或解析对象 | 39 条真实 HTTP content，逐字符核对 |
| 成功战术完整对象 | 摘要及链接 | 333 份 result/selection/laya/decode 全字段 |
| 失败调用 | 分散于原件 | 3 条完整错误，截断战略原文也在 |
| 空意图 | 原件保留 | 正文保留全部 251 次成功空意图 |
| 独立程序处理事件 | 原图日志 | 文末完整列出 39 条战略处理原始事件 |
| 原始证据一致性 | 已存在 | 本轮读到的 828 个文件 SHA-256 全部不变 |
| 阅读与筛选 | 多处文档与原件 | 完整 Markdown + 同内容 HTML，角色/状态/关键词/时间筛选 |

输出结束时间覆盖相对 00:01.348 至 10:01.365。最后两条在 600 秒观察结束之后返回，作为同一轮的收尾记录保留；没有增加观察时长或拼接中断局。第一个战略请求开始于零点前约 0.186 秒，负时间同样保留。

战略回复只表示已保存的可见输出，不能代表内部思维链。Laya 战术是结构化选择及解码记录，不当作 335 次生成式聊天。程序 `ok=true` 不表示游戏采纳；图内事件按同 tick 世界轮次标时，独立展示，没有编造与每次返回的一一因果关系。

## 改动与路径

开发根为 `G:/AIRTS/AI_RTS`，Git 根核验一致。新增目标的主工程边界检查均 rc=0，实际目标没有落入打包版、运行时或历史副本。

- [只读导出器](<G:/AIRTS/AI_RTS/tools/dev/export_adjutant_timeline.py>)：只加载已有 JSON/JSONL，新增文档与来源哈希清单；拒绝覆盖现有输出，不启动游戏或模型服务。
- [任务计划](<G:/AIRTS/AI_RTS/agent/plans/2026-10-15-adjutant-timeline-export.md>)、[可复用任务提示词](<G:/AIRTS/AI_RTS/agent/prompts/2026-10-15-adjutant-timeline-export.md>)。
- 完整 Markdown、同内容 HTML、[来源与输出哈希清单](<G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-full-output-timeline.manifest.json>)及本验证报告。

原采集器、原观察目录、游戏源码与模型配置未由本轮改写。共享工作区已有大量其他改动，未清理、还原、暂存或提交它们；本轮只创建自己的文件并更新自己的新计划。产品 champion、产品连续未提升计数保持原状；本轮接受的仅为文档导出产物。

## 验证命令和证据

导出执行 rc=0：

```text
D:/software/anaconda3/python.exe -B G:/AIRTS/AI_RTS/tools/dev/export_adjutant_timeline.py --run C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/20261015-adjutant-observe-10min02 --output G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-full-output-timeline.md
```

独立内容验证 rc=0，18/18。验证器不导入导出器，从原始调用、HTTP 和结果文件重建期望值，反解 Markdown 单元格并检查每个 ID、排序、开始/结束时间、全部战略原文、全部成功结果、异常、空意图、截断尾部、战略 0028 原话、39 条图内事件和所有文件链接。1,237 个链接引用、826 个不同目标均存在；828 个来源哈希不变。证据：[完整性校验 JSON](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/full-output-timeline-independent-verification.json>)。

```text
D:/software/anaconda3/python.exe -B C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/verify_full_output_timeline.py
node --check C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/full-output-timeline-browser-script.js
```

JavaScript 静态检查 rc=0。真实 Edge 无头打开 HTML 后验证 9/9、rc=0：全部 374 行已渲染；战略 39、战略失败 1、战术失败 2 的筛选数量正确；ID 搜索一条；600 秒以后筛出两条收尾；重置恢复全部；截断原文渲染后的 textContent 与服务端逐字符一致；无浏览器脚本错误。证据：[浏览器校验 JSON](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/full-output-timeline-browser-verification.json>)。

```text
node C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/verify_full_output_timeline_browser.cjs
```

已实际打开查看三张截图：[全部记录入口](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/full-output-timeline-all.png>)、[截断战略回复](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/full-output-timeline-truncated.png>)、[空意图战术记录](<C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/full-output-timeline-empty-tactics.png>)。表头、时间、ID、原文和程序返回各列可读，筛选计数正确，空意图保留原始空数组，截断尾部没有被补写。阅读页验证所开的浏览器已关闭。

## 未运行与边界

本轮只做证据文档导出，依据工程 RSI 的文档类例外，未新开真实 Match、未跑游戏回归、未录玩家操作视频，不声称修复战略或执行行为。Codex 打开 Markdown 工具返回 queued，因此只记录已提交打开请求；HTML 已由浏览器实际打开和截图核验。Markdown 全量内容及转义反解已经独立校验，Codex 客户端的具体大文件渲染表现未直接截图验证。

旧样本中的 runner 自然退出与游戏 stderr 门禁仍未通过，详情保留在[原观察闭环报告](<G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-observation-10min.md>)。本轮交付用于用户逐条检查已有输出，不改变这些运行结论。
