from __future__ import annotations

import json
import os
import time
from pathlib import Path
from types import SimpleNamespace

from codex_voice import voice
from codex_voice.paths import paths_for_root, resolve_root
from codex_voice.voice import DEFAULT_CONFIG, migrate_config


def test_resolve_root_prefers_explicit(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("CODEX_VOICE_HOME", str(tmp_path / "env-root"))

    assert resolve_root(tmp_path / "explicit") == (tmp_path / "explicit").resolve()


def test_resolve_root_uses_environment(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("CODEX_VOICE_HOME", str(tmp_path / "env-root"))

    assert resolve_root() == (tmp_path / "env-root").resolve()


def test_app_paths_are_root_relative(tmp_path: Path) -> None:
    paths = paths_for_root(tmp_path)

    assert paths.config_path == tmp_path.resolve() / "config" / "config.json"


def test_long_roots_use_a_short_model_service_socket(tmp_path: Path) -> None:
    long_root = tmp_path / ("nested-" * 20)
    paths = paths_for_root(long_root)

    assert len(os.fsencode(paths.model_service_socket_path)) < 96


def test_existing_v1_config_migrates_to_two_stage_v4() -> None:
    migrated = migrate_config({"save_recordings": True})

    assert migrated["config_version"] == 4
    assert migrated["save_recordings"] is False
    assert migrated["save_transcripts"] is True
    assert migrated["processing_route"] == "two_stage"
    assert migrated["correction_enabled"] is True


def test_new_default_config_uses_direct_asr() -> None:
    assert DEFAULT_CONFIG["config_version"] == 4
    assert DEFAULT_CONFIG["processing_route"] == "direct_asr"
    assert DEFAULT_CONFIG["direct_asr_model"] == "qwen3-asr-1.7b-8bit"
    assert DEFAULT_CONFIG["correction_enabled"] is False
    assert DEFAULT_CONFIG["save_recordings"] is False
    assert DEFAULT_CONFIG["save_transcripts"] is True


def test_pid_detection_accepts_packaged_worker_entrypoint(monkeypatch) -> None:
    monkeypatch.setattr(voice.os, "kill", lambda _pid, _signal: None)
    monkeypatch.setattr(
        voice.subprocess,
        "run",
        lambda *_args, **_kwargs: SimpleNamespace(
            stdout="/Users/ryu/CodexVoice/src/codex_voice/voice.py --worker",
            returncode=0,
        ),
    )

    assert voice.pid_looks_like_codex_voice(12345) is True


def test_active_pid_recovers_packaged_worker_when_pid_file_is_missing(
    tmp_path: Path,
    monkeypatch,
) -> None:
    old_root = voice.PATHS.root
    voice.set_runtime_root(tmp_path)
    try:
        monkeypatch.setattr(voice.os, "kill", lambda _pid, _signal: None)
        monkeypatch.setattr(
            voice.subprocess,
            "run",
            lambda *_args, **_kwargs: SimpleNamespace(
                stdout=(
                    "101 /usr/bin/other\n"
                    "202 /Users/ryu/CodexVoice/src/codex_voice/voice.py --worker "
                    "--config /Users/ryu/CodexVoice/config/config.json\n"
                ),
                returncode=0,
            ),
        )

        assert voice.active_recording_pid() == 202
        assert voice.PID_PATH.read_text(encoding="utf-8") == "202"

        status = json.loads(voice.STATUS_PATH.read_text(encoding="utf-8"))
        assert status["status"] == "recording"
        assert status["pid"] == 202
    finally:
        voice.set_runtime_root(old_root)


def test_manual_submit_ignores_fresh_recording_worker(
    tmp_path: Path,
    monkeypatch,
) -> None:
    old_root = voice.PATHS.root
    voice.set_runtime_root(tmp_path)
    try:
        voice.ensure_dirs()
        voice.PID_PATH.write_text("999", encoding="utf-8")
        monkeypatch.setattr(voice, "active_recording_pid", lambda: 999)
        logger = voice.logging.getLogger("test")

        pid, submitted = voice.request_manual_submit(
            logger,
            min_recording_age_seconds=10,
        )

        assert pid == 999
        assert submitted is False
        assert not voice.SUBMIT_REQUEST_PATH.exists()

        old_time = time.time() - 20
        os.utime(voice.PID_PATH, (old_time, old_time))
        pid, submitted = voice.request_manual_submit(
            logger,
            min_recording_age_seconds=10,
        )

        assert pid == 999
        assert submitted is True
        assert voice.SUBMIT_REQUEST_PATH.exists()
    finally:
        voice.set_runtime_root(old_root)
