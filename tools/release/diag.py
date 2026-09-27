# -*- coding: utf-8 -*-
"""诊断 GitHub token 与仓库权限（不打印 token 本身）。"""
import json
import os
import urllib.error
import urllib.request

TOKEN = os.environ.get("GH_TOKEN", "").strip()
print("token prefix:", (TOKEN[:8] + "..." + TOKEN[-4:]) if TOKEN else "(missing)", flush=True)


def get(url):
    r = urllib.request.Request(url, headers={
        "Authorization": "token " + TOKEN,
        "User-Agent": "airts-diag",
        "Accept": "application/vnd.github+json",
    })
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:300]
    except Exception as e:  # noqa: BLE001
        return -1, "%s: %s" % (type(e).__name__, e)


st, body = get("https://api.github.com/user")
if st == 200:
    print("auth   : OK  user=%s" % body.get("login"), flush=True)
else:
    print("auth   : FAIL %s %s" % (st, body), flush=True)

st2, body2 = get("https://api.github.com/repos/GoodLoongStudio/AI_RTS")
if st2 == 200:
    print("repo   : OK  full_name=%s  private=%s  permissions=%s" % (
        body2.get("full_name"), body2.get("private"), body2.get("permissions")), flush=True)
else:
    print("repo   : FAIL %s %s" % (st2, body2), flush=True)

st3, body3 = get("https://api.github.com/user/repos?per_page=100&sort=updated")
if st3 == 200 and isinstance(body3, list):
    names = [r["full_name"] for r in body3]
    print("repos  : %d visible; contains target=%s" % (
        len(names), any(n.endswith("/AI_RTS") for n in names)), flush=True)
    for n in names[:15]:
        print("    ", n, flush=True)
else:
    print("repos  : FAIL %s %s" % (st3, str(body3)[:200]), flush=True)

st4, body4 = get("https://api.github.com/repos/GoodLoongStudio/AI_RTS/releases")
print("releases: status=%s count=%s" % (st4, len(body4) if isinstance(body4, list) else body4), flush=True)
