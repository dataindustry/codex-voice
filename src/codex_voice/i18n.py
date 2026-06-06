"""Runtime language helpers for Codex Voice."""

from __future__ import annotations

import os
import re
import subprocess
from typing import Any

SUPPORTED_UI_LANGUAGES = ("system", "en", "zh-Hans", "zh-Hant", "ja")
RUNTIME_LANGUAGES = ("en", "zh-Hans", "zh-Hant", "ja")


TRANSLATIONS: dict[str, dict[str, str]] = {
    "en": {
        "language.system": "Follow System",
        "language.en": "English",
        "language.zh-Hans": "Simplified Chinese",
        "language.zh-Hant": "Traditional Chinese",
        "language.ja": "Japanese",
        "status.idle": "Idle",
        "status.recording": "Recording",
        "status.submitting": "Ending recording",
        "status.transcribing": "Transcribing",
        "status.correcting": "Correcting",
        "status.finalizing": "Copying or pasting text",
        "status.error": "Error",
        "detail.recording_hint": "Press the shortcut again to submit and transcribe",
        "detail.submitting": "Ending recording and preparing transcription",
        "detail.transcribing": "Saving audio and recognizing text",
        "detail.correcting": "Correcting terms and context",
        "detail.finalizing": "Copying or pasting final text",
        "detail.stale": "The status file is stale; the previous process may have exited unexpectedly",
        "notify.accessibility": "Copied to clipboard. Re-enable Accessibility permission.",
        "notify.auto_paste_failed": "Copied to clipboard. Auto paste failed.",
        "notify.recording": "Recording. Press the shortcut again to submit.",
        "notify.no_speech": "No useful speech detected.",
        "notify.max_reached": "Recording limit reached. Transcribing.",
        "notify.finished_recording": "Recording finished. Transcribing.",
        "text.repeated_hallucination": "(Ignored repeated hallucination; no valid instruction)",
        "error.no_speech_prefix": "Last run was not transcribed",
        "error.runtime_prefix": "Last run failed",
        "cli.status_idle": "Codex Voice status: idle.",
        "cli.status_running": "Codex Voice status: {status} ({label}), PID {pid}{suffix}{timestamp}.",
        "cli.no_active_recording": "No active Codex Voice recording.",
        "cli.early_submit": "Codex Voice recording just started; ignored early submit.",
        "cli.submitting": "Submitting current Codex Voice recording.",
        "cli.canceled": "Canceled Codex Voice recording worker: {pid}.",
        "cli.started": "Codex Voice recording started. Press the shortcut again to submit. PID: {pid}",
        "cli.canceled_by_user": "Codex Voice canceled.",
        "cli.no_speech": "No speech detected: {error}",
        "cli.error": "Codex Voice error: {error}",
        "cli.installed_at": "Codex Voice installed at: {root}",
        "cli.conda_env": "Conda env: {env}",
        "cli.python": "Python: {python}",
        "cli.max_recording": "Max recording: {seconds} seconds ({minutes:g} minutes)",
        "cli.input_device": "Input device: {device}",
        "cli.system_default": "system default",
        "cli.transcription_profile": "Transcription profile: {profile}",
        "cli.transcription_model": "Transcription model: {backend} / {model}",
        "cli.ollama_transcription_model": "Ollama transcription model: {model}",
        "cli.correction_profile": "Correction profile: {profile}",
        "cli.correction_model": "Correction model: {backend} / {model}",
        "cli.ui_language": "UI language: {language} (resolved: {resolved})",
        "cli.output_language_legacy": "Legacy output language: {language}",
        "cli.config_file": "Config file: {path}",
        "cli.set_ui_language": "Codex Voice UI language set to: {language} (resolved: {resolved})",
        "cli.invalid_ui_language": "Unsupported UI language: {language}. Use one of: {choices}.",
        "cli.set_input_device": "Codex Voice input device set to: {label}",
        "cli.max_minutes_positive": "Max recording minutes must be greater than 0.",
        "cli.max_minutes_refused": "Refusing to set more than 10 minutes from the panel helper.",
        "cli.set_max_recording": "Codex Voice max recording set to {seconds} seconds ({minutes:g} minutes).",
        "cli.set_transcription_profile": "Codex Voice transcription profile set to: {label}",
        "cli.set_ollama_transcription_model": "Codex Voice Ollama transcription model set to: {label}",
        "cli.set_correction_profile": "Codex Voice correction profile set to: {label}",
        "cli.set_ollama_correction_model": "Codex Voice Ollama correction model set to: {label}",
        "cli.transcription_ready": "Codex Voice transcription model is ready.",
        "cli.correction_ready": "Codex Voice correction model is ready.",
        "cli.correction_unloaded": "Codex Voice correction model was unloaded from memory.",
        "cli.ollama_unloaded": "Codex Voice Ollama model was unloaded: {model}",
        "task.idle": "Idle",
        "task.state_unreadable": "Model task state is unreadable",
        "task.prepare_transcription": "Prepare transcription model: {model}",
        "task.prepare_correction": "Prepare correction model: {model}",
        "task.rule_correction": "Rule correction",
        "task.unload_model": "Unload model: {model}",
        "task.checking": "Checking model configuration",
        "task.loading_mlx": "Downloading or loading MLX Whisper model",
        "task.loading_faster": "Downloading or loading faster-whisper model",
        "task.warming_ollama_audio": "Warming Ollama audio transcription API",
        "task.model_ready": "Model is ready",
        "task.no_model_needed": "No model needs to be loaded",
        "task.loading_ollama_memory": "Loading model into Ollama memory",
        "task.model_loaded": "Model is loaded in memory",
        "task.unloading": "Unloading model from memory",
        "task.unloaded": "Model was unloaded from memory",
        "prompt.initial_terms": "Prefer these software development terms exactly:\n{terms}",
        "prompt.system": (
            "You are a conservative dictation proofreader for a software developer. "
            "The user is speaking commands to an AI coding agent. Correct only speech-recognition "
            "mistakes, technical terms, casing, command/file/path formatting, and obvious typos. "
            "Keep word order, tone, and information density. Do not summarize, expand, translate, "
            "rewrite style, reorder sentences, or add unstated requirements. Output only the final text."
        ),
        "prompt.mode.normal": (
            "Mode: normal. Preserve the original wording as much as possible. Only fix necessary "
            "vocabulary, homophone/context mistakes, technical terms, typos, and formatting."
        ),
        "prompt.mode.strict": (
            "Mode: strict. You may organize into a concise target/task/constraints/acceptance style "
            "structure, but must not add, infer, or rewrite information the user did not say."
        ),
        "prompt.clean_context": (
            "This request is an independent context. Use only the text and terms below. "
            "Do not use or remember previous inputs, logs, or conversation history."
        ),
        "prompt.language": (
            "Language requirement: interpret and correct the natural-language content as English, "
            "and output English. Preserve technical terms, commands, paths, file names, variables, "
            "and abbreviations in their standard spelling."
        ),
        "prompt.user": (
            "{mode_instruction}\n\n{clean_context}\n\n{language_instruction}\n\n"
            "Terms JSON:\n{terms}\n\nText to correct:\n{text}\n\n"
            "Output only the final text. Do not explain. Do not output JSON or a title unless the user explicitly asked for one."
        ),
    },
    "zh-Hans": {
        "language.system": "跟随系统",
        "language.en": "English",
        "language.zh-Hans": "简体中文",
        "language.zh-Hant": "繁體中文",
        "language.ja": "日本語",
        "status.idle": "空闲",
        "status.recording": "正在录音",
        "status.submitting": "正在结束录音",
        "status.transcribing": "正在识别",
        "status.correcting": "正在纠错",
        "status.finalizing": "正在提交文本",
        "status.error": "出错",
        "detail.recording_hint": "再按一次快捷键结束并转写",
        "detail.submitting": "正在结束录音并准备转写",
        "detail.transcribing": "正在保存录音并识别文本",
        "detail.correcting": "正在做术语和上下文纠错",
        "detail.finalizing": "正在复制或粘贴最终文本",
        "detail.stale": "状态文件已过期，可能是上次进程异常退出",
        "notify.accessibility": "已复制到剪贴板，请重新勾选辅助功能权限",
        "notify.auto_paste_failed": "已复制到剪贴板，自动粘贴失败",
        "notify.recording": "正在录音，再按一次快捷键结束",
        "notify.no_speech": "未检测到有效语音",
        "notify.max_reached": "已达到录音上限，正在转写",
        "notify.finished_recording": "录音结束，正在转写",
        "text.repeated_hallucination": "（忽略重复幻听，无有效指令）",
        "error.no_speech_prefix": "上次未转写",
        "error.runtime_prefix": "上次运行错误",
        "cli.status_idle": "Codex Voice 状态：空闲。",
        "cli.status_running": "Codex Voice 状态：{status}（{label}），PID {pid}{suffix}{timestamp}。",
        "cli.no_active_recording": "没有正在进行的 Codex Voice 录音。",
        "cli.early_submit": "Codex Voice 刚开始录音，已忽略过早提交。",
        "cli.submitting": "正在提交当前 Codex Voice 录音。",
        "cli.canceled": "已取消 Codex Voice 录音 worker：{pid}。",
        "cli.started": "Codex Voice 已开始录音。再次按快捷键提交。PID：{pid}",
        "cli.canceled_by_user": "Codex Voice 已取消。",
        "cli.no_speech": "未检测到语音：{error}",
        "cli.error": "Codex Voice 错误：{error}",
        "cli.installed_at": "Codex Voice 安装位置：{root}",
        "cli.conda_env": "Conda 环境：{env}",
        "cli.python": "Python：{python}",
        "cli.max_recording": "最长录音：{seconds} 秒（{minutes:g} 分钟）",
        "cli.input_device": "输入设备：{device}",
        "cli.system_default": "系统默认",
        "cli.transcription_profile": "转录配置：{profile}",
        "cli.transcription_model": "转录模型：{backend} / {model}",
        "cli.ollama_transcription_model": "Ollama 转录模型：{model}",
        "cli.correction_profile": "纠错配置：{profile}",
        "cli.correction_model": "纠错模型：{backend} / {model}",
        "cli.ui_language": "界面语言：{language}（实际：{resolved}）",
        "cli.output_language_legacy": "旧输出语言字段：{language}",
        "cli.config_file": "配置文件：{path}",
        "cli.set_ui_language": "Codex Voice 界面语言已设置为：{language}（实际：{resolved}）",
        "cli.invalid_ui_language": "不支持的界面语言：{language}。请使用：{choices}。",
        "cli.set_input_device": "Codex Voice 输入设备已设置为：{label}",
        "cli.max_minutes_positive": "最长录音分钟数必须大于 0。",
        "cli.max_minutes_refused": "面板助手拒绝设置超过 10 分钟。",
        "cli.set_max_recording": "Codex Voice 最长录音已设置为 {seconds} 秒（{minutes:g} 分钟）。",
        "cli.set_transcription_profile": "Codex Voice 转录配置已设置为：{label}",
        "cli.set_ollama_transcription_model": "Codex Voice Ollama 转录模型已设置为：{label}",
        "cli.set_correction_profile": "Codex Voice 纠错配置已设置为：{label}",
        "cli.set_ollama_correction_model": "Codex Voice Ollama 纠错模型已设置为：{label}",
        "cli.transcription_ready": "Codex Voice 转录模型已准备好。",
        "cli.correction_ready": "Codex Voice 纠错模型已准备好。",
        "cli.correction_unloaded": "Codex Voice 纠错模型已从内存卸载。",
        "cli.ollama_unloaded": "Codex Voice Ollama 模型已卸载：{model}",
        "task.idle": "空闲",
        "task.state_unreadable": "模型任务状态不可读",
        "task.prepare_transcription": "准备转录模型：{model}",
        "task.prepare_correction": "准备纠错模型：{model}",
        "task.rule_correction": "规则纠错",
        "task.unload_model": "卸载模型：{model}",
        "task.checking": "正在检查模型配置",
        "task.loading_mlx": "正在下载或加载 MLX Whisper 模型",
        "task.loading_faster": "正在下载或加载 faster-whisper 模型",
        "task.warming_ollama_audio": "正在调用 Ollama 音频转录接口预热",
        "task.model_ready": "模型已准备好",
        "task.no_model_needed": "无需加载模型",
        "task.loading_ollama_memory": "正在让 Ollama 加载模型到内存",
        "task.model_loaded": "模型已加载到内存",
        "task.unloading": "正在从内存卸载模型",
        "task.unloaded": "模型已从内存卸载",
        "prompt.initial_terms": "以下是需要优先识别为标准写法的软件开发术语：\n{terms}",
        "prompt.system": (
            "你是一个保守但能理解上下文的语音转写校对器。用户正在通过语音向 AI 编程 Agent 下达任务。"
            "你的职责是只修正语音识别造成的词汇理解错误、中文多音字/同音/近音错词、技术术语错误、"
            "英文/缩写误识别、错别字、大小写、命令和文件名格式。尽量保持原文词序、句式、语气和信息密度。"
            "不要总结、扩写、翻译、润色、重排句子或补充用户没有说出的信息。只输出最终文本。"
        ),
        "prompt.mode.normal": (
            "当前模式是 normal。请尽量保持原文逐字顺序，只做必要的词汇、中文多音字/同音/近音上下文错词、"
            "术语、错别字和格式纠错。"
        ),
        "prompt.mode.strict": (
            "当前模式是 strict。可以整理成“目标 / 任务 / 约束 / 验收标准”结构，但不得新增、推断或重写用户没有说出的信息。"
        ),
        "prompt.clean_context": "本次请求是全新的独立上下文；只依据下面这段待纠错文本和术语表，不要引用、延续或记忆任何历史输入。",
        "prompt.language": (
            "输出语言要求：按简体中文理解和纠错，自然语言输出简体中文；英文技术词、命令、路径、文件名、变量名和缩写保留标准英文/代码写法。"
        ),
        "prompt.user": (
            "{mode_instruction}\n\n{clean_context}\n\n{language_instruction}\n\n"
            "术语表 JSON：\n{terms}\n\n待纠错文本：\n{text}\n\n"
            "只输出最终文本，不要解释。不要输出 JSON，不要加标题，除非用户原话要求标题或结构。"
        ),
    },
    "zh-Hant": {
        "language.system": "跟隨系統",
        "language.en": "English",
        "language.zh-Hans": "简体中文",
        "language.zh-Hant": "繁體中文",
        "language.ja": "日本語",
        "status.idle": "閒置",
        "status.recording": "正在錄音",
        "status.submitting": "正在結束錄音",
        "status.transcribing": "正在辨識",
        "status.correcting": "正在校正",
        "status.finalizing": "正在提交文字",
        "status.error": "出錯",
        "detail.recording_hint": "再按一次快捷鍵結束並轉寫",
        "detail.submitting": "正在結束錄音並準備轉寫",
        "detail.transcribing": "正在儲存錄音並辨識文字",
        "detail.correcting": "正在做術語和上下文校正",
        "detail.finalizing": "正在複製或貼上最終文字",
        "detail.stale": "狀態檔已過期，可能是上次程序異常退出",
        "notify.accessibility": "已複製到剪貼簿，請重新勾選輔助使用權限",
        "notify.auto_paste_failed": "已複製到剪貼簿，自動貼上失敗",
        "notify.recording": "正在錄音，再按一次快捷鍵結束",
        "notify.no_speech": "未偵測到有效語音",
        "notify.max_reached": "已達到錄音上限，正在轉寫",
        "notify.finished_recording": "錄音結束，正在轉寫",
        "text.repeated_hallucination": "（已忽略重複幻聽，無有效指令）",
        "error.no_speech_prefix": "上次未轉寫",
        "error.runtime_prefix": "上次執行錯誤",
        "cli.status_idle": "Codex Voice 狀態：閒置。",
        "cli.status_running": "Codex Voice 狀態：{status}（{label}），PID {pid}{suffix}{timestamp}。",
        "cli.no_active_recording": "沒有正在進行的 Codex Voice 錄音。",
        "cli.early_submit": "Codex Voice 剛開始錄音，已忽略過早提交。",
        "cli.submitting": "正在提交目前 Codex Voice 錄音。",
        "cli.canceled": "已取消 Codex Voice 錄音 worker：{pid}。",
        "cli.started": "Codex Voice 已開始錄音。再次按快捷鍵提交。PID：{pid}",
        "cli.canceled_by_user": "Codex Voice 已取消。",
        "cli.no_speech": "未偵測到語音：{error}",
        "cli.error": "Codex Voice 錯誤：{error}",
        "cli.installed_at": "Codex Voice 安裝位置：{root}",
        "cli.conda_env": "Conda 環境：{env}",
        "cli.python": "Python：{python}",
        "cli.max_recording": "最長錄音：{seconds} 秒（{minutes:g} 分鐘）",
        "cli.input_device": "輸入裝置：{device}",
        "cli.system_default": "系統預設",
        "cli.transcription_profile": "轉錄設定：{profile}",
        "cli.transcription_model": "轉錄模型：{backend} / {model}",
        "cli.ollama_transcription_model": "Ollama 轉錄模型：{model}",
        "cli.correction_profile": "校正設定：{profile}",
        "cli.correction_model": "校正模型：{backend} / {model}",
        "cli.ui_language": "介面語言：{language}（實際：{resolved}）",
        "cli.output_language_legacy": "舊輸出語言欄位：{language}",
        "cli.config_file": "設定檔：{path}",
        "cli.set_ui_language": "Codex Voice 介面語言已設定為：{language}（實際：{resolved}）",
        "cli.invalid_ui_language": "不支援的介面語言：{language}。請使用：{choices}。",
        "cli.set_input_device": "Codex Voice 輸入裝置已設定為：{label}",
        "cli.max_minutes_positive": "最長錄音分鐘數必須大於 0。",
        "cli.max_minutes_refused": "面板助手拒絕設定超過 10 分鐘。",
        "cli.set_max_recording": "Codex Voice 最長錄音已設定為 {seconds} 秒（{minutes:g} 分鐘）。",
        "cli.set_transcription_profile": "Codex Voice 轉錄設定已設定為：{label}",
        "cli.set_ollama_transcription_model": "Codex Voice Ollama 轉錄模型已設定為：{label}",
        "cli.set_correction_profile": "Codex Voice 校正設定已設定為：{label}",
        "cli.set_ollama_correction_model": "Codex Voice Ollama 校正模型已設定為：{label}",
        "cli.transcription_ready": "Codex Voice 轉錄模型已準備好。",
        "cli.correction_ready": "Codex Voice 校正模型已準備好。",
        "cli.correction_unloaded": "Codex Voice 校正模型已從記憶體卸載。",
        "cli.ollama_unloaded": "Codex Voice Ollama 模型已卸載：{model}",
        "task.idle": "閒置",
        "task.state_unreadable": "模型任務狀態不可讀",
        "task.prepare_transcription": "準備轉錄模型：{model}",
        "task.prepare_correction": "準備校正模型：{model}",
        "task.rule_correction": "規則校正",
        "task.unload_model": "卸載模型：{model}",
        "task.checking": "正在檢查模型設定",
        "task.loading_mlx": "正在下載或載入 MLX Whisper 模型",
        "task.loading_faster": "正在下載或載入 faster-whisper 模型",
        "task.warming_ollama_audio": "正在呼叫 Ollama 音訊轉錄介面預熱",
        "task.model_ready": "模型已準備好",
        "task.no_model_needed": "無需載入模型",
        "task.loading_ollama_memory": "正在讓 Ollama 將模型載入記憶體",
        "task.model_loaded": "模型已載入記憶體",
        "task.unloading": "正在從記憶體卸載模型",
        "task.unloaded": "模型已從記憶體卸載",
        "prompt.initial_terms": "以下是需要優先辨識為標準寫法的軟體開發術語：\n{terms}",
        "prompt.system": (
            "你是一個保守但能理解上下文的語音轉寫校對器。使用者正在透過語音向 AI 程式設計 Agent 下達任務。"
            "你的職責是只修正語音辨識造成的詞彙理解錯誤、中文多音字/同音/近音錯詞、技術術語錯誤、"
            "英文/縮寫誤識別、錯別字、大小寫、命令和檔名格式。盡量保持原文詞序、句式、語氣和資訊密度。"
            "不要總結、擴寫、翻譯、潤飾、重排句子或補充使用者沒有說出的資訊。只輸出最終文字。"
        ),
        "prompt.mode.normal": (
            "目前模式是 normal。請盡量保持原文逐字順序，只做必要的詞彙、中文多音字/同音/近音上下文錯詞、"
            "術語、錯別字和格式校正。"
        ),
        "prompt.mode.strict": (
            "目前模式是 strict。可以整理成「目標 / 任務 / 約束 / 驗收標準」結構，但不得新增、推斷或重寫使用者沒有說出的資訊。"
        ),
        "prompt.clean_context": "本次請求是全新的獨立上下文；只依據下面這段待校正文字和術語表，不要引用、延續或記憶任何歷史輸入。",
        "prompt.language": (
            "輸出語言要求：按繁體中文理解和校正，自然語言輸出繁體中文；英文技術詞、命令、路徑、檔名、變數名和縮寫保留標準英文/程式碼寫法。"
        ),
        "prompt.user": (
            "{mode_instruction}\n\n{clean_context}\n\n{language_instruction}\n\n"
            "術語表 JSON：\n{terms}\n\n待校正文字：\n{text}\n\n"
            "只輸出最終文字，不要解釋。不要輸出 JSON，不要加標題，除非使用者原話要求標題或結構。"
        ),
    },
    "ja": {
        "language.system": "システムに従う",
        "language.en": "English",
        "language.zh-Hans": "简体中文",
        "language.zh-Hant": "繁體中文",
        "language.ja": "日本語",
        "status.idle": "待機中",
        "status.recording": "録音中",
        "status.submitting": "録音終了中",
        "status.transcribing": "文字起こし中",
        "status.correcting": "補正中",
        "status.finalizing": "コピーまたは貼り付け中",
        "status.error": "エラー",
        "detail.recording_hint": "もう一度ショートカットを押すと送信して文字起こしします",
        "detail.submitting": "録音を終了して文字起こしを準備中",
        "detail.transcribing": "録音を保存して文字認識中",
        "detail.correcting": "用語と文脈を補正中",
        "detail.finalizing": "最終テキストをコピーまたは貼り付け中",
        "detail.stale": "状態ファイルが古く、前回のプロセスが異常終了した可能性があります",
        "notify.accessibility": "クリップボードにコピーしました。アクセシビリティ権限を再度有効にしてください。",
        "notify.auto_paste_failed": "クリップボードにコピーしました。自動貼り付けに失敗しました。",
        "notify.recording": "録音中です。もう一度ショートカットを押すと送信します。",
        "notify.no_speech": "有効な音声を検出できませんでした。",
        "notify.max_reached": "録音上限に達しました。文字起こししています。",
        "notify.finished_recording": "録音が終了しました。文字起こししています。",
        "text.repeated_hallucination": "（重複した幻覚出力を無視しました。有効な指示はありません）",
        "error.no_speech_prefix": "前回は文字起こしされませんでした",
        "error.runtime_prefix": "前回の実行でエラーが発生しました",
        "cli.status_idle": "Codex Voice status: idle.",
        "cli.status_running": "Codex Voice status: {status} ({label}), PID {pid}{suffix}{timestamp}.",
        "cli.no_active_recording": "実行中の Codex Voice 録音はありません。",
        "cli.early_submit": "Codex Voice の録音開始直後のため、早すぎる送信を無視しました。",
        "cli.submitting": "現在の Codex Voice 録音を送信しています。",
        "cli.canceled": "Codex Voice 録音 worker をキャンセルしました: {pid}。",
        "cli.started": "Codex Voice の録音を開始しました。もう一度ショートカットを押すと送信します。PID: {pid}",
        "cli.canceled_by_user": "Codex Voice をキャンセルしました。",
        "cli.no_speech": "音声を検出できませんでした: {error}",
        "cli.error": "Codex Voice エラー: {error}",
        "cli.installed_at": "Codex Voice のインストール先: {root}",
        "cli.conda_env": "Conda 環境: {env}",
        "cli.python": "Python: {python}",
        "cli.max_recording": "最大録音時間: {seconds} 秒（{minutes:g} 分）",
        "cli.input_device": "入力デバイス: {device}",
        "cli.system_default": "システム既定",
        "cli.transcription_profile": "音声認識設定: {profile}",
        "cli.transcription_model": "音声認識モデル: {backend} / {model}",
        "cli.ollama_transcription_model": "Ollama 音声認識モデル: {model}",
        "cli.correction_profile": "補正設定: {profile}",
        "cli.correction_model": "補正モデル: {backend} / {model}",
        "cli.ui_language": "UI 言語: {language}（実際: {resolved}）",
        "cli.output_language_legacy": "旧出力言語フィールド: {language}",
        "cli.config_file": "設定ファイル: {path}",
        "cli.set_ui_language": "Codex Voice UI 言語を設定しました: {language}（実際: {resolved}）",
        "cli.invalid_ui_language": "未対応の UI 言語です: {language}。次のいずれかを使ってください: {choices}。",
        "cli.set_input_device": "Codex Voice 入力デバイスを設定しました: {label}",
        "cli.max_minutes_positive": "最大録音分数は 0 より大きい必要があります。",
        "cli.max_minutes_refused": "パネルヘルパーからは 10 分を超える設定を拒否します。",
        "cli.set_max_recording": "Codex Voice 最大録音時間を {seconds} 秒（{minutes:g} 分）に設定しました。",
        "cli.set_transcription_profile": "Codex Voice 音声認識設定を設定しました: {label}",
        "cli.set_ollama_transcription_model": "Codex Voice Ollama 音声認識モデルを設定しました: {label}",
        "cli.set_correction_profile": "Codex Voice 補正設定を設定しました: {label}",
        "cli.set_ollama_correction_model": "Codex Voice Ollama 補正モデルを設定しました: {label}",
        "cli.transcription_ready": "Codex Voice 音声認識モデルの準備ができました。",
        "cli.correction_ready": "Codex Voice 補正モデルの準備ができました。",
        "cli.correction_unloaded": "Codex Voice 補正モデルをメモリからアンロードしました。",
        "cli.ollama_unloaded": "Codex Voice Ollama モデルをアンロードしました: {model}",
        "task.idle": "待機中",
        "task.state_unreadable": "モデルタスク状態を読めません",
        "task.prepare_transcription": "音声認識モデルを準備: {model}",
        "task.prepare_correction": "補正モデルを準備: {model}",
        "task.rule_correction": "ルール補正",
        "task.unload_model": "モデルをアンロード: {model}",
        "task.checking": "モデル設定を確認中",
        "task.loading_mlx": "MLX Whisper モデルをダウンロードまたはロード中",
        "task.loading_faster": "faster-whisper モデルをダウンロードまたはロード中",
        "task.warming_ollama_audio": "Ollama 音声認識 API をウォームアップ中",
        "task.model_ready": "モデルの準備ができました",
        "task.no_model_needed": "ロードするモデルはありません",
        "task.loading_ollama_memory": "Ollama のメモリへモデルをロード中",
        "task.model_loaded": "モデルをメモリへロードしました",
        "task.unloading": "モデルをメモリからアンロード中",
        "task.unloaded": "モデルをメモリからアンロードしました",
        "prompt.initial_terms": "次のソフトウェア開発用語は標準表記として優先的に認識してください:\n{terms}",
        "prompt.system": (
            "あなたは、文脈を理解するが保守的な音声文字起こし校正者です。ユーザーは音声で AI コーディング Agent に指示しています。"
            "音声認識による語彙の誤り、技術用語、英語や略語の誤認識、誤字、大小文字、コマンド、ファイル名、パスの表記だけを修正してください。"
            "元の語順、文体、語気、情報量をできるだけ保ってください。要約、拡張、翻訳、言い換え、文の並べ替え、ユーザーが言っていない情報の追加は禁止です。"
            "最終テキストだけを出力してください。"
        ),
        "prompt.mode.normal": (
            "現在のモードは normal です。元の語順をできるだけ保ち、必要な語彙、同音・近音・文脈上の誤り、"
            "技術用語、誤字、フォーマットだけを補正してください。"
        ),
        "prompt.mode.strict": (
            "現在のモードは strict です。「目標 / タスク / 制約 / 受け入れ条件」のように整理してもかまいませんが、"
            "ユーザーが言っていない情報を追加、推測、または書き換えてはいけません。"
        ),
        "prompt.clean_context": "このリクエストは独立した新しい文脈です。下の補正対象テキストと用語表だけを使い、過去入力、ログ、会話履歴を参照または記憶しないでください。",
        "prompt.language": (
            "言語要件: 自然言語部分は日本語として理解し、日本語で出力してください。技術用語、コマンド、パス、ファイル名、変数名、略語は標準的な英語またはコード表記を保持してください。"
        ),
        "prompt.user": (
            "{mode_instruction}\n\n{clean_context}\n\n{language_instruction}\n\n"
            "用語表 JSON:\n{terms}\n\n補正対象テキスト:\n{text}\n\n"
            "最終テキストだけを出力してください。説明は不要です。ユーザーが明示的に求めない限り、JSON やタイトルを出力しないでください。"
        ),
    },
}


