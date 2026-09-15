"""把工作台任务同步到离线、按任务隔离的 review 索引（review/index.html + review/G1–G4）。

接入生成/重试/视觉重建/交付流程：server 在任务达到稳定状态后调用 sync_jobs([job_id])。
设计（04-review目录同步交付.md）：
- 同一行 = 同一任务 + 当前版本；失败也更新并显示失败项，绝不用旧成功图冒充新结果。
- G4 按 visual_version 版本化：视觉重建产出新版本子目录，保留旧版本作前后对照，
  不覆盖同任务的历史证据。
- 索引合并既有记录：只重渲本次任务，其余任务沿用已同步图像，避免每次全量重跑。
- 未生成的阶段写“未生成”；验收视图只呈现当前有效的工作台任务。
"""
import datetime as dt
import html
import json
import re
import shutil
from pathlib import Path

from ..viz.review import build_g1_review

GATES = ["G1", "G2", "G3", "G4"]
_STAGE_KEY = {"G1": "g1_input", "G2": "g2_terrain", "G3": "g3_content", "G4": "engine"}
# G4 机位展示顺序：正交俯视 → 45° 正交轴测（均为验收图）→ 透视斜视（仅观感）。
_VIEW_ORDER = {"ortho": 0, "iso45": 1, "oblique": 2}
_VIEW_CAPTION = {"ortho": "正交俯视（验收）", "iso45": "45° 正交轴测（验收）",
                 "oblique": "透视斜视（仅观感）"}


def _view_of(name):
    """从 `<map_id>_<view>.png` 取机位名；非标准命名返回 None。"""
    return Path(str(name)).stem.rsplit("_", 1)[-1] or None


def _shot_key(name):
    return (_VIEW_ORDER.get(_view_of(name), 50), str(name))


def _folder_name(rec):
    """任务目录可读名：标签_layoutX_terrainY_任务短ID。

    不用 32 位裸 job id 做目录名；短 ID 后缀保证同标签、同 seed 的重跑不互盖。
    """
    slug = re.sub(r"[^0-9A-Za-z_.-]+", "_", str(rec.get("label") or "job")).strip("_.-")
    return (f"{slug or 'job'}_layout{rec['seed']}_terrain{rec.get('terrain', 0)}"
            f"_{str(rec['job_id'])[:8]}")


def _now():
    return dt.datetime.now().isoformat(timespec="seconds")


def _read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default if default is not None else {}


def _job_record(folder):
    """从任务目录构造一条 review 记录（含失败项与视觉版本）。"""
    job = _read_json(folder / "job.json")
    if not job:
        return None
    seed = job["config"]["layout_seed"]
    nav = _read_json(folder / "nav_check.json")
    failed_paths = [f"{p.get('from')} → {p.get('to')}"
                    for p in nav.get("paths", []) if p.get("connected") is False]
    forbidden = nav.get("forbidden", [])
    failed_forbidden = [f"{f.get('name')}({f.get('kind')}) d={f.get('dist3d_m')}m"
                        for f in forbidden if f.get("pass") is False]
    smoke = _read_json(folder / "smoke" / "smoke_report.json")
    smoke_assertions = smoke.get("assertions", {}) if smoke else {}
    # 稳健判据：仅当前（修复后）nav_check.gd 会写 forbidden_checked；
    # 旧任务的 nav_check.json 无此字段 → 标为“历史快照（当前代码未复验）”，
    # 防止旧成功图冒充本轮修复后的新结果。
    reverified = ("forbidden_checked" in nav) if nav else False
    return dict(
        job_id=job["id"], seed=seed, terrain=job["config"].get("terrain_seed", 0),
        target=job.get("target", "full"), status=job.get("status"),
        title=job.get("title"), label=job.get("label"),
        map_pass=job.get("map_pass"), created_at=job.get("created_at"),
        reverified_with_current_code=reverified,
        visual_version=int(job.get("visual_version", 1) or 1),
        visual_profile=job.get("visual_profile")
        or job.get("stages", {}).get("g4_scene", {}).get("visual_profile") or "default",
        map_id=job.get("map_id"),
        checks_summary=job.get("checks_summary", {}),
        failed_paths=failed_paths, failed_forbidden=failed_forbidden,
        nav_all=nav.get("all_pass"), smoke_assertions=smoke_assertions,
        stages={},
    )


