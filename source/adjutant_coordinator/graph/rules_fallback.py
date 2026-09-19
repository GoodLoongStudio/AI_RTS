# -*- coding: utf-8 -*-
"""确定性规则兜底：模型不可用时让部队继续工作（不抢模型的决策权）。

为什么需要（2026-09-10 实测）：本地模型链路是
「云 runner → Cloudflare 隧道 → 家宽 → 代理 → Ollama」，
任一环抖动都会让单轮卡满 LLM 超时（实测 elapsed_ms=120015），
期间**全部单位空转**，经济一动不动 —— 用户看到的正是"非常慢且瞎操作"。
提示词要求："模型两次回答之间，部队必须继续工作。"

设计边界（刻意保守）：
- 兜底只做**事实可判定**的事：谁空闲、谁能采集、资源点在哪、基地能不能造工人；
- **不做**目标推理 —— 守哪、打谁、往哪侦察仍归模型；
- 因此兜底产出永远是三件事：工人采集、基地补工人、其余待命。
这样即使模型彻底不可用，部队也在推进经济，而不是站着不动。
"""
from typing import Any, Dict, List, Optional, Tuple

from .contracts import (
    ACTION_ATTACK, ACTION_ATTACK_MOVE, ACTION_BUILD, ACTION_DEFEND, ACTION_GATHER,
    ACTION_HOLD, ACTION_MOVE, ACTION_PRODUCE, ACTION_REGROUP, ACTION_RETREAT,
    ACTION_SCOUT,
)
import math

from .model_context import rules_scene_index
from . import campaign as campaign_mod
from . import placement

#: 兜底最多派几个工人去采集（避免一次灌太多意图）。
#: 【2026-09-12 晚改 4 → 8】工人目标提到 6/基地（见 `WORKERS_PER_BASE`）后，
#: 4 条/tick 的采集配额会让第 5 个以后的工人**长期没有采集意图**（"有钱不采"）。
MAX_GATHER_INTENTS = 8
#: 地板建造落点的半径环（米）：与 `placement.VISION_SAFE_RADIUS_M` 同口径（视野内）。
#: 依据：`NotVisible` 是建造被拒的头号原因，视野半径是 5m 量级
#: （"基地+5m"能建成兵营，8/12/16m 全被拒）；"别堵住部队"由净空排序解决。
BUILD_PLACEMENT_RADII_FLOOR: Tuple[float, ...] = (4.0, 6.0, 8.0)
#: 防御塔至少离开指挥中心这么远（米）：更近就是"套在家门口"。
TURRET_MIN_HQ_M = 6.0
#: 防御塔沿方位外探的硬上限（米）：**收窄到基地附近**。
#: 【2026-09-15 晚 用户实测】"AI副官让防御塔造的位置太靠外面了，这不对的" ——
#: 原上限 24/26m 配合"离基地越远越优先"的打分，塔会一路建到视野边缘、脱离基地支援。
TURRET_MAX_HQ_M = 16.0
#: 防御塔"内圈"半径（米）：距指挥中心 < 此值算"留在基地内"。唯一实现在 `placement`。
#: 用户 2026-09-15 口径："优先建到基地外围，基地内会保留少量防御塔"。
TURRET_INNER_HQ_M = placement.TURRET_INNER_RADIUS_M
#: 已有塔当视野锚点时的外推半径 / 上限（米）：塔视野 **16m**（2026-09-15 用户口径，
#: 一度误做成 64 已改回）⇒ 沿既有塔最多再往外 ~16m 建造，留 0.8 安全余量取 13。
#: 上限仍略放宽（有塔当锚点能看到更远），但配合 `placement.turret_band_rank` 的
#: "出带即降级"打分，不会再把塔越建越远。
TURRET_VISION_WITH_ANCHOR_M = 13.0
TURRET_MAX_HQ_WITH_ANCHOR_M = 18.0
#: 按类型名识别固定防御（地板与模型共用同一套外围选址）。
TURRET_TYPE_IDS = ("anti_air_turret", "anti_ground_turret")
_STRUCTURE_TYPE_HINTS = (
    "command_center", "barracks", "vehicle_factory", "aircraft_factory",
) + TURRET_TYPE_IDS
#: 工人少于该数量时，基地尝试补工人。
WORKER_TARGET = 4
#: 每座"会造工人的建筑"（指挥中心）的目标工人数。
#: **必须与传统 AI 同值**（`SimpleClairvoyantAI.workers_per_command_center = 6`）：
#: 铁律是"副官永不弱于传统 AI"，而这里曾经写 4 —— 开局 5 万时我们比传统 AI
#: 少 1/3 的采集工，属于**规则档位本身**就落后。
#: 实际目标 = max(WORKER_TARGET, 基地数 × 本值)。
WORKERS_PER_BASE = 6
#: "富局"门槛（A 资源）：余额高于此值时**不做穷局节流**（见 `_rich_bank`）。
#: 依据：开局 5 万 = 250 个工人 / 100 辆坦克 / 83 座兵营的购买力，
#: 此时瓶颈是"转化速度"（产能建筑 × 工人 × 并行工地），不是钱。
RICH_BANK_A = 10000
#: 同一产品"队列 + 在途"的上限（计划 §三：AI 不得占满生产队列，玩家订单优先）。
WORKER_QUEUE_CAP = 2
# 【唯一事实来源】"仍算在途占用"的意图状态**直接引用** `graph.state`，不再手抄一份。
# 手抄那一份曾经漏掉 `active_unknown` / `retry_wait`，于是"存活状态"在本模块里
# 与仲裁/微操层口径不一致（同一句判据在不同文件里答案不同）。
from .state import (  # noqa: E402
    INTENT_DROPPED,
    INTENT_LIVE_STATES as LIVE_INTENT_STATES,
)

# ---------------- 发展阶梯（决策手册 BLD-01） ----------------
#: 有作战单位达到该数量且存在可见敌人时，阶梯给出 attack 候选。
#: 【待实测】参考值，不是平衡事实；由配置覆盖，禁止在别处硬编码。
ARMY_ATTACK_THRESHOLD = 2
#: 视为"作战单位"的单位类型 —— **仅作兜底**（规则视图里读不到 `capabilities` 时用，
#: 例如老配置或单测夹具）。运行时的唯一口径是 `combat_types_from_rules()` 的派生结果，
#: 由 `node_ingest` 每轮写进 `state["combat_types"]`，其余模块只读那一个字段。
COMBAT_TYPES = ("soldier", "tank", "helicopter")


def combat_types_from_rules(rules) -> Tuple[str, ...]:
    """**可机动作战单位口径的唯一实现**：规则视图里"能打 **且** 能动"的单位类型。

    ## 为什么必须派生而不是硬编码（2026-09-13 收工自检发现三份口径）
    - 配置里已有 `apc`（带 `apc_autocannon`）与 `heavy_tank`，硬编码的 `COMBAT_TYPES`
      会**漏算**它们 → 兵力上限少算、军事轨不指挥它们、出击门槛不数它们；
    - `behavior_tree` 那份写着 `vehicle` / `aircraft` —— 配置里**根本不存在**这两个 id，
      于是直升机（真实 id `helicopter`）在树里漏计；
    - `campaign` 又抄一份常量。三份口径 = 三处会各自腐烂的地方。

    ## 为什么必须同时要 `move`（2026-09-13 真机导出实测）
    只要 `attack` 会把**固定炮塔**算进来：导出实测能打的类型是
    `[anti_air_turret, anti_ground_turret, apc, heavy_tank, helicopter, soldier, tank]`，
    而炮塔是**不可机动**的（`move=false`）。把它们算成兵力有两个恶果：
    ①60 座炮塔就能把兵力上限吃满、部队再也补不了兵；
    ②军事轨会给炮塔派 `attack_move`（它根本不能动）。
    所以口径 = `attack ∧ move`，实测结果正好是 `[apc, heavy_tank, helicopter, soldier, tank]`。

    ## 判据必须"能力字段齐全"才派生
    只对"有 capabilities 的那几种"派生会得到**残缺**口径：没带能力字段的类型会被判成
    非作战单位 → 兵力上限**少算**（比硬编码更糟）。所以全有才派生，缺一个就返回空元组，
    由调用方回退 `COMBAT_TYPES`（保守）。导出侧"每个类型都带 capabilities"由
    `AdjutantRulesExportSmokeTest` 守门。
    """
    rows = [item for item in (rules or {}).get("unit_types") or [] if isinstance(item, dict)]
    if not rows:
        return ()
    classified = [item for item in rows if isinstance(item.get("capabilities"), dict)]
    if len(classified) != len(rows):
        return ()
    out = [str(item.get("id", "")) for item in classified
           if bool((item.get("capabilities") or {}).get("attack"))
           and bool((item.get("capabilities") or {}).get("move"))]
    return tuple(sorted({item for item in out if item}))
#: 发展阶梯的建造顺序（逐级推进；每级达到 `BUILD_LIMITS` 的座数就往下走）。
#: 【2026-09-12 晚扩线，用户反馈"不会发展、不会多造建筑、防御、分子基地"】
#: 顺序 = 产能（兵营→车厂→机场）→ 防御（防空→反地）→ 分基地（第二座指挥中心）。
#: 不在规则视图里的类型会被 `scene_index` 过滤掉（`continue`），所以这份表可以
#: 写得比实际可建项更全 —— 拿不到就不建，不会发出非法命令。
BUILD_LADDER = ("barracks", "vehicle_factory", "aircraft_factory",
                "anti_air_turret", "anti_ground_turret", "command_center")
#: 每类建造物的**座数上限**（没有条目 = 1 座）。
#: 为什么需要"多座"：旧实现是"有一座就跳过"，于是兵营+车厂之后发展线彻底停摆
#: （实测余额 46800 花不出去、既没有防御也没有第二个基地）。
BUILD_LIMITS = {
    # 【2026-09-12 晚：按开局购买力对齐传统 AI】
    # 原表（各 1 座 + 2 基地）= 整局规划只值 **6,800 A**，即开局 5 万的 **13.6%** ——
    # 实测 5 分钟只花掉 9,550（19%），40,450 一直闲置。钱花不出去**不是执行问题，
    # 是这张上限表本身的设计**：它按"穷局"标定。
    # 传统 AI 的口径是 `max_command_centers = 3` + 3 个编组 × 6 人 = 18 个战斗单位，
    # 也就是"至少 3 座基地、多条产线"。铁律"副官永不弱于传统 AI"要求我们不少于它。
    "barracks": 2,
    "vehicle_factory": 2,
    "aircraft_factory": 1,
    # 防御：一防一空各一座 + 分矿各一座（两处基地都要覆盖）。
    "anti_air_turret": 2,
    "anti_ground_turret": 2,
    # 基地上限对齐传统 AI `max_command_centers = 3`。
    "command_center": 3,
}
#: 各建造物对应的"由谁生产什么"（产品 id → 生产建筑类型）。
#: 【2026-09-12 晚扩线】补上机场产品（`helicopter`）—— 否则新建的机场**永远闲着**，
#: 又变成"有建筑不用"（用户反馈"不会发展"）。只加作战单位，不加 `drone`：
#: 无人机无武器、侦察已由"前压探索 + 专职侦察"覆盖，避免无人机制造堆积。
PRODUCT_LADDER = (("soldier", "barracks"), ("tank", "vehicle_factory"),
                  ("helicopter", "aircraft_factory"))
#: "这个单位打不了这个目标"的记忆时长（tick，默认 1800 ≈ 30 秒）。
#: 仅在**能力版本未知**时作兜底；能力版本已知且未变时，记忆不因时间自动失效（F04）。
TARGET_BAN_TICKS = 1800


def capability_version_of(state: Optional[Dict[str, Any]],
                          rules: Optional[Dict[str, Any]] = None) -> str:
    """武器/规则能力版本。变了才允许重新评估黑名单，不靠固定 30 秒遗忘。"""
    if isinstance(rules, dict):
        raw = rules.get("rules_version")
        if isinstance(raw, dict) and raw.get("content_hash"):
            return str(raw["content_hash"])
        if isinstance(raw, str) and raw:
            return raw
    return str((state or {}).get("rules_version")
               or (state or {}).get("capability_version") or "")


def type_attack_domains(rules: Optional[Dict[str, Any]], unit_type: str) -> List[str]:
    """规则视图里该类型武器能打的域（`weapons[].target_domains`）。"""
    if not rules or not unit_type:
        return []
    for item in rules.get("unit_types") or []:
        if not isinstance(item, dict) or str(item.get("id", "")) != str(unit_type):
            continue
        domains = set()
        for weapon in item.get("weapons") or []:
            if not isinstance(weapon, dict):
                continue
            for domain in weapon.get("target_domains") or []:
                domains.add(str(domain))
        return sorted(domains)
    return []


def type_movement_domain(rules: Optional[Dict[str, Any]], unit_type: str) -> str:
    """该类型的移动域。规则缺失时按空中类型名兜底（与编制口径一致）。"""
    if not unit_type:
        return ""
    if isinstance(rules, dict):
        for item in rules.get("unit_types") or []:
            if isinstance(item, dict) and str(item.get("id", "")) == str(unit_type):
                return str((item.get("movement") or {}).get("domain") or "")
    if str(unit_type) in AIR_UNIT_TYPES:
        return "air"
    return "terrain"


def unit_attack_domains(state: Optional[Dict[str, Any]], unit: str,
                        rules: Optional[Dict[str, Any]] = None,
                        by_name: Optional[Dict[str, Any]] = None) -> List[str]:
    """该单位当前能打的域：先看观测/状态里的活数据，再退回类型表。"""
    name = str(unit)
    live = ((state or {}).get("own_attack_domains") or {}).get(name)
    if live:
        return [str(item) for item in live]
    if by_name and name in by_name:
        live = (by_name.get(name) or {}).get("attack_domains")
        if live:
            return [str(item) for item in live]
    kind = str(((state or {}).get("own_unit_types") or {}).get(name)
               or ((by_name or {}).get(name) or {}).get("type") or "")
    return type_attack_domains(rules, kind)


def enemy_movement_domain(enemy, rules: Optional[Dict[str, Any]] = None,
                          state: Optional[Dict[str, Any]] = None) -> str:
    """敌人当前所在域：实体字段 → 状态表 → 类型表。"""
    if isinstance(enemy, dict):
        domain = str(enemy.get("domain") or "")
        if domain:
            return domain
        entity = entity_id_of(enemy)
        kind = str(enemy.get("unit_type") or enemy.get("type") or "")
    else:
        entity = str(enemy or "")
        kind = str(((state or {}).get("enemy_types") or {}).get(entity, ""))
    table = (state or {}).get("enemy_domains") or {}
    if entity and table.get(entity):
        return str(table[entity])
    return type_movement_domain(rules, kind)


def can_attack_by_capability(state: Optional[Dict[str, Any]], unit: str, enemy,
                             rules: Optional[Dict[str, Any]] = None,
                             by_name: Optional[Dict[str, Any]] = None):
    """事前能力判定：True/False；未知（缺域或缺武器表）返回 None，交给黑名单兜底。"""
    domains = unit_attack_domains(state, unit, rules, by_name)
    target = enemy_movement_domain(enemy, rules, state)
    if not domains or not target:
        return None
    return target in set(domains)


def ban_unattackable_target(state: Dict[str, Any], units, entity, tick: int,
                            entity_type: str = "", unit_types=None) -> None:
    """记下「这些单位打不了这个目标」（按 **单位 × (目标 或 目标类型)** 记账，有界）。

    **为什么要按"目标类型"再记一条**（2026-09-13 实测，第一版修复没生效的原因）：
    只按实体拉黑时，树下一轮会挑**另一个**同类敌人（实测 `Unit_43` 对空目标被拒 10 次 =
    每轮换一个空中目标继续试），命令流照样刷屏。地空不匹配是**武器属性**，
    所以要把"这个单位打不了**这一类**目标"也记下来。

    **为什么按单位而不是按目标**：同一时刻防空单位打得了的目标、地面单位打不了，
    按目标全局拉黑会误伤能打的那批。

    依据：一局 347 条命令里 **124 条**被 `武器无法攻击该目标所处的域` 拒掉，
    同一单位反复重发（`Unit_43` 被拒 **10** 次 ≈ 每 15 秒重试一次，
    正好撞在 `ORDER_REPEAT_WINDOW_TICKS` 的窗口上）—— 用户原话"你下达命令不能瞎下达"。
    """
    entity = str(entity or "")
    kind = str(entity_type or "")
    if not entity and not kind:
        return
    bans = state.setdefault("unattackable_targets", {})
    for unit in units or []:
        name = str(unit)
        if entity:
            bans["%s|%s" % (name, entity)] = int(tick)
        if kind:
            bans["%s|type:%s" % (name, kind)] = int(tick)
    # 【再升级一层：**单位类型 × 目标类型**】能力（武器域）是**类型的属性**，不是某个个体的：
    # 一个士兵打不了无人机，说明"所有士兵都打不了无人机"。只按个体学，就要把
    # "每个单位 × 每种敌方类型"各付一次拒绝（实测 fix6 局仍残留 29 条域不匹配 = 学习成本）。
    # 个体差异（升级/挂载）留在个体键上：类型键只作为**加速**，不做唯一判据。
    known_types = state.get("own_unit_types") or {}
    for unit in units or []:
        own_kind = str((unit_types or {}).get(str(unit))
                       or known_types.get(str(unit), ""))
        if own_kind and kind:
            bans["type:%s|type:%s" % (own_kind, kind)] = int(tick)
    cutoff = int(tick) - TARGET_BAN_TICKS
    for key in [k for k, v in bans.items() if int(v) < cutoff]:
        bans.pop(key, None)
    while len(bans) > 256:                      # 有界（防长局无限增长）
        bans.pop(next(iter(bans)))


def enemy_type_of(state: Dict[str, Any], entity) -> str:
    """该敌人**上一次被看到时的类型**（`state["enemy_types"]`，由 `node_ingest` 每轮刷新）。

    为什么要留一张表：拒绝是**事后的**（回执到达时敌人可能已经离开视野），
    没有这张表就没法把"打不了"升级成"打不了这一类"。
    """
    return str((state.get("enemy_types") or {}).get(str(entity), ""))


