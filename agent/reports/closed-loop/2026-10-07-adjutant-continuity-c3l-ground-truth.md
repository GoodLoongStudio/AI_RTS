# 阶段 C3l：用坐标真值判定停滞 + 修掉我自己的两处口径缺陷（round-17）

日期：2026-10-07。状态：**needs-review —— 三处观测缺陷被修掉（其中两处是我自己的），
并拿到"停滞单位正好是移动最少的单位"这条新定量证据。**

上位：[C3k 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3k-busy-decomposed.md)。

---

## 1. 为什么需要坐标真值

前十几轮用的都是**权威回报**（命令账 `commands.jsonl`、到达账 `events.jsonl`），
不是**位移本身**。round-16 留下三种可能无法区分：
①真在走 ②**命令被接受但没执行** ③到达事件没发。
探针 `nav_sparsity_local.py --observe-seconds` 每 2 秒采一次全量 tactical，
那是独立的位移真值 —— 本轮就用它。

## 2. 修掉三处观测缺陷（两处是我自己的，必须写在最前面）

### 2.1 我把**一个单位的时间轴**套到了所有单位头上

报告顶层 `samples` 是"每个采样点里当时可见的单位"，实测**剧烈抖动**
（同一局的 `samples` 只含 1 个单位 `Unit_1`，而 `samples_moved` 有 **42** 个）。
第一版 `truth_gap_check.py` 用了它，于是把 `Unit_1` 的采样时刻当成所有单位的时刻，
算出"**42 个单位在同一时刻全体没动**"这种假结论。

**修**：一律用 `samples_moved[unit]["track"]`（逐单位、与它自己的 `gaps_s` 同源）。

### 2.2 采样断档被误判成"单位没动"

两局都在 **t≈87→109s** 有一个 **20~21.5 秒**的采样空档，且**可复现**。
原因在探针循环（[nav_sparsity_local.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-01/nav_sparsity_local.py)）：

```python
try:
    snap = base.dcs(SERVER_DBG, {"op": "tactical", ...}, timeout=20)
    lease = base.dcs(SERVER_DBG, {"op": "adjutant_leases"}, timeout=20)
    samples.append({...})
except Exception as exc:
    samples.append({"error": repr(exc)})     # ← 这一支**不记 t**
```

`units` 那一行若失败（或 `tactical` 卡到 20 秒超时），这一轮**不产生样本**，
而 `t` 是按墙钟算的 ⇒ 于是出现一个 20 秒的"空档"，看起来像"单位没动"。

**修**：`truth_gap_check.py` 先算采样空隙（相邻采样 > 5s），落在空隙里的样本
一律判 `sampling_gap`、**不入任何统计**。

### 2.3 探针没保留**逐点轨迹**（这是最要紧的一处）

`samples_moved` 原来只有聚合量（`gaps_s` / `move_events` / `max_gap_s`），
**没有时刻**。于是"这个 105.5 秒的空档发生在第几秒"无从得知，也就无法与命令账对齐。

**修**：`_movement_report` 增加 `track`（逐点 `[t, x, z]`，上限 `TRACK_POINT_LIMIT=600`，
有界）。重跑后 42 个单位全部带轨迹（约 104 点/单位）。

> 这三处合起来说明一件事：**前几轮里凡是依赖 `samples` 的判断都要重新看**。
> 但也要说清：round-16 的 `busy` 残留判定（577 组合 / 16 个 ≥5 轮 / 0 个期间报到达）
> 用的是**命令账与到达账**，两者只依赖 `server_tick`，**不受上述缺陷影响**，结论仍然成立。

## 3. 用"探针自带的口径"看停滞（不依赖采样连续性）

`samples_moved[unit]["gaps_s"]` 是探针自己按"位移 > 0.5m 才算一次移动事件"算的，
**只依赖数据点本身**，所以不受 §2.2 的空档影响：

| 指标 | 值 |
|---|---|
| 移动空档 ≥12s 的个数 | **85** |
| 中位 | **23.6 秒** |
| ≥30s 的个数 | **31** |
| 最大 | **113.9 秒** |

**而这批"停最久"的单位，恰好就是"动得最少"的单位**：

| 单位 | max_gap | move_events | 总位移 |
|---|---|---|---|
| Unit_2 | **113.9s** | **10** | 41.2m |
| Unit_11 | **113.9s** | **10** | 41.6m |
| Unit_16 | 111.8s | 10 | 41.6m |
| Unit_4 | 111.7s | 11 | 42.5m |
| Unit_7 | 109.6s | 14 | 43.7m |
| Unit_20 | 88.2s | 10 | 37.1m |

对照"动得多"的单位（同期同一局）：

| 单位 | max_gap | move_events | 总位移 |
|---|---|---|---|
| Unit_13 | 20.5s | **90** | **668.2m** |
| Unit_17 | 20.5s | 90 | 634.7m |
| Unit_18 | 20.5s | 91 | 642.0m |

⇒ **两个群体差一个数量级**：动得多的单位（位移 500~670m、移动事件 70~90 次）
最大空档只有 20.5 秒；动得少的单位（40m 量级、事件 10 次上下）最大空档 110+ 秒。

这条相关性**比之前任何一条指标都更贴近用户的抱怨**（"走一小段后等很久"）：
不是全体一起卡，而是**一部分单位几乎没被派出去**，于是它们在统计上表现为"长时间停滞"。

## 4. 因此下一轮（round-18）该查什么

把问题从"接续慢"改问成"**为什么这些单位拿到的移动总量少一个数量级**"：

1. 对 §3 表格里那 6 个"动得少"的单位，逐条列出它们**拿到过的全部命令**
   （动作、状态、是否 `Accepted`、目标点），与"动得多"的单位对照。
   判据：如果它们的 `Accepted` 次数也少一个数量级 ⇒ **生成/闸门侧的问题**
   （与本轮之前的结论一致）；如果 `Accepted` 次数相当却走不远 ⇒ **权威执行侧的问题**。
2. 位置轨迹这一轮已经落盘（`track`），可以直接拿来画时间线对照，不用再猜。
3. ⚠ 仍**不许**动任何阈值。

## 5. 改动清单与校验

| 文件 | 改动 |
|---|---|
| [nav_sparsity_local.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-01/nav_sparsity_local.py) | `_movement_report` 增加逐点 `track`（有界 `TRACK_POINT_LIMIT = 600`）；保留原有 `total_path_m` 等聚合量 |
| 新增 [truth_gap_check.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-17/truth_gap_check.py) | 用逐点轨迹 + 命令账 + 到达账做三分类；**自动识别采样空隙并排除**；优先用 `samples_moved.track`、回退时明确告警 |

```powershell
python -X utf8 nav_sparsity_local.py --out .../round-17/ab_truth --runner `
    --observe-seconds 240 --with-ai false          # rc=0
# 验证轨迹已落盘：42/42 个单位带 track，约 104 点/单位
```

## 6. 未验证 / 边界

- **各 1 局**（`archive_8c4158d1` 与 `archive_e1ae97c5`）。
- §3 的"动得少 ⇒ 停得久"是**相关性**，本轮**没有**证明因果（下一轮 §4-1 就是对它做判定）。
- `accepted_no_move` 这一类**本轮没有产出可信样本**：唯一疑似窗口是探针自己的采样空档
  （§2.2），排除后没有剩余样本 ⇒ 所以"**命令被接受但没执行**"这条假设
  **既没被证实、也没被证伪**，仍然悬着。
- `track` 上限 600 点；240 秒 × 0.5Hz ≈ 480 点，所以本轮没有截断，但更长观测需要调上限。
