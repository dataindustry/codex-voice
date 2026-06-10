# Codex Voice Input

本機優先的 macOS 語音輸入工具。按一次內建全域快捷鍵開始錄音，再按一次提交；Codex Voice 會依照狀態列設定中選取的語言進行轉錄、校正與輸出：英文、簡體中文、繁體中文或日文。技術詞、命令、路徑、變數名和檔名會盡量保留標準英文或程式碼寫法。最終文字會寫入剪貼簿，且只有目前焦點確認是輸入框時才自動貼上。

語言版本：[English](README.md) | [简体中文](README.zh-CN.md) | 繁體中文 | [日本語](README.ja.md)

## 適合誰

- 經常在 Codex Desktop、Cursor、VS Code、瀏覽器、聊天工具或任何文字輸入框中，用英文、簡體中文、繁體中文或日文夾雜技術詞輸入。
- 希望轉錄與術語校正主要在本機完成，不預設把音訊送到外部服務。
- 希望全域快捷鍵由常駐狀態列 Agent 直接處理，反應足夠輕。

## 核心能力

- 內建全域快捷鍵：預設 `Option + Space`，也可以在狀態列面板中重新錄製。
- macOS 狀態列面板：開始、提交、取消、權限、模型、輸入裝置與日誌入口集中在同一個彈窗。
- 統一轉錄模型分頁：Qwen3-ASR 和 MLX Whisper 都在同一個模型選擇區中選擇。
- 可選 MLX 校正：Qwen3.6 文字校正可以接在任一轉錄模型之後；再次點擊已選取的校正卡片即可關閉校正。
- 四語全流程：介面語言設定同時控制 ASR 語言、校正提示詞、CLI 使用者輸出和最終文字字形。
- 持久本機 MLX 服務：退出選單列 Agent 不會卸載模型，使用者可在介面主動卸載。
- 統一貼上策略：一定先寫入剪貼簿；只有目前焦點確認可編輯時才模擬 `Cmd+V`。
- 模型管理：從 ModelScope 下載、載入到 MLX 記憶體、查看駐留狀態，並從 UI 卸載模型。

## 工作方式

```text
內建全域快捷鍵
        |
        v
com.codexvoice.agent LaunchAgent
        |
        +-- 錄音、提交、取消、狀態列 UI
        +-- 解析介面/執行時語言
        +-- 轉錄模型：Qwen3-ASR 或 MLX Whisper
        +-- terms.json/確定性規則
        +-- 可選 Qwen3.6 文字校正
        +-- 全部本機模型共用獨立的持久 MLX 模型服務
        +-- pbcopy 寫入剪貼簿
        +-- 目前焦點是輸入框時模擬 Cmd+V
```

## 系統需求

- macOS 13 或更新版本。
- Apple Silicon Mac；本機 MLX 執行環境是為 Apple Silicon 設計。
- Conda、Miniconda、Miniforge 或 Anaconda。
- 建議用 Homebrew 安裝 `ffmpeg` 和 `portaudio`。

## 安裝

建議直接把倉庫放在預設執行目錄：

```bash
git clone https://github.com/dataindustry/codex-voice.git ~/CodexVoice
cd ~/CodexVoice
bash ~/CodexVoice/bin/install.sh
```

如果已經在其他目錄 clone，先同步到預設執行目錄：

```bash
mkdir -p ~/CodexVoice
rsync -a --exclude .git /path/to/codex-voice/ ~/CodexVoice/
bash ~/CodexVoice/bin/install.sh
```

安裝腳本會：

- 建立 `bin/`、`config/`、`models/`、`recordings/`、`transcripts/`、`logs/`、`state/`。
- 檢查 Homebrew、`ffmpeg` 和 `portaudio`。
- 建立或更新 Conda 環境 `codex-voice`。
- 從 `pyproject.toml` 以 editable package 方式安裝 Codex Voice，並安裝測試/靜態檢查工具。
- 設定主程式和安裝腳本的可執行權限。
- 編譯並啟動 `com.codexvoice.agent` 與 `com.codexvoice.model-service` LaunchAgent。
- 編譯原生 Swift 錄音浮窗和狀態列 Agent。

只想重裝 Agent、不重裝 Python 依賴：

```bash
bash ~/CodexVoice/bin/install.sh --skip-deps
```

檢查 Agent 是否正在執行：

```bash
launchctl print gui/$(id -u)/com.codexvoice.agent
```

## AI Agent 安裝 Playbook

當你想讓 AI coding agent 在同一台 Mac 上安裝或更新 Codex Voice 時，可以把這一節交給它執行。

