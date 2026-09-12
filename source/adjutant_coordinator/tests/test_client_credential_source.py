# -*- coding: utf-8 -*-
"""客户端凭证链仓库级静态测试（第四阶段遗留修复）。

- 已作废旧 token 不得出现在任何 git tracked 文件中（防硬编码回归）；
- 客户端必须支持环境变量凭证来源（AI_ADJUTANT_TOKEN）。
"""
import os
import subprocess
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OLD_TOKEN = "AIRTS-ADJ-7c91f2x9"
BINARY_SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".fbx", ".glb", ".ogg", ".wav",
                   ".import", ".dll", ".pdb", ".exe")


class TestClientCredentialSource(unittest.TestCase):

    def _tracked_files(self):
        out = subprocess.run(
            ["git", "-C", REPO_ROOT, "ls-files"],
            capture_output=True, text=True).stdout.splitlines()
        return [line.replace("\\\\", "/") for line in out if line.strip()]

    def test_retired_token_absent_from_tracked_files(self):
        offenders = []
        for rel in self._tracked_files():
            lower = rel.lower()
            if lower.endswith(BINARY_SUFFIXES):
                continue
            path = os.path.join(REPO_ROOT, rel)
            if not os.path.isfile(path):
                continue
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    if OLD_TOKEN in handle.read():
                        offenders.append(rel)
            except OSError:
                continue
        self.assertEqual(offenders, [],
            "已作废旧 token 不得出现在任何 tracked 文件，发现于: %s" % offenders)

    def test_button_supports_env_credential_source(self):
        button_path = os.path.join(REPO_ROOT, "source", "ui", "AdjutantButton.gd")
        with open(button_path, "r", encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("AI_ADJUTANT_TOKEN", text,
            "客户端应支持环境变量 AI_ADJUTANT_TOKEN 凭证来源")
        self.assertIn("user://adjutant_credentials.cfg", text,
            "客户端应支持受保护用户配置凭证来源")
        self.assertNotIn("const TOKEN :=", text,
            "客户端不得再保留硬编码 TOKEN 常量")


if __name__ == "__main__":
    unittest.main()
