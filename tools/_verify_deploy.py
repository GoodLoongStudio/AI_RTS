import paramiko, re, pathlib, hashlib
INFO = pathlib.Path(__file__).resolve().parent.parent / "服务器信息.md"
password = re.search(r"登录密码[:：]\s*(\S+)", INFO.read_text(encoding="utf-8")).group(1).replace("\\", "")
REPO = pathlib.Path(__file__).resolve().parent.parent
cli = paramiko.SSHClient(); cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect("101.43.121.102", username="ubuntu", password=password, timeout=15)
def run(cmd, t=60):
    _, out, err = cli.exec_command(cmd, timeout=t)
    return (out.read() + err.read()).decode("utf-8", "replace").strip()
print("[status]", run("systemctl is-active airts-game"))
ok = True
for rel in ("source/net/NetSync.gd", "source/match/units/Unit.gd",
            "source/match/units/Sniper.tscn", "source/match/units/Rocketeer.tscn",
            "source/match/units/HeavyTank.tscn", "source/match/hud/ra3/Ra3Sidebar.gd",
            "config/balance/demo.balance.v1.json"):
    local = hashlib.sha256((REPO / rel).read_bytes()).hexdigest()
    remote = run("sha256sum /home/ubuntu/AI_RTS/%s | cut -d' ' -f1" % rel)
    match = local == remote
    ok = ok and match
    print("[%s] %s (%s)" % ("OK " if match else "DIFF", rel, remote[:12] or "missing"))
cli.close()
print("[ALL MATCH]" if ok else "[SOME DIFF]")
