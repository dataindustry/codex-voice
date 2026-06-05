"""Ollama integration helpers."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any
from urllib.parse import urlparse, urlunparse

DEFAULT_OLLAMA_BASE_URL = "http://127.0.0.1:11434"
DEFAULT_OLLAMA_CHAT_URL = f"{DEFAULT_OLLAMA_BASE_URL}/api/chat"
DEFAULT_OLLAMA_NUM_CTX = 4000


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


def system_ollama_base_url() -> str:
    host = normalize_ollama_host(os.environ.get("OLLAMA_HOST", ""))
    if host:
        return host

    host = normalize_ollama_host(launchctl_getenv("OLLAMA_HOST"))
    if host:
        return host

    return ""


def ollama_base_url(config: dict[str, Any]) -> str:
    system_url = system_ollama_base_url()
    if system_url:
        return system_url

    configured = configured_ollama_base_url(config)
    if configured:
        return configured

    return DEFAULT_OLLAMA_BASE_URL


def ollama_chat_url(config: dict[str, Any]) -> str:
    system_url = system_ollama_base_url()
    if system_url:
        return f"{system_url}/api/chat"

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


def start_ollama_processes(config: dict[str, Any]) -> tuple[bool, str]:
    ollama_path = shutil.which("ollama")
    if not ollama_path:
        return False, "Ollama CLI is not installed."

    environment = ollama_env(config)
    errors: list[str] = []
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
            errors.append(str(exc))

    try:
        subprocess.Popen(
            [ollama_path, "serve"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            start_new_session=True,
        )
    except Exception as exc:
        errors.append(str(exc))

    return True, "; ".join(errors)
