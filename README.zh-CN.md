# Codex Voice Input

本地优先的 macOS 语音输入工具。按一次内置全局快捷键开始录音，再按一次提交；Codex Voice 会按照状态栏设置里选择的语言进行转录、纠错和输出：英文、简体中文、繁体中文或日文。技术词、命令、路径、变量名和文件名会尽量保持标准英文或代码写法。最终文本会写入剪贴板，并且只有当前焦点确认是输入框时才自动粘贴。

语言版本：[English](README.md) | 简体中文 | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

## 适合谁

- 经常在 Codex Desktop、Cursor、VS Code、浏览器、聊天工具或任意文本框里用英文、简体中文、繁体中文或日文夹杂技术词输入。
- 希望转录和术语纠错主要在本机完成，不把音频默认发到外部服务。
- 希望全局快捷键由常驻状态栏 Agent 直接处理，响应足够轻。

## 核心能力

- 内置全局快捷键：默认 `Option + Space`，也可以在状态栏面板中重新录制。
- macOS 状态栏面板：开始、提交、取消、权限、模型、输入设备和日志入口集中在一个弹窗里。
- 四语全流程：界面语言设置也控制 Whisper 识别语言、Ollama 纠错提示词、CLI 用户输出和最终文本字形。
- 本地转录：默认使用 Apple Silicon 友好的 `mlx-whisper` large-v3-turbo，并保留 `faster-whisper` fallback。
- 本地纠错：默认使用 Ollama 的 `qwen3.6:35b-a3b`，保守修正识别错误、技术术语和格式。
- 统一粘贴策略：始终先写入剪贴板；只有当前焦点确认可编辑时才自动模拟 `Cmd+V`。
- 模型管理：自动启动 Ollama、自动加载当前 qwen 模型、保持 `keep_alive`，也可以从 UI 卸载已加载模型。

## 工作方式

```text
内置全局快捷键
        |
        v
com.codexvoice.agent LaunchAgent
        |
        +-- 录音、提交、取消、状态栏 UI
        +-- 解析界面/运行时语言
        +-- 按实际语言进行 Whisper 转录
        +-- terms.json 确定性术语替换
        +-- 按实际语言进行 Ollama 本地 LLM 纠错
        +-- pbcopy 写入剪贴板
        +-- 当前焦点是输入框时模拟 Cmd+V
```

## 系统要求

- macOS 13 或更新版本。
- Apple Silicon Mac 推荐；Intel Mac 可用但本地转录速度可能明显较慢。
- Conda、Miniconda、Miniforge 或 Anaconda。
- Homebrew 推荐安装 `ffmpeg` 和 `portaudio`。
- Ollama 可选但强烈推荐，用于本地 LLM 纠错。

## 安装

推荐把仓库直接放在默认运行目录：

```bash
git clone https://github.com/dataindustry/codex-voice.git ~/CodexVoice
cd ~/CodexVoice
bash ~/CodexVoice/bin/install.sh
```

如果你已经在别的目录克隆了仓库，先同步到默认运行目录：

```bash
mkdir -p ~/CodexVoice
rsync -a --exclude .git /path/to/codex-voice/ ~/CodexVoice/
bash ~/CodexVoice/bin/install.sh
```

安装脚本会完成这些事情：

- 创建 `bin/`、`config/`、`recordings/`、`transcripts/`、`logs/`、`state/`。
- 检查 Homebrew、`ffmpeg`、`portaudio` 和 Ollama。
- 创建或更新 Conda 环境 `codex-voice`。
- 从 `pyproject.toml` 以 editable package 方式安装 Codex Voice，并安装测试/静态检查工具。
- 给主程序和安装脚本设置可执行权限。
- 编译并启动 `com.codexvoice.agent` LaunchAgent。
- 编译原生 Swift 录音浮窗和状态栏 Agent。

只想重装 Agent、不重装 Python 依赖时：

```bash
bash ~/CodexVoice/bin/install.sh --skip-deps
```

检查 Agent 是否运行：

```bash
launchctl print gui/$(id -u)/com.codexvoice.agent
```

## AI Agent 安装 Playbook

当你想让 AI coding agent 在同一台 Mac 上安装或更新 Codex Voice 时，把这一节交给它执行。

目标：把源码安装或更新到 `~/CodexVoice`，尽量保留用户配置，编译菜单栏 Agent，并验证内置热键/Ollama 集成。

执行规则：

