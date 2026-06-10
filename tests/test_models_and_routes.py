from __future__ import annotations

import json
import logging
import sys
import types
from pathlib import Path
from typing import Any

import pytest

from codex_voice import config_cli, voice
from codex_voice.correction import (
    apply_rule_corrections,
    correct_for_route,
    looks_like_aggressive_rewrite,
    strip_thinking,
)
from codex_voice.model_catalog import (
    DEFAULT_CORRECTION_MODEL,
    DEFAULT_DIRECT_ASR_MODEL,
    DEFAULT_TRANSCRIPTION_MODEL,
    MODEL_BY_ID,
    catalog_payload,
    download_model,
    model_is_installed,
    model_path,
)
from codex_voice.model_client import ModelServiceError
from codex_voice.paths import paths_for_root
from codex_voice.voice import CodexVoiceError, transcribe_audio


def test_rule_corrections_replace_common_misrecognitions() -> None:
    text = apply_rule_corrections(
        "打开麦cp并运行派普恩皮埃姆",
        {"common_misrecognitions": {"麦cp": "MCP", "派普恩皮埃姆": "pnpm"}},
    )

    assert text == "打开MCP并运行pnpm"


def test_aggressive_rewrite_detection() -> None:
    original = "请把这个 Python 脚本里的快捷键触发逻辑重构一下"
    corrected = "This is a completely different English paragraph with unrelated content."

    assert looks_like_aggressive_rewrite(original, corrected, "normal", {})


def test_strip_thinking_removes_think_blocks() -> None:
    assert strip_thinking("<think>hidden</think>最终文本") == "最终文本"


def test_model_catalog_separates_route_capabilities(tmp_path: Path) -> None:
    paths = paths_for_root(tmp_path)
    payload = catalog_payload(paths)

    assert {item["role"] for item in payload} == {
        "direct_asr",
        "transcription",
        "correction",
    }
    assert (
        MODEL_BY_ID[DEFAULT_DIRECT_ASR_MODEL].source_repo
        == "mlx-community/Qwen3-ASR-1.7B-8bit"
    )
    assert "ModelScope" not in str(model_path(paths, DEFAULT_DIRECT_ASR_MODEL))


def test_model_installation_requires_complete_weights(tmp_path: Path) -> None:
    paths = paths_for_root(tmp_path)
    path = model_path(paths, DEFAULT_DIRECT_ASR_MODEL)
    path.mkdir(parents=True)
    (path / "config.json").write_text("{}", encoding="utf-8")
    assert not model_is_installed(paths, DEFAULT_DIRECT_ASR_MODEL)

    (path / "model.safetensors.index.json").write_text(
        json.dumps(
            {
                "weight_map": {
                    "a": "model-00001-of-00002.safetensors",
                    "b": "model-00002-of-00002.safetensors",
                }
            }
        ),
        encoding="utf-8",
    )
    (path / "model-00001-of-00002.safetensors").touch()
    assert not model_is_installed(paths, DEFAULT_DIRECT_ASR_MODEL)

    (path / "model-00002-of-00002.safetensors").touch()
    assert model_is_installed(paths, DEFAULT_DIRECT_ASR_MODEL)


def test_legacy_qwen_asr_id_migrates_to_mlx_8bit() -> None:
    migrated = config_cli.migrate_config(
        {
            "config_version": 4,
            "processing_route": "direct_asr",
            "direct_asr_model": "qwen3-asr-1.7b",
        }
    )

    assert migrated["direct_asr_model"] == DEFAULT_DIRECT_ASR_MODEL