def system_preferred_languages() -> list[str]:
    configured = os.environ.get("CODEX_VOICE_APPLE_LANGUAGES", "").strip()
    if configured:
        return [item.strip() for item in re.split(r"[,;]", configured) if item.strip()]

    try:
        result = subprocess.run(
            ["/usr/bin/defaults", "read", "-g", "AppleLanguages"],
            capture_output=True,
            text=True,
            check=False,
            timeout=1,
        )
    except Exception:
        result = None
    if result is not None and result.returncode == 0:
        languages = re.findall(r'"([^"]+)"|([A-Za-z][A-Za-z0-9_-]*)', result.stdout)
        flattened = [left or right for left, right in languages]
        if flattened:
            return flattened

    lang = os.environ.get("LANG", "").split(".", 1)[0]
    return [lang] if lang else ["en"]


def language_from_locale(locale: str) -> str | None:
    normalized = locale.strip().replace("_", "-")
    if not normalized:
        return None
    lowered = normalized.lower()
    if lowered.startswith("ja"):
        return "ja"
    if lowered.startswith("en"):
        return "en"
    if lowered.startswith("zh"):
        if any(token in lowered for token in ("hant", "-tw", "-hk", "-mo")):
            return "zh-Hant"
        return "zh-Hans"
    return None


