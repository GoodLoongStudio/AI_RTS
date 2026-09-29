# -*- coding: utf-8 -*-
"""更新 Release 的 tag_name / 标题 / 正文（一次搞定），并可删除旧的 git tag。

用法（token 从 GH_TOKEN 环境变量或首个 ghp_ 参数读）:
    python update_release_meta.py [old_tag] [new_tag] [title] [body_md_path] [--delete-old-tag]

示例:
    python update_release_meta.py v0.1-demo v0.4 "AI RTS Demo v0.4 — 评委体验版" RELEASE_NOTES_v4.md --delete-old-tag
"""
import json
import os
import sys
import urllib.error
import urllib.request

OWNER, REPO = "GoodLoongStudio", "AI_RTS"
API = "https://api.github.com"


def req(method, url, token, data=None):
    h = {
        "Authorization": "token " + token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "airts-release-meta",
    }
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=body, headers=h, method=method)
    with urllib.request.urlopen(r, timeout=60) as resp:
        payload = resp.read()
        return json.loads(payload.decode("utf-8")) if payload else {}


def main():
    token = os.environ.get("GH_TOKEN", "").strip()
    args = sys.argv[1:]
    if args and (args[0].startswith("ghp_") or args[0].startswith("github_pat_")):
        token = args.pop(0).strip()
    if not token:
        print("ERROR: no token")
        return 1

    delete_old = "--delete-old-tag" in args
    args = [a for a in args if a != "--delete-old-tag"]

    old_tag = args[0] if len(args) > 0 else "v0.1-demo"
    new_tag = args[1] if len(args) > 1 else "v0.4"
    title = args[2] if len(args) > 2 else "AI RTS Demo v0.4 — 评委体验版"
    body_md = args[3] if len(args) > 3 else None

    body = None
    if body_md:
        with open(body_md, encoding="utf-8") as fh:
            body = fh.read()

    base = "%s/repos/%s/%s" % (API, OWNER, REPO)

    # 1) locate release by old tag
    try:
        rel = req("GET", base + "/releases/tags/" + old_tag, token)
    except urllib.error.HTTPError as e:
        print("FAIL: cannot find release by tag %s: HTTP %s" % (old_tag, e.code))
        return 1
    rid = rel["id"]
    print("release id=%s  old tag=%s  assets=%d" % (rid, rel["tag_name"], len(rel.get("assets", []))))

    # 2) PATCH tag_name / title / body
    data = {"tag_name": new_tag, "name": title}
    if body is not None:
        data["body"] = body
    upd = req("PATCH", base + "/releases/%d" % rid, token, data)
    print("PATCHed: tag_name=%s  name=%s  body=%d chars" % (
        upd["tag_name"], upd["name"], len(upd.get("body") or "")))
    print("url:", upd["html_url"])

    # 3) optionally delete the old git tag ref (release already re-pointed)
    if delete_old and old_tag != new_tag:
        try:
            req("DELETE", base + "/git/refs/tags/" + old_tag, token)
            print("old git tag deleted:", old_tag)
        except urllib.error.HTTPError as e:
            print("WARN: delete old tag failed HTTP %s (可能已被删)" % e.code)

    return 0


if __name__ == "__main__":
    sys.exit(main())
