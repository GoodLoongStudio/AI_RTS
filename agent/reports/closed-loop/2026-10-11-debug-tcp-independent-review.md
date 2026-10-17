# Debug TCP 生命周期补丁独立审查

日期：2026-10-11。结论：**needs-review；生命周期根因修复方向成立，但不能批准为完整背压/协议闭环通过。**

最新签署状态：已完成 round-03 最终冻结hash独立静态复核；当前DCS SHA256 `65795566d1ebf1e309ed02f7fddc45c743d54508738693cb826ceb8da9b60b47` 与唯一编辑者最终声明及新证据一致。round-02的全局背压idle硬反例已修复，签署该局部修复与输出预算静态审查通过；完整任务仍 **needs-review**。首轮/二轮发现保留为历史记录，不套用于新版；最终结论见文末round-03。

## 范围、身份与独立性

- 开发根：`G:/AIRTS/AI_RTS`。已先读 AGENTS、工作区边界、manifest、闭环/RSI、性能测量规则和 `G:/AIRTS/AI_RTS/agent/prompts/2026-10-11-debug-tcp-lifecycle-fix.md`。
- 本次只写本报告；未改产品、测试驱动、缓存或主线证据；未启动 Godot、未连接用户运行实例、未重编译，因未取得与性能测试协调后的运行时段。本次独立验证是静态审查、原始产物审计及内存中的 Python 调度模型，不冒称独立真实 Match 探针。
- `git -C G:/AIRTS/AI_RTS rev-parse --show-toplevel` rc0；报告目标 `check_workspace_target.py --mode develop --target G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-11-debug-tcp-independent-review.md` rc0。工作区大量既有/并行改动，未覆盖或清理。
- 审查源码 `G:/AIRTS/AI_RTS/source/net/DebugControlServer.gd` mtime 2026-10-11 17:23:38，SHA256 `802e58a92df7e5e623ff68d63f1bac43b52fa37c34430a1e202032975d66e172`，与 probe.json 记录一致。
- `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/probe.json` mtime 17:33:25，SHA256 `ee8f97cdb79a5e982612f5ca8cfeb649971f630a3c71aed52cc6d3f1ab3756da`。17:31:34 至17:33:25的记录晚于源码修改；只证明记录绑定了当前候选文件，不证明全部共享资源/DLL稳定。

## 独立发现（按严重性）

### R1 / P1：主线程同步发送没有输出侧背压，输入预算无法保证帧预算

**静态确认的设计缺口；实际阻塞时长未独立实测。** DCS:250、257–258、296 直接 `put_utf8_string`，并未改成可逐帧推进的 partial write，也没有输出字节预算、待发队列上限或写截止时间。Godot 的完整 StreamPeer 写入会等待完整发送完成；不读响应的客户端可在发送窗口耗尽后卡住 `_process`，包括 `request too large` 的拒绝响应路径及截图回执路径。调用后的 poll 无法为已阻塞的发送施加超时。

发送返回值还被忽略，只检查之后的 poll/status；这不是对完整回执提交成功的检查。256/16 请求预算和64KiB读取预算限制的是输入/派发数量，不限制响应大小、处理复杂度或同步写耗时。主线10000短连接均立即读取响应，不能排除此风险。

建议下一轮只验证/处理输出侧：在拥有的隐藏实例中用小接收窗口、不读响应的持续连接请求大状态，旁路轻量status测延迟并设外部watchdog；产品方案必须显式维护长度前缀+正文的发送offset与有限队列，而非仅用poll或丢合法响应掩盖卡顿。未独立运行前不填阻塞秒数。

### R2 / P2：轮转不饿死，但满负载服务呈长突发/长空窗，并非低尾延迟公平

**独立模型复现，非 Godot性能测量。** DCS:219–220、262、266–267 按轮转顺序构造survivors，再固定 cursor=1，确实使首peer每帧前进1，不是常见的“cursor永远1因此尾peer永久饥饿”错误。本审查拒绝该错误指控。

但128个持续有完整请求的peer、每peer16/全局256时，每帧只有连续16个peer得到服务，窗口只前进1。按源码同样的数组变换进行1024帧Python模型：所有128个peer各服务2048条，**最大相邻服务间隔113帧**。每peer会连续服务一段，然后长时间无服务；30 FPS条件下113帧约3.77秒，60 FPS约1.88秒（条件换算，不是本机实测）。主线只有单连接300行及8并发短连接，未覆盖此情况。