目標：把原始碼安裝或更新到 `~/CodexVoice`，保留使用者設定，編譯選單列 Agent，並驗證內建快捷鍵與持久 MLX 模型服務。

執行規則：

- 不要刪除 `~/CodexVoice/config/terms.json`、`transcripts/`、錄音、日誌、狀態檔或使用者改過的設定，除非使用者明確要求。
- 不要執行 `git reset --hard` 這類破壞性 git 指令。
- 如果倉庫 clone 在別處，先同步原始碼到 `~/CodexVoice`，再執行安裝器。
- 未經使用者確認，不要下載約 25 GB 的預設模型集合。

推薦指令：

```bash
mkdir -p ~/CodexVoice
rsync -a --exclude .git /path/to/codex-voice/ ~/CodexVoice/
bash ~/CodexVoice/bin/install.sh
```

驗證指令：

```bash
launchctl print gui/$(id -u)/com.codexvoice.agent
codex-voice --status
codex-voice-config --show
codex-voice-config --list-models
launchctl print gui/$(id -u)/com.codexvoice.model-service
```

安裝後，人類使用者仍需要在 macOS 系統設定中授權麥克風和輔助使用。預設內建快捷鍵是 `Option + Space`。

## macOS 權限

第一次使用需要兩個權限。

麥克風權限：

```text
System Settings -> Privacy & Security -> Microphone
```

授權 `Codex Voice Agent.app` 或觸發錄音的終端/宿主。如果沒有出現系統提示，可以在狀態列面板點「麥克風授權」，再重新觸發錄音。

輔助使用權限：

```text
System Settings -> Privacy & Security -> Accessibility
```

授權這個應用：

```text
~/CodexVoice/Codex Voice Agent.app
```

輔助使用權限只用於確認目前焦點是否為可編輯控制項，以及在確認可編輯時模擬 `Cmd+V`。如果焦點不在輸入框上，Codex Voice 不會強行貼上，只會把文字留在剪貼簿。

源碼安裝使用 ad-hoc 簽名。Agent 重新編譯或重新簽名後，安裝腳本會用 `tccutil` 重置輔助使用項目並打開系統設定；macOS 仍需要使用者手動重新勾選授權。

## 隱私預設值

Codex Voice 是本機優先工具。預設情況下，錄音只作為暫存檔存在，轉錄後刪除：

```json
"save_recordings": false,
"save_transcripts": true
```

逐字稿會保存到 `~/CodexVoice/transcripts`，方便回看識別品質。如果不希望 raw text、final text 和校正中繼資料落盤，把 `save_transcripts` 改成 `false`。

## 內建快捷鍵

狀態列 Agent 啟動時會註冊原生全域快捷鍵，預設是 `Option + Space`。

可以在狀態列面板裡：

- 錄製新的快捷鍵；
- 清除目前快捷鍵；
- 恢復預設 `Option + Space`。

按下快捷鍵時，Agent 會直接呼叫 `codex-voice.py --toggle`。舊的外部觸發檔整合已從主原始碼樹移除，快捷鍵由常駐 Agent 統一處理。

## 語言與輸出策略

Codex Voice 不自動偵測說話人的語言。設定浮層裡選取的語言就是整條處理鏈路的產品策略：

| 設定 | ASR 語言 | 校正/輸出行為 |
| --- | --- | --- |
| `跟隨系統` | 依 macOS 首選語言解析；不支援的系統語言預設為英文。 | 使用下方對應的實際語言。 |
| `English` | `en` | 依英文校正並輸出英文。 |
| `简体中文` | `zh` | 依簡體中文校正並輸出簡體中文；英文技術詞保留英文。 |
| `繁體中文` | `zh` | 依繁體中文校正並輸出繁體中文；英文技術詞保留英文。 |
| `日本語` | `ja` | 依日文校正並輸出日文；英文技術詞保留英文。 |

可以在狀態列面板的設定浮層切換，也可以使用 CLI：

```bash
codex-voice-config --set-ui-language system
codex-voice-config --set-ui-language en
codex-voice-config --set-ui-language zh-Hans
codex-voice-config --set-ui-language zh-Hant
codex-voice-config --set-ui-language ja
```

## 轉錄與本機模型

所有可選擇的語音與校正模型都是內建 MLX 模型。OpenAI 相容介面、Ollama 託管模型和非 MLX Whisper 不會出現在模型選擇中。

第一個模型分頁永遠是「轉錄模型」：