def test_modelscope_download_reports_aggregate_progress(
    tmp_path: Path,
    monkeypatch,
) -> None:
    class FakeProgressCallback:
        def __init__(self, filename: str, file_size: int):
            self.filename = filename
            self.file_size = file_size

    class FakeHubApi:
        def get_model_files(self, *_args, **_kwargs):
            return [
                {
                    "Type": "blob",
                    "Path": "config.json",
                    "Size": 2,
                },
                {
                    "Type": "blob",
                    "Path": "weights.safetensors",
                    "Size": 100,
                },
            ]

    def fake_snapshot_download(_repo: str, *, local_dir: str, progress_callbacks):
        destination = Path(local_dir)
        destination.mkdir(parents=True)
        callback_type = progress_callbacks[0]
        config_callback = callback_type("config.json", 2)
        config_callback.update(2)
        config_callback.end()
        weight_callback = callback_type("weights.safetensors", 100)
        weight_callback.update(25)
        weight_callback.update(75)
        weight_callback.end()
        (destination / "config.json").write_text("{}", encoding="utf-8")
        (destination / "weights.safetensors").write_bytes(b"x" * 100)
        return str(destination)

    modelscope = types.ModuleType("modelscope")
    modelscope_dynamic: Any = modelscope
    modelscope_dynamic.snapshot_download = fake_snapshot_download
    hub = types.ModuleType("modelscope.hub")
    api = types.ModuleType("modelscope.hub.api")
    callback = types.ModuleType("modelscope.hub.callback")
    api_dynamic: Any = api
    callback_dynamic: Any = callback
    api_dynamic.HubApi = FakeHubApi
    callback_dynamic.ProgressCallback = FakeProgressCallback
    monkeypatch.setitem(sys.modules, "modelscope", modelscope)
    monkeypatch.setitem(sys.modules, "modelscope.hub", hub)
    monkeypatch.setitem(sys.modules, "modelscope.hub.api", api)
    monkeypatch.setitem(sys.modules, "modelscope.hub.callback", callback)

    progress: list[float] = []
    paths = paths_for_root(tmp_path)
    download_model(paths, DEFAULT_DIRECT_ASR_MODEL, progress.append)

    assert progress[0] == 0
    assert progress[-1] == 1
    assert progress == sorted(progress)
    assert any(0 < value < 1 for value in progress)


def test_ensure_model_downloads_then_loads(tmp_path: Path, monkeypatch) -> None:
    config_cli.set_runtime_root(tmp_path)
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(config_cli, "model_is_installed", lambda *_args: False)
    monkeypatch.setattr(
        config_cli,
        "download_one",
        lambda model_id, finish_task: calls.append(("download", model_id)),
    )
    monkeypatch.setattr(
        config_cli,
        "service_loaded_ids",
        lambda: (set(), True, ""),
    )
    monkeypatch.setattr(
        config_cli,
        "load_model_for_scope",
        lambda model_id, scope: calls.append((scope, model_id)),
    )

    config_cli.ensure_model(DEFAULT_DIRECT_ASR_MODEL)

    assert calls == [
        ("download", DEFAULT_DIRECT_ASR_MODEL),
        ("transcription", DEFAULT_DIRECT_ASR_MODEL),
    ]


def test_fresh_config_defaults_to_direct_asr() -> None:
    migrated = config_cli.migrate_config({})

    assert migrated["processing_route"] == "direct_asr"
    assert migrated["direct_asr_model"] == DEFAULT_DIRECT_ASR_MODEL
    assert migrated["correction_enabled"] is False


def test_existing_config_preserves_two_stage_behavior() -> None:
    migrated = config_cli.migrate_config(
        {
            "config_version": 2,
            "whisper_backend": "mlx-whisper",
            "correction_backend": "ollama",
            "external_api_enabled": True,
            "openai_transcription_model": "legacy-cloud-asr",
            "ollama_min_similarity": 0.91,
            "ollama_num_ctx": 4000,
            "faster_whisper_device": "cpu",
        }
    )

    assert migrated["processing_route"] == "two_stage"
    assert migrated["transcription_model"] == DEFAULT_TRANSCRIPTION_MODEL
    assert migrated["correction_model"] == DEFAULT_CORRECTION_MODEL
    assert migrated["correction_enabled"] is True
    assert migrated["correction_min_similarity"] == 0.91
    assert "correction_backend" not in migrated
    assert "external_api_enabled" not in migrated
    assert "openai_transcription_model" not in migrated
    assert "correction_profile" not in migrated
    assert "ollama_num_ctx" not in migrated
    assert "faster_whisper_device" not in migrated


