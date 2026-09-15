"""The small, supported parameter surface exposed to the editor."""
import math

from ..contract import ALGO_VERSION, G2_DEFAULTS

SCHEMA_VERSION = 2

# Bands refer to the nearest pair of spawn centres, not travel time after terrain.
SPACING = {'any': (0., 1000.), 'close': (0., 110.), 'standard': (110., 135.), 'far': (135., 1000.)}
CHOICES = [
    dict(key='water_combo', label='河湖组合', default='crossed', options=[
        dict(value='crossed', label='交错双河', controls=dict(river_enabled=1,river_layout=2,lake_count=0)),
        dict(value='single_lake', label='单河一湖', controls=dict(river_enabled=1,river_layout=1,lake_count=1)),
        dict(value='single_two_lakes', label='单河双湖', controls=dict(river_enabled=1,river_layout=1,lake_count=2)),
        dict(value='crossed_lake', label='交河一湖', controls=dict(river_enabled=1,river_layout=2,lake_count=1)),
        dict(value='separate_lake', label='分流一湖', controls=dict(river_enabled=1,river_layout=3,lake_count=1)),
        dict(value='two_lakes', label='双湖盆地', controls=dict(river_enabled=0,river_layout=2,lake_count=2)),
    ]),
    dict(key='player_spacing', label='玩家距离', default='any', hint='按最近两家出生点的直线距离筛选已有 G1 布局。', options=[
        dict(value='any', label='不限'), dict(value='close', label='近', detail='小于110m'), dict(value='standard', label='适中', detail='110–135m'), dict(value='far', label='远', detail='135m以上')]),
    dict(key='river_enabled', label='河流', default=1, options=[dict(value=0, label='无'), dict(value=1, label='有')]),
    dict(key='lake_count', label='湖泊', default=0, options=[dict(value=0, label='无'), dict(value=1, label='一个'), dict(value=2, label='两个')]),
    dict(key='water_size', label='水域大小', default='standard', hint='标准湖约占全图1.9%，大湖约2.3%；空间不足会提示，保持所选大小。', options=[
        dict(value='standard', label='标准', controls=dict(lake_area=5000, river_width=18)),
        dict(value='large', label='大', controls=dict(lake_area=6000, river_width=24))]),
    dict(key='plateau_max', label='高地数量', default=8, hint='包含出生台地和中立战略高地。', options=[dict(value=6, label='六座'), dict(value=7, label='七座'), dict(value=8, label='八座')]),
    dict(key='plateau_ramp_width', label='通路宽窄', default=8, hint='调节上下高地的坡口宽度。', options=[dict(value=7, label='较窄'), dict(value=8, label='适中'), dict(value=12, label='较宽')]),
]