- `Qwen3-ASR-1.7B`：端到端 ASR，新安裝預設選擇。
- `Whisper large-v3-turbo`：MLX Whisper 轉錄模型；當某些口音、麥克風或詞彙下 Qwen3-ASR 表現不穩定時，可作為成熟備選。

校正分頁是可選項。選擇 `Qwen3.6-35B-A3B-4bit` 後，會在所選轉錄模型之後執行文字校正。再次點擊已選取的校正卡片會關閉校正，只保留 `terms.json` 的確定性規則。

為了相容舊設定，設定檔仍保留 `processing_route`：選擇 Qwen3-ASR 時會寫成 `direct_asr`，選擇 Whisper 時會寫成 `two_stage`。一般使用者通常透過轉錄模型卡片切換，不需要手寫此欄位。

模型透過 ModelScope 下載到 `~/CodexVoice/models`。下載完整預設集合前會先詢問：

```bash
bash ~/CodexVoice/bin/install.sh --download-models
codex-voice-config --list-models
```

也可單獨下載或預熱目前選取的轉錄/校正模型：

```bash
codex-voice-config --download-model qwen3-asr-1.7b-8bit
codex-voice-config --download-model whisper-large-v3-turbo
codex-voice-config --download-model qwen3.6-35b-a3b-4bit
codex-voice-config --prepare-current-route-models
```

點擊尚未安裝的模型卡片會立即下載，並顯示系統進度列與「下載模型中」。點擊已安裝但未載入的模型會載入記憶體，並顯示系統進度列與「載入模型中」。

`com.codexvoice.model-service` 獨立持有已載入的 MLX 模型。只退出選單列 Agent 時模型繼續駐留；卡片右上角的 `X` 卸載單一模型，「退出並卸載模型」會停止服務並釋放全部模型記憶體。

## 模型選擇建議

轉錄模型：

| 模型 | 推薦程度 | 說明 |
| --- | --- | --- |
| `mlx-community/Qwen3-ASR-1.7B-8bit` | 預設轉錄模型 | 端到端 ASR，延遲低、記憶體占用相對小，適合日常使用。 |
| `mlx-community/whisper-large-v3-turbo` | 備選轉錄模型 | 成熟的多語 ASR；特定口音、麥克風或詞彙下可與 Qwen3-ASR 比較。 |

校正模型：

| 模型 | 推薦程度 | 說明 |
| --- | --- | --- |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | 可選增強校正 | 多語口述校正與技術詞保留能力強，但記憶體占用明顯高於只轉錄。 |
| `規則校正（不使用 LLM）` | 確定性選項 | 保留 `terms.json` 替換，但不載入大型語言模型。 |

選擇原則：

- 先用 Qwen3-ASR 取得較低延遲與記憶體占用。
- 對同一段錄音切換 MLX Whisper，比較特定場景下的辨識品質。
- 只有術語或句子清理需要更多幫助時，再啟用 Qwen3.6 校正。
- 模型選擇不會靜默回退到其他模型；缺少模型會顯示「未安裝」，並可從卡片直接下載。

## 介面與截圖說明

以下圖片是繁體中文介面截圖說明。其他語言 README 會引用各自語言的截圖路徑，之後可依語言用同名真實截圖取代這些 SVG，README 連結不需要改。

### 狀態列主面板

![狀態列主面板截圖說明](docs/assets/screenshots/zh-TW/status-panel.svg)

主面板是日常使用 Codex Voice 的主要入口：

- 頂部狀態列：圓點與文字顯示閒置、錄音、轉寫或錯誤狀態；計時器顯示目前錄音時間；最長錄音時間可直接調整；紅色按鈕用來退出 Agent。
- 波形區域：錄音或測試輸入裝置時，用來確認麥克風有輸入。
- 錄音操作：`開始`、`提交`、`取消` 分別對應開始錄音、送出目前錄音與放棄目前錄音。
- 權限與設定：語言選擇、麥克風權限、輔助使用權限、內建快捷鍵錄製、清除、恢復預設，以及錄音浮窗開關都在這裡管理。
- 分頁：`轉錄模型`、`校正模型`、`輸入裝置`。
- 轉錄模型分頁：同時包含 Qwen3-ASR 和 MLX Whisper。
- 底部摘要：顯示狀態、目前轉錄模型、可選校正狀態和輸入裝置。

### 模型卡片

![模型卡片截圖說明](docs/assets/screenshots/zh-TW/model-cards.svg)

模型卡片用來選擇轉錄模型、校正模型和輸入裝置：

