# -*- coding: utf-8 -*-
"""四列接口的**唯一提示词实现**：系统提示 + 紧凑输入表 + 输出归一化。

依据（设计 §2.1/§3.3）：
- 系统提示是**常量**（同一模型、同一 4096 上下文），便于前缀缓存，也保证 fast/deep
  只通过"信息范围与决策范围"区分，而不是换提示词换模型；
- 输入表由程序从 `DecisionFrame` 确定性渲染，**只含玩家可见事实**；
- 本模块被生产链路（`pydantic_agents.PydanticAITaskPatchAgent`）与 A/B 工具共用，
  避免"评测用提示词"与"生产用提示词"漂移（那会让验收数字失去意义）。

实测依据（2026-09-12，120 条真实观测）：
- 用 JSON 对象数组表达同一份信息要 1985 token；紧凑文本表只要 918/953 token；
- 2B 会回 ```json 围栏 → 必须提示词禁止 + 解析容错；
- 2B 做不了"设施→合法产品"的两步配对 → 程序把配对预写在表里（见 render_compact_text）；
- 行数上限必须 ≤ 执行者数，否则模型会凑行数重复同一执行者。
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

NEW_SYSTEM_PROMPT = (
    "你是 RTS 游戏里的 AI 副官，负责给执行者派任务。只输出 JSON，形如 "
    '{"u":[["S1","ATK","E3","P1"],["F1","PROD","U1","Q4"]]}。'
    "u 的每一行是 [执行者, 任务, 目标, 参数]，四项必须取自主提示的表："
    "执行者取「执行者」表的 ref；任务取下表；目标按该任务的括号类别取对应表的 ref"
    "（不需要目标写 -）；参数取下表。\n"
    "任务: ATK打敌(E) AMOV推进(L/B) DEF守点(L/B) RET撤离(L/B) SCT侦察(L) GRP集结(L/B) "
    "GAT采集(R) BLD建造(V) PROD生产(U) MOVE移动(L/B) HOLD待命(-) STOP停止(-)\n"
    "参数: P0维持现状 P1直线纵队 P2正面横队快速 P3侧翼疏散 P4经集结点谨慎 P5快速展开 P6固守待命；"
    "生产数量用 Q1~Q8。\n"
    "执行者能力: 作战小队(squad)只做 ATK/AMOV/DEF/RET/SCT/GRP/MOVE/HOLD/STOP；"
    "工人组(worker)只做 GAT/BLD/MOVE/RET/STOP；生产设施(facility)只做 PROD/STOP。\n"
    "每个执行者本轮最多出现一行，重复出现会被拒绝；空闲的执行者都应该派上活。"
    "已经在执行的任务不要重复输出（看「当前任务」那行）：行为树会自己把已批准的任务"
    "循环执行下去，不要重下。\n"
    "「主线」那行是本局的大目标（阶段 / 下一前沿 / 已完成 / 阻塞）与四条线的状态；"
    "「可选路线」是程序按当前局势筛出的可选分支。要改主线分支就在 g 里写路线 ref"
    '（例如 {"g":"D3","u":[]}）；不改分支就把 g 留空或写 ""。'
    "路线的前置条件由程序判定：不满足的选择会被忽略，主线照常推进，所以不要为了凑分支"
    "而输出非法 ref。\n"
    "【发展候选】是程序按当前局势筛出的可做发展动作（含「维持现有任务」）。"
    "要做发展就从里面**整条照抄**成一行，例如候选写了 W1造V1(aircraft_factory)，"
    "就输出 [\"W1\",\"BLD\",\"V1\",\"P0\"]（落点与数量已由程序算好，不要自己改坐标）；"
    "没有合适候选就选「维持现有任务」，不要硬凑。\n"
    "其余按下面来：有工人组且不忙 → GAT（目标取 R）；有可见敌人时，敌人数量多于我方作战单位"
    "就给作战小队 RET（目标取 L 里靠我方基地的点）或 DEF，不要硬打，否则 ATK 最近的敌人"
    "（目标取 E）；没有敌人的作战小队去 SCT 或 MOVE 到 L 的点位。"
    "实在没有可做的才输出 {\"u\":[]}。"
    "只输出一行 JSON 本身：不要 markdown 代码块、不要三个反引号、不要解释、不要复述输入、"
    "不要编造表外的标识或坐标。"
)

NEW_USER_TEMPLATE = (
    "战场事实（只含玩家可见信息）：\n%s\n"
    "本轮最多 %d 行，每个执行者最多一行。已被玩家接管的单位不在执行者表里。"
)

#: 生产候选里给的数量提示。计划 §三要求"**不占满生产队列**"（玩家订单优先，留空位），
#: 手册给的上限是"同一生产建筑在途 AI 队列项 ≤2"；因此这里给 Q2，而不是 Q8。
#: 队列容量信息接入观测后由程序按剩余空位计算（当前 frame 还没有队列字段，先固定 Q2）。
PRODUCE_QTY_HINT = "Q2"
#: 何时开始给"扩建"候选（余额 ≥ 该值且关键建筑已齐）。
EXPANSION_MIN_BUDGET = 1000
#: 关键建筑（按手册 BLD-01 阶梯顺序补齐）。
KEY_BUILDINGS = ("barracks", "vehicle_factory", "aircraft_factory")


def normalize_json_text(text: str) -> str:
    """剥掉常见的模型包装（``` 代码块、"json" 前缀），取出最外层 JSON 对象。

    实测依据：换成紧凑文本输入后，2B 会回 ```json ... ``` 围栏 —— 内容完全正确，
    但直接 `json.loads` 会判非法。生产路径同样需要这层归一化，否则"结构合法率"会把
    可用的输出算成失败（计划 §7.A 要求把首次结构合法率测准，不能靠重试掩盖）。
    """
    cleaned = (text or "").strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[1] if "\n" in cleaned else cleaned
        if cleaned.rstrip().endswith("```"):
            cleaned = cleaned.rstrip()[:-3]
    cleaned = cleaned.strip()
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start >= 0 and end > start:
        return cleaned[start:end + 1]
    return cleaned