def normalize_ui_language(value: Any) -> str:
    text = str(value or "system").strip()
    if text in SUPPORTED_UI_LANGUAGES:
        return text
    mapped = language_from_locale(text)
    return mapped if mapped in RUNTIME_LANGUAGES else "system"


def resolve_ui_language(
    config_or_language: dict[str, Any] | str | None = None,
    preferred_languages: list[str] | None = None,
) -> str:
    if isinstance(config_or_language, dict):
        configured = normalize_ui_language(config_or_language.get("ui_language", "system"))
    else:
        configured = normalize_ui_language(config_or_language)
    if configured != "system":
        return configured
    for language in preferred_languages or system_preferred_languages():
        mapped = language_from_locale(language)
        if mapped:
            return mapped
    return "en"


def language_label(config_or_language: dict[str, Any] | str | None, language: str) -> str:
    return t(config_or_language, f"language.{normalize_ui_language(language)}")


def t(config_or_language: dict[str, Any] | str | None, key: str, **kwargs: Any) -> str:
    language = resolve_ui_language(config_or_language)
    template = TRANSLATIONS.get(language, {}).get(key) or TRANSLATIONS["en"].get(key) or key
    if kwargs:
        return template.format(**kwargs)
    return template


def status_label(config_or_language: dict[str, Any] | str | None, status: str) -> str:
    return t(config_or_language, f"status.{status}")