CONTROLS = [
    dict(key='river_layout', group='河流与岩体', label='河道布局', min=1,max=3,step=1,default=2,unit='',hint=''),
    dict(key='river_enabled', group='河流与岩体', label='河流', min=0, max=1, step=1, default=1, unit='', hint='关闭后不会生成河道或桥梁。'),
    dict(key='lake_count', group='河流与岩体', label='湖泊数量', min=0, max=2, step=1, default=0, unit='个', hint='独立的封闭湖泊，岸边可绕行。'),
    dict(key='lake_area', group='河流与岩体', label='单个湖泊面积', min=2500, max=6000, step=500, default=5000, unit='m²', hint='保持所选面积，允许2%的格网误差；不为通过检查缩小湖泊。'),
    dict(key='neutral_plateau_scale', group='台地与坡口', label='中立台地尺度', min=1.4, max=2., step=.1, default=1.7, unit='×', hint='扩大可用顶面，形成可争夺的高地。'),
    dict(key='plateau_max', group='台地与坡口', label='台地数量上限', min=6, max=8, step=1, default=8, unit='座', hint='至少六座台地，可通行顶面占比至少12%。'),
    dict(key='landform_elongation', group='台地与坡口', label='地块延伸', min=1., max=1.6, step=.05, default=1.2, unit='×', hint='数值越大，台地沿区域走向延伸得越长。'),
    dict(key='landform_recess', group='台地与坡口', label='凹口深度', min=.08, max=.30, step=.02, default=.2, unit='', hint='控制边缘浅凹口，不会生成内部山地起伏。'),
    dict(key='landform_softness', group='台地与坡口', label='转角柔和度', min=.05, max=.28, step=.01, default=.16, unit='', hint='越低越接近长直崖面，越高转角越柔和。'),
    dict(key='plateau_ramp_width', group='台地与坡口', label='坡口宽度', min=7, max=12, step=1, default=8, unit='m', hint='穿崖通道的标称宽度；地面侧另有展开空间。'),
    dict(key='river_width', group='河流与岩体', label='主河基准宽度', min=10, max=26, step=1, default=18, unit='m', hint='生成时在基准附近取值，沿河保留缓慢宽窄变化。'),
    dict(key='river_bend_scale', group='河流与岩体', label='河道弯曲', min=.5, max=1.7, step=.1, default=1., unit='×', hint='改变主河的弯曲幅度；河流仍然连通。'),
    dict(key='river_crossings', group='河流与岩体', label='过河点数量', min=4, max=8, step=1, default=6, unit='处', hint='默认六座桥；封闭任意一座桥后，四家基地仍须互通。'),
    dict(key='obstacle_percent', group='河流与岩体', label='障碍目标占比', min=35, max=45, step=1, default=40, unit='%', hint='包括水体、悬崖和岩体；实际占比会显示在结果中。'),
    dict(key='cover_cluster_max', group='河流与岩体', label='岩体数量上限', min=6, max=14, step=1, default=10, unit='块', hint='只在净空与通路之外安排岩体。'),
    dict(key='layout_attempts', group='生成设置', label='最多筛选候选', min=1, max=7, step=1, default=4, unit='次', hint='首个候选通过即停止；其余候选并行验收。'),
]
DEFAULTS = {c['key']: c['default'] for c in CONTROLS}


def validate_config(value, layout_seeds):
    if not isinstance(value, dict) or set(value) - {'layout_seed', 'terrain_seed', 'controls', 'schema_version', 'algo_version', 'player_spacing'}:
        raise ValueError('参数格式不正确。')
    schema = value.get('schema_version', SCHEMA_VERSION)
    if type(schema) is not int or schema != SCHEMA_VERSION:
        raise ValueError('不支持此参数文件版本。')
    if value.get('algo_version', ALGO_VERSION['G2']) != ALGO_VERSION['G2']:
        raise ValueError(f"参数属于其他算法版本。若要迁移，请明确按当前 G2 {ALGO_VERSION['G2']} 重新生成；结果不会与旧版相同。")
    seed, terrain = value.get('layout_seed'), value.get('terrain_seed', 0)
    spacing = value.get('player_spacing', 'any')
    if not isinstance(spacing, str) or spacing not in SPACING:
        raise ValueError('出生布局或玩家距离选项不正确。')
    if type(seed) is not int or seed not in layout_seeds:
        raise ValueError('请选择一个已有的出生布局。')
    if type(terrain) is not int or not 0 <= terrain <= 2147483647:
        raise ValueError('地貌 Seed 必须是 0–2147483647 的整数。')
    raw = value.get('controls', {})
    if not isinstance(raw, dict) or set(raw) - set(DEFAULTS):
        raise ValueError('包含不支持的调节项。')
    controls = dict(DEFAULTS)
    for spec in CONTROLS:
        key = spec['key']
        n = raw.get(key, spec['default'])
        if type(n) not in (int, float) or not math.isfinite(n) or not spec['min'] <= n <= spec['max']:
            raise ValueError(f"{spec['label']}必须在 {spec['min']}–{spec['max']} 之间。")
        if spec['step'] >= 1 and n != int(n):
            raise ValueError(f"{spec['label']}必须是整数。")
        steps = (n - spec['min']) / spec['step']
        if not math.isclose(steps, round(steps), abs_tol=1e-7):
            raise ValueError(f"{spec['label']}的调节步长为 {spec['step']}。")
        controls[key] = int(n) if spec['step'] >= 1 else round(float(n), 4)
    return dict(schema_version=SCHEMA_VERSION, algo_version=ALGO_VERSION['G2'],
                layout_seed=seed, terrain_seed=terrain, player_spacing=spacing, controls=controls)