def attackable_enemies(state: Dict[str, Any], enemies, units,
                      rules: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
    """这批单位**打得了**的敌人。

    顺序：① 事前权威能力（武器域 vs 目标移动域）；② 事后黑名单兜底。
    能力已知且说"打不了"→ 不发；能力已知且说"打得了"→ 不被类型级黑名单误伤。
    能力版本未变时，黑名单不因 1800 tick 自动放行（F04）。
    """
    now = int(state.get("server_tick", 0) or 0)
    types = state.get("enemy_types") or {}
    bans = state.get("unattackable_targets") or {}
    cap_ver = capability_version_of(state, rules)
    prev_ver = str(state.get("capability_version") or "")
    if cap_ver and prev_ver and cap_ver != prev_ver:
        bans = {}
    if cap_ver:
        state["capability_version"] = cap_ver
    keep_bans = bool(cap_ver) and (not prev_ver or prev_ver == cap_ver)
    own_types = state.get("own_unit_types") or {}
    blocked_entities = set()
    blocked_types = set()
    for unit in units or []:
        own_kind = str(own_types.get(str(unit), ""))
        for key, stamp in (bans or {}).items():
            if (not keep_bans) and now - int(stamp) >= TARGET_BAN_TICKS:
                continue
            if key.startswith("%s|" % str(unit)):
                value = key[len(str(unit)) + 1:]
                if value.startswith("type:"):
                    blocked_types.add(value[len("type:"):])
                else:
                    blocked_entities.add(value)
            elif own_kind and key.startswith("type:%s|" % own_kind):
                value = key[len("type:%s|" % own_kind):]
                if value.startswith("type:"):
                    blocked_types.add(value[len("type:"):])
    out: List[Dict[str, Any]] = []
    for enemy in enemies or []:
        known_allow = False
        known_block = False
        for unit in units or []:
            verdict = can_attack_by_capability(state, str(unit), enemy, rules)
            if verdict is True:
                known_allow = True
            elif verdict is False:
                known_block = True
        if known_block and not known_allow:
            continue
        if known_allow:
            out.append(enemy)
            continue
        entity = str(entity_id_of(enemy))
        if entity and entity in blocked_entities:
            continue
        kind = str(enemy.get("unit_type") or enemy.get("type")
                   or types.get(entity, ""))
        if kind and kind in blocked_types:
            continue
        out.append(enemy)
    return out


ENGAGE_STICK_RATIO = 1.25
FIRE_SOFT_CAP = 1


def pick_engage_target(state, unit, enemies, unit_pos, combat_types=(),
                       locks=None) -> str:
    """合法敌人里按距离/威胁选一个，带滞回与火力分配（F02 唯一口径）。

    `enemies` 是实体列表；返回 entity id。数组顺序不参与排序。
    """
    if not enemies:
        return ""
    locks = locks if isinstance(locks, dict) else ((state or {}).get("engage_locks") or {})
    claimed: Dict[str, int] = {}
    for other, enemy_id in locks.items():
        if str(other) != str(unit):
            claimed[str(enemy_id)] = claimed.get(str(enemy_id), 0) + 1
    here = unit_pos or (0.0, 0.0)
    scored = []
    for enemy in enemies:
        enemy_id = entity_id_of(enemy)
        if not enemy_id:
            continue
        pos = _pos2d(enemy)
        dist = math.hypot(float(pos[0]) - float(here[0]), float(pos[1]) - float(here[1]))
        kind = str(enemy.get("unit_type") or enemy.get("type") or "")
        if kind in set(combat_types or ()):
            threat = 1.0
        elif kind == "worker":
            threat = 0.15
        elif kind:
            threat = 0.5
        else:
            threat = 0.8
        try:
            hp = float(enemy.get("hp") or 0.0)
            hp_max = float(enemy.get("hp_max") or 0.0) or 1.0
        except (TypeError, ValueError):
            hp, hp_max = 0.0, 1.0
        hp_ratio = max(0.1, hp / hp_max) if hp_max else 1.0
        score = dist / max(0.2, threat) / hp_ratio
        scored.append((claimed.get(enemy_id, 0) >= FIRE_SOFT_CAP, score, dist, enemy_id))
    if not scored:
        return ""
    scored.sort()
    best_id = scored[0][3]
    best_score = scored[0][1]
    current = str(locks.get(str(unit)) or "")
    if current and any(item[3] == current for item in scored):
        cur_score = next(item[1] for item in scored if item[3] == current)
        if cur_score <= best_score * ENGAGE_STICK_RATIO:
            return current
    return best_id


#: 作战单位总上限（手册 04 §军队规模规划："接敌前坦克上限 **60**；达到上限停止产坦克，
#: 资源留给战损重建"）。这里按**全部作战单位**（`COMBAT_TYPES`）计 ——
#: 只数坦克会漏掉士兵/直升机，而它们同样吃帧率与指挥带宽。
#:
#: 【为什么必须真的执行】手册把"无上限生产"列为禁止项（v4 实测 385 辆坦克既调不动也
#: 拖垮端点）；2026-09-13 实测同一现象 —— 生产结算修好后 **150 秒兵力 11 → 105**，
#: 游戏帧率被拖到 20~30（用户原话："不应该为了 AI 副官而放弃游戏性能"）。
#: 达到上限 = **停发作战生产**（工人/建筑/防御不受影响），钱留着重建战损。
COMBAT_UNIT_CAP = 60


def combat_types_of(state: Dict[str, Any], rules=None) -> Tuple[str, ...]:
    """**当前生效的**作战单位口径（读的地方只许调这一个）。

    优先级：`state["combat_types"]`（本轮 `node_ingest` 从规则视图派生并落档）
    → 传入的 `rules` 现算 → 兜底常量 `COMBAT_TYPES`（老配置/夹具）。
    落进 state 的好处：它随 checkpoint 与对局档案一起留档，
    复盘时"这局按哪些类型算作战单位"是**可查的事实**，而不是代码里的隐式假设。
    """
    stored = state.get("combat_types") if isinstance(state, dict) else None
    if isinstance(stored, (list, tuple)) and stored:
        return tuple(str(item) for item in stored)
    derived = combat_types_from_rules(rules)
    if derived:
        return derived
    return COMBAT_TYPES


def combat_units(state: Dict[str, Any], tactical, rules=None) -> Tuple[int, int]:
    """(已落地作战单位数, 队列中作战产品数) —— 兵力上限判定的**唯一口径**。

    两个都要数，缺一个上限就守不住：
    - 只数已落地 = "边产边超编"（实测 150 秒从 11 涨到 105）；
    - 只数**队列**不数在途意图 = 队列项还没出现时（刚下发、游戏还没入队）重复下单。
    计数范围 = **观测里我方全部单位**（不只 `ai_controlled_units`）：上限管的是
    "战场上有多少人在跑"，玩家接管的那些一样吃帧率。
    """
    by_name = _normalized_units(tactical)
    combat_ids = combat_types_of(state, rules)
    deployed = sum(1 for info in by_name.values()
                   if str(info.get("type", "")) in combat_ids)
    queued = 0
    for entry in (tactical or {}).get("production") or []:
        if not isinstance(entry, dict):
            continue
        for item in entry.get("items") or []:
            # 队列项的类型字段是 `definition_id`（`product_type_id` 是旧名，实测恒空）。
            item_id = str((item or {}).get("definition_id")
                          or (item or {}).get("product_type_id", ""))
            if item_id in combat_ids:
                queued += 1
    return deployed, queued


def note_army_cap(state: Dict[str, Any], deployed: int, queued: int, tick: int) -> str:
    """记账（**不许静默跳过**）：本轮因为兵力上限没发作战生产，写进 `state["army_cap"]`。

    为什么必须留痕：验收读的是"为什么这一轮没有出兵"——上限拦下的和"忘了出兵/被拒掉"
    在日志上必须能分辨（否则下次复盘会把设计当成故障，或反过来）。
    """
    record = state.setdefault("army_cap", {})
    record["cap"] = COMBAT_UNIT_CAP
    record["deployed"] = int(deployed)
    record["queued"] = int(queued)
    # `blocked` 是**轮次**计数（阶梯与并行填充同一轮各判一次 → 只算一次），
    # 否则"拦住 1 轮"会报成 2（这条坑在受阻降级那边刚踩过）。
    if int(record.get("last_block_tick", -1) or -1) != int(tick):
        record["blocked"] = int(record.get("blocked", 0) or 0) + 1
        record["last_block_tick"] = int(tick)
    return "army_cap:%d/%d(+%d)" % (deployed, COMBAT_UNIT_CAP, queued)


def combat_production_allowed(state: Dict[str, Any], tactical, tick: int,
                              rules=None) -> bool:
    """兵力未达上限 → True（照常产兵）；达到 → **记账后** False（本轮停发作战生产）。"""
    deployed, queued = combat_units(state, tactical, rules)
    if deployed + queued >= COMBAT_UNIT_CAP:
        note_army_cap(state, deployed, queued, tick)
        return False
    return True


def queue_item_product(item) -> str:
    """生产队列项的产品类型 id（**唯一实现**）。

    `definition_id` 是权威字段；`product_type_id` 是旧名（实测恒空）。
    以前同文件两处口径不同（并行填充的工人队列只认旧名 → 恒 0 → 目标工人数永远算不够），
    统一到这里：新增任何"读队列项类型"的地方只许调用本函数。
    """
    if not isinstance(item, dict):
        return ""
    return str(item.get("definition_id") or item.get("product_type_id") or "")


def produce_totals(by_name: Dict[str, Any], tactical, state,
                   scene_index: Optional[Dict[str, str]] = None) -> Dict[str, int]:
    """按产品类型统计"**现有 + 队列 + 在途**"（生产缺口的唯一口径）。

    为什么必须三项都算（2026-09-15 用户要求"按当前数量 + 队列 + 在途算缺口"）：
    只数现有单位时，刚下发的兵还没出现在观测里 → `counts` 恒 0 →
    "数量最少者优先"会**连续多轮押同一个产品**；而车/机一落地就记 1、
    步兵有存量，于是长期偏向车辆与飞机（用户实测"AI 不喜欢生产小步兵"）。

    - 现有：观测里我方单位（`by_name`）；
    - 队列：`tactical["production"][*]["items"]`（权威事实，字段口径见 `queue_item_product`）；
    - 在途：本协调器已下发、权威尚未结算完的 `produce` 意图（按 `target.scene` 反查产品）。
    """
    totals: Dict[str, int] = {}
    for info in (by_name or {}).values():
        key = str((info or {}).get("type", ""))
        if key:
            totals[key] = totals.get(key, 0) + 1
    for entry in (tactical or {}).get("production") or []:
        if not isinstance(entry, dict):
            continue
        for item in entry.get("items") or []:
            key = queue_item_product(item)
            if key:
                totals[key] = totals.get(key, 0) + 1
    scene_to_product: Dict[str, str] = {}
    for product, scene in (scene_index or {}).items():
        if scene:
            scene_to_product[str(scene)] = str(product)
    for intent in (state or {}).get("active_intents") or []:
        if not isinstance(intent, dict):
            continue
        if str(intent.get("action", "")) != ACTION_PRODUCE:
            continue
        if str(intent.get("state", "")) not in LIVE_INTENT_STATES:
            continue
        target = intent.get("target")
        scene = str(target.get("scene", "")) if isinstance(target, dict) else ""
        product = scene_to_product.get(scene, "")
        if product:
            totals[product] = totals.get(product, 0) + 1
    return totals


#: 基础步兵（soldier）的**最低占比**：低于它（或干脆没有步兵）→ 保底补一个。
#: 为什么要有（2026-09-15 用户实测"AI 不喜欢生产小步兵"）：阶梯 2 只按"数量最少"选级，
#: 车/机一落地就记 1、步兵有存量 → 长期偏向车辆与飞机（实测一局 8 分钟没出过兵）。
#: **为什么用占比而不是绝对下限**：绝对下限（如"至少 4 个"）会压掉
#: "3 兵 + 0 坦 → 该补坦克"这类正常的多兵种轮转（既有回归测试正守这条）；
#: 用户要的是"别长期偏向车辆"，不是"步兵永远优先"。
SOLDIER_SHARE = 0.34


def soldier_shortage(soldier_total: int, combat_total: int) -> bool:
    """基础步兵是否"数量不足"（口径 = 现有 + 队列 + 在途，需保底补一个）。

    判据：**完全没有步兵**，或步兵占比低于 `SOLDIER_SHARE`。
    """
    if int(soldier_total) <= 0:
        return True
    if int(combat_total) <= 0:
        return False
    return float(int(soldier_total)) / float(int(combat_total)) < SOLDIER_SHARE


#: 侦察单位的**最低在编数**（现役专职 + 在途/队列无人机 < 它 → 触发专用补充生产）。
#: 为什么需要（2026-09-15 用户实测"不持续侦察全图"）：`PRODUCT_LADDER` 刻意不含 drone，
#: 于是"专职侦察一死，整局再没有侦察"；这里给一条**有上限**的专用补充档，
#: 只补到 `RECON_MIN_PROBES` 为止，不会像作战单位那样堆积。
RECON_MIN_PROBES = 1


def recon_produce_intent(state: Dict[str, Any], by_name: Dict[str, Dict[str, Any]],
                         inputs: Dict[str, Any], tactical, scene_index,
                         *, free_producers: List[str], usable_producers,
                         production_views, tick: int
                         ) -> Optional[Tuple[str, str]]:
    """专职侦察不足时**该补一架无人机**（有上限，不是堆量）。

    返回 `(producer, drone_scene)`；没有缺口 / 没有空闲机场 → None。
    口径：现役专职（drone/scout，未阵亡）+ 队列里的 drone + 在途 drone
    < `RECON_MIN_PROBES` → 用**空闲机场**补一架。

    为什么单独成档、不塞进 `PRODUCT_LADDER`（那边注释明确不加 drone 防堆积）：
    侦察必须"独立配额"（2026-09-15 用户要求"不能被建造/采集/军事挤掉"），
    但也不能变成无上限生产。找不到空闲机场 → 返回 None（不硬塞、不抢造兵产能）。
    """
    drone_scene = str((scene_index or {}).get("drone", ""))
    if not drone_scene:
        return None
    live = 0
    for name in inputs.get("ai_units") or []:
        info = by_name.get(name) or {}
        if str(info.get("type", "")) not in PROBE_TYPES:
            continue
        if info.get("confirmed_dead"):
            continue
        live += 1
    queued_drones = 0
    for entry in (tactical or {}).get("production") or []:
        if not isinstance(entry, dict):
            continue
        for item in entry.get("items") or []:
            if queue_item_product(item) == "drone":
                queued_drones += 1
    inflight = 0
    for intent in (state.get("active_intents") or []):
        if not isinstance(intent, dict):
            continue
        if str(intent.get("action", "")) != ACTION_PRODUCE:
            continue
        if str(intent.get("state", "")) not in LIVE_INTENT_STATES:
            continue
        target = intent.get("target")
        scene = str(target.get("scene", "")) if isinstance(target, dict) else ""
        if scene == drone_scene:
            inflight += 1
    in_service = live + queued_drones + inflight
    if in_service >= RECON_MIN_PROBES:
        return None
    producer = next((name for name in free_producers
                     if str((by_name.get(name) or {}).get("type", "")) == "aircraft_factory"
                     and name in usable_producers
                     and _queue_size_of(production_views, name) < PRODUCER_QUEUE_CAP), "")
    if not producer:
        return None
    # 只返回"该造什么、谁来造"；意图由调用方构造 —— 阶梯里的 `_intent` 是带
    # tick/snapshot 的**局部闭包**，模块级函数拿不到它（已踩一次 NameError）。
    return (producer, drone_scene)


#: 整批里出现这些动作，才算"这批已经在发展"，否则补阶梯。
DEVELOPMENT_ACTIONS = (ACTION_BUILD, ACTION_PRODUCE, ACTION_ATTACK)
#: **可被发展动作抢占**的低优先动作：这些动作占用的单位不算"忙"。
#: 按**优先级语义**定义（低优先即让位），不要按某个具体动作名硬编码 ——
#: 实测两次踩同一个坑：只认 gather 时，模型一发 scout/move 就让建造阶梯再次饿死
#: （整局只有 gather/scout、没有兵营）。
PREEMPTIBLE_ACTIONS = (ACTION_GATHER, ACTION_SCOUT, ACTION_MOVE, ACTION_HOLD)

#: 跨产者的**抢占序**（数字越大越优先）。模型意图与阶梯/行为树意图会落到同一个
#: 单位上，必须有**确定性**的胜负规则，否则要么两套决策打架、要么一方被静默饿死
#: （实测"有兵无营"就是后者：阶梯的 build 每轮都被模型那条 gather 顶掉）。
#:
#: **不要用各自的 `priority` 字段直接比**：两套产者量纲不同
#: （阶梯是 2~4，行为树是 30~95），比数字会得出错误结论。
#: 语义顺序：求生 > 交战 > 发展 > 防御/本职采集 > 机动 > 待命。
ACTION_PREEMPT_RANK = {
    ACTION_RETREAT: 90,
    ACTION_ATTACK: 70,
    ACTION_ATTACK_MOVE: 70,
    ACTION_BUILD: 60,
    ACTION_PRODUCE: 60,
    ACTION_DEFEND: 55,
    ACTION_GATHER: 40,
    ACTION_REGROUP: 30,
    ACTION_SCOUT: 20,
    ACTION_MOVE: 20,
    ACTION_HOLD: 10,
}


def action_rank(action: Any) -> int:
    """动作的抢占序。**未知动作取 100（最高）**：只抢占我们明确认定为低优先的动作，
    拿不准就不抢 —— 保守失败比无依据地打断既有任务安全。
    """
    return int(ACTION_PREEMPT_RANK.get(str(action), 100))
#: 建造落点相对**主基地**的偏移（米）。游戏侧 `_op_build` 必须拿到 position，
#: 缺省 (0,0) 会被拒（NotVisible/OutOfBounds/SurfaceNotBuildable）。
#: 取 5m：贴近基地 → 完全可见、可导航的概率最高。【待实测】偏移量与轮换策略。
BUILD_PLACEMENT_OFFSET_M = 5.0
#: 换方位的时间粒度（tick，60Hz → 600≈10 秒）。
BUILD_PLACEMENT_ROTATE_TICKS = 600
#: "在工地上的工人"判定半径（米）。这个范围内的工人**不许被抢去采集**：
#: 施工是指派制，工人被调走工地就永远建不完（实测车厂挂十几分钟、38 次生产被拒）。
SITE_KEEP_RADIUS_M = 10.0
#: 同一个资源点最多派几个工人（**分配层**的保守常量）。
#: 【2026-09-12 结构性整改】常量与分配算法都已收敛到**唯一实现** `resource_allocation`：
#: 原先 `rules_fallback` 与本文件、`task_patch`、`behavior_tree` 各有一份实现/各写一次常量，
#: 于是"4 个工人挤 1 个矿、旁边 3 个矿没人用"（用户实测）在一条路径上修好了、另一条还是坏的。
#: 这里只做**后向兼容的再导出**：旧调用点 `rf.RESOURCE_WORKERS_PER_NODE` /
#: `rf.assign_resources(...)` 继续可用，但实现只有一处。
from . import resource_allocation as _resource_allocation  # noqa: E402
from .resource_allocation import RESOURCE_WORKERS_PER_NODE as RESOURCE_WORKERS_PER_NODE  # noqa: E402


def assign_resources(by_name: Dict[str, Dict[str, Any]],
                     resources: List[Dict[str, Any]],
                     unit_names: Optional[List[str]] = None,
                     per_node: int = RESOURCE_WORKERS_PER_NODE,
                     *,
                     intents: Optional[List[Dict[str, Any]]] = None,
                     **kwargs: Any) -> Dict[str, str]:
    """（保留旧名）给采集单位分配矿点 → 唯一实现在 `resource_allocation.assign`。

    **调用方只需要传 `intents=`（在途意图）**，占用账（"谁已经在采哪个矿"）会自动补上：
    这是刻意的 —— 让"正确用法"成为默认用法。不传就会出现
    "已经在采的人不在负载里 → 新工人被重复派到同一个矿"（2026-09-12 用户实测：
    4 个工人 3 个挤一个矿、部队被堵、5 米外的矿没人用，而且不会自己散开）。
    """
    if intents is not None and "existing_load" not in kwargs:
        load, type_load, holders = _resource_allocation.occupancy(by_name, resources, intents)
        kwargs.setdefault("existing_load", load)
        kwargs.setdefault("existing_type_load", type_load)
        kwargs.setdefault("skip", set(holders))
    return _resource_allocation.assign(by_name, resources, unit_names, per_node, **kwargs)


def _dist_point_segment(p, a, b) -> float:
    """点 p 到线段 ab 的距离（判断落点是否压在"基地→矿点"的采矿通道上）。"""
    ax, az = a
    bx, bz = b
    px, pz = p
    dx, dz = bx - ax, bz - az
    if dx == 0 and dz == 0:
        return ((px - ax) ** 2 + (pz - az) ** 2) ** 0.5
    t = ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)
    t = max(0.0, min(1.0, t))
    cx, cz = ax + t * dx, az + t * dz
    return ((px - cx) ** 2 + (pz - cz) ** 2) ** 0.5


def _nearest_resource_pos(by_name, resources):
    """采矿通道终点：最近资源点的 (x,z)；无资源返回 None。"""
    anchor = None
    for info in by_name.values():
        if info.get("queue") or info.get("gather"):
            anchor = _pos2d(info)
            break
    if anchor is None:
        return None
    best = None
    for res in resources or []:
        if not isinstance(res, dict):
            continue
        rp = _pos2d(res)
        d = (rp[0] - anchor[0]) ** 2 + (rp[1] - anchor[1]) ** 2
        if best is None or d < best[0]:
            best = (d, rp)
    return best[1] if best else None


# 【几何口径**只有一份**】越界/视野/净空/坏点的判定全部委派给 `placement`
# （唯一事实来源）。这里保留同名薄壳只是为了兼容既有调用与测试 ——
# 本文件不再自行实现第二份几何逻辑（那正是 2026-09-12 同类问题换皮复发的根因）。
BUILD_BOUND_MARGIN_M = placement.BUILD_BOUND_MARGIN_M


def in_map_bounds(spot, bounds, margin: float = BUILD_BOUND_MARGIN_M) -> bool:
    """点是否落在地图内（委派 `placement.in_bounds`）。"""
    return placement.in_bounds(spot, bounds, margin)


def _clamp_into_bounds(spot, bounds, margin: float = BUILD_BOUND_MARGIN_M) -> list:
    """把点夹进地图内（委派 `placement.clamp_into_bounds`）。"""
    return placement.clamp_into_bounds(spot, bounds, margin)


#: 分基地落点距矿点的外推距离（米）：贴着矿点但略微避开采集往返通道。
#: **必须留在视野内**：原值 12m 是结构性错误 —— 矿点旁采矿的工人视野只有 5m 量级，
#: 12m 外的点必然 `NotVisible`（探针实测 172 条 build 被拒的主因之一）。
#: 收到 6m（落在工人视野内），"远离主基地"由 `EXPANSION_MIN_DISTANCE_M` 保证。
EXPANSION_RESOURCE_OFFSET_M = 6.0
#: 分基地落点距主基地的最小距离（米）：比这更近的矿点不算"分基地"，只是主基地圈内。
EXPANSION_MIN_DISTANCE_M = 30.0


