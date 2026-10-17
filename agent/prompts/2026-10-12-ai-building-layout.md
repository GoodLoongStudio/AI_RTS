# 复验 AI 建筑布局、远程施工与分基地

在 G:/AIRTS/AI_RTS 读取 AGENTS.md、工作区边界、闭环/RSI/performance/temporal 规则并核验路径。保护已有 dirty 文件、用户进程和打包版。

复验电脑玩家 EconomyController 与副官 DCS 自动 build 是否走同一 StructurePlacementRuntime：连续建矿场、车厂、兵营、机场，量建筑边缘间距、矿区服务和采矿通道、生产出生/集结通行；不能只看 accepted。开放地图应优选疏散位置，狭窄无安全位置宁可等待；保持玩家手动放置权威规则。

实测 ≤20m/35m/≥50m 同建筑自动施工工作量：距离不含本工地、未完工或敌方基地，小数不能被 int 四舍五入吃掉。检查正常建造、取消退款、分基地完工后附近施工及多基地速度加成。

电脑扩张应找最近可用新矿，不能把 20m 下限当 best upper bound，不得失败后在主基地旁伪扩张；副官须使用观测资源，按真实 footprint 采样矿旁多个方位，并给分基地周围经济/生产建筑锚点。施工中计数去重、开局经济优先、地图边界/地形/余额仍以游戏权威为准。

按 agent/plans/2026-10-12-ai-building-layout.md 和 tests/automated/AiBuildingLayoutSmokeTest.tscn 复验，每个关键补丁另起真实 Match。5fps 非干扰 GPU 录像并实际打开相关帧；相关套件/独立探针复核/全量红归因后写闭环报告，不改判据凑绿。
