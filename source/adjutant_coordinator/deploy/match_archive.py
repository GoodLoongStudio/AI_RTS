# -*- coding: utf-8 -*-
"""**对局留档**：把每一局的事实尽可能落盘，供后续（高级模型）分析。

用户 2026-09-13："现在开始，每个对局都有意义，要尽可能把数据留档，我要给高级模型分析。"

## 为什么单独一层（而不是继续往 runner.out 里塞）

`runner.out` 是**运行日志**（给人排查、给验收脚本数指标用的），它刻意只记"摘要"：
事件只记 `kinds` 计数、单位只记名字、命令只记回执。复盘之所以还有缺口，
是因为缺的正是**逐条明细**（谁被谁打了、掉多少血、这轮双方在哪、队列里排了什么）。
留档层负责这些明细，并且**只增不改**：不改任何决策路径，写失败也不影响指挥链。

## 文件布局（`<archive_root>/archive_<match8>/`）

| 文件 | 内容 | 一行对应什么 |
|---|---|---|
| `events.jsonl` | 游戏事件的**逐条载荷** | 一次受击/阵亡/到达/路径失败/生产开始… |
| `rounds.jsonl` | 每轮**世界事实** | 一轮：余额、我方单位快照、可见敌情、生产队列、扫描指标 |
| `commands.jsonl` | 命令生命周期 | 一次下发：意图→tick→回执状态/错误码/order_id |
| `model.jsonl` | 模型层调用与提议摘要 | 一次模型调用：角色/方法/耗时/成败/**它提议了什么** |
| `decisions.jsonl` | 本轮新增的内部决策 | 一条决策：kind + tick + 原因 |
| `MANIFEST.json` | 身份/配置/计数/文件大小/是否截断 | — |
| `digest.md` | **给分析模型的第一读物**（2~6KB 结构化摘要） | — |

## 有界与诚实

- 每个文件都有**字节上限**（默认 192MB/局，单文件 64MB），超了停止写并在 MANIFEST 里标
  `truncated`；**绝不静默丢弃**（分析时看到的"只有前半局"必须是显式事实）。
- 所有写入都吞异常（`OSError` 等）：留档失败**不允许**影响对局。
"""

import io
import json
import os
import time
from typing import Any, Dict, List, Optional

#: 单文件字节上限（超过就停写该文件并标 truncated）。
FILE_LIMIT_BYTES = 64 * 1024 * 1024
#: 整局总上限（超过就停写全部并标 truncated）。
TOTAL_LIMIT_BYTES = 192 * 1024 * 1024
#: digest 里各榜单保留条数。
DIGEST_TOP = 12


def _pos2d(value: Any) -> List[float]:
    """取 `[x, z]`（允许三元素 `[x, y, z]`）；拿不到返回空表（**不猜**）。"""
    if isinstance(value, (list, tuple)) and len(value) >= 2:
        try:
            return [float(value[0]), float(value[-1] if len(value) >= 3 else value[1])]
        except (TypeError, ValueError):
            return []
    return []


def _nearby(center: List[float], others: List[Dict[str, Any]], radius: float,
            limit: int = 6) -> List[Dict[str, Any]]:
    """半径内的单位（**位置事实，不是归因**）：`[{unit, unit_type, dist}]`。

    兼容两种形状：原始实体（`name`/`pos`）与紧凑快照（`n`/`p`）—— 归档里两种都有。
    """
    out = []
    for item in others or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("unit") or item.get("name") or item.get("n") or "")
        if not name:
            continue
        pos = _pos2d(item.get("pos") or item.get("p"))
        if not pos:
            continue
        dist = ((pos[0] - center[0]) ** 2 + (pos[1] - center[1]) ** 2) ** 0.5
        if dist <= float(radius):
            out.append({"unit": name, "unit_type": str(item.get("unit_type")
                                                      or item.get("t", "")),
                        "dist": round(dist, 1)})
    out.sort(key=lambda entry: entry["dist"])
    return out[:limit]