@pytest.mark.parametrize(
    ("route", "expected"),
    [("direct_asr", False), ("two_stage", True)],
)
def test_v3_config_preserves_previous_correction_behavior(
    route: str,
    expected: bool,
) -> None:
    migrated = config_cli.migrate_config(
        {
            "config_version": 3,
            "processing_route": route,
            "correction_model": DEFAULT_CORRECTION_MODEL,
        }
    )

    assert migrated["correction_enabled"] is expected
    assert migrated["config_version"] == 4


def test_config_cli_sets_processing_route(
    tmp_path: Path,
    monkeypatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    paths = paths_for_root(tmp_path)
    paths.config_dir.mkdir(parents=True)
    paths.config_path.write_text(
        json.dumps({**voice.DEFAULT_CONFIG, "ui_language": "en"}, ensure_ascii=False),
        encoding="utf-8",
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "codex-voice-config",
            "--root",
            str(tmp_path),
            "--set-processing-route",
            "two_stage",
        ],
    )

    assert config_cli.main() == 0
    saved = json.loads(paths.config_path.read_text(encoding="utf-8"))
    assert saved["processing_route"] == "two_stage"
    assert "Two-stage Enhanced" in capsys.readouterr().out


def test_config_cli_rejects_unknown_ui_language(tmp_path: Path, monkeypatch) -> None:
    paths = paths_for_root(tmp_path)
    paths.config_dir.mkdir(parents=True)
    paths.config_path.write_text(
        json.dumps({**voice.DEFAULT_CONFIG, "ui_language": "en"}, ensure_ascii=False),
        encoding="utf-8",
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "codex-voice-config",
            "--root",
            str(tmp_path),
            "--set-ui-language",
            "xx",
        ],
    )

    with pytest.raises(SystemExit, match="Unsupported UI language"):
        config_cli.main()


