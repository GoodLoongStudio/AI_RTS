"""run.py — 闸门运行入口。

用法：
  python run.py --gate G1 --seeds 1-64
  python run.py --gate G1 --seeds 1-64 --min-pair-factor 0.55 --out runs_cmp/
  python run.py --gate G2 --seeds approved
  python run.py --approve G1 --seeds 1,3,5 --note "布局认可"
"""
import argparse
import sys

from rtsmap import gate
from rtsmap.contract import GATES


def parse_seeds(arg: str):
    if arg.strip() == "approved":
        return "approved"
    out = []
    for part in arg.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return sorted(set(out))


def main(argv=None):
    ap = argparse.ArgumentParser(description="RTS_Map_Tool 闸门运行器")
    ap.add_argument("--gate", choices=GATES, help="运行指定闸门")
    ap.add_argument("--approve", choices=GATES, help="放行指定闸门的 Seed（配合 --note）")
    ap.add_argument("--seeds", required=True, help='如 "1-64"、"1,3,5" 或 "approved"')
    ap.add_argument("--note", default="", help="approve 备注")
    ap.add_argument("--min-pair-factor", type=float, default=None, dest="min_pair_factor")
    ap.add_argument("--out", default=None, help="覆盖输出根目录（对照运行用，如 runs_cmp/）")
    ap.add_argument("--sampler", default="A", choices=["A", "B"])
    ap.add_argument("--summary-only", action="store_true", help="跳过单 Seed 大图")
    ap.add_argument("--detail", action="store_true",
                    help="写分项 PNG 到 runs/<seed>/<gate>/（默认只写权威数据 + review/）")
    ap.add_argument("--review-root", default="review", dest="review_root",
                    help="review/<gate>/ 输出根（默认 review）")
    args = ap.parse_args(argv)

    runs_root = args.out or "runs"

    if args.approve:
        seeds = parse_seeds(args.seeds)
        if seeds == "approved":
            ap.error("--approve 需要具体 Seed 列表")
        done = gate.approve(runs_root, args.approve, seeds, args.note)
        print(f"approved {args.approve}: {done} (note: {args.note})")
        return 0

    if not args.gate:
        ap.error("需要 --gate 或 --approve")

    seeds = parse_seeds(args.seeds)
    params = {}
    if args.min_pair_factor is not None:
        params["min_pair_factor"] = args.min_pair_factor

    if args.gate == "G1":
        if seeds == "approved":
            ap.error("G1 无上游，--seeds 需要具体列表")
        from rtsmap.gates import g1_starts
        g1_starts.run_gate(runs_root, seeds, params, args.sampler, args.summary_only,
                           detail=args.detail, review_root=args.review_root)
        return 0

    # 下游闸门：--seeds approved = 上游 approved 的 Seed
    if seeds == "approved":
        up = gate.upstream_gate(args.gate)
        seeds = gate.approved_seeds(runs_root, up)
        if not seeds:
            print(f"错误：上游 {up} 没有任何 approved Seed", file=sys.stderr)
            return 2
    for seed in seeds:
        gate.ensure_upstream_approved(runs_root, seed, args.gate)

    if args.gate == "G2":
        from rtsmap.gates import g2_layout
        g2_layout.run_gate(runs_root, seeds, params, args.summary_only,
                           detail=args.detail, review_root=args.review_root)
    elif args.gate == "G3":
        from rtsmap.gates import g3_content
        g3_content.run_gate(runs_root, seeds, params, args.summary_only,
                            review_root=args.review_root)
    elif args.gate == "G4":
        from rtsmap.gates import g4_export
        g4_export.run_gate(runs_root, seeds, params)
    return 0


if __name__ == "__main__":
    sys.exit(main())