这是响应尾延迟风险而非永久饥饿/吞请求。应明确期望等待上限；若需要均匀轮询，应从上次实际服务终点继续，或采用更小服务量的分轮调度，再验证连接删除/插入时的稳定性。

### R3 / P2：容量满时只是有限backlog等待，无法保证所有合法连接最终可用

**静态确认容量占用；实际backlog溢出未测。** DCS:210–214 在128个peer存活时停止accept，连接没有idle/不完整请求截止时间。128个只保持连接且不发完整行的peer可永久占位，后续合法副官/状态请求只能排队直到OS backlog满或调用方超时；不能把“未accept后主动drop”推广为“所有合法请求不会丢/拒绝”。

保留合法持久连接是正确不变量，不能任意加短idle timeout破坏协议；仍需明确准入/不完整请求/过载策略以及重试语义，并独立测128+连接与idle占位。每peer1MiB也意味着应用buffer最多约128MiB，另有slice临时分配和内核缓冲，不是64KiB总内存界。

### R4 / P2：断开时直接删除应用buffer，FIN/半关闭与已排队合法行的语义未闭环

**源码路径确认，具体半关闭表现待引擎实测，不声称已复现Godot半关闭丢单。** DCS:222–225 在poll/status非CONNECTED时立即erase buffer，不先处理已有完整行；250–251发送后状态变坏也会丢掉剩余buffer。对RST/完全关闭且不再收响应的客户端，丢弃残余请求可能是合理取消政策，但目前没有定义。

“发送完整JSON后shutdown(SHUT_WR)、仍保持读响应”是常见合法TCP用法；是否被Godot该版本poll判为断开，及是否仍有可读/已缓存完整数据，必须实测。主线所谓abrupt_disconnect只发送未闭合JSON后关闭，再测另一个连接成功，既不证明完整请求+FIN，也不证明超预算buffer里的合法行能排空。若口径仅接受读写保持开放到收完响应，报告/协议必须明确限定；否则本路径有静默取消合法请求风险。

### R5 / P2：截图回执与普通请求没有全序/关联ID；队列回收通过不等于截图协议通过

**静态确认，主线证据支持响应超越。** DCS:498–508截图立即返回空串，后续status或第17个截图拒绝可以立即发送；前16个截图要等绘制。因此一条连接中 `screenshot → status` 可以先收到status，再收到截图。响应没有统一关联request_id来消除歧义。主线probe.py:105–109连续17个截图，第一条收到queue full，实际正是第17条响应超越前16条，不是截图全序验证。

这很可能是既有延迟截图设计的语义，并非本生命周期补丁新引入；本轮新队列上限使超越更容易显式出现。需要选择“同连接严格有序”或明确约定异步带ID响应，不应把其他op保持一问一答推断为截图混合pipeline兼容。

`_drawn_since_check`是上次flush的全局帧号，不是每个请求排队时的帧号。即便drawn大于旧check，也只能证明有历史绘制帧，不能严格证明截图请求之后完成过一帧或截图反映刚发出的camera/场景动作。没有可见成功截图、实际打开图或跨帧次序证据。

## 已通过的静态检查与不变量

1. DCS:222 poll先于status；失败/非CONNECTED同时删除buffer并disconnect；260–267单次append幸存者后整体替换，没有逐peer Array.erase。peer对象回收维护O(N)，截图最多16项额外扫描；字节find/slice/JSON成本另计，不冒称完整_process只O(N)。
2. 完整行在budget耗尽时保留：remaining/used限制while，consumed仅覆盖已处理行，剩余slice写回。持续连接且健康的合法完整行不会因单纯预算不足被主动删除。
3. PackedByteArray按newline整体解码，修复跨read UTF8码点问题；请求仍是裸JSON行，响应仍是4字节小端长度+UTF8 JSON及newline，不是纯newline JSON响应。probe.receive按精确长度解析正确。
4. `_current_client`围绕同步dispatch赋值/清null，正常返回不会长期持有最后client。perf在dispatch内部查询时显示true是预期，不能当泄漏；probe中该字段true并未验证帧末为null。
5. `_pending_shots`独立prune检查poll/status及_buffers成员，即使headless无绘制帧也能移除已死client；队列满显式retryable拒绝，不静默吞截图。flush先prune、后capture再次poll，当前看到的引用链合理。尚无exit_tree显式清理/退出中活截图测试。
6. 本补丁网络处理段没有扩大权限：listen仍仅127.0.0.1，受限模式仍先过ADJUTANT_OPS白名单，dispatcher及副官命令执行链未因预算绕过。没有运行不带--debugport的受限模式正反验证；主线夹具是全权限debug模式，不能用其PlayerOverride判据替代权限白名单验证。既有status/full_vision/as_player口径未在本轮改动，不为本补丁做安全认证。

