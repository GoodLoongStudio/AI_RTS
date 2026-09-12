"""Isolated, real-model exploration acceptance run. Never connects to live ports."""
import argparse
import concurrent.futures
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "source"))
from adjutant_coordinator.chat_client import ChatCompletionsClient
from adjutant_coordinator.config import ProviderSettings
from adjutant_coordinator.http_provider import HttpModelProvider
from adjutant_coordinator.provider import ModelCallContext

BASE = Path('/home/ubuntu/ai-adjutant')
REPO = BASE / 'AI_RTS'
GODOT = '/home/ubuntu/godot/Godot_v4.7.1-stable_mono_linux_x86_64/Godot_v4.7.1-stable_mono_linux.x86_64'
SERVER, CLIENT, UDP = 24577, 24578, 24575


def call(port, op, **params):
    if port not in (SERVER, CLIENT):
        raise ValueError('non-isolated port')
    with socket.create_connection(('127.0.0.1', port), 5) as sock:
        sock.settimeout(8)
        sock.sendall((json.dumps(dict(op=op, **params)) + '\n').encode())
        def read(size):
            data = b''
            while len(data) < size:
                chunk = sock.recv(size - len(data))
                if not chunk:
                    raise EOFError('incomplete frame')
                data += chunk
            return data
        size = int.from_bytes(read(4), 'little')
        if not 0 < size <= 32 * 1024 * 1024:
            raise ValueError('frame size')
        return json.loads(read(size))


