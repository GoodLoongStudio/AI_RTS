"""Publish explicit workbench jobs to an offline, task-isolated review index.

薄 CLI 包装：实际同步逻辑在 rtsmap/workbench/review_sync.py（与工作台 server
在生成/重试/视觉重建/交付后调用的是同一实现），保证工具与流程一致。

用法：python tools/sync_workbench_review.py <job_id> [<job_id> ...]
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from rtsmap.workbench.review_sync import sync_jobs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('job_ids', nargs='+')
    parser.add_argument('--root', default=str(ROOT), help='RTS_Map_Tool 根目录')
    parser.add_argument('--output', default=None, help='workbench_output 目录（默认 <root>/workbench_output）')
    args = parser.parse_args()
    synced = sync_jobs(args.job_ids, root=args.root, output=args.output)
    review = Path(args.root) / 'review'
    print(f'Synced {len(synced)} jobs -> {review / "index.html"}')
    if len(synced) != len(args.job_ids):
        missing = [j for j in args.job_ids if j not in synced]
        print('Skipped (no job.json / not found):', missing)


if __name__ == '__main__':
    main()
