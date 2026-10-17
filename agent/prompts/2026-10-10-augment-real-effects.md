# 战区补给后续维护提示词

先读仓库契约和 `agent/plans/2026-10-10-augment-real-effects.md`。需求是让已选战区补给进入真实玩法结算，不是改卡面或额外调平衡。

权威数值来自 `config/match_augments.json`。局内加成与永久成长由 `AugmentModifiers` 合成一次。伤害必须进入 `ProjectileRuntime` 的开火快照，交货必须进入 EconomyRuntime 账户，最大生命必须覆盖现有/新生单位且保持原血量比例，视野必须影响实际可见性。

联机只在服务器选牌结算，客户端只发送卡 ID 和轮次、接收自己的权威状态。校验真实 peer 槽位、当前 offer 与轮次，拒绝重复/非法选择；不能信客户端倍率或转账金额。客户端不能重复发钱或自行叠倍率。快照倒计时使用剩余时长转换，不直接比较两进程单调时钟。血条使用权威 hp_max 后再应用 hp。

逐张实测，不只随机一张，不只检查显示数字。保留成长叠乘、旧选牌/超时、移动/生产与退局清理回归。测试不弹辅助控制台、不抢前台或真实鼠标。未通过的范围如实记入报告，禁止假称全绿。

2026-10-11 接手先读 `agent/reports/closed-loop/2026-10-11-augment-real-effects.md`。补给专项已通过，不要凭旧截图重写或重复乘倍率。客户端配置基线必须在权威 hp_max 快照之前捕获；补发必须等待实际收到 NetSync 权威快照，不能等待仅服务器置真的 `_live`；客户端 owned 卡同步不修改服务器权威当前 HP。pick 和 recommendation RPC 都须拒绝过期请求，即使 offer 尚未被 timeout 清空。

回归入口 `tools/run_augment_verification.py`，每轮新输出目录。effects 覆盖12卡、真实弹体、采矿返程及到账、视野、成长合成、出生幂等；network 使用两进程真ENet并保留未清空的过期offer测试。`--rendered` 在独立Windows desktop渲染，不切换用户桌面。无头6次已知Dummy纹理ERROR不得写成全日志洁净；返回码、完成marker和forbidden/error门禁分开判断。

当前整体 needs-review：20项相关回归仅14marker通过/6日志干净，经济、血条、弹体、采矿等红项尚未逐项A/B归因。先归因这些红项，不能直接断言全是历史问题或全由补给引起；不要顺便改卡牌平衡、重置脏工作区或覆盖评审成品。未录连续视频、未跑完整全量回归、未验公网和完整UI试玩，禁止拿专项绿灯充当发布绿灯。
