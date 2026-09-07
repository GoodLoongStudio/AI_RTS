# -*- coding: utf-8 -*-
"""HTTP Provider 归一化测试：正常/超时/取消/空/非法 JSON/未知状态/HTTP 错误/脱敏。

全部使用脚本假 HTTP 客户端；本文件不发起任何真实网络请求。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.config import ProviderSettings
from adjutant_coordinator.http_provider import HttpResponse, HttpModelProvider
from adjutant_coordinator.provider import (
    ModelCallContext, OUTCOME_CANCELLED, OUTCOME_COMPLETED, OUTCOME_ERROR,
    OUTCOME_REJECTED, OUTCOME_TIMEOUT, ROLE_STRATEGY, ROLE_TACTICS,
)
from adjutant_coordinator.redaction import redact_headers
from adjutant_coordinator.structured_log import MemorySink, StructuredLogger

KEY_ENV = "TEST_HTTP_PROVIDER_KEY"
SECRET = "bearer-secret-do-not-leak-789"


class ScriptedHttpClient:
    """脚本化假客户端：按序返回 (status, body) 或抛异常。"""

    def __init__(self, script):
        self.script = list(script)
        self.calls = []

    def post_json(self, url, headers, payload, timeout_seconds):
        self.calls.append({"url": url, "headers": dict(headers),
                           "payload": dict(payload), "timeout": timeout_seconds})
        step = self.script.pop(0) if self.script else (200, "{}")
        if isinstance(step, Exception):
            raise step
        status, body = step
        from adjutant_coordinator.http_provider import HttpResponse
        return HttpResponse(status_code=status, body_text=body)


def make_context(cancelled=False, role=ROLE_STRATEGY):
    return ModelCallContext(
        request_id="req-1", role=role, match_id="m-1", player_id="Player_1",
        rules_version="hash-1", plan_version="plan-a:v1", snapshot_id=2,
        server_tick=100, issued_tick=100, deadline_tick=250,
        budget={"A": 500}, observation={"units": 4},
        is_cancelled=(lambda: cancelled) if cancelled is not None else None,
    )


def make_provider(script, role=ROLE_STRATEGY, sink=None):
    os.environ[KEY_ENV] = SECRET
    settings = ProviderSettings(
        mode="http", role=role, endpoint="https://gw.internal/v1",
        model="test-model", api_key_env=KEY_ENV, timeout_seconds=3.0)
    logger = StructuredLogger(sink, base={"match_id": "m-1", "player_id": "Player_1"}) \
        if sink is not None else None
    provider = HttpModelProvider(settings=settings,
                                 http_client=ScriptedHttpClient(script),
                                 logger=logger)
    return provider


class ProviderTestBase(unittest.TestCase):

    def setUp(self):
        os.environ[KEY_ENV] = SECRET
        self.addCleanup(os.environ.pop, KEY_ENV, None)


class TestNormalResponses(ProviderTestBase):

    def test_valid_plan_response(self):
        provider = make_provider(
            [(200, '{"status":"ok","plan":{"plan_id":"p1","plan_version":1}}')])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertEqual(outcome.payload["plan_id"], "p1")

    def test_valid_commands_response(self):
        provider = make_provider(
            [(200, '{"status":"ok","commands":[{"command_id":"c1"}]}')],
            role=ROLE_TACTICS)
        outcome = provider.propose(make_context(role=ROLE_TACTICS))
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertEqual(outcome.payload[0]["command_id"], "c1")

    def test_request_carries_context_and_auth_header(self):
        client = ScriptedHttpClient([(200, '{"plan":{}}')])
        os.environ[KEY_ENV] = SECRET
        settings = __import__("adjutant_coordinator.config", fromlist=["ProviderSettings"]).ProviderSettings(
            mode="http", role=ROLE_STRATEGY, endpoint="https://gw.internal/v1",
            model="test-model", api_key_env=KEY_ENV)
        provider = HttpModelProvider(settings=settings, http_client=client)
        provider.propose(make_context())
        call = client.calls[0]
        self.assertEqual(call["url"], "https://gw.internal/v1")
        self.assertEqual(call["headers"]["Authorization"], "Bearer " + SECRET)
        self.assertEqual(call["payload"]["request_id"], "req-1")
        self.assertEqual(call["payload"]["rules_version"], "hash-1")
        self.assertEqual(call["payload"]["observation"], {"units": 4})


class TestAbnormalResponses(ProviderTestBase):

    def test_timeout_normalized(self):
        provider = make_provider([TimeoutError("upstream slow")])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_TIMEOUT)
        self.assertIn("timeout", outcome.reason)

    def test_transport_exception_normalized_retryable(self):
        provider = make_provider([ConnectionError("reset")])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertTrue(outcome.retryable)

    def test_empty_body_normalized(self):
        provider = make_provider([(200, "")])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertIn("empty", outcome.reason)

    def test_invalid_json_normalized(self):
        provider = make_provider([(200, "<<<not json>>>")])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertIn("invalid json", outcome.reason)

    def test_non_object_json_normalized(self):
        provider = make_provider([(200, "[1,2,3]")])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertIn("not an object", outcome.reason)

    def test_unknown_status_normalized_as_rejected(self):
        provider = make_provider([(200, '{"status":"quantum-sync"}')])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_REJECTED)
        self.assertIn("unknown response status", outcome.reason)

    def test_api_error_field_normalized_as_rejected(self):
        provider = make_provider([(200, '{"error":"quota exceeded"}')])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_REJECTED)
        self.assertIn("quota", outcome.reason)

    def test_http_400_normalized(self):
        provider = make_provider([(400, '{"error":"bad request"}')])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertIn("400", outcome.reason)

    def test_http_500_normalized(self):
        provider = make_provider([(500, "server exploded")])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertIn("500", outcome.reason)

    def test_missing_plan_object_normalized(self):
        provider = make_provider([(200, '{"status":"ok","something":1}')])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertIn("plan", outcome.reason)

    def test_empty_object_is_empty_response_not_error(self):
        provider = make_provider([(200, '{}')])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertIsNone(outcome.payload)


class TestCancellation(ProviderTestBase):

    def test_cancelled_before_request_sends_nothing(self):
        client = ScriptedHttpClient([(200, '{"plan":{}}')])
        os.environ[KEY_ENV] = SECRET
        settings = __import__("adjutant_coordinator.config", fromlist=["ProviderSettings"]).ProviderSettings(
            mode="http", role=ROLE_STRATEGY, endpoint="https://gw.internal",
            api_key_env=KEY_ENV)
        provider = HttpModelProvider(settings=settings, http_client=client)
        outcome = provider.propose(make_context(cancelled=True))
        self.assertEqual(outcome.status, OUTCOME_CANCELLED)
        self.assertEqual(client.calls, [])

    def test_cancelled_after_response_wins(self):
        client = ScriptedHttpClient([(200, '{"plan":{"plan_id":"late-accepted"}}')])

        class FlipAfterCall:
            def __init__(self):
                self.flag = False

            def __call__(self):
                return self.flag
        cancelled = FlipAfterCall()

        def post(*args, **kwargs):
            cancelled.flag = True  # 响应到达瞬间被取消
            return HttpResponse_stub
        from adjutant_coordinator.http_provider import HttpResponse
        HttpResponse_stub = HttpResponse(status_code=200, body_text='{"plan":{}}')

        class Client:
            def post_json(self, url, headers, payload, timeout_seconds):
                return post()
        os.environ[KEY_ENV] = SECRET
        settings = __import__("adjutant_coordinator.config", fromlist=["ProviderSettings"]).ProviderSettings(
            mode="http", role=ROLE_STRATEGY, endpoint="https://gw.internal",
            api_key_env=KEY_ENV)
        provider = HttpModelProvider(settings=settings, http_client=Client())
        outcome = provider.propose(
            make_context().__class__(**{**make_context().__dict__,
                                        "is_cancelled": cancelled}))
        self.assertEqual(outcome.status, OUTCOME_CANCELLED)


class TestMissingCredential(ProviderTestBase):

    def test_missing_api_key_is_error_without_request(self):
        os.environ.pop(KEY_ENV, None)
        client = ScriptedHttpClient([(200, '{"plan":{}}')])
        settings = __import__("adjutant_coordinator.config", fromlist=["ProviderSettings"]).ProviderSettings(
            mode="http", role=ROLE_STRATEGY, endpoint="https://gw.internal",
            api_key_env=KEY_ENV)
        provider = HttpModelProvider(settings=settings, http_client=client)
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertIn("api key missing", outcome.reason)
        self.assertFalse(outcome.retryable)  # 配置错误不重试风暴
        self.assertEqual(client.calls, [])


class TestCredentialRedaction(ProviderTestBase):

    def test_logs_never_contain_secret(self):
        sink = MemorySink()
        # HTTP 400 + 响应体里塞入凭证本身：日志必须脱敏。
        provider = make_provider([(400, 'oops %s leaked' % SECRET)], sink=sink)
        provider.propose(make_context())
        serialized = str([e for e in sink.entries])
        self.assertNotIn(SECRET, serialized)
        self.assertIn("***redacted***", serialized)

    def test_request_log_headers_are_masked(self):
        sink = MemorySink()
        provider = make_provider([(200, '{"plan":{}}')], sink=sink)
        provider.propose(make_context())
        request_entries = sink.find("provider_request")
        self.assertEqual(len(request_entries), 1)
        masked = request_entries[0]["headers"]
        self.assertEqual(masked["Authorization"], "***redacted***")
        self.assertNotIn(SECRET, str(masked))

    def test_redact_headers_utility(self):
        masked = redact_headers({"Authorization": "Bearer x",
                                 "X-Api-Key": "k",
                                 "Content-Type": "application/json"})
        self.assertEqual(masked["Authorization"], "***redacted***")
        self.assertEqual(masked["X-Api-Key"], "***redacted***")
        self.assertEqual(masked["Content-Type"], "application/json")


if __name__ == "__main__":
    unittest.main()
