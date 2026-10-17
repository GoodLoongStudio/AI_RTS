"""Read-only loop/branch replay for a completed adjutant observation."""
from __future__ import annotations

import argparse
import ast
import bisect
import html
import json
from collections import Counter
from datetime import datetime,timezone
from pathlib import Path

import export_adjutant_timeline as raw


ROOT=Path(__file__).resolve().parents[2]
FIGURE_NAMES=('adjutant-runtime-loop','adjutant-goal-feedback-loop','adjutant-economy-breakpoint')
ROUTE_CN={'strategic':'战略调度','tactical':'战术调度','wait':'等待/保持既有任务',
          'player_interrupt':'玩家打断','emergency_tactical':'紧急战术'}


def source_audit(run:Path):
    frozen=raw.read_json(run/'source-before.json')
    result={}
    for name in ('graph.py','nodes.py','decision_map.py','campaign.py'):
        p=ROOT/'source/adjutant_coordinator/graph'/name
        sha=raw.digest(p)
        result[name]=dict(path=p.as_posix(),sha256=sha,observed_sha256=frozen.get(str(p)),matches_sample=frozen.get(str(p))==sha)
    return result


def collect(run:Path):
    summary=raw.read_json(run/'summary.json');origin=summary['observation_start']
    archives=sorted((run/'runner-logs').glob('**/rounds.jsonl'))
    if len(archives)!=1:
        raise ValueError('Expected exactly one completed Match archive')
    rounds=raw.read_jsonl(archives[0]);decisions=raw.read_jsonl(archives[0].with_name('decisions.jsonl'))
    commands=raw.read_jsonl(archives[0].with_name('commands.jsonl'))
    # Segment the sequential decision log at event_classified; include same-round
    # pre-classification events as well. Never merge separate occurrences of a tick.
    sections=[];current=[]
    for line_no,event in enumerate(decisions,1):
        if event['kind']=='event_classified':
            sections.append(dict(classify=event,events=[],classify_line=line_no))
        if sections:
            sections[-1]['events'].append(dict(line=line_no,record=event))
    # World tick can occur multiple times; match classified records in sequence.
    if len(rounds)!=len(sections) or any(r['server_tick']!=s['classify']['server_tick'] or r['route']!=s['classify']['route'] for r,s in zip(rounds,sections)):
        raise ValueError('Round/classification identity mismatch; do not guess correlation')
    _,calls=raw.collect(run)
    call_times=[r['end']['ts'] for r in calls]
    states=raw.read_jsonl(run/'strategy-state.jsonl');state_times=[r['ts'] for r in states]
    frames=[]
    for i,(world,section) in enumerate(zip(rounds,sections)):
        ts=world['ts'];ci=bisect.bisect_right(call_times,ts)-1;si=bisect.bisect_right(state_times,ts)-1
        last_call=calls[ci] if ci>=0 else None;state=states[si] if si>=0 else None
        frame=dict(index=i,ts=ts,relative_seconds=ts-origin,server_tick=world['server_tick'],route=world['route'],
                   balance=world.get('balance'),unit_count=len(world.get('units') or []),
                   route_record=section['classify'],classify_line=section['classify_line'],
                   events=section['events'],state=state,
                   state_age_seconds=(ts-state['ts']) if state else None,
                   last_completed_call=(dict(attempt_id=last_call['attempt_id'],role=last_call['role'],ts=last_call['end']['ts'],
                                             ok=last_call['end']['ok'],relative_seconds=last_call['relative_end']) if last_call else None))
        frames.append(frame)
    # One evidence record per model attempt. No inference of a returned plan being
    # applied to a specific graph round.
    contexts=[]
    for c in calls:
        p=run/'attempts'/(c['attempt_id']+'.context.json');ctx=raw.read_json(p)
        camp=ctx.get('campaign') or {}
        contexts.append(dict(attempt_id=c['attempt_id'],role=c['role'],relative_seconds=c['relative_end'],
                             start_ts=c['start']['started_at'],end_ts=c['end']['ts'],input_tick=ctx.get('server_tick'),
                             available_routes=camp.get('available_routes',[]),decision_lines=camp.get('decision_lines',[]),
                             economy=camp.get('economy'),frontier=camp.get('frontier'),done=camp.get('done',[]),
                             active_tasks=ctx.get('active_tasks'),source=p.as_posix()))
    count=Counter(e['kind'] for e in decisions)
    routes=Counter(s['classify']['route'] for s in sections)
    milestones=[dict(line=n,record=e) for n,e in enumerate(decisions,1) if e['kind']=='campaign_milestone_done']
    p28=raw.read_json(run/'attempts/strategy-0028.context.json')
    r28=raw.read_json(run/'attempts/strategy-0028.result.json')
    econ=p28['campaign']['economy'];workers=econ['workers'];m01_done='M01' in p28['campaign']['done']
    recovery_gate=dict(workers=workers,worker_lt_2=workers<2,m01_done=m01_done,m01_not_done=not m01_done,
                       under_attack_total='not present in this saved context; not inferred',
                       needs_recovery_possible=(workers<2 and not m01_done),
                       D2_available='D2' in p28['campaign']['available_routes'],
                       locked_lines=[s for s in p28['campaign']['decision_lines'] if 'D2' in s],
                       context_tick=p28['server_tick'],plan_deadline=p28['current_plan']['valid_until_tick'],
                       economy=econ,active_tasks=p28.get('active_tasks'),rationale=r28['result']['rationale'])
    # A zero balance delta is an observation, not a direct measure of income.
    # Keep the original report's plateau claim scoped to balance samples.
    last_balance=rounds[-1].get('balance');tail_start=len(rounds)-1
    while tail_start>0 and rounds[tail_start-1].get('balance')==last_balance:
        tail_start-=1
    summary_out=dict(world_rounds=len(rounds),decision_entries=len(decisions),command_receipts=len(commands),
                     routes=dict(routes),event_counts=dict(count),milestones=milestones,recovery_gate=recovery_gate,
                     balance_plateau=dict(value=last_balance,first_ts=rounds[tail_start]['ts'],
                                          last_ts=rounds[-1]['ts'],seconds=rounds[-1]['ts']-rounds[tail_start]['ts']),
                     calls=len(calls),D2_context_available=sum('D2' in c['available_routes'] for c in contexts),
                     D2_locked_contexts=sum(any('D2' in s for s in c['decision_lines'] if s.startswith('暂不可选')) for c in contexts),
                     D2_selected_results=sum((raw.read_json(p).get('decode') or {}).get('goal_ref')=='D2' for p in (run/'attempts').glob('*.result.json')),
                     source_audit=source_audit(run))
    return dict(run=run.as_posix(),observation_start=origin,summary=summary_out,frames=frames,contexts=contexts,
                decision_source=archives[0].with_name('decisions.jsonl').as_posix())