## 原始证据覆盖审计

读取 `G:/AIRTS/AI_RTS/tools/dev/debug_tcp_lifecycle_probe.py`、`debug_tcp_match_fixture.gd`，解析probe.json并直接统计 `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/match.log`，未仅复读闭环表格。

|项目|独立复核结果与边界|
|---|---|
|10000短连接|JSON记录10000/10000、77.8969s；脚本8线程，每次收完整response后才关闭，非“发完即关”负载。可信地支持该调用形态生命周期修复，不覆盖慢读/FIN/128上限。|
|连接与buffer稳定|5个after-stress均1/1，perf请求自身占一条；对象4521稳定，memory 241.9MiB。baseline 240.7MiB。before 2/1发生在dispatch中、survivors尚未assign，非稳态不一致证据。|
|计时|after-stress debug_process p50 0.02–0.05ms、p95 0.31–0.46、p99 0.44–1.01，均仅最近64帧。没有全压力窗口维护耗时分布，不能说“整段压力p99≤1.01ms”；尤其不能替代同负载可见性能A/B。|
|持续/半包/多行|脚本12次跨UTF8切包与300行收齐；tag未参与服务端结果，所以半包测试能证明完整JSON行被接受，但未校验回传中文内容。300个响应都只检查match，未使用唯一ID验证顺序/重复。|
|buffer上限|1MiB无newline得到显式request too large；未测合法接近上限完整JSON、上限边界newline及饱和输出。|
|截图|17队列背压+关闭后pending=0支持上限和死引用清理；headless不支持图像输出、请求之后的帧新鲜度或全序。无本任务PNG可供打开，本审查未冒称看过截图。|
|行为|真实Match开局2实体，固定scout→move受理、位移15.2439m；selected_units组注入后PlayerOverride。不是GUI玩家点选/框选，也不是runner决策质量。|
|第二局|夹具queue_free Match再实例化，match_id变化、2实体；不是大厅/网络房间退出重开链路。|
|清理|probe cleanup_ok仅process.poll非空，launcher53132而ready实际36800。单此布尔不证明子PID/登记均已消失；主线报告称另查CIM，本审查没有当前进程快照证据，因此不独立签署cleanup全绿。|
|错误门禁|match.log直接统计行首ERROR 118条、SCRIPT ERROR 9条，共127条；含ProductionTheme解析/依赖compile、overlay card_style、dummy texture/RID泄漏。不能把probe passed=true（其脚本未按日志forbidden失败）当干净真实Match通过。|
|相关回归|strict-forbidden-audit.json仅adjutant-connectivity为空，另4套含解析/加载或泄漏；运行器rc0/marker通过不满足严格门禁。未独立重跑/全量回归。|

客户端wall latency重新排序核算p50 60.3515 / p95 63.4048 / p99 558.1816ms，与主线一致；含排队/连接退避，不是服务端独占耗时。未使用physics_script_ms证明脚本热点。

## 同类TCP服务只读检查

- `G:/AIRTS/AI_RTS/addons/godot_mcp/native_mcp/mcp_http_server.gd`：249–295服务循环检查get_status却**没有任何poll调用**（全文件检索确认）；disconnect数组逐项_connections.erase，272复制连接集合，存在同类僵尸peer与批量二次回收结构风险。HTTP普通回应路径663–669会主动disconnect并下轮回收，因此不能断言所有短HTTP请求都同样泄漏；空连接/未完整HTTP/异常断开及SSE应重点验证。其put_data是同步发送，不过在独立线程，直接阻塞的是该服务线程，不等价于DCS主帧线程。未运行、未修改该插件，未实测对象增长。
- `G:/AIRTS/AI_RTS/source/ui/AdjutantModelService.gd`:145–159连接探测有poll和disconnect；`G:/AIRTS/AI_RTS/source/ui/AdjutantButton.gd`:1916–1972一问一答也有poll/限时等待/主动关闭，未见DCS同类无poll持有列表。
- AdjutantButton响应解析另有既有候选风险：raw.find(newline)可命中长度前缀中字节0x0A（或在正文未收齐时提前结束），并不是可靠完整frame条件；超过等待时长也返回不完整数据。该问题不归因于当前DCS生命周期补丁，但GUI消费方协议兼容不能靠Python精确读长度的probe替代。
- RandomMapRuntime和port_resolver的TCPServer用于端口保留/探测，不是持久accept/扫描服务，不列为同类泄漏实测。

