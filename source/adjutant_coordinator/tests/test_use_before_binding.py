# -*- coding: utf-8 -*-
"""**"先用后绑"守门**：函数里"用到一个名字、但它的第一次赋值在更下面" = 运行时
`UnboundLocalError`（会被上层 `except` 吞掉，变成"每轮少记一条事实"这类静默故障）。

## 为什么要有这条测试（2026-09-13 两次血泪，同一类错）
- `agent_runner` 的扫描埋点引用了不存在的 `scan_stats` → **186/186 轮**都 `tick_error`，
  同轮后面的留档/决策/HUD/回执**全部被跳过**（`scan_hz=0`）；
- `_archive_round` 的 `intents` 字段用了**下面才赋值**的 `live_intents` → 每轮
  `archive_error` → `rounds.jsonl`（每轮世界事实）**从来没落过盘**。
两处都不是逻辑错误，是"埋点顺手写错一个名字"，却让复盘证据整块消失。静态扫一遍很便宜。
"""
import ast
import io
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

SOURCE_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def _assigned_names(function: ast.AST):
    """该函数体内**自身**被绑定的名字 → 首次绑定的行号（不看嵌套函数内部）。"""
    bound = {}

    def note(name: str, lineno: int) -> None:
        if name and (name not in bound or lineno < bound[name]):
            bound[name] = lineno

    for node in ast.walk(function):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)) \
                and node is not function:
            # 嵌套函数自己的赋值不算外层（这里**不进入**它的体）
            continue
        if isinstance(node, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
            # 【必须按推导式自身的行号记账】`{f(key) for key in items}` 里，`f(key)` 出现在
            # `for key ...` **前面**（源码顺序）→ 按 target 的行号记会误报"先用后绑"
            # （实测第一版扫出 30+ 条这种假警报，全是推导式）。
            for generator in node.generators:
                for inner in ast.walk(generator.target):
                    if isinstance(inner, ast.Name):
                        note(inner.id, node.lineno)
        if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            note(node.id, node.lineno)
        elif isinstance(node, ast.arg):
            note(node.arg, node.lineno)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                note((alias.asname or alias.name).split(".")[0], node.lineno)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            note(node.name, node.lineno)
        elif isinstance(node, ast.Global) or isinstance(node, ast.Nonlocal):
            for name in node.names:
                note(name, node.lineno)
    return bound


def _loaded_names(function: ast.AST):
    """该函数体内被**读取**的名字及其行号（同样不进嵌套函数的体）。"""
    loads = []

    def walk(node: ast.AST, depth: int) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)) \
                    and depth >= 0:
                # 嵌套函数：它自己的 Load 由它自己负责（各自会被单独扫描）。
                continue
            if isinstance(child, ast.Name) and isinstance(child.ctx, ast.Load):
                loads.append((child.id, child.lineno))
            walk(child, depth + 1)

    walk(function, 0)
    return loads


def scan_module(path: str):
    """返回 [(函数名, 名字, 使用行, 首次绑定行)] —— 只报"使用行 < 首次绑定行"的情况。"""
    with io.open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    tree = ast.parse(text, filename=path)
    module_level = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            module_level.add(node.name)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                module_level.add((alias.asname or alias.name).split(".")[0])
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    module_level.add(target.id)
    import builtins
    known = module_level | set(dir(builtins))

    findings = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        bound = _assigned_names(node)
        for name, lineno in _loaded_names(node):
            if name in bound:
                first = bound[name]
                if lineno < first:
                    findings.append((node.name, name, lineno, first))
            # 未在本函数绑定的名字交给模块级/内置判断（否则会误报全局函数与导入）
    return findings, known


class UseBeforeBindingTest(unittest.TestCase):
    def test_scanner_detects_the_known_bug_shape(self):
        """扫描器自证：能抓到"下面才赋值、上面就用"的写法。"""
        import tempfile
        source = (
            "def f():\n"
            "    print(later)\n"
            "    later = 1\n")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "sample.py")
            with io.open(path, "w", encoding="utf-8") as handle:
                handle.write(source)
            findings, _ = scan_module(path)
        self.assertEqual([(item[0], item[1]) for item in findings], [("f", "later")])

    def test_no_use_before_binding_in_coordinator(self):
        """真·守门：副官全部模块里不许存在"先用后绑"。"""
        offenders = []
        for base, _dirs, files in os.walk(SOURCE_ROOT):
            if os.path.basename(base) in ("tests", "logs", "__pycache__"):
                continue
            for name in files:
                if not name.endswith(".py"):
                    continue
                path = os.path.join(base, name)
                try:
                    findings, known = scan_module(path)
                except SyntaxError as exc:  # 语法问题由别的测试/解释器负责
                    offenders.append("%s: SyntaxError %s" % (name, exc))
                    continue
                for function, var, used, first in findings:
                    offenders.append("%s::%s 用了 %s（第 %d 行）但第 %d 行才赋值"
                                     % (os.path.relpath(path, SOURCE_ROOT), function,
                                        var, used, first))
        self.assertEqual(offenders, [],
                         "存在『先用后绑』（运行时 UnboundLocalError，会被 except 吞成静默故障）：\n  "
                         + "\n  ".join(offenders))


if __name__ == "__main__":
    unittest.main()