def _campaign_text(campaign: Optional[Dict[str, Any]]) -> str:
    """把整局主线上下文渲染成**一到三行**紧凑文本（纠偏 §7 的硬要求逐项落位）。

    包含：当前阶段、主线目标、已完成/阻塞里程碑、四条线任务、下一前沿、
    可选决策地图节点及其前置条件。**不渲染 Markdown 原文**（那是被纠偏明确禁止的）。
    """
    if not isinstance(campaign, dict) or not campaign:
        return ""
    phase = str(campaign.get("phase", "") or "")
    frontier = str(campaign.get("frontier", "") or "")
    frontier_name = str(campaign.get("frontier_name", "") or "")
    expects = str(campaign.get("frontier_expects", "") or "")
    done = [str(x) for x in (campaign.get("done_names") or []) if str(x)]
    blocked = campaign.get("blocked") or []
    parts = ["主线: 阶段=%s 前沿=%s%s" % (phase or "?", frontier or "?", frontier_name)]
    if done:
        parts.append("已完成=" + ",".join(done[:4]))
    if blocked:
        parts.append("阻塞=" + ",".join(
            "%s(%s)" % (str(item.get("name", "")), str(item.get("reason", ""))[:12])
            for item in blocked[:2]))
    if expects:
        parts.append("完成判据=" + expects[:24])
    tracks = campaign.get("tracks") or {}
    if tracks:
        parts.append("四线=" + " ".join(
            "%s:%s" % (name, str((tracks.get(name) or {}).get("task") or "维持"))
            for name in ("economy", "build", "scout", "military")))
    lines = [" ".join(parts)]
    decision_lines = [str(x) for x in (campaign.get("decision_lines") or []) if str(x)]
    lines.extend(decision_lines[:2])
    suspended = [str(x) for x in (campaign.get("suspended") or []) if str(x)]
    if suspended:
        lines.append("玩家已接管（不要派活）: " + ",".join(suspended[:6]))
    return "\n".join(lines)


