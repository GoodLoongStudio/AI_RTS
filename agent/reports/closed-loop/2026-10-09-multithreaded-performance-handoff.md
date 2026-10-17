# 多线程性能任务：新会话交接记录

日期：2026-10-09（北京时间）。
状态：交接文档已静态核验；游戏性能目标仍为 `needs-review`，未实施本计划中的产品优化。

## 交付范围

用户要求为新 DeepSeek Harness 对话重新制定计划和提示词，重点考虑多线程。开发根为 `G:/AIRTS/AI_RTS`，本轮写入仅三份 Markdown：

- [执行计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-09-multithreaded-performance-plan.md)
- [DeepSeek 执行提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-09-multithreaded-performance-deepseek.md)
- 本交接记录。

后续实现报告应另写 `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-09-multithreaded-performance-report.md`，不能把本记录当性能达标证明。

## 方案重点

1. 重新建立健康的真实 Match 基线，先诊断 100/200 单位，再按预算扩到 1000；正常编队和病态汇聚分开。
2. 线程画像区分主线程计算、worker CPU、等待及帧同步；线程 CPU 时间重叠，不能当互斥阶段相加。
3. Godot 原生避障已有多线程配置。物理服务器独立线程不等于用户移动脚本自动并行，历史注释不能代替实测。
4. 先消除被证明的重复计算，再将可独立的纯数据计算分块并行；快照、提交、版本校验、取消、锁和数组生命周期均设门禁。
5. 保留碰撞、速度、射程、视野、模拟频率、副官与画质；检验真实位移、攻击、采矿、生产和模拟时间，不拿停止模拟换 FPS。
6. 设置 watchdog、样本有效性和三轮无提升换方向规则；性能改动须回归、独立复核、查看截图并检查退局清理。

## 验证记录

- `git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel`：rc=0，根目录正确。
- 对三份文档分别运行 `python G:/AIRTS/AI_RTS/tools/check_workspace_target.py --mode develop --target <绝对路径>`：均 rc=0，允许在主工程内写入。初稿首次创建没有留存逐文件前置检查，本轮补订及新增报告前已补跑；不以事后检查冒充首次创建前已执行。
- PowerShell 严格 UTF-8/非空/代码围栏/关键门禁/尾随空白检查：rc=0，标记 `DOC_STATIC_VALIDATION_OK`。16 个依赖入口存在，4 个相关测试 ID 在当前套件清单中存在。
- `git -C G:/AIRTS/AI_RTS diff --check -- <两份计划/提示词路径>`：rc=0。文件尚未跟踪，因此另做直接内容检查，不把空 diff 当作唯一校验。
- 补订前后 Movement、project.godot、PerformanceGovernor 的 SHA256 和 mtime 一致，未修改这些游戏文件。
- 审计中一次补丁因提示词行匹配失败而整体拒绝，确认没有部分写入后拆分补丁成功；这是文档编辑失败，不是产品解析错误。

已读取 10 月 7 日证据复核及实施报告更正声明。10 月 9 日已有 `_ThreadCfg` 运行记录报告两个 avoidance 线程设置为 true、24 个逻辑处理器、Godot 4.7.1 Mono，退出 rc=0；仅证明设置，不证明真实线程利用率或速度提升。

## 未验证与共享风险

没有本轮新的 before/after FPS、线程 CPU trace 或画面截图；没有执行新 Match 性能测试、C# 构建、相关/全量回归或优化候选独立运行时复核。按文档类任务例外，以上不阻止交接，但禁止据此宣布性能已修好。

未接受产品 candidate/champion，也没有产品迭代轮次。共享工作区检查时已有 941 条状态记录，均保留；Movement 当时 SHA256 为 `7BE4324DB193E9381A8497E49F0449D57F4D8D76CC0B4B8EB0352EE2E952B53F`，已不同于旧报告版本。新会话必须重新核对当前 hash/mtime，不恢复旧版来套用旧数字。

本轮未重打包、未覆盖评审成品、未修改 GitHub release、未清理他人文件或结束用户运行实例。计划中的优化收益和 1000 单位容量均待实施验证。
