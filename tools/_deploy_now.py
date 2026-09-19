import paramiko, re, pathlib, hashlib

INFO = pathlib.Path(__file__).resolve().parent.parent / "服务器信息.md"
password = re.search(r"登录密码[:：]\s*(\S+)", INFO.read_text(encoding="utf-8")).group(1).replace("\\", "")
LOCAL_TAR = pathlib.Path("C:/Users/Lenovo/AppData/Local/Temp/airts_deploy.tar.gz")
LOCAL_DELETED = pathlib.Path("C:/Users/Lenovo/AppData/Local/Temp/deploy_deleted.txt")
REPO = pathlib.Path(__file__).resolve().parent.parent

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect("101.43.121.102", username="ubuntu", password=password, timeout=15)

def run(cmd, t=180):
    _, out, err = cli.exec_command(cmd, timeout=t)
    o, e = out.read().decode("utf-8", "replace"), err.read().decode("utf-8", "replace")
    return (o + e).strip()

sftp = cli.open_sftp()
print("[1] upload tar (%d bytes)..." % LOCAL_TAR.stat().st_size)
sftp.put(str(LOCAL_TAR), "/tmp/airts_deploy.tar.gz")
sftp.put(str(LOCAL_DELETED), "/tmp/deploy_deleted.txt")
print("[2] extract...")
print(run("cd /home/ubuntu/AI_RTS && tar xzf /tmp/airts_deploy.tar.gz && echo EXTRACT_OK"))
print("[3] remove deleted files...")
print(run("cd /home/ubuntu/AI_RTS && while read f; do [ -n \"$f\" ] && rm -f \"$f\"; done < /tmp/deploy_deleted.txt && echo RM_OK"))
print("[4] restart service...")
print(run("sudo -n systemctl restart airts-game 2>&1 || echo SUDO_FAIL"))
import time
time.sleep(5)
print("[5] status:", run("systemctl is-active airts-game"))
print("[6] port:", run("ss -ulnp 2>/dev/null | grep 24567 | head -1")[:80])
for rel in ("source/match/units/projectiles/Rocket.gd",
            "source/match/units/MachineGunTurret.gd",
            "source/match/units/Sniper_native_v3.glb.import"):
    local = hashlib.sha256((REPO / rel).read_bytes()).hexdigest()
    remote = run("sha256sum /home/ubuntu/AI_RTS/%s | cut -d' ' -f1" % rel)
    print("[7] %s match: %s (%s)" % (rel, local == remote, remote[:12] or "missing"))
sftp.close()
cli.close()
print("[DONE]")