- 不要删除 `~/CodexVoice/config/terms.json`、`transcripts/`、录音、日志、状态文件或用户改过的配置，除非用户明确要求。
- 不要运行 `git reset --hard` 这类破坏性 git 命令。
- 如果仓库克隆在别处，先同步源码到 `~/CodexVoice`，再运行安装器。
- 如果 Ollama 不存在，只报告并给出 `ollama pull qwen3.6:35b-a3b`；不要擅自下载大模型。

推荐命令：

```bash
mkdir -p ~/CodexVoice
rsync -a --exclude .git /path/to/codex-voice/ ~/CodexVoice/
bash ~/CodexVoice/bin/install.sh
```

验证命令：

```bash
launchctl print gui/$(id -u)/com.codexvoice.agent
codex-voice --status
codex-voice-config --show
codex-voice-config --list-ollama-models
```

安装后，人类用户仍需要在 macOS 系统设置中授予麦克风和辅助功能权限。默认内置快捷键是 `Option + Space`。

## macOS 权限

第一次使用时需要两个权限。

麦克风权限：

```text
System Settings -> Privacy & Security -> Microphone
```

给 `Codex Voice Agent.app` 或触发录音的终端/宿主授权。如果没有弹窗，可在状态栏面板里点“麦克风授权”，再重新触发录音。

辅助功能权限：

```text
System Settings -> Privacy & Security -> Accessibility
```

给这个应用授权：

```text
~/CodexVoice/Codex Voice Agent.app
```

辅助功能权限只用于确认当前焦点是否为可编辑控件，以及在确认可编辑时模拟 `Cmd+V`。如果焦点不在输入框上，Codex Voice 不会强行粘贴，只把文本留在剪贴板。

源码安装使用 ad-hoc 签名。Agent 重新编译或重签名后，安装脚本会用 `tccutil` 重置辅助功能条目并打开系统设置；macOS 仍需要用户手动重新勾选授权。

## 隐私默认值

Codex Voice 是本地优先工具。默认情况下，录音只作为临时文件存在，转录后删除：

```json
"save_recordings": false,
"save_transcripts": true
```

逐字稿会保存到 `~/CodexVoice/transcripts`，方便回看识别质量。如果不希望 raw text、final text 和纠错元数据落盘，把 `save_transcripts` 改成 `false`。

## 内置快捷键

状态栏 Agent 启动时会注册原生全局快捷键，默认是 `Option + Space`。

可以在状态栏面板里：

- 录制新的快捷键；
- 清除当前快捷键；
- 恢复默认 `Option + Space`。

按下快捷键时，Agent 会直接调用 `codex-voice.py --toggle`。旧的外部触发文件集成已经从主源码树移除，快捷键由常驻 Agent 统一处理。

## 语言和输出策略

Codex Voice 不自动检测说话人的语言。设置浮层里选择的语言就是整条处理链路的产品策略：

| 设置 | Whisper 语言 | 纠错/输出行为 |
| --- | --- | --- |
| `跟随系统` | 根据 macOS 首选语言解析；不支持的系统语言默认英文。 | 使用下方对应的实际语言。 |
| `English` | `en` | 按英文纠错并输出英文。 |
| `简体中文` | `zh` | 按简体中文纠错并输出简体中文；英文技术词保留英文。 |
| `繁體中文` | `zh` | 按繁体中文纠错并输出繁体中文；英文技术词保留英文。 |
| `日本語` | `ja` | 按日文纠错并输出日文；英文技术词保留英文。 |

可以在状态栏面板的设置浮层切换，也可以用 CLI：

```bash
codex-voice-config --set-ui-language system
codex-voice-config --set-ui-language en
codex-voice-config --set-ui-language zh-Hans
codex-voice-config --set-ui-language zh-Hant
codex-voice-config --set-ui-language ja
```

## Ollama 设置

安装 Ollama 后，先拉取推荐纠错模型：

```bash
ollama pull qwen3.6:35b-a3b
```

如果你的 Ollama 不在默认 `127.0.0.1:11434`，建议用 launchd 环境变量告诉 Agent：

```bash
launchctl setenv OLLAMA_HOST 127.0.0.1:11435
bash ~/CodexVoice/bin/install-launch-agents.sh
```

Codex Voice 的 Ollama 地址解析顺序：

1. `OLLAMA_HOST`
2. `launchctl getenv OLLAMA_HOST`
3. 用户显式配置的非默认 `ollama_base_url` 或 `ollama_url`
4. 默认 `http://127.0.0.1:11434`

查看模型扫描结果：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice-config.py --list-ollama-models
```

预热当前纠错模型：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice-config.py --prepare-current-correction-model
```

默认纠错配置重点：

```json
"ollama_model": "qwen3.6:35b-a3b",
"ollama_num_ctx": 4000,
"ollama_num_predict": 256,
"ollama_keep_alive": -1,
"ollama_timeout_seconds": 7,
"ollama_skip_simple_utterances": true
```

