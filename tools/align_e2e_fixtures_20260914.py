# -*- coding: utf-8 -*-
"""把**主表新增的定义**对齐进 e2e 夹具（`config/{balance,godot}/adjutant-e2e.*`）。

为什么要它：`tests/test_e2e_fixture.py` 是守门测试 —— 主表（`demo.balance.v1.json` /
`demo.assets.v1.json`）新增定义而 e2e 夹具没同步时，E2E 会**静默降级**（Catalog 缺定义），
表现成"副官功能坏了"。合并 origin/yyp_test 后上游一次加了 7 个定义，于是这条守门红灯。

做法：**逐段（section）按 id 取差集**，把主表里缺失条目的**原文块**（含其缩进风格）
抄进夹具的同一段；不改夹具里已有的任何条目（夹具的覆盖值是有意的，不许被主表覆盖）。
"""
import io
import json
import re
import sys

PROJECT = r"G:\AIRTS\AI_RTS"
TARGETS = (
    (r"config\balance\demo.balance.v1.json", r"config\balance\adjutant-e2e.balance.v1.json",
     (("unitTypes", "id"), ("weapons", "id"), ("warheads", "id"),
      ("constructions", "id"), ("productions", "id"))),
    (r"config\godot\demo.assets.v1.json", r"config\godot\adjutant-e2e.assets.v1.json",
     (("unitAssets", "unitTypeId"), ("weaponAssets", "weaponId"))),
)


def section_span(text, section):
    """返回 (数组起始下标, 数组结束下标（指向 ']'）, 块列表)。"""
    match = re.search(r'"%s"\s*:\s*\[' % re.escape(section), text)
    if not match:
        return None
    start = match.end() - 1
    depth = 0
    index = start
    while index < len(text):
        char = text[index]
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                break
        index += 1
    inner = text[start + 1:index]
    blocks = []
    depth = 0
    block_start = None
    in_string = False
    escape = False
    for offset, char in enumerate(inner):
        if in_string:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            if depth == 0:
                # 连同**行首空白**一起抓：否则块内后续行的缩进基准无从得知，
                # 抄进夹具时会双重缩进（JSON 还能解析，但 diff 会被格式噪音淹没）。
                line_start = inner.rfind("\n", 0, offset) + 1
                block_start = line_start if inner[line_start:offset].strip() == "" else offset
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0 and block_start is not None:
                blocks.append(inner[block_start:offset + 1])
                block_start = None
    return start, index, blocks


def key_of(block, id_key):
    match = re.search(r'"%s"\s*:\s*"([^"]+)"' % re.escape(id_key), block)
    return match.group(1) if match else ""


def indent_of(block):
    first = block.splitlines()[0]
    return first[:len(first) - len(first.lstrip())]


def align(main_path, fixture_path, sections):
    main_text = io.open(main_path, encoding="utf-8").read()
    fixture_text = io.open(fixture_path, encoding="utf-8").read()
    added = {}
    for section, id_key in sections:
        main_span = section_span(main_text, section)
        fixture_span = section_span(fixture_text, section)
        if not main_span or not fixture_span:
            continue
        have = {key_of(block, id_key) for block in fixture_span[2]}
        want = [(key_of(block, id_key), block) for block in main_span[2]]
        missing = [(key, block) for key, block in want if key and key not in have]
        if not missing:
            continue
        # 目标缩进：跟夹具里已有条目的缩进保持一致；没有条目就用主表条目的缩进。
        block_indent = indent_of(fixture_span[2][0]) if fixture_span[2] else indent_of(missing[0][1])
        close_indent = block_indent[:-1] if len(block_indent) > 0 else ""
        new_blocks = list(fixture_span[2]) + [reindent(block, block_indent[1:])
                                             for _key, block in missing]
        body = "[\n" + ",\n".join(new_blocks) + "\n" + close_indent + "]"
        fixture_text = fixture_text[:fixture_span[0]] + body + fixture_text[fixture_span[1] + 1:]
        added[section] = [key for key, _block in missing]
        # 重新读取（下标已变）
        fixture_span = section_span(fixture_text, section)
    io.open(fixture_path, "w", encoding="utf-8", newline="\n").write(fixture_text)
    data = json.loads(fixture_text)          # 语法自检：写坏了立刻炸，不留半成品
    return {"fixture": fixture_path.split(PROJECT)[-1], "added": added,
            "sections": {section: len(section_span(fixture_text, section)[2])
                         for section, _key in sections}}


def reindent(block, indent):
    """把主表里的条目块**按目标缩进**抄写（去自己的基准缩进，再加目标的）。"""
    lines = block.splitlines()
    base = indent_of(block)
    out = []
    for line in lines:
        out.append(indent + line[len(base):] if line.startswith(base) else line)
    return "\n".join(out)


report = []
for main_rel, fixture_rel, sections in TARGETS:
    report.append(align(PROJECT + "\\" + main_rel, PROJECT + "\\" + fixture_rel, sections))
print(json.dumps(report, ensure_ascii=False, indent=1))
sys.exit(0)
