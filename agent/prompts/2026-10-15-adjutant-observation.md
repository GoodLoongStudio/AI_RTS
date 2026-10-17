# 重跑副官观察

先读主工程 AGENTS.md 与工作区边界规则。运行 `D:/software/anaconda3/python.exe G:/AIRTS/AI_RTS/tools/dev/adjutant_observe.py observe --seconds 600`，等待程序生成的 report.md。已有本机服务可加 `--model-port 11434`，显式复用并保留该服务；不带参数则启动独立服务。保持当前真实模型、plan 战略、tactics on 与 LangGraph；不改生产策略或用户配置，不结束别人的进程。观察工具采用正常单人菜单回调的 command-level 无头自动化，不认证鼠标 UI、GPU 或战斗表现。

先核对 summary.json 的实际观察时长、调用结果、端口/PID、源码冻结与清理，再读 report.md、model-calls.md、模型完整输入 JSON、runner 原生 archive。区分模型可见输出、程序规则解释、正式采纳、权威回执和实际世界结果。不可将隐藏思维链、字符串长度、配置 16K 或响应成功分别冒充可见决策依据、真实 token 数、实际分配上下文或有效战略。先报告可核查的现象与证据，再提出最小定位方向；本提示词不授权产品优化。

还须读 strategy-details.md 和 tactics-decisions.md。runner 的内部 exit 日志不等于实际 OS 退出码；输出 `finish_reason=length`、扫描间隙、stderr 与强制清理不能隐藏。2026-10-15 首次完整局 600 秒采集成立，综合门禁仅18/20、needs-review；不能继承为全绿。启动器最后补了 null 防护与报告索引，未再跑第二次600秒，不追认旧错误。
