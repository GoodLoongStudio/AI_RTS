# Debug TCP 生命周期修复计划

状态：in-progress / candidate 未晋级。源码根 G:/AIRTS/AI_RTS。

## Controller
唯一假设：poll 缺失使合法短连接残留；线性 survivor 回收使维护成本不随历史连接增长。授权仅 DCS、专用 tools/test、计划报告 runs。不覆盖已有 DCS 并行差异、不碰用户 PID/输入。

## 验证顺序
1. [x] 重读任务/AGENTS/边界/manifest/RSI/闭环/性能测量/根因报告；target rc0。
2. [x] 确認当前 diff/mtime（旧差异全部保留）。
3. [x] 最小 poll/线性回收、bounded bytes/peer/work、UTF8 半包、截图/current client 生命周期。
4. [x] 编译rc0及新隐藏真实Match；工程cache/import错误仍明确保留。
5. [x] 10000完整短连接、成功率/内存/维护 p50/p95/p99、稳定基线。
6. [x] 持续连接/UTF8半包/300多行/异常断开重连/buffer与截图上限；128连接饱和未测。
7. [x] 副官scout意图真实移动15.244m/选中组接管PlayerOverride/第二局；UI/runner/大厅级未测。
8. [ ] 相同负载画质视角可见持续性能对照，截图实际打开（待coordinator分工）。
9. [ ] 相关5套runner rc0但严格forbidden仅1/5干净；全量和独立代理审查未完成。
10. [x] requirement→evidence闭环报告与needs-review不晋级champion决策。

证据目录：G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle。
停止条件：解析/启动/命令/清理硬门失败不晋级；不得用改判据或关系统变绿。可见性能期间不并行回归。全部未验证项明列，不能称完成。

## 17:49 独占验证附记（精确追加）
- [x] 两条可再生class cache路径精准修复；已定位副本加.gdignore保留4文件，cache-repair.json留证。
- [x] 新拥有隐藏真实Match实测128idle/FIN/慢读，boundary-review/result.json；进程自然退出rc0，精确PID复核无残留。
- [ ] **blocked：FIN完整300行仅1条响应即EOF；慢读旁路5次2s超时。已报协调者，等待最小DCS补丁后重跑。**
- [ ] 非激活可见持续性能：独立desktop首次EnumWindows失败；工具已改EnumDesktopWindows但尚未重跑；不是用户desktop UI通过。
- [ ] 可见截图实际打开、低频录像回看、截图混合pipeline顺序、UI-player仍未测。
- [ ] 串行124套/严格forbidden审计按硬失败停止条件暂停，未放宽判据。
- [x] 主报告附录/checklist/champion追加结果；候选不晋级，原始证据保留。

## round-02 Controller/Verifier更新
- [x] 拒绝802e58首candidate而不reset；保存baseline/candidate和diff，新方向：poll与输出义务排空绑定。
- [x] 官方4.7.1 TCP实现确认FIN poll直接关闭、partial write非阻塞；保持长度UTF8协议。
- [x] 有界partial输出/peer全局budget/high-water停读与派发，明确idle5s/incomplete30s政策；只改DCS产品。
- [x] build/autoload解析rc0；新PID真实Match 10000/10000，77.281s，稳定1/1、旧移动15.244m/PlayerOverride/第二局rc0。
- [x] FIN300/300、慢读20000旁路5次0–16ms、fixture真128/128后129th4.969s恢复、混合shot/status+FIN关联排空。
- [x] 记录首次容量测量失败（建立期间idle退出），修工具刷新建立期activity后完整重跑真满，不改产品或放宽断言。
- [x] 新鲜mtime/hash/PID清理、round-02及报告/checklist/champion更新；通知协调者恢复独立/串行剩余门禁。
- [ ] GPU成功截图与混合新鲜度、可见同负载持续性能、UI/runner/大厅级、严格相关/124全量与独立运行签署。
- [ ] 未全绿不晋级；状态needs-review，连续未提升2产品轮。头less已有ERROR保留，不当作全工程干净。


## round-03 全局不变量阶段
- [x] 读取round02独立review、核验32ce基线/mtime/diff/路径rc0，保存基线。
- [x] Controller换全局背压方向；精确修kernel待收不能idle取消，声明执行后超大回执不可盲重放。
- [x] build/parse rc0；80slow真实global16779384 bytes保持7.125s+额外FIN请求保留/240000排空。
- [x] 新PID10000/10000，旧副官位移/PlayerOverride/第二局和FIN300/128idle/单slow/shot全部重跑。
- [x] 失败工具证据保留，source/PID核验；报告/checklist/champion更新。
- [ ] 后续独立/可见/全量由其他代理独占，本轮不启动。needs-review不晋级；连续3轮未提升阶段饱和停止微调。

## 验证基础设施新方向 Controller（阶段饱和后）
冻结 DCS 65795566…b47，连续3轮产品不晋级不变；本阶段只编辑专用工具/夹具与证据。新假设：前两轮“无窗口”只枚举 visible HWND，未区分原生窗口存在、窗口可见状态和GPU实际绘制。先记录引擎 display/render driver/native HWND 与全部拥有窗口及实际进程参数，定位具体过滤/窗口隐藏原因；不重复盲启。改用 frame_post_draw 后主viewport捕获，不依赖OS窗口抓取，独立desktop启动即隔离，不切换desktop/激活/系统输入/warp_mouse。真实Match固定合法生成46实体、种子/相机/原生产质量，三段至少20秒无录制稳态测量加60秒5FPS连续捕获与实际回看；完整保留长帧、process/render间隔、真实physics delta累计模拟秒/墙钟秒和清理。读回事件单列，不删除其长帧。baseline只允许隔离脚本/worktree加载，不覆盖主DCS；本阶段可先候选同场景持续复验，诚实声明无合法同场景旧版对照。预算：单实例watchdog 240秒，资格失败先修工具，绝不以blocked勾完成。不重复万次/124套，不修产品。

## 冻结候选最终门禁追加（20:43）
- [x] 冻结65795566…b47每套前后hash一致，未改产品。
- [x] 非干扰GPU资格实际执行两轮；独立desktop无可捕获HWND，rc1，visible-01/02证据保留。
- [ ] 可见持续性能/截图实际打开/录像回看/UI-player：环境blocked，不抢用户前台，不冒称通过。
- [x] 串行124/124全部完成；两次外部137中断按42/120进度续跑，旧日志未覆盖；最终rc1，严格38/124、marker+rc78/124，不放宽判据。
- [x] final-strict-audit.json逐项错误/失败/hash/mtime/PID复核落盘；最后四项观察其他非拥有Godot并发风险保留，不杀其PID。
- [x] 主报告prompt逐条最终证据映射、checklist/champion精确追加；needs-review，连续3轮不晋级。
- [ ] 独立round03运行签署、可见/UI/runner/联网大厅级、86项非绿及最大合法响应上界仍未闭环。
