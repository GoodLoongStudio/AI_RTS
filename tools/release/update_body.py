# -*- coding: utf-8 -*-
"""更新 Release 说明正文（从 RELEASE_NOTES.md 读取）。

用法: set GH_TOKEN=ghp_xxx & python _gh_update_body.py [notes_path]
"""
import json
import os
import sys
import urllib.error
import urllib.request

OWNER, REPO, TAG = "GoodLoongStudio", "AI_RTS", "v0.1-demo"


def main():
    token = os.environ.get("GH_TOKEN", "").strip()
    if not token:
        print("ERROR: GH_TOKEN missing")
        return 1

    notes = r"G:\AIRTS\临时文件夹\release_assets\RELEASE_NOTES.md"
    if len(sys.argv) > 1:
        notes = sys.argv[1]
    try:
        with open(notes, encoding="utf-8") as fh:
            body = fh.read()
    except OSError as e:
        print("ERROR: 读不到 notes: %s (%s)" % (notes, e))
        return 1

    # 追加"GPU 版 laya 实测"一段，这是本次交付最关键的卖点
    body += """

---

## 附：AI 副官决策引擎实测（本机 RTX 3080 Ti）

| 配置 | 单次决策延迟 p50 | max | 与规则/实际一致率 |
|---|---|---|---|
| Laya @ **GPU (cuda)** | **29 ~ 36 ms** | 39.9 ms | **75 %**（带少样本库） |
| Laya @ CPU（对照） | > 7000 ms | — | 必然超时、自动回退 2B |

- Laya 为**判别式**决策引擎（非生成式，无幻觉），毫秒级完成"选哪个技能/谁去/打谁"；
- 必须配合 `laya_demos.jsonl` 少样本库（零样本一致率为 0%）——启动脚本已自动指向；
- 若显卡/驱动不可用，副官会**自动回退**到 2B 链路，不影响对局进行。
"""

    data = json.dumps({"body": body}).encode("utf-8")
    # ⚠ PATCH 必须用 release **id**；用 `releases/tags/<tag>` 会 404（已踩过）。
    headers0 = {
        "Authorization": "token " + token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "airts-release-updater",
    }
    g = urllib.request.Request(
        "https://api.github.com/repos/%s/%s/releases/tags/%s" % (OWNER, REPO, TAG),
        headers=headers0)
    with urllib.request.urlopen(g, timeout=60) as resp:
        rel = json.loads(resp.read().decode("utf-8"))
    rid = rel["id"]
    print("resolved release id:", rid)
    url = "https://api.github.com/repos/%s/%s/releases/%s" % (OWNER, REPO, rid)
    r = urllib.request.Request(url, data=data, method="PATCH", headers={
        "Authorization": "token " + token,
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
        "User-Agent": "airts-release-updater",
    })
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            out = json.loads(resp.read().decode("utf-8"))
        print("OK: release body updated (%d chars)" % len(body))
        print("url:", out.get("html_url"))
    except urllib.error.HTTPError as e:
        print("FAIL HTTP %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:300]))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
