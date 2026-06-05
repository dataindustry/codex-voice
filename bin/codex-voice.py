#!/usr/bin/env python3
"""Codex Voice Input.

Record one short utterance, transcribe it locally, correct developer terms, and
copy or paste the final text into the frontmost macOS app.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse, urlunparse
import wave
from collections import deque
from contextlib import contextmanager
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any


HOME = Path.home()
ROOT = HOME / "CodexVoice"
BIN_DIR = ROOT / "bin"
CONFIG_DIR = ROOT / "config"
RECORDINGS_DIR = ROOT / "recordings"
TRANSCRIPTS_DIR = ROOT / "transcripts"
LOGS_DIR = ROOT / "logs"
STATE_DIR = ROOT / "state"

CONFIG_PATH = CONFIG_DIR / "config.json"
TERMS_PATH = CONFIG_DIR / "terms.json"
PROMPT_PATH = CONFIG_DIR / "correction_prompt.txt"
LOG_PATH = LOGS_DIR / "codex-voice.log"
PID_PATH = STATE_DIR / "recording.pid"
INDICATOR_PID_PATH = STATE_DIR / "indicator.pid"
SUBMIT_REQUEST_PATH = STATE_DIR / "submit.request"
STATUS_PATH = STATE_DIR / "status.json"
LOCK_PATH = STATE_DIR / "state.lock"
PASTE_REQUEST_PATH = STATE_DIR / "paste.request"
PASTE_RESULT_PATH = STATE_DIR / "paste.result"
RUNTIME_PATHS = (
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
)
DEFAULT_OLLAMA_BASE_URL = "http://127.0.0.1:11434"
DEFAULT_OLLAMA_CHAT_URL = f"{DEFAULT_OLLAMA_BASE_URL}/api/chat"
DEFAULT_OLLAMA_NUM_CTX = 4000


DEFAULT_CONFIG: dict[str, Any] = {
    "sample_rate": 16000,
    "channels": 1,
    "input_device": None,
    "max_record_seconds": 300,
    "background_max_record_seconds": 300,
    "start_timeout_seconds": 6,
    "min_record_seconds": 0.4,
    "silence_seconds": 1.0,
    "silence_threshold": 0.006,
    "min_audio_rms": 0.0048,
    "min_audio_peak": 0.02,
    "frame_seconds": 0.08,
    "pre_speech_padding_seconds": 0.3,
    "reject_repeated_hallucinations": True,
    "manual_submit_enabled": True,
    "background_manual_submit_required": True,
    "notify_status": False,
    "recording_indicator": True,
    "paste_requires_editable_focus": True,
    "clipboard_fallback_app_allowlist": ["Codex", "OpenCode"],
    "setup_profile": "recommended",
    "transcription_profile": "mlx-whisper-turbo",
    "whisper_backend": "mlx-whisper",
    "whisper_model": "mlx-community/whisper-large-v3-turbo",
    "whisper_fallback_backend": "faster-whisper",
    "whisper_fallback_model": "large-v3-turbo",
    "whisper_language": "zh",
    "whisper_task": "transcribe",
    "whisper_beam_size": 5,
    "faster_whisper_device": "cpu",
    "faster_whisper_compute_type": "int8",
    "correction_backend": "ollama",
    "ollama_base_url": "http://127.0.0.1:11434",
    "ollama_transcription_model": "",
    "ollama_transcription_timeout_seconds": 120,
    "ollama_url": "http://127.0.0.1:11434/api/chat",
    "external_api_enabled": False,
    "openai_transcription_model": "",
    "openai_correction_model": "",
    "ollama_model": "qwen3.6:35b-a3b",
    "correction_profile": "ollama-correction",
    "ollama_fallback_models": [],
    "ollama_timeout_seconds": 7,
    "ollama_model_prepare_timeout_seconds": 180,
    "ollama_temperature": 0,
    "ollama_num_predict": 256,
    "ollama_num_ctx": DEFAULT_OLLAMA_NUM_CTX,
    "ollama_think": False,
    "ollama_keep_alive": -1,
    "ollama_clean_context_per_request": True,
    "ollama_skip_simple_utterances": True,
    "ollama_simple_max_chars": 8,
    "ollama_reject_aggressive_rewrite": True,
    "ollama_min_similarity": 0.80,
    "ollama_min_length_ratio": 0.80,
    "ollama_max_length_ratio": 1.20,
    "output_language": "zh-Hans+en",
    "force_simplified_chinese": True,
    "auto_paste": True,
    "save_recordings": True,
    "save_transcripts": True,
    "mode": "normal",
}

STATUS_LABELS = {
    "idle": "空闲",
    "recording": "正在录音",
    "submitting": "正在结束录音",
    "transcribing": "正在识别",
    "correcting": "正在纠错",
    "finalizing": "正在提交文本",
    "error": "出错",
}


class CodexVoiceError(Exception):
    """Base exception for expected operational failures."""


class NoSpeechError(CodexVoiceError):
    """Raised when no useful speech is detected."""


class MissingDependencyError(CodexVoiceError):
    """Raised when an optional runtime dependency is unavailable."""


def ensure_runtime_path() -> None:
    current = os.environ.get("PATH", "")
    parts = [part for part in current.split(os.pathsep) if part]
    for path in reversed(RUNTIME_PATHS):
        if path not in parts:
            parts.insert(0, path)
    os.environ["PATH"] = os.pathsep.join(parts)


def ensure_dirs() -> None:
    for directory in (
        BIN_DIR,
        CONFIG_DIR,
        RECORDINGS_DIR,
        TRANSCRIPTS_DIR,
        LOGS_DIR,
        STATE_DIR,
    ):
        directory.mkdir(parents=True, exist_ok=True)


def setup_logging() -> logging.Logger:
    ensure_dirs()
    logger = logging.getLogger("codex_voice")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    file_handler = logging.FileHandler(LOG_PATH, encoding="utf-8")
    file_handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    )
    logger.addHandler(file_handler)

    stream_handler = logging.StreamHandler(sys.stderr)
    stream_handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(stream_handler)
    return logger


def applescript_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify_status(
    config: dict[str, Any],
    message: str,
    logger: logging.Logger,
    title: str = "Codex Voice",
) -> None:
    if not bool(config.get("notify_status", False)):
        return

    script = (
        "display notification "
        f"{applescript_string(message)} with title {applescript_string(title)}"
    )
    try:
        subprocess.run(
            ["osascript", "-e", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=2,
        )
    except Exception as exc:
        logger.debug("Status notification failed: %s", exc)


def write_status_state(
    status: str,
    detail: str = "",
    pid: int | None = None,
    logger: logging.Logger | None = None,
) -> None:
    ensure_dirs()
    label = STATUS_LABELS.get(status, status)
    if status == "idle" and pid is None:
        status_pid = None
    else:
        status_pid = pid if pid is not None else os.getpid()
    payload = {
        "status": status,
        "label": label,
        "detail": detail,
        "pid": status_pid,
        "updated_at": datetime.now().isoformat(timespec="seconds"),
    }
    temp_path = STATUS_PATH.with_name(f"{STATUS_PATH.name}.{os.getpid()}.tmp")
    try:
        temp_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temp_path.replace(STATUS_PATH)
    except Exception as exc:
        if logger is not None:
            logger.debug("Could not write status state: %s", exc)


def read_status_state() -> dict[str, Any]:
    try:
        status = load_json(STATUS_PATH, {})
    except Exception:
        return {}
    return status if isinstance(status, dict) else {}


def stop_recording_indicator(pid: int | None, logger: logging.Logger) -> None:
    if pid is None:
        try:
            text = INDICATOR_PID_PATH.read_text(encoding="utf-8").strip()
            pid = int(text) if text else None
        except Exception:
            pid = None

    if pid is None:
        INDICATOR_PID_PATH.unlink(missing_ok=True)
        return

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except Exception as exc:
        logger.debug("Could not stop recording indicator %s: %s", pid, exc)
    finally:
        INDICATOR_PID_PATH.unlink(missing_ok=True)


def start_recording_indicator(
    config: dict[str, Any],
    logger: logging.Logger,
    max_seconds: float,
) -> int | None:
    if not bool(config.get("recording_indicator", True)):
        return None

    stop_recording_indicator(None, logger)
    indicator_binary = BIN_DIR / "codex-voice-recording-indicator"
    if not indicator_binary.exists() or not os.access(indicator_binary, os.X_OK):
        logger.warning("Recording indicator is missing: %s", indicator_binary)
        return None
    command = [
        str(indicator_binary),
        "--parent-pid",
        str(os.getpid()),
        "--max-seconds",
        str(max_seconds),
    ]
    try:
        with LOG_PATH.open("a", encoding="utf-8") as log_file:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=log_file,
                stderr=log_file,
                start_new_session=True,
                close_fds=True,
            )
        INDICATOR_PID_PATH.write_text(str(process.pid), encoding="utf-8")
        logger.info("Started recording indicator: %s", process.pid)
        return process.pid
    except Exception as exc:
        logger.warning("Could not start recording indicator: %s", exc)
        return None


@contextmanager
def state_lock():
    ensure_dirs()
    with LOCK_PATH.open("a+", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)


def read_recording_pid() -> int | None:
    try:
        text = PID_PATH.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    except OSError:
        return None

    try:
        pid = int(text)
    except ValueError:
        return None
    return pid if pid > 0 else None


def pid_file_is_fresh() -> bool:
    try:
        return time.time() - PID_PATH.stat().st_mtime < 5
    except OSError:
        return False


def pid_looks_like_codex_voice(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "command="],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
    except Exception:
        return True

    command = result.stdout.strip()
    if not command:
        return False
    if "codex-voice.py" in command and "CodexVoice" in command:
        return True
    return pid_file_is_fresh()


def clear_recording_state(pid: int | None = None) -> None:
    current_pid = read_recording_pid()
    if pid is not None and current_pid not in (None, pid):
        return
    PID_PATH.unlink(missing_ok=True)
    SUBMIT_REQUEST_PATH.unlink(missing_ok=True)
    write_status_state("idle", "", None)


def active_recording_pid() -> int | None:
    pid = read_recording_pid()
    if pid is None:
        SUBMIT_REQUEST_PATH.unlink(missing_ok=True)
        return None
    if pid_looks_like_codex_voice(pid):
        return pid
    clear_recording_state()
    return None


def mark_recording_active(pid: int) -> None:
    ensure_dirs()
    PID_PATH.write_text(str(pid), encoding="utf-8")
    SUBMIT_REQUEST_PATH.unlink(missing_ok=True)
    write_status_state(
        "recording",
        "再按一次快捷键结束并转写",
        pid,
    )


def request_manual_submit(logger: logging.Logger) -> int | None:
    pid = active_recording_pid()
    if pid is None:
        return None

    payload = {
        "recording_pid": pid,
        "requester_pid": os.getpid(),
        "requested_at": datetime.now().isoformat(timespec="seconds"),
    }
    SUBMIT_REQUEST_PATH.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_status_state("submitting", "正在结束录音并准备转写", pid, logger)
    logger.info("Manual submit requested for recording worker: %s", pid)
    return pid


def cancel_active_recording(logger: logging.Logger) -> int | None:
    pid = active_recording_pid()
    if pid is None:
        clear_recording_state()
        stop_recording_indicator(None, logger)
        write_status_state("idle", "", None, logger)
        return None

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        clear_recording_state(pid)
        stop_recording_indicator(None, logger)
        write_status_state("idle", "", None, logger)
        return pid

    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if not pid_looks_like_codex_voice(pid):
            clear_recording_state(pid)
            stop_recording_indicator(None, logger)
            write_status_state("idle", "", None, logger)
            logger.info("Canceled Codex Voice worker: %s", pid)
            return pid
        time.sleep(0.1)

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    clear_recording_state(pid)
    stop_recording_indicator(None, logger)
    write_status_state("idle", "", None, logger)
    logger.info("Force-canceled Codex Voice worker: %s", pid)
    return pid


def consume_manual_submit_request(logger: logging.Logger) -> bool:
    if not SUBMIT_REQUEST_PATH.exists():
        return False
    try:
        SUBMIT_REQUEST_PATH.unlink()
    except OSError:
        pass
    logger.info("Manual submit request received.")
    return True


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_config(path: Path = CONFIG_PATH) -> dict[str, Any]:
    user_config = load_json(path, {})
    if not isinstance(user_config, dict):
        raise CodexVoiceError(f"Config must be a JSON object: {path}")
    merged = DEFAULT_CONFIG.copy()
    merged.update(user_config)
    return merged


def load_terms(path: Path = TERMS_PATH) -> dict[str, Any]:
    terms = load_json(path, {})
    if not isinstance(terms, dict):
        raise CodexVoiceError(f"Terms must be a JSON object: {path}")
    return terms


def load_prompt(path: Path = PROMPT_PATH) -> str:
    if not path.exists():
        return (
            "你是一个面向软件开发者的语音转写纠错器。"
            "只输出最终可直接粘贴给 Codex 的文本。"
        )
    return path.read_text(encoding="utf-8").strip()


def timestamp_slug() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def flatten_terms(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        result: list[str] = []
        for item in value:
            result.extend(flatten_terms(item))
        return result
    if isinstance(value, dict):
        result = []
        for key, item in value.items():
            result.append(str(key))
            result.extend(flatten_terms(item))
        return result
    return []


def build_initial_prompt(terms: dict[str, Any]) -> str:
    flattened: list[str] = []
    for key, value in terms.items():
        if key == "common_misrecognitions":
            continue
        flattened.extend(flatten_terms(value))
    unique_terms = sorted({item.strip() for item in flattened if item.strip()})
    if not unique_terms:
        return ""
    prompt = "以下是需要优先识别为标准写法的软件开发术语：\n" + ", ".join(
        unique_terms
    )
    return prompt[:4000]


def summarize_terms_for_llm(terms: dict[str, Any]) -> str:
    compact_terms: dict[str, Any] = {}
    for key, value in terms.items():
        if key == "common_misrecognitions":
            compact_terms[key] = value
        elif isinstance(value, list):
            compact_terms[key] = value[:80]
        else:
            compact_terms[key] = value
    return json.dumps(compact_terms, ensure_ascii=False, indent=2)


def import_numpy():
    try:
        import numpy as np
    except ImportError as exc:
        raise MissingDependencyError(
            "Missing dependency: numpy. Run: bash ~/CodexVoice/bin/install.sh"
        ) from exc
    return np


def audio_rms_and_peak(audio: Any) -> tuple[float, float]:
    np = import_numpy()
    if audio.size == 0:
        return 0.0, 0.0
    rms = float(np.sqrt(np.mean(np.square(audio))))
    peak = float(np.max(np.abs(audio)))
    return rms, peak


def trim_audio_edges(
    audio: Any,
    sample_rate: int,
    frame_seconds: float,
    threshold: float,
    padding_seconds: float,
    logger: logging.Logger,
) -> Any:
    np = import_numpy()
    if audio.size == 0:
        return audio

    frame_size = max(1, int(sample_rate * frame_seconds))
    voiced_ranges: list[tuple[int, int]] = []
    for start in range(0, len(audio), frame_size):
        end = min(len(audio), start + frame_size)
        frame = audio[start:end]
        if frame.size == 0:
            continue
        rms = float(np.sqrt(np.mean(np.square(frame))))
        if rms >= threshold:
            voiced_ranges.append((start, end))

    if not voiced_ranges:
        return audio

    padding_samples = max(0, int(sample_rate * padding_seconds))
    start_sample = max(0, voiced_ranges[0][0] - padding_samples)
    end_sample = min(len(audio), voiced_ranges[-1][1] + padding_samples)
    if start_sample == 0 and end_sample == len(audio):
        return audio

    trimmed = audio[start_sample:end_sample]
    logger.info(
        "Trimmed manual recording edges from %.2fs to %.2fs.",
        len(audio) / sample_rate,
        len(trimmed) / sample_rate,
    )
    return trimmed


def resolve_input_device(
    config: dict[str, Any],
    logger: logging.Logger | None = None,
) -> int | str | None:
    configured = config.get("input_device")
    if configured in (None, ""):
        return None

    text = str(configured)
    if text.lower() in {"auto", "default", "system"}:
        return None

    def fallback(message: str) -> int | str | None:
        if logger is not None:
            logger.warning(message)
        return None

    try:
        import sounddevice as sd
    except ImportError:
        return configured if isinstance(configured, int) else text

    devices = sd.query_devices()

    if isinstance(configured, int):
        if 0 <= configured < len(devices) and int(devices[configured].get("max_input_channels", 0)) > 0:
            return configured
        return fallback(
            f"Configured input device index {configured} is unavailable; using system default input device."
        )

    try:
        index = int(text)
    except ValueError:
        index = None
    if index is not None:
        if 0 <= index < len(devices) and int(devices[index].get("max_input_channels", 0)) > 0:
            return index
        return fallback(
            f"Configured input device index {index} is unavailable; using system default input device."
        )

    candidates = []
    for index, device in enumerate(devices):
        name = str(device.get("name", ""))
        if int(device.get("max_input_channels", 0)) <= 0:
            continue
        if name == text:
            return index
        if text.lower() in name.lower():
            candidates.append(index)

    if candidates:
        return candidates[0]

    return fallback(
        f"Configured input device '{text}' was not found; using system default input device."
    )


def record_audio(config: dict[str, Any], logger: logging.Logger) -> Any:
    try:
        import sounddevice as sd
    except ImportError as exc:
        raise MissingDependencyError(
            "Missing dependency: sounddevice. Run: bash ~/CodexVoice/bin/install.sh"
        ) from exc

    np = import_numpy()

    sample_rate = int(config["sample_rate"])
    channels = int(config["channels"])
    input_device = resolve_input_device(config, logger)
    manual_submit_enabled = bool(config.get("manual_submit_enabled", True))
    manual_submit_required = bool(config.get("_manual_submit_required", False))
    max_seconds = float(config["max_record_seconds"])
    if manual_submit_required:
        max_seconds = float(config.get("background_max_record_seconds", max_seconds))
    start_timeout = float(config["start_timeout_seconds"])
    min_record_seconds = float(config["min_record_seconds"])
    silence_seconds = float(config["silence_seconds"])
    threshold = float(config["silence_threshold"])
    frame_seconds = float(config["frame_seconds"])
    padding_seconds = float(config["pre_speech_padding_seconds"])

    frame_size = max(1, int(sample_rate * frame_seconds))
    max_padding_frames = max(1, int(padding_seconds / frame_seconds))
    pre_speech_frames: deque[Any] = deque(maxlen=max_padding_frames)
    captured_frames: list[Any] = []
    started_at = time.monotonic()
    speech_started_at: float | None = None
    last_voice_at: float | None = None
    manual_submit_pending = False
    stop_reason = "completed"

    logger.info("Recording... speak now.")
    write_status_state("recording", "再按一次快捷键结束并转写", os.getpid(), logger)
    if input_device is not None:
        logger.info("Using input device: %s", input_device)
    else:
        logger.info("Using system default input device.")
    logger.info("Recording max duration: %.0f seconds.", max_seconds)
    indicator_pid = start_recording_indicator(config, logger, max_seconds)
    notify_status(config, "正在录音，再按一次快捷键结束", logger)
    try:
        with sd.InputStream(
            samplerate=sample_rate,
            channels=channels,
            dtype="float32",
            blocksize=frame_size,
            device=input_device,
        ) as stream:
            while True:
                chunk, overflowed = stream.read(frame_size)
                now = time.monotonic()
                if overflowed:
                    logger.warning("Audio input overflow detected; continuing.")

                chunk = np.asarray(chunk, dtype=np.float32).copy()
                rms = float(np.sqrt(np.mean(np.square(chunk)))) if chunk.size else 0.0
                has_voice = rms >= threshold

                if manual_submit_required:
                    # Manual-submit background mode must preserve everything after
                    # the first shortcut press; VAD only records quality metadata.
                    captured_frames.append(chunk)
                    if has_voice:
                        if speech_started_at is None:
                            speech_started_at = now
                            logger.info("Speech detected.")
                        last_voice_at = now
                else:
                    if has_voice:
                        if speech_started_at is None:
                            speech_started_at = now
                            captured_frames.extend(pre_speech_frames)
                            logger.info("Speech detected.")
                        captured_frames.append(chunk)
                        last_voice_at = now
                    elif speech_started_at is not None:
                        captured_frames.append(chunk)
                        if (
                            last_voice_at is not None
                            and now - last_voice_at >= silence_seconds
                            and now - speech_started_at >= min_record_seconds
                        ):
                            stop_reason = "silence"
                            logger.info("Silence detected; stopping recording.")
                            break
                    else:
                        pre_speech_frames.append(chunk)
                        if now - started_at >= start_timeout:
                            raise NoSpeechError(
                                f"No speech detected within {start_timeout:g} seconds."
                            )

                if manual_submit_enabled and consume_manual_submit_request(logger):
                    manual_submit_pending = True

                if manual_submit_pending:
                    if not manual_submit_required and speech_started_at is None:
                        raise NoSpeechError(
                            "Manual submit requested before speech was captured."
                        )
                    captured_samples = sum(frame.shape[0] for frame in captured_frames)
                    if captured_samples / sample_rate >= min_record_seconds:
                        stop_reason = "manual_submit"
                        logger.info("Manual submit requested; stopping recording.")
                        break

                if now - started_at >= max_seconds:
                    stop_reason = "max_duration"
                    logger.info("Reached max recording duration.")
                    break
    except NoSpeechError:
        notify_status(config, "未检测到有效语音", logger)
        raise
    except Exception as exc:
        raise CodexVoiceError(
            "Unable to record audio. Check macOS microphone permission for "
            "Raycast/Terminal/Python."
        ) from exc
    finally:
        stop_recording_indicator(indicator_pid, logger)

    if not captured_frames:
        raise NoSpeechError("No useful speech was captured.")

    if stop_reason == "max_duration":
        notify_status(config, "已达到 5 分钟上限，正在转写", logger)
    else:
        notify_status(config, "录音结束，正在转写", logger)
    logger.info("Recording stopped: %s.", stop_reason)

    audio = np.concatenate(captured_frames, axis=0)
    if manual_submit_required:
        audio = trim_audio_edges(
            audio,
            sample_rate,
            frame_seconds,
            threshold,
            padding_seconds,
            logger,
        )
    duration = len(audio) / sample_rate
    if duration < min_record_seconds:
        raise NoSpeechError("Captured audio was too short to transcribe.")

    rms, peak = audio_rms_and_peak(audio)
    logger.info("Captured %.2f seconds of audio. RMS %.5f, peak %.5f.", duration, rms, peak)
    return audio


def write_wav(audio: Any, path: Path, sample_rate: int) -> None:
    np = import_numpy()
    path.parent.mkdir(parents=True, exist_ok=True)

    pcm = np.clip(audio, -1.0, 1.0)
    pcm = (pcm * 32767).astype(np.int16)

    with wave.open(str(path), "wb") as wav_file:
        channels = 1 if pcm.ndim == 1 else pcm.shape[1]
        wav_file.setnchannels(channels)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm.tobytes())


def create_audio_path(config: dict[str, Any]) -> tuple[Path, bool]:
    if bool(config.get("save_recordings", True)):
        return RECORDINGS_DIR / f"{timestamp_slug()}.wav", False

    temp = tempfile.NamedTemporaryFile(prefix="codex-voice-", suffix=".wav", delete=False)
    temp.close()
    return Path(temp.name), True


def transcribe_with_mlx(
    audio_path: Path, model: str, config: dict[str, Any], initial_prompt: str
) -> str:
    try:
        import mlx_whisper
    except ImportError as exc:
        raise MissingDependencyError(
            "Missing dependency: mlx-whisper. Run: bash ~/CodexVoice/bin/install.sh"
        ) from exc

    kwargs = {
        "language": config.get("whisper_language", "zh"),
        "task": config.get("whisper_task", "transcribe"),
        "initial_prompt": initial_prompt or None,
        "verbose": False,
    }
    try:
        result = mlx_whisper.transcribe(
            str(audio_path),
            path_or_hf_repo=model,
            **kwargs,
        )
    except TypeError:
        result = mlx_whisper.transcribe(str(audio_path), model, **kwargs)
    if isinstance(result, dict):
        return str(result.get("text", "")).strip()
    return str(result).strip()


def transcribe_with_faster_whisper(
    audio_path: Path, model: str, config: dict[str, Any], initial_prompt: str
) -> str:
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise MissingDependencyError(
            "Missing dependency: faster-whisper. Run: bash ~/CodexVoice/bin/install.sh"
        ) from exc

    whisper = WhisperModel(
        model,
        device=str(config.get("faster_whisper_device", "cpu")),
        compute_type=str(config.get("faster_whisper_compute_type", "int8")),
    )
    segments, _info = whisper.transcribe(
        str(audio_path),
        language=config.get("whisper_language", "zh"),
        task=config.get("whisper_task", "transcribe"),
        beam_size=int(config.get("whisper_beam_size", 5)),
        initial_prompt=initial_prompt or None,
        vad_filter=True,
    )
    return "".join(segment.text for segment in segments).strip()


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


def start_ollama(config: dict[str, Any], logger: logging.Logger) -> None:
    ollama_path = shutil.which("ollama")
    if not ollama_path:
        logger.warning("Ollama CLI is not installed; cannot start service.")
        return

    environment = ollama_env(config)
    for command in ([ollama_path, "launch"], ["/usr/bin/open", "-ga", "Ollama"]):
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
            logger.debug("Could not run %s: %s", command, exc)

    try:
        subprocess.Popen(
            [ollama_path, "serve"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            start_new_session=True,
        )
    except Exception as exc:
        logger.debug("Could not start ollama serve: %s", exc)


def ensure_ollama_service(
    config: dict[str, Any],
    logger: logging.Logger,
    requests_module: Any,
) -> None:
    url = f"{ollama_base_url(config)}/api/tags"
    try:
        requests_module.get(url, timeout=2).raise_for_status()
        return
    except Exception as exc:
        logger.info("Ollama API is not ready at %s: %s", url, exc)

    start_ollama(config, logger)
    deadline = time.monotonic() + float(config.get("ollama_start_timeout_seconds", 12))
    last_error = ""
    while time.monotonic() <= deadline:
        try:
            requests_module.get(url, timeout=2).raise_for_status()
            return
        except Exception as exc:
            last_error = str(exc)
            time.sleep(0.4)
    logger.warning("Ollama API did not become ready at %s: %s", url, last_error)


def transcribe_with_ollama(
    audio_path: Path, model: str, config: dict[str, Any], initial_prompt: str
) -> str:
    try:
        import requests
    except ImportError as exc:
        raise MissingDependencyError(
            "Missing dependency: requests. Run: bash ~/CodexVoice/bin/install.sh"
        ) from exc

    if not model:
        raise CodexVoiceError("No Ollama transcription model is configured.")

    ensure_ollama_service(config, logging.getLogger("codex-voice"), requests)
    url = f"{ollama_base_url(config)}/v1/audio/transcriptions"
    timeout = float(config.get("ollama_transcription_timeout_seconds", 120))
    language = str(config.get("whisper_language", "zh"))
    data: dict[str, str] = {
        "model": model,
        "response_format": "json",
        "temperature": "0",
    }
    if language:
        data["language"] = language
    if initial_prompt:
        data["prompt"] = initial_prompt

    with audio_path.open("rb") as handle:
        files = {
            "file": (audio_path.name, handle, "audio/wav"),
        }
        response = requests.post(url, data=data, files=files, timeout=timeout)

    if response.status_code >= 400:
        raise CodexVoiceError(
            f"Ollama transcription failed with HTTP {response.status_code}: "
            f"{response.text[:400]}"
        )

    content_type = response.headers.get("content-type", "")
    if "application/json" in content_type:
        payload = response.json()
        if isinstance(payload, dict):
            return str(payload.get("text", "")).strip()
    return response.text.strip()


def transcription_attempts(config: dict[str, Any]) -> list[tuple[str, str]]:
    primary_backend = str(config.get("whisper_backend", "mlx-whisper"))
    primary_model = str(config.get("whisper_model", "mlx-community/whisper-large-v3-turbo"))
    if primary_backend == "ollama":
        primary_model = str(config.get("ollama_transcription_model") or primary_model)

    configured_attempts = [(primary_backend, primary_model)]
    fallback_backend = str(config.get("whisper_fallback_backend", ""))
    fallback_model = str(config.get("whisper_fallback_model", ""))
    if fallback_backend and fallback_model:
        configured_attempts.append((fallback_backend, fallback_model))

    if primary_backend == "ollama":
        configured_attempts.extend(
            [
                ("mlx-whisper", "mlx-community/whisper-large-v3-turbo"),
                ("faster-whisper", "large-v3-turbo"),
            ]
        )

    attempts: list[tuple[str, str]] = []
    for backend, model in configured_attempts:
        if backend and model and (backend, model) not in attempts:
            attempts.append((backend, model))
    return attempts


def transcribe_audio(
    audio_path: Path,
    config: dict[str, Any],
    terms: dict[str, Any],
    logger: logging.Logger,
) -> tuple[str, str, str]:
    initial_prompt = build_initial_prompt(terms)
    attempts = transcription_attempts(config)

    errors: list[str] = []
    for backend, model in attempts:
        attempt_started = time.monotonic()
        try:
            logger.info("Transcribing with %s: %s", backend, model)
            if backend == "mlx-whisper":
                text = transcribe_with_mlx(audio_path, model, config, initial_prompt)
            elif backend == "faster-whisper":
                text = transcribe_with_faster_whisper(
                    audio_path, model, config, initial_prompt
                )
            elif backend == "ollama":
                text = transcribe_with_ollama(audio_path, model, config, initial_prompt)
            else:
                raise CodexVoiceError(f"Unsupported whisper_backend: {backend}")
            text = text.strip()
            if not text:
                raise CodexVoiceError("Whisper returned empty text.")
            logger.info(
                "Transcription succeeded with %s in %.2fs.",
                backend,
                time.monotonic() - attempt_started,
            )
            return text, backend, model
        except Exception as exc:  # Try fallback before failing the workflow.
            message = f"{backend}/{model} after {time.monotonic() - attempt_started:.2f}s: {exc}"
            logger.warning("Transcription attempt failed: %s", message)
            errors.append(message)

    raise CodexVoiceError("All transcription attempts failed:\n" + "\n".join(errors))


def token_repetition_ratio(text: str) -> float:
    tokens = re.findall(r"[A-Za-z]+|\d+|[\u3400-\u9fff]", text.lower())
    if not tokens:
        return 0.0
    counts: dict[str, int] = {}
    for token in tokens:
        counts[token] = counts.get(token, 0) + 1
    return max(counts.values()) / len(tokens)


def repeated_unit_ratio(text: str) -> tuple[float, str]:
    compact = re.sub(r"[\W_]+", "", text.lower(), flags=re.UNICODE)
    if len(compact) < 24:
        return 0.0, ""

    best_ratio = 0.0
    best_unit = ""
    max_unit_length = min(12, len(compact) // 4)
    for unit_length in range(1, max_unit_length + 1):
        unit = compact[:unit_length]
        if not unit:
            continue
        repeated = (unit * ((len(compact) // unit_length) + 1))[: len(compact)]
        matches = sum(1 for left, right in zip(compact, repeated) if left == right)
        ratio = matches / len(compact)
        if ratio > best_ratio:
            best_ratio = ratio
            best_unit = unit
    return best_ratio, best_unit


def looks_like_repeated_hallucination(text: str) -> bool:
    stripped = text.strip()
    if len(stripped) < 24:
        return False

    tokens = re.findall(r"[A-Za-z]+|\d+|[\u3400-\u9fff]", stripped.lower())
    if len(tokens) >= 12 and token_repetition_ratio(stripped) >= 0.72:
        return True

    unit_ratio, unit = repeated_unit_ratio(stripped)
    if unit_ratio >= 0.92 and len(re.sub(r"[\W_]+", "", stripped, flags=re.UNICODE)) >= 24:
        return True

    words = re.findall(r"[A-Za-z]{3,}", stripped.lower())
    if len(words) >= 8 and len(set(words)) <= 2:
        return True

    return False


def apply_rule_corrections(text: str, terms: dict[str, Any]) -> str:
    replacements = terms.get("common_misrecognitions", {})
    if not isinstance(replacements, dict):
        return text

    corrected = text
    for wrong, right in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        wrong_text = str(wrong)
        right_text = str(right)
        corrected = corrected.replace(wrong_text, right_text)
        corrected = corrected.replace(wrong_text.upper(), right_text)
        corrected = corrected.replace(wrong_text.lower(), right_text)
    return corrected.strip()


def strip_thinking(text: str) -> str:
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL | re.IGNORECASE)
    return text.strip()


def force_simplified_chinese(text: str, config: dict[str, Any]) -> str:
    if not bool(config.get("force_simplified_chinese", True)):
        return text

    try:
        from opencc import OpenCC

        return OpenCC("t2s").convert(text)
    except Exception:
        fallback_map = str.maketrans(
            {
                "這": "这",
                "個": "个",
                "為": "为",
                "還": "还",
                "會": "会",
                "錄": "录",
                "輸": "输",
                "簡": "简",
                "體": "体",
                "詞": "词",
                "彙": "汇",
                "錯": "错",
                "誤": "误",
                "檔": "档",
                "裡": "里",
                "線": "线",
                "對": "对",
                "後": "后",
                "處": "处",
                "發": "发",
                "檢": "检",
                "查": "查",
            }
        )
        return text.translate(fallback_map)


def should_skip_ollama_correction(
    text: str,
    mode: str,
    config: dict[str, Any],
) -> bool:
    if mode == "strict":
        return False
    if not bool(config.get("ollama_skip_simple_utterances", True)):
        return False

    compact_length = len(re.sub(r"\s+", "", text))
    max_chars = int(config.get("ollama_simple_max_chars", 28))
    return compact_length <= max_chars


def looks_like_aggressive_rewrite(
    original: str,
    corrected: str,
    mode: str,
    config: dict[str, Any],
) -> bool:
    if mode == "strict":
        return False
    if not bool(config.get("ollama_reject_aggressive_rewrite", True)):
        return False

    original_compact = re.sub(r"\s+", "", original)
    corrected_compact = re.sub(r"\s+", "", corrected)
    if len(original_compact) < 20 or len(corrected_compact) < 20:
        return False

    length_ratio = len(corrected_compact) / max(1, len(original_compact))
    if length_ratio < float(config.get("ollama_min_length_ratio", 0.65)):
        return True
    if length_ratio > float(config.get("ollama_max_length_ratio", 1.35)):
        return True

    similarity = SequenceMatcher(None, original_compact, corrected_compact).ratio()
    return similarity < float(config.get("ollama_min_similarity", 0.55))


def correct_with_ollama(
    text: str,
    mode: str,
    config: dict[str, Any],
    terms: dict[str, Any],
    logger: logging.Logger,
) -> tuple[str, str, str]:
    if str(config.get("correction_backend", "ollama")) != "ollama":
        return text, str(config.get("correction_backend", "none")), ""
    if should_skip_ollama_correction(text, mode, config):
        logger.info("Skipping Ollama correction for short utterance.")
        return text, "rule-only", ""

    try:
        import requests
    except ImportError as exc:
        logger.warning("requests is not installed; using rule-corrected text.")
        return text, "rule-only", ""

    prompt = load_prompt()
    terms_summary = summarize_terms_for_llm(terms)
    mode_instruction = (
        "当前模式是 strict。可以整理成“目标 / 任务 / 约束 / 验收标准”结构，但不得新增、推断或重写用户没有说出的信息。"
        if mode == "strict"
        else "当前模式是 normal。请尽量保持原文逐字顺序，只做必要的词汇、中文多音字/同音/近音上下文错词、术语、错别字和格式纠错。"
    )
    clean_context_instruction = (
        "本次请求是全新的独立上下文；只依据下面这段待纠错文本和术语表，不要引用、延续或记忆任何历史输入。"
        if bool(config.get("ollama_clean_context_per_request", True))
        else ""
    )
    user_content = (
        f"{mode_instruction}\n\n"
        f"{clean_context_instruction}\n\n"
        "输出语言要求：英文技术词保持英文；中文一律输出简体中文，不要输出繁体字。\n\n"
        f"术语表 JSON：\n{terms_summary}\n\n"
        f"待纠错文本：\n{text}\n\n"
        "只输出最终文本，不要解释。不要总结、扩写、改写语气或重排句子。"
    )

    models = [str(config.get("ollama_model", ""))]
    models.extend(str(item) for item in config.get("ollama_fallback_models", []) if item)
    models = [model for index, model in enumerate(models) if model and model not in models[:index]]

    ensure_ollama_service(config, logger, requests)
    timeout = float(config.get("ollama_timeout_seconds", 25))
    url = ollama_chat_url(config)
    last_error = ""

    for model in models:
        attempt_started = time.monotonic()
        # Keep this request stateless: keep_alive keeps model weights loaded, not prior chat turns.
        payload: dict[str, Any] = {
            "model": model,
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": user_content},
            ],
            "stream": False,
            "think": bool(config.get("ollama_think", False)),
            "keep_alive": config.get("ollama_keep_alive", "10m"),
            "options": {
                "temperature": float(config.get("ollama_temperature", 0)),
                "num_predict": int(config.get("ollama_num_predict", 512)),
            },
        }
        num_ctx = config.get("ollama_num_ctx")
        if num_ctx:
            payload["options"]["num_ctx"] = ollama_num_ctx(config)
        try:
            logger.info("Correcting text with Ollama model: %s", model)
            response = requests.post(url, json=payload, timeout=timeout)
            response.raise_for_status()
            data = response.json()
            corrected = data.get("message", {}).get("content", "")
            corrected = strip_thinking(str(corrected))
            if corrected:
                if looks_like_aggressive_rewrite(text, corrected, mode, config):
                    logger.warning(
                        "Ollama correction looked too aggressive; using rule-corrected text."
                    )
                    return text, "rule-only", ""
                logger.info(
                    "Ollama correction succeeded with %s in %.2fs.",
                    model,
                    time.monotonic() - attempt_started,
                )
                return corrected, "ollama", model
            last_error = f"{model}: empty response"
        except Exception as exc:
            last_error = f"{model} after {time.monotonic() - attempt_started:.2f}s: {exc}"
            logger.warning("Ollama correction failed: %s", last_error)

    if last_error:
        logger.warning("Using rule-corrected text after Ollama failure: %s", last_error)
    return text, "rule-only", ""


def save_transcript(
    mode: str,
    audio_path: Path | None,
    whisper_backend: str,
    whisper_model: str,
    correction_backend: str,
    correction_model: str,
    raw_text: str,
    rule_text: str,
    final_text: str,
    config: dict[str, Any],
) -> Path | None:
    if not bool(config.get("save_transcripts", True)):
        return None

    path = TRANSCRIPTS_DIR / f"{timestamp_slug()}.md"
    audio_display = str(audio_path) if audio_path else "(not saved)"
    content = f"""# Codex Voice Transcript