def pick_expansion_spot(by_name, resources, anchor, blocked=None, bounds=None) -> list:
    """分基地选址：**离主基地较远的可见矿点附近**（而不是主基地旁边再盖一座）。

    为什么不能复用 `pick_build_spot`（4/6/8m 环绕主基地）：
    - 分基地的意义是圈地/靠近新矿；贴着主基地盖第二座基地毫无收益
      （用户 2026-09-12 晚明确要"分子基地"）；
    - 但落点**必须在己方视野内**（实测建造被拒的唯一原因就是 `NotVisible`），
      而**矿点附近一定在视野里**（有工人在那儿采矿）→ "挨着远端矿点"既安全又有收益；
    - 拿不到符合条件的矿点就返回 `[]`（宁可不建，也不在主基地旁边堆一座假分基地）。
    """
    if anchor is None:
        return []
    blocked = blocked if blocked is not None else []
    units = [_pos2d(info) for info in by_name.values() if info.get("pos")]
    best, best_distance = None, 0.0
    for resource in resources or []:
        if not isinstance(resource, dict):
            continue
        pos = _pos2d(resource)
        distance = math.hypot(pos[0] - anchor[0], pos[1] - anchor[1])
        if distance < EXPANSION_MIN_DISTANCE_M:
            continue
        # 从矿点朝"离开主基地"的方向再外推一点，避免压在采集往返通道上。
        dx, dz = pos[0] - anchor[0], pos[1] - anchor[1]
        norm = math.hypot(dx, dz) or 1.0
        spot = (pos[0] + dx / norm * EXPANSION_RESOURCE_OFFSET_M,
                pos[1] + dz / norm * EXPANSION_RESOURCE_OFFSET_M)
        # 可行性走**同一套判据**（界内 + 视野内 + 有净空 + 未被拉黑）。
        # 这里"视野内"天然等于"有己方单位在附近"——远端矿点有工人采矿才算数，
        # 于是"看不见的远方基地"根本不会被产出（那正是 172 条 NotVisible 的来源）。
        if placement.spot_issue(spot, bounds, units, blocked) is not None:
            continue
        if best is None or distance > best_distance:   # 越远越优先：真正的新地盘
            best, best_distance = spot, distance
    if best is None:
        return []
    return [round(best[0], 1), round(best[1], 1)]


def _note(state, kind: str, **payload) -> None:
    """写一条决策日志（与 `nodes._decide` **同形状**；上限也用它那份常量，避免两套口径）。

    延迟导入：模块级 `from . import nodes` 会成环（`nodes` 依赖本模块）。
    """
    from . import nodes

    entry = {**payload, "kind": kind, "server_tick": int(state.get("server_tick", 0))}
    log = state.setdefault("decision_log", [])
    log.append(entry)
    while len(log) > nodes.MAX_DECISION_LOG:
        del log[0]


def pick_build_spot(by_name, resources, anchor, blocked=None, bounds=None,
                    state=None) -> list:
    """选建造落点：**离己方单位与采矿通道最远**，且在地图内、视野内、有净空。

    实测依据（2026-09-12 用户反馈："兵营造的位置会卡住工人采矿"）：
    旧落点是"基地 + 5m、按 tick 轮换方位"，实测 barracks(10,12) 正好压在
    工人 (8~10, 13~14.6) 的采矿通道上，把工人堵在 1.5m 口袋里。
    改为多方位候选 + 三重打分：离己方实体足够远 / 离采矿通道与资源点越远越好 / 半径近优先。

    **几何可行性不再由本函数判断**：候选生成与"界内/视野内/净空/坏点"筛选
    全部委派 `placement.candidate_spots`（唯一事实来源）—— 越界（`OutOfBounds`）
    与视野外（`NotVisible`）这两类**必然被拒**的点在下发前就已被剔除，
    本函数只负责在可行点里按"离采矿通道最远"排序（业务目标）。
    """
    units = [_pos2d(info) for info in by_name.values() if info.get("pos")]
    resource = _nearest_resource_pos(by_name, resources)
    spots = placement.candidate_spots(anchor[0], anchor[1], bounds=bounds,
                                      own_points=units, rejected=blocked,
                                      radii=BUILD_PLACEMENT_RADII_FLOOR)
    if spots:
        best, best_score = None, None
        for spot in spots:
            if resource is not None:
                clear = min(_dist_point_segment(spot, anchor, resource),
                            ((spot[0] - resource[0]) ** 2
                             + (spot[1] - resource[1]) ** 2) ** 0.5)
            else:
                clear = 999.0
            # 净空（相对采矿通道）优先；同分时取**列表中更靠前**的点
            # （`candidate_spots` 已按 净空→近半径→槽位序 排好，确定性）。
            if best_score is None or clear > best_score:
                best, best_score = spot, clear
        return [round(best[0], 1), round(best[1], 1)]
    # 兜底：环上候选全被淘汰（贴边基地 / 点都被拉黑）→ **朝地图中心**逐级后退。
    retreat = placement.retreat_spot(anchor[0], anchor[1], bounds=bounds,
                                     own_points=units, rejected=blocked)
    if retreat is not None:
        return retreat
    # 【最后一次兜底也必须守拉黑与净空（2026-09-14 迭代3 现场修）】
    # 老实现这里直接 `clamp_into_bounds(anchor)` —— 返回的是**基地自身坐标**，
    # 它必然 `SurfaceNotBuildable`：实测同一个点被拒 **13 次**（账本记了也没用，
    # 因为这条路绕过了账本）。用户原话："你下达命令不能瞎下达"。
    # 纪律：**宁可不建**，也不产出一条注定被拒的命令。
    clamped = placement.clamp_into_bounds(anchor, bounds)
    if placement.spot_issue(clamped, bounds, units, blocked) is None:
        return [round(float(clamped[0]), 1), round(float(clamped[1]), 1)]
    if state is not None:
        _note(state, "build_spot_exhausted", anchor=[round(float(anchor[0]), 1),
                                                     round(float(anchor[1]), 1)],
              banned=len(getattr(blocked, "entries", {}) or {}),
              note="候选与兜底全不可用（含被拉黑）：本轮不发建造命令")
    return []


def is_turret_building(building: Any) -> bool:
    """建筑 / 场景 id 是否是固定防御塔。"""
    text = str(building or "").lower()
    return any(token in text for token in TURRET_TYPE_IDS) or "turret" in text


def _structure_anchors(by_name) -> List[Tuple[float, float]]:
    """己方不动建筑坐标（指挥中心、产线、已有塔），给外围环当外推锚点。"""
    out: List[Tuple[float, float]] = []
    for info in (by_name or {}).values():
        kind = str((info or {}).get("type", ""))
        if not any(token in kind for token in _STRUCTURE_TYPE_HINTS) and not info.get("queue"):
            continue
        if not info.get("pos"):
            continue
        out.append(_pos2d(info))
    return out


def _approach_vector(anchor, bounds=None, enemies=None) -> Tuple[float, float]:
    """塔优先朝向：最近可见敌人，否则地图中心，再否则正东。"""
    ax, az = float(anchor[0]), float(anchor[1])
    best = None
    for enemy in enemies or ():
        if not isinstance(enemy, (list, tuple)) or len(enemy) < 2:
            continue
        try:
            ex, ez = float(enemy[0]), float(enemy[1])
        except (TypeError, ValueError):
            continue
        distance = (ex - ax) ** 2 + (ez - az) ** 2
        if best is None or distance < best[0]:
            best = (distance, (ex - ax, ez - az))
    if best is not None:
        return best[1]
    if placement.has_bounds(bounds):
        return (float(bounds[0]) / 2.0 - ax, float(bounds[1]) / 2.0 - az)
    return (1.0, 0.0)


def collect_turret_candidates(by_name, anchor, blocked=None, bounds=None,
                              enemies=None) -> List[Tuple[float, float]]:
    """防御塔候选：当前己方视野能伸到的最外圈（几何仍走 `placement`）。

    视野锚点分两档（用户 2026-09-15："塔优先建到基地外围"）：
    - 己方**还没有塔**：沿用保守的 8m 量级，第一座塔必须落在基地/工人眼皮下；
    - **已有塔**：塔视野 16→64 后它能提供视野，下一座沿它继续外推（半径与上限同时放大）。
    """
    if anchor is None:
        return []
    units = [_pos2d(info) for info in (by_name or {}).values() if info.get("pos")]
    approach = _approach_vector(anchor, bounds, enemies)
    has_anchor = any(is_turret_building(info.get("type"))
                     for info in (by_name or {}).values())
    return placement.collect_perimeter_candidates(
        (float(anchor[0]), float(anchor[1])),
        bounds=bounds,
        own_points=units,
        rejected=blocked,
        extra_origins=_structure_anchors(by_name),
        bearings=(approach,),
        min_radius=TURRET_MIN_HQ_M,
        max_radius=TURRET_MAX_HQ_WITH_ANCHOR_M if has_anchor else TURRET_MAX_HQ_M,
        ring_radii=(6.0, 8.0),
        vision_radius=(TURRET_VISION_WITH_ANCHOR_M if has_anchor
                       else placement.VISION_SAFE_RADIUS_M),
    )


def pick_turret_spot(by_name, resources, anchor, blocked=None, bounds=None,
                     state=None, enemies=None) -> list:
    """防御塔选址：**基地外缘的目标带内**，并与已有塔错开、朝敌/地图中心、避开采矿道。

    为什么不能复用 `pick_build_spot`（4/6/8m 环、同等净空取更近半径）：
    那套是给兵营/车厂的"别堵家门口"，会把塔也砌在指挥中心旁边。
    塔要的是"基地外缘、面朝来敌"，但**不是越远越好**：距离打分走
    `placement.turret_band_rank`，超出 `placement.TURRET_BAND_OUTER_M` 后越远越降级
    （2026-09-15 晚用户实测："AI副官让防御塔造的位置太靠外面了，这不对的"）。
    """
    if anchor is None:
        return []
    spots = collect_turret_candidates(by_name, anchor, blocked=blocked,
                                      bounds=bounds, enemies=enemies)
    resource = _nearest_resource_pos(by_name, resources)
    existing = [_pos2d(info) for info in (by_name or {}).values()
                if info.get("pos") and is_turret_building(info.get("type"))]
    approach = _approach_vector(anchor, bounds, enemies)
    norm = math.hypot(approach[0], approach[1]) or 1.0
    ux, uz = approach[0] / norm, approach[1] / norm

    def _score(spot):
        hq = math.hypot(spot[0] - anchor[0], spot[1] - anchor[1])
        if hq < TURRET_MIN_HQ_M - 0.05:
            return None
        spread = min((math.hypot(spot[0] - turret[0], spot[1] - turret[1])
                      for turret in existing), default=99.0)
        heading = (spot[0] - anchor[0]) * ux + (spot[1] - anchor[1]) * uz
        if resource is not None:
            mine = min(_dist_point_segment(spot, anchor, resource),
                       math.hypot(spot[0] - resource[0], spot[1] - resource[1]))
        else:
            mine = 99.0
        # 距离口径走 `placement.turret_band_rank`（唯一实现）：带内越外越好，
        # **出了带越远越差** —— 不再是"越远越优先"（那会把塔推到视野边缘，用户实测报障）。
        return (placement.turret_band_rank(hq), spread, heading, mine)

    ranked = []
    for spot in spots:
        score = _score(spot)
        if score is not None:
            ranked.append((score, spot))
    # 【用户 2026-09-15："优先建到外围，基地内保留少量"】已有塔但**内圈一座都没有**时，
    # 这一座补在内圈（免得基地门户全空）；其余情况维持"越外围越优先"。
    # 与 GDScript `DefenseController._needs_one_inside_turret` 同一条规则。
    inside_existing = [t for t in existing
                       if math.hypot(t[0] - anchor[0], t[1] - anchor[1]) < TURRET_INNER_HQ_M]
    if existing and not inside_existing:
        inner = [(score, spot) for score, spot in ranked
                 if math.hypot(spot[0] - anchor[0], spot[1] - anchor[1]) < TURRET_INNER_HQ_M]
        if inner:
            inner.sort(key=lambda item: item[0], reverse=True)
            best_inside = inner[0][1]
            return [round(float(best_inside[0]), 1), round(float(best_inside[1]), 1)]
    if ranked:
        ranked.sort(key=lambda item: item[0], reverse=True)
        best = ranked[0][1]
        return [round(float(best[0]), 1), round(float(best[1]), 1)]
    # 外围候选全空（贴边 + 拉黑）→ 退回普通建造点，仍可能比"不建"强。
    return pick_build_spot(by_name, resources, anchor, blocked=blocked,
                           bounds=bounds, state=state)


def base_anchor_pos(by_name: Dict[str, Dict[str, Any]]):
    """**严格**的基地锚点：只认"我方不动的建筑"（command_center 优先，其次带生产队列的建筑）。

    为什么不直接用 `_base_anchor_pos`（后者有"任意非采集单位"的兜底）：
    那条兜底会在**没有基地**时把会动的单位（步兵/坦克/无人机）当成基地，
    于是"以基地为圆心/终点"的行为全部失真：
      - 侦察航点变成**绕着自己转**：每换一个槽位就朝外漂 10m，等价于无依据游走；
      - 集结/撤离的"基地"跟着部队跑，失去意义。
    所以凡"必须以基地为圆心/终点"的地方都用严格版；拿不到就返回 None，
    由调用方决定"不动"（宁可不发，也不凭空猜坐标）。
    """
    for info in by_name.values():
        if "command_center" in str(info.get("type", "")):
            return _pos2d(info)
    for info in by_name.values():
        if info.get("queue"):
            return _pos2d(info)
    return None


def _base_anchor_pos(by_name: Dict[str, Dict[str, Any]]):
    """找"主基地"位置：优先 command_center，其次任意非采集单位（建筑）。"""
    for name, info in by_name.items():
        if "command_center" in str(info.get("type", "")):
            return _pos2d(info)
    for info in by_name.values():
        if info.get("type") and not info.get("gather"):
            return _pos2d(info)
    return None


# ── 观测解析原语已收敛到 `observation_view`（全仓库唯一实现）────────────────
# 2026-09-12 结构性整改：实体判定 / id 取值 / 坐标降维原先定义在这个模块里，
# 行为树、任务补丁、资源分配各自再抄一份 —— 抄歪一次就是"某功能静默失效"。
# 现在只保留**一个**定义处（`observation_view`），这里只做后向兼容的再导出，
# 旧调用点（`rf._pos2d` / `rf.entity_id_of` / …）继续可用，不需要同时改一圈调用方。
from .observation_view import (  # noqa: E402  （语义上是模块级导入，放这里只为紧贴原定义位置）
    entities as _entities,
    own_units as _own_units,
    resources as _resources,
    resource_available as resource_available,
    entity_id_of as entity_id_of,
    normalized_units as normalized_units,
    pos2d as _pos2d,
    owned_augment_tags as owned_augment_tags,
)


def busy_units(state: Dict[str, Any]) -> set:
    """已被活跃/在途意图占用的单位：兜底绝不抢这些单位。

    口径 = `graph.state.INTENT_LIVE_STATES`（唯一事实来源），不再手写状态名。
    """
    busy = set()
    for intent in state.get("active_intents") or []:
        if intent.get("state") in LIVE_INTENT_STATES:
            for unit in intent.get("unit_ids") or []:
                busy.add(str(unit))
    for request in (state.get("pending_requests") or {}):
        busy.add(str(request))
    return busy


def _nearest_resource(unit: Dict[str, Any],
                      resources: List[Dict[str, Any]],
                      *, load: Optional[Dict[str, int]] = None,
                      cap: int = 0) -> Optional[Dict[str, Any]]:
    """最近资源点；带**分配去冲突**：已经站了 cap 个工人的矿点不再分给新工人。

    实测依据（2026-09-12 用户反馈截图）：3 个工人全被派到**同一个**矿点，
    互相挤在一起、部队也被堵住，而余额 5 万却有人闲置。
    根因：所有路径都是"各自取最近的矿点"，**没有任何分配层**负责"谁去哪个矿、
    一个矿最多几个人"。这里给兜底/阶梯路径补上最基础的一版：优先未占用的矿点，
    同矿最多 `RESOURCE_WORKERS_PER_NODE` 人（资源点本身没有容量字段，
    用"每个矿点不超过 2 个工人"这个保守常量代替，避免 3~4 个人挤同一个点）。
    """
    if not resources:
        return None
    load = load if load is not None else {}
    origin = _pos2d(unit)
    best = None
    best_distance = None
    for resource in resources:
        if not resource_available(resource):
            continue
        entity = entity_id_of(resource)
        if cap and int(load.get(str(entity), 0)) >= cap:
            continue
        target = _pos2d(resource)
        distance = (target[0] - origin[0]) ** 2 + (target[1] - origin[1]) ** 2
        if best_distance is None or distance < best_distance:
            best, best_distance = resource, distance
    if best is None:
        # 所有矿点都满了：退回"最近的"（宁可挤，也不要让工人闲置）。
        return _nearest_resource(unit, resources)
    return best


#: 每个生产者的**队列深度上限**（含正在生产的那一项）。
#:
#: 为什么必须有（2026-09-13 真机实测）：修好"按 item_id 结算生产"之后，一个生产意图会在
#: 完成事件到达时**立刻**结算 → 阶梯下一轮就再下一单 —— 而"每轮 0.5 秒"意味着
#: **150 秒发出 1118 条生产回执**（≈7.5 条/秒），兵力 13→111 只用 90 秒，
#: 结果把 10Hz 扫描拖到 3.29Hz、协调掉到 0.83Hz。
#: 生产本身是长动作（120~300 tick = 2~5 秒），队列里排 2 个就足够接续；
#: "接续快"不等于"下单频率等于轮次频率"（用户口径：只发送变化意图）。
PRODUCER_QUEUE_CAP = 2


def _queue_size_of(views: Dict[str, Dict[str, Any]], producer: str) -> int:
    """该生产者当前的**队列深度**（观测事实；拿不到就按 0 处理，不阻塞下单）。"""
    view = views.get(producer) if isinstance(views, dict) else None
    if not isinstance(view, dict):
        return 0
    try:
        return max(0, int(view.get("queue_size", 0) or 0))
    except (TypeError, ValueError):
        return 0


def _worker_product(rules, owned_types: set) -> Optional[Tuple[str, str]]:
    """找"可被现有单位生产的工人产品"，返回 (producer 类型要求, 产品 id)。

    只认名字里含 worker 的产品，并且其 allowed_producer_type_ids 与现有单位类型相交；
    找不到就返回 None（宁可不造，也不造错东西）。
    """
    if not isinstance(rules, dict):
        return None
    for relation in rules.get("productions") or []:
        if not isinstance(relation, dict):
            continue
        product = str(relation.get("product_type_id", "") or "")
        if "worker" not in product.lower():
            continue
        allowed = {str(t) for t in (relation.get("allowed_producer_type_ids") or [])}
        matched = allowed & owned_types
        if matched:
            return (sorted(matched)[0], product)
        return None


def worker_production_in_flight(state: Dict[str, Any], product_id: str) -> bool:
    """是否**已有在途的该产品（工人）生产意图**（LIVE 状态）。

    【2026-09-15 收敛唯一实现】补工人有两条路径 —— 阶梯 1.8 与并行填充轨
    （`_parallel_intents`），它们必须共用同一份去重口径：否则同一设施会被两条路径
    各发一条 `rule-produce-worker-*`，下游按「执行者+动作+产品」判
    `duplicate_of_live_intent` 丢弃（实测重复生成 391 次），白白占掉并行填充名额。
    原实现只存在于阶梯 1.8 的局部变量里，这里抽出供两处复用。
    """
    if not product_id:
        return False
    prefix = "rule-produce-%s" % product_id
    return any(str(intent.get("intent_id", "")).startswith(prefix)
               and str(intent.get("state", "")) in LIVE_INTENT_STATES
               for intent in (state.get("active_intents") or []))


#: 优先执行"扩张前探"的单位类型（专职侦察；没有它们才退到其它机动单位）。
PROBE_TYPES = ("drone", "scout")
#: 视为"产能建筑"的类型：只有它们存在时，"先补兵"才有意义（没有产能时先建造）。
PRODUCTION_BUILDINGS = ("barracks", "vehicle_factory", "aircraft_factory")


def _pick_probe_unit(by_name: Dict[str, Dict[str, Any]], ai_units: List[str],
                     busy: set) -> str:
    """挑一个空闲的**机动**单位去做扩张前探（拿不到就返回空串，宁可不发）。

    排除采集单位（前探不该抽走经济线）、设施（queue）与**所有静态建筑**。
    【必须查 `movement`】不查的话会挑到炮塔/机场这类不动的建筑，
    权威端只能 `Rejected`（实测 6 条 `rule-probe-expansion` 全被拒 →
    扩张选址被误判成"命令一直失败"而阻塞，同时那条坏命令还会把意图前缀拉黑）。
    """
    def usable(name: str) -> bool:
        info = by_name.get(name) or {}
        if name in busy:
            return False
        if info.get("gather") or info.get("queue"):
            return False
        return bool(info.get("movement"))

    # 扩张前探**不得抽走专职侦察**：无人机是 T01 探索的唯一执行者。
    # `u1t01d` 在侦察 TTL 到期后立刻发了 `rule-probe-expansion-Unit_1`，无人机不再换前沿。
    for name in ai_units:
        kind = str((by_name.get(name) or {}).get("type", ""))
        if usable(name) and kind not in PROBE_TYPES:
            return name
    for wanted in PROBE_TYPES:
        for name in ai_units:
            if usable(name) and str((by_name.get(name) or {}).get("type", "")) == wanted:
                return name
    return ""


