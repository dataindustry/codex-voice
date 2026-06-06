from __future__ import annotations

from codex_voice import voice


def test_paste_copy_only_never_requests_frontmost_paste(monkeypatch) -> None:
    copied: list[str] = []
    pasted: list[bool] = []

    monkeypatch.setattr(voice, "copy_to_clipboard", copied.append)
    monkeypatch.setattr(voice, "paste_clipboard_to_frontmost", lambda *_args: pasted.append(True))

    voice.paste_to_frontmost_app("hello", False, {}, voice.logging.getLogger("test"))

    assert copied == ["hello"]
    assert pasted == []


def test_paste_leaves_clipboard_when_focus_is_not_editable(monkeypatch) -> None:
    copied: list[str] = []
    pasted: list[bool] = []

    monkeypatch.setattr(voice, "copy_to_clipboard", copied.append)
    monkeypatch.setattr(
        voice,
        "frontmost_focus_status",
        lambda _logger: ("not-editable", "Finder", "AXWindow"),
    )
    monkeypatch.setattr(voice, "paste_clipboard_to_frontmost", lambda *_args: pasted.append(True))

    voice.paste_to_frontmost_app(
        "hello",
        True,
        {"paste_requires_editable_focus": True},
        voice.logging.getLogger("test"),
    )

    assert copied == ["hello"]
    assert pasted == []


def test_paste_requests_frontmost_when_focus_is_editable(monkeypatch) -> None:
    copied: list[str] = []
    pasted: list[bool] = []

    monkeypatch.setattr(voice, "copy_to_clipboard", copied.append)
    monkeypatch.setattr(voice, "frontmost_focus_status", lambda _logger: ("editable", "Notes", ""))
    monkeypatch.setattr(voice, "paste_clipboard_to_frontmost", lambda *_args: pasted.append(True))

    voice.paste_to_frontmost_app(
        "hello",
        True,
        {"paste_requires_editable_focus": True},
        voice.logging.getLogger("test"),
    )

    assert copied == ["hello"]
    assert pasted == [True]


def test_paste_focus_unknown_prompts_accessibility_reenable(monkeypatch) -> None:
    copied: list[str] = []
    pasted: list[bool] = []
    notices: list[str] = []

    monkeypatch.setattr(voice, "copy_to_clipboard", copied.append)
    monkeypatch.setattr(
        voice,
        "frontmost_focus_status",
        lambda _logger: ("unknown", "System Events", "not authorized"),
    )
    monkeypatch.setattr(voice, "paste_clipboard_to_frontmost", lambda *_args: pasted.append(True))
    monkeypatch.setattr(
        voice,
        "notify_status",
        lambda _config, message, _logger, title="Codex Voice": notices.append(message),
    )

    voice.paste_to_frontmost_app(
        "hello",
        True,
        {
            "paste_requires_editable_focus": True,
            "notify_status": True,
            "ui_language": "zh-Hans",
        },
        voice.logging.getLogger("test"),
    )

    assert copied == ["hello"]
    assert pasted == []
    assert notices == [voice.t({"ui_language": "zh-Hans"}, "notify.accessibility")]
