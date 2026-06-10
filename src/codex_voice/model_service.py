"""Persistent Unix-socket service for local MLX speech and text models."""

from __future__ import annotations

import argparse
import gc
import json
import signal
import socketserver
import threading
from pathlib import Path
from typing import Any

from codex_voice.model_catalog import MODEL_BY_ID, model_is_installed, model_path
from codex_voice.paths import AppPaths, paths_for_root


class ModelRuntime:
    def __init__(self, paths: AppPaths) -> None:
        self.paths = paths
        self.lock = threading.Lock()
        self.qwen_asr_sessions: dict[str, Any] = {}
        self.correction_models: dict[str, tuple[Any, Any]] = {}
        self.loaded_whisper_ids: set[str] = set()

    def loaded_ids(self) -> set[str]:
        return (
            set(self.qwen_asr_sessions)
            | set(self.correction_models)
            | self.loaded_whisper_ids
        )

    def require_installed(self, model_id: str) -> Path:
        if model_id not in MODEL_BY_ID:
            raise ValueError(f"Unknown model id: {model_id}")
        if not model_is_installed(self.paths, model_id):
            raise FileNotFoundError(
                f"Model is not installed: {model_id}. Download it from ModelScope first."
            )
        return model_path(self.paths, model_id)

    def load(self, model_id: str) -> None:
        spec = MODEL_BY_ID.get(model_id)
        path = self.require_installed(model_id)
        if spec is None:
            raise ValueError(f"Unknown model id: {model_id}")
        if spec.role == "direct_asr":
            if model_id not in self.qwen_asr_sessions:
                from mlx_qwen3_asr import Session

                self.qwen_asr_sessions[model_id] = Session(model=str(path))
            return
        if spec.role == "transcription":
            if model_id not in self.loaded_whisper_ids:
                import importlib

                module = importlib.import_module("mlx_whisper.transcribe")
                module.ModelHolder.get_model(str(path), module.mx.float16)
                self.loaded_whisper_ids.add(model_id)
            return
        if spec.role == "correction":
            if model_id not in self.correction_models:
                from mlx_lm import load

                loaded = load(str(path))
                self.correction_models[model_id] = (loaded[0], loaded[1])
            return
        raise ValueError(f"Unsupported model role: {spec.role}")

    def unload(self, model_id: str) -> None:
        spec = MODEL_BY_ID.get(model_id)
        if spec is None:
            raise ValueError(f"Unknown model id: {model_id}")
        self.qwen_asr_sessions.pop(model_id, None)
        self.correction_models.pop(model_id, None)
        if model_id in self.loaded_whisper_ids:
            import importlib

            module = importlib.import_module("mlx_whisper.transcribe")
            module.ModelHolder.model = None
            module.ModelHolder.model_path = None
            self.loaded_whisper_ids.discard(model_id)
        gc.collect()
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:
            pass

    def transcribe(
        self,
        model_id: str,
        audio_path: str,
        language: str | None,
        context: str,
    ) -> dict[str, Any]:
        spec = MODEL_BY_ID.get(model_id)
        if spec is None:
            raise ValueError(f"Unknown model id: {model_id}")
        self.load(model_id)
        if spec.role == "direct_asr":
            result = self.qwen_asr_sessions[model_id].transcribe(
                audio_path,
                language=language,
                context=context or None,
            )
            return {
                "text": str(result.text).strip(),
                "language": str(result.language or ""),
            }
        if spec.role == "transcription":
            import mlx_whisper

            result = mlx_whisper.transcribe(
                audio_path,
                path_or_hf_repo=str(model_path(self.paths, model_id)),
                language=language,
                task="transcribe",
                initial_prompt=context or None,
                verbose=False,
            )
            return {
                "text": str(result.get("text", "") if isinstance(result, dict) else result).strip(),
                "language": language or "",
            }
        raise ValueError(f"Model does not support transcription: {model_id}")

    def correct(
        self,
        model_id: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int,
    ) -> str:
        spec = MODEL_BY_ID.get(model_id)
        if spec is None or spec.role != "correction":
            raise ValueError(f"Model does not support correction: {model_id}")
        self.load(model_id)
        model, tokenizer = self.correction_models[model_id]
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]
        template_kwargs: dict[str, Any] = {
            "tokenize": False,
            "add_generation_prompt": True,
        }
        try:
            prompt = tokenizer.apply_chat_template(
                messages,
                enable_thinking=False,
                **template_kwargs,
            )
        except TypeError:
            prompt = tokenizer.apply_chat_template(messages, **template_kwargs)
        from mlx_lm import generate

        return str(
            generate(
                model,
                tokenizer,
                prompt=prompt,
                max_tokens=max_tokens,
                verbose=False,
            )
        ).strip()

    def handle(self, request: dict[str, Any]) -> dict[str, Any]:
        action = str(request.get("action") or "")
        with self.lock:
            if action == "ping":
                return {"ok": True, "loaded_model_ids": sorted(self.loaded_ids())}
            if action == "status":
                return {"ok": True, "loaded_model_ids": sorted(self.loaded_ids())}
            if action == "load":
                model_id = str(request.get("model_id") or "")
                self.load(model_id)
                return {"ok": True, "loaded_model_ids": sorted(self.loaded_ids())}
            if action == "unload":
                model_id = str(request.get("model_id") or "")
                self.unload(model_id)
                return {"ok": True, "loaded_model_ids": sorted(self.loaded_ids())}
            if action == "transcribe":
                result = self.transcribe(
                    str(request.get("model_id") or ""),
                    str(request.get("audio_path") or ""),
                    str(request["language"]) if request.get("language") else None,
                    str(request.get("context") or ""),
                )
                return {"ok": True, **result}
            if action == "correct":
                text = self.correct(
                    str(request.get("model_id") or ""),
                    str(request.get("system_prompt") or ""),
                    str(request.get("user_prompt") or ""),
                    int(request.get("max_tokens") or 256),
                )
                return {"ok": True, "text": text}
            if action == "shutdown":
                return {"ok": True, "shutdown": True}
        raise ValueError(f"Unsupported model service action: {action}")


class RequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        server = self.server
        if not isinstance(server, ModelServer):
            return
        raw = self.rfile.readline(4 * 1024 * 1024)
        try:
            request = json.loads(raw.decode("utf-8"))
            if not isinstance(request, dict):
                raise ValueError("Request must be a JSON object.")
            response = server.runtime.handle(request)
        except Exception as exc:
            response = {"ok": False, "error": str(exc)}
        self.wfile.write(json.dumps(response, ensure_ascii=False).encode("utf-8") + b"\n")
        self.wfile.flush()
        if response.get("shutdown"):
            threading.Thread(target=server.shutdown, daemon=True).start()


class ModelServer(socketserver.UnixStreamServer):
    def __init__(self, socket_path: Path, runtime: ModelRuntime) -> None:
        self.runtime = runtime
        socket_path.parent.mkdir(parents=True, exist_ok=True)
        socket_path.unlink(missing_ok=True)
        super().__init__(str(socket_path), RequestHandler)
        socket_path.chmod(0o600)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Codex Voice persistent MLX model service")
    parser.add_argument("--root", type=Path, default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    paths = paths_for_root(args.root)
    paths.ensure_dirs()
    server = ModelServer(paths.model_service_socket_path, ModelRuntime(paths))

    def stop(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        paths.model_service_socket_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
