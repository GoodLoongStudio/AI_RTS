# -*- coding: utf-8 -*-
"""删除指定 Release 的全部资产（用于替换为新包）。

用法: set GH_TOKEN=ghp_xxx & python _gh_clear_assets.py [tag] [--keep name1,name2]
"""
import json
import os
import sys
import urllib.error
import urllib.request

OWNER, REPO = "GoodLoongStudio", "AI_RTS"
API = "https://api.github.com"


def req(method, url, token):
    r = urllib.request.Request(url, method=method, headers={
        "Authorization": "token " + token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "airts-asset-cleaner",
    })
    with urllib.request.urlopen(r, timeout=60) as resp:
        body = resp.read()
        return json.loads(body.decode("utf-8")) if body else {}


def main():
    token = os.environ.get("GH_TOKEN", "").strip()
    if not token:
        print("ERROR: GH_TOKEN missing")
        return 1
    tag = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "v0.1-demo"
    keep = []
    if "--keep" in sys.argv:
        keep = sys.argv[sys.argv.index("--keep") + 1].split(",")

    rel = req("GET", "%s/repos/%s/%s/releases/tags/%s" % (API, OWNER, REPO, tag), token)
    assets = rel.get("assets", [])
    print("release id=%s tag=%s  assets=%d" % (rel["id"], tag, len(assets)))
    for a in assets:
        if a["name"] in keep:
            print("  keep: %s" % a["name"])
            continue
        print("  delete: %-42s (%.1f MB)" % (a["name"], a["size"] / 1048576), flush=True)
        req("DELETE", "%s/repos/%s/%s/releases/assets/%s" % (API, OWNER, REPO, a["id"]), token)

    rel2 = req("GET", "%s/repos/%s/%s/releases/tags/%s" % (API, OWNER, REPO, tag), token)
    print("remaining assets:", [x["name"] for x in rel2.get("assets", [])])
    return 0


if __name__ == "__main__":
    sys.exit(main())
