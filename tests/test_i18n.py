from __future__ import annotations

import json
import sys
from pathlib import Path

from codex_voice import config_cli
from codex_voice.i18n import (
    TRANSLATIONS,
    build_correction_user_content,
    language_from_locale,
    normalize_output_text,
    resolve_ui_language,
    whisper_language,
)
from codex_voice.paths import paths_for_root
from codex_voice.voice import DEFAULT_CONFIG, migrate_config


def test_config_migration_adds_ui_language() -> None:
    migrated = migrate_config({"config_version": 2})

    assert migrated["ui_language"] == "system"


def test_system_language_resolution_maps_supported_locales() -> None:
    assert resolve_ui_language("system", ["ja-JP"]) == "ja"
    assert resolve_ui_language("system", ["zh-Hant-TW"]) == "zh-Hant"
    assert resolve_ui_language("system", ["zh-Hans-CN"]) == "zh-Hans"
    assert resolve_ui_language("system", ["fr-FR"]) == "en"
    assert language_from_locale("zh_HK") == "zh-Hant"


def test_whisper_language_follows_resolved_ui_language() -> None:
    assert whisper_language({"ui_language": "en"}) == "en"
    assert whisper_language({"ui_language": "zh-Hans"}) == "zh"
    assert whisper_language({"ui_language": "zh-Hant"}) == "zh"
    assert whisper_language({"ui_language": "ja"}) == "ja"


def test_prompt_language_constraint_follows_ui_language() -> None:
    japanese_prompt = build_correction_user_content(
        {"ui_language": "ja"},
        text="Open the README and run pytest.",
        mode="normal",
        clean_context=True,
        terms="",
    )
    traditional_prompt = build_correction_user_content(
        {"ui_language": "zh-Hant"},
        text="打开 README 并运行 pytest。",
        mode="strict",
        clean_context=False,
        terms="",
    )

    assert "日本語" in japanese_prompt
    assert "Open the README" in japanese_prompt
    assert "繁體中文" in traditional_prompt
    assert "pytest" in traditional_prompt


def test_output_script_normalization_uses_ui_language() -> None:
    assert normalize_output_text("這個錄音", {"ui_language": "zh-Hans"}) == "这个录音"
    assert normalize_output_text("这个录音", {"ui_language": "zh-Hant"}) == "這個錄音"
    assert normalize_output_text("這個 recording", {"ui_language": "en"}) == "這個 recording"


def test_config_cli_sets_ui_language(tmp_path: Path, monkeypatch) -> None:
    paths = paths_for_root(tmp_path)
    paths.config_dir.mkdir(parents=True)
    paths.config_path.write_text(
        json.dumps(DEFAULT_CONFIG, ensure_ascii=False),
        encoding="utf-8",
    )

    monkeypatch.setattr(
        sys,
        "argv",
        ["codex-voice-config", "--root", str(tmp_path), "--set-ui-language", "ja"],
    )

    assert config_cli.main() == 0

    config = json.loads(paths.config_path.read_text(encoding="utf-8"))
    assert config["ui_language"] == "ja"


def test_python_i18n_keys_are_complete() -> None:
    english_keys = set(TRANSLATIONS["en"])
    for language in ["zh-Hans", "zh-Hant", "ja"]:
        assert english_keys <= set(TRANSLATIONS[language])
