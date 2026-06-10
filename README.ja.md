# Codex Voice Input

Codex Voice Input は、ローカル優先の macOS 音声入力ツールです。内蔵グローバルホットキーを 1 回押すと録音開始、もう 1 回押すと送信します。メニューバー設定で選んだ言語に従って、英語、簡体字中国語、繁体字中国語、日本語のいずれかで文字起こし、補正、出力を行います。技術用語、コマンド、パス、変数名、ファイル名は可能な限り標準的な英語またはコード表記のまま保持します。最終テキストはクリップボードへ保存し、現在のフォーカスが入力欄だと確認できた場合だけ自動で貼り付けます。

言語：[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | 日本語

## 想定ユーザー

- Codex Desktop、Cursor、VS Code、ブラウザ、チャットツールなどで、英語、簡体字中国語、繁体字中国語、日本語に技術用語を混ぜて入力する人。
- 音声認識と用語補正をできるだけローカルで完結させたい人。
- グローバルホットキーを常駐メニューバー Agent が直接処理する軽い操作感を求める人。

## 主な機能

- 内蔵グローバルホットキー：既定は `Option + Space`。メニューバーパネルから録り直せます。
- macOS メニューバーパネル：開始、送信、キャンセル、権限、モデル、入力デバイス、ログをまとめて操作。
- 統一された音声認識モデルタブ：Qwen3-ASR と MLX Whisper を同じモデル選択エリアで選べます。
- 任意の MLX 補正：Qwen3.6 テキスト補正はどちらの音声認識モデルの後にも使えます。選択済みの補正カードをもう一度クリックすると補正を無効化します。
- 4 言語ワークフロー：UI 言語設定が ASR 言語、補正プロンプト、CLI 出力、最終出力の文字体系を制御します。
- 永続ローカル MLX サービス：メニューバー Agent を終了してもモデルは残り、UI から明示的にアンロードできます。
- 統一貼り付け方針：最終テキストは必ずクリップボードに保存し、現在のフォーカスが編集可能な場合だけ `Cmd+V` を送信。
- モデル管理：ModelScope からの取得、MLX メモリへのロード、常駐状態の確認、UI からのアンロードに対応。

## 仕組み

```text
内蔵グローバルホットキー
        |
        v
com.codexvoice.agent LaunchAgent
        |
        +-- 録音、送信、キャンセル、メニューバー UI
        +-- UI/実行時言語の解決
        +-- 音声認識モデル：Qwen3-ASR または MLX Whisper
        +-- terms.json/決定的ルール
        +-- 任意の Qwen3.6 テキスト補正
        +-- すべてのローカルモデルで独立した永続 MLX モデルサービスを共有
        +-- pbcopy でクリップボードへ保存
        +-- 入力欄にフォーカスがある場合だけ Cmd+V
```

## 必要環境

- macOS 13 以降。
- Apple Silicon Mac。ローカル MLX ランタイムは Apple Silicon 向けです。
- Conda、Miniconda、Miniforge、または Anaconda。
- Homebrew で `ffmpeg` と `portaudio` を入れておくことを推奨。

## インストール

リポジトリは標準の実行ディレクトリへ置くのがおすすめです。

```bash
git clone https://github.com/dataindustry/codex-voice.git ~/CodexVoice
cd ~/CodexVoice
bash ~/CodexVoice/bin/install.sh
```

別の場所に clone 済みの場合は、標準ディレクトリへ同期してからインストールします。

```bash
mkdir -p ~/CodexVoice
rsync -a --exclude .git /path/to/codex-voice/ ~/CodexVoice/
bash ~/CodexVoice/bin/install.sh
```

インストールスクリプトが行うこと：

- `bin/`、`config/`、`models/`、`recordings/`、`transcripts/`、`logs/`、`state/` を作成。
- Homebrew、`ffmpeg`、`portaudio` を確認。
- Conda 環境 `codex-voice` を作成または更新。
- `pyproject.toml` から Codex Voice を editable package としてインストールし、テスト/静的チェック用ツールも入れます。
- メインプログラムとインストールスクリプトに実行権限を付与。
- `com.codexvoice.agent` と `com.codexvoice.model-service` LaunchAgent をビルドして起動。
- Swift 製の録音インジケータとメニューバー Agent をビルド。

Python 依存関係を再インストールせず Agent だけ更新する場合：

```bash
bash ~/CodexVoice/bin/install.sh --skip-deps
```

Agent の状態確認：

```bash
launchctl print gui/$(id -u)/com.codexvoice.agent
```

## AI Agent Installation Playbook

同じ Mac 上で AI coding agent に Codex Voice をインストールまたは更新させる場合は、この節を渡してください。

目標：ソースを `~/CodexVoice` にインストールまたは更新し、ユーザー設定を保持し、メニューバー Agent をコンパイルし、内蔵ホットキーと永続 MLX モデルサービスを検証します。

実行ルール：

- ユーザーが明示しない限り、`~/CodexVoice/config/terms.json`、`transcripts/`、録音、ログ、状態ファイル、ユーザー編集済み設定を削除しない。
- `git reset --hard` のような破壊的 git コマンドを実行しない。
- リポジトリが別の場所に clone されている場合は、先にソースを `~/CodexVoice` へ同期してから installer を実行する。
- 約 25 GB の標準モデル一式は、ユーザーの確認なしにダウンロードしない。

推奨コマンド：

```bash
mkdir -p ~/CodexVoice
rsync -a --exclude .git /path/to/codex-voice/ ~/CodexVoice/
bash ~/CodexVoice/bin/install.sh
```

検証コマンド：

```bash
launchctl print gui/$(id -u)/com.codexvoice.agent
codex-voice --status
codex-voice-config --show
codex-voice-config --list-models
launchctl print gui/$(id -u)/com.codexvoice.model-service
```

インストール後、人間のユーザーは macOS System Settings で Microphone と Accessibility を許可する必要があります。既定の内蔵ホットキーは `Option + Space` です。

## macOS 権限

初回利用時には 2 つの権限が必要です。

マイク権限：

```text
System Settings -> Privacy & Security -> Microphone
```

`Codex Voice Agent.app`、または録音を起動したターミナル/ホストアプリに許可を与えてください。確認ダイアログが出ない場合は、メニューバーパネルの「麦克风授权」を押してから再度録音を開始します。

アクセシビリティ権限：

```text
System Settings -> Privacy & Security -> Accessibility
```

次のアプリを許可します。

```text
~/CodexVoice/Codex Voice Agent.app
```

この権限は、現在のフォーカスが編集可能か確認し、編集可能な場合に `Cmd+V` を送るためだけに使います。入力欄にフォーカスがない場合、Codex Voice は無理に貼り付けず、テキストをクリップボードに残します。

ソースからのインストールでは ad-hoc 署名を使います。Agent を再ビルドまたは再署名した場合、インストールスクリプトは `tccutil` でアクセシビリティ項目をリセットして System Settings を開きますが、macOS ではユーザーが手動で再度許可する必要があります。

## プライバシー既定値

Codex Voice はローカル優先のツールです。既定では録音は一時ファイルとして扱われ、文字起こし後に削除されます。

```json
"save_recordings": false,
"save_transcripts": true
```

文字起こし結果は `~/CodexVoice/transcripts` に保存され、認識品質の確認に使えます。raw text、final text、補正メタデータを保存したくない場合は、`save_transcripts` を `false` にしてください。

## 内蔵ホットキー

メニューバー Agent は起動時にネイティブのグローバルホットキーを登録します。既定は `Option + Space` です。

メニューバーパネルでは次の操作ができます。

- 新しいホットキーを録る；
- 現在のホットキーをクリアする；
- 既定の `Option + Space` に戻す。

ホットキーが押されると、Agent は直接 `codex-voice.py --toggle` を呼びます。古い外部トリガーファイル連携はメインのソースツリーから削除され、ホットキー処理は常駐 Agent に統一されています。

## 言語と出力方針

Codex Voice は話者の言語を自動検出しません。設定オーバーレイで選んだ言語が、処理全体の製品方針になります。

| 設定 | ASR 言語 | 補正/出力の挙動 |
| --- | --- | --- |
| `システムに従う` | macOS の優先言語から解決します。未対応のシステム言語は英語に fallback します。 | 下の解決済み言語を使います。 |
| `English` | `en` | 英語として補正し、英語で出力します。 |
| `简体中文` | `zh` | 簡体字中国語として補正し、簡体字中国語で出力します。英語の技術用語は英語のまま残します。 |
| `繁體中文` | `zh` | 繁体字中国語として補正し、繁体字中国語で出力します。英語の技術用語は英語のまま残します。 |
| `日本語` | `ja` | 日本語として補正し、日本語で出力します。英語の技術用語は英語のまま残します。 |

メニューバーパネルの設定オーバーレイ、または CLI から変更できます。

```bash
codex-voice-config --set-ui-language system
codex-voice-config --set-ui-language en
codex-voice-config --set-ui-language zh-Hans
codex-voice-config --set-ui-language zh-Hant
codex-voice-config --set-ui-language ja
```

## 音声認識とローカルモデル

選択できる音声認識モデルと補正モデルは、すべて内蔵 MLX モデルです。OpenAI 互換 API、Ollama 管理モデル、非 MLX Whisper はモデル選択に表示しません。

最初のモデルタブは常に「音声認識モデル」です。

- `Qwen3-ASR-1.7B`：エンドツーエンド ASR。新規インストールの既定です。
- `Whisper large-v3-turbo`：MLX Whisper 音声認識モデル。特定のアクセント、マイク、語彙で Qwen3-ASR が安定しない場合の成熟した代替です。

補正タブは任意です。`Qwen3.6-35B-A3B-4bit` を選ぶと、選択した音声認識モデルの後にテキスト補正を実行します。選択済みの補正カードをもう一度クリックすると補正を無効化し、`terms.json` の決定的ルールだけを使います。

互換性のため、設定ファイルには `processing_route` が残っています。Qwen3-ASR を選ぶと `direct_asr`、Whisper を選ぶと `two_stage` に更新されます。通常はこの値を直接編集せず、音声認識モデルカードから切り替えます。

モデルは ModelScope から `~/CodexVoice/models` へダウンロードします。標準モデル一式の取得前に確認があります。

```bash
bash ~/CodexVoice/bin/install.sh --download-models
codex-voice-config --list-models
```

個別取得と、現在選択されている音声認識/補正モデルの事前ロード：

```bash
codex-voice-config --download-model qwen3-asr-1.7b-8bit
codex-voice-config --download-model whisper-large-v3-turbo
codex-voice-config --download-model qwen3.6-35b-a3b-4bit
codex-voice-config --prepare-current-route-models
```

未インストールのモデルカードをクリックすると、その場でダウンロードを開始し、システム進捗バーと「モデルをダウンロード中」を表示します。インストール済みで未ロードのモデルをクリックすると、メモリへロードし、システム進捗バーと「モデルをロード中」を表示します。

`com.codexvoice.model-service` がロード済み MLX モデルを独立して保持します。メニューバー Agent だけを終了した場合はモデルが残ります。カード右上の `X` は 1 モデルをアンロードし、「アンロードして終了」はサービスを停止して全モデルのメモリを解放します。

## モデル選択の目安

音声認識モデル：

| モデル | 推奨度 | 説明 |
| --- | --- | --- |
| `mlx-community/Qwen3-ASR-1.7B-8bit` | 既定の音声認識モデル | エンドツーエンド ASR。低遅延でメモリ使用量も比較的小さく、日常利用の第一候補です。 |
| `mlx-community/whisper-large-v3-turbo` | 代替の音声認識モデル | 成熟した多言語 ASR。特定のアクセント、マイク、語彙では Qwen3-ASR と比較してください。 |

補正モデル：

| モデル | 推奨度 | 説明 |
| --- | --- | --- |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | 任意の強化補正 | 多言語補正と技術用語保持に強い一方、音声認識のみの場合より大きなメモリを使います。 |
| `ルール補正（LLM なし）` | 決定的な選択肢 | `terms.json` の置換を残し、大規模言語モデルはロードしません。 |

選択の目安：

- まず Qwen3-ASR で低遅延・省メモリの結果を確認します。
- 同じ録音を MLX Whisper でも試し、特定条件での認識品質を比較します。
- 用語や文の整理にさらに助けが必要な場合だけ、Qwen3.6 補正を有効化します。
- モデル選択は別モデルへ黙ってフォールバックしません。未インストールのモデルは明示され、カードから直接ダウンロードできます。

## UI とスクリーンショット説明

以下の画像は日本語 UI のスクリーンショット説明です。他言語の README はそれぞれの言語別パスを参照するため、あとで言語ごとに同名の実スクリーンショットへ差し替えても README のリンクは変えずに済みます。

### メニューバーメインパネル

![メインパネルのスクリーンショット説明](docs/assets/screenshots/ja/status-panel.svg)

メインパネルは Codex Voice を日常的に操作する中心です。

- 上部ステータス行: ドットとラベルで待機中、録音中、文字起こし中、エラーを表示します。タイマーは録音時間を示し、最大録音時間はその場で調整できます。赤いボタンは Agent の終了です。
- 波形エリア: 録音中または入力デバイスのテスト中に、マイク入力が届いているかを確認できます。
- 録音操作: `開始`、`送信`、`キャンセル` は、録音開始、現在の録音の送信、現在の録音の破棄に対応します。
- 権限と設定: 言語選択、マイク権限、アクセシビリティ権限、内蔵ホットキーの録音、クリア、既定値復元、録音インジケータ切り替えをここで管理します。
- タブ: `音声認識モデル`、`補正モデル`、`入力デバイス`。
- 音声認識モデルタブ: Qwen3-ASR と MLX Whisper の両方を含みます。
- 下部サマリー: 状態、現在の音声認識モデル、任意の補正状態、入力デバイスを表示します。

### モデルカード

![モデルカードのスクリーンショット説明](docs/assets/screenshots/ja/model-cards.svg)

モデルカードでは、音声認識モデル、補正モデル、入力デバイスを選びます。

- モデルカードには音声認識またはテキスト補正の種類と、規模、構成、提供元を表示します。
- 同じグループ内のカードは等しい高さになりますが、高さは内容から自動測定されます。長いモデル名は固定幅の中で折り返されます。
- 選択中のカードは強調表示されます。選択済みの補正モデルをもう一度クリックすると補正を無効化します。
- モデルスナップショットが無い場合は未インストールと明示します。クリックするとダウンロードし、システム進捗バーを表示します。
- インストール済みで未ロードのモデルは、使用前にメモリへロードし、システム進捗バーを表示します。
- ロード済み MLX モデルの右上には丸い `X` が表示され、メモリだけを解放します。

### 内蔵ホットキー

![内蔵ホットキーのスクリーンショット説明](docs/assets/screenshots/ja/native-hotkey.svg)

設定オーバーレイで、録音開始と送信に使うネイティブグローバルホットキーを管理します。

- 既定値は `Option + Space` です。
- 通常のキー組み合わせには少なくとも 1 つの修飾キーが必要です。保存前に macOS の公開ホットキー登録 API で利用可否を確認します。
- double Control のような修飾キーのみのダブルタップも録音できます。ただし macOS には、この種類のジェスチャーが他アプリに使われているかを公開 API で確実に調べる方法がないため、「衝突なし確認済み」とは表示しません。
- `クリア` は現在の内蔵ホットキーを無効化し、`既定値` は `Option + Space` に戻します。
- オーバーレイ表示中は下のカード領域をブロックするため、カードの hover、クリック、スクロールは背後に抜けません。

### 終了時のモデルアンロード

![終了確認のスクリーンショット説明](docs/assets/screenshots/ja/quit-unload.svg)

終了フローでは、実行中の録音と永続モデルサービスを明示的に扱います。

- 録音 worker が動いている場合、Codex Voice は録音をキャンセルして終了するか確認します。
- モデルサービスにロード済みモデルがある場合、名前を表示して `アンロードして終了`、`終了のみ`、`キャンセル` を選べます。
- `終了のみ`は独立サービスを残し、`アンロードして終了`はサービスを停止して全モデルのメモリを解放します。
- アンロード失敗は表示されますが、Agent が終了フローで無限に止まることはありません。

## よく使う操作

```text
内蔵ホットキーを 1 回押す -> 録音開始
同じホットキーをもう 1 回押す -> 録音を送信
```

最大録音時間を設定：

```bash
conda run -n codex-voice python ~/CodexVoice/bin/codex-voice-config.py --set-max-minutes 10
```

設定、用語表、文字起こし履歴、ログを開く：

```bash
open -e ~/CodexVoice/config/config.json
open -e ~/CodexVoice/config/terms.json
open ~/CodexVoice/transcripts
tail -n 120 ~/CodexVoice/logs/codex-voice.log
```

## 設定ファイル

主な設定：

```text
~/CodexVoice/config/config.json
```

重要な言語フィールド：

```json
"ui_language": "system",
"processing_route": "direct_asr"
```

`processing_route` は `direct_asr` または `two_stage` で、現在選択されている音声認識モデルによって自動的に維持されます。`ui_language` は UI、CLI、ASR 言語、任意の Qwen3.6 補正プロンプト、最終出力の文字体系を制御します。

用語と決定的な置換：

```text
~/CodexVoice/config/terms.json
```

補正プロンプト：

```text
~/CodexVoice/config/correction_prompt.txt
```

決定的な置換は ASR の後、任意の Qwen3.6 補正の前に実行されます。

## トラブルシューティング

内蔵ホットキーが使えない：

```bash
tail -n 120 ~/CodexVoice/logs/codex-voice.log
open -e ~/CodexVoice/config/config.json
```

メニューバーパネルを開いてください。ホットキーが利用不可または競合の可能性ありと表示される場合は、別のキー組み合わせを録るか既定値に戻してください。

Agent が動いていない：

```bash
bash ~/CodexVoice/bin/install-launch-agents.sh
launchctl print gui/$(id -u)/com.codexvoice.agent
```

ローカルモデルが表示またはロードされない：

```bash
codex-voice-config --list-models
launchctl print gui/$(id -u)/com.codexvoice.model-service
tail -n 120 ~/CodexVoice/logs/com.codexvoice.model-service.err.log
```

自動貼り付けできない場合は、アクセシビリティ権限と現在のフォーカスが入力欄であることを確認してください。Agent を再ビルドした直後は、インストールスクリプトが項目をリセットして System Settings を開いたあと、手動で再度許可してください。自動貼り付けしない場合でも、最終テキストはクリップボードに残ります。

## 停止または削除

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.codexvoice.agent.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.codexvoice.model-service.plist
rm -f ~/Library/LaunchAgents/com.codexvoice.agent.plist
rm -f ~/Library/LaunchAgents/com.codexvoice.model-service.plist
rm -rf ~/CodexVoice
```

今回だけ終了したい場合は、メニューバーパネル右上の赤い終了ボタンを押します。macOS LaunchAgent の `KeepAlive` は `false` なので、ユーザーが終了した直後に自動再起動されることはありません。