def _summary_of(value: Any, limit: int = 400) -> str:
    """把任意值压成一行短摘要（超长截断并显式标 `…`）。"""
    try:
        text = json.dumps(value, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        text = str(value)
    return text if len(text) <= limit else text[:limit] + "…"


def compact_units(units: Any, limit: int = 400) -> List[Dict[str, Any]]:
    """我方单位快照压成紧凑表：`{n,t,p[x,z],hp,carried?}`。

    为什么不直接存原始实体：原始条目每个 20+ 字段（含脚本路径、炮管朝向…），
    一局 50 单位 × 数百轮会膨胀到几十 MB，而分析真正要的是"谁在哪、多少血、在扛什么"。
    """
    out: List[Dict[str, Any]] = []
    for entry in (units or [])[:limit]:
        if not isinstance(entry, dict):
            continue
        pos = entry.get("pos") or []
        item: Dict[str, Any] = {
            "n": str(entry.get("name", "")),
            "t": str(entry.get("unit_type", "") or entry.get("unit_type_id", "")),
            "p": [round(float(pos[0]), 1), round(float(pos[2]), 1)] if len(pos) >= 3 else [],
            "hp": round(float(entry.get("hp", 0.0) or 0.0), 1),
        }
        if entry.get("carried"):
            item["carried"] = entry.get("carried")
        if entry.get("constructed") is False:
            item["building"] = True
        out.append(item)
    return out


def compact_production(production: Any, limit: int = 64) -> List[Dict[str, Any]]:
    """生产队列压成紧凑表：哪座设施、排了几个、当前项做到哪一步。"""
    out: List[Dict[str, Any]] = []
    for entry in (production or [])[:limit]:
        if not isinstance(entry, dict):
            continue
        items = entry.get("items") or []
        head = items[0] if items and isinstance(items[0], dict) else {}
        out.append({
            # 字段名两套：`op=tactical` 用 `producer`，10Hz 快照用 `unit`（实测两边都在用，
            # 只认一个会让摘要里"生产设施"全空白 —— 曾经就是这样）。
            "producer": str(entry.get("producer") or entry.get("unit") or ""),
            "queue": int(entry.get("queue_size", len(items)) or len(items)),
            "item": str(head.get("item_id", "") or head.get("definition_id", "")),
            "work": "%s/%s" % (head.get("completed_work", ""), head.get("required_work", "")),
            "state": str(head.get("state", "")),
        })
    return out


def compact_enemies(enemies: Any, limit: int = 128) -> List[Dict[str, Any]]:
    """可见敌情压成紧凑表（迷雾公平：只用**本玩家见过**的敌情）。"""
    out: List[Dict[str, Any]] = []
    for entry in (enemies or [])[:limit]:
        if not isinstance(entry, dict):
            continue
        pos = entry.get("pos") or []
        out.append({
            "n": str(entry.get("name", "")),
            "t": str(entry.get("unit_type", "")),
            "p": [round(float(pos[0]), 1), round(float(pos[2]), 1)] if len(pos) >= 3 else [],
            "hp": round(float(entry.get("hp", 0.0) or 0.0), 1),
            "seen": int(entry.get("last_seen_tick", 0) or 0),
        })
    return out


class MatchArchive:
    """一局的留档写入器（有界、可失败、只读事实）。"""

    def __init__(self, root: str, *, match_id: str, player: str, rules_version: str = "",
                 config: Optional[Dict[str, Any]] = None, open_time: Optional[float] = None):
        self.match_id = str(match_id)
        self.dir = os.path.join(str(root), "archive_%s" % (self.match_id[:8] or "nomatch"))
        self.opened_at = float(open_time if open_time is not None else time.time())
        self.counts: Dict[str, int] = {}
        self.meta: Dict[str, Any] = {
            "match_id": self.match_id, "player": str(player),
            "rules_version": str(rules_version), "opened_at": self.opened_at,
            "config": dict(config or {}),
        }
        self.truncated: List[str] = []
        #: 写入异常留痕（最多 8 条）：**静默失败是留档最危险的失效模式**
        #: （实测 2026-09-13：文件建出来但一直是 0 字节，不报错、没人发现）。
        self.errors: List[str] = []
        self._handles: Dict[str, Any] = {}
        self._bytes: Dict[str, int] = {}
        self._total = 0
        self.first_tick: Optional[int] = None
        self.last_tick: Optional[int] = None
        self._events_by_kind: Dict[str, int] = {}
        self._decisions_by_kind: Dict[str, int] = {}
        self._commands_by_action: Dict[str, int] = {}
        self._commands_by_status: Dict[str, int] = {}
        self._reject_reasons: Dict[str, int] = {}
        self._reject_examples: Dict[str, str] = {}
        self._model_by_role: Dict[str, int] = {}
        self._model_failures = 0
        self._model_latency_ms: List[int] = []
        self._rounds = 0
        self._last_round: Dict[str, Any] = {}
        self._timeline: List[Dict[str, Any]] = []
        #: 命令记录的内存副本（有界）：收尾时要把图内 `command_timing` 合并进来。
        self._command_records: List[Dict[str, Any]] = []
        #: 主线时间线的"上次状态"（幂等去重）。
        self._phase = ""
        self._frontier = ""
        self._done: set = set()
        self._interrupt_count = 0
        self._phase_history: List[str] = []
        self._closed = False

    # ---------- 打开/写入 ----------

    def _handle(self, name: str):
        if name in self._handles:
            return self._handles[name]
        if name in self.truncated:
            return None
        try:
            os.makedirs(self.dir, exist_ok=True)
            # 【行缓冲，必须】2026-09-13 实测的真问题：验收/收尾会用 `taskkill /F` 收 runner，
            # 而默认缓冲（8KB）下"已写"的行还在内存里 —— 进程一被强杀就**整份丢失**，
            # 表现为档案里 `rounds.jsonl` 从未出现（MANIFEST 只能写"runner 未写留档"）。
            # `buffering=1` = 行缓冲：每写一行就落盘，代价可忽略（每轮 1 行）。
            # 留档的价值全在"事后还能看"，所以**不许**依赖优雅退出。
            handle = io.open(os.path.join(self.dir, name), "a", encoding="utf-8",
                             buffering=1)
        except (OSError, ValueError):
            # `ValueError`：Windows 上非法路径（如内嵌 NUL）抛的不是 OSError。
            # 留档失败**必须**只是"记一笔"，绝不允许冒泡到指挥链（实测被守门测试抓到）。
            self.truncated.append(name)
            return None
        self._handles[name] = handle
        self._bytes.setdefault(name, 0)
        return handle

    def write(self, name: str, record: Dict[str, Any]) -> bool:
        """写一行 JSONL；超上限/写失败都返回 False 并**显式记账**（不静默丢）。"""
        handle = self._handle(name)
        if handle is None:
            return False
        if self._bytes.get(name, 0) >= FILE_LIMIT_BYTES or self._total >= TOTAL_LIMIT_BYTES:
            if name not in self.truncated:
                self.truncated.append(name)
            return False
        try:
            line = json.dumps(record, ensure_ascii=False, default=str)
            # 【孤立代理字符】游戏侧读来的字符串可能带 `\udcxx`（Windows/GBK 解码残留）：
            # `ensure_ascii=False` 会把它原样保留，写 utf-8 时抛 `UnicodeEncodeError`
            # （它是 ValueError 子类 → 被下面当成"写失败"吞掉 → **整档静默变空**）。
            # 实测（2026-09-13 真机局 f3b）：四个明细文件全是 0 字节而且不报错。
            # 这里先按 replace 洗一遍，保证"任何字符串都能落盘"，脏字符变成 `?` 而不是丢文件。
            line = line.encode("utf-8", "replace").decode("utf-8")
        except (TypeError, ValueError, UnicodeError) as exc:
            # 序列化失败也要**显式记账**（名字带 :json 后缀），不许静默消失。
            if ("%s:json" % name) not in self.truncated:
                self.truncated.append("%s:json" % name)
            if len(self.errors) < 8:
                self.errors.append("json:%s:%r" % (name, exc))
            return False
        try:
            handle.write(line + "\n")
            size = len(line.encode("utf-8")) + 1
            self._bytes[name] = self._bytes.get(name, 0) + size
            self._total += size
        except (OSError, ValueError) as exc:
            if name not in self.truncated:
                self.truncated.append(name)
            if len(self.errors) < 8:
                self.errors.append("write:%s:%r" % (name, exc))
            return False
        return True

    def _write_text(self, name: str, text: str) -> None:
        """写整份文本（MANIFEST/digest）：失败只记账。"""
        try:
            os.makedirs(self.dir, exist_ok=True)
            with io.open(os.path.join(self.dir, name), "w", encoding="utf-8") as handle:
                handle.write(text)
        except (OSError, ValueError):
            if name not in self.truncated:
                self.truncated.append(name)
        return True

    def _bump(self, bucket: Dict[str, int], key: str) -> None:
        bucket[str(key)] = bucket.get(str(key), 0) + 1

    # ---------- 四类事实 ----------

    # ---------- 复盘增强（纯函数，可单测） ----------

    def command_lifecycle(self, graph_events: List[Dict[str, Any]]) -> Dict[str, int]:
        """把图内 `command_timing` 合并进命令表：**生成 tick → 收到 tick → 回执**。

        为什么必须合并：`commands.jsonl` 原本只有回执（权威层收没收），
        而"从决定到下发的时延"在另一份日志里 —— 分析"为什么慢/为什么没接上"时必须两段拼一起。
        合并键 = `intent_id`（图内 timing 与回执都带它）。
        """
        timing: Dict[str, Dict[str, Any]] = {}
        for record in graph_events or []:
            if str(record.get("event", "")) != "command_timing":
                continue
            intent_id = str(record.get("intent_id", ""))
            if intent_id:
                timing[intent_id] = {
                    "generated_tick": record.get("generated_tick"),
                    "received_tick": record.get("received_tick"),
                    "dispatch_status": str(record.get("status", "")),
                }
        # 【收档工具是另一个进程】它的 `_command_records` 是空的（记录在**文件**里）——
        # 必须先把已有命令表读回来再合并，否则 `merged=0` 但看起来"合并成功"（实测踩过）。
        if not self._command_records:
            path = os.path.join(self.dir, "commands.jsonl")
            if os.path.isfile(path):
                try:
                    with io.open(path, encoding="utf-8", errors="replace") as handle:
                        for line in handle:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                record = json.loads(line)
                            except ValueError:
                                continue
                            if isinstance(record, dict):
                                self._command_records.append(record)
                except (OSError, ValueError):
                    pass
        merged = 0
        for record in self._command_records:
            patch = timing.get(str(record.get("intent_id", "")))
            if not patch:
                continue
            record.update(patch)
            generated, received = patch.get("generated_tick"), patch.get("received_tick")
            if isinstance(generated, int) and isinstance(received, int):
                record["dispatch_ticks"] = max(0, received - generated)
            merged += 1
        if merged:
            # 合并后重写整份文件（行数少，且"生命周期"必须与回执一致）。
            # 【必须先关掉追加句柄再重写】Windows 上"文件还被追加句柄开着"时用另一个句柄
            # 截断重写，会与尚未刷出的缓冲互相覆盖 —— 实测：合并返回 merged=1 但文件里没字段。
            handle = self._handles.pop("commands.jsonl", None)
            if handle is not None:
                try:
                    handle.flush()
                    handle.close()
                except (OSError, ValueError):
                    pass
            path = os.path.join(self.dir, "commands.jsonl")
            try:
                with io.open(path, "w", encoding="utf-8") as handle:
                    for record in self._command_records:
                        handle.write(json.dumps(record, ensure_ascii=False,
                                                default=str) + "\n")
                self._bytes["commands.jsonl"] = os.path.getsize(path)
            except (OSError, ValueError):
                pass
        return {"merged": merged, "timing_events": len(timing)}

    def schema_text(self) -> str:
        """字段字典 + 口径与坑（**给分析模型看的**，随档案一起落盘）。

        为什么必须有：分析模型最容易犯的三类错——把 `Accepted` 当"完成"、
        把"日志里没有"当"没发生"、把推断当事实。字典把这三条写在最前面。
        """
        lines = [
            "# 档案字段字典与口径（自动生成）", "",
            "## 三条硬口径（违反其一结论就不成立）", "",
            "1. **`Accepted` ≠ `Completed`**：回执只说明权威层收下了命令；",
            "   是否**生效**要看 `events.jsonl` 里的 `*_done/arrival/production_finished/damage` 等事实，",
            "   或 `decisions.jsonl` 里的 `*_effective` 决策。没有证据就写「未证明」。",
            "2. **缺失 ≠ 没发生**：先看 `MANIFEST.json` 的 `missing`/`truncated`/`errors`；",
            "   字段不在档案里 = 当时没有留档能力，**不等于**当时没发生。",
            "3. **`enriched`/`nearby_*` 是推断**：事件里带 `enriched: true` 的字段由归档层根据",
            "   位置邻近补出来的**上下文**，不是权威归因（游戏侧受伤信号不带攻击者）。",
            "", "## 时间与坐标", "",
            "- 所有 `server_tick` 是游戏权威 tick；**60 tick ≈ 1 秒**（换算秒 = tick / 60）。",
            "- 位置是 `[x, z]`（地图平面，米）；`pos` 缺失表示当时拿不到。",
            "", "## 文件与字段", "",
            "### events.jsonl（逐条游戏事件）",
            "| 字段 | 含义 |", "|---|---|",
            "| `kind` | `damage`/`unit_dead`/`unit_lost`/`unit_spawned`/`arrival`/"
            "`path_failed`/`production_started`/`production_finished`/`construction_done`/"
            "`receipt`/`unit_lost` 等 |",
            "| `unit`, `unit_type`, `owner` | 事件主体 |",
            "| `hp`,`hp_max`,`delta` | 受伤事件的血量事实（`delta` 为负） |",
            "| `pos` | 事件位置（受伤/阵亡 = 受害者位置） |",
            "| `nearby_own` / `nearby_enemy` | **推断上下文**：该位置附近的我方/可见敌方单位与距离 |",
            "| `order` | 挨打的是**我方**单位时：**当时我们命令它干什么** |",
            "| `attacker_orders` | 挨打的是**敌人**时：**我们在用哪些单位打它** |",
            "",
            "### rounds.jsonl（每轮世界事实）",
            "| 字段 | 含义 |", "|---|---|",
            "| `balance` | 余额（A 资源） |",
            "| `units` | 我方单位快照（名/类型/位置/血量/是否建成） |",
            "| `enemies` | **可见**敌人（迷雾：只含被看见过的） |",
            "| `production` | 生产设施：`producer`（设施名）/`queue`（队列长度）/`item`/`work` |",
            "| `lanes` | 五条线路各有多少活跃任务、多久没被服务 |",
            "| `movement` | 安全移动账：放行/被拦原因/未闸门/unsafe/侦察先行覆盖率 |",
            "| `scan_hz`,`snapshot_age_p95`,`event_latency_p95` | 观测通道健康度 |",
            "| `elapsed_ms`,`coord_hz`,`observe_ms` | 协调节拍与开销 |",
            "",
            "### commands.jsonl（命令生命周期）",
            "| 字段 | 含义 |", "|---|---|",
            "| `intent_id`,`action`,`unit_ids`,`target` | 我们想干什么 |",
            "| `status`,`accepted`,`reason`,`error_code` | 权威层收没收、为什么拒 |",
            "| `generated_tick`→`received_tick`→`dispatch_ticks` | 决定→下发→回执的时延（tick） |",
            "",
            "### decisions.jsonl（副官为什么这么做）",
            "`kind` + 该 kind 自己的字段；常见：`movement_gate`（安全闸门拦了谁、为什么）、",
            "`movement_blocked_fallback`（拦住之后改成什么）、`lane_starved`（线路被饿死）、",
            "`intent_dropped`（任务被丢弃及原因）、`fast_events_consumed`（事件处理延迟）、",
            "`campaign_*`（主线推进/中断）。",
            "",
            "### model.jsonl（模型层）",
            "只记**调用与提议摘要**（角色/方法/耗时/成败/它提议了什么），**没有**原始 prompt/输出：",
            "想分析「它当时看到了什么」，只能结合同期 `rounds.jsonl` + `decisions.jsonl` 反推。",
            "",
            "### MANIFEST.json / digest.md / raw/",
            "清单（含缺口与写入异常）、给分析模型的第一读物、原始证据副本（runner.out、",
            "图内打点、checkpoint、游戏侧 stdout、验收报告、截图）。",
        ]
        return "\n".join(lines) + "\n"

    def enrich_event(self, record: Dict[str, Any], *, units: List[Dict[str, Any]] = None,
                     enemies: List[Dict[str, Any]] = None,
                     intents: List[Dict[str, Any]] = None,
                     radius: float = 35.0) -> Dict[str, Any]:
        """给"战斗类事件"补上下文：当时这支部队**被命令去干什么**、**附近有谁**。

        全部是**已存在的事实**的组合（位置来自观测、命令来自我们自己的状态），
        不做归因（不写"谁打的"——游戏侧受伤信号不带攻击者）。带 `enriched: true` 显式标注。
        """
        if str(record.get("kind", "")) not in ("damage", "unit_dead", "unit_lost"):
            return record
        unit = str(record.get("unit", ""))
        pos = _pos2d(record.get("pos"))
        out = dict(record)
        out["enriched"] = True
        for intent in intents or []:
            if not isinstance(intent, dict):
                continue
            if not unit:
                break
            # ① 挨打的是**我们**的单位 → 记"当时我们命令它干什么"。
            if unit in [str(item) for item in (intent.get("unit_ids") or [])]:
                out["order"] = {
                    "intent_id": str(intent.get("intent_id", "")),
                    "action": str(intent.get("action", "")),
                    "target": intent.get("target") or {},
                    "issued_tick": intent.get("issued_tick"),
                    "state": str(intent.get("state", "")),
                }
                continue
            # ② 挨打的是**敌人**（我们打它）→ 记"我们在用谁打它"（否则只会看到"敌人掉血"）。
            target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
            if str(target.get("entity_id", "")) == unit:
                out.setdefault("attacker_orders", []).append({
                    "intent_id": str(intent.get("intent_id", "")),
                    "action": str(intent.get("action", "")),
                    "units": [str(item) for item in (intent.get("unit_ids") or [])][:8],
                })
        if pos:
            own = _nearby(pos, units or [], radius)
            foe = _nearby(pos, enemies or [], radius)
            if own:
                out["nearby_own"] = own
            if foe:
                out["nearby_enemy"] = foe
        return out

    def event(self, record: Dict[str, Any]) -> None:
        """游戏事件逐条落档（受击/阵亡/到达/路径失败/生产…）。"""
        self._bump(self.counts, "events")
        self._bump(self._events_by_kind, str(record.get("kind", "")))
        self.write("events.jsonl", record)

    def round_(self, record: Dict[str, Any]) -> None:
        """一轮世界事实（余额/单位/敌情/生产/扫描指标）。"""
        self._rounds += 1
        tick = int(record.get("server_tick", 0) or 0)
        self.first_tick = tick if self.first_tick is None else min(self.first_tick, tick)
        self.last_tick = tick if self.last_tick is None else max(self.last_tick, tick)
        self._last_round = record
        self.write("rounds.jsonl", record)

    def command(self, record: Dict[str, Any]) -> None:
        """命令生命周期（下发→回执）。"""
        self._bump(self.counts, "commands")
        self._bump(self._commands_by_action, str(record.get("action", "")))
        status = str(record.get("status", ""))
        self._bump(self._commands_by_status, status)
        if status and status != "Accepted":
            reason = str(record.get("reason", "") or record.get("error_code", ""))
            self._bump(self._reject_reasons, reason[:80])
            self._reject_examples.setdefault(reason[:80], _summary_of({
                "tick": record.get("server_tick"), "intent": record.get("intent_id"),
                "action": record.get("action"), "units": record.get("unit_ids")}, 200))
        # 留一份内存副本（有界）：`command_lifecycle` 要在收尾时把图内 timing 合并进来，
        # 只能重写整份文件（行数少，换来"每条命令都有完整生命周期"）。
        if len(self._command_records) < 20000:
            self._command_records.append(record)
        self.write("commands.jsonl", record)

    def model(self, record: Dict[str, Any]) -> None:
        """模型层调用与**提议摘要**（高级模型分析"它当时为什么这么决定"的关键输入）。"""
        self._bump(self.counts, "model_calls")
        self._bump(self._model_by_role, str(record.get("role", "")))
        if not record.get("ok", True):
            self._model_failures += 1
        latency = record.get("latency_ms")
        if isinstance(latency, (int, float)):
            self._model_latency_ms.append(int(latency))
        self.write("model.jsonl", record)

    def decision(self, record: Dict[str, Any]) -> None:
        """内部决策（与 runner.out 的 `decision` 同源，落档便于一次性分析）。"""
        self._bump(self.counts, "decisions")
        self._bump(self._decisions_by_kind, str(record.get("kind", "")))
        self.write("decisions.jsonl", record)

    def hydrate(self, manifest: Dict[str, Any]) -> None:
        """把**已存在**的 MANIFEST 事实装回来（收档工具合并用）。

        为什么必须有这个：收档工具在验收结束后会再开一个 `MatchArchive` 写清单，
        如果它不把 runner 写的计数装回来，`close()` 就会用**空计数**覆盖掉真实事实
        （实测 2026-09-13：`counts={}`、`files={}` 把 runner 的证据全抹了，连排查都做不了）。
        纪律：**合并而不是覆盖** —— 谁先写的谁的事实不能丢。
        """
        if not isinstance(manifest, dict):
            return
        for key, bucket in (("counts", self.counts),
                            ("events_by_kind", self._events_by_kind),
                            ("decisions_by_kind", self._decisions_by_kind),
                            ("commands_by_action", self._commands_by_action),
                            ("commands_by_status", self._commands_by_status),
                            ("reject_reasons", self._reject_reasons)):
            value = manifest.get(key)
            if isinstance(value, dict):
                bucket.update({str(k): int(v or 0) for k, v in value.items()})
        for name in manifest.get("truncated") or []:
            if str(name) not in self.truncated:
                self.truncated.append(str(name))
        for item in manifest.get("errors") or []:
            if len(self.errors) < 8:
                self.errors.append(str(item))
        for item in manifest.get("timeline") or []:
            if isinstance(item, dict) and item not in self._timeline:
                self._timeline.append(item)
        model = manifest.get("model") or {}
        if isinstance(model, dict):
            self._model_failures = max(self._model_failures,
                                       int(model.get("failures", 0) or 0))
            for role, count in (model.get("by_role") or {}).items():
                self._model_by_role[str(role)] = max(
                    int(self._model_by_role.get(str(role), 0)), int(count or 0))
        if isinstance(manifest.get("rounds"), int):
            self._rounds = max(self._rounds, int(manifest["rounds"]))
        for key in ("first_tick", "last_tick"):
            value = manifest.get(key)
            if isinstance(value, int):
                if key == "first_tick":
                    self.first_tick = min(self.first_tick, value) if self.first_tick else value
                else:
                    self.last_tick = max(self.last_tick, value) if self.last_tick else value
        for key in ("match_id", "player", "rules_version"):
            if manifest.get(key) and not self.meta.get(key):
                self.meta[key] = manifest[key]
        if isinstance(manifest.get("config"), dict) and manifest["config"]:
            # 配置**按字段合并**：runner 写的那份最全（model/策略模式/节拍），收档工具那份只有
            # provider/port。直接覆盖会让索引里「模式」一列变成 `?`（实测踩过）。
            merged = dict(manifest["config"])
            for key, value in (self.meta.get("config") or {}).items():
                if merged.get(key) in ("", None) and value not in ("", None):
                    merged[key] = value
            self.meta["config"] = merged

    def rebuild_from_files(self, *, limit_bytes: int = 32 * 1024 * 1024) -> Dict[str, Any]:
        """**从明细文件反推摘要**（谁最后写都不重要：事实在文件里）。

        为什么需要：进程被 `taskkill` 时不会跑收尾，进度文件只到"最近 10 轮"；
        而摘要（digest）必须反映**磁盘上真实有的东西**，否则会出现
        "事件 250 条但被拒原因空白、最后一轮世界缺失"这种自相矛盾的档案（实测踩过）。
        上限之外的巨型档案跳过反推（避免为了摘要读 200MB），并在返回里标注。
        """
        names = ("events.jsonl", "rounds.jsonl", "commands.jsonl", "decisions.jsonl",
                 "model.jsonl")
        sizes = {}
        for name in names:
            path = os.path.join(self.dir, name)
            sizes[name] = os.path.getsize(path) if os.path.isfile(path) else 0
        total = sum(sizes.values())
        if total > int(limit_bytes):
            return {"rebuilt": False, "bytes": total,
                    "note": "档案过大，跳过反推（只按进度文件出摘要）"}
        # 反推前先清空这些桶，避免"进度文件 + 文件"两份数字相加翻倍。
        self.counts = {key: 0 for key in ("events", "commands", "decisions", "model_calls")}
        self._events_by_kind, self._decisions_by_kind = {}, {}
        self._commands_by_action, self._commands_by_status = {}, {}
        self._reject_reasons = {}
        self._rounds = 0
        self.first_tick = self.last_tick = None
        self._last_round = {}
        handlers = {
            "events.jsonl": lambda rec: (
                self._bump(self.counts, "events"),
                self._bump(self._events_by_kind, str(rec.get("kind", "")))),
            "rounds.jsonl": self._rebuild_round,
            "commands.jsonl": self._rebuild_command,
            "decisions.jsonl": lambda rec: (
                self._bump(self.counts, "decisions"),
                self._bump(self._decisions_by_kind, str(rec.get("kind", "")))),
            "model.jsonl": self._rebuild_model,
        }
        for name, handler in handlers.items():
            path = os.path.join(self.dir, name)
            if not sizes.get(name):
                continue
            try:
                with io.open(path, encoding="utf-8", errors="replace") as handle:
                    for line in handle:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            handler(json.loads(line))
                        except (ValueError, TypeError):
                            continue
            except (OSError, ValueError):
                continue
        return {"rebuilt": True, "bytes": total, "rounds": self._rounds,
                "counts": dict(self.counts)}

    def _rebuild_round(self, record: Dict[str, Any]) -> None:
        tick = int(record.get("server_tick", 0) or 0)
        self._rounds += 1
        self.first_tick = tick if self.first_tick is None else min(self.first_tick, tick)
        self.last_tick = tick if self.last_tick is None else max(self.last_tick, tick)
        self._last_round = record

    def _rebuild_command(self, record: Dict[str, Any]) -> None:
        self._bump(self.counts, "commands")
        self._bump(self._commands_by_action, str(record.get("action", "")))
        status = str(record.get("status", ""))
        self._bump(self._commands_by_status, status)
        if status and status != "Accepted":
            reason = str(record.get("reason", "") or record.get("error_code", ""))
            self._bump(self._reject_reasons, reason[:80])

    def _rebuild_model(self, record: Dict[str, Any]) -> None:
        self._bump(self.counts, "model_calls")
        self._bump(self._model_by_role, str(record.get("role", "")))
        if not record.get("ok", True):
            self._model_failures += 1
        latency = record.get("latency_ms")
        if isinstance(latency, (int, float)):
            self._model_latency_ms.append(int(latency))

    def flush(self) -> None:
        """把缓冲刷到磁盘 + 落一份**存活进度**。

        为什么必须显式刷：留档文件是**长跑进程**持续追加的，Python 的缓冲要满 8KB 才落盘。
        留档的意义就是"进程随时可能被打断也要留下证据"，所以每轮收尾刷一次。

        为什么还要 `_progress.json`：进程被 `taskkill` 杀掉时**不会**跑 `finally`，
        于是"到底写到哪、有没有截断/异常"就随进程一起消失了（实测踩过：只能看到 4 个
        0 字节文件，完全无法判断是没写、写失败还是缓冲没落盘）。每 10 轮写一份小进度，
        任何时刻都能回答"留档活着吗、写到第几条"。
        """
        for handle in self._handles.values():
            try:
                handle.flush()
            except (OSError, ValueError) as exc:
                if len(self.errors) < 8:
                    self.errors.append("flush:%r" % (exc,))
        if self._rounds and self._rounds % 10 == 0:
            self._write_text("_progress.json", json.dumps({
                "rounds": self._rounds, "bytes": self._bytes,
                "counts": self.counts, "first_tick": self.first_tick,
                "last_tick": self.last_tick, "truncated": sorted(set(self.truncated)),
                "errors": self.errors, "timeline": self._timeline[:200],
                "updated_at": time.time(),
            }, ensure_ascii=False, indent=1))

    def campaign_moments(self, campaign: Dict[str, Any]) -> List[str]:
        """把主线摘要的**变化**记成时间线（幂等：同一变化只记一次）。

        这里的地雷（实测踩到，整轮留档因此中断）：`campaign["interrupts"]` 是**整数计数**
        （不是列表），直接 `for ... in` 会抛 `TypeError: 'int' object is not iterable`。
        所以按类型分支处理，并且**列表/整数都支持**。
        """
        if not isinstance(campaign, dict):
            return []
        out: List[str] = []
        tick = int(campaign.get("updated_tick", 0) or 0)
        phase = str(campaign.get("phase", ""))
        if phase and phase != self._phase:
            self._phase = phase
            self.timeline("phase", phase=phase,
                          frontier=str(campaign.get("frontier", "")), tick=tick)
            out.append("phase")
        frontier = str(campaign.get("frontier", ""))
        if frontier and self._frontier and frontier != self._frontier:
            self.timeline("frontier", frontier=frontier,
                          name=str(campaign.get("frontier_name", "")), tick=tick)
            out.append("frontier")
        if frontier:
            self._frontier = frontier
        for key in campaign.get("done") or []:
            if str(key) not in self._done:
                self._done.add(str(key))
                self.timeline("milestone_done", milestone=str(key), tick=tick)
                out.append("milestone_done")
        interrupts = campaign.get("interrupts")
        if isinstance(interrupts, bool):
            pass
        elif isinstance(interrupts, int):
            if interrupts != self._interrupt_count:
                self._interrupt_count = interrupts
                self.timeline("interrupts", count=interrupts, tick=tick)
                out.append("interrupts")
        elif isinstance(interrupts, (list, tuple)):
            for item in interrupts:
                kind = str(item if isinstance(item, str) else (item or {}).get("kind", ""))
                if kind and ("interrupt:%s" % kind) not in self._done:
                    self._done.add("interrupt:%s" % kind)
                    self.timeline("interrupt", kind=kind, tick=tick)
                    out.append("interrupt")
        return out

    def timeline(self, event: str, **fields: Any) -> None:
        """主线/阶段类**里程碑时刻**（少量，直接进 digest）。"""
        item = {"tick": fields.pop("tick", self.last_tick or 0), "event": str(event)}
        item.update(fields)
        self._timeline.append(item)
        if event == "phase" and fields.get("phase"):
            self._phase_history.append("%s@%s" % (fields.get("phase"), item["tick"]))

    # ---------- 收尾 ----------

    def manifest(self, *, status: str = "", extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        sizes = {}
        for name in set(list(self._bytes) + list(self._handles)):
            path = os.path.join(self.dir, name)
            sizes[name] = os.path.getsize(path) if os.path.isfile(path) else 0
        latency = sorted(self._model_latency_ms)
        payload = dict(self.meta)
        payload.update({
            "closed_at": time.time(),
            "duration_s": round(time.time() - self.opened_at, 1),
            "status": str(status),
            "first_tick": self.first_tick, "last_tick": self.last_tick,
            "rounds": self._rounds,
            "counts": dict(self.counts),
            "events_by_kind": dict(self._events_by_kind),
            "decisions_by_kind": dict(self._decisions_by_kind),
            "commands_by_action": dict(self._commands_by_action),
            "commands_by_status": dict(self._commands_by_status),
            "reject_reasons": dict(self._reject_reasons),
            "model": {"by_role": dict(self._model_by_role), "failures": self._model_failures,
                      "latency_ms_p50": latency[len(latency) // 2] if latency else None,
                      "latency_ms_max": latency[-1] if latency else None},
            "timeline": self._timeline[:200],
            "files": sizes,
            "bytes_total": self._total,
            "truncated": sorted(set(self.truncated)),
            "errors": list(self.errors),
            "extra": dict(extra or {}),
        })
        try:
            self._write_text("MANIFEST.json",
                             json.dumps(payload, ensure_ascii=False, indent=1))
        except (TypeError, ValueError):
            pass
        return payload

    def digest(self, payload: Optional[Dict[str, Any]] = None) -> str:
        """给分析模型的第一读物：结构化、够短、只讲事实。"""
        data = payload or self.manifest()
        lines: List[str] = []
        lines.append("# 对局档案摘要（自动生成，事实优先）")
        lines.append("")
        lines.append("- match：`%s`  玩家：`%s`  规则版本：`%s`"
                     % (data.get("match_id"), data.get("player"),
                        str(data.get("rules_version"))[:16]))
        extra = data.get("extra") or {}
        assembly = extra.get("assembly") or {}
        # 补档（历史局）时"收档耗时"不是对局时长 —— 对局时长从 tick 段推（60 tick/秒）。
        span = extra.get("observed_span_s")
        span_note = ""
        if span is None:
            first, last_tick = data.get("first_tick"), data.get("last_tick")
            if isinstance(first, int) and isinstance(last_tick, int) and last_tick > first:
                span = round((last_tick - first) / 60.0, 1)
                span_note = "（由 tick 段推算）"
            else:
                span = data.get("duration_s")
        lines.append("- 段落：tick %s → %s（%s 轮协调，%ss%s）  状态：%s"
                     % (data.get("first_tick"), data.get("last_tick"), data.get("rounds"),
                        span, span_note, data.get("status") or "—"))
        if extra.get("report_passed") is not None:
            lines.append("- 验收判定：%s" % ("通过" if extra["report_passed"] else "未过"))
        for problem in (extra.get("report_problems") or [])[:6]:
            lines.append("  - ⛔ %s" % str(problem)[:170])
        for key in ("outcome", "exit_code", "degraded_reason", "route", "plan_version",
                    "sent", "model_calls", "units"):
            if extra.get(key) not in (None, "", [], {}):
                lines.append("- %s：%s" % (key, _summary_of(extra[key], 170)))
        if assembly.get("missing"):
            lines.append("- **缺口**（分析时必须知道，不要当成「没有发生」）：%s"
                         % "，".join(str(item) for item in assembly["missing"])[:320])
        counts = data.get("counts") or {}
        events_note = "（逐条事件缺失：旧版 runner 只记计数，见缺口）" if not counts.get("events") else ""
        lines.append("- 规模：事件 %s 条%s、命令 %s 条、决策 %s 条、模型调用 %s 次"
                     % (counts.get("events", 0), events_note, counts.get("commands", 0),
                        counts.get("decisions", 0), counts.get("model_calls", 0)))
        if data.get("truncated"):
            lines.append("- ⚠ **留档被截断**（超上限，分析时注意）：%s" % data["truncated"])
        if data.get("errors"):
            lines.append("- ⚠ **留档写入异常**（分析时要打折看）：%s" % data["errors"][:3])
        lines.append("")
        lines.append("## 命令（权威层收没收）")
        status = data.get("commands_by_status") or {}
        lines.append("- 状态：%s" % (status or "无"))
        actions = data.get("commands_by_action") or {}
        if actions:
            top = sorted(actions.items(), key=lambda kv: -kv[1])[:DIGEST_TOP]
            lines.append("- 动作分布：%s" % "，".join("%s×%d" % kv for kv in top))
        reasons = data.get("reject_reasons") or {}
        if reasons:
            top = sorted(reasons.items(), key=lambda kv: -kv[1])[:DIGEST_TOP]
            lines.append("- 被拒原因（前 %d）：" % min(DIGEST_TOP, len(top)))
            for reason, count in top:
                lines.append("  - ×%d `%s`" % (count, reason[:120]))
        lines.append("")
        lines.append("## 决策与主线")
        decisions = data.get("decisions_by_kind") or {}
        if decisions:
            top = sorted(decisions.items(), key=lambda kv: -kv[1])[:DIGEST_TOP]
            lines.append("- 决策分布：%s" % "，".join("%s×%d" % kv for kv in top))
        events = data.get("events_by_kind") or {}
        if events:
            top = sorted(events.items(), key=lambda kv: -kv[1])[:DIGEST_TOP]
            lines.append("- 游戏事件分布：%s" % "，".join("%s×%d" % kv for kv in top))
        timeline = data.get("timeline") or []
        if timeline:
            lines.append("- 里程碑（%d 条，全量在 MANIFEST.timeline）：" % len(timeline))
            for item in timeline[:DIGEST_TOP]:
                detail = {key: value for key, value in item.items()
                          if key not in ("event", "tick")}
                lines.append("  - tick %s %s %s" % (item.get("tick"), item.get("event"),
                                                  _summary_of(detail, 120) if detail else ""))
        model = data.get("model") or {}
        if model.get("by_role"):
            lines.append("- 模型：%s，失败 %s 次，延迟 p50=%sms max=%sms"
                         % (model.get("by_role"), model.get("failures"),
                            model.get("latency_ms_p50"), model.get("latency_ms_max")))
        last = self._last_round
        if last:
            lines.append("")
            lines.append("## 最后一轮的世界（tick %s）" % last.get("server_tick"))
            if str(last.get("derived", "")) == "runner.out" and not last.get("units"):
                # 【不许把缺数据印成 0】旧版 runner 没留单位快照 → 直说，别让人读成"一个单位都没了"。
                lines.append("- 该局由 `runner.out` 还原：**没有单位快照/余额/敌情**（旧版 runner 未留），"
                             "以下只有节拍与线路账")
            else:
                lines.append("- 余额：%s  我方单位：%d  可见敌人：%d  生产设施：%s"
                             % (last.get("balance"), len(last.get("units") or []),
                                len(last.get("enemies") or []),
                                _summary_of(last.get("production"), 200)))
            lines.append("- 节拍：协调 %sHz（耗时 %sms）、扫描 %sHz、快照年龄 p95=%ss"
                         % (last.get("coord_hz"), last.get("elapsed_ms"), last.get("scan_hz"),
                            last.get("snapshot_age_p95")))
            if last.get("movement"):
                movement = last["movement"]
                lines.append("- 移动账：放行 %s / 被拦 %s / 未闸门 %s / unsafe %s / 侦察先行覆盖 %s"
                             % (movement.get("allowed"), movement.get("blocked_reasons"),
                                movement.get("ungated"), movement.get("unsafe_dispatches"),
                                movement.get("scout_first_coverage")))
        lines.append("")
        lines.append("## 明细文件（同目录）")
        for name, size in sorted((data.get("files") or {}).items()):
            lines.append("- `%s`（%.1fKB）" % (name, size / 1024.0))
        lines.append("")
        lines.append("> 分析建议：先读本摘要；需要细节时按 tick 读 `rounds.jsonl`（世界）、"
                     "`events.jsonl`（发生了什么）、`commands.jsonl`（下发与回执）、"
                     "`decisions.jsonl`（副官为什么这么做）、`model.jsonl`（模型层输入输出摘要）。")
        return "\n".join(lines)

    def close(self, *, status: str = "", extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        # 字段字典随档案落盘：分析模型最容易把 Accepted 当完成、把缺失当没发生。
        try:
            self._write_text("SCHEMA.md", self.schema_text())
        except (TypeError, ValueError):
            pass
        payload = self.manifest(status=status, extra=extra)
        try:
            self._write_text("digest.md", self.digest(payload))
        except (TypeError, ValueError):
            pass
        for handle in self._handles.values():
            try:
                handle.close()
            except (OSError, ValueError):
                pass
        self._handles = {}
        self._closed = True
        return payload

    @property
    def closed(self) -> bool:
        return self._closed