def config_from_spec(spec):
    """Export source-version settings, never label a historical map as current."""
    params = spec['params']
    controls = {key: params.get(key, default) for key, default in DEFAULTS.items()}
    controls.update(plateau_max=params['plateau_count'][1],
                    river_width=sum(params['river_width']) / 2.,
                    obstacle_percent=round(params['cover_target_frac'] * 100))
    return dict(schema_version=SCHEMA_VERSION, algo_version=spec['algo_version'],
                layout_seed=spec['master_seed'], terrain_seed=params.get('terrain_seed', 0),
                player_spacing='any', controls=controls)


def generator_params(config):
    c = config['controls']
    params = dict(G2_DEFAULTS)
    for key in DEFAULTS:
        if key in params and key != 'river_width':
            params[key] = c[key]
    params.update(terrain_seed=config['terrain_seed'],
                  plateau_count=(6, c['plateau_max']),
                  river_width=(c['river_width'] - 2., c['river_width'] + 2.),
                  cover_target_frac=c['obstacle_percent'] / 100.,
                  obstacle_frac_min=c['obstacle_percent'] / 100. - .005,
                  obstacle_frac_max=c['obstacle_percent'] / 100. + .005)
    return params


CHECK_LABELS = {
    'plateau_area_pass': '台地可用顶面占比至少12%',
    'bridge_redundancy_pass': '任意单桥封闭后四家仍互通',
    'river_presence_pass': '河流符合选择', 'lake_count_pass': '湖泊数量符合选择',
    'lake_size_pass': '湖泊面积符合选择', 'lake_strategy_pass': '湖泊阻隔玩家间的直线通路',
    'lake_shape_pass': '湖泊完整且与河流分离', 'spawn_layout_pass': '出生距离与领地公平',
    'solid_frac_pass': '障碍占比符合目标（±0.5%）', 'solid_comp_pass': '障碍分量数量',
    'max_block_pass': '单块障碍规模', 'open_single_pass': '所有可走区域连通',
    'keypoints_pass': '出生与争夺点可达', 'struct_connect_pass': '坡口、桥头与台地可达',
    'plateau_full_pass': '台地数量', 'plateau_strategy_pass': '台地具备战略用途',
    'plateau_ramps_pass': '每块台地至少两个有效坡口', 'home_plateau_pass': '两座出生台地',
    'water_connected_pass': '有河时主河贯通，无河时不生成河道', 'water_crossings_pass': '有河时桥梁确实跨越河岸',
    'crossing_count_pass': '过河点数量符合设置', 'water_semantics_pass': '河床与桥面一致',
    'contest_fair_pass': '邻接争夺路程比 ≤ 1.3', 'plateau_fair_pass': '中立高地访问比 ≤ 1.7',
    'expansion_fair_pass': '扩张路程比 ≤ 1.3', 'neutral_contest_pass': '至少两座中立高地',
    'flank_width_pass': '路线最窄处 ≥ 5m', 'routes_clear_pass': '路线不穿障碍',
    'route_alternatives_pass': '各方向有备选路线', 'bridge_width_pass': '桥梁实测宽度',
    'home_clear_pass': '出生点 20m 净空', 'path_fairness_pass': '邻接路程比 ≤ 1.6',
}