def render_compact_text(frame, *, balance: Optional[Dict[str, Any]] = None,
                        deep: bool = False) -> str:
    """把 `DecisionFrame` 渲染成**超紧凑文本表**（四列接口的正式输入）。

    为什么不用 JSON 对象数组（实测依据）：
    - 同一份信息用 JSON 对象表示要 1985 token（超过 fast 模式 1024 输入预算），
      主因是键名重复、每个目标一个对象、参数档 15 条；
    - 换成"一行一类"的紧凑文本（ref 本身已带类别语义）后，同一信息约 1/3 字符，
      且保留了模型真正需要的事实：谁能干什么、去哪、打谁、造什么。

    `deep=True` 才补充血量、更多敌人/资源/点位（设计 §3.3：深度模式通过**信息范围**与
    决策范围区分，而不是让同一个模型"想更久"）。
    """
    max_resources = 8 if deep else 4
    max_enemies = 8 if deep else 4
    max_locations = 8 if deep else 6
    # 余额优先用 frame 自带的那份：生产链路（runner）不额外传 balance，
    # 从前因此**整行余额都没渲染给模型** → 模型不知道钱够，钱再多也不发展
    # （实测 2026-09-12 用户反馈：余额 49750 却不建 aircraft_factory/不补兵）。
    if not balance:
        balance = dict(getattr(frame, "balance", {}) or {})
    lines: List[str] = []
    actors = []
    facilities = []
    builders = []
    for actor in frame.actors.values():
        text = "%s(%s·%d)" % (actor["ref"], "/".join(actor["types"]), actor["count"])
        if deep and int(actor.get("hp_pct", -1)) >= 0:
            text += "hp%d" % int(actor["hp_pct"])
        actors.append(text)
        if actor.get("products"):
            facilities.append(str(actor["ref"]))
        if actor.get("buildings"):
            builders.append(str(actor["ref"]))
    lines.append("执行者: " + " ".join(actors))

    # 距离以「我方部队质心」为参考（不是世界原点）：模型关心的是"离我近不近"。
    points = [actor["pos"] for actor in frame.actors.values()
              if actor["kind"] in ("squad", "worker") and actor.get("pos")]
    origin_x = sum(float(p[0]) for p in points) / len(points) if points else 0.0
    origin_z = sum(float(p[1]) for p in points) / len(points) if points else 0.0

    def _distance(target: Dict[str, Any]) -> float:
        pos = target.get("pos") or [0.0, 0.0]
        return (float(pos[0]) - origin_x) ** 2 + (float(pos[1]) - origin_z) ** 2

    groups: Dict[str, List[str]] = {}
    product_refs: Dict[str, str] = {}
    building_refs: List[str] = []
    for target in sorted(frame.targets.values(), key=_distance):
        kind = str(target["kind"])
        if kind == "product":
            if target.get("category") == "building":
                building_refs.append("%s=%s" % (target["ref"], target.get("scene", "")))
            else:
                product_refs[str(target.get("scene", ""))] = str(target["ref"])
            continue
        if kind == "location" and str(target.get("cn", "")).startswith("建造落点"):
            continue    # 建造落点由程序自选（BLD 的目标是 V），不给模型添噪声
        cap = {"resource": max_resources, "enemy": max_enemies,
               "location": max_locations}.get(kind)
        items = groups.setdefault(kind, [])
        if cap is None or len(items) < cap:
            items.append(str(target["ref"]))
    # 【关键·实测修正】把"设施 → 它能造的产品"**预先配对写在表里**。
    # 实测（120 条真实观测，fast）：全局产品表 + 每设施能力，要求 2B 做两步配对，
    # 结果 139 次 capability_mismatch（语义合法率被压到 54%）。程序既然已经知道
    # 合法组合，就应该直接给出"F1 只能产 U4"这种单步事实（2B 的单步比较才可靠）。
    if facilities:
        pairs = []
        for ref in sorted(facilities):
            actor = frame.actors.get(ref) or {}
            items = []
            for product in actor.get("products", []) or []:
                cost = int((frame.targets.get(product_refs.get(str(product), "")) or {})
                           .get("cost", 0) or 0)
                items.append("%s(%s,%d)" % (product_refs.get(str(product), str(product)),
                                            product, cost))
            pairs.append("%s只能造%s" % (ref, "/".join(items) if items else "无"))
        lines.append("生产设施: " + " ".join(pairs))
    if groups.get("enemy"):
        if deep:
            lines.append("敌人: " + ",".join(
                "%s(hp%d)" % (ref, int((frame.targets.get(ref) or {}).get("hp_pct", -1)))
                for ref in groups["enemy"]))
        else:
            lines.append("敌人: " + ",".join(groups["enemy"]))
    if groups.get("resource"):
        lines.append("资源点: " + ",".join(groups["resource"]))
    if groups.get("anchor"):
        lines.append("我方基点: " + ",".join(groups["anchor"]))
    if groups.get("location"):
        # 点位按编号给出语义标签（基地/前压/侦察），编号本身就是稳定语义。
        ordered = sorted(groups["location"], key=lambda r: int(r[1:]))
        lines.append("点位: " + ",".join(
            "%s=%s" % (ref, str((frame.targets.get(ref) or {}).get("cn", ""))[:6])
            for ref in ordered))
    have = sorted({t for actor in frame.actors.values()
                   if actor["kind"] == "facility" for t in actor["types"]})
    missing = [scene for scene in ("barracks", "vehicle_factory", "aircraft_factory")
               if scene not in have]
    # 可建造物的完整枚举不再直接给模型：只给「发展候选」这条菜单（计划要求候选，
    # 不是全量清单）；候选里已带 V 编号，模型照抄即可。
    # 【关键·实测修正】建造也必须**预配对**：实测 2B 会输出 ["F1","BLD","V4"]（让车厂去建造）
    # —— 8/8 条全部被拒。程序既然知道"谁能造哪个"，就直接给出「工人N造V4(barracks)」这种
    # 单步组合；模型只需在候选里挑一个，不用自己把执行者与建筑配起来。
    scene_to_ref = {entry.split("=", 1)[1]: entry.split("=", 1)[0]
                    for entry in building_refs}
    scene_cost = {str(t.get("scene", "")): int(t.get("cost", 0) or 0)
                  for t in frame.targets.values()
                  if str(t.get("kind")) == "product"
                  and str(t.get("category")) == "building"}
    budget = sum(int(v or 0) for v in (balance or {}).values())
    # 【计划 §二第 1 条 / §七§3 第 4 条：候选菜单】**程序筛出当前该做的发展动作**，
    # 只给 2~3 条 + 「维持现有任务」，由模型选——不用长段自然语言训导
    # （计划/手册都实测过：多步政策式提示会让 2B 在采集与发展之间摇摆）。
    # 候选顺序按手册 BLD-01 阶梯：缺关键建筑 → 空闲设施生产 → 扩建竞争项。
    candidates: List[str] = []
    if missing and builders:
        for scene in sorted(missing, key=lambda s: scene_cost.get(s, 0)):
            ref = scene_to_ref.get(scene)
            if ref and scene_cost.get(scene, 0) <= budget:
                candidates.append("%s造%s(%s)" % (sorted(builders)[0], ref, scene))
    for ref in sorted(facilities):
        actor = frame.actors.get(ref) or {}
        current = (frame.current_tasks or {}).get(ref) or {}
        if str(current.get("skill", "")):
            continue        # 已在生产：行为树会继续，不重复派（避免重置任务）
        for product in actor.get("products", []) or []:
            ref_product = product_refs.get(str(product), str(product))
            cost = int((frame.targets.get(ref_product) or {}).get("cost", 0) or 0)
            if cost <= budget:
                candidates.append("%s产%s(%s) %s" % (ref, ref_product, product,
                                                     PRODUCE_QTY_HINT))
    expansion = [scene for scene in ("anti_air_turret", "anti_ground_turret",
                                     "command_center")
                 if scene not in missing and scene_to_ref.get(scene)
                 and scene_cost.get(scene, 0) <= budget]
    if budget >= EXPANSION_MIN_BUDGET and expansion and builders:
        scene = min(expansion, key=lambda s: scene_cost.get(s, 0))
        candidates.append("%s造%s(%s)" % (sorted(builders)[0], scene_to_ref[scene], scene))
    # 发展候选 = 上面程序筛好的菜单（缺关键建筑 → 空闲设施生产 → 扩建竞争项）。
    # 只给 3 条 + 「维持现有任务」：模型整条照抄，或明确选择维持（不强迫每轮下命令）。
    #
    # 【置顶】(2026-09-12 结果层修正)：实测 2B 只盯输入表最前面的行，把"发展"放在
    # 中后段时它整局只回采集。菜单插到「执行者」之后的第 2 行，让它成为最显眼的可选项。
    menu = candidates[:3] + ["维持现有任务"]
    # 【整局主线】放在最前面（仅次于执行者表）：2B 只盯最前面的行，而"当前阶段 /
    # 下一前沿 / 已完成里程碑 / 四条线"是它做分支选择与参数选择**唯一**的依据。
    # 内容全部来自 `campaign.context_view()`（`frame.campaign`），本函数只排版。
    campaign_line = _campaign_text(getattr(frame, "campaign", None))
    if campaign_line:
        lines.insert(1, campaign_line)
    lines.insert(2 if campaign_line else 1,
                 "本轮发展骨架（优先照抄一行，或选维持）: " + " | ".join(menu))
    if builders:
        lines.append("能建造的执行者: " + ",".join(sorted(builders)))
    lines.append("已有建筑: " + (",".join(have) if have else "无"))
    combat = sum(actor["count"] for actor in frame.actors.values()
                 if actor["kind"] == "squad")
    # 当前任务（权威任务表）：明确告诉模型"这些已经在执行，别重复派"。
    # 实测依据（2026-09-12 用户反馈）：没有这一行时，模型每轮都重发同一行
    # （"工人采集"被反复下令）——行为树本来就会自己循环，重复命令纯属噪声。
    active_tasks = []
    for actor in frame.actors.values():
        task = actor.get("current_task") or {}
        skill = str(task.get("skill", "") or "")
        if not skill:
            continue
        ref = str(task.get("target_ref", "") or "-")
        active_tasks.append("%s=%s%s" % (actor["ref"], skill, ref))
    if active_tasks:
        lines.append("当前任务（已在执行，不要重复输出）: " + " ".join(active_tasks))
    lines.append("我方作战单位=%d 可见敌人=%d" % (combat, len(groups.get("enemy") or [])))
    if balance:
        lines.append("余额: " + " ".join("%s=%s" % (k, v) for k, v in balance.items()))
    if frame.phase_goal:
        lines.append("阶段目标: " + str(frame.phase_goal))
    return "\n".join(lines)


def build_user_prompt(frame, *, balance: Optional[Dict[str, Any]] = None,
                      max_rows: int) -> str:
    """系统提示之外的 user 部分（紧凑表 + 本轮行数上限）。"""
    from .task_patch import MODE_DEEP, effective_max_rows
    deep = str(getattr(frame, "mode", "")) == MODE_DEEP
    rows = int(max_rows) if max_rows else effective_max_rows(frame)
    return NEW_USER_TEMPLATE % (
        render_compact_text(frame, balance=balance, deep=deep), rows)
