# -*- coding: utf-8 -*-
"""微操行为树（方案定调：**微操归行为树，LLM 只出意图**）。

## 为什么需要它

2026-09-11 实机验证暴露的真问题：副官"只会采集 + 造兵 + 造工人"。
根因有两层，之前只修了浅层：

1. 模型层 `num_ctx=8192` 超窗截断（**已修**：换 16K 模型后战略/战术契约全绿）；
2. **微操层根本不存在** —— 全仓库搜 `行为树/BehaviorTree` 命中 0，
   真正的"兜底"只是 `rules_fallback` 的浅规则阶梯，只会三条硬编码。

模型修好后仍有硬约束：本机 2B 模型单次决策 **14~16s**（实测）。
这决定了架构分工，也是本模块存在的理由：

```
战略层  LLM（慢、异步、10~45s）   → 出"目标/优先级"
战术层  LLM/规则（慢、异步）      → 把目标分派到单位
微操层  ★行为树（每 tick、快）★  → 单位级即时执行、打断、避战
```

LLM 16s 更新一次意图完全可以接受 —— **前提是这中间单位由行为树顶着**。
所以微操不能等模型，必须是确定性的、每 tick 都能跑的树。

## 与业界做法一致

RTS 主流是**分层 + 混合**：战略用 HTN/Utility，单位级用行为树（腾讯 behaviac 是最成熟的
开源行为树框架；RTS 方向常见"层次化行为树"，其要点正是本模块的结构 ——
军事决策分层、数据导向、条件前置）。本模块取行为树，因为它对"优先级抢占/打断"最直观，
正好匹配"避战 vs 交战 vs 采集"这种互斥选择。

## 设计要点

- **纯 stdlib、无外部依赖**：方便单测，也不拖慢 runner。
- **每单位一棵树实例**：微操是"单位视角"的，不能全局共享状态。
- **黑板（Blackboard）**：LLM 意图作为黑板输入，树只读它 + 观测事实。
- **优先级即树形顺序**：Selector 从左到右，第一个 SUCCESS 即定论。
  顺序即纪律：**让权 > 求生 > 执行任务 > 本职 > 不空转**。
- **安全边界不靠提示词**：玩家接管的单位在**第二层条件**就被拦掉（第一层直接让权）。

## 输出契约

与 `rules_fallback._intent` 完全一致（普通 dict），因此可直接与既有意图流汇合：
`intent_id / task_id / unit_ids / action / target / priority /
based_on_snapshot / issued_tick / expires_tick / generation / rationale`
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# 行为树内核
# ---------------------------------------------------------------------------


class Status:
    """节点 tick 结果（用字符串是为了日志/回执可读）。"""

    SUCCESS = "success"
    FAILURE = "failure"
    RUNNING = "running"


class Node:
    """行为树节点基类。"""

    def __init__(self, name: str = "") -> None:
        self.name = name or self.__class__.__name__

    def tick(self, bb: "Blackboard") -> str:  # pragma: no cover - 抽象
        raise NotImplementedError

    def children(self) -> Sequence["Node"]:
        return ()


class Condition(Node):
    """条件节点：谓词为真 → SUCCESS，否则 FAILURE（不写黑板）。"""

    def __init__(self, predicate: Callable[["Blackboard"], bool], name: str = "") -> None:
        super().__init__(name or getattr(predicate, "__name__", "condition"))
        self._predicate = predicate

    def tick(self, bb: "Blackboard") -> str:
        try:
            return Status.SUCCESS if self._predicate(bb) else Status.FAILURE
        except Exception:  # noqa: BLE001
            # 微操层任何异常都视为"条件不成立"：宁可少下发，不可误下发。
            return Status.FAILURE


class Action(Node):
    """动作节点：执行副作用，返回 SUCCESS/FAILURE/RUNNING。

    异常一律吞成 FAILURE —— 行为树绝不能把异常抛回指挥链。
    """

    def __init__(self, fn: Callable[["Blackboard"], str], name: str = "") -> None:
        super().__init__(name or getattr(fn, "__name__", "action"))
        self._fn = fn

    def tick(self, bb: "Blackboard") -> str:
        try:
            return self._fn(bb) or Status.SUCCESS
        except Exception:  # noqa: BLE001
            return Status.FAILURE


class Sequence(Node):
    """顺序节点（AND）：全部 SUCCESS 才 SUCCESS；遇 FAILURE 立刻失败。

    RUNNING 立即向上传递（本模块的动作要么立即成功要么失败，RUNNING 预留）。
    """

    def __init__(self, *children: Node, name: str = "") -> None:
        super().__init__(name)
        self._children = list(children)

    def children(self) -> Sequence[Node]:
        return tuple(self._children)

    def tick(self, bb: "Blackboard") -> str:
        for child in self._children:
            status = child.tick(bb)
            if status != Status.SUCCESS:
                return status
        return Status.SUCCESS


class Selector(Node):
    """选择节点（OR）：**从左到右**，第一个非 FAILURE 即为结果。

    顺序即优先级 —— 这是本树表达"纪律"的主要手段。
    """

    def __init__(self, *children: Node, name: str = "") -> None:
        super().__init__(name)
        self._children = list(children)

    def children(self) -> Sequence[Node]:
        return tuple(self._children)

    def tick(self, bb: "Blackboard") -> str:
        for child in self._children:
            status = child.tick(bb)
            if status != Status.FAILURE:
                return status
        return Status.FAILURE


class AlwaysSucceed(Node):
    """包一层"无论如何都算成功"（用于止损分支，避免继续尝试低优先分支）。"""

    def __init__(self, child: Node, name: str = "") -> None:
        super().__init__(name)
        self._child = child

    def children(self) -> Sequence[Node]:
        return (self._child,)

    def tick(self, bb: "Blackboard") -> str:
        self._child.tick(bb)
        return Status.SUCCESS


# ---------------------------------------------------------------------------
# 黑板
# ---------------------------------------------------------------------------


class Blackboard:
    """单位视角的只读事实 + 唯一出口 `emit()`。

    刻意做成"读多写一"：所有叶子只能通过 `emit()` 产生一条意图，
    这样"一个单位同一批只出现一次"就成为**结构性保证**，而不是提示词纪律
    （实测提示词约束 2B 模型并不可靠，会同一单位既 attack 又 move）。
    """

    def __init__(self, facts: Dict[str, Any]) -> None:
        self.facts = facts
        self.unit: str = str(facts.get("unit") or "")
        self.intent: Optional[Dict[str, Any]] = None
        #: 记录叶子决策路径，便于诊断"为什么它这么干"（方案要求把理由回传 UI）。
        self.trace: List[str] = []

    # -- 便捷读取 ---------------------------------------------------------
    @property
    def unit_info(self) -> Dict[str, Any]:
        return (self.facts.get("unit_info") or {})

    def get(self, key: str, default: Any = None) -> Any:
        return self.facts.get(key, default)

    # -- 唯一出口 ---------------------------------------------------------
    def emit(self, action: str, target: Any = None, *, priority: int = 50,
             rationale: str = "", suffix: str = "", id_tick: Optional[int] = None) -> str:
        """下发该单位本批的唯一一条意图。

        重复 emit 会**覆盖**前一条（而不是追加）：保证契约上"一个单位一条"，
        同时让"更靠前的分支"天然获胜（因为 Selector 不会走到后面的分支）。

        `id_tick`：**可选的稳定 id 时间戳**，给"同一条意图要跨多个 tick 保持同一 id"的
        场景用（目前只有侦察航点）。它**必须随状态变化而改变**，否则就退化成"固定 id"
        —— 游戏按 intent_id 做幂等缓存，固定 id 会让重试永远命中最早那次回执。
        侦察传的是**航点槽位**：同一航点内重复上报命中幂等回执、不会每 tick 重置移动路径
        （否则单位会在原地抖、永远走不到航点），换槽位 = 换航点 = 新 id。
        """
        if not self.unit:
            return Status.FAILURE
        tick = int(self.facts.get("server_tick") or 0)
        expires = tick + max(1, int(self.facts.get("ttl_ticks") or 3600))
        # intent_id 必须带 tick：游戏按 intent_id 做幂等缓存，
        # 固定 id 会让重试永远命中最早那次回执（实测真凶）。
        intent_id = "bt-%s-%s%s-%d" % (
            action, self.unit, suffix, tick if id_tick is None else int(id_tick))
        self.intent = {
            "intent_id": intent_id,
            "task_id": str(self.facts.get("task_id") or ""),
            "unit_ids": [self.unit],
            "action": action,
            "target": target,
            "priority": int(priority),
            "based_on_snapshot": int(self.facts.get("snapshot_id") or 0),
            "issued_tick": tick,
            "expires_tick": expires,
            "generation": 0,
            "rationale": rationale or action,
        }
        self.trace.append("%s(%s) prio=%d" % (self.name_of(action), action, priority))
        return Status.SUCCESS

    @staticmethod
    def name_of(action: str) -> str:
        return {"gather": "采集", "build": "建造", "produce": "生产",
                "attack": "攻击", "scout": "侦察", "retreat": "撤退",
                "move": "移动", "defend": "防守"}.get(action, action)


# ---------------------------------------------------------------------------
# 微操叶子：按纪律顺序拼装
# ---------------------------------------------------------------------------


def _player_controlled(bb: Blackboard) -> bool:
    return bb.unit in (bb.get("player_controlled_units") or ())


def _yield_to_player(bb: Blackboard) -> str:
    """玩家已接管该单位 → 不产生任何意图（让权）。

    这是**安全边界的第一道**：必须在任何"派活"逻辑之前，且一旦命中就终结本单位的树。
    实测教训：加了"不许空转"规则后，模型会反过来给玩家接管的单位下发指令；
    仲裁层虽能兜底，但微操层本就该自己先让开。
    """
    bb.trace.append("让权给玩家")
    bb.intent = None
    return Status.SUCCESS


def _is_combat(bb: Blackboard) -> bool:
    info = bb.unit_info
    return bool(info.get("type") in (bb.get("combat_types") or ()))


def _outnumbered(bb: Blackboard) -> bool:
    """可见敌人数 **多于** 我方作战单位数 → 劣势。

    刻意用**单步比较**（多于），不用"≥2 倍"：实测对 2B 模型，多步算术类判据无效。
    这条在行为树里是确定性代码，但仍保持同一口径，便于与模型口径一致。
    """
    enemies = len(bb.get("visible_enemies") or ())
    return enemies > int(bb.get("own_combat_count") or 0) > 0


def _retreat(bb: Blackboard) -> str:
    """劣势撤离：朝自己主基地方向给一个远离敌人的坐标。

    `target` 必须是 **dict**（契约 `IntentTarget`），不是裸坐标列表 ——
    实测写成 `[x, z]` 会被契约校验拒绝：`intents.0.target: Input should be a valid dictionary`。
    """
    home = bb.get("home_pos") or [0.0, 0.0]
    return bb.emit("retreat", {"pos": [round(float(home[0]), 1), round(float(home[1]), 1)]},
                   priority=95, rationale="可见敌人数多于我方作战单位，撤离保存战力")


def _has_assigned_target(bb: Blackboard) -> bool:
    target = bb.get("assigned_target")
    return bool(target) and target in (bb.get("visible_enemies") or ())


def _attack_assigned(bb: Blackboard) -> str:
    return bb.emit("attack", {"entity_id": str(bb.get("assigned_target"))}, priority=80,
                   rationale="执行上层分派的交战目标")


def _is_worker(bb: Blackboard) -> bool:
    return bool(bb.unit_info.get("gather"))


def _nearest_resource(bb: Blackboard):
    """最近的可见资源（坐标一律用适配器给的 2D `unit_pos`/`pos`）。

    注意：观测里的 `pos` 是**三维** [x, y, z]，直接当成 [x, z] 用会错位。
    适配器已统一成 2D，这里不再自己解析。
    """
    res = bb.get("visible_resources") or []
    if not res:
        return None
    pos = bb.get("unit_pos") or [0.0, 0.0]
    best, best_d = None, None
    for entry in res:
        rp = (entry or {}).get("pos") or [0.0, 0.0]
        d = (float(rp[0]) - float(pos[0])) ** 2 + (float(rp[1]) - float(pos[1])) ** 2
        if best_d is None or d < best_d:
            best, best_d = entry, d
    return best


def _gather(bb: Blackboard) -> str:
    # 优先用**程序分配器**给的矿点（人少优先 + A/B 均衡），没有再退回"最近的矿"。
    # 实测依据：纯"最近"会让 3 个工人全指向同一个矿点（用户截图：挤成一团、有人闲置）。
    assigned = str(bb.get("assigned_resource") or "")
    res = next((e for e in (bb.get("visible_resources") or [])
                if str(e.get("entity_id", "")) == assigned), None) if assigned else None
    res = res or _nearest_resource(bb)
    if not res:
        return Status.FAILURE
    rp = res.get("pos") or [0.0, 0.0]
    return bb.emit("gather", {
        "entity_id": str(res.get("entity_id") or ""),
        "pos": [round(float(rp[0]), 1), round(float(rp[1]), 1)],
    }, priority=50, rationale="工人采集最近的可见资源（经济优先）")


def _should_regroup(bb: Blackboard) -> bool:
    """空闲作战单位向主基地集结（**默认开启**，可用 `allow_idle_regroup=false` 关掉）。

    为什么现在默认开启（2026-09-11 用户要求"要看到副官批量指挥部队"）：
    - 目标点是**观测到的主基地位置**（`home_anchor`），不是凭空算的野外坐标
      —— 原始纪律禁止的是"没有依据的游走"，这条不违反它；
    - 全队**同一个目标** → 仲裁层（`arbitration.merge_same_orders`）把这一批 move
      合并成**一条多单位命令**：屏幕上就是"整队一起动"，日志里是一条命令带 N 个单位。

    历史教训仍要记住：给空闲单位发**凭空坐标**的侦察会把金标准用例 `replay_model_timeout`
    （期望该 tick 无下发）打挂 —— 那条用例里 Unit_1 是 tank、没有基地锚点，
    所以这里仍要求 `home_anchor` 存在，拿不到就**不动作**（宁可不发）。
    """
    return bool(bb.get("allow_idle_regroup")) and _is_combat(bb)


# ---------------------------------------------------------------------------
# 专职侦察（不违反"不许无依据地动"）
# ---------------------------------------------------------------------------

#: 侦察航点的罗盘方位（按顺序轮换）。
SCOUT_BEARINGS: Tuple[Tuple[int, int], ...] = (
    (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1))
#: 逐圈外扩的半径步长（米）。
SCOUT_RING_STEP = 10.0
#: 单个航点的停留时长（tick）。放长的原因：飞行到位需要时间，
#: 换得太勤会一直在半路改目标（配合"航点槽位做意图 id"才不会抖）。
SCOUT_HOLD_TICKS = 600
#: 外扩上限（米），避免一路飞出战场纵深。
SCOUT_MAX_RADIUS = 70.0


def _is_scout(bb: Blackboard) -> bool:
    """是否**专职侦察单位**（默认 `scout_types = ("drone", "scout")`）。

    刻意只认专职侦察，不把作战单位也算进来：让坦克/步兵满地图乱跑是
    无依据的战场动作（见 `_should_regroup` 的教训），而无人机本来就是"眼睛"。
    """
    return bool(bb.unit_info.get("type") in (bb.get("scout_types") or ()))


def _scout_slot(bb: Blackboard) -> int:
    hold = max(1, int(bb.get("scout_hold_ticks") or SCOUT_HOLD_TICKS))
    return int(bb.get("server_tick") or 0) // hold


def _scout_waypoint(bb: Blackboard):
    """按 tick 推出**确定性侦察航点**；拿不到基地坐标返回 None（宁可不发）。

    为什么这次可以算坐标（此前"空闲集结"被判为无依据而默认关闭）：
    旧版是**凭空游走**（没有任何观测依据）；这里每个航点都由
    **观测到的主基地位置**（`home_anchor`，真实读自 `op=tactical`）
    加确定性方位/圈数推出 —— 同一 tick 必然得到同一点，可复现、可单测，
    因此不违反"不许做无依据的战场动作"这条纪律。
    """
    home = bb.get("home_anchor")
    if not home:
        return None
    slot = _scout_slot(bb)
    bearing = SCOUT_BEARINGS[slot % len(SCOUT_BEARINGS)]
    ring = 1 + slot // len(SCOUT_BEARINGS)
    step = float(bb.get("scout_ring_step") or SCOUT_RING_STEP)
    radius = min(step * ring, float(bb.get("scout_max_radius") or SCOUT_MAX_RADIUS))
    return [round(float(home[0]) + bearing[0] * radius, 1),
            round(float(home[1]) + bearing[1] * radius, 1)]


def _scout(bb: Blackboard) -> str:
    """专职侦察单位向确定性航点前压（发现敌人后由"交火/撤离"分支接管）。

    为什么必须存在：验收要求"侦察"，而在此之前空闲单位**没有任何动作** ——
    实测 5 分钟对局里回执只有 `gather/produce/build`，无人机整局停在基地。
    没有侦察就没有敌情，后面的"交战 / 劣势撤离"根本无从触发。

    意图 id 用**航点槽位**（`id_tick=_scout_slot`）而不是 tick，理由见 `emit`。
    """
    if not _is_scout(bb):
        return Status.FAILURE
    point = _scout_waypoint(bb)
    if not point:
        return Status.FAILURE
    return bb.emit("scout", {"pos": point}, priority=20, id_tick=_scout_slot(bb),
                   rationale="专职侦察按确定性航点前压 %s（基地位置+方位/圈数推出）" % (point,))


def _engage_nearest(bb: Blackboard) -> str:
    enemies = bb.get("visible_enemies") or []
    if not enemies:
        return Status.FAILURE
    return bb.emit("attack", {"entity_id": str(enemies[0])}, priority=75,
                   rationale="作战单位交火最近的可见敌人")


def _regroup(bb: Blackboard) -> str:
    """空闲作战单位向主基地靠拢（有据可依的兜底，非凭空侦察）。

    坐标取自观测到的主基地位置；拿不到基地位置就**不动作**（宁可不发）。
    """
    home = bb.get("home_anchor")
    if not home:
        return Status.FAILURE
    return bb.emit("regroup", {
        "pos": [round(float(home[0]), 1), round(float(home[1]), 1)],
    }, priority=30, rationale="无可见敌人：向主基地靠拢保持队形（不做无依据的野外游走）")


def build_micro_tree() -> Node:
    """构造微操行为树（每单位一棵，顺序即纪律）。

    优先级（高 → 低）：
      1. 玩家接管 → 让权（**安全边界，必须最前**）
      2. 劣势 → 撤离（求生优先于一切军事行动）
      3. 有已分派目标 → 攻击该目标（执行 LLM/阶梯意图）
      4. 作战单位 → 打最近的可见敌人
      5. 工人 → 采集（兜底，**可被阶梯的建造/生产抢占** —— 见 `micro_intents` 分工说明）
      6. 专职侦察 → 向确定性航点前压（无人机等；有据可依，见 `_scout_waypoint`）
      7. 否则 → 空闲集结（**默认关闭**，见 `_should_regroup`）

    **建造/生产不在本树内**：由 `rules_fallback.development_intents` 决定"造什么/产什么"
    并优先认领单位，本树只处理剩余单位。这样避免"工人先命中采集就永远轮不到建造"
    （或反过来"无条件建造"）这类由**判据归属不清**造成的死结。
    """
    return Selector(
        # 1. 安全边界：玩家接管的单位，副官绝不碰。
        Sequence(Condition(_player_controlled, "玩家已接管"),
                 Action(_yield_to_player, "让权"), name="让权给玩家"),

        # 2. 求生：劣势先撤，不要硬冲（实测模型会拿 1 个兵冲 3 个敌人）。
        Sequence(Condition(_is_combat, "是作战单位"),
                 Condition(_outnumbered, "敌多于我"),
                 Action(_retreat, "撤离"), name="劣势撤离"),

        # 3. 执行上层分派的交战目标。
        Sequence(Condition(_has_assigned_target, "有分派目标"),
                 Action(_attack_assigned, "攻击目标"), name="执行交战"),

        # 4. 作战单位打最近的可见敌人。
        Sequence(Condition(_is_combat, "是作战单位"),
                 Action(_engage_nearest, "交火"), name="就近交火"),

        # 5. 工人本职：采集（低优先、可被阶梯抢占）。
        Sequence(Condition(_is_worker, "是工人"),
                 Action(_gather, "采集"), name="工人采集"),

        # 6. 专职侦察：侦察单位向确定性航点前压。
        # 【2026-09-11 新增】此前空闲单位没有任何动作 → 无人机整局停在基地，
        # 验收项"侦察"从未发生、也就永远没有敌情可谈（交战/撤离无从触发）。
        # 与已关闭的"空闲集结"区别：航点由**观测到的基地位置**推出，不是凭空游走。
        Sequence(Condition(_is_scout, "是专职侦察"),
                 Action(_scout, "侦察"), name="专职侦察"),

        # 7. 兜底：空闲作战单位向基地靠拢（默认关闭，见 _should_regroup）。
        Sequence(Condition(_should_regroup, "允许空闲集结"),
                 Action(_regroup, "集结"), name="空闲集结"),

        name="微操树",
    )


# ---------------------------------------------------------------------------
# 入口：把观测归一化成黑板，逐单位 tick
# ---------------------------------------------------------------------------


def _adapt(
    state: Dict[str, Any],
    tactical: Optional[Dict[str, Any]],
    rules: Optional[Dict[str, Any]],
    cfg: Dict[str, Any],
) -> Dict[str, Any]:
    """把观测归一化成**全局共享事实**（所有单位复用，避免 N 次重复解析）。

    刻意复用 `rules_fallback` 的私有适配器（`_normalized_units` / `_living_enemies` /
    `_resources` / `_pos2d` / `_base_anchor_pos`）而不是另写一套：
    观测字段（`kind`/`unit_type`/三维 `pos`）的解读方式必须**全仓库唯一**，
    两套解析必然迟早分叉 —— 而那正是"改了参数却毫无变化"这类幽灵 bug 的温床。
    """
    from . import rules_fallback as rf

    by_name = rf._normalized_units(tactical)
    resources = rf._resources(tactical)
    enemies = rf._living_enemies(tactical)
    ai_units = [str(u) for u in ((state or {}).get("ai_controlled_units") or [])]

    return {
        "by_name": by_name,
        # 敌人只需 id（目标推理归模型，微操只负责"打最近的"）。
        # id 一律经 `rf.entity_id_of` 取：游戏端导出的实体只有 `name`。
        # 【曾按 `entity_id` 读 → `visible_enemies` 恒空 → 就近交火与劣势撤离
        #   **永远不触发**，且不报错、不降级，只表现为"副官从不打仗"。】
        "visible_enemies": [rf.entity_id_of(e) for e in enemies if rf.entity_id_of(e)],
        # 资源坐标统一成 2D：观测里的 pos 是 [x, y, z]，直接当 [x, z] 会错位。
        # 同一原因：资源实体的字段也是 `name`，读错会让工人在树里**永远采不了矿**。
        "visible_resources": [
            {"entity_id": rf.entity_id_of(e), "pos": list(rf._pos2d(e))}
            for e in resources if rf.entity_id_of(e)
        ],
        "own_combat_count": sum(
            1 for n in ai_units if by_name.get(n, {}).get("type") in cfg["combat_types"]),
        # **采集分配器**（照搬游戏内传统 AI `EconomyController._find_visible_resource`）：
        # 按"资源节点已分配人数 + 资源类型均衡 + 距离"给每个工人**预分配**矿点，
        # 避免所有工人取"最近矿"挤成一团（实测 3 工人同矿、部队被堵、有人闲置）。
        "assigned_resources": rf.assign_resources(by_name, resources, unit_names=ai_units),
        # 撤离用：允许兜底（必须**一定有坐标可撤**，拿不到基地就退回自身位置）。
        "home_pos": (lambda anchor: list(anchor) if anchor else None)(
            rf._base_anchor_pos(by_name)),
        # 侦察/集结用：**严格**只认不动的建筑（`base_anchor_pos`）。
        # 【2026-09-11 实测】`_base_anchor_pos` 的兜底会把会动的兵当基地 →
        # 侦察航点变成"绕自己转"（每换槽位朝外漂 10m），等价于无依据游走。
        "base_anchor": (lambda anchor: list(anchor) if anchor else None)(
            rf.base_anchor_pos(by_name)),
    }


def micro_parts(
    state: Dict[str, Any],
    *,
    tactical: Optional[Dict[str, Any]] = None,
    rules: Optional[Dict[str, Any]] = None,
    config: Optional[Dict[str, Any]] = None,
    ttl_ticks: int = 3600,
    server_tick: Optional[int] = None,
    snapshot_id: Optional[int] = None,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """微操层入口，返回 **(阶梯意图, 行为树意图)** 两段 —— **来源显式**。

    为什么要把来源分开返回：两段的**合并语义不同**，混在一起就说不清谁该让谁 ——

    - **阶梯**（build/produce/attack 的发展骨架）允许顶掉模型的**低优先**动作：
      实测"工人全被派去采集"时，阶梯的 build 会被模型那条 gather 顶掉，
      于是整局只有兵没有营（`tests/test_ladder_batch_integration.py` 钉住）；
    - **行为树**的自主动作（就近交火/集结/采集兜底）**不顶**模型意图：
      模型意图优先是金标准（`replay_player_takeover.jsonl` 明确钉住
      "模型下发 move 必须被接受"），行为树只处理模型没管的单位。
      唯一例外是**求生**（retreat）——见 `nodes._may_displace`。

    合并规则单点在 `nodes.node_tactical_agent`；本模块只负责产出与区分来源。
    """
    from . import rules_fallback as rf

    cfg = {"combat_types": ("soldier", "vehicle", "tank", "aircraft"),
           # 专职侦察单位：无人机是这局里唯一的"眼睛"（`scout` 对应 Scout.tscn 的单位类型）。
           # 只认这两类，作战单位不参与侦察（见 `_is_scout` 的说明）。
           "scout_types": ("drone", "scout")}
    cfg.update(config or {})
    tick = int(server_tick or (state or {}).get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or (state or {}).get("latest_snapshot_id", 0) or 0)

    player_units = [str(u) for u in ((state or {}).get("player_controlled_units") or [])]
    # 候选池与 rules_fallback 严格同口径：只碰有 AI 租约的 `ai_controlled_units`。
    # （曾放宽为"我方单位 − 玩家接管"，被安全边界用例拦下，见 rules_fallback 同名注释。）
    ai_units = [str(u) for u in ((state or {}).get("ai_controlled_units") or [])]
    if not ai_units:
        return [], []

    # ① 发展阶梯优先认领：它的意图已通过既有契约与落点修复，原样透传。
    ladder: List[Dict[str, Any]] = []
    try:
        ladder = rf.development_intents(
            state, tactical=tactical, rules=rules, ttl_ticks=ttl_ticks,
            server_tick=tick, snapshot_id=snapshot) or []
    except Exception:  # noqa: BLE001 - 阶梯异常绝不允许拖垮微操
        ladder = []
    claimed = {str(u) for intent in ladder for u in (intent.get("unit_ids") or [])}

    # ② 行为树处理剩余单位。
    shared = _adapt(state, tactical, rules, cfg)
    assigned = (state or {}).get("assigned_targets")
    tree = build_micro_tree()
    out: List[Dict[str, Any]] = []
    for name in ai_units:
        if name in claimed:
            continue  # 阶梯已认领（建造/生产/出击），微操不插手
        info = shared["by_name"].get(name) or {}
        unit_pos = _unit_pos(info)
        bb = Blackboard({
            "unit": name,
            "unit_info": info,
            "unit_pos": unit_pos,
            "server_tick": tick,
            "snapshot_id": snapshot,
            "ttl_ticks": ttl_ticks,
            "player_controlled_units": player_units,
            "combat_types": cfg["combat_types"],
            "visible_enemies": shared["visible_enemies"],
            "visible_resources": shared["visible_resources"],
            # 预分配的矿点（程序分配器的结果；没有时退回"最近的矿"）。
            "assigned_resource": (shared.get("assigned_resources") or {}).get(name, ""),
            "own_combat_count": shared["own_combat_count"],
            # 撤离用：必须**一定有坐标可撤**，拿不到基地就退回自身位置。
            "home_pos": shared["home_pos"] or unit_pos,
            # 集结/侦察用：必须是**真实观测到的不动建筑**（严格锚点），
            # 拿不到就不动作（宁可不发）—— 用松散兜底会让航点绕着自己漂。
            "home_anchor": shared["base_anchor"],
            # 空闲集结**默认开启**（2026-09-11 用户要求"要看到副官批量指挥部队"）：
            # 目标点是**观测到的主基地**（全队同一目标 → 仲裁层把这一批 move 合并成
            # **一条多单位命令**，屏幕上就是"整队一起动"）。这不是凭空游走 ——
            # 原始纪律禁止的是"没有依据的野外游走"，而"回基地集结"的位置来自观测。
            "allow_idle_regroup": bool(cfg.get("allow_idle_regroup", True)),
            # 专职侦察的航点参数（默认取模块常量；可按对局/验收需要收窄）。
            "scout_types": tuple(cfg.get("scout_types") or ()),
            "scout_hold_ticks": int(cfg.get("scout_hold_ticks") or SCOUT_HOLD_TICKS),
            "scout_ring_step": float(cfg.get("scout_ring_step") or SCOUT_RING_STEP),
            "scout_max_radius": float(cfg.get("scout_max_radius") or SCOUT_MAX_RADIUS),
            "assigned_target": (assigned or {}).get(name) if isinstance(assigned, dict) else None,
        })
        tree.tick(bb)
        if bb.intent:
            out.append(bb.intent)
    return ladder, out


def micro_intents(
    state: Dict[str, Any],
    *,
    tactical: Optional[Dict[str, Any]] = None,
    rules: Optional[Dict[str, Any]] = None,
    config: Optional[Dict[str, Any]] = None,
    ttl_ticks: int = 3600,
    server_tick: Optional[int] = None,
    snapshot_id: Optional[int] = None,
) -> List[Dict[str, Any]]:
    """微操层意图**列表**（阶梯在前、行为树在后）：`micro_parts` 的合并视图。

    调用方通常应该用 `micro_parts` —— 两段的**合并语义不同**，
    混成一个列表就分不清"谁该让谁"（见 `micro_parts` 说明）。
    """
    ladder, tree = micro_parts(
        state, tactical=tactical, rules=rules, config=config,
        ttl_ticks=ttl_ticks, server_tick=server_tick, snapshot_id=snapshot_id)
    return ladder + tree


def micro_batch(
    state: Dict[str, Any],
    *,
    tactical: Optional[Dict[str, Any]] = None,
    rules: Optional[Dict[str, Any]] = None,
    config: Optional[Dict[str, Any]] = None,
    ttl_ticks: int = 3600,
    server_tick: Optional[int] = None,
    snapshot_id: Optional[int] = None,
) -> Dict[str, Any]:
    """微操层意图**批次**：形状与模型输出一致，因此可走同一套校验/仲裁/预算流程。"""
    tick = int(server_tick or (state or {}).get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or (state or {}).get("latest_snapshot_id", 0) or 0)
    intents = micro_intents(
        state, tactical=tactical, rules=rules, config=config,
        ttl_ticks=ttl_ticks, server_tick=tick, snapshot_id=snapshot)
    return {
        "match_id": "", "player_id": "", "plan_version": "",
        "based_on_snapshot": snapshot, "intents": intents,
    }


def _unit_pos(info: Dict[str, Any]) -> List[float]:
    """归一化单位的 2D 位置（三维观测 → [x, z]）。"""
    from . import rules_fallback as rf
    x, z = rf._pos2d({"pos": (info or {}).get("pos")})
    return [x, z]


if __name__ == "__main__":  # pragma: no cover - 手工自检
    # 观测形状与真实 DCS 一致：实体在 `entities` 里，用 `kind` 区分，
    # 单位类型字段是 `unit_type`，坐标是三维 [x, y, z]。
    demo_state = {
        "server_tick": 1000, "latest_snapshot_id": 3,
        "ai_controlled_units": ["U_w1", "U_s1", "U_s2", "U_p1", "U_taken"],
        "player_controlled_units": ["U_taken"],
        "assigned_targets": {"U_s1": "E_1"},
    }
    demo_tac = {
        "entities": [
            {"kind": "unit_self", "name": "U_w1", "unit_type": "worker",
             "gather": True, "construct": True, "pos": [5, 0, 5]},
            {"kind": "unit_self", "name": "U_s1", "unit_type": "soldier", "pos": [6, 0, 5]},
            {"kind": "unit_self", "name": "U_s2", "unit_type": "soldier", "pos": [7, 0, 5]},
            {"kind": "unit_self", "name": "U_p1", "unit_type": "barracks",
             "queue": True, "pos": [0, 0, 0]},
            {"kind": "resource", "entity_id": "R_1", "pos": [8, 0, 6]},
            {"kind": "unit_enemy", "entity_id": "E_1", "pos": [30, 0, 30]},
        ],
    }
    demo_rules = {
        "builds": [{"building_type_id": "factory",
                    "allowed_builder_type_ids": ["worker"]}],
        "productions": [{"product_type_id": "soldier",
                         "allowed_producer_type_ids": ["barracks"]}],
    }
    print("--- 1 敌 2 兵（不劣势）---")
    for it in micro_intents(demo_state, tactical=demo_tac, rules=demo_rules):
        print("%-8s %-8s %s" % (it["unit_ids"][0], it["action"], it["rationale"]))

    # 劣势场景：三个敌人 > 两个作战单位 → 必须撤离而不是硬冲。
    demo_tac["entities"].extend([
        {"kind": "unit_enemy", "entity_id": "E_2", "pos": [31, 0, 30]},
        {"kind": "unit_enemy", "entity_id": "E_3", "pos": [32, 0, 30]},
    ])
    print("--- 3 敌 2 兵（劣势，应撤离）---")
    for it in micro_intents(demo_state, tactical=demo_tac, rules=demo_rules):
        print("%-8s %-8s %s" % (it["unit_ids"][0], it["action"], it["rationale"]))
