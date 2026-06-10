from __future__ import annotations

import threading
from pathlib import Path

import pytest

from codex_voice.model_client import ModelServiceError, request_model_service
from codex_voice.model_service import ModelRuntime, ModelServer
from codex_voice.paths import paths_for_root


def test_model_service_reports_loaded_models_and_shuts_down(tmp_path: Path) -> None:
    paths = paths_for_root(tmp_path)
    paths.ensure_dirs()
    runtime = ModelRuntime(paths)
    runtime.qwen_asr_sessions["qwen3-asr-1.7b-8bit"] = object()
    server = ModelServer(paths.model_service_socket_path, runtime)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        response = request_model_service(
            paths,
            {"action": "status"},
            timeout=1,
            start_if_needed=False,
        )
        assert response["loaded_model_ids"] == ["qwen3-asr-1.7b-8bit"]

        request_model_service(
            paths,
            {"action": "shutdown"},
            timeout=1,
            start_if_needed=False,
        )
        thread.join(timeout=2)
        assert not thread.is_alive()
    finally:
        server.server_close()


def test_model_service_returns_explicit_missing_model_error(tmp_path: Path) -> None:
    paths = paths_for_root(tmp_path)
    paths.ensure_dirs()
    server = ModelServer(paths.model_service_socket_path, ModelRuntime(paths))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with pytest.raises(ModelServiceError, match="Model is not installed"):
            request_model_service(
                paths,
                {"action": "load", "model_id": "qwen3-asr-1.7b-8bit"},
                timeout=1,
                start_if_needed=False,
            )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
