"""Chinese, source-grounded reading layer over saved adjutant outputs."""
from __future__ import annotations

import argparse
import hashlib
import html
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import export_adjutant_timeline as raw


ACTIONS = {
    'gather': '采集', 'build': '建造', 'produce': '生产', 'scout': '侦察',
    'attack': '攻击', 'attack_move': '攻击前进', 'move': '移动', 'defend': '防守',
    'retreat': '撤退', 'hold': '待命', 'stop': '停止', 'regroup': '集结',
}
SKILLS = {'GAT': '采集', 'BLD': '建造', 'PROD': '生产', 'SCT': '侦察',
          'ATK': '攻击', 'AMOV': '攻击前进', 'MOVE': '移动', 'DEF': '防守',
          'RET': '撤退', 'HOLD': '待命', 'STOP': '停止', 'GRP': '集结'}
KINDS = {'worker': '工人组', 'squad': '作战小队', 'facility': '生产设施',
         'resource': '资源点', 'product': '可生产/建造项目', 'enemy': '敌方目标',
         'location': '位置', 'building': '建筑', 'unit': '单位'}
STATES = {'running': '执行中', 'completed': '已完成', 'failed': '失败',
          'unknown': '状态未知', 'pending': '等待', 'suspended': '已挂起'}
NAMES = {'ore_refinery': '矿场', 'vehicle_factory': '车厂', 'worker': '工人',
         'tank': '坦克', 'drone': '无人机', 'command_center': '指挥中心',
         'aircraft_factory': '机场', 'anti_air_turret': '防空炮塔',
         'anti_ground_turret': '反地面炮塔'}
PARAMS = {'direct': '直达', 'flank': '侧翼', 'rally': '经过集结点',
          'loose': '疏散队形', 'column': '纵队', 'line': '横队',
          'fast': '快速', 'normal': '常规', 'careful': '谨慎',
          'short': '短程追击'}
FIELDS = {
    'plan_id': '计划编号', 'plan_version': '计划版本', 'match_id': '对局编号',
    'player_id': '玩家编号', 'rules_version': '规则版本', 'based_on_snapshot': '依据快照',
    'valid_until_tick': '有效截止逻辑帧', 'phase_goal': '阶段目标', 'tasks': '本次列出的任务',
    'reserves': '资源预留', 'rationale': '模型给出的理由', 'abort_when': '中止条件',
    'maintain_current': '维持当前计划', 'task_id': '任务编号', 'priority': '优先级数值',
    'completion': '完成条件', 'units': '参与单位', 'unit_constraint': '单位约束',
    'target_type': '目标类型', 'allowed_actions': '允许动作', 'result': '返回结果',
    'selection': '选择附加记录', 'laya': 'Laya选择记录', 'decode': '解码记录',
    'batch_id': '批次编号', 'intents': '程序转换后的新意图', 'intent_id': '意图编号',
    'unit_ids': '单位编号列表', 'action': '动作', 'target': '目标', 'entity_id': '实体编号',
    'resource': '资源实体', 'issued_tick': '签发逻辑帧', 'expires_tick': '到期逻辑帧',
    'generation': '控制代数', 'emergency': '是否紧急', 'reacquire': '是否重新获取控制',
    'event': '记录事件', 'task': '选择的技能', 'actor': '选择的执行者',
    'confidence': '技能选择置信分数（非成功概率）', 'latency_ms': '记录耗时毫秒',
    'extra_passes': '额外推理次数', 'accepted': '解码接纳数量（非游戏执行数）',
    'rejected': '解码拒绝数量', 'reject_reasons': '解码拒绝原因',
    'modifications': '解码后的任务修改', 'row_index': '输出行序号',
    'actor_ref': '执行者引用', 'skill': '技能', 'target_ref': '目标引用',
    'params_ref': '参数档引用', 'actor_kind': '执行者类型', 'squad_id': '小组编号',
    'kind': '类别', 'ref': '引用编号', 'pos': '位置坐标', 'params': '执行参数',
    'route': '行进路线', 'formation': '队形', 'tempo': '节奏', 'pursuit': '追击范围',
    'cn': '中文说明', 'task_version': '任务版本', 'generations': '各单位控制代数',
    'unchanged': '是否与现有任务相同', 'rejections': '逐行拒绝记录',
    'goal_ref': '路线分支引用', 'branch_source': '路线来源',
}


