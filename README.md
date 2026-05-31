# Codex Voice Input

Codex Voice Input 是一个本地 macOS 语音输入层：通过 Raycast 全局快捷键录音，把中文夹杂 IT 英文术语的口述内容转成文本，经过术语纠错后复制到剪贴板，并可自动粘贴到 Codex Desktop、OpenCode、Cursor、VS Code、浏览器输入框等当前前台输入位置。

它不会修改 Codex Desktop，也不会改系统代理。所有文件默认放在 `~/CodexVoice`。

## 架构

```text
Raycast Script Command
        |
        v
~/CodexVoice/bin/codex-voice-trigger.sh
        |
        v
~/CodexVoice/state/triggers/*
        |
        v
com.codexvoice.agent LaunchAgent
        |
        v
~/CodexVoice/bin/codex-voice.py --toggle
        |
        +-- sounddevice 录音 + RMS 静音检测
        |      Raycast 后台模式默认等第二次触发提交录音
        |
        +-- mlx-whisper 转录
        |      fallback: faster-whisper
        |
        +-- terms.json 规则替换
        |
        +-- Ollama 本地 LLM 纠错
        |      fallback: 规则替换文本
        |
        +-- pbcopy 写入剪贴板
        |
        +-- Codex Voice Agent 原生模拟 Cmd+V

同一个 Codex Voice Agent 也会读取 ~/CodexVoice/state/status.json，
在 macOS 状态栏显示：黑色空闲、绿色录音、黄色识别/纠错。
```

## 安装

先确认文件已经在 `~/CodexVoice`，然后运行：

```bash
bash ~/CodexVoice/bin/install.sh
```

安装脚本会：

- 创建 `bin/`、`config/`、`raycast/`、`recordings/`、`transcripts/`、`logs/`、`state/`。
- 检查 Homebrew、`ffmpeg`、`portaudio`、Ollama、Raycast。
- 创建或更新 Conda 环境 `codex-voice`。
- 安装 `environment.yml` 和 `requirements.txt` 里的依赖。
- 设置主程序和 Raycast 脚本的可执行权限。
- 编译并启动唯一的 `com.codexvoice.agent` LaunchAgent，负责状态栏、Raycast 触发、录音提交和取消入口。
- 编译原生 Swift 录音浮窗；浮窗不会在 Dock 里显示 `Python 3.12`。

当前安装位置：

```text
~/CodexVoice
```

当前默认 Python 环境：

```text
~/anaconda3/envs/codex-voice
```

如果你想手动管理 Conda 环境，也可以直接运行：

```bash
conda env create -f ~/CodexVoice/environment.yml
conda run -n codex-voice python -m pip install -r ~/CodexVoice/requirements.txt
```

Docker 不作为默认方案，因为这个工具需要访问 macOS 麦克风、Raycast、AppleScript 粘贴和桌面浮窗，容器里会失去这些用户会话权限。

如果 `ffmpeg` 或 `portaudio` 缺失：

```bash
brew install ffmpeg portaudio
```

如果只想检查脚本和权限，不安装 Python 依赖：

```bash
bash ~/CodexVoice/bin/install.sh --skip-deps
```

## Raycast 配置

1. 打开 Raycast 设置。
2. 找到 Extensions -> Script Commands。
3. 添加目录：`~/CodexVoice/raycast`。
4. 你会看到四个命令：
   - `Codex Voice Input`
   - `Codex Voice Copy Only`
   - `Codex Voice Strict`
   - `Codex Voice Config`
5. 给 `Codex Voice Input` 绑定全局快捷键，例如 `Option + Space`。

如果 Raycast 找不到脚本，先确认：

```bash
ls -l ~/CodexVoice/raycast
```

这些 `.sh` 文件都应该有可执行权限。

Codex Voice Agent 状态：

```bash
launchctl print gui/$(id -u)/com.codexvoice.agent
```

## Ollama 配置

当前默认复用本机已有模型：