说明：

- `keep_alive: -1` 是 Ollama 请求参数，表示尽量把 qwen 模型保留在内存里；它和 macOS LaunchAgent 的 `KeepAlive` 无关。
- `num_ctx: 4000` 面向普通十分钟以内语音转写后的纠错场景。非常长的逐字稿仍建议分段处理。
- 如果 Ollama 已安装但服务没启动，Agent 会尝试自动启动或唤醒 Ollama。
- 如果默认 qwen 模型没有安装，界面会用当前语言显示 `qwen3.6:35b-a3b` 未安装；程序不会自动下载大模型。

## 模型选择建议

转录模型：

| 模型 | 推荐程度 | 说明 |
| --- | --- | --- |
| `mlx-community/whisper-large-v3-turbo` | 默认推荐 | Apple Silicon 上速度和准确率比较均衡，是默认路线。 |
| `faster-whisper large-v3-turbo` | 兼容备用 | MLX 不可用时使用，通常更慢，但覆盖面更广。 |
| Ollama audio/Whisper 类模型 | 实验性 | 只有本机 Ollama 检测到具备 audio 能力或名称像 ASR/Whisper 的模型时才显示。 |

纠错模型：

| 模型 | 推荐程度 | 说明 |
| --- | --- | --- |
| `qwen3.6:35b-a3b` | 默认推荐 | 多语言口述纠错、IT 术语保留和保守改写的本地默认选择。需要较多内存，适合常驻加载。 |
| 中等尺寸 Qwen / coder 模型 | 可选 | 内存压力较小时可以尝试，响应更快，但中文口述纠错稳定性通常弱于默认 35B。 |
| `qwen2.5-coder:1.5b` | 仅建议测速 | 很快，但容易把自然口述改得太像代码或英文，不建议长期默认使用。 |
| `规则纠错（不使用 LLM）` | 快速兜底 | 不依赖 Ollama，适合 Ollama 未安装、模型未下载或只需要确定性术语替换时使用。 |

选择原则：

- 想要质量：保留默认 `mlx-whisper large-v3-turbo` + `qwen3.6:35b-a3b`。
- 想要低延迟：保持 qwen 常驻加载，短句让规则纠错直接处理。
- 想要省内存：改用规则纠错，或手动选择更小的 Ollama 文本模型。

## 界面和截图说明

下面的图片是简体中文界面截图说明。其他语言 README 会引用各自语言的截图路径，之后可以按语言用同名真实截图替换这些 SVG，README 链接无需改变。

### 状态栏主面板

![状态栏主面板截图说明](docs/assets/screenshots/zh-CN/status-panel.svg)

主面板是日常使用 Codex Voice 的主要入口：

- 顶部状态行：圆点和文字显示空闲、录音、转写或错误状态；计时器显示当前录音时长；最长录音时间可以直接调整；红色按钮用于退出 Agent。
- 波形区域：录音或测试输入设备时用于确认麦克风有输入。
- 录音操作：`开始`、`提交`、`取消` 分别对应开始录音、提交当前录音和放弃当前录音。
- 权限与设置：语言选择、麦克风权限、辅助功能权限、内置快捷键录制、清除、恢复默认，以及录音浮窗开关都在这里管理。
- 标签页：`转录模型`、`纠错模型`、`输入设备` 切换下方卡片区；卡片区高度跟随当前页内容收紧，不保留其他标签页的旧高度。
- 底部摘要：集中显示当前状态、转录模型、纠错模型和输入设备，方便确认最终生效配置。

### 模型卡片

![模型卡片截图说明](docs/assets/screenshots/zh-CN/model-cards.svg)

模型卡片用于选择转录模型、纠错模型和输入设备：

- 每张卡片显示来源、模型名、参数规模、架构和厂商；没有对应信息时会保持简洁，不用空白硬撑高度。
- 同一组卡片保持等高，但高度由内容自动测量，长模型名会在固定宽度内换行。
- 当前选中的卡片会高亮；不可用卡片会说明原因，例如正在扫描、正在启动 Ollama、未安装 qwen，或没有检测到输入设备。
- 卡片列表可以横向拖动或滚动，多个 Ollama 模型和多个输入设备不会挤压布局。
- 已加载的 Ollama 模型右上角会出现圆形 `X`。点击后只把模型从内存卸载，不删除磁盘上的模型文件。
- 如果 qwen 已安装但尚未加载，Codex Voice 会在卡片区显示加载状态，并使用配置里的 Ollama `keep_alive` 和上下文长度预热模型。