## 本次命令与后续闸门

本次只读git/rg/文件审计、报告边界检查和独立Python模型均rc0。模型代码在工具调用内存执行，无新文件/缓存：按源码构造128 peer、1024帧、global256/peer16、survivors旋转+cursor1，得到公平总量但113帧最大服务空窗。它不替代引擎网络实测。

本次未运行Godot/编译/套件，未产生独立截图或独立运行时JSON；因此只签署**独立静态与证据审查已交付**，不签署产品闭环完成或champion晋级。建议协调无性能测量并发的拥有实例时段后补：慢读输出压力、128+idle占位、多peer公平尾延迟、完整请求+FIN/半关闭、多行唯一ID、混合截图响应关联与请求后绘制、受限模式权限正反、退出时活截图引用，以及清洁错误门禁与当前PID树清理。可见同场景性能、GUI接管和全量回归仍保持未验证。

## Round-02 追加独立审查（首轮发现保留，不冒称最终对象已冻结）

### 对象及验证边界

本次恢复审查仍只读产品/缓存、不启动Godot，只更新本报告。当前读取的 `G:/AIRTS/AI_RTS/source/net/DebugControlServer.gd` SHA256为 `32ce7607e0a4278fb72607b9fe53f94e7e9428e9d2ed99209a85a4f1bdeadfb4`，mtime 17:56:09。`G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-02/lifecycle/probe.json`记录同hash，passed=true、10000/10000、77.280592s、match_rc=0。**尚待唯一编辑者agent_d0c9cbb2明确报告final hash；同hash快照不替代最终对象确认。**

读取round-02/direction.md、autoload-parse.log、boundary/result.json和当前boundary探针源码；本地Python调度模型及JSON/hash核对rc0。autoload解析日志无DCS错误，不因_queue_reply源文件普通引号跨实际换行的风格单独指控解析失败。本次没有执行引擎验证或官方源码运行，只对当前API用法作静态核验。

### R2-01 / P1：全局背压下 idle 可杀内核待收合法请求（即时上报，待编辑者处理）

当前DCS:248要求 `_can_dispatch(id)` 才读取内核数据；319要求全局_output_bytes<16MiB。290–300判断空输出、无截图、应用buffer无完整行就执行idle检查，**并不要求get_available_bytes()==0**。

确定性控制流反例：其他多个慢读连接保持全局输出≥16MiB超过5秒；目标peer自己的应用buffer/output为空、无截图，其合法完整JSON已到达内核但因全局背压未读取。起始poll在available>0时不会把此正常peer关闭，随后available被门禁留为0，_last_activity仍是旧时间。末尾再poll仍CONNECTED，但idle_ms≥5000，于是_drop_peer，合法在途请求被关闭。无需依赖FIN或异常API才能形成反例。单慢读客户端的256KiB高水位测试无法到达全局16MiB，因此现有旁路通过不覆盖该分支。

同一问题也影响有不完整应用buffer且内核新片段因背压未读取的30s deadline。建议唯一编辑者保证idle/不完整过期只针对真正无可读进展的连接（至少排除内核可读字节），并明确暂停读取时间如何计算。这里不是允许直接放松预算或增加盲目重放。本审查未改源码、未运行反例；已立即向协调者报告具体路径和hash。

### Poll延迟：有限义务保留成立，但不得宣称所有peer都有5秒回收界

241–246只有内核仍有字节或应用义务为空时poll；有完整buffer、待发送输出、异步截图时避免零字节FIN被Godot poll消费，是针对该引擎FIN行为的有意识政策。发送使用put_partial_data，ERROR则_drop_peer；义务排空后的294–295恢复poll；_drop_peer同步删outputs/buffers/activity/close标志并扣_output_bytes。因此不是首轮“不再poll”的无条件僵尸累积路径，不把已验证FIN300再次标为未通过。

但不读且仍保持开放的peer可长期保留非空输出，并暂停读取/派发；其5秒idle被明确豁免。若应用输出为空、但有budget暂未派发的完整行，也不idle。最大128个peer及每peer输出高水位使数量/内存有限，却没有服务可用性保证：128个慢读有义务peer仍可永久占位。遇到关闭/RST，partial write通常能返回错误；零进展write且无内核可读时没有强制poll或写deadline，**错误被发现的有限时间没有静态保证**。已有slow_closed_recovery=1/1支持单个客户端该次关闭回收，不能推广全部慢读/丢包/零进展模式。