```json
"ollama_model": "qwen3.6:35b-a3b",
"ollama_fallback_models": [],
"ollama_timeout_seconds": 7,
"ollama_num_predict": 256,
"ollama_num_ctx": 4096,
"ollama_think": false,
"ollama_keep_alive": -1,
"ollama_skip_simple_utterances": true,
"ollama_simple_max_chars": 8,
"ollama_reject_aggressive_rewrite": true,
"output_language": "zh-Hans+en",
"force_simplified_chinese": true
```

极短句会跳过 Ollama，只执行规则替换，避免“继续”“好的”这类指令等待 35B。超过 8 个非空白字符的中文句子会进入 Ollama，以便按上下文修正“启动向/启动项”“后台中午/后台进程”这类中文多音字、同音或近音错词。修正提示词仍保持保守，只修语音识别词汇、技术术语、错别字和格式；如果模型输出看起来像大幅重写，会自动丢弃并使用规则纠错文本。

最终输出会强制为“英文技术词 + 简体中文”。如果 Whisper 或 Ollama 偶尔给出繁体字，程序会在复制/粘贴前转成简体。

查看本机模型：

```bash
ollama list
```

默认继续使用 `qwen3.6:35b-a3b`，因为它对中文口述纠错和术语替换更稳。冷启动可能接近 10 秒，热启动通常明显更快；`keep_alive: -1` 会让 Ollama 尽量一直保留模型在内存中，但每次纠错请求仍是全新的独立上下文。

如果想改成更小或更快的模型，编辑：

```bash
open -e ~/CodexVoice/config/config.json
```

例如：

```json
"ollama_model": "qwen2.5-coder:1.5b"
```

注意：`qwen2.5-coder:1.5b` 很快，但可能把普通中文口述改成英文或 JSON，更适合临时测速，不建议默认使用。

也可以直接在状态栏“纠错模型”菜单里选择。菜单按三段排列：第一段是内置纠错模型，例如 `规则纠错（不使用 LLM）`；第二段是 “Ollama 已安装纠错模型”，会列出本机 `ollama list` 扫描出的文本模型；第三段是 “外接在线 API”，OpenAI API 目前只作为未启用的预留项显示。Embedding 模型会被自动排除。

选择纠错模型后，Agent 会自动预热当前模型；如果是 Ollama 模型，会请求 Ollama 将它加载到内存并按配置保持 `keep_alive`。准备或卸载过程中，再打开“纠错模型”菜单会看到动态进度条。菜单里的“从内存卸载当前纠错模型”只释放内存，不删除模型文件。

Ollama 不可用、超时或输出为空时，程序会退回到规则替换后的文本，不会中断整个输入流程。

## Whisper 模型

默认配置针对 Apple Silicon：

```json
"transcription_profile": "mlx-whisper-turbo",
"whisper_backend": "mlx-whisper",
"whisper_model": "mlx-community/whisper-large-v3-turbo",
"whisper_fallback_backend": "faster-whisper",
"whisper_fallback_model": "large-v3-turbo"
```

第一次运行会下载 Whisper 模型，可能比较慢。后续会使用本地缓存。

如果 MLX 转录失败，程序会尝试 `faster-whisper` fallback。`faster-whisper` 在 Apple Silicon 上通常走 CPU，速度可能比 MLX 慢。

状态栏菜单里的“转录模型”可以切换：

- `MLX Whisper large-v3-turbo`：默认推荐路线。
- `faster-whisper large-v3-turbo`：兼容路线。
- `Ollama 已安装转录模型`：通过本机 Ollama `/api/tags` 和 `/api/show` 扫描，只显示具备 `audio` 能力或名称看起来像 ASR/Whisper 的模型；当前未检测到时会显示“未检测到 Ollama 转录模型”。
- `OpenAI API（未启用）`：预留入口，当前不会发起外部请求。

选择转录模型后，状态栏 Agent 会在后台自动准备当前模型。内置模型还没下载时会触发下载/加载；再次打开“转录模型”菜单时，顶部会显示一个动态进度条。也可以手动点“预热当前转录模型”。

## 术语表

编辑：

```bash
open -e ~/CodexVoice/config/terms.json
```

常用内容：

