# -*- coding: utf-8 -*-
"""启动健壮性守门：整个包**不许出现「把标准库模块名当模块用、却没 import 它」**。

## 为什么必须有这条（2026-09-15 实测事故）

`deploy/agent_runner.py` 在"收尾时把 `command_timing` 合并进命令生命周期表"的函数里调用了
`io.open(...)`，但文件头**没有 `import io`** ⇒ runner **启动阶段就抛
`NameError("name 'io' is not defined")` 并退出**；面板上只剩「副官尚未启动」，
失败是**静默的**（只有 `runner.err` 里一行），玩家完全看不出原因。

这类错误 `py_compile` / `compileall` **抓不到**（语法合法，只在运行时炸），
所以必须用 AST 做静态检查。本用例遍历 `adjutant_coordinator` 全部模块，
找出"`mod.xxx` 形式使用标准库模块名、但既没 import 也没本地定义"的地方，
一旦有人再犯，**测试立刻失败并指名文件**。

（只覆盖标准库常见模块名：这些正是"忘了 import 也照样编译通过"的高危项。
第三方/自有模块漏 import 通常会表现为 ImportError，编译或首次引用即暴露。）
"""

import ast
import io
import pathlib
import unittest

PACKAGE_ROOT = pathlib.Path(__file__).resolve().parent.parent

#: 高危标准库模块名：忘了 import 也**不会**影响编译，只在运行时炸。
STDLIB_MODULE_NAMES = frozenset({
    "io", "os", "sys", "json", "re", "time", "math", "random", "threading",
    "subprocess", "shutil", "pathlib", "collections", "itertools", "datetime",
    "uuid", "socket", "signal", "argparse", "typing", "traceback", "logging",
    "copy", "functools", "hashlib", "tempfile", "zipfile", "asyncio", "queue",
    "secrets", "urllib", "glob", "codecs", "statistics", "decimal", "csv",
})


def _imported_names(tree: ast.AST) -> set:
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add((alias.asname or alias.name).split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names:
                names.add(alias.asname or alias.name)
    return names


def _defined_names(tree: ast.AST) -> set:
    """模块内自定义的名字（函数/类/赋值/参数/except 别名）——它们不依赖 import。"""
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            names.add(node.id)
        elif isinstance(node, ast.arg):
            names.add(node.arg)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            names.add(node.name)
    return names


def _module_attribute_roots(tree: ast.AST) -> set:
    """`mod.xxx` 形态里被当作模块用的根名字。"""
    roots = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            roots.add(node.value.id)
    return roots


class StartupImportSanityTest(unittest.TestCase):
    def test_no_stdlib_module_used_without_import(self):
        offenders = []
        for path in sorted(PACKAGE_ROOT.rglob("*.py")):
            if "__pycache__" in str(path):
                continue
            source = io.open(path, encoding="utf-8", errors="replace").read()
            try:
                tree = ast.parse(source)
            except SyntaxError as exc:  # 语法错误也要点名（否则运行时才炸）
                offenders.append("%s: 语法错误 %s" % (path.name, exc))
                continue
            missing = sorted(
                (_module_attribute_roots(tree) & STDLIB_MODULE_NAMES)
                - _imported_names(tree)
                - _defined_names(tree)
            )
            if missing:
                offenders.append("%s: 缺 import %s" % (path.name, missing))
        self.assertEqual(
            offenders, [],
            "以下模块把标准库模块名当模块用但没有 import（启动时会 NameError 静默退出）：\n  "
            + "\n  ".join(offenders))