* Time: {datetime.now().isoformat(timespec="seconds")}
* Mode: {mode}
* Audio: {audio_display}
* Whisper Backend: {whisper_backend}
* Whisper Model: {whisper_model}
* Correction Backend: {correction_backend}
* Correction Model: {correction_model or "(none)"}

## Raw Transcript

{raw_text}

## Rule-Corrected Transcript

{rule_text}

## Final Transcript

{final_text}
"""
    path.write_text(content, encoding="utf-8")
    return path


def copy_to_clipboard(text: str) -> None:
    try:
        import pyperclip

        pyperclip.copy(text)
        return
    except Exception:
        pass

    subprocess.run(["pbcopy"], input=text, text=True, check=True)


def config_string_list(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def frontmost_focus_status(logger: logging.Logger) -> tuple[str, str, str]:
    script = r'''
tell application "System Events"
    set appName to ""
    try
        set frontApp to first application process whose frontmost is true
        set appName to name of frontApp as text
        set focusedElement to value of attribute "AXFocusedUIElement" of frontApp
    on error errMsg
        return "unknown|" & appName & "|" & errMsg
    end try

    set roleValue to ""
    set subroleValue to ""
    set roleDescriptionValue to ""
    set editableValue to false

    try
        set roleValue to value of attribute "AXRole" of focusedElement as text
    end try
    try
        set subroleValue to value of attribute "AXSubrole" of focusedElement as text
    end try
    try
        set roleDescriptionValue to value of attribute "AXRoleDescription" of focusedElement as text
    end try
    try
        set editableValue to value of attribute "AXEditable" of focusedElement
    end try
    try
        set selectedRangeValue to value of attribute "AXSelectedTextRange" of focusedElement
        if selectedRangeValue is not missing value then return "editable|" & appName
    end try

    if editableValue is true then return "editable|" & appName
    if roleValue is "AXTextField" then return "editable|" & appName
    if roleValue is "AXTextArea" then return "editable|" & appName
    if roleValue is "AXComboBox" then return "editable|" & appName
    if roleDescriptionValue is "text field" then return "editable|" & appName
    if roleDescriptionValue is "text area" then return "editable|" & appName

    return "not-editable|" & appName & "|" & roleValue & "|" & subroleValue & "|" & roleDescriptionValue
end tell
'''
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            check=False,
            timeout=3,
        )
    except Exception as exc:
        logger.warning("Could not verify editable focus; skipping auto paste: %s", exc)
        return "unknown", "", str(exc)

    status = result.stdout.strip()
    if result.returncode != 0:
        logger.warning(
            "Could not verify editable focus; skipping auto paste: %s",
            result.stderr.strip() or status,
        )
        return "unknown", "", result.stderr.strip() or status

    parts = status.split("|", 2)
    focus_status = parts[0] if parts else ""
    app_name = parts[1] if len(parts) > 1 else ""
    detail = parts[2] if len(parts) > 2 else ""
    return focus_status, app_name, detail


def clipboard_fallback_apps(config: dict[str, Any]) -> list[str]:
    return config_string_list(config.get("clipboard_fallback_app_allowlist", []))


def paste_clipboard_to_frontmost(logger: logging.Logger, config: dict[str, Any]) -> None:
    ensure_dirs()
    request_id = f"{timestamp_slug()}-{os.getpid()}"
    payload = {"id": request_id, "created_at": datetime.now().isoformat(timespec="seconds")}
    temp_path = PASTE_REQUEST_PATH.with_suffix(f".{os.getpid()}.tmp")
    try:
        PASTE_RESULT_PATH.unlink(missing_ok=True)
        temp_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        temp_path.replace(PASTE_REQUEST_PATH)
    except Exception as exc:
        logger.warning("Could not request paste from Codex Voice Agent: %s", exc)
        notify_status(config, "已复制到剪贴板，自动粘贴失败", logger)
        return

    deadline = time.monotonic() + 5
    last_message = ""
    while time.monotonic() < deadline:
        try:
            result = json.loads(PASTE_RESULT_PATH.read_text(encoding="utf-8"))
        except FileNotFoundError:
            time.sleep(0.1)
            continue
        except Exception as exc:
            last_message = str(exc)
            time.sleep(0.1)
            continue

        if result.get("id") != request_id:
            time.sleep(0.1)
            continue

        if result.get("ok") is True:
            logger.info("Pasted final text into frontmost app via Codex Voice Agent.")
            return

        message = str(result.get("message", "unknown paste failure"))
        logger.warning("Auto paste failed in Codex Voice Agent: %s", message)
        notify_status(config, "已复制到剪贴板，自动粘贴失败", logger)
        return

    logger.warning(
        "Auto paste timed out waiting for Codex Voice Agent. Last result detail: %s",
        last_message,
    )
    notify_status(config, "已复制到剪贴板，自动粘贴失败", logger)


def paste_to_frontmost_app(
    text: str,
    auto_paste: bool,
    config: dict[str, Any],
    logger: logging.Logger,
) -> None:
    if not auto_paste:
        copy_to_clipboard(text)
        logger.info("Copied final text to clipboard.")
        logger.info("Auto paste is disabled.")
        return

    fallback_apps = clipboard_fallback_apps(config)
    if bool(config.get("paste_requires_editable_focus", True)):
        focus_status, app_name, detail = frontmost_focus_status(logger)
        if focus_status == "editable":
            copy_to_clipboard(text)
            logger.info("Copied final text to clipboard.")
            paste_clipboard_to_frontmost(logger, config)
            return

        if focus_status == "unknown" and app_name in fallback_apps:
            logger.info(
                "Focused element is unavailable for fallback app %s; copying and trying paste. Detail: %s",
                app_name,
                detail,
            )
            copy_to_clipboard(text)
            logger.info("Copied final text to clipboard.")
            paste_clipboard_to_frontmost(logger, config)
            return

        if app_name in fallback_apps:
            copy_to_clipboard(text)
            logger.info(
                "Focused element is not editable in fallback app %s; copied final text to clipboard.",
                app_name,
            )
            return

        logger.info(
            "Focused element is not editable; leaving existing clipboard unchanged: %s|%s|%s",
            focus_status,
            app_name,
            detail,
        )
        return

    copy_to_clipboard(text)
    logger.info("Copied final text to clipboard.")
    paste_clipboard_to_frontmost(logger, config)


def start_background_worker(args: argparse.Namespace, logger: logging.Logger) -> int:
    existing_pid = active_recording_pid()
    if existing_pid is not None:
        return existing_pid

    script_path = Path(__file__).resolve()
    command = [
        sys.executable,
        str(script_path),
        "--worker",
        "--config",
        str(args.config),
    ]
    if args.mode:
        command.extend(["--mode", args.mode])

    ensure_dirs()
    with LOG_PATH.open("a", encoding="utf-8") as log_file:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=log_file,
            start_new_session=True,
            close_fds=True,
        )

    mark_recording_active(process.pid)
    logger.info("Started background recording worker: %s", process.pid)
    return process.pid


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Codex Voice Input")
    parser.add_argument(
        "--mode",
        choices=["normal", "copy-only", "strict"],
        help="Output mode. Defaults to config.json mode.",
    )
    parser.add_argument(
        "--stdout-only",
        action="store_true",
        help="Print final text only; do not copy or paste.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=CONFIG_PATH,
        help="Path to config.json.",
    )
    parser.add_argument(
        "--toggle",
        action="store_true",
        help="Raycast mode: start recording in the background, or submit if already recording.",
    )
    parser.add_argument(
        "--submit-current",
        action="store_true",
        help="Submit the currently active background recording and exit.",
    )
    parser.add_argument(
        "--cancel-current",
        action="store_true",
        help="Terminate the active background recording worker and clear state.",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Print current recording status and exit.",
    )
    parser.add_argument(
        "--worker",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def run_pipeline(args: argparse.Namespace, logger: logging.Logger) -> int:
    pipeline_started = time.monotonic()
    config = load_config(args.config)
    if args.worker and bool(config.get("background_manual_submit_required", True)):
        config["_manual_submit_required"] = True
    terms = load_terms()
    mode = args.mode or str(config.get("mode", "normal"))

    if mode not in {"normal", "copy-only", "strict"}:
        raise CodexVoiceError(f"Unsupported mode: {mode}")

    audio_path, is_temporary_audio = create_audio_path(config)
    saved_audio_path: Path | None = audio_path if not is_temporary_audio else None

    try:
        stage_started = time.monotonic()
        audio = record_audio(config, logger)
        logger.info("Recording stage finished in %.2fs.", time.monotonic() - stage_started)
        write_status_state("transcribing", "正在保存录音并识别文本", os.getpid(), logger)
        write_wav(audio, audio_path, int(config["sample_rate"]))
        audio_rms, audio_peak = audio_rms_and_peak(audio)
        min_audio_rms = float(config.get("min_audio_rms", 0))
        min_audio_peak = float(config.get("min_audio_peak", 0))
        if audio_rms < min_audio_rms and audio_peak < min_audio_peak:
            if audio_rms <= 0.000001 and audio_peak <= 0.000001:
                raise NoSpeechError(
                    "Microphone input is silent. Open the Codex Voice status bar menu "
                    "and choose '请求麦克风权限 / 测试输入', then allow Microphone access."
                )
            raise NoSpeechError(
                "Captured audio was too quiet to transcribe "
                f"(RMS {audio_rms:.5f}, peak {audio_peak:.5f})."
            )

        stage_started = time.monotonic()
        raw_text, whisper_backend, whisper_model = transcribe_audio(
            audio_path, config, terms, logger
        )
        logger.info("Transcription stage finished in %.2fs.", time.monotonic() - stage_started)
        if bool(config.get("reject_repeated_hallucinations", True)) and looks_like_repeated_hallucination(raw_text):
            final_text = "（忽略重复幻听，无有效指令）"
            transcript_path = save_transcript(
                mode=mode,
                audio_path=saved_audio_path,
                whisper_backend=whisper_backend,
                whisper_model=whisper_model,
                correction_backend="rejected",
                correction_model="repeated-hallucination-filter",
                raw_text=raw_text,
                rule_text=raw_text,
                final_text=final_text,
                config=config,
            )
            if transcript_path:
                logger.info("Saved rejected transcript: %s", transcript_path)
            logger.warning("Rejected repeated Whisper hallucination; not copying or pasting.")
            print(final_text)
            return 2

        rule_text = apply_rule_corrections(raw_text, terms)
        write_status_state("correcting", "正在做术语和上下文纠错", os.getpid(), logger)
        stage_started = time.monotonic()
        final_text, correction_backend, correction_model = correct_with_ollama(
            rule_text, mode, config, terms, logger
        )
        final_text = force_simplified_chinese(final_text, config)
        logger.info("Correction stage finished in %.2fs.", time.monotonic() - stage_started)
        if not final_text.strip():
            raise CodexVoiceError("Final transcript is empty.")

        transcript_path = save_transcript(
            mode=mode,
            audio_path=saved_audio_path,
            whisper_backend=whisper_backend,
            whisper_model=whisper_model,
            correction_backend=correction_backend,
            correction_model=correction_model,
            raw_text=raw_text,
            rule_text=rule_text,
            final_text=final_text,
            config=config,
        )
        if transcript_path:
            logger.info("Saved transcript: %s", transcript_path)

        if args.stdout_only:
            print(final_text)
            logger.info("Pipeline finished in %.2fs.", time.monotonic() - pipeline_started)
            return 0

        should_paste = bool(config.get("auto_paste", True)) and mode != "copy-only"
        write_status_state("finalizing", "正在复制或粘贴最终文本", os.getpid(), logger)
        paste_to_frontmost_app(final_text, should_paste, config, logger)
        print(final_text)
        logger.info("Pipeline finished in %.2fs.", time.monotonic() - pipeline_started)
        return 0
    finally:
        if is_temporary_audio:
            try:
                audio_path.unlink(missing_ok=True)
            except Exception:
                logger.warning("Could not delete temporary audio file: %s", audio_path)
        write_status_state("idle", "", None, logger)


def run() -> int:
    ensure_runtime_path()
    args = parse_args()
    logger = setup_logging()

    if args.status:
        with state_lock():
            pid = active_recording_pid()
            status = read_status_state()
        status_name = str(status.get("status", "idle"))
        label = str(status.get("label", STATUS_LABELS.get(status_name, status_name)))
        detail = str(status.get("detail", ""))
        updated_at = str(status.get("updated_at", ""))
        if pid is None:
            if status_name != "idle":
                write_status_state("idle", "", None, logger)
            print("Codex Voice status: idle.")
        else:
            suffix = f", {detail}" if detail else ""
            timestamp = f", updated {updated_at}" if updated_at else ""
            print(f"Codex Voice status: {status_name} ({label}), PID {pid}{suffix}{timestamp}.")
        return 0

    if args.submit_current:
        with state_lock():
            pid = request_manual_submit(logger)
        if pid is None:
            print("No active Codex Voice recording.", file=sys.stderr)
            return 1
        print("Submitting current Codex Voice recording.")
        return 0

    if args.cancel_current:
        with state_lock():
            pid = cancel_active_recording(logger)
        if pid is None:
            print("No active Codex Voice recording.")
        else:
            print(f"Canceled Codex Voice recording worker: {pid}.")
        return 0

    if args.toggle:
        with state_lock():
            pid = request_manual_submit(logger)
            if pid is not None:
                print("Submitting current Codex Voice recording.")
                return 0

            pid = start_background_worker(args, logger)
        print(f"Codex Voice recording started. Press the shortcut again to submit. PID: {pid}")
        return 0

    if args.worker:
        mark_recording_active(os.getpid())
        try:
            return run_pipeline(args, logger)
        finally:
            clear_recording_state(os.getpid())

    return run_pipeline(args, logger)


def main() -> None:
    try:
        raise SystemExit(run())
    except KeyboardInterrupt:
        print("Codex Voice canceled.", file=sys.stderr)
        raise SystemExit(130)
    except NoSpeechError as exc:
        write_status_state("idle", f"上次未转写：{exc}", None)
        print(f"No speech detected: {exc}", file=sys.stderr)
        raise SystemExit(2)
    except CodexVoiceError as exc:
        write_status_state("error", f"上次运行错误：{exc}", None)
        print(f"Codex Voice error: {exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