def test_config_cli_toggles_selected_correction_model(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = paths_for_root(tmp_path)
    paths.config_dir.mkdir(parents=True)
    paths.config_path.write_text(
        json.dumps({**voice.DEFAULT_CONFIG, "ui_language": "en"}, ensure_ascii=False),
        encoding="utf-8",
    )
    argv = [
        "codex-voice-config",
        "--root",
        str(tmp_path),
        "--toggle-correction-model",
        DEFAULT_CORRECTION_MODEL,
    ]

    monkeypatch.setattr(sys, "argv", argv)
    assert config_cli.main() == 0
    enabled = json.loads(paths.config_path.read_text(encoding="utf-8"))
    assert enabled["correction_enabled"] is True
    assert enabled["correction_model"] == DEFAULT_CORRECTION_MODEL

    monkeypatch.setattr(sys, "argv", argv)
    assert config_cli.main() == 0
    disabled = json.loads(paths.config_path.read_text(encoding="utf-8"))
    assert disabled["correction_enabled"] is False
    assert disabled["correction_model"] == DEFAULT_CORRECTION_MODEL


@pytest.mark.parametrize(
    ("route", "primary_model"),
    [
        ("direct_asr", DEFAULT_DIRECT_ASR_MODEL),
        ("two_stage", DEFAULT_TRANSCRIPTION_MODEL),
    ],
)
@pytest.mark.parametrize("correction_enabled", [False, True])
def test_prepare_route_loads_optional_correction_model(
    monkeypatch,
    route: str,
    primary_model: str,
    correction_enabled: bool,
) -> None:
    loaded: list[tuple[str, str]] = []
    monkeypatch.setattr(
        config_cli,
        "load_model_for_scope",
        lambda model_id, scope: loaded.append((model_id, scope)),
    )
    config = {
        "processing_route": route,
        "direct_asr_model": DEFAULT_DIRECT_ASR_MODEL,
        "transcription_model": DEFAULT_TRANSCRIPTION_MODEL,
        "correction_model": DEFAULT_CORRECTION_MODEL,
        "correction_enabled": correction_enabled,
    }

    config_cli.prepare_current_route_models(config)

    assert loaded[0] == (primary_model, "transcription")
    if correction_enabled:
        assert loaded[1] == (DEFAULT_CORRECTION_MODEL, "correction")
    else:
        assert len(loaded) == 1


@pytest.mark.parametrize(
    ("route", "model_key", "expected_model", "expected_backend"),
    [
        ("direct_asr", "direct_asr_model", DEFAULT_DIRECT_ASR_MODEL, "qwen3-asr"),
        ("two_stage", "transcription_model", DEFAULT_TRANSCRIPTION_MODEL, "mlx-whisper"),
    ],
)
def test_transcription_uses_only_the_selected_route(
    tmp_path: Path,
    monkeypatch,
    route: str,
    model_key: str,
    expected_model: str,
    expected_backend: str,
) -> None:
    requests: list[dict[str, object]] = []

    def fake_request(_paths, payload, **_kwargs):
        requests.append(payload)
        return {"text": "recognized"}

    monkeypatch.setattr(voice, "request_model_service", fake_request)
    config = {
        "processing_route": route,
        model_key: expected_model,
        "ui_language": "en",
    }

    text, backend, model = transcribe_audio(
        tmp_path / "sample.wav",
        config,
        {},
        logging.getLogger("route-test"),
    )

    assert (text, backend, model) == ("recognized", expected_backend, expected_model)
    assert [request["model_id"] for request in requests] == [expected_model]


def test_transcription_failure_does_not_fall_back(monkeypatch, tmp_path: Path) -> None:
    calls = 0

    def fail_request(_paths, _payload, **_kwargs):
        nonlocal calls
        calls += 1
        raise ModelServiceError("model missing")

    monkeypatch.setattr(voice, "request_model_service", fail_request)

    with pytest.raises(CodexVoiceError, match="model missing"):
        transcribe_audio(
            tmp_path / "sample.wav",
            {
                "processing_route": "direct_asr",
                "direct_asr_model": DEFAULT_DIRECT_ASR_MODEL,
                "ui_language": "en",
            },
            {},
            logging.getLogger("route-test"),
        )

    assert calls == 1


def test_disabled_correction_never_invokes_text_correction(monkeypatch) -> None:
    def unexpected(*_args, **_kwargs):
        raise AssertionError("correction model should not be called")

    monkeypatch.setattr(voice, "correct_with_model_service", unexpected)

    result = correct_for_route(
        "rule-corrected",
        "normal",
        {"processing_route": "direct_asr", "correction_enabled": False},
        {},
        logging.getLogger("route-test"),
    )

    assert result == ("rule-corrected", "not-used", "")


@pytest.mark.parametrize("route", ["direct_asr", "two_stage"])
def test_enabled_correction_runs_for_both_asr_routes(
    monkeypatch,
    route: str,
) -> None:
    monkeypatch.setattr(
        voice,
        "correct_with_model_service",
        lambda *_args, **_kwargs: ("corrected", "mlx-lm", DEFAULT_CORRECTION_MODEL),
    )

    result = correct_for_route(
        "raw",
        "normal",
        {"processing_route": route, "correction_enabled": True},
        {},
        logging.getLogger("route-test"),
    )

    assert result == ("corrected", "mlx-lm", DEFAULT_CORRECTION_MODEL)


def test_transcript_records_route_and_model_metadata(tmp_path: Path) -> None:
    old_root = voice.PATHS.root
    voice.set_runtime_root(tmp_path)
    try:
        voice.ensure_dirs()
        path = voice.save_transcript(
            mode="normal",
            audio_path=None,
            processing_route="direct_asr",
            asr_backend="qwen3-asr",
            asr_model=DEFAULT_DIRECT_ASR_MODEL,
            correction_backend="not-used",
            correction_model="",
            raw_text="raw",
            rule_text="rule",
            final_text="final",
            config={"save_transcripts": True},
        )
        assert path is not None
        content = path.read_text(encoding="utf-8")
        assert "* Processing Route: direct_asr" in content
        assert f"* ASR Model: {DEFAULT_DIRECT_ASR_MODEL}" in content
        assert "* Correction Applied: no" in content
    finally:
        voice.set_runtime_root(old_root)
