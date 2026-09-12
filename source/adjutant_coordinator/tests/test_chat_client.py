import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
from adjutant_coordinator.chat_client import ChatCompletionsClient
from adjutant_coordinator.http_provider import HttpResponse


class Stub:
    def __init__(self, response):
        self.response = response

    def post_json(self, url, headers, payload, timeout):
        self.payload = payload
        return self.response


class ChatTests(unittest.TestCase):
    def test_adapter(self):
        stub = Stub(HttpResponse(200, json.dumps({"choices": [{
            "finish_reason": "stop", "message": {"content": '{"commands":[]}'}}],
            "usage": {"total_tokens": 20}})))
        client = ChatCompletionsClient("Return JSON", stub)
        result = client.post_json("https://example.invalid", {}, {"model": "x"}, 1)
        self.assertEqual(json.loads(result.body_text), {"commands": []})
        self.assertEqual(stub.payload["messages"][0]["role"], "system")
        self.assertEqual(client.calls[0]["usage"]["total_tokens"], 20)

    def test_truncated_output_rejected(self):
        stub = Stub(HttpResponse(200, json.dumps({"choices": [{
            "finish_reason": "length", "message": {"content": '{"commands":[]}'}}]})))
        self.assertEqual(ChatCompletionsClient("", stub).post_json(
            "", {}, {"model": "x"}, 1).status_code, 502)

    def test_http_failure_preserved(self):
        stub = Stub(HttpResponse(429, "rate limited"))
        self.assertEqual(ChatCompletionsClient("", stub).post_json(
            "", {}, {"model": "x"}, 1).status_code, 429)

    def test_low_reasoning_is_explicit(self):
        stub = Stub(HttpResponse(429, ''))
        ChatCompletionsClient('', stub, reasoning_effort='low').post_json('', {}, {'model':'x'}, 1)
        self.assertEqual(stub.payload['reasoning_effort'], 'low')
