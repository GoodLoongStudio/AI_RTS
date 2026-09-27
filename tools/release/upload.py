# -*- coding: utf-8 -*-
"""把交付资产上传到 GitHub Release。

用法（token 只从环境变量读，不落盘、不打印）：
    set GH_TOKEN=ghp_xxx & python _gh_upload.py <stage_dir> [--only name1 name2 ...]

行为：
- 若 tag 已存在则复用该 release，否则创建；
- 逐个上传 stage_dir 下的文件；已存在同名资产则先删除再传（便于重跑）；
- 每个文件打印进度百分比（GB 级文件需要）。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

OWNER = "GoodLoongStudio"
REPO = "AI_RTS"
# 【2026-09-28】Release 的 tag 已由 v0.1-demo 改为 test_demo（旧 tag 已删除）。
# 这里若留着旧 tag，脚本 GET /releases/tags/<旧> 会 404 → 走"创建新 release"分支，
# 于是资产被上传到**另一个新 Release**，评委看的那个 Release 纹丝不动
# （实测事故：667MB 新游戏包被传进了误建的 v0.1-demo release）。
# 改 tag 时**必须同步改这里**。
TAG = "test_demo"
RELEASE_NAME = "AI RTS Demo — 评委体验版"

API = "https://api.github.com"


def req(method, url, token, data=None, headers=None, raw=False):
    h = {
        "Authorization": "token " + token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "airts-release-uploader",
    }
    if headers:
        h.update(headers)
    body = data
    if isinstance(data, dict):
        body = json.dumps(data).encode("utf-8")
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=body, headers=h, method=method)
    with urllib.request.urlopen(r, timeout=120) as resp:
        payload = resp.read()
        return json.loads(payload.decode("utf-8")) if (payload and not raw) else payload


def upload_asset(upload_url, token, path, name):
    # ⚠ 不要在函数体里再 import urllib.*：那会让 `urllib` 成为函数局部名，
    # 使同函数内对全局 `urllib.request` 的引用报 UnboundLocalError（已踩过）。
    import http.client
    import urllib.parse

    size = os.path.getsize(path)
    total = 0
    t0 = time.time()
    u = urllib.parse.urlsplit(upload_url)
    conn = http.client.HTTPSConnection(u.netloc, timeout=3600)
    # ⚠ asset 名走 query，必须显式 UTF-8 编码；否则中文名会被写成 "00-.-.txt"（已踩过）
    target = u.path + "?" + urllib.parse.urlencode({"name": name}, encoding="utf-8")
    conn.putrequest("POST", target)
    conn.putheader("Authorization", "token " + token)
    conn.putheader("User-Agent", "airts-release-uploader")
    conn.putheader("Content-Type", "application/octet-stream")
    conn.putheader("Content-Length", str(size))
    conn.endheaders()
    chunk = 4 * 1024 * 1024
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(chunk)
            if not buf:
                break
            conn.send(buf)
            total += len(buf)
            if total % (64 * 1024 * 1024) < chunk:
                pct = total * 100.0 / size
                print("      %.1f%%  (%.2f/%.2f GB, %.1f MB/s)"
                      % (pct, total / 2**30, size / 2**30, total / 2**20 / max(0.1, time.time() - t0)), flush=True)
    resp = conn.getresponse()
    body = resp.read().decode("utf-8", "replace")
    conn.close()
    if resp.status not in (200, 201):
        raise RuntimeError("upload failed HTTP %s: %s" % (resp.status, body[:300]))
    return json.loads(body)


def main():
    # token 来源：命令行首参（若形如 ghp_/github_pat_）优先，其次环境变量 GH_TOKEN
    args = [a for a in sys.argv[1:]]
    token = ""
    if args and (args[0].startswith("ghp_") or args[0].startswith("github_pat_")):
        token = args.pop(0).strip()
    if not token:
        token = os.environ.get("GH_TOKEN", "").strip()
    if not token:
        print("ERROR: 未提供 token（命令行首参或 GH_TOKEN 环境变量）")
        return 1
    stage = sys.argv[1] if len(sys.argv) > 1 else r"G:\AIRTS\release_assets_gpu"
    only = []
    if "--only" in sys.argv:
        i = sys.argv.index("--only")
        only = sys.argv[i + 1:]

    files = sorted(f for f in os.listdir(stage) if os.path.isfile(os.path.join(stage, f)))
    if only:
        files = [f for f in files if any(o in f for o in only)]
    print("stage  :", stage)
    print("files  :", files, flush=True)

    # 1) 找到或创建 release
    rel = None
    try:
        rel = req("GET", "%s/repos/%s/%s/releases/tags/%s" % (API, OWNER, REPO, TAG), token)
        print("release exists: id=%s tag=%s" % (rel["id"], rel["tag_name"]), flush=True)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        print("creating release %s ..." % TAG, flush=True)
        rel = req("POST", "%s/repos/%s/%s/releases" % (API, OWNER, REPO), token, data={
            "tag_name": TAG,
            "name": RELEASE_NAME,
            "body": "AI RTS Demo v0.1 —— 下载即玩（含 AI 副官）。详见附件中的 RELEASE_NOTES.md。",
            "draft": False,
            "prerelease": False,
        })
        print("created: id=%s" % rel["id"], flush=True)

    upload_url = rel["upload_url"].split("{")[0]
    existing = {a["name"]: a["id"] for a in rel.get("assets", [])}

    # 2) 逐个上传
    for name in files:
        path = os.path.join(stage, name)
        size = os.path.getsize(path)
        if name in existing:
            # 已存在且**大小一致** ⇒ 视为已传完，直接跳过（避免中断重跑时白传 GB 级文件）
            remote = [a for a in rel.get("assets", []) if a["name"] == name]
            remote_size = remote[0].get("size", 0) if remote else 0
            if remote_size == size:
                print("[skip] %s 已在远端且大小一致（%.2f GB），跳过" % (name, size / 2**30), flush=True)
                continue
            print("[re] %s 远端大小 %s != 本地 %s，删除重传" % (name, remote_size, size), flush=True)
            req("DELETE", "%s/repos/%s/%s/releases/assets/%s" % (API, OWNER, REPO, existing[name]), token)
        print("[up] %s  (%.2f GB)" % (name, size / 2**30), flush=True)
        t0 = time.time()
        a = upload_asset(upload_url, token, path, name)
        print("     done: %s  %.1f min" % (a.get("browser_download_url", "?"), (time.time() - t0) / 60), flush=True)

    print("ALL DONE", flush=True)
    print("release page: https://github.com/%s/%s/releases/tag/%s" % (OWNER, REPO, TAG), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
