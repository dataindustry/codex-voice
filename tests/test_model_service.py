from __future__ import annotations

import threading
from pathlib import Path
from subprocess import CompletedProcess

import pytest

from codex_voice import model_client
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


def test_start_model_service_bootstraps_unregistered_launch_agent(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    paths = paths_for_root(tmp_path)
    plist = tmp_path / "Library" / "LaunchAgents" / "com.codexvoice.model-service.plist"
    plist.parent.mkdir(parents=True)
    plist.write_text("plist", encoding="utf-8")
    commands: list[list[str]] = []

    def fake_run(command: list[str], **_kwargs: object) -> CompletedProcess[str]:
        commands.append(command)
        return CompletedProcess(command, 1 if len(commands) == 1 else 0, "", "not found")

    monkeypatch.setattr(model_client.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(model_client.subprocess, "run", fake_run)
    monkeypatch.setattr(model_client, "_send", lambda *_args, **_kwargs: {"ok": True})

    model_client.start_model_service(paths, timeout=0.1)

    assert [command[1] for command in commands] == ["kickstart", "bootstrap", "kickstart"]