def pick_scout_executor(by_name: Dict[str, Dict[str, Any]], ai_units: List[str],
                        busy: set, *, explore: Optional[Dict[str, Any]] = None,
                        blocked: Optional[set] = None,
                        state: Optional[Dict[str, Any]] = None) -> str:
    """侦察执行者：专职优先；专职不在编制/阵亡/0 血时转交其它机动单位。

    计划 U1 / T03：受阻或阵亡后要有人接着探，不能只在原单位上 `wait`。
    玩家接管 = 不在 `ai_controlled_units` 里，同样转交，且不夺回玩家单位。

    **不许**在"这局从来没有专职侦察"的夹具/开局里抢工人 —— 那会把在途 move
    判成 `scout_executor_transfer` 丢掉（金标准 `replay_path_failed` / PendingAuthority
    会被整单冲掉）。转交只在"专职确实没了"时发生。
    """
    assigned = {}
    if isinstance(explore, dict):
        raw = explore.get("assigned")
        if isinstance(raw, dict):
            assigned = raw
    prior_assigned = [str(name) for name in assigned]
    blocked = {str(item) for item in (blocked or set())}

    def gone(name: str) -> bool:
        if name not in ai_units:
            return True
        info = by_name.get(name) or {}
        if info.get("confirmed_dead"):
            return True
        hp = info.get("hp")
        if hp is not None:
            try:
                return float(hp) <= 0.0
            except (TypeError, ValueError):
                return False
        return False

    def usable(name: str) -> bool:
        info = by_name.get(name) or {}
        if name in busy or name in blocked or gone(name):
            return False
        if info.get("queue"):
            return False
        return bool(info.get("movement"))

    living_probes = [
        name for name in ai_units
        if not gone(name)
        and str((by_name.get(name) or {}).get("type", "")) in PROBE_TYPES
    ]
    def _finish(picked: str, *, transfer: bool) -> str:
        if transfer and picked and assigned:
            for name in list(assigned):
                if gone(name):
                    assigned.pop(name, None)
        return picked

    for _wanted in PROBE_TYPES:
        for name in living_probes:
            if usable(name):
                return _finish(name, transfer=False)
    # 专职还在编制里（哪怕本轮忙碌）→ 不转交，避免采集工把正在飞的无人机顶掉。
    if living_probes:
        return ""
    known_probes = set()
    for name, info in (by_name or {}).items():
        if str((info or {}).get("type", "")) in PROBE_TYPES:
            known_probes.add(str(name))
    for name, kind in ((state or {}).get("own_unit_types") or {}).items():
        if str(kind) in PROBE_TYPES:
            known_probes.add(str(name))
    assigned_missing = bool(prior_assigned) and all(gone(name) for name in prior_assigned)
    # 从来没有专职、也没有"原探索执行者已不在" → 不抢工人。
    if not known_probes and not assigned_missing:
        return ""
    for name in ai_units:
        info = by_name.get(name) or {}
        if usable(name) and not info.get("gather"):
            return _finish(name, transfer=True)
    for name in ai_units:
        if usable(name):
            return _finish(name, transfer=True)
    # 开局往往没有空闲士兵：专职没了就抢一个仍在采集的机动工人，否则 T03 无人可交。
    # `busy` 可抢（采集），`blocked`（玩家挂起）不可抢。
    for name in ai_units:
        if name in blocked:
            continue
        info = by_name.get(name) or {}
        if gone(name) or info.get("queue"):
            continue
        if not info.get("movement"):
            continue
        return _finish(name, transfer=True)
    return ""


def release_unit_for_scout_transfer(state: Dict[str, Any], unit: str) -> int:
    """专职侦察没了时，释放替代者身上的采集/机动占用，让新 scout 能发出去。

    抢占序里 scout(20) < gather(40)，不先丢掉旧采集，仲裁会把转交侦察压掉。
    """
    if not unit or not isinstance(state, dict):
        return 0
    released = 0
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict):
            continue
        if intent.get("state") not in LIVE_INTENT_STATES:
            continue
        if unit not in {str(item) for item in (intent.get("unit_ids") or [])}:
            continue
        action = str(intent.get("action", ""))
        if action not in (ACTION_GATHER, ACTION_MOVE, ACTION_HOLD, ACTION_SCOUT):
            continue
        intent["state"] = INTENT_DROPPED
        intent["drop_reason"] = "scout_executor_transfer"
        released += 1
    return released


def release_unit_for_expansion_cc(state: Dict[str, Any], unit: str) -> int:
    """分基地是当前前沿时，可把工人从采集/本地续建上拉开。"""
    if not unit or not isinstance(state, dict):
        return 0
    released = 0
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict):
            continue
        if intent.get("state") not in LIVE_INTENT_STATES:
            continue
        if unit not in {str(item) for item in (intent.get("unit_ids") or [])}:
            continue
        action = str(intent.get("action", ""))
        if action not in (ACTION_GATHER, ACTION_MOVE, ACTION_HOLD, ACTION_BUILD):
            continue
        target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
        scene = str(target.get("scene", ""))
        if action == ACTION_BUILD and "command_center" in scene:
            continue
        intent["state"] = INTENT_DROPPED
        intent["drop_reason"] = "expansion_cc_preempt"
        released += 1
    return released


def batch_from_rules(state: Dict[str, Any], *, tactical=None, rules=None,
                     ttl_ticks: int = 3600, server_tick: int = 0,
                     snapshot_id: int = 0) -> Dict[str, Any]:
    """产出保守的兜底意图批次；形状与模型输出一致，后续走同一套校验与仲裁。"""
    owned = _own_units(tactical)
    # 观测里的类型字段是 unit_type（不是 type）。**统一走唯一实现**（`observation_view`）：
    # 这里曾经手写第三份解析，少了 `constructed` 三态（就是"38 次 ProducerNotConstructed"
    # 的成因），后来又在同类问题上少了 `movement`。字段口径只允许有一处定义。
    by_name = _normalized_units(tactical)
    ai_units = [str(u) for u in (state.get("ai_controlled_units") or [])]
    busy = busy_units(state)
    tick = int(server_tick or state.get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or state.get("latest_snapshot_id", 0) or 0)
    expires = tick + max(1, int(ttl_ticks or 3600))

    intents: List[Dict[str, Any]] = []

    # 【采集与补工人**都只有一处实现**】本函数曾经自己造 `rule-gather-*` 与
    # `rule-produce-worker-*`，而 `development_intents()` 的并行填充（经济轨/生产轨）
    # 现在也会产出同一条 —— 同批次里出现两份 → 契约层直接判"intent_id 重复"并整批打回
    # （实测：`intent_batch: intents.intent_id 重复：rule-gather-Unit_2`）。
    # 动作现在**全部**由下面那一处产出（含"工地上的工人不许被抽走"、占用账、
    # 目标工人数、队列/在途去重），这里不再自建任何采集/生产意图。

    # 发展阶梯（BLD-01）：兜底**必须**包含发展动作，否则"工人全去采集"就成了死循环。
    # 放在采集/补工人之后：两者不冲突（阶梯会挑一个可被抢占的采集者）。
    intents.extend(development_intents(
        state, tactical=tactical, rules=rules, ttl_ticks=ttl_ticks,
        server_tick=tick, snapshot_id=snapshot))

    # 没有任何可判定动作时**不生成** hold：hold 对游戏侧等价于"原地不动"，
    # 本来就不需要下发；下发反而会因为模型耗时把 expires_tick 拖过期
    # （实测 `rule-hold-Unit_1` 报 "expires_tick: 命令已过期（当前 tick 120152）"），
    # 只增加拒绝噪音、干扰"失败率"统计。

    return {
        "match_id": "", "player_id": "", "plan_version": "",
        "based_on_snapshot": snapshot, "intents": intents,
    }


def _normalized_units(tactical) -> Dict[str, Dict[str, Any]]:
    """观测单位视图（**委派** `observation_view.normalized_units`，全仓唯一实现）。

    【为什么这里是薄壳而不是再写一份】本函数曾经是一份**独立副本**：
    `constructed` 三态与后来的 `movement` 字段都只加在 `observation_view` 那一份上，
    于是"同一份观测、两条路径看到不同字段"。2026-09-12 真机就因此出事：
    前探挑选单位时读不到 `movement` → 挑中炮塔这类**不会动的建筑** → `move` 被权威端
    `Rejected`（6 条）→ 扩张选址被误判成"命令连续失败"而阻塞。
    纪律：几何/观测的解析只允许 `observation_view` 一处实现，别处只能转调。
    """
    return normalized_units(tactical)


def _living_enemies(tactical) -> List[Dict[str, Any]]:
    return [e for e in _entities(tactical)
            if str(e.get("kind", "")).startswith("unit_enemy")
            and not bool(e.get("confirmed_dead"))]


def bank_a(tactical) -> int:
    """本玩家 A 资源余额（观测口径 `tactical.balance`，与 `op=tactical` 同源）。

    取不到就返回 0（按"穷局"处理）—— **宁可保守也不猜**：把未知余额当成富局会让
    规则在真没钱时乱铺工地（那正是 172 条 `NotVisible` + 采集线停摆的成因）。
    """
    raw = (tactical or {}).get("balance") if isinstance(tactical, dict) else None
    if not isinstance(raw, dict):
        return 0
    for key, value in raw.items():
        if str(key).lower() == "a":
            try:
                return int(value)
            except (TypeError, ValueError):
                return 0
    return 0


def _worker_queue_cap(bank: int, target: int, deployed: int) -> int:
    """工人"队列 + 在途"上限。

    穷局 = `WORKER_QUEUE_CAP`（计划 §三铁律：AI 不得占满生产队列，玩家订单优先）。
    富局 = **缺几个就排几个** —— 钱不缺时让指挥中心空着是纯浪费（实测余额 4 万+、
    指挥中心闲置、整局只出 3 个工人）。

    注意：富局放宽的是**数量**，不是"绕过玩家预留"（预留由 `reserves` 独立把关）。
    """
    if int(bank) >= RICH_BANK_A:
        return max(WORKER_QUEUE_CAP, int(target) - int(deployed))
    return WORKER_QUEUE_CAP


def ladder_inputs(state: Dict[str, Any], *, tactical=None, rules=None) -> Dict[str, Any]:
    """发展阶梯的**输入快照**（决策与诊断共用同一份口径）。

    为什么要单独暴露（交接教训）：离线调用 `development_intents` 能正常产出
    `barracks` build，但运行时一局 90s **一条 build 都到不了游戏**。说明断点在
    "喂给阶梯的 state"，不在算法。只有把输入打点出来，才能判定是
    (a) 压根没生成 还是 (b) 生成后被仲裁丢弃/过期 —— 否则只能反复试探
    （交接前已经因此绕了三圈）。

    返回值刻意**只含 JSON 安全的标量与字符串列表**：`GraphServices.log` 会吞掉
    序列化异常，塞进 set 就会让整行日志静默消失（与上面同一类失败模式）。
    """
    by_name = _normalized_units(tactical)
    ai_units = [str(u) for u in (state.get("ai_controlled_units") or [])]
    busy = busy_units(state)
    preemptible = set()
    live_intents: List[str] = []
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict):
            continue
        if intent.get("state") not in ("active", "pending_authority"):
            continue
        action = str(intent.get("action", ""))
        units = [str(u) for u in (intent.get("unit_ids") or [])]
        # 留痕形状："动作:状态:单位" —— 用于确认"阶梯的候选池单位是否真被占着"。
        live_intents.append("%s:%s:%s" % (action, intent.get("state"), ",".join(units)))
        if action in PREEMPTIBLE_ACTIONS:
            preemptible.update(units)

    idle_builders = [n for n in ai_units
                     if n not in busy and bool(by_name.get(n, {}).get("construct"))]
    idle_producers = [n for n in ai_units
                      if n not in busy and bool(by_name.get(n, {}).get("queue"))]
    # 逐角色抢占（不能要求两个角色同时为空，见 development_intents 的长注释）。
    if not idle_builders and preemptible:
        idle_builders = [n for n in ai_units
                         if n in preemptible
                         and bool(by_name.get(n, {}).get("construct"))]
    if not idle_producers and preemptible:
        idle_producers = [n for n in ai_units
                          if n in preemptible
                          and bool(by_name.get(n, {}).get("queue"))]

    own_types = {info["type"] for info in by_name.values() if info["type"]}
    built_types = {info["type"] for info in by_name.values()
                   if info["type"] and not info["gather"]}
    # 未完工的工地：**只有显式 constructed=False** 才算（None=未知，不当未完工，
    # 否则会把"观测没给该字段"误判成工地，导致反复派工去"施工"）。
    #
    # 【2026-09-14 修：幽灵工地】权威端已经回过 `ConstructionSiteNotFound` 的工地
    # （= 已完工/已失效，见 `placement.REJECT_SITE`）**必须移出清单**：否则阶梯 1.5
    # "有未完工工地就先续建"会短路后面所有步骤 —— 实测 a 局 `Unit_5` 从 tick 3k 挂到
    # 26k，整局不再开新工地、闲工人也用不上（玩家反馈"有建设需求但工人不去建"）。
    ledger = placement.ledger_from_state(state)
    ledger_tick = int(state.get("server_tick", 0) or 0)
    unfinished = [name for name, info in by_name.items()
                  if info["type"] and not info["gather"]
                  and info.get("constructed") is False
                  and not ledger.is_banned("rule-finish-site-%s" % name, ledger_tick)]
    # 可用于生产的设施：constructed 不是 False（None=未知仍放行，交由权威端裁决）。
    constructed_producers = [name for name, info in by_name.items()
                             if info.get("queue") and info.get("constructed") is not False]
    return {
        "observed_units": sorted(by_name.keys()),
        "ai_units": ai_units,
        "busy": sorted(busy),
        "preemptible": sorted(preemptible),
        "idle_builders": idle_builders,
        "idle_producers": idle_producers,
        "own_types": sorted(own_types),
        "built_types": sorted(built_types),
        "unfinished_buildings": unfinished,
        "constructed_producers": constructed_producers,
        "live_intents": live_intents,
        # 地图边界进诊断：落点越界曾经是"发展停摆"的头号原因（160/169 条 OutOfBounds），
        # 没有这一项就只能对着 `build_spot_blocked` 的坐标反推地图有多大。
        "map_bounds": list(state.get("map_bounds") or []),
    }


# ------------------------------------------------------- 前压方向（唯一判据）
#: 作战单位"前压"的半径硬上限（米）。**不许把部队送到地图边缘**。
ADVANCE_SAFE_RADIUS_M = 40.0
#: 前压的最小半径（米）：基地已经贴着地图内侧时要仍然往外站一点。
ADVANCE_MIN_RADIUS_M = 15.0
#: 有敌情时的逼近系数：前压距离 ≤ 最近已知敌人距离 × 本值（推进到能打，但不扎进敌群）。
ADVANCE_ENEMY_STANDOFF = 0.5
#: 航点距地图边缘的最小余量（米）。
ADVANCE_EDGE_MARGIN_M = 10.0
#: 无情报时的前压半径系数：不超过"基地到最近地图边"的一半。
ADVANCE_EDGE_FACTOR = 0.5


##: 【小部队快打】没有**可见**敌人时，用"上次见过的敌方情报点"当前压目标（用户 2026-09-14：
##: "AI 副官可以高频操作，那就没必要集结大部队，按小部队快速集结后就可以行动了"）。
##: 为什么必须用它：旧口径在没情报时只推地图中心、半径上限 40m —— 部队整局在家门口转圈，
##: 实测一局攒到 **36 个作战单位、可见敌人 0**、全程只有前压命令（= 玩家眼里的"攒兵不打"）。
##: 已经侦察到的敌方单位（`strategic.enemy_intel`）是**合法的公开情报**，不用它就等于装作没看见。
##: 无任何情报且小队成形时，允许**更大搜索半径**（去找人打），仍受地图边缘余量与硬上限约束。
ADVANCE_SEARCH_RADIUS_M = 90.0
ADVANCE_SEARCH_ENEMY_STANDOFF = 0.6
##: 【小部队快打】"小队成形"的最小兵力（作战单位数）：到它就允许主动出击 + 允许远距搜索。
##: 与 `campaign.SQUAD_ACTION_MIN` **同一口径**（那边直接引用这里，不许各写一份数字）。
SQUAD_ACTION_MIN = 2