- 每張模型卡片明確顯示類型：轉錄或文字校正，並顯示參數規模、架構和廠商。
- 同一組卡片保持等高，但高度由內容自動測量，長模型名會在固定寬度內換行。
- 目前選取的卡片會高亮；再次點擊已選取的校正模型會關閉校正。
- 模型快照缺少時明確顯示「未安裝」；點擊後會下載模型並顯示系統進度列。
- 已安裝但未載入的模型會先載入記憶體，並顯示系統進度列。
- 已載入的 MLX 模型右上角會出現圓形 `X`，只卸載記憶體，不刪除磁碟模型。

### 內建快捷鍵

![內建快捷鍵截圖說明](docs/assets/screenshots/zh-TW/native-hotkey.svg)

設定浮層用來錄製和管理原生全域快捷鍵：

- 預設快捷鍵是 `Option + Space`。
- 一般組合鍵必須包含至少一個修飾鍵；儲存前會使用 macOS 公開的熱鍵註冊 API 做一次可用性檢查。
- 雙擊修飾鍵手勢，例如雙擊 Control，也可以錄製；但 macOS 沒有公開 API 可以可靠檢查這類手勢是否被其他應用程式占用，因此不會標記為「已檢測無衝突」。
- `清除` 會停用目前內建快捷鍵；`預設` 會恢復 `Option + Space`。
- 設定浮層開啟時會擋住下方卡片區，底層卡片不會繼續回應 hover、點擊或滾輪。

### 退出並卸載模型

![退出確認截圖說明](docs/assets/screenshots/zh-TW/quit-unload.svg)

退出流程會明確處理仍在執行的錄音和持久模型服務：

- 如果目前還有錄音 worker，Codex Voice 會先詢問是否取消錄音並退出。
- 如果模型服務仍有已載入模型，彈窗會列出名稱，並提供 `退出並卸載模型`、`僅退出`、`取消`。
- `僅退出`保留獨立模型服務；`退出並卸載模型`停止服務並釋放全部模型記憶體。
- 卸載失敗會提示，但不會讓 Agent 無限卡在退出流程裡。

## 常用操作

```text
按一次內建快捷鍵 -> 開始錄音
再按一次同一個快捷鍵 -> 提交錄音
```

設定最長錄音時間：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice-config.py --set-max-minutes 10
```

打開設定、術語表、轉寫記錄和日誌：

```bash
open -e ~/CodexVoice/config/config.json
open -e ~/CodexVoice/config/terms.json
open ~/CodexVoice/transcripts
tail -n 120 ~/CodexVoice/logs/codex-voice.log
```

## 設定檔

主要設定：

```text
~/CodexVoice/config/config.json
```

重要語言欄位：

```json
"ui_language": "system",
"processing_route": "direct_asr"
```

`processing_route` 可選 `direct_asr` 或 `two_stage`，由目前選取的轉錄模型自動維護。`ui_language` 控制介面、CLI、ASR 語言、可選的 Qwen3.6 校正提示詞和最終輸出字形。

術語和確定性替換：

```text
~/CodexVoice/config/terms.json
```

校正提示詞：

```text
~/CodexVoice/config/correction_prompt.txt
```

確定性替換在 ASR 之後、可選的 Qwen3.6 校正之前執行。

## 故障排查

內建快捷鍵無法使用：

```bash
tail -n 120 ~/CodexVoice/logs/codex-voice.log
open -e ~/CodexVoice/config/config.json
```

打開狀態列面板。如果顯示快捷鍵不可用或可能衝突，請錄製新的組合鍵，或恢復預設值。

Agent 沒有執行：

```bash
bash ~/CodexVoice/bin/install-launch-agents.sh
launchctl print gui/$(id -u)/com.codexvoice.agent
```

本機模型未顯示或無法載入：

```bash
codex-voice-config --list-models
launchctl print gui/$(id -u)/com.codexvoice.model-service
tail -n 120 ~/CodexVoice/logs/com.codexvoice.model-service.err.log
```

無法自動貼上時，請確認已授權輔助使用、目前焦點是文字輸入框；如果剛重新編譯 Agent，請在安裝腳本重置並打開系統設定後重新勾選授權。即使不自動貼上，最終文字也已在剪貼簿中。

## 停止或移除

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.codexvoice.agent.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.codexvoice.model-service.plist
rm -f ~/Library/LaunchAgents/com.codexvoice.agent.plist
rm -f ~/Library/LaunchAgents/com.codexvoice.model-service.plist
rm -rf ~/CodexVoice
```

如果只想退出本次執行，點狀態列面板右上角紅色退出按鈕即可。LaunchAgent 的 macOS `KeepAlive` 為 `false`，使用者退出後不會立刻被系統自動拉起。
