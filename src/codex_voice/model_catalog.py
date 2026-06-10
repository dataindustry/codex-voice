"""Local model catalog and ModelScope-backed storage."""

from __future__ import annotations

import json
import threading
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from codex_voice.paths import AppPaths


@dataclass(frozen=True)
class ModelSpec:
    id: str
    name: str
    role: str
    model_type: str
    source_repo: str
    relative_path: str
    parameter_size: str
    architecture: str
    vendor: str
    quantization: str


MODEL_SPECS = (
    ModelSpec(
        id="qwen3-asr-1.7b-8bit",
        name="Qwen3-ASR-1.7B-8bit",
        role="direct_asr",
        model_type="direct_asr",
        source_repo="mlx-community/Qwen3-ASR-1.7B-8bit",
        relative_path="transcription/qwen3-asr-1.7b-8bit",
        parameter_size="1.7B",
        architecture="Qwen3-ASR",
        vendor="MLX Community",
        quantization="8-bit",
    ),
    ModelSpec(
        id="whisper-large-v3-turbo",
        name="Whisper large-v3-turbo",
        role="transcription",
        model_type="transcription",
        source_repo="mlx-community/whisper-large-v3-turbo",
        relative_path="transcription/whisper-large-v3-turbo",
        parameter_size="809M",
        architecture="Whisper Transformer",
        vendor="MLX Community",
        quantization="FP16",
    ),
    ModelSpec(
        id="qwen3.6-35b-a3b-4bit",
        name="Qwen3.6-35B-A3B-4bit",
        role="correction",
        model_type="text_correction",
        source_repo="mlx-community/Qwen3.6-35B-A3B-4bit",
        relative_path="correction/qwen3.6-35b-a3b-4bit",
        parameter_size="35B-A3B",
        architecture="Qwen3.6 MoE",
        vendor="Qwen / MLX",
        quantization="4-bit",
    ),
)

MODEL_BY_ID = {spec.id: spec for spec in MODEL_SPECS}

DEFAULT_DIRECT_ASR_MODEL = "qwen3-asr-1.7b-8bit"
LEGACY_MODEL_ID_ALIASES = {
    "qwen3-asr-1.7b": DEFAULT_DIRECT_ASR_MODEL,
}
DEFAULT_TRANSCRIPTION_MODEL = "whisper-large-v3-turbo"
DEFAULT_CORRECTION_MODEL = "qwen3.6-35b-a3b-4bit"


def canonical_model_id(model_id: str) -> str:
    return LEGACY_MODEL_ID_ALIASES.get(model_id, model_id)


def model_path(paths: AppPaths, model_id: str) -> Path:
    model_id = canonical_model_id(model_id)
    try:
        spec = MODEL_BY_ID[model_id]
    except KeyError as exc:
        raise ValueError(f"Unknown model id: {model_id}") from exc
    return paths.models_dir / spec.relative_path


def model_is_installed(paths: AppPaths, model_id: str) -> bool:
    model_id = canonical_model_id(model_id)
    path = model_path(paths, model_id)
    if not path.is_dir() or not (path / "config.json").is_file():
        return False

    index_path = path / "model.safetensors.index.json"
    if index_path.is_file():
        try:
            payload = json.loads(index_path.read_text(encoding="utf-8"))
            weight_map = payload.get("weight_map", {})
            shards = {str(value) for value in weight_map.values()}
        except (OSError, ValueError, AttributeError):
            return False
        return bool(shards) and all((path / shard).is_file() for shard in shards)

    return any(path.glob("*.safetensors")) or (path / "weights.npz").is_file()


def model_size_bytes(paths: AppPaths, model_id: str) -> int | None:
    model_id = canonical_model_id(model_id)
    path = model_path(paths, model_id)
    if not path.is_dir():
        return None
    try:
        return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())
    except OSError:
        return None


def catalog_payload(
    paths: AppPaths,
    loaded_model_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    loaded = loaded_model_ids or set()
    payload: list[dict[str, Any]] = []
    for spec in MODEL_SPECS:
        item = asdict(spec)
        item.update(
            {
                "path": str(model_path(paths, spec.id)),
                "installed": model_is_installed(paths, spec.id),
                "loaded": spec.id in loaded,
                "size": model_size_bytes(paths, spec.id),
            }
        )
        payload.append(item)
    return payload


def download_model(
    paths: AppPaths,
    model_id: str,
    progress_callback: Callable[[float], None] | None = None,
) -> Path:
    """Download one complete model snapshot from ModelScope."""

    try:
        from modelscope import snapshot_download
        from modelscope.hub.api import HubApi
        from modelscope.hub.callback import ProgressCallback
    except ImportError as exc:
        raise RuntimeError("ModelScope is not installed. Run bin/install.sh first.") from exc

    model_id = canonical_model_id(model_id)
    spec = MODEL_BY_ID.get(model_id)
    if spec is None:
        raise ValueError(f"Unknown model id: {model_id}")
    destination = model_path(paths, model_id)
    destination.parent.mkdir(parents=True, exist_ok=True)

    callbacks: list[type[ProgressCallback]] | None = None
    if progress_callback is not None:
        report_progress = progress_callback
        total_size = 0
        completed_size = 0
        try:
            files = HubApi().get_model_files(
                spec.source_repo,
                recursive=True,
                use_cookies=False,
            )
            for item in files:
                if item.get("Type") != "blob":
                    continue
                size = int(item.get("Size") or 0)
                total_size += size
                relative_path = str(item.get("Path") or item.get("Name") or "")
                local_file = destination / relative_path
                if size > 0 and local_file.is_file() and local_file.stat().st_size == size:
                    completed_size += size
        except Exception:
            total_size = 0
            completed_size = 0

        state_lock = threading.Lock()
        state = {
            "total": total_size,
            "completed": completed_size,
            "observed_total": 0,
        }

        class AggregateProgress(ProgressCallback):
            def __init__(self, filename: str, file_size: int):
                super().__init__(filename, file_size)
                self.transferred = 0
                with state_lock:
                    state["observed_total"] += max(0, file_size)

            def update(self, size: int) -> None:
                increment = max(0, size)
                with state_lock:
                    self.transferred += increment
                    state["completed"] += increment
                    denominator = state["total"] or state["observed_total"]
                    progress = (
                        min(0.99, state["completed"] / denominator)
                        if denominator > 0
                        else 0.0
                    )
                report_progress(progress)

            def end(self) -> None:
                with state_lock:
                    missing = max(0, self.file_size - self.transferred)
                    self.transferred += missing
                    state["completed"] += missing
                    denominator = state["total"] or state["observed_total"]
                    progress = (
                        min(0.99, state["completed"] / denominator)
                        if denominator > 0
                        else 0.0
                    )
                report_progress(progress)

        callbacks = [AggregateProgress]
        report_progress(
            min(0.99, completed_size / total_size) if total_size > 0 else 0.0
        )

    snapshot_download(
        spec.source_repo,
        local_dir=str(destination),
        progress_callbacks=callbacks,
    )
    if not model_is_installed(paths, model_id):
        raise RuntimeError(f"ModelScope download did not produce a valid model: {destination}")
    if progress_callback is not None:
        progress_callback(1.0)
    return destination