### 输出帧与高水位：API/字节顺序通过静态检查，回执上限需限定语义

- _queue_reply:326–340正文是(reply+newline) UTF8，encode_u32前缀为默认little-endian，frame按FIFO追加；_process:280–289以min(peer64KiB/global1MiB)切片调用put_partial_data，按返回实际bytes去除前缀段并扣总量。partial write在无空间时不等待完整发送，OK/0保持队列至下帧；不以请求数量误当写预算。这解决首轮R1的同步完整write阻塞路径，不能再声称本hash仍直接put_utf8_string主线程发送。
- _can_dispatch在while条件检查，未满足时不前移consumed；健康合法完整行继续保留。高水位是soft门槛：单次最多追加1MiB正文+4字节，peer理论<256KiB+1MiB+4，总量<16MiB+1MiB+4；不是严格262144/16777216硬缓存上限。截图flush也逐项检查门槛，pending总数16，未见绕过此检查无限追加。
- >1MiB响应在**执行命令后**替换为response too large。请求未吞/命令可能已执行，但原回执、command_id/accepted等消失，不能笼统说所有合法命令与其原回执语义完全不变。尤其重复提交非幂等动作存在风险。需证明实际合法最大回应都≤1MiB，或明确限制及可追踪错误语义；现有2实体status压力不证明大局回复上界。
- 字节队列采用slice重建剩余数组而非offset原地推进，预算限制网络传输而非copy/JSON/GPU成本；避免将partial write通过误报为整个_process耗时严格受字节预算限制。

### Idle政策与公平：首轮问题部分解决

空连接5秒、没有进展的不完整行30秒是新协议政策，不是透明生命周期实现。已接收完整行、排队输出、pending截图不受idle杀除，正常read/write进展更新_last_activity。该政策可使合法空闲持久连接在5秒后关闭，调用方须显式知道重连要求；不能写持久连接永久兼容。背压在途例外见R2-01。

新cursor按256/16=16推进，128个满负载peer的独立1024帧模型：各服务2048条、最大服务间隔8帧，解决首轮113帧突发空窗。在当前survivors重新排列的实现中该旋转正确；但稀疏请求/动态删除和全局输出背压下仍无尾延迟实测保证。

### 截图顺序与新鲜度

- 新item记录drawn和queued_ms；flush仅drawn>item.drawn才capture，比首轮全局_drawn_since_check严谨，静态上保证请求排队后出现新完成绘制帧，修复首轮新鲜度控制缺口。GPU实际成功截图和打开图仍未验证。
- 同连接普通回应仍可超越截图，源码明确preserve existing asynchronous ordering；这是**保留并声明旧语义，不是修复全序**。当前协议无统一request ID，混合消费者必须自行匹配或一问一答，不可宣称全序兼容。
- headless无新绘制帧5s后排队no rendered frame，_has_pending_shot避免提前消费FIN；但若全局高水位，flush先_can_dispatch false会推迟超时回应，不是严格5秒收到结果。
- _prune_pending_shots不poll，只用tracked buffer/status；它防止破坏FIN，代价是在刷新状态前不能识别所有已死client，可能为其做capture。参考单次headless超时+输出错误回收，不将首轮“poll后绝不为死peer读回”承诺延用至新版。

### 新证据支持及未覆盖

`round-02/boundary/result.json`记录FIN1=1/1、FIN300=300/300，随后clients/buffers1/1；slow请求发送320000字节，5次旁路perf均返回，slow关闭后回到1/1。这支持当前FIN排空及单慢读非阻塞方向。该结果JSON没有DCS hash，旧版本边界脚本也缺少唯一响应ID/输出字节高水位读数，不独立签署其对象严格绑定或全局16MiB分支。

当前 `G:/AIRTS/AI_RTS/tools/dev/debug_tcp_boundary_probe.py`已另指向boundary-verified，增加idle129计时与mixed screenshot/status+FIN headless超时检查；不把当前脚本的新断言追溯到之前boundary/result.json中。round02 lifecycle的万次JSON与当前hash一致，仍不是本审查自行运行的独立探针。

结论保持needs-review：R1同步发送及首轮公平/截图drawn标记有明确改善；FIN300新证据认可；R2-01在途请求idle反例待唯一编辑者修正或提供排除此分支的充分依据。最终hash未确认，不能签署冻结版本通过。原有关错误门禁、可见截图/同场景性能、GUI接管和全量回归未验证项不自动因网络边界变绿而消失。