- `agent_tools`：Codex、MCP、Raycast、AGENTS.md 等。
- `frontend` / `backend` / `devops`：框架、库、数据库、部署工具。
- `commands`：常用命令。
- `project_specific`：项目专有词、文件名、路径、包名。
- `common_misrecognitions`：确定性的错词替换，例如“麦cp”到 `MCP`、“派普恩皮埃姆”到 `pnpm`。

确定性替换会先于 LLM 纠错执行。

## 使用方式

普通模式，转录纠错后复制并自动粘贴：

```bash
python ~/CodexVoice/bin/codex-voice.py
```

Raycast 脚本默认使用 toggle 模式：第一次按快捷键开始后台录音，第二次按同一个快捷键会提交当前录音。后台模式不会因为短暂停顿或不说话超时自动提交；如果忘记第二次按键，5 分钟安全上限会结束录音并转写，避免麦克风一直开着。
Raycast 自身只写入一个触发文件并立即返回；常驻的 `com.codexvoice.agent` LaunchAgent 会在后台处理录音和提交，所以 Raycast 不会等待 Python、Whisper 或 Ollama。
状态栏常驻显示 `● CV` / `● REC`：黑色表示空闲，绿色表示正在录音，黄色表示正在识别、转写、纠错或粘贴。点击状态栏图标可以提交当前录音、取消当前录音、切换“显示录音浮窗”、选择转录模型、选择纠错模型、选择输入设备、请求粘贴权限、打开配置、打开转录记录和日志。开启“显示录音浮窗”时，录音中会显示一个置顶的 `REC 正在录音` 小浮窗，带有 `00:00 / 05:00` 计时；结束录音时浮窗会自动关闭。关闭后只看状态栏颜色，不显示浮窗。默认不再发送开始/结束通知。自动粘贴前会确认当前焦点是可编辑文本控件；任何应用里的文本框都会自动粘贴。如果当前焦点明确不是文本框，普通模式不会覆盖原剪贴板；Codex/OpenCode 作为例外会保留一份到剪贴板，方便手动粘贴。

当前最长录音/识别时长是 `300` 秒，也就是 5 分钟。16kHz 单声道 wav 约 9.6MB；按普通中文口述速度，大约可覆盖 900 到 1200 个汉字左右，实际转写时间取决于内容长度。

可以用 Raycast 里的 `Codex Voice Config` 修改最长录音分钟数，也可以在终端运行：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice-config.py --set-max-minutes 5
```

查看当前安装位置和配置：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice-config.py --show
```

```bash
python ~/CodexVoice/bin/codex-voice.py --toggle
python ~/CodexVoice/bin/codex-voice.py --submit-current
python ~/CodexVoice/bin/codex-voice.py --cancel-current
python ~/CodexVoice/bin/codex-voice.py --status
```

只复制到剪贴板，不自动粘贴：

```bash
python ~/CodexVoice/bin/codex-voice.py --mode copy-only
```

结构化严格模式：

```bash
python ~/CodexVoice/bin/codex-voice.py --mode strict
```

只输出到 stdout，不复制不粘贴：

```bash
python ~/CodexVoice/bin/codex-voice.py --stdout-only
```

Raycast 里推荐先使用 `Codex Voice Copy Only` 测试，确认转录和剪贴板正常后，再使用自动粘贴模式。

## macOS 权限

首次运行可能需要授权：

- 麦克风权限：Raycast、Terminal、Python 或你触发脚本的宿主进程。
- 辅助功能权限：`Codex Voice Agent.app`，用于原生模拟 `Cmd+V`。

路径通常是：

```text
System Settings -> Privacy & Security -> Microphone
System Settings -> Privacy & Security -> Accessibility
```

如果已经确认是文本框但自动粘贴失败，文本仍会保留在剪贴板里，可以手动 `Cmd+V`。如果当前焦点明确不是文本框，普通模式会保留原剪贴板不变。

## 历史记录

成功转录后会保存 Markdown 到：

```text
~/CodexVoice/transcripts/
```

默认录音文件保存到：

```text
~/CodexVoice/recordings/
```

