# -*- coding: utf-8 -*-
"""DCS 回执口径守卫：网关结果的"成功/原因"判据**只允许有一处实现**。

2026-09-12 真机教训：`_construct_on_existing_site` 自己手写 `result.get("accepted", false)`，
而 `gateway.ConstructUnits()` 返回的是 `CommandResult`（`{command_id, status, unit_results[]}`），
**没有顶层 `accepted` 字段** → 每一条"续建"都被回报成 `Rejected` + 空原因：

- 同局 5 分钟里 30 条 `rule-finish-site` 全部如此，占该局全部命令的 **26%**；
- 协调器拿不到原因 → 归不进任何类别 → 不退避 → 一遍遍重发同一条命令；
- 一并污染里程碑判定（"命令连续被拒"→ 扩张/分基地被判走不通）。

同一份日志里其实写着真相：外层 `status=Rejected / reason=""`，内层
`result.status="Accepted"`、`unit_results[0].accepted=true` —— 工人早就接到命令了。

本守卫钉死：**凡直接调用网关命令方法的返回值，必须经 `_unified_receipt()` 归一化**。
"""

import io
import os
import re
import unittest

_VENDOR_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_ROOT = os.path.abspath(os.path.join(_VENDOR_DIR, "..", "..", ".."))
DCS_PATH = os.path.join(SOURCE_ROOT, "source", "net", "DebugControlServer.gd")

#: 网关命令方法赋值：`var result: Dictionary = gateway.ConstructUnits(...)`。
GATEWAY_ASSIGN_RE = re.compile(
    r"var\s+(\w+)\s*(?::\s*[A-Za-z_][\w\[\]]*\s*)?=\s*gateway\.[A-Z]\w*\(")
#: 手写判据的特征（应当只出现在 `_unified_receipt` 内部）。
HAND_ROLLED_RE = re.compile(r'get\(\s*"accepted"')


def _strip_comments(text: str) -> str:
    """去掉 GDScript 行注释（注释里写反例说明不算违规代码）。"""
    out = []
    for line in text.splitlines():
        cut = -1
        quote = ""
        for index, char in enumerate(line):
            if quote:
                if char == quote:
                    quote = ""
                continue
            if char in "\"'":
                quote = char
            elif char == "#":
                cut = index
                break
        out.append(line[:cut] if cut >= 0 else line)
    return "\n".join(out)


def _read() -> str:
    with io.open(DCS_PATH, encoding="utf-8") as handle:
        return _strip_comments(handle.read())


def _functions(text: str):
    """切出顶层函数 → [(名字, 正文)]。"""
    parts = re.split(r"\nfunc ", text)
    for part in parts[1:]:
        name = part.split("(", 1)[0].strip()
        yield name, part


class GatewayReceiptContractTest(unittest.TestCase):
    def test_dcs_file_exists(self):
        self.assertTrue(os.path.exists(DCS_PATH), DCS_PATH)

    def test_gateway_results_go_through_unified_receipt(self):
        """凡是把网关命令结果存进变量的，都必须把这个变量交给 `_unified_receipt`。"""
        offenders = []
        for name, body in _functions(_read()):
            for variable in set(GATEWAY_ASSIGN_RE.findall(body)):
                if "_unified_receipt(%s" % variable not in body:
                    offenders.append("%s(%s)" % (name, variable))
        self.assertEqual(
            offenders, [],
            "这些网关结果没有走统一回执（CommandResult 没有顶层 accepted，自己判恒为 false）"
            "→ 必须改走 `_unified_receipt()`：%s" % offenders)

    def test_construct_routing_keeps_its_shape(self):
        body = dict(_functions(_read())).get("_construct_on_existing_site", "")
        self.assertTrue(body, "找不到 `_construct_on_existing_site`（改名了？同步更新本守卫）")
        self.assertIn("_unified_receipt(", body)
        self.assertNotIn('var accepted := bool(result.get("accepted", false))', body)

    def test_unified_receipt_derives_accepted_from_status_and_units(self):
        """`_unified_receipt` 必须同时看 `status` 与 `unit_results[].accepted`。"""
        body = dict(_functions(_read())).get("_unified_receipt", "")
        self.assertTrue(body)
        self.assertIn('get("status"', body)
        self.assertIn('get("unit_results"', body)
        self.assertIn('get("accepted"', body)


if __name__ == "__main__":
    unittest.main()