### 内置快捷键

![内置快捷键截图说明](docs/assets/screenshots/zh-CN/native-hotkey.svg)

设置浮层用于录制和管理原生全局快捷键：

- 默认快捷键是 `Option + Space`。
- 普通组合键必须包含至少一个修饰键；保存前会用 macOS 公开的热键注册 API 做一次可用性检查。
- 双击修饰键手势，例如双击 Control，也可以录制；但 macOS 没有公开 API 可以可靠检查这类手势是否被其他应用占用，因此不会标记为“已检测无冲突”。
- `清除` 会禁用当前内置快捷键；`默认` 会恢复 `Option + Space`。
- 设置浮层打开时会挡住下面的卡片区，底层卡片不会继续响应 hover、点击或滚轮。

### 退出并卸载模型

![退出确认截图说明](docs/assets/screenshots/zh-CN/quit-unload.svg)

退出流程会明确处理仍在运行的录音和仍在内存中的 Ollama 模型：

- 如果当前还有录音 worker，Codex Voice 会先询问是否取消录音并退出。
- 如果 Ollama 当前还有已加载模型，弹窗会列出模型名称，并提供 `退出并卸载模型`、`仅退出`、`取消`。
- `退出并卸载模型` 会向 Ollama 发送 `keep_alive: 0`，只释放内存中的模型，不删除已安装模型。
- 卸载失败会提示，但不会让 Agent 无限卡在退出流程里。

## 常用操作

开始和提交：

```text
按一次内置快捷键 -> 开始录音
再按一次同一个快捷键 -> 提交录音
```

设置最长录音时间：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice-config.py --set-max-minutes 10
```

打开配置：

```bash
open -e ~/CodexVoice/config/config.json
```

打开术语表：

```bash
open -e ~/CodexVoice/config/terms.json
```

查看转写记录：

```bash
open ~/CodexVoice/transcripts
```

查看日志：

```bash
tail -n 120 ~/CodexVoice/logs/codex-voice.log
tail -n 120 ~/CodexVoice/logs/com.codexvoice.agent.err.log
```

## 配置文件

主要配置：

```text
~/CodexVoice/config/config.json
```

重要语言字段：

```json
"ui_language": "system"
```

`ui_language` 可以是 `system`、`en`、`zh-Hans`、`zh-Hant` 或 `ja`。它控制界面文本、CLI 用户输出、Whisper 识别语言、Ollama 纠错提示词和最终输出字形。`output_language`、`force_simplified_chinese` 等旧字段仍可兼容读取，但新的配置不建议依赖它们。

术语和错词替换：

```text
~/CodexVoice/config/terms.json
```

纠错提示词：

```text
~/CodexVoice/config/correction_prompt.txt
```

确定性替换会先于 Ollama 纠错执行。适合放进 `terms.json` 的内容包括项目名、库名、命令、文件名、专有缩写和稳定错词。

## 故障排查

内置快捷键无法使用：

```bash
tail -n 120 ~/CodexVoice/logs/codex-voice.log
open -e ~/CodexVoice/config/config.json
```

打开状态栏面板。如果显示“快捷键不可用/可能冲突”，录制一个新的组合键，或恢复默认值。

Agent 没有运行：

```bash
bash ~/CodexVoice/bin/install-launch-agents.sh
launchctl print gui/$(id -u)/com.codexvoice.agent
```

Ollama 模型未显示：

```bash
which ollama
ollama list
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice-config.py --list-ollama-models
```

如果使用非默认端口，先设置 `OLLAMA_HOST` 并重启 Agent。

不能自动粘贴：

- 给 `~/CodexVoice/Codex Voice Agent.app` 授予辅助功能权限。
- 如果刚重新编译过 Agent，请在安装脚本重置并打开系统设置后重新勾选辅助功能权限。
- 确认当前焦点是文本框或文本区。
- 即使不自动粘贴，最终文本也已经在剪贴板里，可以手动 `Cmd+V`。

录音没有声音：

- 检查麦克风权限。
- 在状态栏面板的“输入设备”标签页选择正确设备。
- 点击“测试输入”查看 RMS 和 Peak 是否变化。

## 卸载或停止

停止 Agent：

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.codexvoice.agent.plist
```

删除 LaunchAgent：

```bash
rm -f ~/Library/LaunchAgents/com.codexvoice.agent.plist
```

删除运行目录：

```bash
rm -rf ~/CodexVoice
```

如果只想退出本次运行，点击状态栏面板右上角红色退出按钮即可。LaunchAgent 的 macOS `KeepAlive` 为 `false`，用户退出后不会立刻被系统自动拉起。