日志文件：

```text
~/CodexVoice/logs/codex-voice.log
```

如不想保存录音，可在 `config.json` 里设置：

```json
"save_recordings": false
```

## 测试

安装后先测试帮助命令：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice.py --help
```

然后测试只复制模式：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice.py --mode copy-only
```

测试 Raycast toggle 行为时，按一次快捷键开始录音，说完后再按一次同一个快捷键提交。

建议说：

```text
请帮我检查麦cp server 和派普恩皮埃姆 build 的问题
```

期望最终文本包含 `MCP server` 和 `pnpm build`。

默认 Raycast 测试节奏：

```text
按一次快捷键 -> 菜单栏变绿色 `● REC` -> 说话 -> 再按一次同一个快捷键 -> 菜单栏变黄色 `● CV`
```

## 常见问题

### 没有录到音

先检查麦克风权限，然后看日志：

```bash
tail -n 80 ~/CodexVoice/logs/codex-voice.log
```

如果周围环境很吵，调高或调低：

```json
"silence_threshold": 0.006,
"min_audio_rms": 0.0048,
"min_audio_peak": 0.02
```

如果出现 `address address...`、`HelloHello...`、`從從從...` 这类重复文本，通常是短噪声触发了 Whisper 幻听。当前配置会先按整段音频 RMS/peak 过滤低能量噪声，再拦截重复幻听，避免复制或粘贴垃圾文本。

### Raycast 一直转圈或录音不结束

现在 Raycast 入口是 `@raycast.mode silent`，只写触发文件，不直接执行 Python。再次触发同一个命令会由 `com.codexvoice.agent` 提交当前录音：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice.py --submit-current
```

如果想直接取消当前后台 worker：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice.py --cancel-current
```

如果状态文件异常，可删除：

```bash
rm -f ~/CodexVoice/state/recording.pid ~/CodexVoice/state/submit.request
```

如果 Agent 没在运行，重新安装 LaunchAgent：

```bash
~/CodexVoice/bin/install-launch-agents.sh
```

### 状态栏图标没有出现

状态栏图标由原生 Swift 小程序提供，并调用 Conda 里的 Python 语音流水线。重新编译并启动：

```bash
~/CodexVoice/bin/install-launch-agents.sh
```

如果仍然没有出现，检查日志：

```bash
tail -n 80 ~/CodexVoice/logs/com.codexvoice.agent.err.log
```

### 无法自动粘贴

给 `~/CodexVoice/Codex Voice Agent.app` 授予辅助功能权限。已经确认是文本框时，如果自动粘贴失败，文本会保留在剪贴板里。如果当前焦点明确不是文本框，程序会主动跳过粘贴并保留原剪贴板；Codex/OpenCode 例外，会复制到剪贴板作为兜底。

### Whisper 模型加载慢

第一次运行需要下载并加载模型。后续会快很多。若仍然太慢，可以把 `whisper_model` 换成较小的 MLX Whisper 模型。

### Ollama 纠错失败

确认服务在运行：

```bash
ollama list
```

如果模型太慢，可以临时改用小模型测速：

```json
"ollama_model": "qwen2.5-coder:1.5b"
```

但小模型纠错质量明显不如 `qwen3.6:35b-a3b`。当前更推荐保留 35B，并依靠短句跳过、`num_ctx=4096`、7 秒超时和重复幻听过滤减少无效等待。

### 技术词识别不准

优先往 `terms.json` 的 `common_misrecognitions` 添加确定性替换，再补充到对应术语分类。

### Raycast 找不到脚本

确认目录添加的是：

```text
~/CodexVoice/raycast
```

确认脚本可执行：

```bash
chmod +x ~/CodexVoice/raycast/*.sh
```

## 后续升级

- Raycast Extension 版，使用 `Clipboard.paste` 和更好的 UI 状态。
- Silero VAD，替代 RMS 阈值检测。
- 实时字幕浮窗。
- MCP server，读取最近语音记录或把转录历史作为 Agent 上下文。
- OpenAI API 或其他 HTTP LLM API 作为可选纠错后端。
