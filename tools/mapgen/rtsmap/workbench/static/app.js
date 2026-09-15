/* RTS map workbench client. The generator pipeline remains the source of truth. */
(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const dom = {
    version: $('version'), form: $('generator-form'), settings: $('settings'),
    terrainSeed: $('terrain-seed'),
    randomSeed: $('random-seed'), controls: $('controls'), reset: $('reset'),
    generate: $('generate'), generateG2: $('generate-g2'), dirty: $('dirty'), progress: $('progress'),
    progressPhase: $('progress-phase'), progressDetail: $('progress-detail'), elapsed: $('elapsed'),
    mapImage: $('map-image'), mapTransform: $('map-transform'), viewport: $('viewport'),
    empty: $('empty'), mapStatus: $('map-status'), mapTitle: $('map-title'),
    history: $('history'), historyCount: $('history-count'), result: $('result'),
    resultEmpty: $('result-empty'), resultSummary: $('result-summary'), metrics: $('metrics'),
    stageList: $('stage-list'), jobActions: $('job-actions'), retryJob: $('retry-job'),
    rebuildVisual: $('rebuild-visual'),
    failed: $('failed'), checks: $('checks'), checksIcon: $('checks-icon'),
    checkCount: $('check-count'), useSettings: $('use-settings'),
    exportConfig: $('export-config'), exportMap: $('export-map'), importConfig: $('import-config'),
    toast: $('toast'), zoomIn: $('zoom-in'), zoomOut: $('zoom-out'), fit: $('fit'),
    simple: $('simple-controls'), layoutCaption: $('layout-caption'), replay: $('replay-settings'),
  };

  const state = {
    boot: null, jobs: [], selectedId: null, selectedJob: null, activeId: null,
    layer: 'g4_ortho', appliedConfig: null, pollTimer: null, pollPending: false,
    elapsedTimer: null, transform: { scale: 1, x: 0, y: 0 }, drag: null,
    displayedImageJob: null, toastTimer: null, spacing: 'any', sourceLayout: null,
  };

  const FULL_LAYERS = ['g4_ortho', 'g4_iso45', 'g4_oblique', 'g3', 'overview', 'strategy'];
  const G2_LAYERS = ['overview', 'strategy'];

  const imageLayers = [...document.querySelectorAll('[data-layer]')];
  const controlByKey = () => new Map((state.boot?.controls || []).map((item) => [item.key, item]));

  function create(tag, props = {}, children = []) {
    const element = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (key === 'className') element.className = value;
      else if (key === 'text') element.textContent = value;
      else if (key === 'htmlFor') element.htmlFor = value;
      else if (key === 'dataset') Object.entries(value).forEach(([dataKey, dataValue]) => { element.dataset[dataKey] = dataValue; });
      else if (key.startsWith('data-')) element.dataset[key.slice(5)] = value;
      else if (key in element) element[key] = value;
      else element.setAttribute(key, value);
    }
    children.flat().filter(Boolean).forEach((child) => element.append(child));
    return element;
  }

  function apiError(payload, fallback) {
    return payload && typeof payload.error === 'string' ? payload.error : fallback;
  }

  async function request(path, options = {}) {
    let response;
    try {
      response = await fetch(path, { cache: 'no-store', ...options });
    } catch (_) {
      throw new Error('无法连接工作台服务。请确认 serve_g2.py 正在运行。');
    }
    const isJson = (response.headers.get('content-type') || '').includes('application/json');
    const payload = isJson ? await response.json().catch(() => null) : await response.text();
    if (!response.ok) throw new Error(apiError(payload, `请求失败（${response.status}）`));
    return payload;
  }

  function fixedNumber(value, decimals = 2) {
    if (value == null || !Number.isFinite(Number(value))) return '—';
    return Number(value).toLocaleString('zh-CN', { maximumFractionDigits: decimals });
  }

  function seconds(value) {
    if (!Number.isFinite(Number(value))) return '—';
    const total = Math.max(0, Math.round(Number(value)));
    return total < 60 ? `${total}s` : `${Math.floor(total / 60)}m ${total % 60}s`;
  }

  function sameConfig(a, b) {
    if (!a || !b) return false;
    if (a.layout_seed !== b.layout_seed || a.terrain_seed !== b.terrain_seed || a.algo_version !== b.algo_version) return false;
    if ((a.player_spacing ?? 'any') !== (b.player_spacing ?? 'any')) return false;
    const keys = Object.keys(a.controls || {});
    return keys.length === Object.keys(b.controls || {}).length
      && keys.every((key) => Number(a.controls[key]) === Number(b.controls[key]));
  }

  function toast(message, kind = '') {
    dom.toast.textContent = message;
    dom.toast.className = `toast ${kind}`.trim();
    dom.toast.hidden = false;
    clearTimeout(state.toastTimer);
    state.toastTimer = window.setTimeout(() => { dom.toast.hidden = true; }, kind === 'error' ? 6500 : 4200);
  }

  function resetTransform() {
    state.transform = { scale: 1, x: 0, y: 0 };
    applyTransform();
  }

  function applyTransform() {
    const { scale, x, y } = state.transform;
    dom.mapTransform.style.transform = `translate(${x}px, ${y}px) scale(${scale})`;
  }

  function zoom(delta) {
    state.transform.scale = Math.min(4, Math.max(.5, Number((state.transform.scale + delta).toFixed(2))));
    applyTransform();
  }

  function currentConfig() {
    const controls = {};
    for (const control of state.boot.controls) {
      controls[control.key] = Number(document.getElementById(`value-${control.key}`).value);
    }
    return {
      schema_version: state.boot.schema_version,
      algo_version: state.boot.version,
      layout_seed: state.sourceLayout,
      terrain_seed: Number(dom.terrainSeed.value),
      player_spacing: state.spacing,
      controls,
    };
  }

  function updateDirty() {
    if (!state.boot) return;
    let config;
    try { config = currentConfig(); } catch (_) { return; }
    const validationError = basicValidation(config, false);
    const dirty = !sameConfig(config, state.appliedConfig);
    dom.dirty.textContent = validationError || (dirty
      ? '参数有改动，生成后才会应用到地图。'
      : '设置与当前地图一致，点击生成会得到新的随机地图。');
    dom.dirty.classList.toggle('invalid', Boolean(validationError));
    syncChoices();
  }

  function basicValidation(config, replay = false) {
    const layoutKnown = state.boot.layouts.some((layout) => layout.seed === config.layout_seed);
    if (replay && !layoutKnown) return '请先载入一张地图的参数，再按编号复现。';
    const layout = state.boot.layouts.find((item) => item.seed === config.layout_seed);
    if (replay && config.player_spacing !== 'any' && layout.spacing !== config.player_spacing) return '距离偏好已改变，请使用随机生成地图。';
    if (!Number.isInteger(config.terrain_seed) || config.terrain_seed < 0 || config.terrain_seed > 2147483647) return '地貌 Seed 必须是 0–2147483647 的整数。';
    for (const control of state.boot.controls) {
      const value = config.controls[control.key];
      const steps = (value - control.min) / control.step;
      if (!Number.isFinite(value) || value < control.min || value > control.max || Math.abs(steps - Math.round(steps)) > 1e-6) {
        return `${control.label}必须在 ${control.min}–${control.max} 内，并遵循步长 ${control.step}。`;
      }
    }
    return '';
  }

  function eligibleLayouts() {
    return state.boot.layouts.filter((layout) => state.spacing === 'any' || layout.spacing === state.spacing);
  }

  function renderChoices() {
    dom.simple.replaceChildren(...state.boot.choices.map((choice) => create('div', { className: 'simple-control' }, [
      create('div', { className: 'choice-label', text: choice.label }, [create('span', { id: `custom-${choice.key}`, className: 'custom-value' })]),
      create('div', { className: 'choice-options', role: 'group', ariaLabel: choice.label }, choice.options.map((option) => {
        const button = create('button', { type: 'button', text: option.label, title: option.detail || option.label,
          dataset: { choice: choice.key, value: String(option.value) }, ariaPressed: 'false' });
        button.addEventListener('click', () => {
          if (choice.key === 'player_spacing') {
            state.spacing = option.value;
          } else {
            for (const [key, value] of Object.entries(option.controls || { [choice.key]: option.value })) {
              $(`value-${key}`).value = String(value);
              $(`range-${key}`).value = String(value);
            }
          }
          updateDirty();
        });
        return button;
      })),
      choice.hint ? create('p', { className: 'hint', text: choice.hint }) : null,
    ])));
  }

  function syncChoices() {
    dom.layoutCaption.textContent = `出生点由系统随机安排，当前距离范围内有 ${eligibleLayouts().length} 套布局。`;
    for (const choice of state.boot.choices) {
      const composite = choice.options.some((option) => option.controls);
      const value = composite
        ? choice.options.find((option) => Object.entries(option.controls).every(([key, n]) => Number($(`value-${key}`).value) === n))?.value
        : choice.key === 'player_spacing' ? state.spacing : $(`value-${choice.key}`).value;
      dom.simple.querySelectorAll(`[data-choice="${choice.key}"]`).forEach((button) => {
        const selected = button.dataset.value === String(value);
        button.setAttribute('aria-pressed', String(selected));
        button.classList.toggle('selected', selected);
      });
      const custom = !choice.options.some((option) => String(option.value) === String(value));
      $(`custom-${choice.key}`).textContent = custom ? `自定义${composite ? '' : ` ${value}`}` : '';
    }
    const river = Number($('value-river_enabled').value) === 1;
    for (const key of ['river_width', 'river_bend_scale', 'river_crossings']) {
      $(`value-${key}`).disabled = !river;
      $(`range-${key}`).disabled = !river;
      $(`value-${key}`).closest('.control').classList.toggle('inactive', !river);
    }
    const lakes = Number($('value-lake_count').value) > 0;
    $('value-lake_area').disabled = !lakes; $('range-lake_area').disabled = !lakes;
    $('value-lake_area').closest('.control').classList.toggle('inactive', !lakes);
  }

  function syncControl(control, source) {
    const range = document.getElementById(`range-${control.key}`);
    const value = document.getElementById(`value-${control.key}`);
    if (source === range) value.value = range.value;
    if (source === value && value.validity.valid && value.value !== '') range.value = value.value;
    updateDirty();
  }

  function controlElement(control) {
    const range = create('input', { id: `range-${control.key}`, type: 'range', min: control.min, max: control.max, step: control.step, value: control.default });
    const value = create('input', { id: `value-${control.key}`, type: 'number', min: control.min, max: control.max, step: control.step, value: control.default, ariaLabel: control.label });
    range.addEventListener('input', () => syncControl(control, range));
    value.addEventListener('input', () => syncControl(control, value));
    value.addEventListener('change', () => {
      if (value.validity.valid && value.value !== '') range.value = value.value;
      updateDirty();
    });
    return create('div', { className: 'control', hidden: ['river_enabled', 'river_layout', 'lake_count'].includes(control.key) }, [
      create('div', { className: 'control-row' }, [
        create('label', { htmlFor: range.id, text: control.label }),
        create('div', { className: 'numeric-value' }, [value, create('span', { className: 'unit', text: control.unit || ' ' })]),
      ]),
      range,
      create('div', { className: 'range-labels' }, [create('span', { text: String(control.min) }), create('span', { text: String(control.max) })]),
      create('p', { className: 'hint', text: control.hint }),
    ]);
  }

  function renderControls() {
    dom.controls.replaceChildren();
    const groups = new Map();
    state.boot.controls.forEach((control) => {
      if (!groups.has(control.group)) groups.set(control.group, []);
      groups.get(control.group).push(control);
    });
    let index = 2;
    for (const [group, controls] of groups) {
      const summary = create('summary', {}, [create('span', {}, [create('span', { className: 'number', text: String(index++).padStart(2, '0') }), create('span', { text: group })])]);
      const details = create('details', { className: 'parameter-group' }, [summary, ...controls.map(controlElement)]);
      dom.controls.append(details);
    }
  }

  function setFormDisabled(disabled) {
    dom.settings.disabled = disabled;
    dom.generate.disabled = disabled;
    dom.generateG2.disabled = disabled;
    dom.reset.disabled = disabled; dom.replay.disabled = disabled || state.sourceLayout == null;
    dom.useSettings.disabled = disabled; dom.importConfig.disabled = disabled;
    dom.generate.querySelector('span').textContent = disabled ? '正在生成…' : '生成完整地图';
  }

  function populateConfig(config, { announce = false } = {}) {
    const target = normalizeConfigForUi(config);
    state.spacing = target.player_spacing;
    state.sourceLayout = target.layout_seed;
    dom.replay.disabled = Boolean(state.activeId);
    dom.terrainSeed.value = String(target.terrain_seed);
    for (const control of state.boot.controls) {
      const value = target.controls[control.key];
      document.getElementById(`range-${control.key}`).value = String(value);
      document.getElementById(`value-${control.key}`).value = String(value);
    }
    const isOld = config.algo_version && config.algo_version !== state.boot.version;
    if (isOld) {
      state.appliedConfig = null;
      if (announce) toast(`已载入 G2 ${config.algo_version} 的参数；将按当前 G2 ${state.boot.version} 重新生成，结果可能不同。`);
    } else {
      if (announce) toast('已载入这张图的参数。');
    }
    updateDirty();
  }

  function normalizeConfigForUi(config) {
    if (!config || typeof config !== 'object' || !config.controls || typeof config.controls !== 'object') throw new Error('参数文件缺少 controls。');
    const layoutSeed = Number(config.layout_seed);
    const terrainSeed = Number(config.terrain_seed ?? 0);
    const spacing = config.player_spacing ?? 'any';
    if (![1, state.boot.schema_version].includes(config.schema_version ?? 1)) throw new Error('不支持此参数文件版本。');
    if (!state.boot.choices.find((choice) => choice.key === 'player_spacing').options.some((option) => option.value === spacing)) throw new Error('玩家距离选项无效。');
    if (!state.boot.layouts.some((item) => item.seed === layoutSeed)) throw new Error('参数文件中的出生布局不在当前工作台中。');
    if (!Number.isInteger(terrainSeed) || terrainSeed < 0 || terrainSeed > 2147483647) throw new Error('参数文件中的地貌 Seed 无效。');
    const supported = new Set(state.boot.controls.map((item) => item.key));
    const unknown = Object.keys(config.controls).filter((key) => !supported.has(key));
    if (unknown.length) throw new Error(`参数文件包含当前工作台不支持的项目：${unknown.join('、')}。`);
    const controls = {};
    for (const control of state.boot.controls) {
      const value = Number(config.controls[control.key] ?? control.default);
      const steps = (value - control.min) / control.step;
      if (!Number.isFinite(value) || value < control.min || value > control.max || Math.abs(steps - Math.round(steps)) > 1e-6) {
        throw new Error(`参数文件中的“${control.label}”不在当前允许范围内。`);
      }
      controls[control.key] = value;
    }
    const layout = state.boot.layouts.find((item) => item.seed === layoutSeed);
    if (spacing !== 'any' && layout.spacing !== spacing) throw new Error('布局与玩家距离筛选不一致。');
    return { layout_seed: layoutSeed, terrain_seed: terrainSeed, controls, player_spacing: spacing };
  }

  function upsertJob(job) {
    const index = state.jobs.findIndex((item) => item.id === job.id);
    if (index >= 0) state.jobs[index] = job;
    else state.jobs.unshift(job);
    state.jobs.sort((a, b) => String(b.created_at || '').localeCompare(String(a.created_at || '')));
  }

  function jobStatus(job) {
    if (job.status === 'running') return ['生成中', 'neutral'];
    if (job.status === 'error') return [job.error_kind === 'interrupted' ? '已中断' : '未生成', 'fail'];
    if ((job.target || 'g2') === 'full') return job.map_pass ? ['地图通过', ''] : ['需检查', 'fail'];
    return job.result?.all_pass ? ['几何通过', ''] : ['需检查', 'fail'];
  }

  function layersFor(job) {
    return (job.target || 'g2') === 'full' ? FULL_LAYERS : G2_LAYERS;
  }

  function defaultLayer(job) {
    return (job.target || 'g2') === 'full' ? 'g4_ortho' : 'overview';
  }

  function syncLayerTabs(job) {
    const full = (job.target || 'g2') === 'full';
    const g3ok = full && job.stages?.g3_content?.status === 'done';
    const g4ok = full && job.stages?.engine?.status === 'done';
    const avail = {
      g4_ortho: g4ok, g4_iso45: g4ok, g4_oblique: g4ok, g3: g3ok,
      overview: true, strategy: true,
    };
    imageLayers.forEach((button) => {
      const ok = full ? !!avail[button.dataset.layer] : (button.dataset.layer === 'overview' || button.dataset.layer === 'strategy');
      button.hidden = !ok;
      if (!ok && state.layer === button.dataset.layer) state.layer = 'overview';
    });
    if (full && !avail[state.layer]) state.layer = g4ok ? 'g4_ortho' : 'overview';
    if (!full && state.layer !== 'overview' && state.layer !== 'strategy') state.layer = 'overview';
    imageLayers.forEach((button) => {
      const active = button.dataset.layer === state.layer;
      button.classList.toggle('active', active); button.setAttribute('aria-pressed', String(active));
    });
  }

  function imageUrl(job, layer) {
    return `/artifacts/${encodeURIComponent(job.id)}/${layer}.png?job=${encodeURIComponent(job.id)}`;
  }

  function renderHistory() {
    dom.history.replaceChildren();
    dom.historyCount.textContent = String(state.jobs.length);
    state.jobs.forEach((job) => {
      const [status, statusClass] = jobStatus(job);
      const layer = defaultLayer(job);
      const preview = job.status === 'done'
        ? create('img', { src: imageUrl(job, layer), alt: '' })
        : create('div', { className: 'history-placeholder', text: job.status === 'running' ? '⋯' : '×' });
      const result = job.result;
      const title = job.baseline ? `参考 ${job.result?.version || ''} · 布局 ${job.config?.layout_seed}` : job.title;
      const kindTag = (job.target || 'g2') === 'full' && !job.baseline ? '完整 · ' : '地形 · ';
      const detail = result ? `${kindTag}${result.rivers ?? 0} 河 · ${result.lakes ?? 0} 湖 · ${result.plateaus} 高地` : job.status === 'error' ? (job.error || '未生成') : stagePhaseText(job);
      const card = create('button', { type: 'button', className: `history-card${job.id === state.selectedId ? ' selected' : ''}`, ariaPressed: String(job.id === state.selectedId) }, [
        preview,
        create('div', { className: 'history-info' }, [create('strong', { text: title }), create('p', { text: detail }), create('span', { className: `status ${statusClass}`, text: status })]),
      ]);
      card.addEventListener('click', () => selectJob(job.id));
      dom.history.append(card);
    });
  }

  function stagePhaseText(job) {
    const progress = job.progress || {};
    return [progress.stage, progress.phase].filter(Boolean).join(' · ') || '正在生成';
  }

  function setMapImage(job) {
    const expected = imageUrl(job, state.layer);
    const selectedId = job.id;
    dom.mapImage.onload = () => {
      if (state.selectedId !== selectedId || dom.mapImage.dataset.src !== expected) return;
      dom.mapImage.hidden = false;
      dom.empty.hidden = true;
      state.displayedImageJob = selectedId;
      resetTransform();
    };
    dom.mapImage.onerror = () => {
      if (state.selectedId !== selectedId) return;
      dom.mapImage.hidden = true;
      dom.empty.hidden = false;
      dom.empty.querySelector('h2').textContent = '预览图无法加载';
      dom.empty.querySelector('p').textContent = '地图数据仍可从历史记录重新选择，或稍后刷新页面。';
      toast('预览图加载失败，请检查本地服务。', 'error');
    };
    dom.mapImage.dataset.src = expected;
    dom.mapImage.src = expected;
  }

  function clearMap(title, description) {
    dom.mapImage.hidden = true;
    dom.mapImage.removeAttribute('src');
    dom.empty.hidden = false;
    dom.empty.querySelector('h2').textContent = title;
    dom.empty.querySelector('p').textContent = description;
    state.displayedImageJob = null;
    resetTransform();
  }

  function setMapStatus(text, type = 'neutral') {
    dom.mapStatus.textContent = text;
    dom.mapStatus.className = `status ${type}`;
  }

  function setDownloads(job) {
    dom.exportConfig.href = `/artifacts/${encodeURIComponent(job.id)}/config.json`;
    dom.exportMap.href = `/artifacts/${encodeURIComponent(job.id)}/bundle.zip`;
    dom.exportConfig.removeAttribute('aria-disabled'); dom.exportMap.removeAttribute('aria-disabled');
  }

  function clearDownloads() {
    dom.exportConfig.removeAttribute('href'); dom.exportMap.removeAttribute('href');
    dom.exportConfig.setAttribute('aria-disabled', 'true'); dom.exportMap.setAttribute('aria-disabled', 'true');
  }

  function metric(label, value, unit = '') {
    return create('div', { className: 'metric' }, [create('span', { text: label }), create('strong', { text: value }, [unit ? create('em', { text: unit }) : null])]);
  }

  function renderResult(job) {
    const result = job.result;
    if (!result) return;
    const full = (job.target || 'g2') === 'full';
    const pass = full ? job.map_pass : result.all_pass;
    dom.result.hidden = false;
    dom.resultEmpty.hidden = true;
    dom.resultSummary.className = `result-summary${pass ? '' : ' fail'}`;
    dom.resultSummary.replaceChildren(
      create('strong', { text: full ? (pass ? '地图完成并通过全部验收' : '地图已生成，但有未通过的检查') : (pass ? '通过全部几何检查' : '有待处理的几何检查') }),
      create('p', { text: `${job.baseline ? '历史参考 · ' : ''}${full ? '完整流水线' : 'G2 快速预览'} · G2 ${result.version} · 候选 ${result.chosen_attempt} · 耗时 ${seconds(job.duration)}` }),
    );
    renderStageList(job);
    dom.metrics.replaceChildren(
      metric('最近玩家距离', fixedNumber(result.nearest_pair_m, 1), 'm'),
      metric('高地数量', fixedNumber(result.plateaus, 0), '座'),
      metric('河流', fixedNumber(result.rivers, 0), '条'),
      metric('湖泊', fixedNumber(result.lakes, 0), '个'),
      metric('湖泊总面积', fixedNumber(result.lake_area_m2, 0), 'm²'),
      metric('主河基准宽', fixedNumber(result.river_width_m, 1), 'm'),
      metric('有效过河点', fixedNumber(result.crossings, 0), '处'),
      metric('路线最窄处', fixedNumber(result.min_route_width, 2), 'm'),
      ...(full ? [
        metric('素材实例', fixedNumber(job.stages?.g3_content?.instance_count, 0), '个'),
        metric('导航烘焙', fixedNumber(job.stages?.engine?.nav_bake_wait_s, 1), 's'),
        metric('视觉装饰', fixedNumber(job.stages?.g4_scene?.visual_stats?.total, 0), '件'),
      ] : []),
    );
    const checks = Object.entries(result.checks || {});
    const failed = checks.filter(([, value]) => !value);
    dom.checkCount.textContent = `${checks.length - failed.length}/${checks.length}`;
    dom.checksIcon.textContent = failed.length ? `${failed.length} 项待处理` : '✓';
    dom.checksIcon.style.color = failed.length ? '#a17444' : '';
    dom.checks.replaceChildren(...checks.map(([key, ok]) => create('div', { className: `check${ok ? '' : ' fail'}`, text: state.boot.check_labels[key] || key })));
    dom.failed.hidden = failed.length === 0;
    if (failed.length) {
      dom.failed.replaceChildren(create('strong', { text: '当前候选未通过：' }), create('span', { text: failed.map(([key]) => state.boot.check_labels[key] || key).join('；') }));
    } else dom.failed.replaceChildren();
    dom.jobActions.hidden = job.baseline;
    dom.retryJob.disabled = Boolean(state.activeId);
    dom.rebuildVisual.disabled = Boolean(state.activeId) || !(full && job.stages?.g4_scene?.status === 'done');
    setDownloads(job);
  }

  const STAGE_TEXT = {
    g1_input: '出生布局', g2_terrain: '地形生成', g3_content: '资源与素材',
    g4_scene: '游戏场景导出', engine: '引擎加载与导航验收',
  };
  const STAGE_STATUS_TEXT = {
    done: '完成', running: '进行中', error: '失败', skipped: '未运行',
  };

  function renderStageList(job) {
    const full = (job.target || 'g2') === 'full';
    dom.stageList.hidden = !full || job.baseline;
    if (!full || job.baseline) return;
    const stages = job.stages || {};
    dom.stageList.replaceChildren(...Object.keys(STAGE_TEXT).map((name) => {
      const stage = stages[name] || {};
      const status = stage.status || '等待';
      const cls = status === 'done' ? (stage.pass === false ? ' fail' : '') : status === 'error' ? ' fail' : '';
      const detail = stage.status === 'done' && stage.duration_s != null ? `${stage.duration_s}s`
        : stage.error ? String(stage.error).slice(0, 90) : stage.reason || '';
      return create('div', { className: `stage-item${cls}` }, [
        create('span', { className: 'stage-name', text: STAGE_TEXT[name] }),
        create('span', { className: 'stage-state', text: STAGE_STATUS_TEXT[status] || status }),
        create('span', { className: 'stage-detail', text: detail }),
      ]);
    }));
  }

  function renderNoResult(text) {
    dom.result.hidden = true;
    dom.resultEmpty.hidden = false;
    dom.resultEmpty.textContent = text;
    dom.checkCount.textContent = '—';
    clearDownloads();
  }

  function renderProgress(job) {
    if (job.status !== 'running') {
      dom.progress.hidden = true;
      clearInterval(state.elapsedTimer); state.elapsedTimer = null;
      return;
    }
    const progress = job.progress || {};
    dom.progress.hidden = false;
    dom.progressPhase.textContent = progress.stage ? `${progress.stage} · ${progress.phase || ''}` : (progress.phase || '正在生成地图');
    const suffix = Array.isArray(progress.failed_checks) && progress.failed_checks.length
      ? `上一候选未通过 ${progress.failed_checks.length} 项检查`
      : progress.reason || '保持当前预览，完成后自动更新。';
    dom.progressDetail.textContent = progress.attempt != null
      ? `候选 ${progress.attempt || 0} / ${progress.limit || '—'} · ${suffix}`
      : suffix;
    const refresh = () => { dom.elapsed.textContent = seconds(job.duration); };
    refresh(); clearInterval(state.elapsedTimer); state.elapsedTimer = setInterval(refresh, 500);
  }

  function renderError(job) {
    renderProgress(job);  // 确保进度横幅清除
    const reason = job.error || '生成未完成。';
    const attempts = Array.isArray(job.attempts) && job.attempts.length
      ? ` 已尝试 ${job.attempts.length} 个候选：${job.attempts.map((item) => item.rejected || (item.failed_checks || []).join('、') || '未通过').join('；')}`
      : '';
    const stageInfo = job.stages ? Object.entries(job.stages).filter(([, s]) => s.status === 'error')
      .map(([name, s]) => `${STAGE_TEXT[name] || name}：${s.error || '失败'}`).join('；') : '';
    renderNoResult(`${reason}${attempts}${stageInfo ? `\n${stageInfo}` : ''}`);
    setMapStatus(job.error_kind === 'interrupted' ? '已中断' : '未生成', 'fail');
    dom.mapTitle.textContent = job.title || '本次请求没有生成地图';
    renderStageList(job);
    dom.result.hidden = false; dom.resultEmpty.hidden = true;
    dom.jobActions.hidden = false;
    dom.retryJob.disabled = Boolean(state.activeId);
    dom.rebuildVisual.disabled = true;
    clearDownloads();
    clearMap('没有可展示的新地图', '可重试本任务（输入不变），或重新随机生成。');
  }

  function selectJob(id) {
    const job = state.jobs.find((item) => item.id === id);
    if (!job) return;
    state.selectedId = job.id;
    state.selectedJob = job;
    syncLayerTabs(job);
    renderHistory(); renderProgress(job);
    if (job.status === 'done') {
      const full = (job.target || 'g2') === 'full';
      const pass = full ? job.map_pass : job.result?.all_pass;
      setMapStatus(full ? (pass ? '地图通过' : '需检查') : (pass ? '几何通过' : '需检查'), pass ? '' : 'fail');
      const versionTag = full ? `完整地图${job.map_id ? ` · ${job.map_id}` : ''}` : `G2 ${job.result?.version || ''}`;
      dom.mapTitle.textContent = `${job.baseline ? '历史参考 · ' : ''}${job.title || `布局 ${job.config?.layout_seed}`} · ${versionTag}`;
      setMapImage(job); renderResult(job);
      state.appliedConfig = job.config?.algo_version === state.boot.version ? job.config : null;
      updateDirty();
    } else if (job.status === 'running') {
      setMapStatus('生成中', 'neutral');
      dom.mapTitle.textContent = `${job.title || '新候选'} · 当前预览保留上一张地图`;
      renderNoResult('正在生成。完成前，检查指标不会用旧图冒充新参数。');
      renderStageList(job);
    } else {
      renderError(job);
    }
  }

  function activeJob() { return state.activeId ? state.jobs.find((item) => item.id === state.activeId) : null; }

  function stopPolling() {
    clearInterval(state.pollTimer); state.pollTimer = null;
  }

  async function pollActive() {
    if (!state.activeId || state.pollPending) return;
    state.pollPending = true;
    try {
      const job = await request(`/api/jobs/${encodeURIComponent(state.activeId)}`);
      upsertJob(job);
      if (job.id === state.selectedId) selectJob(job.id);
      else renderHistory();
      if (job.status !== 'running') {
        state.activeId = null; stopPolling(); setFormDisabled(false);
        if (job.status === 'done' && job.id === state.selectedId) populateConfig(job.config);
        if (job.status === 'done') {
          if ((job.target || 'g2') === 'full') toast(job.map_pass ? '完整地图已生成并通过验收。' : '地图已生成，但有检查项未通过，请查看详情。', job.map_pass ? '' : 'error');
          else toast(job.result?.all_pass ? '新地图已通过全部几何检查。' : '新地图已生成，但有待处理的检查项。', job.result?.all_pass ? '' : 'error');
        }
        else toast(job.error || '生成未完成。', 'error');
      }
    } catch (error) {
      const current = activeJob();
      if (current) {
        current.pollError = error.message;
        if (current.id === state.selectedId) {
          dom.progressDetail.textContent = `${error.message} 正在重试状态查询。`;
        }
      }
    } finally {
      state.pollPending = false;
    }
  }

  function startPolling(id) {
    state.activeId = id;
    setFormDisabled(true);
    stopPolling(); pollActive();
    state.pollTimer = setInterval(pollActive, 1000);
  }

  async function generate(event, replay = false, target = 'full') {
    if (event?.preventDefault) event.preventDefault();
    if (state.activeId) return;
    const config = currentConfig();
    const error = basicValidation(config, replay);
    if (error) { toast(error, 'error'); return; }
    if (!replay) { delete config.layout_seed; delete config.terrain_seed; }
    config.target = target;
    setFormDisabled(true);
    try {
      const job = await request('/api/generate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(config) });
      upsertJob(job); state.appliedConfig = null;
      selectJob(job.id); startPolling(job.id);
    } catch (error) {
      setFormDisabled(false); toast(error.message, 'error');
    }
  }

  async function retryJob() {
    const job = state.selectedJob;
    if (!job || state.activeId) return;
    setFormDisabled(true);
    try {
      const updated = await request(`/api/jobs/${encodeURIComponent(job.id)}/retry`, { method: 'POST' });
      upsertJob(updated);
      selectJob(updated.id); startPolling(updated.id);
      toast('已从上次失败的阶段继续，输入保持不变。');
    } catch (error) {
      setFormDisabled(false); toast(error.message, 'error');
    }
  }

  async function rebuildVisual() {
    const job = state.selectedJob;
    if (!job || state.activeId) return;
    setFormDisabled(true);
    try {
      const updated = await request(`/api/jobs/${encodeURIComponent(job.id)}/rebuild_visual`,
        { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) });
      upsertJob(updated);
      selectJob(updated.id); startPolling(updated.id);
      toast('逻辑地图保持不变，正在重建视觉层与截图。');
    } catch (error) {
      setFormDisabled(false); toast(error.message, 'error');
    }
  }

  function updateLayer(layer) {
    state.layer = layer;
    imageLayers.forEach((button) => {
      const active = button.dataset.layer === layer;
      button.classList.toggle('active', active); button.setAttribute('aria-pressed', String(active));
    });
    if (state.selectedJob?.status === 'done') setMapImage(state.selectedJob);
  }

  function randomTerrainSeed() {
    const buffer = new Uint32Array(1);
    if (window.crypto?.getRandomValues) window.crypto.getRandomValues(buffer);
    else buffer[0] = Math.floor(Math.random() * 0x7fffffff);
    dom.terrainSeed.value = String(1 + (buffer[0] % 2147483647));
    updateDirty();
  }

  function resetDefaults() {
    const layout = state.sourceLayout ?? state.boot.layouts[0]?.seed;
    const controls = Object.fromEntries(state.boot.controls.map((control) => [control.key, control.default]));
    populateConfig({ layout_seed: layout, terrain_seed: 0, controls });
    state.appliedConfig = null;
    updateDirty(); toast('已恢复默认地貌参数，保留当前出生布局。');
  }

  async function importConfig(event) {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    try {
      const raw = JSON.parse(await file.text());
      normalizeConfigForUi(raw);
      populateConfig(raw, { announce: true });
    } catch (error) { toast(`无法导入参数：${error.message}`, 'error'); }
  }

  function loadSelectedSettings() {
    if (!state.selectedJob?.config) return;
    try { populateConfig(state.selectedJob.config, { announce: true }); }
    catch (error) { toast(`无法载入参数：${error.message}`, 'error'); }
  }

  function bindInteractions() {
    dom.form.addEventListener('submit', (event) => generate(event, false, 'full'));
    dom.generateG2.addEventListener('click', (event) => generate(event, false, 'g2'));
    dom.terrainSeed.addEventListener('input', updateDirty);
    dom.randomSeed.addEventListener('click', randomTerrainSeed);
    dom.replay.addEventListener('click', (event) => generate(event, true, (state.selectedJob?.target) || 'full'));
    dom.retryJob.addEventListener('click', retryJob);
    dom.rebuildVisual.addEventListener('click', rebuildVisual);
    dom.reset.addEventListener('click', resetDefaults);
    dom.useSettings.addEventListener('click', loadSelectedSettings);
    dom.importConfig.addEventListener('change', importConfig);
    imageLayers.forEach((button) => button.addEventListener('click', () => updateLayer(button.dataset.layer)));
    dom.zoomIn.addEventListener('click', () => zoom(.2)); dom.zoomOut.addEventListener('click', () => zoom(-.2)); dom.fit.addEventListener('click', resetTransform);
    dom.viewport.addEventListener('wheel', (event) => { if (!dom.mapImage.hidden) { event.preventDefault(); zoom(event.deltaY < 0 ? .15 : -.15); } }, { passive: false });
    dom.viewport.addEventListener('pointerdown', (event) => {
      if (dom.mapImage.hidden) return;
      state.drag = { id: event.pointerId, x: event.clientX, y: event.clientY, originX: state.transform.x, originY: state.transform.y };
      dom.viewport.setPointerCapture(event.pointerId);
    });
    dom.viewport.addEventListener('pointermove', (event) => {
      if (!state.drag || state.drag.id !== event.pointerId) return;
      state.transform.x = state.drag.originX + event.clientX - state.drag.x;
      state.transform.y = state.drag.originY + event.clientY - state.drag.y;
      applyTransform();
    });
    const endDrag = (event) => {
      if (state.drag?.id === event.pointerId) state.drag = null;
    };
    dom.viewport.addEventListener('pointerup', endDrag); dom.viewport.addEventListener('pointercancel', endDrag);
    dom.viewport.addEventListener('keydown', (event) => {
      if (event.key === '+' || event.key === '=') { event.preventDefault(); zoom(.2); }
      if (event.key === '-') { event.preventDefault(); zoom(-.2); }
      if (event.key === '0') { event.preventDefault(); resetTransform(); }
    });
    window.addEventListener('beforeunload', () => stopPolling());
  }

  async function initialize() {
    try {
      const boot = await request('/api/bootstrap');
      state.boot = boot; state.jobs = boot.jobs || []; state.activeId = boot.active || null;
      dom.version.textContent = `G2 ${boot.version} · 流水线 ${boot.pipeline_version || ''}`.trim();
      renderControls(); renderChoices(); bindInteractions(); clearDownloads();
      const completed = state.jobs.find((job) => job.status === 'done');
      const selected = state.jobs.find((job) => job.id === state.activeId) || completed;
      if (selected) { selectJob(selected.id); }  // 仅展示，不回填参数（主按钮保持默认）
      else { renderHistory(); renderNoResult('生成后会显示实际指标与验收结果。'); }
      if (state.activeId) startPolling(state.activeId);
      updateDirty();
    } catch (error) {
      dom.dirty.textContent = error.message;
      dom.dirty.classList.add('invalid');
      setMapStatus('服务未连接', 'fail'); clearMap('无法连接工作台', '启动 serve_g2.py 后刷新此页面。');
      toast(error.message, 'error');
    }
  }

  initialize();
})();
