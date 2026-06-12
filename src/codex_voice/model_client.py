"""Client for the persistent local MLX model service."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

from codex_voice.paths import AppPaths


class ModelServiceError(RuntimeError):
    """Raised when the local model service cannot complete a request."""


def _send(socket_path: Path, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    request = dict(payload)
    request.setdefault("id", str(uuid.uuid4()))
    encoded = json.dumps(request, ensure_ascii=False).encode("utf-8") + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(str(socket_path))
        client.sendall(encoded)
        chunks = bytearray()
        while not chunks.endswith(b"\n"):
            data = client.recv(65536)
            if not data:
                break
            chunks.extend(data)
    if not chunks:
        raise ModelServiceError("Model service returned no response.")
    response = json.loads(chunks.decode("utf-8"))
    if not isinstance(response, dict):
        raise ModelServiceError("Model service returned an invalid response.")
    if not response.get("ok", False):
        raise ModelServiceError(str(response.get("error") or "Model service request failed."))
    return response


def start_model_service(paths: AppPaths, timeout: float = 15) -> None:
    label = "com.codexvoice.model-service"
    domain = f"gui/{os.getuid()}"
    service = f"{domain}/{label}"
    kickstart = subprocess.run(
        ["/bin/launchctl", "kickstart", "-k", f"{domain}/{label}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if kickstart.returncode != 0:
        plist = Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"
        if not plist.is_file():
            detail = (kickstart.stderr or kickstart.stdout).strip()
            raise ModelServiceError(
                f"Model service is not installed: {plist}"
                + (f" ({detail})" if detail else "")
            )
        subprocess.run(
            ["/bin/launchctl", "bootstrap", domain, str(plist)],
            capture_output=True,
            text=True,
            check=False,
        )
        subprocess.run(
            ["/bin/launchctl", "kickstart", "-k", service],
            capture_output=True,
            text=True,
            check=False,
        )
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() < deadline:
        try:
            _send(paths.model_service_socket_path, {"action": "ping"}, 1)
            return
        except Exception as exc:
            last_error = str(exc)
            time.sleep(0.2)
    raise ModelServiceError(f"Model service did not become ready: {last_error}")


def request_model_service(
    paths: AppPaths,
    payload: dict[str, Any],
    *,
    timeout: float = 300,
    start_if_needed: bool = True,
) -> dict[str, Any]:
    try:
        return _send(paths.model_service_socket_path, payload, timeout)
    except OSError as exc:
        if not start_if_needed:
            raise ModelServiceError(str(exc)) from exc
    start_model_service(paths)
    return _send(paths.model_service_socket_path, payload, timeout)
