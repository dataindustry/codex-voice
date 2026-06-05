"""Runtime path helpers for Codex Voice."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class AppPaths:
    root: Path

    @property
    def bin_dir(self) -> Path:
        return self.root / "bin"

    @property
    def config_dir(self) -> Path:
        return self.root / "config"

    @property
    def recordings_dir(self) -> Path:
        return self.root / "recordings"

    @property
    def transcripts_dir(self) -> Path:
        return self.root / "transcripts"

    @property
    def logs_dir(self) -> Path:
        return self.root / "logs"

    @property
    def state_dir(self) -> Path:
        return self.root / "state"

    @property
    def config_path(self) -> Path:
        return self.config_dir / "config.json"

    @property
    def terms_path(self) -> Path:
        return self.config_dir / "terms.json"

    @property
    def prompt_path(self) -> Path:
        return self.config_dir / "correction_prompt.txt"

    @property
    def log_path(self) -> Path:
        return self.logs_dir / "codex-voice.log"

    @property
    def status_path(self) -> Path:
        return self.state_dir / "status.json"

    @property
    def state_lock_path(self) -> Path:
        return self.state_dir / "state.lock"

    @property
    def recording_pid_path(self) -> Path:
        return self.state_dir / "recording.pid"

    @property
    def indicator_pid_path(self) -> Path:
        return self.state_dir / "indicator.pid"

    @property
    def submit_request_path(self) -> Path:
        return self.state_dir / "submit.request"

    @property
    def paste_request_path(self) -> Path:
        return self.state_dir / "paste.request"

    @property
    def paste_result_path(self) -> Path:
        return self.state_dir / "paste.result"

    @property
    def model_task_path(self) -> Path:
        return self.state_dir / "model-task.json"

    def ensure_dirs(self) -> None:
        for directory in (
            self.bin_dir,
            self.config_dir,
            self.recordings_dir,
            self.transcripts_dir,
            self.logs_dir,
            self.state_dir,
        ):
            directory.mkdir(parents=True, exist_ok=True)


def resolve_root(value: str | os.PathLike[str] | None = None) -> Path:
    """Resolve runtime root with --root > CODEX_VOICE_HOME > ~/CodexVoice."""

    if value:
        return Path(value).expanduser().resolve()
    env_value = os.environ.get("CODEX_VOICE_HOME")
    if env_value:
        return Path(env_value).expanduser().resolve()
    return (Path.home() / "CodexVoice").resolve()


def paths_for_root(value: str | os.PathLike[str] | None = None) -> AppPaths:
    return AppPaths(resolve_root(value))