def _sync_one(job_id, root, review, output=None):
    """同步单个任务的 G1–G4 图像到 review/<gate>/workbench/<job_id>/，返回记录。"""
    folder = (output or (root / "workbench_output")) / job_id
    if not (folder / "job.json").exists():
        return None
    record = _job_record(folder)
    if record is None:
        return None
    tname = record["folder"] = _folder_name(record)
    job = _read_json(folder / "job.json")
    stages = job.get("stages", {})
    seed = record["seed"]
    # G1 未改时可复用原始数据重绘（源只读）；渲染到临时 staging 再复制。
    if (folder / "runs" / str(seed) / "G1" / "mapspec.json").exists():
        staging = root / "tmp_logs" / "review_render" / job_id
        build_g1_review(folder / "runs", staging, [seed])
    else:
        staging = folder / "review"
    cur_v = record["visual_version"]
    for gate in GATES:
        if gate == "G4":
            # G4 版本化：当前视觉版本 → v<cur>；历史归档版本 → v<N>（保留前后对照）。
            gdst = review / "G4" / "workbench" / tname
            vdirs = {}
            cur_dst = gdst / f"v{cur_v}"
            cur_dst.mkdir(parents=True, exist_ok=True)
            shots = sorted((folder / "shots").glob("*.png"), key=lambda p: _shot_key(p.name))
            for src in shots:
                shutil.copy2(src, cur_dst / src.name)
            vdirs[cur_v] = [p.name for p in shots]
            for arch in sorted((folder / "g4").glob("visual_v*")):
                try:
                    vn = int(arch.name.replace("visual_v", ""))
                except ValueError:
                    continue
                adst = gdst / f"v{vn}"
                adst.mkdir(parents=True, exist_ok=True)
                apng = sorted(arch.glob("*.png"), key=lambda p: _shot_key(p.name))
                for src in apng:
                    shutil.copy2(src, adst / src.name)
                if apng:
                    vdirs[vn] = [p.name for p in apng]
            for evidence in ("job.json", "nav_check.json"):
                if (folder / evidence).exists():
                    shutil.copy2(folder / evidence, gdst / evidence)
            if (folder / "smoke" / "smoke_report.json").exists():
                shutil.copy2(folder / "smoke" / "smoke_report.json", gdst / "smoke_report.json")
            images = [f"v{cur_v}/{n}" for n in vdirs.get(cur_v, [])]
            images.sort(key=_shot_key)
            sources_present = bool(images)
            history = sorted(v for v in vdirs if v != cur_v)
        else:
            dst = review / gate / "workbench" / tname
            dst.mkdir(parents=True, exist_ok=True)
            src_dir = (staging if gate == "G1" else folder / "review") / gate
            sources = sorted(src_dir.glob("*.png"), key=lambda p: _shot_key(p.name)) \
                if src_dir.exists() else []
            for src in sources:
                shutil.copy2(src, dst / src.name)
            images = [p.name for p in sources]
            sources_present = bool(sources)
            history = []
        stage = stages.get(_STAGE_KEY[gate], {})
        state = "未生成" if not sources_present else ("通过" if stage.get("pass") is True else "需检查")
        preview = next((p for p in images if "ortho" in p or "overview" in p),
                       images[0] if images else None)
        record["stages"][gate] = dict(state=state, images=images, preview=preview,
                                      version=stage.get("version"), history_versions=history)
        meta = dict(record, gate=gate, source_job=str(folder / "job.json"),
                    synced_at=_now(),
                    note="图像来自本任务权威数据/真实引擎输出；生成或导航通过不等于实战通过。")
        mdir = review / gate / "workbench" / tname
        mdir.mkdir(parents=True, exist_ok=True)
        (mdir / f"source_v{cur_v}.json" if gate == "G4" else mdir / "source.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    return record


def _rebuild_index(review, records):
    """从全部记录重建 index.html + workbench-index.json + 各阶段联系图。"""
    records = sorted(records, key=lambda r: r.get("created_at") or "", reverse=True)
    now = _now()
    page = [
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>地图分阶段验收</title>',
        '<style>body{font:16px system-ui;max-width:1600px;margin:30px auto;background:#f4f6f8;'
        'color:#202b38}table{width:100%;border-collapse:collapse}td,th{padding:12px;border:1px '
        'solid #ccd3da;vertical-align:top}img{max-width:100%;height:auto}a{color:#1766ac}'
        'small{overflow-wrap:anywhere}th{background:#dfe8f1}.fail{color:#b3261e;font-weight:600}'
        '.ok{color:#1b7f37}.warn{color:#9a6700}</style>',
        '<h1>地图分阶段验收 · G1–G4</h1>',
        f'<p>索引更新：{now}。点击图片看原图。<b>同一行 = 同一任务 + 当前版本</b>；'
        '失败如实标注，不用旧成功图冒充。已被重跑取代的历史快照与更早根目录产物移入 review_archive。</p>',
        '<p>生成/导航通过不等于实战通过；实战（4AI 对局采集/卡死）状态单列，未运行标 not_run。</p>',
        '<table><tr><th>任务 / 版本</th><th>G1 出生</th><th>G2 地形</th>'
        '<th>G3 资源</th><th>G4 引擎 + 实战</th></tr>',
    ]
    for rec in records:
        jid = rec["job_id"]
        tname = rec.get("folder") or _folder_name(rec)
        pass_cls = "ok" if rec.get("map_pass") else "fail"
        pass_txt = "地图检查通过" if rec.get("map_pass") else "地图需检查"
        if rec.get("reverified_with_current_code"):
            badge = '<span class="ok">✓ 本轮修复后重验</span>'
        else:
            badge = '<span class="warn">⚠ 历史快照·当前代码未复验</span>'
        label = rec.get("label") or ""
        label_html = f'<br><b>{html.escape(str(label))}</b>' if label else ""
        page.append(
            f'<tr><td>布局 {rec["seed"]} · 地貌 {rec["terrain"]}{label_html}<br>'
            f'<small>目录 {html.escape(tname)}</small><br><small>job {html.escape(jid)}</small><br>'
            f'视觉 v{rec.get("visual_version",1)} '
            f'({html.escape(str(rec.get("visual_profile","default")))})<br>'
            f'<span class="{pass_cls}">{pass_txt}</span><br>{badge}<br>'
            f'<small>{html.escape(str(rec.get("created_at")))}</small></td>')
        for gate in GATES:
            data = rec["stages"].get(gate, {})
            prefix = f'{gate}/workbench/{tname}'
            st = data.get("state", "未生成")
            cls = {"通过": "ok", "需检查": "fail", "未生成": "warn"}.get(st, "")
            page.append(f'<td><span class="{cls}">{st}</span>'
                        f'<br><small>版本 {html.escape(str(data.get("version")))}</small>')
            names = list(data.get("images", []))
            preview = data.get("preview")
            # 顶视与 45° 轴测都是 G4 验收图，必须同时内嵌可见，不能只给链接。
            inline = [preview] if preview else []
            if gate == "G4":
                inline += [n for n in names if _view_of(n) == "iso45" and n not in inline]
            shown = set()
            for name in inline:
                url = f'{prefix}/{name}'
                view = _view_of(name)
                cap = _VIEW_CAPTION.get(view, "预览")
                page.append(f'<br><a href="{url}"><img src="{url}" alt="{html.escape(cap)}"></a>'
                            f'<br><small>{html.escape(cap)} · {html.escape(str(name))}</small>')
                shown.add(name)
            for name in names:
                if name not in shown:
                    page.append(f'<br><a href="{prefix}/{name}">{html.escape(name)}</a>')
            for hv in data.get("history_versions", []):
                page.append(f'<br><small>历史视觉 v{hv}：'
                            f'<a href="{prefix}/v{hv}/">对照</a></small>')
            if gate == "G4":
                page.append(f'<br><a href="{prefix}/job.json">任务参数与状态</a>')
                if (review / prefix / "nav_check.json").exists():
                    page.append(f'<br><a href="{prefix}/nav_check.json">导航原始报告</a>')
                if rec.get("failed_paths"):
                    page.append('<p class="fail">未连通路径：'
                                + html.escape("；".join(rec["failed_paths"])) + "</p>")
                if rec.get("failed_forbidden"):
                    page.append('<p class="fail">禁止穿越失败（水/崖可走）：'
                                + html.escape("；".join(rec["failed_forbidden"])) + "</p>")
                sa = rec.get("smoke_assertions") or {}
                if sa:
                    items = "；".join(f'{k}={v.get("status")}' for k, v in sa.items())
                    cls2 = "ok" if all(v.get("status") == "pass" for v in sa.values()) else "fail"
                    page.append(f'<p class="{cls2}">实战断言：{html.escape(items)}</p>')
                else:
                    page.append('<p class="warn">实战（4AI 对局）：not_run</p>')
            page.append("</td>")
        page.append("</tr>")
    page.append("</table></html>")
    review.mkdir(exist_ok=True)
    (review / "index.html").write_text("\n".join(page), encoding="utf-8")
    (review / "workbench-index.json").write_text(
        json.dumps(dict(updated_at=now, jobs=records), indent=2, ensure_ascii=False),
        encoding="utf-8")
    _contact_sheets(review, records, now)
    return records


def _contact_sheets(review, records, now):
    try:
        from PIL import Image, ImageDraw
    except Exception:
        return
    # G4 验收需顶视与 45° 轴测两张联系图；其余阶段只有顶视预览。
    plans = {gate: [(None, "contact.png")] for gate in GATES}
    plans["G4"] = [("ortho", "contact.png"), ("iso45", "contact_iso45.png")]
    for gate in GATES:
        saved = []
        for view, fname in plans[gate]:
            sheets = []
            for rec in records:
                data = rec["stages"].get(gate, {})
                folder = rec.get("folder") or _folder_name(rec)
                if view is None:
                    name = data.get("preview")
                else:
                    name = next((n for n in data.get("images", [])
                                 if _view_of(n) == view), None)
                if not name:
                    continue
                p = review / gate / "workbench" / folder / name
                if p.exists():
                    sheets.append((rec, p))
            if not sheets:
                continue
            sheet = Image.new("RGB", (480 * len(sheets), 530), "white")
            draw = ImageDraw.Draw(sheet)
            for i, (rec, p) in enumerate(sheets):
                try:
                    with Image.open(p) as img:
                        img.thumbnail((480, 480))
                        sheet.paste(img.convert("RGB"), (i * 480, 35))
                except Exception:
                    draw.text((i * 480 + 8, 260), "(图不可读)", fill="red")
                draw.text((i * 480 + 8, 8),
                          f'{gate} | {(view or "ortho")} | layout {rec["seed"]} '
                          f'| v{rec.get("visual_version", 1)} '
                          f'| {rec.get("label") or str(rec["job_id"])[:12]}', fill="black")
            (review / gate / "workbench").mkdir(parents=True, exist_ok=True)
            sheet.save(review / gate / "workbench" / fname)
            saved.append(fname)
        if not saved:
            continue
        # CURRENT.md 在 review/<gate>/，联系图在 review/<gate>/workbench/，链接必须带子目录。
        links = " 或 ".join(f"[{_VIEW_CAPTION.get(v, v)}](workbench/{f})"
                            for v, f in plans[gate] if f in saved)
        (review / gate / "CURRENT.md").write_text(
            f'# {gate} 当前工作台验收\n\n更新时间：{now}。\n\n'
            f'查看 [四阶段总览](../index.html) 或 {links}。\n\n'
            '任务目录名为「标签_layoutX_terrainY_任务短ID」，完整 job id 在页内与 source.json。'
            'G4 按当前视觉版本分子目录。已被重跑取代的历史快照与更早的根目录产物已移入 '
            '../review_archive，如需对照可用 tools/sync_workbench_review.py 重新发布。'
            '实战仍待有效验证。\n', encoding="utf-8")


def sync_jobs(job_ids, root=None, output=None):
    """同步指定任务并合并重建索引（供 server 在任务稳定后调用；也供 CLI 使用）。

    output 可显式指定 workbench_output 目录（测试用临时输出时避免误定位）。
    """
    root = Path(root) if root else Path(__file__).resolve().parents[2]
    output = Path(output) if output else None
    review = root / "review"
    existing = _read_json(review / "workbench-index.json", {}).get("jobs", [])
    merged = {r["job_id"]: r for r in existing if isinstance(r, dict) and r.get("job_id")}
    for r in merged.values():
        r["folder"] = r.get("folder") or _folder_name(r)
    synced = []
    for job_id in job_ids:
        if not str(job_id).isalnum():
            raise ValueError("Expected an alphanumeric workbench job ID")
        rec = _sync_one(str(job_id), root, review, output)
        if rec is not None:
            merged[job_id] = rec
            synced.append(job_id)
    _rebuild_index(review, list(merged.values()))
    return synced
