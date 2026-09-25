# -*- coding: utf-8 -*-
"""用自对局采集的数据监督微调 Laya（choice 决策头）。

依据（提示词 §1.4 已知限制 1 + P0 实测）：零样本一致率 0%、少样本也不稳——
必须用项目自己的数据训练。本脚本把 `selfplay_match.py`（带 AIRTS_LAYA_DATASET）
采集的 JSONL 转成 (state, question, 正确选项) 样本，对多语言版 Laya 做微调。

样本构造（每个"教师行"拆四问）：
- 教师标签 = 该拍**实际下发**的四列行（Laya 自己被拒时取自 2B 回退）；
- task/actor/params 问用初始问题集的选项；target 问用细级追问的选项集；
- 选项里没有的标签跳过（与推理时的候选同源，不教模型选不存在的选项）。

用法：
    python train_laya.py --dataset a.jsonl --dataset b.jsonl --out ft_dir
                         [--epochs 3] [--lr 2e-5] [--batch 8] [--device cuda]

产物：`--out` 目录（rl_agent_config.json + model.safetensors + tokenizer/encoder/），
可直接 `AIRTS_LAYA_MODEL=<out>` 加载（laya.Agent 支持本地路径）。
"""

from __future__ import annotations

import argparse
import copy
import glob
import json
import os
import shutil
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # source/
sys.path.insert(0, ROOT)

#: 默认训练的问题（choice 类；score/noul 不在 v1）。
#: `branch` = 决策地图主线分支（2026-09-21 接入 Laya 的战略层选择）。
DEFAULT_QUESTIONS = ("task", "actor", "target", "params", "branch")


