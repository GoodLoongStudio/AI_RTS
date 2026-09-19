import paramiko, re, pathlib
INFO = pathlib.Path(__file__).resolve().parent.parent / "服务器信息.md"
password = re.search(r"登录密码[:：]\s*(\S+)", INFO.read_text(encoding="utf-8")).group(1).replace("\\", "")
cli = paramiko.SSHClient(); cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect("101.43.121.102", username="ubuntu", password=password, timeout=15)
def run(cmd, t=900):
    _, out, err = cli.exec_command(cmd, timeout=t)
    return (out.read() + err.read()).decode("utf-8", "replace").strip()
BIN = "/home/ubuntu/godot/Godot_v4.7.1-stable_mono_linux_x86_64"
gbin = run("ls %s 2>/dev/null | head -1" % BIN)
print("[bin]", BIN + "/" + gbin)
print("[import-start]", run("cd /home/ubuntu/AI_RTS && nohup timeout 560 %s/%s --headless --import --path . > /tmp/import.log 2>&1 & echo LAUNCHED" % (BIN, gbin)))
import time
for i in range(30):
    time.sleep(20)
    running = run("pgrep -af 'headless --import' | head -1")
    print("[wait %d] running=%s" % (i, bool(running)))
    if not running:
        break
print("[import-tail]", run("tail -3 /tmp/import.log")[:300])
print("[restart]", run("sudo -n systemctl restart airts-game && echo RESTART_OK"))
time.sleep(4)
print("[status]", run("systemctl is-active airts-game"))
print("[port]", "24567" in run("ss -ulnp 2>/dev/null | grep 24567 | head -1"))
cli.close()