def write_figure_markdown(figures:Path):
    descriptions={
        'adjutant-runtime-loop':('现有程序循环','源码拓扑；分支计数来自本局 event_classified，表示路由次数，不是模型调用次数。宿主下一轮是外部循环。节点没有 enter/exit 日志时，不据此声称精确节点耗时。'),
        'adjutant-goal-feedback-loop':('必须具备的目标反馈循环','需求合同图，包含成功、正常等待、失败与超时回退；不是已实现全部分支的证明。'),
        'adjutant-economy-breakpoint':('这局的经济恢复入口卡点','实线解释已有条件和已记录事实；虚线是需要补的反馈入口。本轮只建立诊断图，没有修改运行时条件。')}
    for name in FIGURE_NAMES:
        title,description=descriptions[name];mmd=raw.read_text(figures/(name+'.mmd'))
        output=figures/(name+'.md')
        if output.exists():raise FileExistsError(output)
        output.write_text('# '+title+'\n\n'+description+'\n\n```mermaid\n'+mmd.rstrip()+'\n```\n',encoding='utf-8')


def html_document(data:dict,figures:Path):
    payload=json.dumps(data,ensure_ascii=False,separators=(',',':')).replace('<','\\u003c').replace('&','\\u0026')
    svg=raw.read_text(figures/'adjutant-runtime-loop.svg')
    svg=svg[svg.index('<svg'):]
    parts=['''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>副官循环 · 分支与卡点回放</title><style>
:root{font-family:system-ui,"Microsoft YaHei",sans-serif;color:#203449;background:#f2f5f8}body{margin:0}header{background:#fff;padding:24px 28px}h1{font-size:26px;margin:0 0 12px}p{line-height:1.8;margin:10px 0}nav{position:sticky;top:0;z-index:3;background:#fff;box-shadow:0 2px 8px #1232;padding:12px 28px;display:flex;flex-wrap:wrap;gap:12px;align-items:center}input[type=range]{min-width:280px;flex:1}input,select,button{font:inherit;padding:6px 8px}input[type=number]{width:100px}.layout{display:grid;grid-template-columns:minmax(520px,1.1fr) minmax(430px,1fr);gap:18px;padding:20px}.panel{background:white;border:1px solid #d7e0e8;border-radius:6px;padding:18px;min-width:0}h2{font-size:19px;margin:6px 0 14px}.graph svg{width:100%;height:auto;max-height:760px}.graph g.actual>rect,.graph g.actual>polygon{fill:#fff0b3!important;stroke:#b46d18!important;stroke-width:4px!important}.meta{color:#526b80;font-size:13px}pre{font:12px/1.65 Consolas,"Microsoft YaHei",monospace;white-space:pre-wrap;overflow-wrap:anywhere;max-height:390px;overflow:auto}.warning{background:#fff2df;border-left:4px solid #c68a3b;padding:12px;margin:12px 0;line-height:1.8}.facts{line-height:1.9}.evidence{font-size:13px;line-height:1.8}.gallery{padding:0 20px 24px;display:grid;grid-template-columns:1fr 1fr;gap:18px}.gallery img{width:100%;height:auto}a{color:#155f9a}details{margin:14px 0}summary{cursor:pointer}#events{max-height:380px}select{max-width:100%}@media(max-width:1050px){.layout,.gallery{grid-template-columns:1fr}.layout{padding:10px}.graph svg{max-height:none}}
</style><style>.graph-viewport{height:660px;overflow:auto;border:1px solid #e2e8ef;border-radius:4px}.graph-viewport svg{min-width:700px;max-height:none!important}.gallery{grid-template-columns:1fr}.gallery .panel{max-width:1400px}.gallery img{max-width:100%}.figure-link{display:block;margin-bottom:12px}</style><header><h1>AI 副官 · 循环、分支与卡点回放</h1>
<p>已有 10 分钟样本的离线回放。黄色节点只标明日志实际记录的路由选择，其他连接是源码定义的路径；没有节点进入/退出日志，不显示虚构耗时。下方另有目标反馈需求图与本局入口卡点。</p>
<p class="meta">本页不连接游戏、不改变运行时。一次“图的轮次”可能没有新模型调用；最近完成调用只按时间列出，不能据此断言被该轮采纳。</p></header>
<nav><button id="prev">上一轮</button><input type="range" id="slider" min="0" value="0" aria-label="选择观察轮次"><button id="next">下一轮</button>
<label>跳到秒 <input type="number" id="seconds" step="0.001" value="0"></label><button id="jump">跳转</button><button id="case">定位经济卡点</button><strong id="position"></strong></nav>
<main class="layout"><section class="panel graph"><h2>现有调度循环</h2><div class="graph-viewport">''',svg,
        '''</div><p class="meta">图内可滚动查看完整循环。路线计数是本样本总数。黄色只代表选中轮次有 event_classified 证据。源码路径不等于所有节点都有逐项追踪证据。</p></section>
<section class="panel"><h2 id="route"></h2><div class="facts" id="facts"></div><div class="warning" id="gate"></div>
<label>最近已完成调用 <select id="calls"></select></label><div id="context" class="evidence"></div>
<details><summary>查看本轮分组事件（日志区段，非精确因果链）</summary><pre id="events"></pre></details>
<details><summary>查看最近既有状态采样（有采样年龄）</summary><pre id="state"></pre></details>
<p class="meta">分组从本次分类事件到下次分类事件前；异步结果可能属于更早发起的任务。状态采样为最近较早记录，不冒充本轮完整状态。</p></section></main><div class="gallery">''']
    for name,title in [('adjutant-goal-feedback-loop','目标反馈循环：必须具备的分支'),('adjutant-economy-breakpoint','本局证据：经济恢复入口未开放')]:
        p=figures/(name+'.png')
        uri=html.escape(p.resolve().as_uri(),quote=True)
        parts.append('<section class="panel"><h2>'+title+'</h2><a class="figure-link" href="'+uri+'" target="_blank" rel="noopener">打开完整原图查看分支文字</a><a href="'+uri+'" target="_blank" rel="noopener"><img src="'+uri+'" alt="'+title+'"></a></section>')
    parts.append('</div><script type="application/json" id="data">'+payload+'</script>')
    parts.append('''<script>
const data=JSON.parse(document.getElementById('data').textContent);const frames=data.frames,contexts=data.contexts;let index=0;
const slider=document.getElementById('slider');slider.max=frames.length-1;
const fmt=t=>{const sign=t<0?'-':'';let ms=Math.round(Math.abs(t)*1000);return sign+String(Math.floor(ms/60000)).padStart(2,'0')+':'+String(Math.floor(ms%60000/1000)).padStart(2,'0')+'.'+String(ms%1000).padStart(3,'0')};
const cn={strategic:'战略调度',tactical:'战术调度',wait:'等待/保持既有任务'};const nodes={strategic:'strategy',tactical:'tactics',wait:'wait',player_interrupt:'reconcile',emergency_tactical:'tactics'};
function showContext(id){const c=contexts.find(c=>c.attempt_id===id);const target=document.getElementById('context');target.textContent='';if(!c)return;
const head=document.createElement('p');head.textContent=c.attempt_id+' · 返回 '+fmt(c.relative_seconds)+' · 输入 tick '+c.input_tick;target.appendChild(head);
for(const s of c.decision_lines){const p=document.createElement('p');p.textContent=s;target.appendChild(p)}
const eco=document.createElement('p');eco.textContent='输入经济：'+JSON.stringify(c.economy)+'；已完成里程碑：'+c.done.join('、');target.appendChild(eco)}
function render(i){index=Math.max(0,Math.min(frames.length-1,i));const f=frames[index];slider.value=index;document.getElementById('seconds').value=f.relative_seconds.toFixed(3);document.getElementById('position').textContent=(index+1)+' / '+frames.length+' 轮 · '+fmt(f.relative_seconds);
document.getElementById('route').textContent='本轮实际路由：'+(cn[f.route]||f.route);
document.getElementById('facts').textContent='tick '+f.server_tick+'；余额 '+f.balance+'；自有实体 '+f.unit_count+'。分类事件原件第 '+f.classify_line+' 行。最近完成调用：'+(f.last_completed_call?f.last_completed_call.attempt_id+'（时间相邻，不代表采纳）':'尚无');
for(const g of document.querySelectorAll('.graph g.node')){g.classList.remove('actual');for(const shape of g.querySelectorAll(':scope > rect,:scope > polygon')){if(!('traceOriginalStyle' in shape.dataset))shape.dataset.traceOriginalStyle=shape.getAttribute('style')||'';shape.setAttribute('style',shape.dataset.traceOriginalStyle)}}
for(const name of ['classify',nodes[f.route]])for(const g of document.querySelectorAll('.graph g.node'))if(g.id.includes('flowchart-'+name+'-')){g.classList.add('actual');for(const shape of g.querySelectorAll(':scope > rect,:scope > polygon')){shape.style.setProperty('fill','#fff0b3','important');shape.style.setProperty('stroke','#b46d18','important');shape.style.setProperty('stroke-width','4px','important')}}
const viewport=document.querySelector('.graph-viewport');const selected=[...document.querySelectorAll('.graph g.node.actual')].map(g=>g.getBoundingClientRect());if(selected.length){const bounds=viewport.getBoundingClientRect();const top=Math.min(...selected.map(r=>r.top))-bounds.top+viewport.scrollTop;const bottom=Math.max(...selected.map(r=>r.bottom))-bounds.top+viewport.scrollTop;viewport.scrollTop=Math.max(0,(top+bottom-viewport.clientHeight)/2)}
const g=data.summary.recovery_gate;document.getElementById('gate').textContent='已核验案例：输入 tick '+g.context_tick+'，工人 '+g.workers+'，M01 已完成。现有 D2 入口要求“受过袭击 AND M01 未完成 AND 工人<2”，后两项已不满足；该上下文 D2 '+(g.D2_available?'可选':'不可选')+'。这是固定案例证据，不冒充当前轮的完整条件。';
document.getElementById('events').textContent=JSON.stringify(f.events,null,2);document.getElementById('state').textContent=JSON.stringify({age_seconds:f.state_age_seconds,saved_state:f.state},null,2);
const select=document.getElementById('calls');select.textContent='';const before=contexts.filter(c=>c.end_ts<=f.ts);for(const c of before.slice(-12).reverse()){const o=document.createElement('option');o.value=c.attempt_id;o.textContent=c.attempt_id+' · '+fmt(c.relative_seconds);select.appendChild(o)}showContext(select.value);}
slider.addEventListener('input',()=>render(Number(slider.value)));document.getElementById('prev').onclick=()=>render(index-1);document.getElementById('next').onclick=()=>render(index+1);document.getElementById('calls').onchange=e=>showContext(e.target.value);
document.getElementById('jump').onclick=()=>{const t=Number(document.getElementById('seconds').value);let i=frames.findIndex(f=>f.relative_seconds>=t);render(i<0?frames.length-1:i)};
document.getElementById('case').onclick=()=>{const i=frames.findIndex(f=>f.server_tick>=data.summary.recovery_gate.context_tick);render(i<0?frames.length-1:i)};render(0);
</script></html>''')
    return '\n'.join(parts)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--run',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();run=args.run.resolve();output=args.output.resolve();figures=output.parent/'figures'
    html_path=output.with_suffix('.html');json_path=output.with_suffix('.json');manifest_path=output.with_suffix('.manifest.json')
    for p in (html_path,json_path,manifest_path):
        if p.exists():raise FileExistsError(p)
    sources=raw.source_files(run)+[run/'strategy-state.jsonl',run/'source-before.json']+sorted((run/'runner-logs').glob('**/commands.jsonl'))
    before={p.relative_to(run).as_posix():raw.digest(p) for p in sources}
    data=collect(run)
    if not all(a['matches_sample'] for a in data['summary']['source_audit'].values()):
        raise ValueError('Current graph source differs from sample; source graph must not be presented as observed version')
    write_figure_markdown(figures)
    html_path.write_text(html_document(data,figures),encoding='utf-8')
    json_path.write_text(raw.dump(data)+'\n',encoding='utf-8')
    after={p.relative_to(run).as_posix():raw.digest(p) for p in sources}
    manifest=dict(created_at=datetime.now(timezone.utc).isoformat(),source_hashes=before,source_unchanged=before==after,
                  source_audit=data['summary']['source_audit'],outputs={p.as_posix():raw.digest(p) for p in (html_path,json_path)},
                  figure_hashes={p.as_posix():raw.digest(p) for name in FIGURE_NAMES for p in (figures/(name+'.mmd'),figures/(name+'.md'),figures/(name+'.svg'),figures/(name+'.png'))})
    manifest_path.write_text(raw.dump(manifest)+'\n',encoding='utf-8')
    print(raw.dump(data['summary']))
    if before!=after:raise RuntimeError('Source evidence changed')
    return 0


if __name__=='__main__':raise SystemExit(main())
