"""Keep offered workbench options from fighting the generator.

Random generate does not lock a G1 layout. A layout that cannot host the
chosen river/lake geometry is swapped automatically. Locked layout_seed
(replay / explicit API) still fails cleanly and never shrinks lakes.
"""

from ..gates.g2_layout import hard_layout_reject

WATER_COMBOS = (
    dict(value='crossed', river_enabled=1, river_layout=2, lake_count=0),
    dict(value='single_lake', river_enabled=1, river_layout=1, lake_count=1),
    dict(value='single_two_lakes', river_enabled=1, river_layout=1, lake_count=2),
    dict(value='crossed_lake', river_enabled=1, river_layout=2, lake_count=1),
    dict(value='separate_lake', river_enabled=1, river_layout=3, lake_count=1),
    dict(value='two_lakes', river_enabled=0, river_layout=2, lake_count=2),
)


def attempts_are_hard_rejects(attempts):
    if not attempts:
        return False
    return all(hard_layout_reject(item.get('rejected')) for item in attempts)


def align_water_controls(controls):
    """Snap river_layout onto a named combo when river/lake chips no longer match one."""
    aligned = dict(controls)
    river = int(aligned.get('river_enabled', 1))
    lakes = int(aligned.get('lake_count', 0))
    layout = int(aligned.get('river_layout', 2))
    if any(item['river_enabled'] == river and item['river_layout'] == layout
           and item['lake_count'] == lakes for item in WATER_COMBOS):
        return aligned
    matches = [item for item in WATER_COMBOS
               if item['river_enabled'] == river and item['lake_count'] == lakes]
    if matches:
        aligned['river_layout'] = matches[0]['river_layout']
    return aligned


#: 已经人工验证过"哪个水系组合能在哪些 G1 布局上过检"的登记表（**唯一实现**）。
#: 来源：`RTS_Map_Tool/review/G2/water_combos/` 的产物（2026-09-15，`all_pass=True` 的 seed）。
#: 为什么要这张表：随机生成原来只在池子里盲轮，实测「双湖盆地」轮了 28 套布局、耗时 87s，
#: 最后仍拿回一张不过几何检查的图 —— 玩家感受就是"空生成长等"。
#: 键 = (river_enabled, river_layout, lake_count)，值 = 已验证容纳该水系的布局 seed（优先级从高到低）。
VERIFIED_WATER_LAYOUTS = {
    (1, 2, 0): (36, 5),           # 交错双河（工作台任务实测 ~3s 出图）
    (1, 1, 1): (16,),             # 单河一湖
    (1, 2, 1): (16, 35),          # 交河一湖
    (1, 3, 1): (16,),             # 分流一湖
    (1, 1, 2): (61, 16, 35, 47),  # 单河双湖
    (0, 2, 2): (35,),             # 双湖盆地（只有 35 号布局被验证能过）
}

#: 连续多少套布局"根本放不下所选水域"就认为整池都没戏 —— 收手，别让玩家干等。
HARD_REJECT_STREAK_LIMIT = 4

#: 一次生成最多轮换多少套布局（一套 ≈3~5s）：`双湖盆地` 实测轮遍 30 套用了 ~100s，
#: 最后仍交回一张不过检的图。超过上限就当作"池子试完了"，把最好的那张交给玩家。
#: 【2026-09-15 提速】从 8 收到 4：VERIFIED_WATER_LAYOUTS 已把"能过检的水系↔布局"
#: 排在最前，盲轮只是兜底，8 套 ≈40s 的等待对玩家没有额外收益。
LAYOUT_WALK_LIMIT = 4


def water_key(controls):
    """水系签名：与 `settings.WATER_COMBOS` / VERIFIED_WATER_LAYOUTS 同一口径。"""
    controls = controls if isinstance(controls, dict) else {}
    return (int(controls.get('river_enabled', 1)),
            int(controls.get('river_layout', 2)),
            int(controls.get('lake_count', 0)))