## Round-03 最终冻结对象复核与签署

### 最终身份确认

唯一编辑者最终声明、当前DCS两次独立SHA256读取、round-03/identity.json、global-03/result.json与lifecycle/probe.json均为：

`65795566d1ebf1e309ed02f7fddc45c743d54508738693cb826ceb8da9b60b47`

对象是 `G:/AIRTS/AI_RTS/source/net/DebugControlServer.gd`。本轮只读复核，没有启动Godot、没有编辑产品/cache；仅追加本报告。round-02“final hash未确认”已被本节取代。

### 核心判据复核

**R2-01关闭，局部静态通过。** 当前296–305在末尾poll后再次读取kernel available：健康且unread>0则更新_last_activity；idle/incomplete只有健康、unread==0且deadline到期才关闭。完整应用行、输出和pending截图仍排除在该idle分支外。全局高水位故意暂停读取但kernel已有请求时，既不会被5秒空闲杀除，也不会恢复后沿用旧30秒不完整计时误杀。没有删掉排空后的poll来掩盖回收：FIN300/排队输出完成后仍可刷新状态并_drop_peer同步清理。此处正面修复了独立报告提出的具体反例，而不是只让测试判据变绿。

**输出预算/帧格式静态通过。** 每peer64KiB、全局1MiB每帧的put_partial_data推进保持；仅按实际成功bytes扣队列及global budget；OK/0保留待发数据，错误走_drop_peer。回应FIFO拼成u32 LE长度+UTF8正文/newline，再分字节传输，partial write拆帧不改变wire framing。高水位停读/停dispatch时consumed不前移，未见因该预算静默吞完整合法行。16MiB/256KiB仍是soft高水位，允许一条≤1MiB回应的有限越界，不应改写为严格硬字节上限。

>1MiB回应错误现在明确execution_status=unknown、retryable=false并提示已dispatch不可仅因超限重放，关闭了“错误看似拒绝诱导重试”的文案/协议歧义；仍不恢复原command_id或完整回执，也未证明大型局所有合法回应≤1MiB。因此签署的是有限回应政策及非盲重放提示，不是所有大回应原样兼容保证。

截图设计未被本轮扩大承诺：每请求drawn更新条件保留；普通回应可超越截图仍是显式异步语义，无统一request_id全序；无headless绘制帧时显式超时回执，但被全局高水位暂停时非严格5秒送达。GPU成功capture及实际打开图仍未签署。

### 原始最终证据交叉核验

已独立解析而非只转述verification.md：

- `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/global-03/result.json`：同最终hash，saturation_hold_s=7.125，drained_responses=240000，额外response.match=true，after clients/buffers/output_bytes均0，passed=true、rc0。报告记录自然应用输出16,779,384bytes及额外FIN请求在kernel待收超过5秒，符合修复分支；这是主线提供的运行证据审计，不冒称本审查自行启动的独立探针。
- `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/lifecycle/probe.json`：同最终hash，10000/10000、78.212372s、passed=true、match_rc0；半包/持续300、1MiB输入、shot背压、15.2439m位移、PlayerOverride组级、不同match_id第二局记录存在。
- `G:/AIRTS/AI_RTS/agent/runs/2026-10-11-debug-tcp-lifecycle/round-03/boundary-02/result.json`：容量观察确有128 clients，129th4.968s恢复；FIN300/300；mixed截图/status+FIN先普通状态、后带指定path的no rendered frame；慢读旁路与恢复通过，passed=true、rc0。
- `round-03/verification.md`仍明确成功日志含136/130/58 ERROR、SCRIPT ERROR0，并未宣称干净门禁；本次不将网络目标通过提升为全项目无错误或全量回归通过。

### 最终签署结论

**签署通过：最终hash对象一致；独立静态生命周期/partial-write输出预算与帧格式审查；round-02 kernel待收请求idle误杀反例已关闭；提供的FIN/全局饱和排空/万次证据与修复方向相符。当前未发现要求再次修改该冻结DCS的新增明确硬失败。**

**整体状态仍needs-review，不晋级全项目champion。** 本审查是独立静态与原始证据复核，不是独立运行时复现；全量/严格相关错误门禁、可见同场景持续性能、成功GPU截图实际打开、GUI玩家接管、runner决策与大厅/网络级退局仍缺。128个长期有义务的慢读peer可占满容量、回应上限改变大回执语义、截图异步超越等已知政策边界继续保留，不因本轮成功而抹除。停止继续产品微调与最终对象冻结符合当前授权。