def military_waypoint(base, *, bounds=None, enemies=(), ring: int = 1,
                      bearing=None, max_radius=None, intel=(), search=False,
                      state=None, unit: str = ""
                      ) -> Optional[List[float]]:
    """作战单位"往哪前压"的**唯一方向判据**（行为树与并行填充共用）。

    ## 用户实测问题（2026-09-12）
    部队按罗盘方位一圈圈往外走（步长 25m、上限 120m）—— 实际效果就是**把兵送到地图边缘**；
    实战途中遇敌被逐个击破（"这样很危险，中途都会遇到敌人的"）。

    ## 三条硬约束（取代"罗盘均匀撒"）
    1. **方向有依据**：有已知敌情 → 朝**最近敌人**方向；没有敌情 → 朝**地图中心**
       （那里通常才是交战区/要道；地图边缘是死角，占了也没价值）。
    2. **不越过交战线**：有敌情时半径 ≤ 最近敌人距离 × `ADVANCE_ENEMY_STANDOFF`。
    3. **不离地图内侧**：半径 ≤ `ADVANCE_SAFE_RADIUS_M`，且不超过"基地到最近地图边"
       的一半；落点再按 `ADVANCE_EDGE_MARGIN_M` 内缩。

    返回 `[x, z]`；**没有任何依据时返回 None**（宁可不发，也不乱派一路兵出去）。
    """
    if not base or len(base) < 2:
        return None
    try:
        base_x, base_z = float(base[0]), float(base[1])
    except (TypeError, ValueError):
        return None
    has_bounds = isinstance(bounds, (list, tuple)) and len(bounds) >= 2 \
        and float(bounds[0]) > 0 and float(bounds[1]) > 0
    size_x, size_z = (float(bounds[0]), float(bounds[1])) if has_bounds else (0.0, 0.0)
    # 硬上限：配置给的上限与安全上限取小（安全上限永远是赢家，配置只能更保守）。
    hard_radius = ADVANCE_SAFE_RADIUS_M
    try:
        if max_radius and float(max_radius) > 0:
            hard_radius = min(ADVANCE_SAFE_RADIUS_M, float(max_radius))
    except (TypeError, ValueError):
        hard_radius = ADVANCE_SAFE_RADIUS_M
    # ---- 1. 方向与"推进到哪"（三种依据，按优先级）----
    #   ① 可见敌人（实时事实）；② **上次见过的敌情**（公开情报，可能已不在视野里）；
    #   ③ 什么都没有 → 朝地图中心；`search=True`（小队已成形）时放宽半径，**去找人打**。
    # 半径上限：默认 40m；一旦要"够到情报点"或处于搜索态，放宽到 ADVANCE_SEARCH_RADIUS_M
    # （仍受地图边缘余量约束，绝不会把部队送到边缘）。
    limit_radius = max(hard_radius, ADVANCE_SEARCH_RADIUS_M) if search else hard_radius
    nearest: Optional[Tuple[float, float, float]] = None
    for enemy in enemies or ():
        point = _pos2d(enemy)
        distance = math.hypot(float(point[0]) - base_x, float(point[1]) - base_z)
        if nearest is None or distance < nearest[0]:
            nearest = (distance, float(point[0]), float(point[1]))
    from_intel = False
    if nearest is None:
        # 没有可见敌人 → 退一步用"上次见过的敌情"（公开情报，不是全局视野）。
        for item in intel or ():
            point = _pos2d(item)
            if not point:
                continue
            distance = math.hypot(float(point[0]) - base_x, float(point[1]) - base_z)
            if distance <= 1e-3:
                continue
            if nearest is None or distance < nearest[0]:
                nearest = (distance, float(point[0]), float(point[1]))
        from_intel = nearest is not None
    if nearest is not None:
        if nearest[0] <= 1e-3:
            return None
        direction = (nearest[1] - base_x, nearest[2] - base_z)
        # 【多方向铺开】朝敌人的**大方向**不变，按"圈号"给一个交替的小角度偏置：
        # 调用方按单位序号分批给 ring（`1 + index // 4`，每 4 个单位一环），
        # 相邻两环分向两侧 → 部队铺成"朝敌人的扇形"，而不是一条纵队挤在同一目标上
        #（2026-09-15 用户要求"拆成多个小队、前往不同方向/不同接触区域"）。
        # 角度固定 ±18°：仍在"朝最近敌人"这条依据之内（不是凭空撒点）；
        # 半径与边界约束（下面的 `radius_cap`）一律不变。
        # 【2026-09-15 用户："副官只会派部队直线进攻，要能绕路指挥侧边进攻"】
        # 原实现只给 ±18° 微散开 —— 那只是"别挤在同一个点"，观感仍是**朝敌人直线平推**。
        # 改为**档位化侧翼角**：正面（ring 0/1）保留"最近敌人"这条依据不变；
        # ring≥2 起向两翼明显张开（±45° → ±70° → ±90°），让后续批次真的从**侧边**压上，
        # 而不是所有单位走同一条直线。半径与边界约束（`radius_cap` 之后的分支）一律不变。
        if int(ring) > 1:
            flank_steps = (45.0, 70.0, 90.0)
            step = flank_steps[min((int(ring) - 2) // 2, len(flank_steps) - 1)]
            angle = math.radians(step if int(ring) % 2 == 0 else -step)
            cos_a, sin_a = math.cos(angle), math.sin(angle)
            dir_x, dir_z = direction
            direction = (dir_x * cos_a - dir_z * sin_a,
                         dir_x * sin_a + dir_z * cos_a)
        # 情报点（非实时）→ 要真的走过去，站位比"看得见时"更靠前。
        standoff = ADVANCE_SEARCH_ENEMY_STANDOFF if from_intel else ADVANCE_ENEMY_STANDOFF
        if from_intel:
            limit_radius = max(limit_radius, ADVANCE_SEARCH_RADIUS_M)
        radius_cap = min(limit_radius, nearest[0] * standoff)
    elif has_bounds:
        # 【U1/F01】没有敌情/情报时，用**探索前沿 + 访问记忆**选点（不再是一个固定坐标）。
        # 审查 F01 实测：旧口径 ring 取 1/2/3/5/10/100 都返回同一个点，部队到了以后
        # 继续收到同一个目标 —— 没有"推进"也没有"去过哪"的记忆。
        unit_type = ""
        if isinstance(state, dict):
            unit_type = str((state.get("own_unit_types") or {}).get(str(unit), ""))
        # 只有专职侦察（或单测未标类型）才写入探索记忆。作战单位前压只读已覆盖格，
        # 不得改写 `current` —— 否则士兵一调用就把无人机的到达结算冲掉
        # （`u1t01d`：无人机停在 [17.5,17.5]，covered 却被地面到达刷到 4）。
        commit = (not unit_type) or unit_type in PROBE_TYPES
        frontier = explore_frontier(state, base, bounds, unit=str(unit), intel=intel,
                                    ring=ring, commit=commit)
        if frontier:
            return list(frontier["point"])
        direction = (size_x / 2.0 - base_x, size_z / 2.0 - base_z)
        if math.hypot(*direction) < 1e-3:
            direction = tuple(bearing) if bearing else (1.0, 0.0)
        # 无情报时不越过"基地到最近地图边"的一半 —— 直接禁止"派往地图边缘"；
        # 搜索态放宽系数（但仍不越过边缘余量），否则"没情报"= 永远在家门口转圈。
        edge_distance = min(base_x, base_z, size_x - base_x, size_z - base_z)
        edge_cap = edge_distance * (ADVANCE_SEARCH_ENEMY_STANDOFF if search
                                    else ADVANCE_EDGE_FACTOR)
        radius_cap = min(limit_radius, max(ADVANCE_MIN_RADIUS_M, edge_cap))
    elif bearing:
        direction = (float(bearing[0]), float(bearing[1]))
        radius_cap = min(limit_radius,
                         max(ADVANCE_MIN_RADIUS_M, ADVANCE_MIN_RADIUS_M * max(1, int(ring))))
    else:
        return None
    length = math.hypot(direction[0], direction[1])
    if length < 1e-3:
        return None
    radius = min(limit_radius,
                 max(ADVANCE_MIN_RADIUS_M, ADVANCE_MIN_RADIUS_M * max(1, int(ring))),
                 radius_cap)
    point = [base_x + direction[0] / length * radius,
             base_z + direction[1] / length * radius]
    if has_bounds:
        point[0] = min(max(point[0], ADVANCE_EDGE_MARGIN_M), size_x - ADVANCE_EDGE_MARGIN_M)
        point[1] = min(max(point[1], ADVANCE_EDGE_MARGIN_M), size_z - ADVANCE_EDGE_MARGIN_M)
    return [round(point[0], 1), round(point[1], 1)]


# ------------------------------------------------------------------ 探索前沿（U1/F01）
#: 探索前沿网格边长（米）：把地图切成格，**格中心**是候选前沿。
#: 24m ≈ 2×`VISION_SAFE_RADIUS`…… 这个尺度是为"一次移动就能带来新增视野"选的：
#: 太小会让部队在家门口来回；太大则单跳距离过远、中途遇敌就白跑。
EXPLORE_CELL_M = 24.0
#: 判定"已到达某前沿"的半径（米）：单位进到这个范围内就记 `covered` 并换下一个前沿。
EXPLORE_REACHED_M = 8.0
#: 同一前沿连续失败上限：达到就记 `unreachable` 并换目标（**退避**，不是无限重试）。
EXPLORE_MAX_FAILURES = 3
#: 访问记忆容量（格数，有界）：超出时丢最早的一条，防长局无限增长。
EXPLORE_MEMORY_LIMIT = 128
#: 临时条件：网格不可用 / 查询超时 / 未接线 / 版本过期 / 版本 0。
#: 这类失败**立刻换目标或等待**，不累计成永久 `unreachable`（T02：恢复后还要能继续）。
EXPLORE_WAIT_REASONS = frozenset({
    "navmesh_unavailable", "nav_timeout", "nav_query_unwired", "stale_nav_revision",
})
#: 真正的路径失败（两点不连通 / 退化路径）。累计到上限才标 `unreachable`。
EXPLORE_FAIL_REASONS = frozenset({"path_failed", "no_path", "path_too_short"})
#: 空中单位类型（规则视图缺失时的移动域兜底，与 `squads.SQUAD_AIR_TYPES` 同口径）。
AIR_UNIT_TYPES = ("drone", "helicopter", "scout")
#: 基地回防半径：唯一口径在 `campaign.DEFENSE_RADIUS_M`（手册 DEF-01）。
DEFENSE_RADIUS_M = campaign_mod.DEFENSE_RADIUS_M
#: 家里没人时最多召回的最近作战单位数。唯一口径在 `campaign.DEFEND_RECALL_MAX`。
DEFEND_RECALL_MAX = campaign_mod.DEFEND_RECALL_MAX


def base_under_attack_active(state: Optional[Dict[str, Any]]) -> bool:
    """整局主线里是否有活跃的 `base_under_attack`。

    中断栈是权威；路上偶遇敌人不走这里。真机事件名由 `campaign._note_base_raid`
    从「建筑附近见敌 / 建筑掉血」合成。
    """
    campaign = (state or {}).get("campaign_state")
    if not isinstance(campaign, dict):
        return False
    for entry in campaign.get("interrupt_stack") or []:
        if not isinstance(entry, dict):
            continue
        if (str(entry.get("kind", "")) == "base_under_attack"
                and str(entry.get("status", "")) == "active"):
            return True
    return False


def _home_structure_points(by_name) -> List[Tuple[float, float]]:
    points: List[Tuple[float, float]] = []
    seen = set()
    for info in (by_name or {}).values():
        kind = str((info or {}).get("type") or "")
        if not ((info or {}).get("queue")
                or any(token in kind for token in _STRUCTURE_TYPE_HINTS)):
            continue
        pos = _pos2d(info)
        if not pos:
            continue
        key = (round(float(pos[0]), 1), round(float(pos[1]), 1))
        if key in seen:
            continue
        seen.add(key)
        points.append(pos)
    return points


def defense_home_pos(by_name):
    """回防落点：指挥中心优先，没有就用最近的己方建筑。"""
    anchor = base_anchor_pos(by_name)
    if anchor:
        return anchor
    points = _home_structure_points(by_name)
    return points[0] if points else None


def home_raid_visible(by_name, enemies, radius: float = DEFENSE_RADIUS_M) -> bool:
    """己方建筑附近有可见敌人。路上偶遇（远离建筑）不算基地受袭。"""
    homes = _home_structure_points(by_name)
    if not homes:
        return False
    reach = float(radius)
    for enemy in enemies or ():
        pos = _pos2d(enemy)
        if not pos:
            continue
        for home in homes:
            if math.hypot(pos[0] - home[0], pos[1] - home[1]) <= reach:
                return True
    return False


def defending_home_now(state: Optional[Dict[str, Any]], by_name=None,
                       enemies=()) -> bool:
    """这一轮要不要按基地受袭指挥：中断栈，或眼前就能看见建筑被摸。"""
    if base_under_attack_active(state):
        return True
    return home_raid_visible(by_name or {}, enemies)


def defense_recall_names(combat_names, by_name, base,
                         quota: Optional[int] = None) -> List[str]:
    """基地受袭时要召回的野外作战单位。

    已在回防圈内的人不进名单。圈内人数已达配额 → 空名单（远处线不召回）。
    家里没人 → 按距基地从近到远补满 `min(配额, 作战单位总数)`。
    """
    names = [str(name) for name in (combat_names or []) if str(name)]
    if not names or not base:
        return []
    cap = DEFEND_RECALL_MAX if quota is None else max(0, int(quota))
    near: List[str] = []
    field: List[Tuple[str, float]] = []
    for name in names:
        pos = _pos2d((by_name or {}).get(name) or {})
        if not pos:
            continue
        if unit_near_base(pos, base):
            near.append(name)
            continue
        field.append((name, math.hypot(pos[0] - float(base[0]),
                                       pos[1] - float(base[1]))))
    need = min(max(1, cap), len(near) + len(field))
    if len(near) >= need:
        return []
    field.sort(key=lambda item: item[1])
    return [name for name, _dist in field[:need - len(near)]]


def unit_near_base(unit_pos, base, radius: float = DEFENSE_RADIUS_M) -> bool:
    """单位是否在基地回防圈内。坐标一律 [x, z]。"""
    if not unit_pos or not base:
        return False
    try:
        return math.hypot(float(unit_pos[0]) - float(base[0]),
                          float(unit_pos[1]) - float(base[1])) <= float(radius)
    except (TypeError, ValueError, IndexError):
        return False


#: 队形散开：成员离小队中心超过这个半径（米）就该前线快集结。
#: 略小于 `squads.CLUSTER_SIZE`（20），避免“刚编进一队仍被判散开”。
SCATTER_RADIUS_M = 18.0
#: 前线集结点距主基地的最小距离（米）。小于它就等于回家门口。
FORWARD_RALLY_MIN_FROM_BASE_M = 25.0
#: 落点离主基地至少这么远（米），撤退/集结都不得踩在指挥中心上。
FORWARD_RALLY_HOME_CLEAR_M = 12.0
#: 脱离一步的默认距离（米）。
DISENGAGE_STEP_M = 20.0


def _xz_of(item) -> Optional[Tuple[float, float]]:
    """把 dict / [x,z] / [x,y,z] 收成平面坐标。

    行为树的 `enemy_facts.pos` 已经是 `[x, z]`；观测实体是 `[x, y, z]`。
    两种都要认，否则撤离会把敌人误读到原点。
    """
    if item is None:
        return None
    raw = item.get("pos") if isinstance(item, dict) else item
    if not isinstance(raw, (list, tuple)) or len(raw) < 2:
        return None
    try:
        if len(raw) >= 3:
            return (float(raw[0]), float(raw[2]))
        return (float(raw[0]), float(raw[1]))
    except (TypeError, ValueError):
        return None


def _field_combat_points(positions, home) -> List[Tuple[float, float]]:
    """野外作战单位坐标。家里的兵不参与前线点/散开判定，免得把集结点拽回家。"""
    points: List[Tuple[float, float]] = []
    for item in positions or ():
        point = _xz_of(item)
        if point is not None:
            points.append(point)
    home_xz = _xz_of(home)
    if home_xz is None or not points:
        return points
    outside = [item for item in points
               if math.hypot(item[0] - home_xz[0],
                             item[1] - home_xz[1]) > DEFENSE_RADIUS_M]
    return outside or points


def combat_scattered(positions, radius: float = SCATTER_RADIUS_M, *,
                     home=None) -> bool:
    """野外作战单位离小队中心过远 → 队形散开。

    只看**已经离开主基地回防圈**的人。家里留人 + 野外一人，不算散开
    （否则野外那人会被拽回被家里兵拉歪的中点）。单兵不算散开。
    """
    points = _field_combat_points(positions, home)
    if len(points) < 2:
        return False
    center_x = sum(item[0] for item in points) / len(points)
    center_z = sum(item[1] for item in points) / len(points)
    threshold = max(1.0, float(radius) * 0.5)
    return any(math.hypot(item[0] - center_x, item[1] - center_z) > threshold
               for item in points)


def _nudge_off_home(point, base, *,
                    min_clear: float = FORWARD_RALLY_HOME_CLEAR_M
                    ) -> Optional[List[float]]:
    """若落点贴着主基地，沿离开方向推到 `min_clear`。"""
    if not point or len(point) < 2:
        return None
    if not base or len(base) < 2:
        return [round(float(point[0]), 1), round(float(point[1]), 1)]
    try:
        px, pz = float(point[0]), float(point[1])
        bx, bz = float(base[0]), float(base[1])
        clear = max(1.0, float(min_clear))
    except (TypeError, ValueError):
        return [round(float(point[0]), 1), round(float(point[1]), 1)]
    distance = math.hypot(px - bx, pz - bz)
    if distance >= clear:
        return [round(px, 1), round(pz, 1)]
    if distance < 1e-3:
        return [round(bx + clear, 1), round(bz, 1)]
    scale = clear / distance
    return [round(bx + (px - bx) * scale, 1), round(bz + (pz - bz) * scale, 1)]


def _nearest_aim(origin: Tuple[float, float], candidates) -> Optional[Tuple[float, float, float]]:
    best: Optional[Tuple[float, float, float]] = None
    for item in candidates or ():
        point = _xz_of(item)
        if point is None:
            continue
        distance = math.hypot(point[0] - origin[0], point[1] - origin[1])
        if distance <= 1e-3:
            continue
        if best is None or distance < best[0]:
            best = (distance, point[0], point[1])
    return best


def forward_rally_point(base=None, *, bounds=None, intel=(), enemies=(),
                        combat_positions=()) -> Optional[List[float]]:
    """前线集结点（决策地图 ATK-01 / ADV-01 / REG-01 的唯一选点）。

    优先级：可见敌人 / 上次敌情 → 小队中心（已离开主基地）→ 地图中心。
    **绝不返回主基地坐标。** 没有方向依据时返回 None，由调用方决定不发。
    """
    origin: Optional[Tuple[float, float]] = None
    base_xz = _xz_of(base)
    combat_pts = _field_combat_points(combat_positions, base_xz)
    if combat_pts:
        origin = (sum(p[0] for p in combat_pts) / len(combat_pts),
                  sum(p[1] for p in combat_pts) / len(combat_pts))
    if origin is None and base_xz is not None:
        origin = base_xz
    if origin is None:
        return None

    nearest = _nearest_aim(origin, enemies) or _nearest_aim(origin, intel)
    has_bounds = isinstance(bounds, (list, tuple)) and len(bounds) >= 2
    try:
        size_x = float(bounds[0]) if has_bounds else 0.0
        size_z = float(bounds[1]) if has_bounds else 0.0
        has_bounds = size_x > 0.0 and size_z > 0.0
    except (TypeError, ValueError):
        has_bounds = False
        size_x = size_z = 0.0

    aim: Optional[Tuple[float, float]] = None
    radius = FORWARD_RALLY_MIN_FROM_BASE_M
    if nearest is not None:
        aim = (nearest[1], nearest[2])
        radius = max(FORWARD_RALLY_MIN_FROM_BASE_M,
                     min(ADVANCE_SEARCH_RADIUS_M,
                         nearest[0] * ADVANCE_SEARCH_ENEMY_STANDOFF))
    elif has_bounds:
        aim = (size_x / 2.0, size_z / 2.0)
        toward = math.hypot(aim[0] - origin[0], aim[1] - origin[1])
        radius = max(FORWARD_RALLY_MIN_FROM_BASE_M,
                     min(ADVANCE_SEARCH_RADIUS_M, toward * 0.5 if toward else
                         FORWARD_RALLY_MIN_FROM_BASE_M))
    elif combat_pts and base_xz is not None:
        if math.hypot(origin[0] - base_xz[0],
                      origin[1] - base_xz[1]) >= FORWARD_RALLY_MIN_FROM_BASE_M:
            return _nudge_off_home([origin[0], origin[1]], base_xz,
                                   min_clear=FORWARD_RALLY_MIN_FROM_BASE_M)
        return None
    else:
        return None

    dx, dz = aim[0] - origin[0], aim[1] - origin[1]
    length = math.hypot(dx, dz)
    if length < 1e-3:
        return _nudge_off_home([origin[0], origin[1]], base_xz,
                               min_clear=FORWARD_RALLY_MIN_FROM_BASE_M)
    point = [origin[0] + dx / length * radius, origin[1] + dz / length * radius]
    if has_bounds:
        point[0] = min(max(point[0], ADVANCE_EDGE_MARGIN_M),
                       size_x - ADVANCE_EDGE_MARGIN_M)
        point[1] = min(max(point[1], ADVANCE_EDGE_MARGIN_M),
                       size_z - ADVANCE_EDGE_MARGIN_M)
    return _nudge_off_home(point, base_xz,
                           min_clear=FORWARD_RALLY_MIN_FROM_BASE_M)


def _clamp_to_bounds(point: List[float], bounds) -> List[float]:
    if not (isinstance(bounds, (list, tuple)) and len(bounds) >= 2):
        return point
    try:
        size_x, size_z = float(bounds[0]), float(bounds[1])
    except (TypeError, ValueError):
        return point
    if size_x <= 0.0 or size_z <= 0.0:
        return point
    return [min(max(point[0], ADVANCE_EDGE_MARGIN_M), size_x - ADVANCE_EDGE_MARGIN_M),
            min(max(point[1], ADVANCE_EDGE_MARGIN_M), size_z - ADVANCE_EDGE_MARGIN_M)]


def disengage_point(unit_pos, *, home=None, enemies=(), bounds=None,
                    step: float = DISENGAGE_STEP_M) -> Optional[List[float]]:
    """撤离落点：远离最近敌人；可掺主基地方向，但不得落在主基地上。

    贴边夹紧之后若把"远离敌人"反过来了，改试垂直方向，避免被推去敌人那边。
    """
    origin = _xz_of(unit_pos)
    if origin is None:
        return None
    home_xz = _xz_of(home)
    nearest = _nearest_aim(origin, enemies)
    ux, uz = origin
    if nearest is None:
        if home_xz is None:
            return None
        dx, dz = home_xz[0] - ux, home_xz[1] - uz
        length = math.hypot(dx, dz)
        if length < 1e-3:
            return _nudge_off_home([ux, uz], home_xz)
        travel = min(float(step), max(0.0, length - FORWARD_RALLY_HOME_CLEAR_M))
        return _nudge_off_home(_clamp_to_bounds(
            [ux + dx / length * travel, uz + dz / length * travel], bounds), home_xz)

    away_x, away_z = ux - nearest[1], uz - nearest[2]
    away_len = math.hypot(away_x, away_z) or 1.0
    away = (away_x / away_len, away_z / away_len)
    directions: List[Tuple[float, float]] = [away, (-away[1], away[0]), (away[1], -away[0])]
    if home_xz is not None:
        hx, hz = home_xz[0] - ux, home_xz[1] - uz
        home_len = math.hypot(hx, hz)
        if home_len > 1e-3:
            hx, hz = hx / home_len, hz / home_len
            if hx * away[0] + hz * away[1] > -0.2:
                mixed = (away[0] + hx, away[1] + hz)
                norm = math.hypot(*mixed) or 1.0
                directions.insert(1, (mixed[0] / norm, mixed[1] / norm))

    best: Optional[List[float]] = None
    best_dist = -1.0
    for dx, dz in directions:
        candidate = _nudge_off_home(_clamp_to_bounds(
            [ux + dx * float(step), uz + dz * float(step)], bounds), home_xz)
        if not candidate:
            continue
        dist = math.hypot(candidate[0] - nearest[1], candidate[1] - nearest[2])
        if dist <= nearest[0] + 0.5:
            continue
        if dist > best_dist:
            best, best_dist = candidate, dist
    if best is not None:
        return best
    # 所有方向夹紧后都没更远：仍给一个不踩主基地的点，让闸门去判能不能走。
    return _nudge_off_home(_clamp_to_bounds(
        [ux + away[0] * float(step), uz + away[1] * float(step)], bounds), home_xz)


def explore_frontier(state: Dict[str, Any], base, bounds, *, unit: str = "",
                     intel=(), ring: int = 1, commit: bool = True
                     ) -> Optional[Dict[str, Any]]:
    """选一个**尚未覆盖**的探索前沿（带访问记忆、失败退避；确定性）。

    ## 为什么必须替换旧口径（审查 F01）
    旧实现没有敌情/情报时是**纯几何**：方向朝地图中心、半径被"基地到最近边"卡死，
    于是 ring 取任何值都返回同一个坐标。部队到了以后继续收到同一个目标 ——
    没有"推进"，也没有"去过哪"的记忆（`archive_5d6cdb0e` 侦察覆盖恒 0.0）。

    ## 区域状态（计划 U1 要求）
    - **未探**：不在记忆里 → 候选；
    - **已覆盖 `covered`**：单位进到格心 `EXPLORE_REACHED_M` 内（用既有路线事实判定：
      `routes[unit].invalidated_reason == "arrived"`，**不新增埋点**）；
    - **暂不可达 `unreachable`**：同一前沿连续失败 `EXPLORE_MAX_FAILURES` 次（路径失败类）
      → 换目标；记忆有界（`EXPLORE_MEMORY_LIMIT`）。
    - **等待有效条件 `waiting`**：`navmesh_unavailable` / 查询超时等临时断路
      → **立刻释放指派并换目标**，网格版本变化后把该格重新打开，禁止永久 `no_path`。
      `nav_revision=0` 是合法首版，单独出现不得标 waiting。
    重访**必须有理由**：当前实现只在"无可用前沿"时返回最后一个已覆盖格（并标 `reason=revisit`），
    否则宁可返回 None（宁可不发，也不给固定点）。

    ## 选择顺序（确定性）
    有情报 → 先朝**情报点**方向（"朝上次见过敌人的方向"探索）；
    否则 → 距基地**由近到远**（先把家周围覆盖干净，再逐圈外推）。

    `commit=False`：只读已覆盖格选一个点（给前压用），**不改** `current` / `assigned` /
    `selected`。作战单位与侦察共用函数但不能共用"当前前沿"指针。
    """
    if not placement.has_bounds(bounds):
        return None
    base_x, base_z = float(base[0]), float(base[1])
    # 没有状态（旧调用点/单测）时用一个**临时**记忆：仍然按 `ring` 取不同的格，
    # 这样"ring 取任何值都返回同一坐标"的旧缺陷在**函数级**也不复现（审查 F01 的判据）。
    scratch: Dict[str, Any] = {}
    memory: Dict[str, Any] = state.setdefault("explore", {}) if isinstance(state, dict) else scratch
    cells: Dict[str, Dict[str, Any]] = memory.setdefault("cells", {})
    assigned: Dict[str, str] = memory.setdefault("assigned", {})
    # --- ① 网格恢复后，把等待格重新打开（T02：不能永久 no_path）---
    _reopen_waiting_explore(cells, state if isinstance(state, dict) else {})
    # --- ② 用**本单位自己的指派**结算到达 / 失败（禁止看全局 current）---
    if commit and unit:
        _settle_explore_assignment(memory, cells, assigned, state, str(unit), bounds)
    # --- ② 淘汰记忆（有界） ---
    while len(cells) > EXPLORE_MEMORY_LIMIT:
        cells.pop(next(iter(cells)))
    # 未到达前保持本单位已指派的前沿（不抖、不刷 selected）。
    if commit and unit:
        held = str(assigned.get(str(unit), "") or "")
        held_entry = cells.get(held) or {}
        if held and str(held_entry.get("state", "open")) == "open":
            point = _cell_center_from_key(held, bounds)
            if point:
                memory["current"] = held
                return {
                    "point": point, "cell": held, "reason": "hold_assigned",
                    "covered": sum(1 for item in cells.values() if item.get("state") == "covered"),
                    "unreachable": sum(1 for item in cells.values()
                                       if item.get("state") == "unreachable"),
                }
    # --- ③ 候选排序 ---
    grid_x, grid_z, _usable_x, _usable_z, _margin = _explore_grid(bounds)
    # 情报点有两种形状，都要认：`state["enemy_intel_points"]` 是 `[[x, z], …]`（列表），
    # 而实体字典走 `_pos2d`。**只认一种会让情报在这条路上静默失效**（实测踩到）。
    intel_points = []
    for item in (intel or ()):
        if isinstance(item, (list, tuple)) and len(item) >= 2:
            intel_points.append((float(item[0]), float(item[1])))
        else:
            point = _pos2d(item)
            if point:
                intel_points.append(point)
    base_cell = _cell_key_of_point(base_x, base_z, bounds)
    taken = {str(cell) for cell in assigned.values() if cell}
    if unit:
        taken.discard(str(assigned.get(str(unit), "") or ""))
    candidates: List[Tuple[float, float, str, List[float]]] = []
    for ix in range(grid_x):
        for iz in range(grid_z):
            point = _cell_center(ix, iz, bounds)
            key = "%d,%d" % (ix, iz)
            entry = cells.get(key) or {}
            if str(entry.get("state", "")) in ("covered", "unreachable"):
                continue
            if str(entry.get("state", "")) == "waiting":
                continue
            if commit and key in taken:
                continue
            distance_base = math.hypot(point[0] - base_x, point[1] - base_z)
            if distance_base <= EXPLORE_REACHED_M and key == base_cell:
                # 出发格不算前沿（它已经被"我们在这里"覆盖），只记一次。
                if commit:
                    cells[base_cell] = {"state": "covered", "tick": 0, "visits": 1,
                                        "role": "base"}
                continue
            if intel_points:
                distance_intel = min(math.hypot(point[0] - p[0], point[1] - p[1])
                                     for p in intel_points)
            else:
                distance_intel = distance_base
            candidates.append((distance_intel, distance_base, key, point))
    if not candidates:
        # 没有可推进的前沿：**宁可不发**（返回 None），调用方会退回几何兜底。
        return None
    candidates.sort(key=lambda item: (round(item[0], 3), round(item[1], 3), item[2]))
    # `ring` 是**候选序号偏移**（同一轮里不同单位各自去不同的前沿；也让无记忆调用的
    # `ring=1..N` 得到不同结果）。取模保证永远落在候选表内。
    index = (max(1, int(ring)) - 1) % len(candidates)
    distance_intel, _distance_base, key, point = candidates[index]
    reason = "toward_intel" if intel_points and distance_intel < 1e9 else "nearest_unvisited"
    if commit:
        if unit:
            assigned[str(unit)] = key
        if str(memory.get("current", "")) != key:
            memory["selected"] = int(memory.get("selected", 0) or 0) + 1
        memory["current"] = key
        entry = cells.setdefault(key, {"state": "open", "visits": 0})
        entry["state"] = "open"
    return {
        "point": point, "cell": key, "reason": reason,
        "covered": sum(1 for item in cells.values() if item.get("state") == "covered"),
        "unreachable": sum(1 for item in cells.values() if item.get("state") == "unreachable"),
    }


def _settle_explore_assignment(memory: Dict[str, Any], cells: Dict[str, Dict[str, Any]],
                               assigned: Dict[str, str], state: Dict[str, Any],
                               unit: str, bounds) -> None:
    """按**该单位自己的指派格**结算到达/失败；全局 `current` 不再参与判定。"""
    mine = str(assigned.get(unit, "") or "")
    if not mine:
        # 兼容旧档案：还没有 assigned 时退回 current（仅当本单位路线目标就是那一格）。
        mine = str(memory.get("current", "") or "")
    if not mine:
        return
    previous = _previous_route_for_explore(state, unit)
    target = [float(v) for v in (previous.get("target") or []) if isinstance(v, (int, float))]
    if not target or _cell_key_of_point(target[0], target[1], bounds) != mine:
        return
    invalidated = str(previous.get("invalidated_reason", "") or "")
    route_reason = str(previous.get("reason", "") or "")
    reason = invalidated or route_reason
    if not reason and not previous.get("ok"):
        reason = "path_failed"
    if invalidated == "arrived":
        cells[mine] = {"state": "covered",
                       "tick": int(previous.get("arrived_tick", 0) or 0),
                       "visits": int((cells.get(mine) or {}).get("visits", 0)) + 1,
                       "by": unit, "role": "scout"}
        assigned.pop(unit, None)
        return
    if not (invalidated or not previous.get("ok") or reason):
        return
    entry = cells.setdefault(mine, {"state": "open", "visits": 0})
    entry["last_fail"] = reason
    nav_rev = _explore_nav_revision(state)
    if reason in EXPLORE_WAIT_REASONS:
        # 临时断路：立刻换目标，格标 waiting。`nav_revision=0` 是合法首版，
        # 不许当成"未烘焙"（真机 `u1t02a` 全程 revision=0 但无人机在飞）。
        entry["state"] = "waiting"
        entry["wait_reason"] = reason
        entry["wait_revision"] = nav_rev
        assigned.pop(unit, None)
        return
    entry["fails"] = int(entry.get("fails", 0)) + 1
    if entry["fails"] >= EXPLORE_MAX_FAILURES:
        entry["state"] = "unreachable"
        assigned.pop(unit, None)


def _explore_nav_revision(state: Optional[Dict[str, Any]]) -> int:
    """当前导航网格版本。0 是合法值（未烘焙），不许写成 `value or -1`。"""
    raw = (state or {}).get("nav_revision", -1)
    if raw is None:
        return -1
    try:
        return int(raw)
    except (TypeError, ValueError):
        return -1


def _reopen_waiting_explore(cells: Dict[str, Dict[str, Any]],
                            state: Dict[str, Any]) -> None:
    """网格恢复后重新打开 waiting 格。

    恢复条件：当前 `nav_revision` 与记下的 `wait_revision` **不同**
    （0→正数、重烘换版本）。同一版本上的临时失败不立刻重试同一格。
    0 是合法首版，不许写成 `rev<=0 就跳过`。
    """
    rev = _explore_nav_revision(state)
    for entry in cells.values():
        if not isinstance(entry, dict) or str(entry.get("state", "")) != "waiting":
            continue
        raw_waited = entry.get("wait_revision", -1)
        try:
            waited = int(-1 if raw_waited is None else raw_waited)
        except (TypeError, ValueError):
            waited = -1
        if waited != rev:
            entry["state"] = "open"
            entry["fails"] = 0
            entry.pop("wait_reason", None)


def _cell_center_from_key(key: str, bounds) -> Optional[List[float]]:
    parts = str(key).split(",")
    if len(parts) != 2:
        return None
    try:
        return _cell_center(int(parts[0]), int(parts[1]), bounds)
    except (TypeError, ValueError):
        return None


def _explore_grid(bounds) -> Tuple[int, int, float, float, float]:
    """探索网格：`(格数x, 格数z, 可用宽, 可用高, 边缘余量)`。

    **网格建在"可用区"里**（地图减掉边缘余量），而不是建在整张地图上再逐点夹取 ——
    后者会让贴边的好几格被夹到同一个坐标（实测 `[40,12]` 重复出现），
    于是"换了前沿"在坐标上根本看不出来（T01 要的是**不同可达前沿**）。
    """
    size_x, size_z = float(bounds[0]), float(bounds[1])
    margin = float(ADVANCE_EDGE_MARGIN_M)
    usable_x = max(1.0, size_x - 2.0 * margin)
    usable_z = max(1.0, size_z - 2.0 * margin)
    grid_x = max(1, int(math.ceil(usable_x / EXPLORE_CELL_M)))
    grid_z = max(1, int(math.ceil(usable_z / EXPLORE_CELL_M)))
    return grid_x, grid_z, usable_x, usable_z, margin


def _cell_key_of_point(x: float, z: float, bounds) -> str:
    """点 → 所在探索格的键（与 `_cell_center` 同一网格/同一映射）。"""
    grid_x, grid_z, usable_x, usable_z, margin = _explore_grid(bounds)
    ix = min(grid_x - 1, max(0, int((float(x) - margin) / max(1e-6, usable_x / grid_x))))
    iz = min(grid_z - 1, max(0, int((float(z) - margin) / max(1e-6, usable_z / grid_z))))
    return "%d,%d" % (ix, iz)


def _cell_center(ix: int, iz: int, bounds) -> List[float]:
    """格中心（**必然落在可用区内**，且不同格不同点）。"""
    grid_x, grid_z, usable_x, usable_z, margin = _explore_grid(bounds)
    x = margin + (ix + 0.5) * (usable_x / grid_x)
    z = margin + (iz + 0.5) * (usable_z / grid_z)
    return [round(x, 1), round(z, 1)]


def _previous_route_for_explore(state: Dict[str, Any], unit: str) -> Dict[str, Any]:
    """取该单位上一条路线记录（延迟导入 `movement`，避免模块级循环依赖）。"""
    from . import movement

    return movement.previous_route(state, str(unit)) or {}


# --------------------------------------------------------------- 意图构造（唯一）
def make_intent(intent_id, action, unit, target, priority, rationale, task_id,
                *, tick: int, snapshot: int, expires: int) -> Dict[str, Any]:
    """意图字面量的**唯一构造点**（阶梯与并行填充共用）。

    并行填充产出的意图必须与阶梯**同形状**（走同一套契约校验/仲裁/回执），
    形状在两处各写一遍必然分叉 —— 本项目已有多次先例，所以收敛成一个函数。
    """
    return {
        "intent_id": intent_id, "task_id": task_id, "unit_ids": [unit],
        "action": action, "target": target, "priority": priority,
        "based_on_snapshot": snapshot, "issued_tick": tick,
        "expires_tick": expires, "generation": 0, "rationale": rationale,
    }


# ---------------------------------------------------------------- 并行填充
#: 一次决策最多补多少条并行意图（其余下一轮继续）。
#: 与 `GraphConfig.max_batch` 同量级；决策 ~1.4 轮/秒 × 上限 8 ⇒ 上限约 11 条/秒，
#: 这是"每秒至少一次操作"在结构上得以成立的原因。
PARALLEL_FILL_CAP = 8


def _parallel_intents(state: Dict[str, Any], *, tactical=None, rules=None,
                      primary: Optional[List[Dict[str, Any]]] = None,
                      ttl_ticks: int = 3600, server_tick: int = 0,
                      snapshot_id: int = 0,
                      army_threshold: int = ARMY_ATTACK_THRESHOLD
                      ) -> List[Dict[str, Any]]:
    """**多轨并行填充**：让还没拿到任务的空闲单位各自执行当前该做的事。

    ## 为什么必须有这一步（2026-09-12 用户要求）
    用户原话："不能做到每秒至少一次操作，不能同时处理多线情况，现在远不及要求。"

    结构根因：发展阶梯是"逐级 `return` **一条**"的写法 ——
    实测决策 **1.4 轮/秒**，但每轮最多产出 **1 条**命令，而且**同一时刻只有一条线在动**
    （建造时不出兵、出兵时不采集）。一局 15 个单位的局面里，绝大多数单位整轮拿不到命令，
    实测只有 **0.3~0.45 条命令/秒**。

    本函数把"空闲单位"当作第一类公民，**四条轨各自独立产出、互不排斥**：
    经济（采集）/ 生产（每个空闲产能建筑各一条）/ 侦察（专职侦察）/ 军事（每个空闲作战单位）；
    合计不超过 `PARALLEL_FILL_CAP`，其余下一轮继续 —— 于是"每秒 ≥1 次操作"成为稳态。
    """
    out: List[Dict[str, Any]] = list(primary or [])
    by_name = _normalized_units(tactical)
    if not by_name:
        return out
    # 给 `military_waypoint` 的 commit 判定补齐类型（ingest 已写时不覆盖）。
    types = state.setdefault("own_unit_types", {})
    if isinstance(types, dict):
        for name, info in by_name.items():
            kind = str((info or {}).get("type", ""))
            if kind and name not in types:
                types[name] = kind
    inputs = ladder_inputs(state, tactical=tactical, rules=rules)
    ai_units = list(inputs["ai_units"])
    busy = set(inputs["busy"])
    tick = int(server_tick or state.get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or state.get("latest_snapshot_id", 0) or 0)
    expires = tick + max(1, int(ttl_ticks or 3600))
    used = {str(u) for intent in out for u in (intent.get("unit_ids") or [])}
    prefs = campaign_mod.frontier_preferences(state, tick=tick)
    suspended = {str(u) for u in (prefs.get("suspended_objects") or [])}

    def _add(intent_id, action, unit, target, priority, rationale, task_id) -> None:
        out.append(make_intent(intent_id, action, unit, target, priority, rationale,
                               task_id, tick=tick, snapshot=snapshot, expires=expires))
        used.add(str(unit))

    def _free(name: str) -> bool:
        return name not in busy and name not in used and name not in suspended

    from . import movement as _movement

    def _en_route(name: str) -> bool:
        return _movement.unit_en_route(state, name, tick)

    # 侦察轨至少留 1 个名额：产能/采集把 PARALLEL_FILL_CAP 吃满后，
    # 无人机到达第一前沿也发不出下一跳（`u1t01d` scout.last_served 钉死 948）。
    # **只挑一次**：`pick_scout_executor` 转交时会清掉已阵亡的 assigned，
    # 预留名额再挑一次会把"专职没了"信号吃掉，后面就转交不出去。
    scout_pick = pick_scout_executor(
        by_name, ai_units, busy | used,
        explore=state.get("explore") if isinstance(state, dict) else None,
        blocked=suspended, state=state if isinstance(state, dict) else None)
    scout_reserve = 1 if scout_pick else 0

    def _room(*, reserve: int = 0) -> bool:
        return len(out) < PARALLEL_FILL_CAP - reserve

    # ---- 轨 1：经济（还没上岗的采集单位 → 最近且人少的矿）----
    resources = _resources(tactical)
    if resources:
        # 工地上的工人不许被抽走（施工是指派制，人被调走工地永远建不完）。
        # 【2026-09-15 用户口径「留少部分建造就行，闲置工人优先采矿」】
        # 原实现对**每个未完工工地**保护它 10m 半径内的**全部**工人 —— 但施工其实只有
        # 1 个执行者（建造意图按阶梯「逐级 return 一条」下发），于是路过 / 被挤到工地
        # 附近的工人**一起被排除出采集**、原地闲置（这是用户反馈「闲职工人不优先采矿」
        # 的直接来源）。现在：
        #   ① 每个工地**最多保护 1 个**（离它最近的工人）；
        #   ② **手里已有在途 build 意图的人一律保护** —— 工人可能还在赶往工地的路上，
        #      位置判据保护不到它，抽走会打断施工。
        on_site: set = set()
        on_site.update(
            str(u)
            for intent in (state.get("active_intents") or [])
            if str(intent.get("action", "")) == ACTION_BUILD
            and str(intent.get("state", "")) in LIVE_INTENT_STATES
            for u in (intent.get("unit_ids") or []))
        # 【2026-09-15 用户："工人没事不要闲置啊，有闲置的 1-2 个工人就给建造命令"】
        # 原来这里还按**位置**给每个未完工工地保护"离它最近的 1 个工人" —— 但续建
        # （阶梯 1.5）一轮只派 **1 个**执行者，于是多工地 / 工人扎堆时，被位置保护
        # 却没被指派的人**两头不靠、原地闲置**（这是"工人闲着"的直接来源）。
        # 位置判据已被上面的"有在途 build 意图"覆盖（赶往工地的路上同样受保护），
        # 故整段删除：不在建造链上的工人一律回到采集/建造填充，不再凭空闲置。
        load, _type_load, _holders = _resource_allocation.occupancy(
            by_name, resources, state.get("active_intents") or [])
        for name in ai_units:
            if not _room(reserve=scout_reserve):
                break
            info = by_name.get(name) or {}
            if not _free(name) or name == scout_pick or name in on_site or not info.get("gather"):
                continue
            resource = _nearest_resource(info, resources, load=load,
                                         cap=RESOURCE_WORKERS_PER_NODE)
            if resource is None:
                break
            entity = str(entity_id_of(resource))
            load[entity] = load.get(entity, 0) + 1
            _add("rule-fill-gather-%s-%d" % (name, tick), ACTION_GATHER, name,
                 {"entity_id": entity_id_of(resource),
                  "pos": [round(_pos2d(resource)[0], 1), round(_pos2d(resource)[1], 1)]},
                 4, "并行填充：经济轨（空闲工人采集）", "rule-gather")

    # ---- 轨 2：生产（每个还没在产的产能建筑各一条，而不是只发一条）----
    scene_index = rules_scene_index(rules)
    own_types = set(inputs["own_types"])
    # 工人目标（与阶梯 1.8 同口径）：填充补工人时不得越过它。
    worker_product = _worker_product(rules, own_types)
    worker_id = str((worker_product or ("", ""))[1])
    producer_type_id = str((worker_product or ("", ""))[0])
    deployed_workers = sum(1 for name in ai_units
                           if str(by_name.get(name, {}).get("type", "")) == worker_id)
    base_count = sum(1 for name in ai_units
                     if str(by_name.get(name, {}).get("type", "")) == producer_type_id)
    target_workers = max(WORKER_TARGET, base_count * WORKERS_PER_BASE)
    queued_workers = 0
    for entry in (tactical or {}).get("production") or []:
        if not isinstance(entry, dict):
            continue
        for item in entry.get("items") or []:
            # 统一口径（`queue_item_product`）：旧名 `product_type_id` 实测恒空，
            # 只认它会让"已排队的工人"永远算 0 → 目标工人数被重复下单。
            if queue_item_product(item) == worker_id:
                queued_workers += 1
    producing = {str(unit)
                 for intent in (state.get("active_intents") or [])
                 if str(intent.get("action", "")) == ACTION_PRODUCE
                 and str(intent.get("state", "")) in LIVE_INTENT_STATES
                 for unit in (intent.get("unit_ids") or [])}
    # 生产缺口口径 = 现有 + 队列 + 在途（与阶梯 2 共用 `produce_totals`，唯一实现）。
    counts = produce_totals(by_name, tactical, state, scene_index)
    # 兵力上限（与阶梯 2 同口径、同记账函数）：达到上限时生产轨**不再补作战单位**。
    # 判一次即可（本函数内兵力不会变），避免每个设施各算一次。
    combat_ids = combat_types_of(state, rules)
    combat_allowed = combat_production_allowed(state, tactical, tick, rules)
    for name in sorted(inputs["constructed_producers"]):
        if not _room(reserve=scout_reserve):
            break
        # `used` 必须一起判：骨架已经给这个设施派了活，填充不得再派同一条
        # （否则同一批次里出现两条一模一样的 produce —— 契约层会直接判 id 重复）。
        if name in producing or name not in ai_units or name in used:
            continue
        producer_type = str(by_name.get(name, {}).get("type", ""))
        options = [(product, scene_index.get(product, ""))
                   for product, producer in PRODUCT_LADDER
                   if producer == producer_type and producer in own_types
                   and scene_index.get(product, "")
                   and (combat_allowed or product not in combat_ids)]
        # 【2026-09-15 决定：**并行轨不补工人**，补工人只由阶梯 1.8 负责】
        # 曾试过在这里也补工人（为了绕过阶梯的「逐级 return」），但同一轮内两条路径会各产
        # 一条（`worker_production_in_flight` 只查**历史** state，看不到本轮刚产出的意图）⇒
        # 每轮多一条 produce 意图，打乱了"每轮下发条数"的既有契约（`test_graph_runtime_fake`
        # 等以 `transport.sent == 1` 钉住该契约）。根因改由**阶梯 1.8 的生产者判据放宽**解决
        # （见 `_development_intents_raw` 里「与阶梯 2 同口径」那段）。
        if not options:
            continue
        product, scene = min(options, key=lambda item: counts.get(item[0], 0))
        # 补工人要守**目标工人数**（与阶梯 1.8 同口径）：否则会绕过"够用就停手"，
        # 把指挥中心一直挂在"造工人"上（实测会挤掉出兵）。
        # 【2026-09-15 修死代码】原判据 `product == worker_product` 是 **str 与 tuple 比较**
        # ⇒ 恒为假，这层守卫从未生效。改成按**产品 id** 比较（上面的候选过滤已先挡一道）。
        if worker_product and product == worker_product[1]:
            if deployed_workers + queued_workers >= target_workers:
                continue
        counts[product] = counts.get(product, 0) + 1
        _add("rule-produce-%s-%s-%d" % (product, name, tick), ACTION_PRODUCE, name,
             {"scene": scene, "producer": name}, 3,
             "并行填充：生产轨（%s 空闲，补 %s）" % (name, product),
             "rule-produce-%s" % product)

    # ---- 轨 3：侦察（专职侦察单位各自前探，互不排队）----
    enemies = _living_enemies(tactical)
    base = base_anchor_pos(by_name)
    bounds = state.get("map_bounds")
    combat_all = [n for n in ai_units
                  if str(by_name.get(n, {}).get("type", "")) in combat_ids]
    # 主动交火的门槛与阶梯 3 **同口径**（兵力达标 ∧ 阶段允许 ∧ 有可见敌人）：
    # 并行填充只放宽"谁能拿到任务"，绝不放宽"什么时候能打"（手册禁止未达规模就添油）。
    may_attack = (bool(enemies) and bool(prefs.get("allow_attack", True))
                  and len(combat_all) >= max(1, int(army_threshold)))
    intel_points = list(state.get("enemy_intel_points") or [])   # 公开情报（上次见过的敌情）
    # 专职都在就仍派专职；专职没了才转交一个机动单位（T03 换执行者）。
    scout_names = [name for name in ai_units
                   if _free(name)
                   and str((by_name.get(name) or {}).get("type", "")) in PROBE_TYPES]
    if not scout_names:
        replacement = scout_pick
        if replacement and replacement not in suspended:
            # 转交时允许抢采集工：专职没了比"工人继续采"更缺执行者。
            # 玩家挂起单位绝不转交、也不释放其在途意图。
            release_unit_for_scout_transfer(state, replacement)
            busy.discard(replacement)
            used.discard(replacement)
            scout_names = [replacement]
    for name in scout_names:
        if not _room():
            break
        point = military_waypoint(base, bounds=bounds, enemies=enemies,
                                  intel=intel_points, state=state, unit=name)
        if not point:
            continue
        if _en_route(name):
            # 侦察还在飞当前前沿：换 tick 再发一条只会半路改令（T13）。
            continue
        # `rule-fill-` 前缀：与阶梯骨架的 id 明确区分（同一批次里绝不允许 id 重复，
        # 契约层会直接判非法），日志/报告里也能一眼看出"这条是并行填充发的"。
        _add("rule-fill-scout-%s-%d" % (name, tick), ACTION_SCOUT, name, {"pos": point}, 3,
             "并行填充：侦察轨（朝已知敌情/地图内侧前探）", "rule-scout")

    # ---- 轨 4：军事（每个空闲作战单位各一条：能打就打、不能打就**有界**前压）----
    # `attack_move` 而不是 `move`：一路遇敌就地交火，不用再等下一轮决策。
    defending_home = defending_home_now(state, by_name, enemies)
    home = defense_home_pos(by_name) or base
    recall_ids = set(defense_recall_names(
        [n for n in ai_units if str((by_name.get(n) or {}).get("type", "")) in combat_ids],
        by_name, home)) if defending_home else set()
    from . import movement as _movement
    local_radius = float(getattr(_movement, "LOCAL_CONTACT_RADIUS_M", 30.0))
    for index, name in enumerate(ai_units):
        if not _room():
            break
        info = by_name.get(name) or {}
        if not _free(name) or str(info.get("type", "")) not in combat_ids:
            continue
        if defending_home and (unit_near_base(_pos2d(info), home) or name in recall_ids):
            # 近处回防、家里无人时的召回：都归行为树 `defend`，填充不抢。
            continue
        if enemies:
            # T07：基地受袭且家里已有人时，远处线不许被召回打家里的敌人。
            # 远处只打自己接触圈里的敌人，否则继续前压。
            if defending_home:
                local = [enemy for enemy in enemies
                         if unit_near_base(_pos2d(enemy), _pos2d(info), local_radius)]
                if local and may_attack:
                    hittable = attackable_enemies(state, local, [name])
                    locks = state.setdefault("engage_locks", {})
                    target_id = pick_engage_target(
                        state, name, hittable, _pos2d(info), combat_ids, locks)
                    if target_id:
                        locks[str(name)] = target_id
                        _add("rule-fill-attack-%s" % name, ACTION_ATTACK, name,
                             {"entity_id": target_id}, 2,
                             "并行填充：军事轨（远处线只打接触圈内敌人）", "rule-attack")
                        continue
                origin = _pos2d(info) if info.get("pos") else base
                point = military_waypoint(origin or base, bounds=bounds, enemies=local,
                                          intel=intel_points, search=False,
                                          ring=1 + index // 4, state=state, unit=name)
                if point and not _en_route(name):
                    _add("rule-fill-advance-%s-%d" % (name, tick), ACTION_ATTACK_MOVE, name,
                         {"pos": point}, 3,
                         "并行填充：军事轨（基地受袭，远处线保持前压）", "rule-advance")
                continue
            # **有可见敌人时，作战单位只走"打"这一条路**：够格才打，不够格就**不发**。
            # 绝不能"不够格也往前顶" —— 那就是"拿 1 个兵硬冲 3 个敌人"，
            # 微操树同时还要负责劣势撤离（`test_outnumbered_retreat_preempts_model_attack`）。
            # 交火/撤离的威胁判断归行为树（它看得见数量对比），这里只做"规模够了就开打"。
            if may_attack:
                # 只挑**打得了**的目标：被权威以"武器域不匹配"拒过的 单位×目标 对在窗口内剔除
                # （修正维度是**换目标**，不是重发同一条命令 —— 见 `ban_unattackable_target`）。
                hittable = attackable_enemies(state, enemies, [name])
                locks = state.setdefault("engage_locks", {})
                target_id = pick_engage_target(
                    state, name, hittable, _pos2d(info), combat_ids, locks)
                if target_id:
                    locks[str(name)] = target_id
                    _add("rule-fill-attack-%s" % name, ACTION_ATTACK, name,
                         {"entity_id": target_id}, 2,
                         "并行填充：军事轨（交火局部最近/高威胁目标）", "rule-attack")
            continue
        # 无可见敌人：才谈"前压"。前压点由 `military_waypoint` 给
        # （朝地图内侧 / 朝已知敌情、不越交战线、不贴边）。
        # **小队已成形 → search=True**：允许更远（去找人打），否则部队会在家门口转圈
        # （实测一局攒到 36 个作战单位、可见敌人 0、只有前压命令 = 玩家眼里的"攒兵不打"）。
        origin = _pos2d(info) if info.get("pos") else base
        point = military_waypoint(origin or base, bounds=bounds, enemies=enemies,
                                  intel=intel_points, search=True,
                                  ring=1 + index // 4, state=state, unit=name)
        if not point:
            break
        if _en_route(name):
            continue
        _add("rule-fill-advance-%s-%d" % (name, tick), ACTION_ATTACK_MOVE, name,
             {"pos": point}, 3,
             "并行填充：军事轨（前压到 %s，遇敌即交火）" % (point,), "rule-advance")

    return out


def development_intents(state: Dict[str, Any], *, tactical=None, rules=None,
                        ttl_ticks: int = 3600, server_tick: int = 0,
                        snapshot_id: int = 0,
                        army_threshold: int = ARMY_ATTACK_THRESHOLD
                        ) -> List[Dict[str, Any]]:
    """确定性**发展阶梯**（决策手册 BLD-01）的**对外出口**。

    返回 = 阶梯骨架（0~1 条，"当前主线最该做的那件事"）
         + **多轨并行填充**（其余空闲单位各自的活，见 `_parallel_intents`），
    最后按拒绝账本过滤。

    为什么过滤放在出口（而不是每个阶梯各自判断）："这条命令已被权威端拒过 N 次"
    是**全局知识**，只应有一个地方执行 —— 否则同类问题会在每个生产者里各犯一次
    （2026-09-12 实测：同一条坏命令刷屏 976 次）。
    """
    primary = _development_intents_raw(state, tactical=tactical, rules=rules,
                                      ttl_ticks=ttl_ticks, server_tick=server_tick,
                                      snapshot_id=snapshot_id, army_threshold=army_threshold)
    filled = _parallel_intents(state, tactical=tactical, rules=rules, primary=primary,
                               ttl_ticks=ttl_ticks, server_tick=server_tick,
                               snapshot_id=snapshot_id, army_threshold=army_threshold)
    return placement.filter_rejected(filled, state)


def army_threshold_for_augments(base: int, tactical=None) -> int:
    """已选加成只微调阶梯门槛，不重算采集/伤害数字。

    经济牌 → 更晚出击；军事牌 → 略提早出击。建造/侦察不改这条门槛。
    """
    tags = owned_augment_tags(tactical)
    value = int(base)
    if "military" in tags:
        return max(1, value - 1)
    if "economy" in tags:
        return value + 1
    return value


def _development_intents_raw(state: Dict[str, Any], *, tactical=None, rules=None,
                            ttl_ticks: int = 3600, server_tick: int = 0,
                            snapshot_id: int = 0,
                            army_threshold: int = ARMY_ATTACK_THRESHOLD
                            ) -> List[Dict[str, Any]]:
    """发展阶梯的实际实现（不经账本过滤；过滤在 `development_intents` 出口统一做）。

    为什么需要：实测两条路都不会发展 ——
      ① `rules_fallback` 只在模型失败时触发，而模型是"成功但只回 gather"；
      ② 2B 模型在 worker 全在采集时每轮重复 gather，整局不造建筑/不出兵。
    因此由调用方在"模型这一批没有任何发展动作"时用本函数**补上骨架**。

    边界（刻意保守，与本模块既有纪律一致）：
    - 只做**事实可判定**的事：缺什么建筑、谁空闲能造、谁能生产什么、有没有可见敌人；
    - **不做目标推理**：守哪、打谁、往哪侦察仍归模型；
    - 费用与预留不在这里判（下游 `reserves.apply_budget` 统一拦），这里只保证"能力+组合合法"。
    """
    by_name = _normalized_units(tactical)
    if not by_name:
        return []
    # 候选池严格取 `ai_controlled_units`（AI 租约列表）。
    # 【曾试图放宽，已撤回】一度改成"我方单位 − 玩家接管"，被安全边界用例
    # `test_player_controlled_units_never_appear` 拦住 —— 该用例证明
    # "不在 ai_controlled_units 里就不该碰"是**刻意设计的安全边界**，
    # 不能因为"想让它多干活"就放宽。要放宽必须先查清 `ai_controlled_units`
    # 由谁填充（`state.register_unit_generation` 的调用方），拿证据说话。
    # 输入统一由 ladder_inputs 计算：决策与诊断打点用**同一份口径**，
    # 否则"日志里看到的输入"和"实际喂给阶梯的输入"会分叉，
    # 排查又会退化成猜（这个坑本项目已经踩过）。
    inputs = ladder_inputs(state, tactical=tactical, rules=rules)
    busy = set(inputs["busy"])
    army_threshold = army_threshold_for_augments(army_threshold, tactical)
    tick = int(server_tick or state.get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or state.get("latest_snapshot_id", 0) or 0)
    expires = tick + max(1, int(ttl_ticks or 3600))
    scene_index = rules_scene_index(rules)
    # 【整局主线】规则中台按 `next_frontier` 推进（建造顺序 / 是否出击 / 是否前探），
    # 这就是"模型关闭时规则也沿主线发展"的落点。**没有 campaign_state 时返回宽松默认**，
    # 所以直接调用本函数的单测/回放语义不变。
    prefs = campaign_mod.frontier_preferences(state, tick=tick)
    suspended = {str(u) for u in (prefs.get("suspended_objects") or [])}
    ai_units = [u for u in inputs["ai_units"] if u not in suspended]
    busy = {u for u in busy if u not in suspended}

    def _intent(intent_id, action, unit, target, priority, rationale, task_id):
        # 唯一构造点在 `make_intent`（并行填充产出同形状意图，两处各写必然分叉）。
        return make_intent(intent_id, action, unit, target, priority, rationale,
                           task_id, tick=tick, snapshot=snapshot, expires=expires)

    # 挂起对象（玩家接管 / 中断）**不参与**阶梯：候选池必须与 `ai_units` 同一口径，
    # 否则"暂停受影响对象"会被 ladder_inputs 里未过滤的空闲清单绕过（实测会复发）。
    idle_builders = [u for u in inputs["idle_builders"] if u not in suspended]
    idle_producers = [u for u in inputs["idle_producers"] if u not in suspended]
    own_types = set(inputs["own_types"])
    built_types = set(inputs["built_types"])   # 建筑不是采集单位
    # 生产视图（生产者 → 队列）在**本函数开头**建一次：工人补产与作战单位补产两处都要用
    # （放在后面会让前面的分支引用未定义变量 —— 实测一次就炸出 14 个测试错误）。
    production_views: Dict[str, Dict[str, Any]] = {}
    for entry in (tactical or {}).get("production") or []:
        if isinstance(entry, dict) and entry.get("producer"):
            production_views[str(entry["producer"])] = entry
    # 【三个叠加缺陷，2026-09-11 逐个修掉，勿回退】现由 `ladder_inputs()` 单点实现：
    #  A. 抢占判据曾要求**两个角色同时**为空。基地（command_center, queue=True）
    #     天然是"空闲生产者"，条件恒 False → 工人全忙时**永远没人去建造**。
    #     这就是"有兵无营"的直接成因。→ 改为**逐角色**判定。
    #  B. 候选池曾**试图**放宽成"我方单位 − 玩家接管"，被安全边界用例
    #     `test_player_controlled_units_never_appear` 拦下并撤回。纪律：
    #     不碰 `ai_controlled_units` 之外的单位是刻意设计的边界；
    #     **测试拦住你时，先假设测试是对的。**
    #  C. 抢占动作曾按具体动作名硬编码（只认 gather）→ 模型一发 scout/move
    #     就让建造阶梯再次饿死。→ 改为按**优先级语义**（PREEMPTIBLE_ACTIONS）。

    # 阶梯 1：按 `BUILD_LADDER` 补齐/扩建建造物（产能 → 防御 → 分基地），只往前推一级。
    # 退避期内**不尝试建造**（连续被拒 3 次 → 停 15 秒；GPT Q6：不得用无限重试掩盖拒绝），
    # 生产/采集等其它骨架不受影响。
    #
    # 【2026-09-12 晚扩线，用户反馈"不会发展、不会多造建筑、防御、分子基地"】
    # 旧实现是 `if building in own_types or building in built_types: continue` —— 只要
    # 有**一座**该类型就永远跳过，于是兵营+车厂建完发展线就彻底停（余额 46800 花不出去）。
    # 现在按**数量上限**判定（`BUILD_LIMITS`），于是"多造建筑 / 防御塔 / 第二座基地"
    # 才可能出现；同一类型需要几座由限额表说了算，不是"有一座就够"。
    building_counts: Dict[str, int] = {}
    for info in by_name.values():
        key = str(info.get("type", ""))
        if key:
            building_counts[key] = building_counts.get(key, 0) + 1
    # 【只建"规则视图里真能建的东西"】`rules_scene_index` 同时收 `unit_types[].scene_path`
    # 和 `constructions[].blueprint_scene_path`（unit_type 优先），所以 `scene_index` 里
    # **存在**某个 id ≠ 它能被建造。实测教训：规则视图里没有 `constructions` 时，
    # 阶梯仍会拿 `command_center` 的**单位**场景去发 build（=发一条必被权威端拒的命令）。
    # 建造清单以 `constructions` 为准（那才是"可建造"的权威声明）。
    buildable_ids = {str(item.get("id", ""))
                     for item in (rules or {}).get("constructions", []) or []
                     if isinstance(item, dict) and item.get("id")}
    build_backoff = tick < int(state.get("build_backoff_until_tick", 0) or 0)
    # 【施工串行】已有工地在施工 → 本轮**不开新工地**。
    # 依据（传统 AI 优点 #2"施工单工地串行：有任何建筑在施工就整轮不动，空工地才派 1 个工人"；
    # 2026-09-12 晚实测）：同时铺开多个工地时 `build` 命令 181 条、其中 **172 条被
    # `NotVisible` 拒**（落点在视野外），还把工人成批从采集里抽走 —— 采集线当场停摆。
    # 施工进度由下面的阶梯 1.5 保障（只派 1 个工人到场续建，其余继续干本职）。
    unfinished_now = list(inputs.get("unfinished_buildings") or [])
    # 主基地旁还有工地时，默认不开新工地（施工串行）。分基地是**另一处远端矿**，
    # 被这条规定挡住就会错过"前探单位还在矿旁"的窗口（无模型主线卡在 M05）。
    expansion_cc_open = (str(prefs.get("milestone_id") or "") == campaign_mod.M05
                         and "command_center" in (prefs.get("build_order") or ()))
    # 落点可行性**账本**（几何类按点拉黑 / 内容类按意图前缀拉黑），整个循环共用：
    # 传账本本体而不是坐标列表 —— 落点生成器据此一次筛干净（含旧 `blocked_build_spots` 兼容）。
    blocked_spots = placement.ledger_from_state(state)
    # 【主线优先：兵力 or 扩建】当主线要的是"兵力/施压"（`produce_first`）且产能建筑
    # 已经就位时，**本轮不开新工地**，把这一轮让给生产级。
    # 依据（2026-09-12 真机 5 分钟实测）：阶梯是"逐级 return"结构，而建造序列
    # （兵营→车厂→机场→两座塔→第二座基地）永远还有下一座 → 生产级**一次都轮不到**，
    # 结果"建筑全建完、作战单位 0 个"。让位后 M03 秒级完成，前沿推进到扩张/施压，
    # 建造线随后自然恢复（前沿一换就重建 build_order）。
    # 施工串行与续建（阶梯 1.5）不受影响：工地上还有人干活。
    # 【富局不"二选一"】`produce_first` 是**穷局纪律**（钱只够一头：先补兵、别铺工地）。
    # 开局 5 万的购买力（250 工人 / 100 坦克 / 83 兵营）下钱不是瓶颈，**并行**才是对的：
    # 一边补兵一边继续铺产能/防御/分基地。实测穷局纪律用在富局上的后果就是
    # 5 分钟只花掉 9,550（19%）、余额 40,450 闲置、第二座基地拖到第 7.5 分钟。
    build_order = list(prefs.get("build_order") or BUILD_LADDER)
    if (prefs.get("produce_first") and (built_types & set(PRODUCTION_BUILDINGS))
            and bank_a(tactical) < RICH_BANK_A):
        # 【2026-09-15 用户："生产建筑造完就造些塔"】穷局纪律原来把**整条建造序列清空**，
        # 于是车厂/兵营一到位，塔就再也不会被排上（M03/M06/M07 全是 produce_first）。
        # 现在只让"产能/扩建"让位给补兵，**防御塔保留**（塔单价低、穷局正需要）。
        build_order = [b for b in build_order
                       if b in ("anti_air_turret", "anti_ground_turret")]

    # 阶梯 0：**扩张前探**（只在"扩张选址"是前沿、且尚无合法落点时）。
    # 依据（手册 SCT-01 开局散点探路 / SCT-02 定向侦察）：分基地落点必须落在
    # **己方视野内**，而远端矿点没有己方单位就不会进视野 —— 缺的正是"派人过去"这一环。
    # 纪律：前探只能占用非采集的机动单位，且**绝不打断采集/建造**（四条线同时推进）。
    if prefs.get("expand_probe") and prefs.get("probe_point"):
        probe_unit = _pick_probe_unit(by_name, ai_units, busy)
        point = prefs.get("probe_point") or []
        if probe_unit and len(point) >= 2:
            return [_intent("rule-probe-expansion-%s-%d" % (probe_unit, tick),
                            ACTION_MOVE, probe_unit,
                            {"pos": [round(float(point[0]), 1), round(float(point[1]), 1)]},
                            2,
                            "扩张选址：派 %s 前探远端矿点方向（视野内的落点才合法）"
                            % probe_unit,
                            "rule-probe-expansion")]

    pending_order = list(build_order)
    if build_backoff:
        pending_order = []
    elif unfinished_now:
        pending_order = (["command_center"] if expansion_cc_open
                         and "command_center" in build_order else [])
    for building in pending_order:
        if building not in buildable_ids:
            continue
        if building_counts.get(building, 0) >= int(BUILD_LIMITS.get(building, 1)):
            continue
        scene = scene_index.get(building, "")
        if not scene:
            continue
        builders = list(idle_builders)
        if not builders and building == "command_center" and expansion_cc_open:
            suspended = {str(item) for item in (prefs.get("suspended_objects") or [])}
            for name in ai_units:
                if name in suspended:
                    continue
                if not bool((by_name.get(name) or {}).get("construct")):
                    continue
                release_unit_for_expansion_cc(state, name)
                builders = [name]
                break
        if not builders:
            continue
        builder = builders[0]
        # 【必须带落点】游戏侧 `_op_build` 取的是 `parsed.pos`，缺省为 (0,0) →
        # 实测被拒：{"primary_issue":"NotVisible","issues":["NotVisible","OutOfBounds",
        # "SurfaceNotBuildable"]}。这里取**主基地附近**的偏移点：基地一定在视野内，
        # 且周围通常是可建平地（比用建造者自身位置更稳）。
        anchor = _base_anchor_pos(by_name) or _pos2d(by_name.get(builder, {}))
        # 落点：**离己方单位与采矿通道最远**（实测旧落点"基地+5m 轮换方位"压在
        # 基地→矿点的通道上：barracks(10,12) 对工人 (8~10,13~14.6)，把工人堵在
        # 1.5m 口袋里采矿——用户反馈"兵营造的位置会卡住工人采矿"）。
        resources = [e for e in _entities(tactical)
                     if str(e.get("kind", "")).startswith("resource")]
        if building == "command_center":
            # 分基地：**不能**贴着主基地盖（那样毫无收益），要选远端矿点附近。
            place = pick_expansion_spot(by_name, resources, anchor,
                                        blocked=blocked_spots,
                                        bounds=state.get("map_bounds"))
            if not place:
                continue      # 没有"离主基地较远的可见矿点"→ 不建假分基地，继续看下级
            site_note = "派工人到远端矿点附近建造"
        elif is_turret_building(building):
            # 防御塔：当前视野最外围（接近路），不是指挥中心 4m 环。
            enemy_pts = [_pos2d(item) for item in _living_enemies(tactical)]
            place = pick_turret_spot(by_name, resources, anchor,
                                    blocked=blocked_spots,
                                    bounds=state.get("map_bounds"),
                                    state=state, enemies=enemy_pts)
            site_note = "派工人到基地外围建造"
        else:
            place = pick_build_spot(by_name, resources, anchor,
                                   blocked=blocked_spots,
                                   bounds=state.get("map_bounds"),
                                   state=state)   # 传 state 只为了留痕（候选全不可用时记账）
            site_note = "派工人到基地附近建造"
        if not place:
            continue
        # intent_id 必须**带上 tick**：游戏侧按 intent_id 幂等缓存回执，
        # 若沿用固定 id，重试会一直命中最早那次拒绝（实测 `intent_replay: true` +
        # `issued_tick` 停在旧值），换落点也永远不会被执行。
        return [_intent("rule-build-%s-%s-%d" % (building, builder, tick), ACTION_BUILD,
                        builder, {"scene": scene, "producer": builder, "pos": place}, 3,
                        "发展阶梯：尚无 %s，%s" % (building, site_note),
                        "rule-build-%s" % building)]

    # 阶梯 1.5：**未完工的工地，派工人"到场"继续施工**（2026-09-12 实测真凶链）。
    #
    # 为什么是 `move` 而不是再发一次 `build`（关键，吃过亏）：
    # 游戏侧 `build` 走 `PlaceStructure` —— 它**新建**一座建筑；车厂已经放置过
    # （`constructed=False` 是"已放置、未完工"），重复放置必然被判 `Occupied`/不可建
    # （实测该 `rule-build-finish-*` 被权威端 **连续 Rejected ×32**）。
    # 施工本身在 `PlaceStructure` 成功时就通过 `AssignBuilders` 指给了工人，
    # **工人留在工地就会自动建完**；真正的病根是我们的指挥层把工人调走去采集，
    # 工地从此没人干活。所以这里只负责"把工人送回去"。
    unfinished = list(inputs.get("unfinished_buildings") or [])
    if unfinished and idle_builders:
        site = str(unfinished[0])
        x, z = _pos2d(by_name.get(site, {}))
        # 【必须带 scene】契约 `contracts.TacticalIntent` 对 `SCENE_ACTIONS`（build/produce）
        # 同时要求 `target.scene` 与 `target.producer`：缺 scene 直接判 `contract_invalid`
        # 丢掉。实测依据：`rule-finish-site-Unit_4-*` 就是这么被丢的。
        # scene 取**工地自身类型**的场景路径；取不到就整条不发 —— 阶梯继续往下走，
        # 不能因为"续建发不出去"把后面的出兵一起堵死。
        site_scene = scene_index.get(str(by_name.get(site, {}).get("type", "")), "")
        # target 同时带 `entity_id`：游戏侧 `Constructing.is_applicable`（工人 + 未完工己方建筑）
        # 需要**目标实体**才能挂 `ConstructUnits`；只给坐标会被当成"新建"→ `PlaceStructure`
        # → 必然 `Occupied`（实测 Rejected ×32）。带上实体名后，游戏侧即可路由到续建。
        if site_scene:
            return [_intent("rule-finish-site-%s-%d" % (site, tick), ACTION_BUILD,
                            idle_builders[0],
                            {"producer": idle_builders[0], "entity_id": site,
                             "scene": site_scene,
                             "pos": [round(x, 1), round(z, 1)]}, 3,
                            "发展阶梯：%s 未完工，派工人续建（实体续建，不是新建）" % site,
                            "rule-finish-site-%s" % site)]

    # 阶梯 1.8：**补工人**（纠偏 §一：默认策略里明确含"工人数目标"）。
    #
    # 为什么必须补这一步（实测 2026-09-12 晚）：`model=off` 的 5 分钟真实局里工人数
    # 一直停在 2、余额不动 —— 旧实现把"补工人"挂在 `batch_from_rules`（**降级批次**）里，
    # 而纠偏要求"规则中台常驻、模型只做稀疏覆盖"之后降级批次不再被调用，
    # 于是**整局没人造工人**，经济彻底停摆（这正是"地板必须自己完整"的意思）。
    #
    # **顺序刻意放在建造之后**：阶梯 1（补关键建筑）是手册 BLD-01 的第一优先，
    # 被既有回归 `test_builds_barracks_when_missing` /
    # `test_ladder_build_preempts_model_gather_on_same_worker` 钉住；
    # 而建造进入 `build_backoff`（连续被拒）时这里就能接管 —— 经济不会跟着建造一起停。
    #
    # 目标 = max(WORKER_TARGET, 会造工人的建筑数 × WORKERS_PER_BASE)，
    # 再减**已部署 + 队列中 + 在途**（三重去重），且**不占满生产队列**
    # （队列+在途 ≤ WORKER_QUEUE_CAP，遵循计划 §三"AI 不得占满生产队列"）。
    owned_types = {str(info.get("type", "")) for info in by_name.values()
                   if info.get("type")}
    worker_product = _worker_product(rules, owned_types)
    if worker_product:
        producer_type, product_id = worker_product
        deployed_workers = sum(1 for name in ai_units
                               if str(by_name.get(name, {}).get("type", "")) == product_id)
        base_count = sum(1 for name in ai_units
                         if str(by_name.get(name, {}).get("type", "")) == producer_type)
        target_workers = max(WORKER_TARGET, base_count * WORKERS_PER_BASE)
        queued_workers = 0
        for entry in (tactical or {}).get("production") or []:
            if not isinstance(entry, dict):
                continue
            for item in entry.get("items") or []:
                # 【字段口径】10Hz/`op=tactical` 的队列项用的是 **`definition_id`**
                # （`product_type_id` 是旧名，实测恒为空 → 这层"队列去重"静默失效、
                # 同一条生产被反复下发）。两个名字都认，权威优先。
                item_id = str((item or {}).get("definition_id")
                              or (item or {}).get("product_type_id", ""))
                if item_id == product_id:
                    queued_workers += 1
        # 去重口径收敛到唯一实现（并行轨补工人也用它，见 `worker_production_in_flight`）。
        in_flight_workers = 1 if worker_production_in_flight(state, product_id) else 0
        # 【2026-09-15 治本：与阶梯 2（补作战单位）**同口径**】
        # 原来这里只从 `idle_producers`（严格「不在 busy」）里挑生产者 ⇒ 指挥中心一旦进入
        # `busy`（哪怕只是拿了 hold/移动这类**非生产**意图）就再也发不出工人。
        # 真实局铁证（match 9fa2f599，2026-09-15 22:26~22:30）：整局 `rule-produce-worker-*`
        # **0 条**、`built_types` 里始终没有 worker；开局唯一的工人 Unit_3 在 tick 1604 阵亡后，
        # 后续 16 分钟 AI **一个工人都没有** ⇒ 没人采矿、经济完全没启动
        # （用户反馈「闲置工人不优先采矿」—— 实际是没有工人可派）。
        # 判据与阶梯 2 完全一致：**已完工 ∧ 该设施没有在途生产意图 ∧ 队列未满**；
        # 其中「队列空 = 没在忙」用**观测事实**判定（不靠超时猜测，见阶梯 2 的长注释）。
        producing_units_now = {str(unit)
                               for intent in (state.get("active_intents") or [])
                               if str(intent.get("action", "")) == ACTION_PRODUCE
                               and str(intent.get("state", "")) in LIVE_INTENT_STATES
                               for unit in (intent.get("unit_ids") or [])}
        for name in list(producing_units_now):
            view = production_views.get(name)
            if view is not None and int(view.get("queue_size", 0) or 0) <= 0:
                producing_units_now.discard(name)
        producer = next((name for name in ai_units
                         if str(by_name.get(name, {}).get("type", "")) == producer_type
                         and by_name.get(name, {}).get("constructed") is not False
                         and name not in producing_units_now
                         and _queue_size_of(production_views, name) < PRODUCER_QUEUE_CAP), "")
        worker_scene = scene_index.get(product_id, "")
        if in_flight_workers:
            # 【关键】本级已在推进时**绝不 return 同一条**：下游 `duplicate_of_live_intent`
            # 会把它拦下（它按"执行者+动作+产品"去重，不认 intent_id 里的 tick），而阶梯是
            # "逐级 return"结构 → **后面的出兵（阶梯 2）永远轮不到**。
            # 实测（2026-09-12 晚，model=off 5 分钟真实局）：`rule-produce-worker-Unit_0`
            # 被重复生成 **391 次**、全部因去重丢弃，结果是"兵营/车厂都建好了、余额一分没花、
            # 整局一个兵都没出"。这里改成"已在推进 → 往下走"。
            pass
        elif (producer and worker_scene
                and _queue_size_of(production_views, producer) < PRODUCER_QUEUE_CAP
                and deployed_workers + queued_workers < target_workers
                and queued_workers < _worker_queue_cap(bank_a(tactical), target_workers,
                                                       deployed_workers)):
            return [_intent("rule-produce-%s-%s-%d" % (product_id, producer, tick),
                            ACTION_PRODUCE, producer,
                            {"scene": worker_scene, "producer": producer}, 4,
                            "发展阶梯：工人 %d/%d（队列 %d），基地补工人"
                            % (deployed_workers, target_workers, queued_workers),
                            "rule-produce-%s" % product_id)]

    # 阶梯 2：已有生产建筑且空闲 → 补作战单位（只补一级，避免一次灌太多）。
    #
    # **必须按"现有兵力构成"选级，不能总是返回第一级**（2026-09-11 实测修正）：
    # 兵营一旦建成，第一级 (soldier, barracks) 就永远命中 → 车厂全程闲置、
    # 整局只出士兵 —— "多兵种"名存实亡（实测 8 分钟只有 soldier，没有一辆坦克）。
    # 选级规则刻意做成**单步比较**（与 2B 模型口径一致，也便于单测）：
    # 在"产能可用"的级里，选**当前数量最少**的产品；并列时按阶梯顺序。
    options: List[Tuple[str, str, str]] = []
    # 生产只能派给**已完工**的设施（constructed 不是 False）。实测未加这条时，
    # 未完工的车厂被反复派产坦克 → 38 次 `ProducerNotConstructed`（纯噪音 + 卡住发展）。
    usable_producers = set(inputs.get("constructed_producers") or [])
    # 【2026-09-12 晚修：有钱不出兵 / 产线被"忙"整体挡死】
    # 判据从"整个 busy 集合"收窄到"**这个执行者是否已有在途的 produce 意图**"。
    # 为什么必须收窄（用户截图实测）：余额 46550、四座生产建筑全部 `queue_size=0`，
    # HUD 却是"本轮没有新命令" —— 因为 `idle_producers` 用的是 `busy`，而 `busy` 把
    # **任何**非可抢占的在途意图都算成占用；模型丢一条 `produce` 意图在途，再加上
    # 生产本身要 180~360 tick（3~6 秒）才结算，整条生产线就被判"占用"而停摆。
    # 收窄后：只有"该设施确实正在生产"才跳过，其它已完工设施照常补货。
    #
    # 【必须过滤存活状态】只看 `action == produce` 是不够的：`active_intents`
    # 是**追加式历史**（永不清理），第一次生产完之后，那条 `completed/expired` 的
    # 生产意图仍然留在表里 → 该设施被**永久**判为"正在生产"→ 再也不会被派生产。
    # 2026-09-12 真机 5 分钟实测：整局只出了 1 个兵（唯一一条 produce 回执），
    # 兵营/车厂/机场全部闲置，M03"首支作战队"卡了 12000 tick 才被超时阻塞。
    # 状态口径取 `graph.state.INTENT_LIVE_STATES`（唯一事实来源）；过期由
    # `runtime.tick()` 每轮统一标记为 expired，所以不需要在这里再查 TTL。
    # 【设施队列为空 = 它确实没在忙】未知状态的生产意图**不许永久占用设施**。
    # 归档复盘的链尾（archive_045ed0d6）：类型错配 → 进度恒 unknown → 意图一直 active_unknown
    # （仍是 LIVE 状态）→ 设施被判"正在生产"→ 下一单要等旧意图 TTL 过期才发（实测相隔 1148 tick）。
    # 判据用**观测事实**（队列空），不是超时猜测：队列空说明设施闲着，新单带新 item_id，
    # 不影响旧任务继续对账。
    producing_units = {str(unit)
                       for intent in (state.get("active_intents") or [])
                       if str(intent.get("action", "")) == ACTION_PRODUCE
                       and str(intent.get("state", "")) in LIVE_INTENT_STATES
                       for unit in (intent.get("unit_ids") or [])}
    for name in list(producing_units):
        view = production_views.get(name)
        if view is not None and int(view.get("queue_size", 0) or 0) <= 0:
            producing_units.discard(name)
    free_producers = [name for name in idle_producers if name not in producing_units]
    for name in sorted(usable_producers):
        if name not in producing_units and name not in free_producers:
            free_producers.append(name)
    # 【侦察补充档】专职侦察没了就补无人机 —— 优先于常规补兵：
    # 侦察是独立配额线（2026-09-15 用户要求），不能被建造/采集/军事任务长期挤掉。
    recon_option = recon_produce_intent(
        state, by_name, inputs, tactical, scene_index,
        free_producers=free_producers, usable_producers=usable_producers,
        production_views=production_views, tick=tick)
    if recon_option is not None:
        recon_producer, recon_scene = recon_option
        return [_intent("rule-produce-recon-%s-%d" % (recon_producer, tick),
                        ACTION_PRODUCE, recon_producer,
                        {"scene": recon_scene, "producer": recon_producer}, 3,
                        "侦察补充：专职侦察在编不足，机场补无人机",
                        "rule-produce-drone")]
    for product, producer_type in PRODUCT_LADDER:
        if producer_type not in own_types:
            continue
        scene = scene_index.get(product, "")
        if not scene:
            continue
        producer = next((n for n in free_producers
                         if by_name.get(n, {}).get("type") == producer_type
                         and n in usable_producers
                         and _queue_size_of(production_views, n) < PRODUCER_QUEUE_CAP), "")
        if not producer:
            continue
        options.append((product, producer, scene))
    if options:
        # 阶梯 2.5：**兵力上限**（手册 04 §军队规模规划）。达到上限 → 本轮不产作战单位，
        # 让阶梯继续往下走（出击/其它），钱留给战损重建。工人与建造不受影响。
        combat_ids = combat_types_of(state, rules)
        if not combat_production_allowed(state, tactical, tick, rules):
            options = [item for item in options if item[0] not in combat_ids]
    if options:
        # 【缺口口径 = 现有 + 队列 + 在途】只数现有会让"刚下单的产品"被重复押注，
        # 也让车/机（一落地就计数）长期挤掉步兵（2026-09-15 用户要求）。
        totals = produce_totals(by_name, tactical, state, scene_index)
        combat_total = sum(int(totals.get(product_id, 0) or 0)
                           for product_id, _producer_type in PRODUCT_LADDER)
        soldier_option = next((item for item in options if item[0] == "soldier"), None)
        # 【基础步兵保底】没步兵或占比过低时优先补步兵；其余情况照常按缺口轮转（多兵种不变）。
        if soldier_option is not None and soldier_shortage(
                int(totals.get("soldier", 0) or 0), combat_total):
            product, producer, scene = soldier_option
            rationale = ("发展阶梯：基础步兵 %d/%d 不足（无步兵或占比 < %.0f%%），优先补步兵"
                         % (int(totals.get("soldier", 0) or 0), combat_total,
                            SOLDIER_SHARE * 100.0))
        else:
            product, producer, scene = min(
                options, key=lambda item: int(totals.get(item[0], 0) or 0))
            rationale = ("发展阶梯：现有+队列+在途 %s 最少（%d），补充 %s"
                         % (product, int(totals.get(product, 0) or 0), product))
        # 同样带 tick：生产被拒（如队列已满/资源不足）后要有机会重试，
        # 不能被游戏侧按 intent_id 幂等缓存成"永远同一个回执"。
        return [_intent("rule-produce-%s-%s-%d" % (product, producer, tick), ACTION_PRODUCE,
                        producer, {"scene": scene, "producer": producer}, 3,
                        rationale, "rule-produce-%s" % product)]

    # 阶梯 3：兵力达标且有可见敌人 → 出击（打谁由"最近"这一事实决定，不做威胁评估）。
    # 【整局主线】出击只在**施压/收束**阶段由规则发起（手册：集结 → 前压 → 进攻，
    # 禁止"未达规模就添油"）。`allow_attack` 缺省为 True，所以无 mainline 的调用不受影响。
    enemies = _living_enemies(tactical)
    combat = [n for n in ai_units
              if n not in busy
              and by_name.get(n, {}).get("type") in combat_types_of(state, rules)]
    # T07：基地受袭时骨架出击只许近处/召回单位打家里的敌人，其余远处线不拉回来。
    if defending_home_now(state, by_name, enemies):
        home = defense_home_pos(by_name)
        recall = set(defense_recall_names(combat, by_name, home))
        combat = [n for n in combat
                  if unit_near_base(_pos2d(by_name.get(n) or {}), home)
                  or n in recall]
    # 【别让部队去打它打不了的目标】把"被权威以武器域不匹配拒过"的目标从候选里剔除
    # （按单位×目标记，见 `ban_unattackable_target`）。出击前先过滤，避免"出击 → 被拒 → 再出击"。
    hittable = attackable_enemies(state, enemies, combat)
    if (hittable and len(combat) >= max(1, int(army_threshold))
            and bool(prefs.get("allow_attack", True))):
        locks = state.setdefault("engage_locks", {})
        info = by_name.get(combat[0]) or {}
        target_id = pick_engage_target(
            state, combat[0], hittable, _pos2d(info), combat_types_of(state, rules), locks)
        if target_id:
            locks[str(combat[0])] = target_id
            return [_intent("rule-attack-%s" % combat[0], ACTION_ATTACK, combat[0],
                            {"entity_id": target_id}, 2,
                            "发展阶梯：兵力达标且可见敌人，出击", "rule-attack")]
    return []