def join_items(items) -> str:
    return '、'.join(str(item) for item in items) or '无'


def task_name(ident: str) -> str:
    if ident.startswith('rule-build-'):
        return '建造' + NAMES.get(ident[11:], ident[11:]) + f'（{ident}）'
    if ident.startswith('rule-produce-'):
        return '生产' + NAMES.get(ident[13:], ident[13:]) + f'（{ident}）'
    return {'rule-gather': '采集任务（rule-gather）', 'rule-scout': '侦察任务（rule-scout）'}.get(ident, ident)


def chinese_object(value, key=''):
    """Translate field labels and known enums, preserve IDs and model text."""
    if isinstance(value, dict):
        return {f'{FIELDS.get(k, k)}〔{k}〕': chinese_object(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [chinese_object(v, key) for v in value]
    if isinstance(value, str):
        mapping = ACTIONS if key in ('action', 'allowed_actions') else (
            SKILLS if key in ('task', 'skill') else KINDS if key in ('kind', 'actor_kind') else (
                PARAMS if key in ('route', 'formation', 'tempo', 'pursuit') else {}))
        return f'{mapping[value]}（{value}）' if value in mapping else value
    if value is True:
        return '是〔true〕'
    if value is False:
        return '否〔false〕'
    if value is None:
        return '无〔null〕'
    return value


def input_facts(context: dict) -> str:
    campaign = context.get('campaign') or {}
    econ = campaign.get('economy') or {}
    amount = (context.get('strategic_summary') or {}).get('resources', context.get('balance', {}))
    parts = [f"输入逻辑帧 {context.get('server_tick')}；快照 {context.get('snapshot_id')}。",
             f"程序给定主线阶段：{campaign.get('phase', '未记录')}；前沿：{campaign.get('frontier_name', '未记录')}。",
             f"输入余额：{join_items(f'{k}={v}' for k,v in (amount or {}).items())}。",
             f"输入经济记录：工人 {econ.get('workers', '未记录')}；矿场完工 {econ.get('refinery_constructed', '未记录')}；交货 {econ.get('refinery_delivered', '未记录')}。"]
    if 'current_plan' in context:
        plan = context.get('current_plan')
        parts.append('输入没有当前活动计划。' if not plan else
                     f"输入当前计划版本 {plan.get('plan_version')}；截止逻辑帧 {plan.get('valid_until_tick')}。")
        tasks = context.get('active_tasks') or {}
        parts.append('输入任务状态：' + join_items(f'{task_name(k)}={STATES.get(v,v)}' for k,v in tasks.items()) + '。')
    return '\n'.join(parts)


def explain_strategy(context: dict, plan: dict | None, raw_text: str):
    notes = []
    if plan is None:
        return ('本次未取得已保存的完整战略计划，未形成可核对的结构化决定。',
                '没有完整解析出的理由字段；可见响应及失败原因按同条原始记录保留。',
                ['未保存完整战略计划；超时、传输失败或格式问题以调用结束记录为准，不能仅凭结果缺失推断截断。'])
    parts = [f"阶段目标：{plan.get('phase_goal', '未记录')}。",
             '计划动作：' + ('维持现有计划。' if plan.get('maintain_current') else '提交计划内容，是否采纳须看图内记录。'),
             f"计划版本 {plan.get('plan_version')}；依据快照 {plan.get('based_on_snapshot')}；截止逻辑帧 {plan.get('valid_until_tick')}。"]
    tasks = plan.get('tasks') or []
    if not tasks:
        parts.append('本次未列出新增或修改任务（空数组）；不代表整局没有任务。')
    for task in tasks:
        parts.append(f"任务 {task_name(task.get('task_id', ''))}：优先级数值 {task.get('priority')}；单位 {join_items(task.get('units', []))}；允许 {join_items(ACTIONS.get(a,a) for a in task.get('allowed_actions', []))}；完成条件：{task.get('completion', '')}。"
                     f"单位约束：{task.get('unit_constraint') or '未指定'}；目标类型：{task.get('target_type') or '未指定'}。")
    parts.append('资源预留：' + (raw.dump(plan.get('reserves', {})) if plan.get('reserves') else '无') + '；中止条件：' + join_items(plan.get('abort_when', [])) + '。')
    if plan.get('maintain_current') and not context.get('current_plan'):
        notes.append('输入无当前计划，输出却要求维持当前计划。')
    deadline, tick = plan.get('valid_until_tick'), context.get('server_tick')
    if isinstance(deadline, int) and isinstance(tick, int) and deadline <= tick:
        notes.append(f'输出截止帧 {deadline} ≤ 输入帧 {tick}，不满足请求中“valid_until_tick 必须大于 server_tick”的约束。')
    failed = [task_name(k) for k,v in (context.get('active_tasks') or {}).items() if v == 'failed']
    if plan.get('maintain_current') and failed:
        notes.append('输入有失败任务：' + join_items(failed) + '；本次仍要求维持。是否合理需要结合恢复机制，不能仅凭 JSON 合法判定。')
    return '\n'.join(parts), plan.get('rationale') or '未记录自然语言理由。', notes


def actor_label(context: dict, ref: str) -> str:
    entry = (context.get('actors') or {}).get(ref)
    if not entry:
        return ref + '（本次上下文未找到引用）'
    return f"{ref}（{KINDS.get(entry.get('kind'),entry.get('kind'))}；本组 {entry.get('count', len(entry.get('units', [])))} 个单位；成员 {join_items(entry.get('units', []))}）"


def target_label(context: dict, ref: str) -> str:
    entry = (context.get('targets') or {}).get(ref)
    if not entry:
        return ref + '（本次上下文未找到引用）'
    return f"{ref}（{KINDS.get(entry.get('kind'),entry.get('kind'))} {entry.get('entity_id') or entry.get('scene') or entry.get('cn') or ''}；位置 {entry.get('pos', '未记录')}）"


def explain_tactics(context: dict, result: dict | None):
    if result is None:
        return '本次未取得已保存的结构化返回。', '未记录自然语言理由。', ['调用失败；不要从空记录推断模型选择。']
    laya = result.get('laya') or {}
    decode = result.get('decode') or {}
    intents = (result.get('result') or {}).get('intents') or []
    task = laya.get('task', '')
    parts = [f"技能选择记录：{SKILLS.get(task, task)}（{task}）。" if laya else
             "本次没有 Laya 选择对象；以下显示实际保存的转换结果。",
             '选择执行者：' + actor_label(context, laya.get('actor','')) + '。',
             '选择目标：' + target_label(context, laya.get('target','')) + '。']
    modifications = decode.get('modifications') or []
    for mod in modifications:
        par = mod.get('params') or {}
        parts.append(f"解码修改：让 {join_items(mod.get('units', []))} 执行{ACTIONS.get(mod.get('action'),mod.get('action'))}；目标 {mod.get('target_ref')} → {(mod.get('target') or {}).get('entity_id', (mod.get('target') or {}).get('pos'))}；参数 {mod.get('params_ref')}：{par.get('cn') or raw.dump(par)}；与现任务相同：{'是' if mod.get('unchanged') else '否'}。")
    goal = decode.get('goal_ref')
    if goal:
        route_name = (context.get('campaign') or {}).get('available_route_names', {}).get(goal)
        parts.append(f"选择路线：{goal}（{route_name or '本次上下文未记录中文名'}），来源 {decode.get('branch_source') or '未记录'}；这是路线选择记录，不能直接等同发起攻击。")
    parts.append(f"记录的技能选择置信分数：{laya.get('confidence')}（非任务成功概率）；额外推理 {laya.get('extra_passes')} 次；解码接纳 {laya.get('accepted')} 条、拒绝 {laya.get('rejected')} 条。")
    parts.append(f"程序转换后新意图 {len(intents)} 条。")
    for intent in intents:
        target = intent.get('target') or {}
        parts.append(f"新意图 {intent.get('intent_id')}：单位 {join_items(intent.get('unit_ids', []))} → {ACTIONS.get(intent.get('action'),intent.get('action'))} → {target.get('entity_id') or target.get('resource') or target.get('pos') or target}；签发帧 {intent.get('issued_tick')}，到期帧 {intent.get('expires_tick')}。")
    notes = []
    if not intents:
        unchanged = modifications and all(m.get('unchanged') for m in modifications)
        if unchanged:
            notes.append('选择与现有任务相同，解码记录 unchanged=true；转换结果不重复生成新意图。空数组不等于模型没有作选择，也不证明单位停止工作。')
        else:
            notes.append('没有新意图；仅凭空数组不能判断是否停止工作或是否决策失败。')
    if (context.get('campaign') or {}).get('available_route_names', {}).get(goal) == '进攻' and task == 'GAT':
        notes.append('同次记录同时选择“进攻”路线和“采集”动作；两者分属主线分支与当前任务，不能把它读成已发出攻击命令。')
    return '\n'.join(parts), '这条已保存记录没有自然语言理由；以下中文由引用表翻译，不是模型自述。', notes


def build_rows(run: Path):
    summary, rows = raw.collect(run)
    for row in rows:
        ident = row['attempt_id']
        context = raw.read_json(run/'attempts'/f'{ident}.context.json')
        p = run/'attempts'/f'{ident}.result.json'
        saved = raw.read_json(p) if p.exists() else None
        row['facts_cn'] = input_facts(context)
        if row['role'] == 'strategy':
            decision, reason, notes = explain_strategy(context, saved.get('result') if saved else None, row['output_text'])
        else:
            decision, reason, notes = explain_tactics(context, saved)
        row['decision_cn'], row['reason_cn'] = decision, reason
        if row['end']['ok']:
            outcome = '封装成功返回。此状态仅证明收到/解析出结果，不证明游戏执行成功。'
        else:
            outcome = f"调用失败：{row['end'].get('error_type')}。原始错误：{row['end'].get('error')}"
        row['checks_cn'] = '\n'.join(notes) if notes else '本页未由确定性对照检出上述问题；不等于战略决策正确。'
        row['outcome_cn'] = outcome
        row['translated_object'] = raw.dump(chinese_object(saved)) if saved is not None else '未生成完整结果对象；查看原始错误与服务端文本。'
        row['flags'] = notes
    return summary, rows


def analysis_text(run: Path, summary: dict, rows: list[dict]) -> str:
    plan_issues = [r for r in rows if r['role']=='strategy' and r['flags']]
    lengths = []
    for path in sorted((run/'http').glob('*.response.json')):
        response = raw.read_json(path)
        if any(choice.get('finish_reason') == 'length' for choice in response.get('choices', [])):
            lengths.append(path.name)
    return '\n'.join([
        '## 这种结构化输出是否合适', '',
        '结构化输出可以用于语言模型控制游戏：它让程序知道计划和动作是什么，并可校验目标是否合法。但结构合法只是接口要求，不能证明模型理解局势、目标合理或执行成功。', '',
        '战略模型的已记录可见解释来自 rationale 字段，下表单独原样展示该字段；没有记录的理由不补写。模型及运行设置以本次 summary 和实际 HTTP 请求为准。', '',
        '上一版主要问题是缺少人读层。模型接口可继续使用机器能校验的字段，中文意思应由日志程序根据本次上下文翻译。不能把我补写的说明冒充模型当时说过的话。', '',
        '当前设计有证据支持的负担：战略要生成计划/对局/玩家/规则编号、快照和有效帧，以及任务集合。对局编号、规则哈希等已有上下文，要求模型重复这些字段会增加输出长度与复制约束；可考虑由程序补齐。注意原文里才是模型亲自生成的字段，解析结果还会增加默认字段；战术的完整 result/selection/laya/decode 是应用层保存的记录，不能全部当作模型逐字生成的内容。', '',
        f"本样本 finish_reason=length 的响应共 {len(lengths)} 条：{join_items(lengths)}。截断与否按实际响应标记记录；不能套用其他对局的案例。", '',
        f'逐条对照中 {len(plan_issues)} 次战略返回触发了至少一项明确检查，具体条目见各行；这是检查计数，不是已经确诊的独立缺陷数量。', '',
        f"未与调用精确关联的 HTTP 请求：{join_items(summary.get('_unmatched_http', []))}。以下完整性附录保留其输入与输出，不猜测调用归属。", '',
        '建议的下一版接口（尚未实施、未做 A/B）：让小模型只返回精简决策字段、短理由，以及可核验的观测依据/触发重新规划的条件；由程序补身份、版本和时间元数据，并用同样的 10 分钟轨迹比较任务达成、非法引用、截断率和延迟。自然语言长解释不自动等于更好战略，不应在未测量时直接要求每次输出长篇思考。', '',
        '## 阅读口径', '',
        '“输入事实”来自本次 context；“决策中文”由字段和本次引用表直接翻译；“模型原话/理由”仅保留已有 rationale，战术未保存理由时明确写未记录；“程序结果/对照提示”由返回记录和确定性数值比较得到，不冒充模型思考，也不把调用成功当作游戏执行成功。', '',
        '置信分数只照录 Laya 技能选择 confidence，没有校准证据，不解释成任务成功率。空意图如果与现任务相同，会明确注明重复抑制，不当作“没有思考”。每条均保留完整原文与完整程序对象，字段中文对照也在附录。', '',
    ]) + unmatched_http_appendix(run, summary)


def unmatched_http_appendix(run: Path, summary: dict) -> str:
    parts = []
    for ident in summary.get('_unmatched_http', []):
        parts += [f'\n\n## 未归因 HTTP 原件：{ident}']
        for suffix in ('request', 'response'):
            path = run/'http'/f'{ident}.{suffix}.json'
            parts += ['\n\n' + suffix + '\n\n' + (raw.read_text(path) if path.exists() else '未保存，未知')]
    return ''.join(parts)


def markdown(summary: dict, rows: list[dict], analysis: str) -> str:
    counts = Counter(r['role'] for r in rows)
    lines = ['# AI 副官：逐条中文对照时间表', '',
             f'**{len(rows)} 条完整中文对照：{counts["strategy"]} 条战略、{counts["tactics"]} 条战术。** 原始输出保留在文末每条附录；全文不删重复、空意图、异常或截断。', '',
             f"观察零点 {raw.localtime(summary['observation_start'])}；观察 {summary.get('observed_seconds')} 墙钟秒。按输出完成时间排序；超出观察末点的条目是收尾返回。", '',
             '## 逐条中文时间表', '',
             '| 时间与编号 | 当时输入事实 | 决策中文与模型原话 | 程序结果与对照提示 |', '|---|---|---|---|']
    for number, r in enumerate(rows, 1):
        timing = f"**#{number} {r['attempt_id']}**<br>{'战略' if r['role']=='strategy' else '战术'}<br>完成 {raw.reltime(r['relative_end'])}<br>开始 {raw.reltime(r['relative_start'])}<br>耗时 {r['end']['latency_s']:.3f} 秒<br>[完整原文与中文字段](#raw-{r['attempt_id']})"
        decision = r['decision_cn']+'\n\n【模型原话/已记录理由】\n'+r['reason_cn']
        outcome = r['outcome_cn']+'\n\n【根据输入和输出做的对照；不是模型原话】\n'+r['checks_cn']
        lines.append(f"| {timing} | {raw.cell(r['facts_cn'])} | {raw.cell(decision)} | {raw.cell(outcome)} |")
    lines += ['', analysis, '## 原文与中文字段完整附录', '']
    for r in rows:
        lines += [f"<a id=\"raw-{r['attempt_id']}\"></a>", '', f"### {r['attempt_id']} · {raw.reltime(r['relative_end'])}", '',
                  '原始可见输出/战术完整记录：', '', '````text', r['output_text'], '````', '',
                  '完整结果对象的中文字段对照（显示转换；不是模型新增回复）：', '', '````json', r['translated_object'], '````', '',
                  '程序结束记录、HTTP 元数据与解析结果：', '', '````text', r['program_text'], '````', '',
                  '原件：'+' · '.join(raw.link(label,p) for label,p in r['refs']), '']
    return '\n'.join(lines)


def html_document(summary: dict, rows: list[dict], analysis: str, md_path: Path) -> str:
    counts = Counter(r['role'] for r in rows)
    parts = ['''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI 副官 · 逐条中文对照</title><style>
:root{font-family:system-ui,"Microsoft YaHei",sans-serif;color:#203044;background:#f2f5f8;color-scheme:light}body{margin:0}header{background:#fff;padding:28px 30px 14px}h1{font-size:27px;margin:0 0 12px}p{line-height:1.8;margin:12px 0}a{color:#155f9a}nav{display:flex;gap:12px;align-items:center;flex-wrap:wrap;position:sticky;top:0;background:#fff;padding:14px 30px;box-shadow:0 3px 10px #1232;z-index:2}select,input,button{font:inherit;border:1px solid #aebdcb;border-radius:5px;padding:7px 9px;background:#fff}input[type=number]{width:75px}input[type=search]{width:235px}main{padding:20px}table{width:100%;table-layout:fixed;border-collapse:collapse;background:#fff}td,th{border:1px solid #d6e0e8;vertical-align:top;text-align:left;padding:14px;font-size:14px;line-height:1.85}th{background:#e7eff7}th:nth-child(1){width:170px}th:nth-child(2){width:23%}th:nth-child(3){width:38%}.block{white-space:pre-wrap;overflow-wrap:anywhere}.id{display:block;margin:8px 0}.badge{font-size:12px;background:#e4edf9;padding:3px 8px;border-radius:4px}h3{font-size:14px;margin:12px 0 6px}.reason{background:#edf4fc;border-left:3px solid #7896bd;padding:10px;margin:16px 0}.checks{background:#fff4e7;border-left:3px solid #cb975b;padding:10px;margin:14px 0}.meta{color:#536d82;font-size:12px}.fail{color:#a32d1c}details{margin:15px 0;border-top:1px solid #d6e0e8;padding-top:10px}summary{cursor:pointer;color:#155f9a}pre{font:12px/1.7 Consolas,"Microsoft YaHei",monospace;white-space:pre-wrap;overflow-wrap:anywhere}.analysis{max-width:1200px;padding:20px;background:#fff;margin:24px auto}h2{font-size:22px}.analysis p{white-space:pre-wrap}[hidden]{display:none!important}@media(max-width:1050px){table,tbody,tr,td{display:block}thead{display:none}td{border-bottom:0}td:last-child{border-bottom:1px solid #d6e0e8;margin-bottom:20px}main{padding:10px}header,nav{padding:16px}}
</style><header><h1>AI 副官 · 逐条中文对照时间表</h1>
<p>每条翻译当时的事实、动作、执行者、目标、路线和程序结果。模型已有理由单独引用；没有理由的记录明确标注，解释不冒充模型原话。</p>''',
        f'<p><strong>全部 {len(rows)} 条：{counts["strategy"]} 条战略、{counts["tactics"]} 条战术。</strong></p>',
        '<p>观察零点 '+raw.localtime(summary['observation_start'])+'。按输出完成时间排序；空意图、重复、超时、截断均保留。原文和完整中文字段对照在每行的“查看”中。</p>',
        '<p><a href="'+html.escape(md_path.resolve().as_uri(),quote=True)+'">完整中文 Markdown（含全部原文附录）</a> · <a href="#format">结构化输出是否合适：证据与判断</a></p></header>',
        '''<nav><label>角色 <select id="role"><option value="all">全部</option><option value="strategy">战略</option><option value="tactics">战术</option></select></label>
<label>状态 <select id="state"><option value="all">全部</option><option value="ok">成功返回</option><option value="error">失败</option></select></label>
<input id="q" type="search" placeholder="搜索中文、任务、ID、原话" aria-label="搜索中文记录">
<label>从 <input id="from" type="number" step="0.001" placeholder="秒"></label><label>到 <input id="to" type="number" step="0.001" placeholder="秒"></label>
<button id="reset">显示全部</button><b id="count"></b></nav><main><table><thead><tr><th>时间与调用</th><th>当时输入事实</th><th>决策中文与模型原话</th><th>程序结果与对照提示</th></tr></thead><tbody>''']
    for number,r in enumerate(rows,1):
        esc = html.escape
        role = '战略' if r['role']=='strategy' else '战术'
        status = 'ok' if r['end']['ok'] else 'error'
        refs = ' · '.join('<a href="'+esc(p.resolve().as_uri(),quote=True)+'">'+esc(label)+'</a>' for label,p in r['refs'])
        parts.append(f'<tr data-id="{r["attempt_id"]}" data-role="{r["role"]}" data-state="{status}" data-time="{r["relative_end"]!r}">'
                     f'<td><span class="badge">{role}</span><b class="id">#{number} {r["attempt_id"]}</b><b>完成 {raw.reltime(r["relative_end"])}</b><br>开始 {raw.reltime(r["relative_start"])}<br>耗时 {r["end"]["latency_s"]:.3f} 秒<br><span class="meta">{raw.localtime(r["end"]["ts"])}</span></td>'
                     f'<td><div class="block facts">{esc(r["facts_cn"])}</div></td>'
                     f'<td><div class="block decision">{esc(r["decision_cn"])}</div><div class="reason"><b>模型原话 / 已记录理由</b><div class="block rationale">{esc(r["reason_cn"])}</div></div></td>'
                     f'<td><div class="block outcome {"fail" if status=="error" else ""}">{esc(r["outcome_cn"])}</div><div class="checks"><b>输入 / 输出对照（非模型原话）</b><div class="block check-text">{esc(r["checks_cn"])}</div></div>'
                     f'<details><summary>查看完整原文与中文字段</summary><h3>真实可见原文 / 战术完整记录</h3><pre class="raw-output">{esc(r["output_text"])}</pre>'
                     f'<h3>完整中文字段对照（程序显示转换）</h3><pre class="translated">{esc(r["translated_object"])}</pre>'
                     f'<h3>程序结束记录与解析结果</h3><pre class="raw-program">{esc(r["program_text"])}</pre>{refs}</details></td></tr>')
    parts.append('</tbody></table><article class="analysis" id="format">')
    for paragraph in analysis.split('\n\n'):
        if paragraph.startswith('## '):
            parts.append('<h2>'+html.escape(paragraph[3:])+'</h2>')
        else:
            parts.append('<p>'+html.escape(paragraph)+'</p>')
    parts.append('''</article></main><script>
const rows=Array.from(document.querySelectorAll('tr[data-id]'));const ids=['role','state','q','from','to'];
function filter(){const role=document.getElementById('role').value;const state=document.getElementById('state').value;const q=document.getElementById('q').value.toLocaleLowerCase();const low=document.getElementById('from').value;const high=document.getElementById('to').value;let count=0;
for(const row of rows){const t=Number(row.dataset.time);const show=(role==='all'||row.dataset.role===role)&&(state==='all'||row.dataset.state===state)&&(!q||row.textContent.toLocaleLowerCase().includes(q))&&(low===''||t>=Number(low))&&(high===''||t<=Number(high));row.hidden=!show;if(show)count++;}document.getElementById('count').textContent='显示 '+count+' / '+rows.length+' 条';}
for(const id of ids)document.getElementById(id).addEventListener('input',filter);document.getElementById('reset').addEventListener('click',()=>{for(const id of ids)document.getElementById(id).value=(id==='role'||id==='state')?'all':'';filter();});filter();
</script></html>''')
    return '\n'.join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run, output = args.run.resolve(), args.output.resolve()
    html_path, manifest_path = output.with_suffix('.html'), output.with_suffix('.manifest.json')
    for p in (output,html_path,manifest_path):
        if p.exists():
            raise FileExistsError(f'Refusing to overwrite {p}')
    sources = raw.source_files(run)
    before = {p.relative_to(run).as_posix():raw.digest(p) for p in sources}
    summary, rows = build_rows(run)
    analysis = analysis_text(run,summary,rows)
    md = markdown(summary,rows,analysis)
    page = html_document(summary,rows,analysis,output)
    after = {p.relative_to(run).as_posix():raw.digest(p) for p in sources}
    if before != after:
        raise RuntimeError('Input evidence changed')
    output.write_text(md,encoding='utf-8',newline='\n')
    html_path.write_text(page,encoding='utf-8',newline='\n')
    manifest = dict(exported_at=datetime.now(timezone.utc).isoformat(),run=run.as_posix(),
                    source_hashes=before,source_unchanged=before==after,
                    rows=[dict(attempt_id=r['attempt_id'],role=r['role'],flags=r['flags']) for r in rows],
                    outputs={p.as_posix():raw.digest(p) for p in (output,html_path)},
                    counts=dict(Counter(r['role'] for r in rows)),
                    roles_and_reasons='Only strategy rationale is a recorded natural-language model reason; tactics explanations are deterministic translations')
    manifest_path.write_text(raw.dump(manifest)+'\n',encoding='utf-8')
    print(raw.dump(dict(markdown=output.as_posix(),html=html_path.as_posix(),
                        rows=len(rows),counts=manifest['counts'],source_unchanged=manifest['source_unchanged'],
                        strategy_rows_with_checks=sum(bool(r['flags']) and r['role']=='strategy' for r in rows),
                        md_bytes=output.stat().st_size)))
    return 0


if __name__=='__main__':
    raise SystemExit(main())
