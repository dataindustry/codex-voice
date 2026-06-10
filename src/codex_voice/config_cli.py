#!/usr/bin/env python3
"""Configuration and local-model management CLI for Codex Voice."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path
from typing import Any

from codex_voice.i18n import (
    SUPPORTED_UI_LANGUAGES,
    language_label,
    normalize_ui_language,
    resolve_ui_language,
    t,
)
from codex_voice.model_catalog import (
    DEFAULT_CORRECTION_MODEL,
    DEFAULT_DIRECT_ASR_MODEL,
    DEFAULT_TRANSCRIPTION_MODEL,
    MODEL_BY_ID,
    canonical_model_id,
    catalog_payload,
    download_model,
    model_is_installed,
    model_path,
)
from codex_voice.model_client import ModelServiceError, request_model_service
from codex_voice.paths import AppPaths, paths_for_root

PATHS = paths_for_root()
ROOT = PATHS.root
CONFIG_PATH = PATHS.config_path
MODEL_TASK_PATH = PATHS.model_task_path
DEFAULT_NATIVE_HOTKEY = {"key_code": 49, "key": "space", "modifiers": ["option"]}
LEGACY_CORRECTION_FIELDS = {
    "ollama_clean_context_per_request": "correction_clean_context_per_request",
    "ollama_max_length_ratio": "correction_max_length_ratio",
    "ollama_min_length_ratio": "correction_min_length_ratio",
    "ollama_min_similarity": "correction_min_similarity",
    "ollama_num_predict": "correction_num_predict",
    "ollama_reject_aggressive_rewrite": "correction_reject_aggressive_rewrite",
}
LEGACY_MODEL_FIELDS = {
    "correction_backend",
    "correction_profile",
    "correction_num_ctx",
    "external_api_enabled",
    "openai_correction_model",
    "openai_transcription_model",
    "transcription_profile",
    "whisper_backend",
    "whisper_beam_size",
    "whisper_fallback_backend",
    "whisper_fallback_model",
    "whisper_model",
}


def migrate_config(config: dict[str, Any]) -> dict[str, Any]:
    migrated = dict(config)
    is_existing_install = bool(migrated)
    version = int(migrated.get("config_version", 1) or 1)
    legacy_rule_only = migrated.get("correction_profile") in {"rule-only", "none"}
    if version < 2:
        migrated["save_recordings"] = False
        migrated.setdefault("save_transcripts", True)
    if version < 3:
        # Existing installations used Whisper followed by Ollama correction.
        for old_key, new_key in LEGACY_CORRECTION_FIELDS.items():
            if old_key in migrated and new_key not in migrated:
                migrated[new_key] = migrated[old_key]
        migrated.setdefault(
            "processing_route",
            "two_stage" if is_existing_install else "direct_asr",
        )
        migrated.setdefault("direct_asr_model", DEFAULT_DIRECT_ASR_MODEL)
        migrated.setdefault("transcription_model", DEFAULT_TRANSCRIPTION_MODEL)
        migrated.setdefault("correction_model", DEFAULT_CORRECTION_MODEL)
    migrated.setdefault("processing_route", "direct_asr")
    migrated.setdefault("direct_asr_model", DEFAULT_DIRECT_ASR_MODEL)
    migrated.setdefault("transcription_model", DEFAULT_TRANSCRIPTION_MODEL)
    migrated.setdefault("correction_model", DEFAULT_CORRECTION_MODEL)
    migrated["direct_asr_model"] = canonical_model_id(str(migrated["direct_asr_model"]))
    migrated["transcription_model"] = canonical_model_id(str(migrated["transcription_model"]))
    migrated["correction_model"] = canonical_model_id(str(migrated["correction_model"]))
    if version < 4:
        migrated.setdefault(
            "correction_enabled",
            bool(
                is_existing_install
                and migrated.get("processing_route") == "two_stage"
                and not legacy_rule_only
            ),
        )
    migrated["config_version"] = 4
    migrated.setdefault("correction_enabled", False)
    for key in list(migrated):
        if key.startswith(("ollama_", "faster_whisper_")) or key in LEGACY_MODEL_FIELDS:
            migrated.pop(key, None)
    migrated.setdefault("ui_language", "system")
    migrated.setdefault("native_hotkey_enabled", True)
    if not isinstance(migrated.get("native_hotkey"), dict):
        migrated["native_hotkey"] = DEFAULT_NATIVE_HOTKEY.copy()
    return migrated


def load_config() -> dict[str, Any]:
    with CONFIG_PATH.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise SystemExit(f"Config is not a JSON object: {CONFIG_PATH}")
    return migrate_config(data)


def safe_message_config() -> dict[str, Any]:
    try:
        return load_config()
    except Exception:
        return {"ui_language": "system"}


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temp_path.replace(path)


def save_config(config: dict[str, Any]) -> None:
    config["config_version"] = 4
    write_json_atomic(CONFIG_PATH, config)


def set_runtime_root(root: str | os.PathLike[str] | None) -> AppPaths:
    global PATHS, ROOT, CONFIG_PATH, MODEL_TASK_PATH
    PATHS = paths_for_root(root)
    ROOT = PATHS.root
    CONFIG_PATH = PATHS.config_path
    MODEL_TASK_PATH = PATHS.model_task_path
    os.environ["CODEX_VOICE_HOME"] = str(ROOT)
    return PATHS


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def write_model_task(
    status: str,
    scope: str,
    label: str,
    detail: str = "",
    progress: float | None = None,
    label_key: str = "",
    detail_key: str = "",
    label_args: dict[str, Any] | None = None,
    detail_args: dict[str, Any] | None = None,
    model_id: str = "",
    phase: str = "",
) -> None:
    config = safe_message_config()
    if label_key:
        label = t(config, label_key, **(label_args or {}))
    if detail_key:
        detail = t(config, detail_key, **(detail_args or {}))
    payload: dict[str, Any] = {
        "status": status,
        "scope": scope,
        "model_id": model_id,
        "phase": phase,
        "label": label,
        "label_key": label_key,
        "label_args": label_args or {},
        "detail": detail,
        "detail_key": detail_key,
        "detail_args": detail_args or {},
        "progress": progress,
        "pid": os.getpid() if status == "running" else None,
        "started_at": iso_now(),
        "updated_at": iso_now(),
    }
    write_json_atomic(MODEL_TASK_PATH, payload)


def read_model_task() -> dict[str, Any]:
    if not MODEL_TASK_PATH.exists():
        config = safe_message_config()
        return {
            "status": "idle",
            "scope": "",
            "model_id": "",
            "phase": "",
            "label": t(config, "task.idle"),
            "label_key": "task.idle",
            "label_args": {},
            "detail": "",
            "detail_key": "",
            "detail_args": {},
            "progress": None,
            "pid": None,
            "updated_at": iso_now(),
        }
    try:
        data = json.loads(MODEL_TASK_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"status": "error", "scope": "", "detail": str(exc)}
    return data if isinstance(data, dict) else {}


def service_loaded_ids() -> tuple[set[str], bool, str]:
    try:
        response = request_model_service(
            PATHS,
            {"action": "status"},
            timeout=2,
            start_if_needed=False,
        )
        return set(str(item) for item in response.get("loaded_model_ids", [])), True, ""
    except Exception as exc:
        return set(), False, str(exc)


def list_models() -> None:
    loaded, available, error = service_loaded_ids()
    models = catalog_payload(PATHS, loaded)
    print(
        json.dumps(
            {
                "available": available,
                "status": "available" if available else "service_unavailable",
                "error": error,
                "socket": str(PATHS.model_service_socket_path),
                "models": models,
                "direct_asr_models": [
                    item for item in models if item["role"] == "direct_asr"
                ],
                "transcription_models": [
                    item for item in models if item["role"] == "transcription"
                ],
                "correction_models": [
                    item for item in models if item["role"] == "correction"
                ],
            },
            ensure_ascii=False,
        )
    )


def list_loaded_models() -> None:
    loaded, available, error = service_loaded_ids()
    print(
        json.dumps(
            {
                "available": available,
                "status": "available" if available else "service_unavailable",
                "error": error,
                "models": sorted(loaded),
            },
            ensure_ascii=False,
        )
    )


def require_model_role(model_id: str, role: str) -> None:
    model_id = canonical_model_id(model_id)
    spec = MODEL_BY_ID.get(model_id)
    if spec is None:
        raise SystemExit(f"Unknown model id: {model_id}")
    if spec.role != role:
        raise SystemExit(f"Model {model_id} has role {spec.role}, expected {role}.")


def set_processing_route(config: dict[str, Any], route: str) -> None:
    if route not in {"direct_asr", "two_stage"}:
        raise SystemExit("processing_route must be direct_asr or two_stage.")
    config["processing_route"] = route
    config["setup_profile"] = "custom"


def processing_route_label(config: dict[str, Any], route: str) -> str:
    return t(config, f"route.{route}")


def set_model(config: dict[str, Any], key: str, model_id: str, role: str) -> None:
    model_id = canonical_model_id(model_id)
    require_model_role(model_id, role)
    config[key] = model_id
    config["setup_profile"] = "custom"


def toggle_correction_model(config: dict[str, Any], model_id: str) -> bool:
    model_id = canonical_model_id(model_id)
    require_model_role(model_id, "correction")
    is_same_model = config.get("correction_model") == model_id
    is_enabled = bool(config.get("correction_enabled", False))
    config["correction_model"] = model_id
    config["correction_enabled"] = not (is_same_model and is_enabled)
    config["setup_profile"] = "custom"
    return bool(config["correction_enabled"])


def task_scope_for_model(model_id: str) -> str:
    model_id = canonical_model_id(model_id)
    spec = MODEL_BY_ID.get(model_id)
    if spec is None:
        raise RuntimeError(f"Unknown model id: {model_id}")
    return "correction" if spec.role == "correction" else "transcription"


def download_one(
    model_id: str,
    *,
    finish_task: bool = True,
) -> None:
    model_id = canonical_model_id(model_id)
    spec = MODEL_BY_ID.get(model_id)
    if spec is None:
        raise SystemExit(f"Unknown model id: {model_id}")
    scope = task_scope_for_model(model_id)
    label_args = {"model": spec.name}
    progress_lock = threading.Lock()
    last_progress = -1.0
    last_update = 0.0

    def report_progress(progress: float) -> None:
        nonlocal last_progress, last_update
        now = time.monotonic()
        with progress_lock:
            if (
                progress < 1.0
                and progress - last_progress < 0.005
                and now - last_update < 0.1
            ):
                return
            last_progress = progress
            last_update = now
            write_model_task(
                "running",
                scope,
                "",
                "",
                progress,
                label_key="task.downloading_model",
                label_args=label_args,
                model_id=model_id,
                phase="download",
            )

    report_progress(0.0)
    try:
        download_model(PATHS, model_id, progress_callback=report_progress)
        if finish_task:
            write_model_task(
                "succeeded",
                scope,
                "",
                "",
                1.0,
                label_key="task.download_model",
                detail_key="task.model_ready",
                label_args=label_args,
                model_id=model_id,
                phase="download",
            )
    except Exception as exc:
        write_model_task(
            "failed",
            scope,
            "",
            str(exc),
            None,
            label_key="task.download_model",
            label_args=label_args,
            model_id=model_id,
            phase="download",
        )
        raise


def load_model_for_scope(model_id: str, scope: str) -> None:
    model_id = canonical_model_id(model_id)
    spec = MODEL_BY_ID.get(model_id)
    if spec is None:
        raise RuntimeError(f"Unknown model id: {model_id}")
    label_args = {"model": spec.name}
    write_model_task(
        "running",
        scope,
        "",
        "",
        None,
        label_key="task.loading_model",
        label_args=label_args,
        model_id=model_id,
        phase="load",
    )
    try:
        request_model_service(
            PATHS,
            {"action": "load", "model_id": model_id},
            timeout=300,
        )
        write_model_task(
            "succeeded",
            scope,
            "",
            "",
            1.0,
            label_key="task.prepare_model",
            detail_key="task.model_loaded",
            label_args=label_args,
            model_id=model_id,
            phase="load",
        )
    except Exception as exc:
        write_model_task(
            "failed",
            scope,
            "",
            str(exc),
            None,
            label_key="task.prepare_model",
            label_args=label_args,
            model_id=model_id,
            phase="load",
        )
        raise


def ensure_model(model_id: str) -> None:
    model_id = canonical_model_id(model_id)
    if model_id not in MODEL_BY_ID:
        raise RuntimeError(f"Unknown model id: {model_id}")
    if not model_is_installed(PATHS, model_id):
        download_one(model_id, finish_task=False)

    loaded, available, _ = service_loaded_ids()
    if available and model_id in loaded:
        return
    load_model_for_scope(model_id, task_scope_for_model(model_id))


def prepare_current_transcription_model(config: dict[str, Any]) -> None:
    if config.get("processing_route") == "direct_asr":
        load_model_for_scope(str(config["direct_asr_model"]), "transcription")
    else:
        load_model_for_scope(str(config["transcription_model"]), "transcription")


def prepare_current_correction_model(config: dict[str, Any]) -> None:
    if not bool(config.get("correction_enabled", False)):
        raise SystemExit("Text correction is disabled.")
    load_model_for_scope(str(config["correction_model"]), "correction")


def prepare_current_route_models(config: dict[str, Any]) -> None:
    prepare_current_transcription_model(config)
    if bool(config.get("correction_enabled", False)):
        prepare_current_correction_model(config)


def unload_model(model_id: str) -> None:
    model_id = canonical_model_id(model_id)
    spec = MODEL_BY_ID.get(model_id)
    if spec is None:
        raise RuntimeError(f"Unknown model id: {model_id}")
    label_args = {"model": spec.name}
    write_model_task(
        "running",
        spec.role,
        "",
        "",
        None,
        label_key="task.unload_model",
        detail_key="task.unloading",
        label_args=label_args,
        model_id=model_id,
        phase="unload",
    )
    request_model_service(
        PATHS,
        {"action": "unload", "model_id": model_id},
        timeout=60,
    )
    write_model_task(
        "succeeded",
        spec.role,
        "",
        "",
        1.0,
        label_key="task.unload_model",
        detail_key="task.unloaded",
        label_args=label_args,
        model_id=model_id,
        phase="unload",
    )


def delete_model(model_id: str) -> None:
    model_id = canonical_model_id(model_id)
    if model_id not in MODEL_BY_ID:
        raise RuntimeError(f"Unknown model id: {model_id}")
    try:
        unload_model(model_id)
    except ModelServiceError:
        pass
    shutil.rmtree(model_path(PATHS, model_id), ignore_errors=False)


def default_input_index(sd: Any) -> int | None:
    value = sd.default.device
    if isinstance(value, (list, tuple)) or hasattr(value, "__getitem__"):
        value = value[0] if value else None
    try:
        index = int(value)
    except (TypeError, ValueError):
        return None
    return index if index >= 0 else None


def list_input_devices(config: dict[str, Any]) -> None:
    try:
        import sounddevice as sd
    except ImportError as exc:
        raise SystemExit(f"sounddevice is not installed: {exc}") from exc
    default_index = default_input_index(sd)
    devices = [
        {
            "index": index,
            "name": str(device.get("name", "")),
            "default": index == default_index,
            "channels": int(device.get("max_input_channels", 0)),
        }
        for index, device in enumerate(sd.query_devices())
        if int(device.get("max_input_channels", 0)) > 0
    ]
    print(json.dumps({"configured": config.get("input_device"), "devices": devices}, ensure_ascii=False))


def resolve_input_device_for_probe(config: dict[str, Any], sd: Any) -> int | None:
    configured = config.get("input_device")
    if configured in (None, ""):
        return None
    if isinstance(configured, int):
        return configured
    text = str(configured)
    if text.lower() in {"auto", "default", "system", "__default__"}:
        return None
    try:
        return int(text)
    except ValueError:
        pass
    candidates = []
    for index, device in enumerate(sd.query_devices()):
        name = str(device.get("name", ""))
        if int(device.get("max_input_channels", 0)) <= 0:
            continue
        if name == text:
            return index
        if text.lower() in name.lower():
            candidates.append(index)
    return candidates[0] if candidates else None


def probe_input_device(config: dict[str, Any]) -> None:
    try:
        import numpy as np
        import sounddevice as sd
    except ImportError as exc:
        raise SystemExit(f"Audio probe dependency is not installed: {exc}") from exc
    sample_rate = int(config.get("sample_rate", 16000))
    channels = int(config.get("channels", 1))
    device = resolve_input_device_for_probe(config, sd)
    frames = max(1, int(sample_rate * 0.6))
    with sd.InputStream(
        samplerate=sample_rate,
        channels=channels,
        dtype="float32",
        blocksize=frames,
        device=device,
    ) as stream:
        data, overflowed = stream.read(frames)
    rms = float(np.sqrt(np.mean(np.square(data)))) if data.size else 0.0
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    print(
        json.dumps(
            {
                "device": "system default" if device is None else device,
                "rms": rms,
                "peak": peak,
                "overflowed": bool(overflowed),
            },
            ensure_ascii=False,
        )
    )


def show(config: dict[str, Any]) -> None:
    max_seconds = int(config.get("background_max_record_seconds", config.get("max_record_seconds", 300)))
    resolved = resolve_ui_language(config)
    configured_language = normalize_ui_language(config.get("ui_language", "system"))
    print(t(config, "cli.installed_at", root=ROOT))
    print(t(config, "cli.conda_env", env=os.environ.get("CODEX_VOICE_CONDA_ENV", "codex-voice")))
    print(t(config, "cli.python", python=os.environ.get("CODEX_VOICE_PYTHON", sys.executable)))
    print(t(config, "cli.max_recording", seconds=max_seconds, minutes=max_seconds / 60))
    print(t(config, "cli.input_device", device=config.get("input_device") or t(config, "cli.system_default")))
    print(
        t(
            config,
            "cli.processing_route",
            route=processing_route_label(config, str(config["processing_route"])),
        )
    )
    print(t(config, "cli.direct_asr_model", model=config["direct_asr_model"]))
    print(t(config, "cli.transcription_model", model=config["transcription_model"]))
    print(t(config, "cli.correction_model", model=config["correction_model"]))
    print(
        t(
            config,
            "cli.ui_language",
            language=language_label(config, configured_language),
            resolved=language_label(config, resolved),
        )
    )
    print(t(config, "cli.config_file", path=CONFIG_PATH))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Configure Codex Voice")
    parser.add_argument("--root", type=Path, default=None)
    parser.add_argument("--show", action="store_true")
    parser.add_argument("--migrate-config", action="store_true")
    parser.add_argument("--list-input-devices", action="store_true")
    parser.add_argument("--set-input-device")
    parser.add_argument("--probe-input-device", action="store_true")
    parser.add_argument("--set-max-minutes", type=float)
    parser.add_argument("--set-ui-language")
    parser.add_argument("--set-processing-route")
    parser.add_argument("--list-models", action="store_true")
    parser.add_argument("--list-loaded-models", action="store_true")
    parser.add_argument("--set-direct-asr-model")
    parser.add_argument("--set-transcription-model")
    parser.add_argument("--set-correction-model")
    parser.add_argument("--toggle-correction-model")
    parser.add_argument("--download-model")
    parser.add_argument("--ensure-model")
    parser.add_argument("--download-default-models", action="store_true")
    parser.add_argument("--delete-model")
    parser.add_argument("--prepare-current-transcription-model", action="store_true")
    parser.add_argument("--prepare-current-correction-model", action="store_true")
    parser.add_argument("--prepare-current-route-models", action="store_true")
    parser.add_argument("--unload-current-correction-model", action="store_true")
    parser.add_argument("--unload-model")
    parser.add_argument("--shutdown-model-service", action="store_true")
    parser.add_argument("--model-task-status", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    set_runtime_root(args.root)
    config = load_config()

    if args.migrate_config:
        save_config(config)
        return 0
    if args.model_task_status:
        print(json.dumps(read_model_task(), ensure_ascii=False))
        return 0
    if args.list_input_devices:
        list_input_devices(config)
        return 0
    if args.probe_input_device:
        probe_input_device(config)
        return 0
    if args.list_models:
        list_models()
        return 0
    if args.list_loaded_models:
        list_loaded_models()
        return 0

    if args.set_input_device is not None:
        value = args.set_input_device.strip()
        if value in {"", "__default__", "default", "system", "auto"}:
            config["input_device"] = None
            label = t(config, "cli.system_default")
        else:
            config["input_device"] = value
            label = value
        save_config(config)
        print(t(config, "cli.set_input_device", label=label))
        return 0
    if args.set_max_minutes is not None:
        if args.set_max_minutes <= 0:
            raise SystemExit(t(config, "cli.max_minutes_positive"))
        if args.set_max_minutes > 10:
            raise SystemExit(t(config, "cli.max_minutes_refused"))
        seconds = int(round(args.set_max_minutes * 60))
        config["max_record_seconds"] = seconds
        config["background_max_record_seconds"] = seconds
        save_config(config)
        print(
            t(
                config,
                "cli.set_max_recording",
                seconds=seconds,
                minutes=args.set_max_minutes,
            )
        )
        return 0
    if args.set_ui_language is not None:
        language = args.set_ui_language.strip()
        normalized = normalize_ui_language(language)
        if normalized not in SUPPORTED_UI_LANGUAGES or (
            normalized == "system" and language not in {"", "system"}
        ):
            raise SystemExit(
                t(
                    config,
                    "cli.invalid_ui_language",
                    language=language,
                    choices=", ".join(SUPPORTED_UI_LANGUAGES),
                )
            )
        config["ui_language"] = normalized
        save_config(config)
        print(
            t(
                config,
                "cli.set_ui_language",
                language=language_label(config, normalized),
                resolved=language_label(config, resolve_ui_language(config)),
            )
        )
        return 0
    if args.set_processing_route is not None:
        route = args.set_processing_route.strip()
        set_processing_route(config, route)
        save_config(config)
        print(
            t(
                config,
                "cli.set_processing_route",
                route=processing_route_label(config, route),
            )
        )
        return 0
    if args.set_direct_asr_model is not None:
        model_id = args.set_direct_asr_model.strip()
        set_model(config, "direct_asr_model", model_id, "direct_asr")
        save_config(config)
        print(t(config, "cli.set_direct_asr_model", model=MODEL_BY_ID[model_id].name))
        return 0
    if args.set_transcription_model is not None:
        model_id = args.set_transcription_model.strip()
        set_model(config, "transcription_model", model_id, "transcription")
        save_config(config)
        print(t(config, "cli.set_transcription_model", model=MODEL_BY_ID[model_id].name))
        return 0
    if args.set_correction_model is not None:
        model_id = args.set_correction_model.strip()
        set_model(config, "correction_model", model_id, "correction")
        config["correction_enabled"] = True
        save_config(config)
        print(t(config, "cli.set_correction_model", model=MODEL_BY_ID[model_id].name))
        return 0
    if args.toggle_correction_model is not None:
        model_id = args.toggle_correction_model.strip()
        enabled = toggle_correction_model(config, model_id)
        save_config(config)
        key = "cli.correction_enabled" if enabled else "cli.correction_disabled"
        print(t(config, key, model=MODEL_BY_ID[model_id].name))
        return 0

    if args.download_model:
        download_one(args.download_model.strip())
        return 0
    if args.ensure_model:
        ensure_model(args.ensure_model.strip())
        return 0
    if args.download_default_models:
        for model_id in (
            DEFAULT_DIRECT_ASR_MODEL,
            DEFAULT_TRANSCRIPTION_MODEL,
            DEFAULT_CORRECTION_MODEL,
        ):
            if not model_is_installed(PATHS, model_id):
                download_one(model_id)
        return 0
    if args.delete_model:
        delete_model(args.delete_model.strip())
        return 0
    if args.prepare_current_transcription_model:
        prepare_current_transcription_model(config)
        return 0
    if args.prepare_current_correction_model:
        prepare_current_correction_model(config)
        return 0
    if args.prepare_current_route_models:
        prepare_current_route_models(config)
        return 0
    if args.unload_current_correction_model:
        unload_model(str(config["correction_model"]))
        return 0
    if args.unload_model:
        unload_model(args.unload_model.strip())
        return 0
    if args.shutdown_model_service:
        request_model_service(PATHS, {"action": "shutdown"}, timeout=10, start_if_needed=False)
        return 0

    show(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