def whisper_language(config_or_language: dict[str, Any] | str | None) -> str:
    language = resolve_ui_language(config_or_language)
    if language == "ja":
        return "ja"
    if language in {"zh-Hans", "zh-Hant"}:
        return "zh"
    return "en"


def build_initial_prompt_text(config_or_language: dict[str, Any] | str | None, terms: str) -> str:
    return t(config_or_language, "prompt.initial_terms", terms=terms)


def build_correction_system_prompt(config_or_language: dict[str, Any] | str | None) -> str:
    return t(config_or_language, "prompt.system")


def build_correction_user_content(
    config_or_language: dict[str, Any] | str | None,
    mode: str,
    clean_context: bool,
    terms: str,
    text: str,
) -> str:
    clean_text = t(config_or_language, "prompt.clean_context") if clean_context else ""
    return t(
        config_or_language,
        "prompt.user",
        mode_instruction=t(config_or_language, f"prompt.mode.{mode}"),
        clean_context=clean_text,
        language_instruction=t(config_or_language, "prompt.language"),
        terms=terms,
        text=text,
    )


def normalize_output_text(text: str, config_or_language: dict[str, Any] | str | None) -> str:
    language = resolve_ui_language(config_or_language)
    if language not in {"zh-Hans", "zh-Hant"}:
        return text

    converter_name = "t2s" if language == "zh-Hans" else "s2t"
    try:
        from opencc import OpenCC

        return OpenCC(converter_name).convert(text)
    except Exception:
        if language == "zh-Hant":
            traditional_map: dict[str, str | int | None] = {
                "这": "這",
                "个": "個",
                "为": "為",
                "还": "還",
                "会": "會",
                "录": "錄",
                "输": "輸",
                "简": "簡",
                "体": "體",
                "词": "詞",
                "汇": "彙",
                "错": "錯",
                "误": "誤",
                "档": "檔",
                "里": "裡",
                "线": "線",
                "对": "對",
                "后": "後",
                "处": "處",
                "发": "發",
                "检": "檢",
            }
            return text.translate(str.maketrans(traditional_map))
        simplified_map: dict[str, str | int | None] = {
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
        }
        return text.translate(str.maketrans(simplified_map))