def spacing_pool(layouts, spacing):
    if spacing == 'any':
        return [item['seed'] for item in layouts]
    return [item['seed'] for item in layouts if item.get('spacing') == spacing]


def preferred_water_layouts(layouts, controls, spacing):
    """该水系组合里、布局库中确实存在且与所选玩家距离不冲突的 seed（有序）。"""
    by_seed = {item['seed']: item for item in layouts}
    verified = [seed for seed in VERIFIED_WATER_LAYOUTS.get(water_key(controls), ())
                if seed in by_seed]
    if spacing != 'any':
        # 玩家距离是硬筛（server.start 会校验布局 band），不能为了水系把它顶掉。
        verified = [seed for seed in verified if by_seed[seed].get('spacing') == spacing]
    return verified


def generation_pool(layouts, spacing, water_preferred=()):
    """Prefer the chosen spacing, then the rest of the library so a band cannot dead-end.

    已被验证能容纳所选水系的布局排到最前：这两个约束打架时，先保证"放得下水"，
    否则就是轮遍整池、耗时 87s 再拿回一张不过检的图。
    """
    primary = spacing_pool(layouts, spacing)
    if spacing == 'any':
        ordered = shuffle_pool(primary)
    else:
        extra = [seed for seed in spacing_pool(layouts, 'any') if seed not in primary]
        ordered = shuffle_pool(primary) + shuffle_pool(extra)
    pool = set(ordered)
    head = [seed for seed in water_preferred if seed in pool]
    head_set = set(head)
    return head + [seed for seed in ordered if seed not in head_set]


def note_hard_reject(job, attempts):
    """记一次"这套布局根本放不下水域"；返回 True = 可以收手（连续硬拒达上限）。"""
    if attempts_are_hard_rejects(attempts):
        job['hard_reject_streak'] = int(job.get('hard_reject_streak', 0)) + 1
    else:
        job['hard_reject_streak'] = 0
    return int(job.get('hard_reject_streak', 0)) >= HARD_REJECT_STREAK_LIMIT


def shuffle_pool(seeds, rng=None):
    import secrets
    ordered = list(seeds)
    (rng or secrets.SystemRandom()).shuffle(ordered)
    return ordered


def next_layout_seed(job):
    if job.get('layout_locked', True):
        return None
    tried = {item['seed'] for item in job.get('layout_tried', [])}
    # 上限：一套布局 ~3s，轮遍 30 套就是 ~100s 白等（实测双湖盆地）。
    # 玩家要的是"别干等"，不是"陪生成器轮完全池"，超限就按池子试完处理。
    if len(tried) >= LAYOUT_WALK_LIMIT:
        return None
    for seed in job.get('layout_pool') or []:
        if seed not in tried:
            return seed
    return None


def record_layout_try(job, seed, reason, attempts=None):
    job.setdefault('layout_tried', []).append(dict(
        seed=int(seed), reason=reason,
        attempts=len(attempts or []),
        rejected=(attempts or [{}])[-1].get('rejected') if attempts else None))


def bind_job_layout(job, seed, layouts, reroll_terrain=False):
    layout = next((item for item in layouts if item['seed'] == seed), None)
    job['config']['layout_seed'] = int(seed)
    if reroll_terrain and not job.get('terrain_locked', True):
        import secrets
        job['config']['terrain_seed'] = secrets.randbelow(2147483648)
    job['title'] = f"布局 {seed} · 地貌 {job['config'].get('terrain_seed', 0)}"
    if layout is not None:
        job['spacing'] = layout['spacing']
        if job['config'].get('player_spacing') != 'any' and layout['spacing'] != job['config']['player_spacing']:
            job['config']['player_spacing'] = layout['spacing']
    return layout


def should_rotate_failed_checks(job, mapspec):
    if job.get('layout_locked', True):
        return False
    return mapspec is None or not bool(mapspec.get('all_pass'))
