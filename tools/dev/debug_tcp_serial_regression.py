#!/usr/bin/env python3
"""Serial full-suite runner v2 (2026-10-11 debug-tcp corrective P0).

相对 v1（存档：agent/runs/2026-10-11-dtcp-corrective/driver-v1-archive/）的变更：

1. **双端口分离**：v1 把同一个临时端口同时替换 `{free_port}`（DCS `--debugport`）与
   `GODOT_BRIDGE_PORT`（MCP）→ 同进程两个 TCPServer 抢同一地址，DCS 成功后 MCP
   必 error 22（已证实的工具错误）。v2 从 `config/dev_ports.json` 的 `dynamic_dev`
   段实测挑一段空闲块（复用 tools/dev/match_instance.py），DCS 用 base+1、bridge
   用 base+3，断言不同；不声称原子预留（bind 探测存在启动竞态，由启动后核验兜住）。
2. **启动资格核验**：DCS/MCP 监听成功日志 + 内核监听 PID 归属本轮进程树
   （Get-NetTCPConnection + 祖先链比对）。绑定失败或归属不符 ⇒ 环境失败，
   换端口重启，最多 RESTART_LIMIT 次；绝不连接其它已监听实例。
3. **--ids / --out / --run-id / --resume**：断点续跑只允许相同 driver/源码/配置 hash
   与相同测试清单（防混合树）；环境失败的行会重跑，其余完成行跳过。
4. **有界 watchdog**：= 套件 `timeout_seconds` + STARTUP_GRACE_S（启动/退出余量，
   明确说明）；不再使用 v1 的 +240s 兜底。超时 ⇒ kill 本轮拥有进程树并记录。
5. **cleanup_ok**：进程树（wrapper + 记录到的游戏 PID）退出核验。
6. 判绿（strict_pass）= `rc0 + marker + 原 forbidden 为空 + 无超时 + cleanup_ok`
   + 监听资格通过 + 非环境失败。判据口径（forbidden/marker/--quit-after/权限语义）
   与 v1 保持一致，只修端口分配与资格错误。

权限语义（保持不变）：
- 带 `{free_port}` 的套件用本轮显式 DCS 端口；
- 不带 `--debugport` 的套件保持受限模式（DCS=ADJUTANT_PORT 24579）。若 24579 被
  占用：对已确认纯静态、不依赖服务的套件（STATIC_SUITES_NO_ADJUTANT_OK）注入
  `--no-adjutant` 并标注"此样本不验证受限服务"；其余套件记环境失败。
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path('G:/AIRTS/AI_RTS')
DRIVER_VERSION = '2.0.0'
CREATE_NO_WINDOW = 0x08000000
STARTUP_GRACE_S = 30          # watchdog = 套件 timeout_seconds + 此余量（启动/退出开销）
LISTEN_WAIT_S = 25            # 等待两条监听出现并做内核归属核验的窗口
RESTART_LIMIT = 2             # 环境失败时换端口重启的最大次数（共 1+2 次尝试）
ADJUTANT_PORT = 24579         # 受限模式 DCS 端口（source/net/DebugControlServer.gd:21）

# 已确认纯静态、不依赖服务（源码检查 + 静态函数调用，无 TCP）的套件；
# 仅在 24579 被占用时注入 --no-adjutant（标注后仍有资格缺口）。
STATIC_SUITES_NO_ADJUTANT_OK = {
    'adjutant-connectivity',          # tests/automated/AdjutantConnectivitySmokeTest.gd
    'adjutant-ui-state-consistency',  # tests/automated/AdjutantUIStateConsistencyTest.gd
    'adjutant-tcp-framing',           # 本地随机端口 TCPServer，不依赖 DCS/受限服务
}

DCS_LISTEN_FMT = '[DBGCTL] 调试控制端点已启动 127.0.0.1:%d'
DCS_BIND_FAIL_FMT = '[DBGCTL] 端口 %d 被占用'
MCP_LISTEN_FMT = 'McpInteractionServer: Listening on 127.0.0.1:%d'
MCP_FAIL_FMT = 'McpInteractionServer: Failed to listen on port %d'

try:  # GBK 控制台下避免 UnicodeEncodeError
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def load_match_instance():
    sys.path.insert(0, str(ROOT / 'tools' / 'dev'))
    import match_instance  # noqa: E402
    return match_instance


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def read_text_safe(path) -> str:
    try:
        return Path(path).read_text(encoding='utf-8', errors='replace')
    except OSError:
        return ''


def compute_identity(ids, godot_exe) -> dict:
    return {
        'driver_version': DRIVER_VERSION,
        'driver_sha256': sha256_file(Path(__file__)),
        'dcs_sha256': sha256_file(ROOT / 'source/net/DebugControlServer.gd'),
        'client_sha256': sha256_file(ROOT / 'source/ui/AdjutantButton.gd'),
        'suite_config_sha256': sha256_file(ROOT / 'config/full_regression_suite.json'),
        'ids': list(ids),
        'godot': godot_exe,
    }


def listener_kernel_check(ports, root_pid, timeout=45):
    """返回 {'ok': True/False/None, 'listeners': {port: [pid]}, 'ancestors': {pid:[...]}}。

    ok=None 表示内核查询工具不可用（不据此判失败，仅降级证据）。
    """
    if os.name != 'nt':
        return {'ok': None, 'error': 'not windows'}
    port_list = ','.join(str(int(p)) for p in ports)
    ps = (
        "$res=@{};"
        "foreach($p in @(%(ports)s)){"
        " $o=Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue"
        " | Select-Object -ExpandProperty OwningProcess;"
        " $res[\"$p\"]=@($o)};"
        "$anc=@{};"
        "foreach($p in @(%(ports)s)){ foreach($opid in $res[\"$p\"]){ $chain=@(); $cur=$opid;"
        " for($i=0;$i -lt 6;$i++){ $proc=Get-CimInstance Win32_Process -Filter \"ProcessId=$cur\""
        " -ErrorAction SilentlyContinue; if(-not $proc){break};"
        " $parent=$proc.ParentProcessId; $chain+=$parent; $cur=$parent }; $anc[\"$opid\"]=$chain } };"
        "ConvertTo-Json -Compress -Depth 5 @{listeners=$res; ancestors=$anc}"
    ) % {'ports': port_list}
    try:
        proc = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', ps],
                              capture_output=True, text=True, encoding='utf-8',
                              errors='replace', timeout=timeout,
                              creationflags=CREATE_NO_WINDOW)
        data = json.loads((proc.stdout or '').strip() or '{}')
    except Exception as exc:  # noqa: BLE001
        return {'ok': None, 'error': repr(exc)}
    listeners = data.get('listeners', {}) or {}
    ancestors = data.get('ancestors', {}) or {}
    owners = {}
    in_tree = {}
    for port in ports:
        pids = [int(x) for x in (listeners.get(str(port)) or []) if str(x).strip().isdigit()]
        owners[int(port)] = pids
        for opid in pids:
            chain = [int(x) for x in (ancestors.get(str(opid)) or []) if str(x).strip().isdigit()]
            in_tree[opid] = (opid == root_pid) or (root_pid in chain)
    ok = bool(in_tree) and all(in_tree.values())
    return {'ok': ok, 'listeners': owners, 'in_tree': in_tree}


def run_one(test, pats, out_dir, mi, godot_exe, watchdog_grace_s):
    tid = test['id']
    timeout_s = int(test.get('timeout_seconds', 120)) + watchdog_grace_s
    needs_dcs = any('{free_port}' in str(x) for x in test.get('extra_args', []))
    history = []
    attempt = 0
    row = None
    while attempt <= RESTART_LIMIT:
        attempt += 1
        block = mi.allocate_ports()
        dcs_port = block['client_dcs']    # base+1，port_free 已验证（TCP+UDP）
        bridge_port = block['server_dcs']  # base+3，port_free 已验证
        if dcs_port == bridge_port:
            raise RuntimeError('internal: dcs/bridge port collision')
        auto_no_adjutant = False
        listen_note = ''
        expect_dcs = needs_dcs
        dcs_expect_port = dcs_port
        if not needs_dcs:
            if mi.port_free(ADJUTANT_PORT):
                expect_dcs = True
                dcs_expect_port = ADJUTANT_PORT
            elif tid in STATIC_SUITES_NO_ADJUTANT_OK:
                auto_no_adjutant = True
                expect_dcs = False
                listen_note = ('default DCS port %d busy; --no-adjutant injected '
                               '(restricted service NOT exercised)' % ADJUTANT_PORT)
            else:
                # 受限口 24579 被占且套件未确认纯静态：换端口无意义（24579 是
                # 产品语义，不扩产品端口凑绿），直接记环境失败行（此前此路径
                # 三连 continue 会让 row=None 并在 persist 崩溃——v2.1 修复）。
                mi.release_ports(block)
                return {
                    'id': tid, 'returncode': None, 'marker_found': False,
                    'forbidden_hits': [], 'strict_pass': False, 'runner_pass': False,
                    'timeout': False, 'seconds': 0.0, 'wrapper_pid': 0,
                    'game_pids': [], 'cleanup_ok': True,
                    'listen': {'dcs': False, 'bridge': False,
                               'bind_fail': 'default_dcs_port_busy',
                               'pid_verify': 'skipped',
                               'expected_ports': [ADJUTANT_PORT],
                               'kernel_listeners': {}},
                    'adjutant_disabled': False, 'listen_note': '',
                    'environment_fail': True,
                    'env_fail_reason': 'default DCS port %d busy and suite not '
                                       'confirmed static' % ADJUTANT_PORT,
                    'attempt': attempt, 'attempts_history': history,
                    'dcs_port': 0, 'bridge_port': 0,
                    'log': '', 'command': [], 'error_lines': [],
                }
        extra = [str(x).replace('{free_port}', str(dcs_port)) for x in test.get('extra_args', [])]
        if auto_no_adjutant:
            extra = extra + ['--no-adjutant']
        cmd = [godot_exe, '--headless', '--path', str(ROOT), '--quit-after', '200000',
               test['scene']] + extra
        env = dict(os.environ)
        env['AIRTS_INSTANCE_DIR'] = ''
        env['AIRTS_INSTANCE_STRICT_DCS'] = '0'
        env['GODOT_BRIDGE_PORT'] = str(bridge_port)
        logpath = out_dir / (tid + '.log')
        if logpath.exists():
            logpath.rename(logpath.with_suffix('.interrupted-%d.log' % int(time.time())))
        expect_ports = ([dcs_expect_port] if expect_dcs else []) + [bridge_port]
        t0 = time.time()
        listen = {'dcs': False, 'bridge': False, 'bind_fail': '', 'pid_verify': 'pending',
                  'kernel': None}
        timedout = False
        with logpath.open('xb') as log:
            proc = subprocess.Popen(cmd, cwd=str(ROOT), env=env, stdout=log,
                                    stderr=subprocess.STDOUT, creationflags=CREATE_NO_WINDOW)
            listen_deadline = t0 + LISTEN_WAIT_S
            while time.time() < listen_deadline and proc.poll() is None:
                text = read_text_safe(logpath)
                if expect_dcs and (DCS_LISTEN_FMT % dcs_expect_port) in text:
                    listen['dcs'] = True
                if (MCP_LISTEN_FMT % bridge_port) in text:
                    listen['bridge'] = True
                if expect_dcs and (DCS_BIND_FAIL_FMT % dcs_expect_port) in text:
                    listen['bind_fail'] = 'dcs_port_in_use'
                    break
                if (MCP_FAIL_FMT % bridge_port) in text:
                    listen['bind_fail'] = 'bridge_port_in_use'
                    break
                log_ready = (listen['dcs'] or not expect_dcs) and listen['bridge']
                if log_ready and listen['pid_verify'] in ('pending', 'retry'):
                    kernel = listener_kernel_check(expect_ports, proc.pid)
                    listen['kernel'] = kernel
                    if kernel['ok']:
                        listen['pid_verify'] = 'ok'
                        break
                    if kernel['ok'] is None and listen['pid_verify'] == 'retry':
                        listen['pid_verify'] = 'unavailable'
                        break
                    listen['pid_verify'] = 'retry'
                time.sleep(0.4)
            # 监听阶段结束（进程可能已自然退出）：最终日志复核 + 一次内核复核
            text = read_text_safe(logpath)
            if expect_dcs and (DCS_LISTEN_FMT % dcs_expect_port) in text:
                listen['dcs'] = True
            if (MCP_LISTEN_FMT % bridge_port) in text:
                listen['bridge'] = True
            if proc.poll() is not None:
                # Process exited: the listen success lines come from this very
                # process stdout, which is sufficient proof; downgrade pending AND
                # retry (retry = kernel check did not finish before exit).
                if listen['pid_verify'] in ('pending', 'retry') \
                        and (listen['dcs'] or not expect_dcs) and listen['bridge']:
                    listen['pid_verify'] = 'process_exited'
            elif listen['pid_verify'] == 'pending':
                kernel = listener_kernel_check(expect_ports, proc.pid)
                listen['kernel'] = kernel
                if kernel['ok']:
                    listen['pid_verify'] = 'ok'
                elif kernel['ok'] is None:
                    listen['pid_verify'] = 'unavailable'
                else:
                    listen['pid_verify'] = 'mismatch'
            try:
                rc = proc.wait(timeout=max(5, timeout_s - (time.time() - t0)))
            except subprocess.TimeoutExpired:
                timedout = True
                mi.kill_tree(proc.pid)
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    pass
                rc = -9
        text = read_text_safe(logpath)
        hits = [x.pattern for x in pats if x.search(text)]
        marker = test.get('expected_marker', '')
        found = bool(marker) and marker in text
        cleanup_ok = not mi.is_pid_running(proc.pid)
        game_pids = sorted({pid for pids in (listen.get('kernel') or {}).get('listeners', {}).values()
                            for pid in pids})
        for gpid in game_pids:
            cleanup_ok = cleanup_ok and not mi.is_pid_running(gpid)
        listen_ok = ((listen['dcs'] or not expect_dcs) and listen['bridge']
                     and not listen['bind_fail']
                     and listen['pid_verify'] in ('ok', 'unavailable', 'process_exited'))
        environment_fail = bool(listen['bind_fail']) or not listen_ok
        strict = (rc == 0 and found and not hits and not timedout
                  and cleanup_ok and listen_ok and not environment_fail)
        row = {
            'id': tid, 'returncode': rc, 'marker_found': found, 'forbidden_hits': hits,
            'strict_pass': strict, 'runner_pass': rc == 0 and found, 'timeout': timedout,
            'seconds': round(time.time() - t0, 3),
            'wrapper_pid': proc.pid, 'game_pids': game_pids, 'cleanup_ok': cleanup_ok,
            'listen': {'dcs': listen['dcs'], 'bridge': listen['bridge'],
                       'bind_fail': listen['bind_fail'], 'pid_verify': listen['pid_verify'],
                       'expected_ports': expect_ports,
                       'kernel_listeners': (listen.get('kernel') or {}).get('listeners', {})},
            'adjutant_disabled': auto_no_adjutant, 'listen_note': listen_note,
            'environment_fail': environment_fail,
            'attempt': attempt, 'attempts_history': history,
            'dcs_port': dcs_port if needs_dcs else (ADJUTANT_PORT if expect_dcs else 0),
            'bridge_port': bridge_port,
            'log': str(logpath), 'command': cmd,
            'error_lines': [line for line in text.splitlines()
                            if any(x.search(line) for x in pats)][:30],
        }
        mi.release_ports(block)
        if not environment_fail:
            break
        history.append({'attempt': attempt, 'env_fail': listen['bind_fail'] or 'listen_missing',
                        'pid_verify': listen['pid_verify'],
                        'dcs_port': dcs_port, 'bridge_port': bridge_port})
        time.sleep(1)
    return row


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--run-id', default=time.strftime('%Y%m%d-%H%M%S') + '-serial')
    parser.add_argument('--out', default='', help='输出目录（默认 agent/runs/<run-id>/serial）')
    parser.add_argument('--ids', default='', help='逗号分隔的套件 id 子集（默认全部）')
    parser.add_argument('--resume', action='store_true',
                        help='续跑已存在 out/results.json（要求身份 hash 完全一致）')
    parser.add_argument('--godot', default='', help='Godot console 可执行文件（默认自动定位）')
    parser.add_argument('--watchdog-grace-s', type=int, default=STARTUP_GRACE_S,
                        help='watchdog 在套件 timeout_seconds 之上附加的启动/退出余量秒数')
    args = parser.parse_args(argv)
    watchdog_grace_s = int(args.watchdog_grace_s)

    mi = load_match_instance()
    godot_exe = args.godot or mi.godot_exe()
    out_dir = Path(args.out) if args.out else (ROOT / 'agent/runs' / args.run_id / 'serial')
    out_dir.mkdir(parents=True, exist_ok=True)

    suite = json.loads((ROOT / 'config/full_regression_suite.json').read_text(encoding='utf-8-sig'))
    pats = [re.compile(x) for x in suite['forbidden_output_patterns']]
    by_id = {t['id']: t for t in suite['godot_tests']}
    if args.ids:
        ids = [x.strip() for x in args.ids.split(',') if x.strip()]
        missing = [x for x in ids if x not in by_id]
        if missing:
            print('UNKNOWN ids: %s' % missing, flush=True)
            return 2
    else:
        ids = list(by_id.keys())

    identity = compute_identity(ids, godot_exe)
    identity['run_id'] = args.run_id
    identity['started'] = time.time()
    results_path = out_dir / 'results.json'
    rows = []
    if results_path.exists():
        if not args.resume:
            print('REFUSE: %s already exists; pass --resume (identity-checked) or a new --out'
                  % results_path, flush=True)
            return 2
        prev = json.loads(results_path.read_text(encoding='utf-8'))
        prev_identity = dict(prev.get('identity', {}))
        prev_identity.pop('started', None)
        mine = dict(identity)
        mine.pop('started', None)
        if prev_identity != mine:
            print('REFUSE resume: identity mismatch', flush=True)
            for key in sorted(set(prev_identity) | set(mine)):
                if prev_identity.get(key) != mine.get(key):
                    print('  %s: prev=%r now=%r'
                          % (key, prev_identity.get(key), mine.get(key)), flush=True)
            return 2
        rows = [r for r in prev.get('rows', []) if not r.get('environment_fail')]
        print('RESUME: %d completed row(s) kept, %d re-run candidate(s)'
              % (len(rows), len(prev.get('rows', [])) - len(rows)), flush=True)

    def persist():
        payload = {
            'run_id': args.run_id, 'driver_version': DRIVER_VERSION,
            'identity': identity, 'out_dir': str(out_dir),
            'updated': time.time(), 'total_expected': len(ids),
            'completed': len(rows),
            'strict_pass': sum(bool(x['strict_pass']) for x in rows),
            'environment_fail': sum(bool(x.get('environment_fail')) for x in rows),
            'rows': rows,
        }
        tmp = results_path.with_suffix('.json.tmp')
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding='utf-8')
        os.replace(tmp, results_path)

    done = {r['id'] for r in rows}
    for tid in ids:
        if tid in done:
            print('%s SKIP (resume: completed)' % tid, flush=True)
            continue
        cur_dcs = sha256_file(ROOT / 'source/net/DebugControlServer.gd')
        cur_client = sha256_file(ROOT / 'source/ui/AdjutantButton.gd')
        if cur_dcs != identity['dcs_sha256'] or cur_client != identity['client_sha256']:
            print('STOP: source changed mid-run (dcs=%s.. client=%s..); use a new run-id'
                  % (cur_dcs[:12], cur_client[:12]), flush=True)
            persist()
            return 3
        row = run_one(by_id[tid], pats, out_dir, mi, godot_exe, watchdog_grace_s)
        rows.append(row)
        persist()
        print('%s rc=%s strict=%s env_fail=%s listen(dcs=%s bridge=%s pid=%s) '
              'forbidden=%s timeout=%s %.1fs'
              % (tid, row['returncode'], row['strict_pass'], row['environment_fail'],
                 row['listen']['dcs'], row['listen']['bridge'], row['listen']['pid_verify'],
                 row['forbidden_hits'], row['timeout'], row['seconds']), flush=True)
    strict = sum(bool(x['strict_pass']) for x in rows)
    envfail = sum(bool(x.get('environment_fail')) for x in rows)
    print('COMPLETE total=%d strict=%d env_fail=%d out=%s'
          % (len(rows), strict, envfail, out_dir), flush=True)
    return 0 if strict == len(rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
