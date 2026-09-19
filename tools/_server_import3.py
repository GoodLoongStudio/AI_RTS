import paramiko, re, pathlib
INFO = pathlib.Path(__file__).resolve().parent.parent / "服务器信息.md"
password = re.search(r"登录密码[:：]\s*(\S+)", INFO.read_text(encoding="utf-8")).group(1).replace("\\", "")
cli = paramiko.SSHClient(); cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect("101.43.121.102", username="ubuntu", password=password, timeout=15)
def run(cmd, t=900):
    _, out, err = cli.exec_command(cmd, timeout=t)
    return (out.read() + err.read()).decode("utf-8", "replace").strip()
gbin = run("find /home/ubuntu/godot -maxdepth 2 -type f -name 'Godot*' -perm -u+x | head -3")
print("[bin candidates]", gbin)
BIN = gbin.splitlines()[0] if gbin else ""
if BIN:
    print("[import-start]", run("cd /home/ubuntu/AI_RTS && nohup timeout 560 %s --headless --import --path . > /tmp/import.log 2>&1 & echo LAUNCHED" % BIN))
    import time
    for i in range(30):
        time.sleep(20)
        running = run("pgrep -af 'headless --import' | head -1")
        print("[wait %d] running=%s" % (i, bool(running)))
        if not running:
            break
    print("[import-tail]", run("tail -3 /tmp/import.log")[:400])
    print("[restart]", run("sudo -n systemctl restart airts-game && echo RESTART_OK"))
    import time; time.sleep(4)
    print("[status]", run("systemctl is-active airts-game"))
    print("[port]", "24567" in run("ss -ulnp 2>/dev/null | grep 24567 | head -1"))
cli.close()
