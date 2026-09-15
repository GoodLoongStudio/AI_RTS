import paramiko, re, pathlib
INFO = pathlib.Path(__file__).resolve().parent.parent / "服务器信息.md"
password = re.search(r"登录密码[:：]\s*(\S+)", INFO.read_text(encoding="utf-8")).group(1).replace("\\", "")
cli = paramiko.SSHClient(); cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect("101.43.121.102", username="ubuntu", password=password, timeout=15)
def run(cmd, t=600):
    _, out, err = cli.exec_command(cmd, timeout=t)
    return (out.read() + err.read()).decode("utf-8", "replace").strip()
print("[godot]", run("which godot || ls /usr/local/bin/godot* /home/ubuntu/godot* 2>/dev/null | head -2"))
print("[import]", run("cd /home/ubuntu/AI_RTS && timeout 540 $(command -v godot || echo /usr/local/bin/godot) --headless --import --path . 2>&1 | tail -2", t=600)[:200])
print("[restart]", run("sudo -n systemctl restart airts-game && echo RESTART_OK"))
import time; time.sleep(4)
print("[status]", run("systemctl is-active airts-game"))
print("[port]", "24567" in run("ss -ulnp 2>/dev/null | grep 24567 | head -1"))
cli.close()
