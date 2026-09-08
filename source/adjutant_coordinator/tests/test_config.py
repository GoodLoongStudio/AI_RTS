# -*- coding: utf-8 -*-
"""Provider 配置测试：环境变量构造、凭证脱敏视图、Fake/HTTP 工厂切换。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.config import (
    MODE_FAKE, MODE_HTTP, ProviderSettings,
    create_strategy_provider, create_tactics_provider,
)
from adjutant_coordinator.fakes import (
    ScriptedStrategyProvider, ScriptedTacticsProvider,
)

KEY_ENV = "TEST_ADJUTANT_API_KEY_XYZ"


class TestProviderSettings(unittest.TestCase):

    def setUp(self):
        os.environ[KEY_ENV] = "super-secret-value-456"
        self.addCleanup(os.environ.pop, KEY_ENV, None)

    def test_from_env_reads_role_prefixed_config(self):
        os.environ["AI_ADJUTANT_STRATEGY_MODE"] = "http"
        os.environ["AI_ADJUTANT_STRATEGY_ENDPOINT"] = "https://gw.internal/plan"
        os.environ["AI_ADJUTANT_STRATEGY_MODEL"] = "strategy-model-1"
        self.addCleanup(os.environ.pop, "AI_ADJUTANT_STRATEGY_MODE", None)
        self.addCleanup(os.environ.pop, "AI_ADJUTANT_STRATEGY_ENDPOINT", None)
        self.addCleanup(os.environ.pop, "AI_ADJUTANT_STRATEGY_MODEL", None)
        settings = ProviderSettings.from_env("strategy")
        self.assertEqual(settings.mode, MODE_HTTP)
        self.assertEqual(settings.endpoint, "https://gw.internal/plan")
        self.assertEqual(settings.model, "strategy-model-1")
        self.assertEqual(settings.role, "strategy")

    def test_invalid_mode_falls_back_to_fake(self):
        os.environ["AI_ADJUTANT_TACTICS_MODE"] = "quantum"
        self.addCleanup(os.environ.pop, "AI_ADJUTANT_TACTICS_MODE", None)
        settings = ProviderSettings.from_env("tactics")
        self.assertEqual(settings.mode, MODE_FAKE)

    def test_safe_dict_masks_credentials(self):
        settings = ProviderSettings(mode=MODE_HTTP, role="strategy",
                                    endpoint="https://gw.internal",
                                    api_key_env=KEY_ENV)
        safe = settings.safe_dict()
        self.assertEqual(safe["api_key"], "***redacted***")
        self.assertNotIn("super-secret-value-456", str(safe))
        # 正文字段保持可诊断。
        self.assertEqual(safe["endpoint"], "https://gw.internal")
        self.assertEqual(safe["api_key_env"], KEY_ENV)

    def test_resolve_api_key_reads_env_at_call_time(self):
        settings = ProviderSettings(api_key_env=KEY_ENV)
        self.assertEqual(settings.resolve_api_key(), "super-secret-value-456")
        settings_missing = ProviderSettings(api_key_env="TEST_ENV_NEVER_SET_9527")
        self.assertEqual(settings_missing.resolve_api_key(), "")


class TestFactory(unittest.TestCase):

    def test_fake_mode_returns_injected_fake_provider(self):
        fake = ScriptedStrategyProvider([])
        settings = ProviderSettings(mode=MODE_FAKE, role="strategy")
        provider = create_strategy_provider(settings, fake_provider=fake)
        self.assertIs(provider, fake)

    def test_fake_mode_tactics_default(self):
        settings = ProviderSettings(mode=MODE_FAKE, role="tactics")
        provider = create_tactics_provider(settings)
        self.assertIsInstance(provider, ScriptedTacticsProvider)

    def test_http_mode_builds_http_provider(self):
        from adjutant_coordinator.http_provider import HttpModelProvider
        settings = ProviderSettings(mode=MODE_HTTP, role="strategy")
        provider = create_strategy_provider(settings, http_client=object())
        self.assertIsInstance(provider, HttpModelProvider)


if __name__ == "__main__":
    unittest.main()