def load_records(paths: List[str]) -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    for path in paths:
        for pattern in sorted(glob.glob(path)) or [path]:
            with open(pattern, "r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        item = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(item, dict) and item.get("state"):
                        records.append(item)
    return records


def build_examples(records: List[Dict[str, Any]],
                   questions: Tuple[str, ...] = DEFAULT_QUESTIONS
                   ) -> List[Dict[str, Any]]:
    """数据集记录 → (state, 问题定义, 正确选项键) 样本列表。"""
    examples: List[Dict[str, Any]] = []
    for record in records:
        label = record.get("label") or {}
        rows = label.get("rows") or []
        if not rows:
            continue                      # 无下发行（维持/无标签）不产生监督
        base_q = record.get("questions") or {}
        fine_q = record.get("fine_questions") or {}
        state = str(record.get("state", ""))

        def qdef(qid: str) -> Optional[Dict[str, Any]]:
            entry = base_q.get(qid) or fine_q.get(qid)
            if not isinstance(entry, dict):
                return None
            if entry.get("type") != "choice":
                return None
            criteria = entry.get("criteria")
            if not isinstance(criteria, dict) or not criteria:
                return None
            return entry

        for row in rows:
            if len(row) < 4:
                continue
            actor_ref, skill, target_ref, params_ref = (str(row[0]), str(row[1]),
                                                        str(row[2]), str(row[3]))
            # 分支教师标签：当时主线实际沿用的节点（campaign 的 model_branch），
            # 不是模型自述——避免自己教自己；缺失表示该拍没有可学分支。
            branch_label = str((label.get("branch") or "") if isinstance(label, dict) else "")
            wanted = {"task": skill, "actor": actor_ref,
                      "target": target_ref, "params": params_ref,
                      "branch": branch_label}
            for qid in questions:
                label_key = wanted.get(qid, "")
                if not label_key or label_key == "-":
                    continue
                entry = qdef(qid)
                if entry is None:
                    continue
                options = [str(k) for k in entry["criteria"].keys()]
                if label_key not in options:
                    continue              # 标签不在候选项 = 不同源，跳过
                examples.append({
                    "state": state,
                    "qid": qid,
                    "question": {"type": "choice",
                                 "instructions": str(entry.get("instructions", "")),
                                 "criteria": {str(k): str(v)
                                              for k, v in entry["criteria"].items()}},
                    "label": label_key,
                    "options": options,
                })
    return examples


def _internal_question(example: Dict[str, Any]) -> Dict[str, Any]:
    """外部问题定义 → laya 内部格式（build_sequence 认识 {"t","ins","crit"}）。"""
    entry = example["question"]
    return {"t": str(entry.get("type", "choice")),
            "ins": str(entry.get("instructions", "")),
            "crit": {str(k): str(v) for k, v in (entry.get("criteria") or {}).items()}}


def main() -> int:
    parser = argparse.ArgumentParser(description="用自对局数据微调 Laya")
    parser.add_argument("--dataset", action="append", required=True,
                        help="训练数据 JSONL（可多次；支持 glob）")
    parser.add_argument("--base", default="convaiinnovations/laya",
                        help="基础模型（HF id 或本地目录）")
    parser.add_argument("--subfolder", default="multilingual")
    parser.add_argument("--out", required=True, help="输出目录（微调后的模型）")
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--lr", type=float, default=2e-5)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--device", default="")
    parser.add_argument("--val-ratio", type=float, default=0.1)
    parser.add_argument("--max-len", type=int, default=0,
                        help="训练序列上限（0=模型默认 1024）。实测 state 多 ≤600 "
                             "token，压到 640~768 可显著提速、质量损失很小")
    parser.add_argument("--seed", type=int, default=20260921)
    args = parser.parse_args()

    import random

    rng = random.Random(args.seed)
    records = load_records(args.dataset)
    examples = build_examples(records)
    print("records=%d examples=%d" % (len(records), len(examples)), flush=True)
    if not examples:
        print("没有可用训练样本（先跑 selfplay_match.py 采集）", flush=True)
        return 2
    by_qid: Dict[str, int] = {}
    for item in examples:
        by_qid[item["qid"]] = by_qid.get(item["qid"], 0) + 1
    print("by question:", by_qid, flush=True)

    rng.shuffle(examples)
    n_val = max(1, int(len(examples) * args.val_ratio)) if len(examples) > 20 else 0
    val = examples[:n_val]
    train = examples[n_val:]

    import laya  # noqa: E402
    from laya.common import QTYPES, build_sequence, collate_items  # noqa: E402

    agent = laya.load(args.base, subfolder=args.subfolder,
                      device=args.device or None)
    model = agent.model
    tok = agent.tok
    cfg = dict(agent.cfg)
    device = agent.device
    max_len = int(args.max_len or cfg.get("max_len", 1024))
    head_max_len = int(cfg.get("head_max_len", 256))
    print("train max_len=%d head_max_len=%d" % (max_len, head_max_len), flush=True)
    model.train()
    optimizer = __import__("torch").optim.AdamW(model.parameters(), lr=args.lr)

    # 预分词（一次）：每个 example 的序列只编一次，多 epoch 复用——
    # 实测每 batch 重新分词会让一个 epoch 从 ~2 分钟劣化到 20 分钟以上。
    cache: List[Optional[Dict[str, Any]]] = [None] * len(examples)

    def prepare(idx: int) -> Optional[Dict[str, Any]]:
        if cache[idx] is not None:
            return cache[idx]
        item = examples[idx]
        q = _internal_question(item)
        try:
            ids, markers = build_sequence(tok, item["state"], q, max_len, head_max_len)
            label_idx = item["options"].index(item["label"])
        except Exception:  # noqa: BLE001 —— 坏样本跳过（不影响训练）
            cache[idx] = False  # type: ignore[assignment]
            return None
        cache[idx] = {"ids": ids, "markers": markers,
                      "qtype": QTYPES["choice"], "label": label_idx}
        return cache[idx]

    def make_batch(indices: List[int]):
        seqs = [prepare(i) for i in indices]
        seqs = [s for s in seqs if s]
        if not seqs:
            return None
        # collate_items 收"批的列表"（与 laya system_one 的 [items] 同款）。
        batch = collate_items(
            [[{"ids": s["ids"], "markers": s["markers"], "qtype": s["qtype"]}
              for s in seqs]], tok.pad_token_id)
        batch["labels"] = __import__("torch").tensor(
            [s["label"] for s in seqs], dtype=__import__("torch").long)
        return batch

    def evaluate(indices: List[int]) -> float:
        if not indices:
            return 0.0
        model.eval()
        correct = 0
        total = 0
        with __import__("torch").no_grad():
            for start in range(0, len(indices), args.batch):
                batch = make_batch(indices[start:start + args.batch])
                if batch is None:
                    continue
                logits, _act = model(
                    batch["input_ids"].to(device),
                    batch["attention_mask"].to(device),
                    batch["marker_pos"].to(device),
                    batch["marker_mask"].to(device),
                    batch["qtype"].to(device))
                pred = logits.float().argmax(-1).cpu()
                correct += int((pred == batch["labels"]).sum())
                total += int(batch["labels"].numel())
        model.train()
        return correct / float(total) if total else 0.0

    train_idx = list(range(n_val, len(examples)))
    val_idx = list(range(0, n_val))
    # 预热分词缓存（进度可见）。
    t_tok = time.time()
    for i in range(len(examples)):
        prepare(i)
    print("tokenized %d examples in %.0fs" % (len(examples), time.time() - t_tok),
          flush=True)
    # 长度分桶：按序列长度排序后再连续成 batch —— 否则一个 batch 里长短差异大，
    # padding 到最长会把有效算力浪费数倍（实测 7.3s/batch → 分桶后 <1s）。
    def _seq_len(i: int) -> int:
        item = cache[i]
        return len(item["ids"]) if item else 0

    train_idx.sort(key=_seq_len)
    val_idx.sort(key=_seq_len)
    # 基础目录（保存 checkpoint 时复制 tokenizer/encoder 用）。
    src_dir = os.path.join(str(agent.cfg.get("_model_dir", "")), "")
    if not src_dir or not os.path.isdir(src_dir):
        from huggingface_hub import snapshot_download

        src_dir = snapshot_download(args.base,
                                    allow_patterns=[f"{args.subfolder}/*"])
        src_dir = os.path.join(src_dir, args.subfolder)
    print("val 基线准确率: %.3f" % evaluate(val_idx), flush=True)
    torch = __import__("torch")
    for epoch in range(max(1, args.epochs)):
        # 不再整表 shuffle：train_idx 已按长度分桶（打乱会破坏分桶、padding 浪费复现）。
        # 数据在划分 train/val 前已整体洗牌过一次，epoch 间保持分桶即可。
        total, correct, loss_sum, n_batches = 0, 0, 0.0, 0
        started = time.time()
        for start in range(0, len(train_idx), args.batch):
            batch = make_batch(train_idx[start:start + args.batch])
            if batch is None:
                continue
            optimizer.zero_grad()
            logits, _act = model(
                batch["input_ids"].to(device),
                batch["attention_mask"].to(device),
                batch["marker_pos"].to(device),
                batch["marker_mask"].to(device),
                batch["qtype"].to(device))
            logits = logits.float()
            loss = torch.nn.functional.cross_entropy(logits, batch["labels"].to(device))
            loss.backward()
            optimizer.step()
            pred = logits.argmax(-1).cpu()
            correct += int((pred == batch["labels"]).sum())
            total += int(batch["labels"].numel())
            loss_sum += float(loss.detach()) * int(batch["labels"].numel())
            n_batches += 1
        print("epoch %d: loss=%.4f acc=%.3f (%d batches, %.0fs)"
              % (epoch + 1, loss_sum / max(1, total), correct / max(1, total),
                 n_batches, time.time() - started), flush=True)
        # 每个 epoch 存一次（长训练被中断也不丢已完成的 epoch）。
        _save_checkpoint(args.out, model, cfg, src_dir)
    print("val 微调后准确率: %.3f" % evaluate(val_idx), flush=True)

    print("saved: %s（AIRTS_LAYA_MODEL=%s 即可加载）" % (args.out, args.out),
          flush=True)
    return 0


def _save_checkpoint(out_dir: str, model: Any, cfg: Dict[str, Any],
                     src_dir: str) -> None:
    """保存微调 checkpoint：复制基础目录结构 + 覆盖权重（Agent 直接加载本地目录）。"""
    os.makedirs(out_dir, exist_ok=True)
    for name in ("tokenizer", "encoder"):
        source = os.path.join(src_dir, name)
        if os.path.isdir(source):
            shutil.copytree(source, os.path.join(out_dir, name),
                            dirs_exist_ok=True)
    from safetensors.torch import save_file as _save_safetensors

    # 必须是 safetensors 格式（laya.Agent 用 safetensors.torch.load_file 读；
    # torch.save 的旧格式会被报 "header too large"）。
    _save_safetensors(model.state_dict(), os.path.join(out_dir, "model.safetensors"))
    with open(os.path.join(out_dir, "rl_agent_config.json"), "w",
              encoding="utf-8") as handle:
        json.dump({k: v for k, v in cfg.items() if not k.startswith("_")},
                  handle, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    raise SystemExit(main())
