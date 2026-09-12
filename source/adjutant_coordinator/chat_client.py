"""Adapt the existing provider gateway contract to Chat Completions."""
import json

from .http_provider import HttpResponse, UrllibHttpClient


class ChatCompletionsClient:
    def __init__(self, instruction, client=None, max_tokens=4096, reasoning_effort=None):
        self.instruction = instruction
        self.client = client or UrllibHttpClient()
        self.max_tokens = max_tokens
        if reasoning_effort not in (None, 'low', 'medium', 'high'):
            raise ValueError('invalid reasoning effort')
        self.reasoning_effort = reasoning_effort
        self.calls = []

    def post_json(self, url, headers, payload, timeout_seconds):
        request = {
            "model": payload["model"],
            "messages": [
                {"role": "system", "content": self.instruction},
                {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
            ],
            "max_tokens": self.max_tokens,
            "temperature": 0.2,
            "response_format": {"type": "json_object"},
        }
        if self.reasoning_effort:
            request['reasoning_effort'] = self.reasoning_effort
        response = self.client.post_json(url, headers, request, timeout_seconds)
        if response.status_code != 200:
            return response
        try:
            body = json.loads(response.body_text)
            choice = body["choices"][0]
            self.calls.append({"usage": body.get("usage"),
                               "finish_reason": choice.get("finish_reason"),
                               "content_characters": len(choice.get("message", {}).get("content") or '')})
            if choice.get("finish_reason") != "stop":
                raise ValueError("incomplete model output")
            content = choice["message"]["content"]
            if not isinstance(json.loads(content), dict):
                raise ValueError("model output must be an object")
            return HttpResponse(200, content)
        except (ValueError, KeyError, IndexError, TypeError):
            return HttpResponse(502, '{"error":"invalid chat completion"}')
