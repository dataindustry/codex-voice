from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from codex_voice.config_cli import classify_ollama_model, list_loaded_ollama_models
from codex_voice.correction import (
    apply_rule_corrections,
    looks_like_aggressive_rewrite,
    should_skip_ollama_correction,
    strip_thinking,
)
from codex_voice.ollama import ollama_base_url, ollama_chat_url, ollama_num_ctx


def test_rule_corrections_replace_common_misrecognitions() -> None:
    text = apply_rule_corrections(
        "打开麦cp并运行派普恩皮埃姆",
        {"common_misrecognitions": {"麦cp": "MCP", "派普恩皮埃姆": "pnpm"}},
    )

    assert text == "打开MCP并运行pnpm"


def test_short_utterance_skips_ollama_in_normal_mode() -> None:
    assert should_skip_ollama_correction("继续", "normal", {"ollama_simple_max_chars": 8})
    assert not should_skip_ollama_correction("继续", "strict", {"ollama_simple_max_chars": 8})


def test_aggressive_rewrite_detection() -> None:
    original = "请把这个 Python 脚本里的快捷键触发逻辑重构一下"
    corrected = "This is a completely different English paragraph with unrelated content."

    assert looks_like_aggressive_rewrite(original, corrected, "normal", {})


def test_strip_thinking_removes_think_blocks() -> None:
    assert strip_thinking("<think>hidden</think>最终文本") == "最终文本"


def test_ollama_urls_prefer_explicit_non_default_config(monkeypatch) -> None:
    monkeypatch.delenv("OLLAMA_HOST", raising=False)
    monkeypatch.setattr("codex_voice.ollama.launchctl_getenv", lambda _name: "")
    config = {"ollama_base_url": "http://127.0.0.1:11435", "ollama_num_ctx": "4000"}

    assert ollama_base_url(config) == "http://127.0.0.1:11435"
    assert ollama_chat_url(config) == "http://127.0.0.1:11435/api/chat"
    assert ollama_num_ctx(config) == 4000


def test_ollama_urls_prefer_environment_over_config(monkeypatch) -> None:
    monkeypatch.setenv("OLLAMA_HOST", "127.0.0.1:11435")

    config = {
        "ollama_base_url": "http://127.0.0.1:11436",
        "ollama_url": "http://127.0.0.1:11436/api/chat",
    }

    assert ollama_base_url(config) == "http://127.0.0.1:11435"
    assert ollama_chat_url(config) == "http://127.0.0.1:11435/api/chat"


def test_configured_qwen_is_correction_candidate_when_show_has_no_capabilities(
    monkeypatch,
) -> None:
    monkeypatch.setattr("codex_voice.config_cli.ollama_post_json", lambda *_args, **_kwargs: {})

    model = classify_ollama_model(
        {"ollama_model": "qwen3.6:35b-a3b"},
        {"name": "qwen3.6:35b-a3b", "details": {}},
    )

    assert model["correction_candidate"] is True


class FakeOllamaHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/api/ps":
            body = {"models": [{"name": "qwen3.6:35b-a3b"}]}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(body).encode("utf-8"))
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        return


def test_list_loaded_ollama_models_uses_api_ps(capsys) -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllamaHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host = str(server.server_address[0])
        port = int(server.server_address[1])
        list_loaded_ollama_models({"ollama_base_url": f"http://{host}:{port}"})
        payload = json.loads(capsys.readouterr().out)
        assert payload["available"] is True
        assert payload["models"] == ["qwen3.6:35b-a3b"]
    finally:
        server.shutdown()
