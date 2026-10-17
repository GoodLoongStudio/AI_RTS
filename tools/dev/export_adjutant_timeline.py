"""Read-only export of an existing adjutant observation to complete output tables.

No game/runtime imports, network calls, subprocesses, or edits to source evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path


def read_text(path: Path) -> str:
    return path.read_bytes().decode('utf-8-sig')


def read_json(path: Path):
    return json.loads(read_text(path))


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in read_text(path).splitlines() if line.strip()]


def dump(value) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reltime(seconds: float) -> str:
    sign = '-' if seconds < 0 else ''
    millis = round(abs(seconds) * 1000)
    minutes, rem = divmod(millis, 60000)
    secs, ms = divmod(rem, 1000)
    return f'{sign}{minutes:02d}:{secs:02d}.{ms:03d}'


def localtime(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone(timedelta(hours=8))).isoformat(timespec='milliseconds')


def cell(text: str) -> str:
    # Markdown table delimiters, HTML syntax and physical newlines must be encoded.
    escaped = html.escape(text, quote=False).replace('|', '&#124;')
    return '<code>' + escaped.replace('\r', '&#13;').replace('\n', '<br>') + '</code>'


def link(label: str, path: Path) -> str:
    return f'[{label}](<{path.resolve().as_posix()}>)'


def source_files(run: Path) -> list[Path]:
    files = [run / name for name in ('summary.json', 'attempts.jsonl', 'http.jsonl')]
    files += sorted((run / 'attempts').glob('*.json'))
    files += sorted((run / 'http').glob('*.json'))
    files += sorted((run / 'runner-logs').glob('**/decisions.jsonl'))
    files += sorted((run / 'runner-logs').glob('**/rounds.jsonl'))
    return files


def collect(run: Path):
    summary = read_json(run / 'summary.json')
    origin = summary['observation_start']
    attempts = read_jsonl(run / 'attempts.jsonl')
    starts = {r['attempt_id']: r for r in attempts if r['kind'] == 'attempt_start'}
    ends = {r['attempt_id']: r for r in attempts if r['kind'] == 'attempt_end'}
    if len(starts) + len(ends) != len(attempts) or starts.keys() != ends.keys():
        raise ValueError('Repeated or incomplete attempt IDs; no partial export is allowed')
    http_records = read_jsonl(run / 'http.jsonl')
    requests = [r for r in http_records if r['kind'] == 'request']
    responses = {r['request_id']: r for r in http_records if r['kind'] == 'response'}
    rows, used_requests = [], set()
    for ident, end in sorted(ends.items(), key=lambda item: (item[1]['ts'], item[0])):
        start = starts[ident]
        context_path = run / 'attempts' / f'{ident}.context.json'
        result_path = run / 'attempts' / f'{ident}.result.json'
        context = read_json(context_path)
        result = read_json(result_path) if result_path.exists() else None
        if end['ok'] != (result is not None):
            raise ValueError(f'Unexpected result presence for {ident}')
        refs = [('输入上下文', context_path), ('调用流水', run / 'attempts.jsonl')]
        if result is not None:
            refs.append(('完整结果原件', result_path))
        row = dict(attempt_id=ident, role=end['role'], start=start, end=end,
                   relative_start=start['started_at'] - origin,
                   relative_end=end['ts'] - origin,
                   server_tick=context.get('server_tick'), snapshot_id=context.get('snapshot_id'),
                   http_request_id=None, output_text='', program_text='', refs=refs)
        program = ['【调用封装结束记录；ok 只表示返回/解析成功，不表示游戏采纳】', dump(end)]
        if end['role'] == 'strategy':
            candidates = [r for r in requests if r['role'] == end['role']
                          and start['started_at'] <= r['started_at'] <= end['ts']]
            matches = []
            for req in candidates:
                request_path = run / 'http' / f"{req['request_id']}.request.json"
                request = read_json(request_path)
                users = [json.loads(m['content']) for m in request['messages'] if m['role'] == 'user']
                if users == [context]:
                    matches.append((req, request_path, request))
            texts = []
            row['http_request_ids'] = []
            for req, request_path, request in matches:
                if req['request_id'] in used_requests:
                    raise ValueError('HTTP request mapped twice')
                used_requests.add(req['request_id'])
                row['http_request_ids'].append(req['request_id'])
                response_record = responses.get(req['request_id']) or {}
                response_path = run / 'http' / f"{req['request_id']}.response.json"
                response = read_json(response_path) if response_path.exists() else {}
                choices = response.get('choices', [])
                text = '\n'.join(str(c.get('message', {}).get('content') or '') for c in choices)
                texts.append(f"【{req['request_id']} 完整可见响应】\n" +
                             (text or dump(response or {'response': '未保存响应，不补写正文'})))
                program += ['【HTTP 服务元数据】', dump(dict(
                    request_id=req['request_id'], status=response_record.get('status'),
                    response_ts=response_record.get('ts'),
                    response_relative_seconds=(response_record['ts'] - origin)
                    if 'ts' in response_record else None,
                    finish_reasons=[c.get('finish_reason') for c in choices], usage=response.get('usage'),
                    max_completion_tokens=request.get('max_completion_tokens', request.get('max_tokens')),
                    context_json_equals_user_message=True))]
                row['refs'] += [('实际完整请求', request_path)]
                if response_path.exists():
                    row['refs'].append(('实际完整响应', response_path))
            row['output_text'] = '\n\n'.join(texts) or '【本次无可确认关联的 HTTP 请求；以下为调用结束原件】\n' + dump(end)
            row['http_request_id'] = row['http_request_ids'][0] if len(matches) == 1 else None
            row['http_mapping_context_equal'] = bool(matches)
            if result is not None:
                program += ['【完整解析结果，所有已保存字段】', read_text(result_path)]
            else:
                program += ['【未生成解析结果文件；左栏仍是服务端真实返回的可见原文】']
        elif end['role'] == 'tactics':
            if result is not None:
                row['output_text'] = read_text(result_path)
            else:
                row['output_text'] = '【无已保存结构化返回；以下是完整失败记录，不补写输出】\n' + dump(end)
        else:
            raise ValueError(f'Unknown role {end["role"]}')
        row['program_text'] = '\n'.join(program)
        rows.append(row)
    # 不按“最近调用”猜测归属。未能精确关联的 HTTP 原件单独保留在完整性附录。
    summary['_unmatched_http'] = [r['request_id'] for r in requests
                                  if r['request_id'] not in used_requests]
    return summary, rows


def graph_events(run: Path, origin: float) -> list[dict]:
    # Preserve outcome records independently; do not invent per-attempt correlation.
    kinds = {'strategy_result_rejected', 'strategy_degraded', 'plan_hold', 'plan_adopted'}
    result = []
    for path in sorted((run / 'runner-logs').glob('**/decisions.jsonl')):
        rounds_path = path.with_name('rounds.jsonl')
        by_tick = {}
        for record in read_jsonl(rounds_path):
            by_tick.setdefault(record['server_tick'], []).append(record['ts'])
        for line_no, record in enumerate(read_jsonl(path), 1):
            if record.get('kind') not in kinds:
                continue
            timestamps = by_tick.get(record.get('server_tick'), [])
            result.append(dict(record=record, source=path, source_line=line_no,
                               same_tick_world_timestamps=timestamps,
                               relative_world_times=[ts-origin for ts in timestamps]))
    return result


def introduction(summary: dict, rows: list[dict], html_path: Path) -> list[str]:
    counts = Counter(r['role'] for r in rows)
    failed = sum(not r['end']['ok'] for r in rows)
    return [
        '# AI 副官：10 分钟完整输出时间表', '',
        f"本表正文逐条展示 **{len(rows)} 次调用**：战略 {counts['strategy']} 次、战术 {counts['tactics']} 次。成功 {len(rows)-failed} 次，失败 {failed} 次。重复、空意图和截断回复全部保留。", '',
        f"观察零点：**{localtime(summary['observation_start'])}（UTC+08:00）**；观察时长 {summary['observed_seconds']:.6f} 秒。按 `attempt_end.ts` 从早到晚排序，同时列出调用开始时间和耗时。负时间表示采集就绪前已开始的请求；超过 10:00 的返回是本轮收尾期间取得，仍完整保留。", '',
        '战略栏直接显示 HTTP 响应 `choices[0].message.content` 的完整可见字符串，不重新排版 JSON、不补齐截断。程序栏显示 HTTP 元数据、封装返回记录和完整解析对象。', '',
        '战术使用 Laya，正文显示已保存结果文件的全部 `result / selection / laya / decode` 字段；其中 result 是转换后的意图，laya 是选择记录，decode 是解码结果。这里没有战术聊天正文或隐藏推理记录，不能据此声称已取得内部思维链。', '',
        '返回成功仅代表封装收到结果。图内实际采纳/拒绝另见文末独立事件表；这些事件按同 tick 世界记录近似标时，没有冒充某次输出的精确执行结果。最后的返回可能尚未来得及被图消费。', '',
        f'也可打开{link("可筛选阅读版（相同完整内容）", html_path)}，按角色、ID、关键词或时间筛选；本 Markdown 正文已包含全部原文，无需逐条打开 JSON。', '',
        '采集口径：既有单人无头真实 Match、command-level 菜单流程。此页只导出现有证据，未重跑对局；原独立审计仍为 18/20、rc=2。', '',
        '## 按完成时间排列的完整表', '',
    ]


def markdown(summary: dict, rows: list[dict], events: list[dict], html_path: Path) -> str:
    lines = introduction(summary, rows, html_path)
    previous_bucket = None
    for number, row in enumerate(rows, 1):
        minute = int(max(row['relative_end'], 0) // 60)
        if minute != previous_bucket:
            lines += ['', f'### {minute:02d}:00–{minute+1:02d}:00' + ('（收尾返回）' if minute >= 10 else ''), '',
                      '| 完成 / 开始 / 耗时 | 角色、编号与原件 | 完整可见输出 / 完整战术记录 | 程序返回与完整解析结果 |',
                      '|---|---|---|---|']
            previous_bucket = minute
        timing = (f"完成 {reltime(row['relative_end'])}<br>开始 {reltime(row['relative_start'])}"
                  f"<br>耗时 {row['end']['latency_s']:.6f} 秒<br>{localtime(row['end']['ts'])}")
        role = '战略 MiniCPM' if row['role'] == 'strategy' else '战术 Laya'
        ident = (f"**#{number} {row['attempt_id']}**<br>{role}<br>输入 tick {row['server_tick']}"
                 f" / snapshot {row['snapshot_id']}<br>" + '<br>'.join(link(label, path) for label, path in row['refs']))
        lines.append(f"| {timing} | {ident} | {cell(row['output_text'])} | {cell(row['program_text'])} |")
    lines += ['', '## 图内战略处理原始事件（独立表）', '',
              '下表保留全部战略拒绝、维持、采纳和降级事件。时间来自相同 server_tick 的世界记录，表示处理所在轮次的标时，不能当作事件自身带毫秒的时间戳。没有同 tick 记录时明确留空；未用最近时间强行绑定调用。', '',
              '| 世界轮次相对时间（同 tick 对齐） | 完整图内事件 | 原件行号 |', '|---|---|---|']
    for event in events:
        timing = ', '.join(reltime(t) for t in event['relative_world_times']) or '未记录同 tick 时间'
        lines.append(f"| {timing} | {cell(dump(event['record']))} | {link('decisions.jsonl', event['source'])} 第 {event['source_line']} 行 |")
    lines += ['', '## 完整性与边界', '',
              f"调用正文 {len(rows)} 行，输出字段均完整嵌入；图内战略事件 {len(events)} 行。原始上下文、请求、响应及结果可从每行链接复核。", '',
              '表内代码文本只对 Markdown/HTML 分隔符做可逆转义，换行显示为换行，没有删字段、截短、去重、修正模型内容或代写解释。战略原文以响应字符串为准，战术以既存结构化文件为准。', '']
    return '\n'.join(lines)


def html_document(summary: dict, rows: list[dict], events: list[dict], md_path: Path) -> str:
    head = '''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI 副官 · 10 分钟完整输出时间表</title>
<style>
:root{color-scheme:light;font-family:system-ui,"Microsoft YaHei",sans-serif;color:#1c2938;background:#f3f5f8}
body{margin:0}header{padding:28px 32px 14px;background:#fff}h1{font-size:26px;margin:0 0 12px}
p{line-height:1.7;max-width:1200px}a{color:#155fa0}nav{position:sticky;top:0;z-index:2;background:#fff;padding:14px 32px;box-shadow:0 2px 8px #10203018;display:flex;gap:12px;flex-wrap:wrap;align-items:center}
input,select,button{font:inherit;border:1px solid #aebdcb;border-radius:6px;padding:7px 10px;background:white;color:#1c2938}input[type=number]{width:85px}#search{width:260px}
main{padding:18px 24px}table{border-collapse:collapse;background:#fff;width:100%;table-layout:fixed}th,td{border:1px solid #d7dee7;padding:13px;text-align:left;vertical-align:top}th{background:#e9eff6}th:first-child{width:210px}th:nth-child(2){width:46%}
pre{white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.65 ui-monospace,Consolas,"Microsoft YaHei",monospace;margin:6px 0 16px}small{font-size:12px}strong.id{display:block;margin:8px 0}.badge{display:inline-block;border-radius:4px;padding:3px 6px;background:#e6f0fb}.failure{color:#a32a1c}.refs a{display:block;margin:6px 0}.muted{color:#566b7d}.event{margin:12px 0;background:#fff;border:1px solid #d7dee7;padding:16px}h2{margin:30px 0 16px}
[hidden]{display:none!important}@media(max-width:1000px){main{padding:12px}header{padding:20px}nav{padding:12px}table,tbody,tr,td{display:block}thead{display:none}td{border-bottom:0}td:last-child{border-bottom:1px solid #d7dee7;margin-bottom:16px}}
</style><header><h1>AI 副官 · 10 分钟完整输出时间表</h1>'''
    intro = introduction(summary, rows, md_path)
    head += '<p>' + html.escape(intro[2]).replace('**', '') + '</p>'
    head += '<p>按输出完成时间排列；每条输出直接展开。战略显示服务端完整可见原文，战术显示 Laya 已保存的全部结构化字段。空结果、超时与截断均保留。<br>'
    head += '观察零点：' + localtime(summary['observation_start']) + '；时间为 UTC+08:00。返回成功不表示图内采纳；战略处理事件在文末独立展示。</p>'
    head += '<p><a href="' + html.escape(md_path.resolve().as_uri(), quote=True) + '">打开同内容完整 Markdown</a> · 原采集审计 18/20、rc=2；本页只做证据导出，未重跑游戏。</p></header>'
    head += '''<nav><label>角色 <select id="role"><option value="all">全部</option><option value="strategy">战略 MiniCPM</option><option value="tactics">战术 Laya</option></select></label>
<label>状态 <select id="state"><option value="all">全部</option><option value="ok">成功返回</option><option value="error">失败</option></select></label>
<input id="search" type="search" placeholder="搜索 ID、原文、任务、错误" aria-label="搜索全部内容">
<label>从 <input id="from" type="number" step="0.001" placeholder="秒"></label><label>到 <input id="to" type="number" step="0.001" placeholder="秒"></label>
<button id="reset">显示全部</button><strong id="count"></strong></nav><main><table><thead><tr><th>时间与调用</th><th>完整可见输出 / 战术记录</th><th>程序返回与完整解析结果</th></tr></thead><tbody>'''
    parts = [head]
    for number, row in enumerate(rows, 1):
        role = '战略 MiniCPM' if row['role'] == 'strategy' else '战术 Laya'
        state = 'ok' if row['end']['ok'] else 'error'
        refs = ''.join(f'<a href="{html.escape(p.resolve().as_uri(), quote=True)}">{html.escape(label)}</a>' for label, p in row['refs'])
        parts.append(f'<tr data-id="{row["attempt_id"]}" data-role="{row["role"]}" data-state="{state}" data-time="{row["relative_end"]!r}">'
                     f'<td><span class="badge">{role}</span><strong class="id">#{number} {row["attempt_id"]}</strong>'
                     f'<b>完成 {reltime(row["relative_end"])}</b><br>开始 {reltime(row["relative_start"])}<br>耗时 {row["end"]["latency_s"]:.6f} 秒'
                     f'<p class="{"failure" if state=="error" else "muted"}">{"成功返回" if state=="ok" else "失败"}<br>'
                     f'输入 tick {row["server_tick"]}<br>snapshot {row["snapshot_id"]}<br><small>{localtime(row["end"]["ts"])}</small></p><div class="refs">{refs}</div></td>'
                     f'<td><pre class="output">{html.escape(row["output_text"])}</pre></td>'
                     f'<td><pre class="program">{html.escape(row["program_text"])}</pre></td></tr>')
    parts += ['</tbody></table><h2>图内战略处理原始事件（独立表）</h2>',
              '<p>下面的时间取同 tick 世界轮次记录，不是事件自身的精确时间，也没有强行绑定到某次调用。</p>']
    for event in events:
        times = ', '.join(reltime(t) for t in event['relative_world_times']) or '未记录同 tick 时间'
        parts.append('<article class="event"><b>' + times + '</b><pre>' + html.escape(dump(event['record'])) + '</pre>'
                     '<a href="' + html.escape(event['source'].resolve().as_uri(), quote=True) + '">原件第 ' + str(event['source_line']) + ' 行</a></article>')
    parts.append('''</main><script>
const rows=Array.from(document.querySelectorAll('tr[data-id]'));
const ids=['role','state','search','from','to'];
function filter(){const role=document.getElementById('role').value;const state=document.getElementById('state').value;
const q=document.getElementById('search').value.toLocaleLowerCase();const low=document.getElementById('from').value;const high=document.getElementById('to').value;
let count=0;for(const row of rows){const t=Number(row.dataset.time);const show=(role==='all'||row.dataset.role===role)&&(state==='all'||row.dataset.state===state)&&(!q||row.textContent.toLocaleLowerCase().includes(q))&&(low===''||t>=Number(low))&&(high===''||t<=Number(high));row.hidden=!show;if(show)count++;}
document.getElementById('count').textContent='显示 '+count+' / '+rows.length+' 条';}
for(const id of ids)document.getElementById(id).addEventListener('input',filter);
document.getElementById('reset').addEventListener('click',()=>{for(const id of ids)document.getElementById(id).value=(id==='role'||id==='state')?'all':'';filter();});filter();
</script></html>''')
    return '\n'.join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='Complete Markdown path')
    args = parser.parse_args()
    run, output = args.run.resolve(), args.output.resolve()
    # The exporter may add new artifacts, never overwrite any existing file.
    html_path = output.with_suffix('.html')
    manifest_path = output.with_suffix('.manifest.json')
    paths = (output, html_path, manifest_path)
    for p in paths:
        if p.exists():
            raise FileExistsError(f'Refusing to overwrite {p}')
    sources = source_files(run)
    before = {p.relative_to(run).as_posix(): digest(p) for p in sources}
    summary, rows = collect(run)
    events = graph_events(run, summary['observation_start'])
    md = markdown(summary, rows, events, html_path)
    document = html_document(summary, rows, events, output)
    after = {p.relative_to(run).as_posix(): digest(p) for p in sources}
    if before != after:
        raise RuntimeError('Source evidence changed during export')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(md, encoding='utf-8', newline='\n')
    html_path.write_text(document, encoding='utf-8', newline='\n')
    manifest = dict(exported_at=datetime.now(timezone.utc).isoformat(), run=run.as_posix(),
                    observation_start=summary['observation_start'],
                    observation_seconds=summary['observed_seconds'],
                    counts=dict(Counter(r['role'] for r in rows)),
                    attempts=len(rows), failures=sum(not r['end']['ok'] for r in rows),
                    graph_events=len(events), source_hashes=before, source_unchanged=before == after,
                    outputs={p.as_posix(): digest(p) for p in (output, html_path)},
                    rows=[dict(attempt_id=r['attempt_id'], end_ts=r['end']['ts'],
                               relative_start=r['relative_start'], relative_end=r['relative_end'],
                               http_request_id=r['http_request_id'],
                               http_mapping_context_equal=r.get('http_mapping_context_equal'),
                               visible_output_sha256=hashlib.sha256(r['output_text'].encode('utf-8')).hexdigest())
                          for r in rows])
    manifest_path.write_text(dump(manifest) + '\n', encoding='utf-8')
    print(dump(dict(markdown=output.as_posix(), html=html_path.as_posix(), manifest=manifest_path.as_posix(),
                    attempts=len(rows), counts=manifest['counts'], failures=manifest['failures'],
                    source_unchanged=manifest['source_unchanged'], markdown_bytes=output.stat().st_size,
                    first_end=reltime(rows[0]['relative_end']), last_end=reltime(rows[-1]['relative_end']))))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
