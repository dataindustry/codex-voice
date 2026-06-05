"""Clipboard and paste helpers."""

from codex_voice.voice import (
    copy_to_clipboard,
    frontmost_focus_status,
    paste_clipboard_to_frontmost,
    paste_to_frontmost_app,
)

__all__ = [
    "copy_to_clipboard",
    "frontmost_focus_status",
    "paste_clipboard_to_frontmost",
    "paste_to_frontmost_app",
]