def await_state(port, predicate, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            state = call(port, 'status', lite=True)
            if predicate(state):
                return state
        except (OSError, ValueError, EOFError):
            pass
        time.sleep(1)
    raise TimeoutError('isolated match did not become ready')


def load_settings(role):
    import yaml
    from dotenv import dotenv_values
    home = Path.home() / '.hermes'
    model = yaml.safe_load((home / 'config.yaml').read_text())['model']
    if model['provider'] != 'stepfun':
        raise ValueError('unreviewed model provider')
    values = dotenv_values(home / '.env')
    key = os.environ.get('STEPFUN_API_KEY') or values.get('STEPFUN_API_KEY')
    if not key:
        raise ValueError('missing server credential')
    os.environ['AI_ADJUTANT_API_KEY'] = key
    base = model.get('base_url') or values.get('STEPFUN_BASE_URL') or 'https://api.stepfun.ai/v1'
    if not base.startswith('https://'):
        raise ValueError('TLS required')
    return ProviderSettings(mode='http', role=role, model=model['default'],
                            endpoint=base.rstrip('/') + '/chat/completions', timeout_seconds=60)


def unobserved_spans(cells):
    """Lossless row intervals of sampled unknown cells; these are data, not routes."""
    rows = {}
    for x, z in cells:
        rows.setdefault(z, []).append(x)
    spans = []
    for z, xs in sorted(rows.items()):
        ordered = sorted(xs)
        start = end = ordered[0]
        for x in ordered[1:]:
            if x == end+1:
                end = x
            else:
                spans.append([z+.5, start+.5, end+.5])
                start = end = x
        spans.append([z+.5, start+.5, end+.5])
    return spans


def run_round(root, index, seconds, effort=None):
    directory = root / str(index)
    directory.mkdir()
    processes, logs = [], []
    report = {'round': index, 'ok': False, 'model_calls': [], 'receipts': [],
              'coverage_metric': '1m cell centers observed within catalog sight radius; sampled each second',
              'computer_ai': False, 'reasoning_effort':effort or 'provider_default'}
    events = (directory / 'events.jsonl').open('w', encoding='utf-8')
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    future = None
    try:
        for port, kind in ((SERVER, socket.SOCK_STREAM), (CLIENT, socket.SOCK_STREAM), (UDP, socket.SOCK_DGRAM)):
            with socket.socket(socket.AF_INET, kind) as sock:
                sock.bind(('127.0.0.1', port))
        for name, options in [('server', ['--server', '--port', str(UDP), '--debugport', str(SERVER)]),
                              ('client', ['--debugport', str(CLIENT), '--autojoin', '--autojoin-lobby',
                                          '--smokehost', '127.0.0.1', '--smokeport', str(UDP)])]:
            log = (directory / (name + '.log')).open('wb')
            logs.append(log)
            processes.append(subprocess.Popen([GODOT, '--headless', '--path', str(REPO), '--'] + options,
                                               stdin=subprocess.DEVNULL, stdout=log, stderr=log))
            await_state(SERVER if name == 'server' else CLIENT, lambda s: s.get('networked'))
        call(CLIENT, 'start', with_ai=False)
        status = await_state(SERVER, lambda s: s.get('match') and s.get('players')
                             and s.get('counts', {}).get('total', 0) > 0)
        players = status.get('players', [])
        # Empty lobby slots are generic Player nodes, also reported human=false.
        import re
        launch = (directory/'server.log').read_text(errors='replace')
        configs = re.findall(r'配置 \[([0-9, ]+)\]', launch)
        if not configs or 2 in [int(v.strip()) for v in configs[-1].split(',')]:
            raise ValueError('cannot confirm lobby has no computer AI')
        report['slot_configuration'] = configs[-1]
        player = next(p['name'] for p in players if p.get('human'))
        rules = call(SERVER, 'rules', as_player=player)
        strategic = call(SERVER, 'strategic', as_player=player)
        bounds = strategic['map_bounds']
        types = rules['unit_types']
        if isinstance(types, list):
            types = {v['id']: v for v in types}
        cells = {(x, z) for x in range(math.ceil(bounds[0])) for z in range(math.ceil(bounds[1]))}
        seen = set()
        points = [(x, z) for z in range(3, int(bounds[1]), 6) for x in range(3, int(bounds[0]), 6)]
        report.update(match_id=rules['match_id'], rules_version=rules['rules_version']['content_hash'], bounds=bounds,
                      players=players)
        instruction = ('You command an RTS exploration team with no enemy AI. Explore the ENTIRE map. '
                       'Coordinates are [x,z] in [0,width] x [0,height]. Use only observed movable own units. '
                       'Divide areas among workers, avoid revisiting covered cells, escape stuck positions. '
                       'You alone choose destinations; no scripted routes execute for you. '
                       'Return JSON {"commands":[{"units":["exact unit name"],"dest":[x,z]}],"reason":"brief"}. '
                       'At most one destination per unit, max 3 commands. No other action. '
                       'Keep output under 200 tokens, no explanation outside JSON.')
        instruction += (' Unobserved_spans encode exact remaining cells as [z,x_start,x_end]. '
                        'The coarse grid can be empty while edge cells remain. Use spans to finish ALL edges and corners. '
                        'Use sight_ranges to choose viewpoints covering gaps; try a different approach if stationary.')
        tactics_client = ChatCompletionsClient(instruction, max_tokens=8192, reasoning_effort=effort)
        tactics = HttpModelProvider(load_settings('tactics'), tactics_client)
        strategy_client = ChatCompletionsClient('Plan a full-map RTS exploration mission without opponents. '
                                               'Return JSON {"plan":{"goal":"...","assignments":[...]}}. '
                                               'Divide regions among existing movable units. No scripted AI allies. '
                                               'At most 3 assignments, keep entire response under 200 tokens. '
                                               'Do not echo the input or generate a full map grid.',
                                               max_tokens=8192, reasoning_effort=effort)
        strategy = HttpModelProvider(load_settings('strategy'), strategy_client)
        start = time.monotonic()
        next_progress = start
        next_call = start
        role = 'strategy'
        plan = None
        positions = {}
        distances = {}
        stationary_since = {}
        pending_snapshot = None
        while time.monotonic() - start < seconds:
            tactical = call(SERVER, 'tactical', as_player=player, limit=1000)
            if tactical.get('truncated'):
                raise ValueError('truncated observation')
            if tactical['match_id'] != report['match_id'] or tactical['rules_version'] != report['rules_version']:
                raise ValueError('identity drift')
            own = [e for e in tactical['entities'] if e['kind'] == 'unit_self']
            for unit in own:
                x, _, z = unit['pos']
                radius = float(types[unit['unit_type']]['sight_range'])
                if unit.get('hp', 0) > 0 and unit.get('constructed', True):
                    seen.update(c for c in cells - seen if (c[0]+.5-x)**2 + (c[1]+.5-z)**2 <= radius**2)
                if unit.get('movement'):
                    previous = positions.get(unit['name'], (x,z))
                    if math.dist(previous,(x,z)) > .1:
                        stationary_since[unit['name']] = time.monotonic()
                    stationary_since.setdefault(unit['name'],time.monotonic())
                    distances[unit['name']] = distances.get(unit['name'], 0) + math.dist(previous, (x,z))
                    positions[unit['name']] = (x,z)
            coverage = len(seen)/len(cells)
            if 'initial_coverage' not in report:
                report['initial_coverage'] = coverage
            events.write(json.dumps({'tick': tactical['server_tick'], 'coverage': coverage, 'units': own})+'\n')
            events.flush()
            if future and future.done():
                outcome = future.result()
                elapsed = time.monotonic() - issued_at
                report['model_calls'].append({'role': role, 'latency': elapsed, 'status': outcome.status,
                                              'reason': outcome.reason if outcome.reason.startswith('http ') else outcome.status,
                                              'payload': outcome.payload if outcome.status == 'completed' else None})
                if outcome.status == 'completed' and role == 'strategy':
                    plan = outcome.payload
                    role = 'tactics'
                elif outcome.status == 'completed' and role == 'tactics':
                    movable = {u['name'] for u in own if u.get('movement')}
                    used = set()
                    for proposal in (outcome.payload or [])[:3]:
                        names = proposal.get('units', [])
                        dest = proposal.get('dest', [])
                        if (not names or not set(names) <= movable or set(names) & used or len(dest) != 2
                                or not all(isinstance(v, (float,int)) and math.isfinite(v) for v in dest)
                                or not all(0 <= dest[i] <= bounds[i] for i in range(2))):
                            report['receipts'].append({'status':'InvalidModelMove'})
                            continue
                        used.update(names)
                        receipt = call(SERVER, 'adjutant_command', command_id=str(uuid.uuid4()),
                                       request_id=context.request_id, task_id='explore', plan_version='1',
                                       player_id=player, match_id=report['match_id'], rules_version=report['rules_version'],
                                       based_on_snapshot=pending_snapshot['snapshot_id'], issued_tick=pending_snapshot['server_tick'],
                                       expires_tick=pending_snapshot['server_tick']+4200, action='move',
                                       params={'units':names, 'dest':dest})
                        report['receipts'].append(receipt)
                else:
                    report['chat_usage'] = strategy_client.calls + tactics_client.calls
                    report['model_failures'] = report.get('model_failures',0)+1
                    # Keep accepted orders active. Failed outputs never become movement commands.
                    print(json.dumps({'round':index,'model_failure':outcome.status}),flush=True)
                future = None
                next_call = time.monotonic() + (0 if role == 'tactics' and len(report['model_calls']) == 1 else 8)
            if not future and time.monotonic() >= next_call and len(report['model_calls']) < 18:
                observation = {'map_bounds': bounds, 'own_units': own, 'strategy': plan,
                               'coverage':coverage, 'unobserved_grid_centers': [[x,z] for x,z in points if (x,z) not in seen],
                               'unobserved_spans':unobserved_spans(cells-seen),
                               'sight_ranges':{u['unit_type']:types[u['unit_type']]['sight_range'] for u in own},
                               'stationary_seconds':{n:round(time.monotonic()-t) for n,t in stationary_since.items()},
                               'recent_calls':report['model_calls'][-2:]}
                context = ModelCallContext(str(uuid.uuid4()), role, report['match_id'], player,
                                           report['rules_version'], snapshot_id=tactical['snapshot_id'],
                                           server_tick=tactical['server_tick'], issued_tick=tactical['server_tick'],
                                           deadline_tick=tactical['server_tick']+4200, observation=observation)
                pending_snapshot = tactical
                issued_at = time.monotonic()
                future = pool.submit((strategy if role == 'strategy' else tactics).propose, context)
            report.update(final_coverage=coverage, distance_by_unit=distances,
                          duration_seconds=time.monotonic()-start)
            if time.monotonic() >= next_progress:
                print(json.dumps({'round':index, 'elapsed':round(time.monotonic()-start),
                                  'coverage':round(coverage,4), 'model_calls':len(report['model_calls']),
                                  'accepted':sum(r.get('accepted',False) for r in report['receipts'])}), flush=True)
                next_progress = time.monotonic()+30
            if coverage >= 1.0:
                report['ok'] = True
                break
            time.sleep(1)
        report['chat_usage'] = strategy_client.calls + tactics_client.calls
        report['unobserved_cells'] = sorted(cells-seen)
        report['result'] = 'PASS' if report['ok'] else 'FAIL: exploration below 100%'
    except Exception as exc:
        report['error'] = type(exc).__name__ + ': ' + str(exc)[:160]
    finally:
        pool.shutdown(wait=True, cancel_futures=True)
        if future is not None:
            report['pending_result_discarded_at_shutdown'] = True
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(5)
        report['all_stopped'] = all(p.poll() is not None for p in processes)
        events.close()
        for log in logs:
            log.close()
        (directory/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2), encoding='utf-8')
    print(json.dumps({k:report.get(k) for k in ('round','ok','result','error','final_coverage','all_stopped')}), flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--effort', choices=['low','medium','high'])
    args = parser.parse_args()
    if not args.run_id.replace('_','').replace('-','').isalnum():
        raise ValueError('invalid run id')
    root = BASE/'runs'/args.run_id
    root.mkdir(exist_ok=False)
    results = [run_round(root,i,args.seconds,args.effort) for i in range(1,args.rounds+1)]
    (root/'summary.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
    sys.exit(0 if all(r['ok'] for r in results) else 1)
