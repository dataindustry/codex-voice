#!/usr/bin/env python3
"""Small config helper for Codex Voice."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path
from urllib.parse import urlparse, urlunparse
from typing import Any


ROOT = Path.home() / "CodexVoice"
CONFIG_PATH = ROOT / "config" / "config.json"
STATE_DIR = ROOT / "state"
MODEL_TASK_PATH = STATE_DIR / "model-task.json"
DEFAULT_MLX_WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_FASTER_WHISPER_MODEL = "large-v3-turbo"
DEFAULT_OLLAMA_BASE_URL = "http://127.0.0.1:11434"
DEFAULT_OLLAMA_CHAT_URL = f"{DEFAULT_OLLAMA_BASE_URL}/api/chat"
DEFAULT_OLLAMA_NUM_CTX = 4000


def load_config() -> dict[str, Any]:
    with CONFIG_PATH.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise SystemExit(f"Config is not a JSON object: {CONFIG_PATH}")
    return data


def save_config(config: dict[str, Any]) -> None:
    CONFIG_PATH.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temp_path.replace(path)


def write_model_task(
    status: str,
    scope: str,
    label: str,
    detail: str = "",
    progress: float | None = None,
) -> None:
    payload: dict[str, Any] = {
        "status": status,
        "scope": scope,
        "label": label,
        "detail": detail,
        "progress": progress,
        "pid": os.getpid() if status == "running" else None,
        "updated_at": iso_now(),
    }
    if MODEL_TASK_PATH.exists():
        try:
            existing = json.loads(MODEL_TASK_PATH.read_text(encoding="utf-8"))
            if (
                isinstance(existing, dict)
                and existing.get("started_at")
                and existing.get("status") == status
                and existing.get("scope") == scope
                and existing.get("label") == label
            ):
                payload["started_at"] = existing["started_at"]
        except Exception:
            pass
    payload.setdefault("started_at", iso_now())
    write_json_atomic(MODEL_TASK_PATH, payload)


def read_model_task() -> dict[str, Any]:
    if not MODEL_TASK_PATH.exists():
        return {
            "status": "idle",
            "scope": "",
            "label": "空闲",
            "detail": "",
            "progress": None,
            "pid": None,
            "updated_at": iso_now(),
        }
    try:
        data = json.loads(MODEL_TASK_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        return {
            "status": "error",
            "scope": "",
            "label": "模型任务状态不可读",
            "detail": str(exc),
            "progress": None,
            "pid": None,
            "updated_at": iso_now(),
        }
    return data if isinstance(data, dict) else {}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Configure Codex Voice")
    parser.add_argument(
        "--show",
        action="store_true",
        help="Show current configurable values.",
    )
    parser.add_argument(
        "--list-input-devices",
        action="store_true",
        help="List available input devices as JSON.",
    )
    parser.add_argument(
        "--set-input-device",
        help="Set input device by name, or use __default__ for system default.",
    )
    parser.add_argument(
        "--probe-input-device",
        action="store_true",
        help="Open the configured input device briefly and print RMS/peak JSON.",
    )
    parser.add_argument(
        "--set-max-minutes",
        type=float,
        help="Set max recording duration in minutes, e.g. 5.",
    )
    parser.add_argument(
        "--list-ollama-models",
        action="store_true",
        help="List installed Ollama models classified for transcription/correction.",
    )
    parser.add_argument(
        "--set-transcription-profile",
        help="Set transcription profile: mlx-whisper-turbo, faster-whisper-turbo, or ollama-transcription.",
    )
    parser.add_argument(
        "--set-ollama-transcription-model",
        help="Set an installed Ollama model as the transcription backend.",
    )
    parser.add_argument(
        "--set-correction-profile",
        help="Set correction profile: rule-only or ollama-correction.",
    )
    parser.add_argument(
        "--set-ollama-correction-model",
        help="Set an installed Ollama model as the correction backend.",
    )
    parser.add_argument(
        "--prepare-current-transcription-model",
        action="store_true",
        help="Download/load the currently selected transcription model and report progress.",
    )
    parser.add_argument(
        "--prepare-current-correction-model",
        action="store_true",
        help="Download/load the currently selected correction model and report progress.",
    )
    parser.add_argument(
        "--unload-current-correction-model",
        action="store_true",
        help="Unload the currently selected correction model from memory when supported.",
    )
    parser.add_argument(
        "--unload-ollama-model",
        help="Unload the named Ollama model from memory.",
    )
    parser.add_argument(
        "--model-task-status",
        action="store_true",
        help="Show the current model preparation task state as JSON.",
    )
    return parser.parse_args()


def show(config: dict[str, Any]) -> None:
    max_seconds = int(config.get("background_max_record_seconds", config.get("max_record_seconds", 300)))
    print(f"Codex Voice installed at: {ROOT}")
    print(f"Conda env: {os.environ.get('CODEX_VOICE_CONDA_ENV', 'codex-voice')}")
    print(f"Python: {os.environ.get('CODEX_VOICE_PYTHON', sys.executable)}")
    print(f"Max recording: {max_seconds} seconds ({max_seconds / 60:g} minutes)")
    print(f"Input device: {config.get('input_device') or 'system default'}")
    print(f"Transcription profile: {transcription_profile(config)}")
    print(f"Transcription model: {config.get('whisper_backend')} / {config.get('whisper_model')}")
    if config.get("ollama_transcription_model"):
        print(f"Ollama transcription model: {config.get('ollama_transcription_model')}")
    print(f"Correction profile: {correction_profile(config)}")
    print(f"Correction model: {config.get('correction_backend')} / {config.get('ollama_model') or '(none)'}")
    print(f"Output language: {config.get('output_language', 'zh-Hans+en')}")
    print(f"Config file: {CONFIG_PATH}")


def transcription_profile(config: dict[str, Any]) -> str:
    configured = str(config.get("transcription_profile") or "").strip()
    if configured:
        return configured

    backend = str(config.get("whisper_backend", "mlx-whisper"))
    if backend == "mlx-whisper":
        return "mlx-whisper-turbo"
    if backend == "faster-whisper":
        return "faster-whisper-turbo"
    if backend == "ollama":
        return "ollama-transcription"
    return backend or "mlx-whisper-turbo"


def correction_profile(config: dict[str, Any]) -> str:
    configured = str(config.get("correction_profile") or "").strip()
    if configured:
        return configured

    backend = str(config.get("correction_backend", "ollama"))
    if backend == "ollama":
        return "ollama-correction"
    if backend in {"rule-only", "none"}:
        return "rule-only"
    return backend or "rule-only"


def normalize_ollama_host(value: str) -> str:
    value = value.strip().rstrip("/")
    if not value:
        return ""
    if "://" not in value:
        value = f"http://{value}"
    parsed = urlparse(value)
    if parsed.scheme and parsed.netloc:
        return urlunparse((parsed.scheme, parsed.netloc, "", "", "", "")).rstrip("/")
    return ""


def base_url_from_chat_url(value: str) -> str:
    parsed = urlparse(value.strip())
    if parsed.scheme and parsed.netloc:
        return urlunparse((parsed.scheme, parsed.netloc, "", "", "", "")).rstrip("/")
    return ""


def launchctl_getenv(name: str) -> str:
    try:
        result = subprocess.run(
            ["/bin/launchctl", "getenv", name],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except Exception:
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def configured_ollama_base_url(config: dict[str, Any]) -> str:
    configured = normalize_ollama_host(str(config.get("ollama_base_url") or ""))
    if configured and configured != DEFAULT_OLLAMA_BASE_URL:
        return configured

    configured_chat = base_url_from_chat_url(str(config.get("ollama_url") or ""))
    if configured_chat and configured_chat != DEFAULT_OLLAMA_BASE_URL:
        return configured_chat
    return ""


def ollama_base_url(config: dict[str, Any]) -> str:
    configured = configured_ollama_base_url(config)
    if configured:
        return configured

    host = normalize_ollama_host(os.environ.get("OLLAMA_HOST", ""))
    if host:
        return host

    host = normalize_ollama_host(launchctl_getenv("OLLAMA_HOST"))
    if host:
        return host

    return DEFAULT_OLLAMA_BASE_URL


def ollama_chat_url(config: dict[str, Any]) -> str:
    configured = str(config.get("ollama_url") or "").strip()
    configured_base = base_url_from_chat_url(configured)
    if configured and configured_base and configured_base != DEFAULT_OLLAMA_BASE_URL:
        return configured
    return f"{ollama_base_url(config)}/api/chat"


def ollama_env(config: dict[str, Any]) -> dict[str, str]:
    environment = os.environ.copy()
    parsed = urlparse(ollama_base_url(config))
    if parsed.netloc:
        environment["OLLAMA_HOST"] = parsed.netloc
    return environment


def ollama_num_ctx(config: dict[str, Any]) -> int:
    try:
        return int(config.get("ollama_num_ctx", DEFAULT_OLLAMA_NUM_CTX))
    except (TypeError, ValueError):
        return DEFAULT_OLLAMA_NUM_CTX


def read_ollama_json(config: dict[str, Any], path: str, timeout: float = 3) -> dict[str, Any]:
    with urllib.request.urlopen(f"{ollama_base_url(config)}{path}", timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def wait_for_ollama(config: dict[str, Any], timeout: float) -> tuple[bool, str]:
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() <= deadline:
        try:
            read_ollama_json(config, "/api/tags", timeout=2)
            return True, ""
        except Exception as exc:
            last_error = str(exc)
            time.sleep(0.4)
    return False, last_error


def start_ollama(config: dict[str, Any]) -> tuple[bool, str]:
    ollama_path = shutil.which("ollama")
    if not ollama_path:
        return False, "Ollama CLI is not installed."

    environment = ollama_env(config)
    launch_errors: list[str] = []
    commands = [
        [ollama_path, "launch"],
        ["/usr/bin/open", "-ga", "Ollama"],
    ]
    for command in commands:
        if not Path(command[0]).exists():
            continue
        try:
            subprocess.run(
                command,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=environment,
                timeout=3,
            )
        except Exception as exc:
            launch_errors.append(str(exc))

    try:
        subprocess.Popen(
            [ollama_path, "serve"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            start_new_session=True,
        )
    except Exception as exc:
        launch_errors.append(str(exc))

    if launch_errors:
        return True, "; ".join(launch_errors)
    return True, ""


def ensure_ollama_service(config: dict[str, Any]) -> tuple[bool, str, str]:
    ready, error = wait_for_ollama(config, timeout=0.1)
    if ready:
        return True, "available", ""

    if not shutil.which("ollama"):
        return False, "ollama_not_installed", "Ollama CLI is not installed."

    started, start_error = start_ollama(config)
    if not started:
        return False, "ollama_not_installed", start_error

    ready, error = wait_for_ollama(
        config,
        timeout=float(config.get("ollama_start_timeout_seconds", 12)),
    )
    if ready:
        return True, "available", ""
    detail = error or start_error or "Ollama API did not become ready."
    return False, "service_unavailable", detail


def ollama_post_json(
    config: dict[str, Any],
    path: str,
    payload: dict[str, Any],
    timeout: float = 3,
) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{ollama_base_url(config)}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def ollama_get_json(config: dict[str, Any], path: str) -> dict[str, Any]:
    return read_ollama_json(config, path, timeout=3)


def model_name(model: dict[str, Any]) -> str:
    return str(model.get("model") or model.get("name") or "").strip()


def is_embedding_model(name: str, capabilities: list[str], details: dict[str, Any]) -> bool:
    lower = name.lower()
    family = str(details.get("family", "")).lower()
    families = " ".join(str(item).lower() for item in details.get("families", []))
    if "embedding" in capabilities:
        return True
    return any(token in lower or token in family or token in families for token in (
        "embed",
        "embedding",
        "nomic",
        "bge",
        "e5",
    ))


def is_name_based_audio_candidate(name: str) -> bool:
    lower = name.lower()
    return any(token in lower for token in ("whisper", "asr", "speech", "transcribe"))


def classify_ollama_model(config: dict[str, Any], model: dict[str, Any]) -> dict[str, Any]:
    name = model_name(model)
    show: dict[str, Any] = {}
    if name:
        try:
            show = ollama_post_json(config, "/api/show", {"model": name, "verbose": True})
        except Exception:
            show = {}

    capabilities = [str(item).lower() for item in show.get("capabilities", [])]
    details = show.get("details") if isinstance(show.get("details"), dict) else model.get("details", {})
    if not isinstance(details, dict):
        details = {}
    embedding = is_embedding_model(name, capabilities, details)
    audio_capable = "audio" in capabilities
    name_audio_candidate = is_name_based_audio_candidate(name)
    transcription_candidate = (audio_capable or name_audio_candidate) and not embedding
    correction_candidate = "completion" in capabilities and not embedding

    return {
        "name": name,
        "size": model.get("size"),
        "modified_at": model.get("modified_at"),
        "capabilities": capabilities,
        "details": details,
        "transcription_candidate": transcription_candidate,
        "transcription_needs_test": transcription_candidate and not audio_capable,
        "correction_candidate": correction_candidate,
    }


def list_ollama_models(config: dict[str, Any]) -> None:
    service_ready, status, service_error = ensure_ollama_service(config)
    base_url = ollama_base_url(config)
    configured_correction_model = str(config.get("ollama_model", "") or "")
    if not service_ready:
        payload = {
            "available": False,
            "status": status,
            "error": service_error,
            "base_url": base_url,
            "models": [],
            "transcription_models": [],
            "correction_models": [],
            "configured_correction_model": configured_correction_model,
            "configured_correction_model_installed": False,
            "configured_correction_model_loaded": False,
        }
        print(json.dumps(payload, ensure_ascii=False))
        return

    try:
        tags = ollama_get_json(config, "/api/tags")
        models = tags.get("models", [])
        if not isinstance(models, list):
            models = []
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(json.dumps({
            "available": False,
            "status": "service_unavailable",
            "error": str(exc),
            "base_url": base_url,
            "models": [],
            "transcription_models": [],
            "correction_models": [],
            "configured_correction_model": configured_correction_model,
            "configured_correction_model_installed": False,
            "configured_correction_model_loaded": False,
        }, ensure_ascii=False))
        return

    classified = [
        classify_ollama_model(config, model)
        for model in models
        if isinstance(model, dict) and model_name(model)
    ]
    loaded_names: set[str] = set()
    try:
        running = ollama_get_json(config, "/api/ps")
        running_models = running.get("models", [])
        if isinstance(running_models, list):
            loaded_names = {
                model_name(item)
                for item in running_models
                if isinstance(item, dict) and model_name(item)
            }
    except Exception:
        loaded_names = set()
    for item in classified:
        item["loaded"] = item["name"] in loaded_names
    transcription_models = [item for item in classified if item["transcription_candidate"]]
    correction_models = [item for item in classified if item["correction_candidate"]]
    configured_installed = any(item["name"] == configured_correction_model for item in classified)
    configured_loaded = configured_correction_model in loaded_names
    payload = {
        "available": True,
        "status": "available",
        "error": "",
        "base_url": base_url,
        "models": classified,
        "transcription_models": transcription_models,
        "correction_models": correction_models,
        "configured_correction_model": configured_correction_model,
        "configured_correction_model_installed": configured_installed,
        "configured_correction_model_loaded": configured_loaded,
    }
    print(json.dumps(payload, ensure_ascii=False))


def set_transcription_profile(config: dict[str, Any], profile: str) -> str:
    profile = profile.strip()
    if profile == "mlx-whisper-turbo":
        config["transcription_profile"] = profile
        config["whisper_backend"] = "mlx-whisper"
        config["whisper_model"] = DEFAULT_MLX_WHISPER_MODEL
        config["whisper_fallback_backend"] = "faster-whisper"
        config["whisper_fallback_model"] = DEFAULT_FASTER_WHISPER_MODEL
        config["setup_profile"] = "custom"
        return "MLX Whisper large-v3-turbo"
    if profile == "faster-whisper-turbo":
        config["transcription_profile"] = profile
        config["whisper_backend"] = "faster-whisper"
        config["whisper_model"] = DEFAULT_FASTER_WHISPER_MODEL
        config["whisper_fallback_backend"] = "mlx-whisper"
        config["whisper_fallback_model"] = DEFAULT_MLX_WHISPER_MODEL
        config["setup_profile"] = "custom"
        return "faster-whisper large-v3-turbo"
    if profile == "ollama-transcription":
        model = str(config.get("ollama_transcription_model") or "").strip()
        if not model:
            raise SystemExit("Choose an Ollama transcription model first.")
        return set_ollama_transcription_model(config, model)
    raise SystemExit(f"Unsupported transcription profile: {profile}")


def set_ollama_transcription_model(config: dict[str, Any], model: str) -> str:
    model = model.strip()
    if not model:
        raise SystemExit("Ollama transcription model name cannot be empty.")
    config["transcription_profile"] = "ollama-transcription"
    config["whisper_backend"] = "ollama"
    config["whisper_model"] = model
    config["ollama_transcription_model"] = model
    config["whisper_fallback_backend"] = "mlx-whisper"
    config["whisper_fallback_model"] = DEFAULT_MLX_WHISPER_MODEL
    config["setup_profile"] = "custom"
    return model


def set_correction_profile(config: dict[str, Any], profile: str) -> str:
    profile = profile.strip()
    if profile == "rule-only":
        config["correction_profile"] = profile
        config["correction_backend"] = "rule-only"
        config["setup_profile"] = "custom"
        return "规则纠错"
    if profile == "ollama-correction":
        model = str(config.get("ollama_model") or "").strip()
        if not model:
            raise SystemExit("Choose an Ollama correction model first.")
        return set_ollama_correction_model(config, model)
    raise SystemExit(f"Unsupported correction profile: {profile}")


def set_ollama_correction_model(config: dict[str, Any], model: str) -> str:
    model = model.strip()
    if not model:
        raise SystemExit("Ollama correction model name cannot be empty.")
    config["correction_profile"] = "ollama-correction"
    config["correction_backend"] = "ollama"
    config["ollama_model"] = model
    config["setup_profile"] = "custom"
    return model


def create_silent_wav(path: Path, sample_rate: int = 16000, seconds: float = 0.3) -> None:
    frames = int(sample_rate * seconds)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"\x00\x00" * frames)


def prepare_current_transcription_model(config: dict[str, Any]) -> None:
    backend = str(config.get("whisper_backend", "mlx-whisper"))
    model = str(config.get("whisper_model", ""))
    if backend == "ollama":
        model = str(config.get("ollama_transcription_model") or model)

    label = f"准备转录模型：{model or backend}"
    write_model_task("running", "transcription", label, "正在检查模型配置", 0.05)
    try:
        if backend == "mlx-whisper":
            write_model_task("running", "transcription", label, "正在下载或加载 MLX Whisper 模型", None)
            import mlx_whisper

            with tempfile.TemporaryDirectory(prefix="codex-voice-model-") as directory:
                audio_path = Path(directory) / "silence.wav"
                create_silent_wav(audio_path)
                try:
                    mlx_whisper.transcribe(
                        str(audio_path),
                        path_or_hf_repo=model,
                        language=str(config.get("whisper_language", "zh")),
                        task=str(config.get("whisper_task", "transcribe")),
                        verbose=False,
                    )
                except TypeError:
                    mlx_whisper.transcribe(
                        str(audio_path),
                        model,
                        language=str(config.get("whisper_language", "zh")),
                        task=str(config.get("whisper_task", "transcribe")),
                        verbose=False,
                    )
        elif backend == "faster-whisper":
            write_model_task("running", "transcription", label, "正在下载或加载 faster-whisper 模型", None)
            from faster_whisper import WhisperModel

            WhisperModel(
                model,
                device=str(config.get("faster_whisper_device", "cpu")),
                compute_type=str(config.get("faster_whisper_compute_type", "int8")),
            )
        elif backend == "ollama":
            if not model:
                raise RuntimeError("No Ollama transcription model is selected.")
            service_ready, _status, service_error = ensure_ollama_service(config)
            if not service_ready:
                raise RuntimeError(f"Ollama service is not ready: {service_error}")
            write_model_task("running", "transcription", label, "正在调用 Ollama 音频转录接口预热", None)
            try:
                import requests
            except ImportError as exc:
                raise RuntimeError("requests is not installed.") from exc
            with tempfile.TemporaryDirectory(prefix="codex-voice-model-") as directory:
                audio_path = Path(directory) / "silence.wav"
                create_silent_wav(audio_path)
                with audio_path.open("rb") as handle:
                    response = requests.post(
                        f"{ollama_base_url(config)}/v1/audio/transcriptions",
                        data={"model": model, "response_format": "json", "temperature": "0"},
                        files={"file": (audio_path.name, handle, "audio/wav")},
                        timeout=float(config.get("ollama_transcription_timeout_seconds", 120)),
                    )
                if response.status_code >= 400:
                    raise RuntimeError(response.text[:400])
        else:
            raise RuntimeError(f"Unsupported transcription backend: {backend}")
        write_model_task("succeeded", "transcription", label, "模型已准备好", 1.0)
    except Exception as exc:
        write_model_task("failed", "transcription", label, str(exc), None)
        raise


def prepare_current_correction_model(config: dict[str, Any]) -> None:
    backend = str(config.get("correction_backend", "ollama"))
    model = str(config.get("ollama_model", "")) if backend == "ollama" else backend
    label = f"准备纠错模型：{model or backend}"
    write_model_task("running", "correction", label, "正在检查模型配置", 0.05)
    try:
        if backend in {"rule-only", "none"}:
            write_model_task("succeeded", "correction", "规则纠错", "无需加载模型", 1.0)
            return
        if backend == "ollama":
            if not model:
                raise RuntimeError("No Ollama correction model is selected.")
            service_ready, _status, service_error = ensure_ollama_service(config)
            if not service_ready:
                raise RuntimeError(f"Ollama service is not ready: {service_error}")
            write_model_task("running", "correction", label, "正在让 Ollama 加载模型到内存", None)
            payload = {
                "model": model,
                "messages": [
                    {"role": "user", "content": "ping"}
                ],
                "stream": False,
                "think": bool(config.get("ollama_think", False)),
                "keep_alive": config.get("ollama_keep_alive", -1),
                "options": {
                    "temperature": 0,
                    "num_predict": 1,
                    "num_ctx": ollama_num_ctx(config),
                },
            }
            ollama_post_json(
                config,
                "/api/chat",
                payload,
                timeout=float(config.get("ollama_model_prepare_timeout_seconds", 180)),
            )
            write_model_task("succeeded", "correction", label, "模型已加载到内存", 1.0)
            return
        raise RuntimeError(f"Unsupported correction backend: {backend}")
    except Exception as exc:
        write_model_task("failed", "correction", label, str(exc), None)
        raise


def unload_ollama_model(config: dict[str, Any], model: str, scope: str = "correction") -> None:
    model = model.strip()
    label = f"卸载模型：{model}"
    write_model_task("running", scope, label, "正在从内存卸载模型", None)
    try:
        if not model:
            raise RuntimeError("Ollama model name cannot be empty.")
        service_ready, _status, service_error = ensure_ollama_service(config)
        if not service_ready:
            raise RuntimeError(f"Ollama service is not ready: {service_error}")
        ollama_post_json(
            config,
            "/api/generate",
            {"model": model, "prompt": "", "stream": False, "keep_alive": 0},
            timeout=30,
        )
        write_model_task("succeeded", scope, label, "模型已从内存卸载", 1.0)
        return
    except Exception as exc:
        write_model_task("failed", scope, label, str(exc), None)
        raise


def unload_current_correction_model(config: dict[str, Any]) -> None:
    backend = str(config.get("correction_backend", "ollama"))
    model = str(config.get("ollama_model", "")) if backend == "ollama" else backend
    if backend in {"rule-only", "none"}:
        write_model_task("succeeded", "correction", "规则纠错", "无需卸载模型", 1.0)
        return
    if backend == "ollama":
        if not model:
            raise RuntimeError("No Ollama correction model is selected.")
        unload_ollama_model(config, model, scope="correction")
        return
    raise RuntimeError(f"Unsupported correction backend: {backend}")


def default_input_index(sd: Any) -> int | None:
    default_device = sd.default.device
    if isinstance(default_device, (list, tuple)) or hasattr(default_device, "__getitem__"):
        value = default_device[0] if default_device else None
    else:
        value = default_device
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
    devices = []
    for index, device in enumerate(sd.query_devices()):
        if int(device.get("max_input_channels", 0)) <= 0:
            continue
        name = str(device.get("name", ""))
        devices.append(
            {
                "index": index,
                "name": name,
                "default": index == default_index,
                "channels": int(device.get("max_input_channels", 0)),
            }
        )

    payload = {
        "configured": config.get("input_device"),
        "devices": devices,
    }
    print(json.dumps(payload, ensure_ascii=False))


def resolve_input_device_for_probe(config: dict[str, Any], sd: Any) -> int | str | None:
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
    payload = {
        "device": "system default" if device is None else device,
        "rms": rms,
        "peak": peak,
        "overflowed": bool(overflowed),
    }
    print(json.dumps(payload, ensure_ascii=False))


def main() -> int:
    args = parse_args()
    config = load_config()

    if args.model_task_status:
        print(json.dumps(read_model_task(), ensure_ascii=False))
        return 0

    if args.list_input_devices:
        list_input_devices(config)
        return 0

    if args.probe_input_device:
        probe_input_device(config)
        return 0

    if args.list_ollama_models:
        list_ollama_models(config)
        return 0

    if args.set_input_device is not None:
        value = args.set_input_device.strip()
        if value in {"", "__default__", "default", "system", "auto"}:
            config["input_device"] = None
            label = "system default"
        else:
            config["input_device"] = value
            label = value
        save_config(config)
        print(f"Codex Voice input device set to: {label}")
        return 0

    if args.set_max_minutes is not None:
        minutes = args.set_max_minutes
        if minutes <= 0:
            raise SystemExit("Max recording minutes must be greater than 0.")
        if minutes > 10:
            raise SystemExit("Refusing to set more than 10 minutes from Raycast helper.")

        seconds = int(round(minutes * 60))
        config["max_record_seconds"] = seconds
        config["background_max_record_seconds"] = seconds
        save_config(config)
        print(f"Codex Voice max recording set to {seconds} seconds ({minutes:g} minutes).")
        return 0

    if args.set_transcription_profile is not None:
        label = set_transcription_profile(config, args.set_transcription_profile)
        save_config(config)
        print(f"Codex Voice transcription profile set to: {label}")
        return 0

    if args.set_ollama_transcription_model is not None:
        label = set_ollama_transcription_model(config, args.set_ollama_transcription_model)
        save_config(config)
        print(f"Codex Voice Ollama transcription model set to: {label}")
        return 0

    if args.set_correction_profile is not None:
        label = set_correction_profile(config, args.set_correction_profile)
        save_config(config)
        print(f"Codex Voice correction profile set to: {label}")
        return 0

    if args.set_ollama_correction_model is not None:
        label = set_ollama_correction_model(config, args.set_ollama_correction_model)
        save_config(config)
        print(f"Codex Voice Ollama correction model set to: {label}")
        return 0

    if args.prepare_current_transcription_model:
        prepare_current_transcription_model(config)
        print("Codex Voice transcription model is ready.")
        return 0

    if args.prepare_current_correction_model:
        prepare_current_correction_model(config)
        print("Codex Voice correction model is ready.")
        return 0

    if args.unload_current_correction_model:
        unload_current_correction_model(config)
        print("Codex Voice correction model was unloaded from memory.")
        return 0

    if args.unload_ollama_model is not None:
        unload_ollama_model(config, args.unload_ollama_model)
        print(f"Codex Voice Ollama model was unloaded: {args.unload_ollama_model}")
        return 0

    show(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
