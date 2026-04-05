# Claude Code hooks × BurntToast 通知システム (v2)

Windows 11 + PowerShell 7.6 環境で、Claude Code の待受状態をトースト通知し、
通知クリックで該当ペインにフォーカスする仕組み。**psmux / WSL tmux** の両環境に対応。

参考: [Mac版実装 (terminal-notifier + tmux)](https://nealle-dev.hatenablog.com/entry/2025/12/25/122620) の Windows 移植。

> **注**: Windows で click-to-focus まで実現する既存ソリューションは存在しない
> (claude-notifications-go, @claude-code-hooks/notification 等は Windows で click-to-focus 未対応)。

## アーキテクチャ

```
CC が待受状態 (idle/permission/question) → Notification hook 発火
  ↓
claude-notification.sh (bash - 高速、~50ms)
  ├─ 環境自動検出 (psmux / WSL)
  ├─ stdin から JSON payload 読み取り (message フィールド抽出)
  ├─ tmux display-message でセッション名・ペインID 取得
  ├─ tmux list-panes で window_index を逆引き (peers 対応)
  ├─ .last-notify.json にペイン情報を書き出し
  │    psmux: ~/.claude/hooks/.last-notify.json
  │    WSL:   /mnt/c/Users/<user>/.claude/hooks/.last-notify.json
  └─ 通知発行はデーモンに委譲 (FSW 経由)

[常駐プロセス] focus-listener-daemon.ps1 (Windows 側)
  ├─ FileSystemWatcher で .last-notify.json 変更検知 → BurntToast 通知
  ├─ BurntToast OnActivated でクリック検出
  ├─ env フィールドで psmux/WSL 分岐
  │    psmux: tmux -S <socket> select-window -t <session>:<window_index>
  │           tmux -S <socket> select-pane -t <pane_id>
  │    WSL:   wsl -d <distro> -- tmux -S <socket> select-window/select-pane
  └─ Win32 SetForegroundWindow で Windows Terminal をアクティブ化
```

## インストール

```bash
git clone https://github.com/nappa/claude-notification.git
cd claude-notification
```

## 前提条件

### 共通 (Windows 側)

```powershell
# PowerShell 7.1+ (OnActivated イベントに必要)
pwsh --version  # 7.1 以上

# BurntToast v1.0.1+ (OnActivated sticky fix 済み。最新は v1.1.0)
Install-Module BurntToast -Scope CurrentUser
Get-Module BurntToast -ListAvailable  # 1.0.1 以上を確認

# jq (推奨、なくてもフォールバックあり)
winget install jqlang.jq
```

### psmux 環境の場合

```powershell
# psmux (winget / cargo / scoop いずれか)
winget install psmux
# or: cargo install psmux
```

### WSL 環境の場合

```bash
# WSL 内で:
sudo apt install tmux jq  # tmux + jq
npm install -g @anthropic-ai/claude-code  # CC (WSL 側に別途必要)
```

## ファイル構成

```
# Windows 側
~/.claude/
├── hooks/
│   ├── claude-notification.sh         # hook スクリプト (psmux 環境用)
│   ├── focus-listener-daemon.ps1      # 常駐リスナー (psmux/WSL 共用)
│   └── .last-notify.json              # 自動生成 (ペイン情報)
├── icons/
│   └── claude-ai-icon.png             # 通知アイコン (任意)
└── settings.json                      # hooks 設定を追記

~/
└── start-psmux.ps1                    # psmux セッション開始 (任意)

# WSL 側 (WSL 環境の場合)
~/.claude/
├── hooks/
│   └── claude-notification.sh         # hook スクリプト (WSL 環境用、同一ファイル)
└── settings.json                      # hooks 設定を追記 (Windows 側とは別管理)

~/
└── start-wsl.sh                       # WSL tmux セッション開始 (任意)
```

## セットアップ (psmux 環境)

### 1. スクリプトを配置

```powershell
New-Item -Path "$HOME\.claude\hooks" -ItemType Directory -Force
New-Item -Path "$HOME\.claude\icons" -ItemType Directory -Force

Copy-Item claude-notification.sh "$HOME\.claude\hooks\"
Copy-Item focus-listener-daemon.ps1 "$HOME\.claude\hooks\"
Copy-Item start-psmux.ps1 "$HOME\"  # 任意
```

### 2. settings.json に hooks を追記

`~/.claude/settings.json` に settings-hooks.json の内容を **マージ** する。

**注意点**:
- `command` の `bash` は CC の実行環境 (Git Bash) で利用可能
- `~` は bash が `$HOME` に展開する
- 既存の settings.json がある場合は `hooks` キーをマージすること

### 3. 常駐リスナーの起動

**方法A: start-psmux.ps1 に組み込み (推奨)**

```powershell
.\start-psmux.ps1 -SessionName work
```

**方法B: 手動起動**

```powershell
pwsh -STA -NoProfile -WindowStyle Hidden -File ~/.claude/hooks/focus-listener-daemon.ps1
```

### 4. 動作確認

```powershell
# 1. BurntToast 動作確認
New-BurntToastNotification -Text "Test", "CC notification test"

# 2. psmux 内でペイン情報確認
tmux display-message -p '#{session_name}:#{pane_id}'

# 3. 常駐リスナーの稼働確認
Get-Process pwsh | Where-Object { $_.CommandLine -like "*focus-listener*" }
```

## セットアップ (WSL 環境)

### 1. Windows 側にデーモンを配置

```powershell
# Windows PowerShell で:
New-Item -Path "$HOME\.claude\hooks" -ItemType Directory -Force
Copy-Item focus-listener-daemon.ps1 "$HOME\.claude\hooks\"
```

### 2. WSL 側にスクリプトを配置

```bash
# WSL 内で:
mkdir -p ~/.claude/hooks
cp /mnt/c/<リポジトリパス>/claude-notification.sh ~/.claude/hooks/
cp /mnt/c/<リポジトリパス>/start-wsl.sh ~/
chmod +x ~/.claude/hooks/claude-notification.sh ~/start-wsl.sh
```

### 3. WSL 側の settings.json に hooks を追記

WSL 側の `~/.claude/settings.json` に settings-hooks.json の `hooks` キーをマージする。
Windows 側とは別ファイルなので **両方に設定が必要**。

```bash
# WSL 内で (jq がある場合):
jq -s '.[0] * .[1]' ~/.claude/settings.json /mnt/c/<リポジトリパス>/settings-hooks.json \
    > ~/.claude/settings.json.tmp && mv ~/.claude/settings.json.tmp ~/.claude/settings.json

# jq がない場合: 手動で ~/.claude/settings.json に "hooks" キーを追記
# settings-hooks.json の内容を参照
```

### 4. セッション開始

```bash
# WSL 内で (HWND 取得 + デーモン起動 + tmux セッション作成を一括実行):
bash ~/start-wsl.sh
```

### 5. 動作確認

```bash
# WSL tmux 内で hook を手動テスト:
echo '{"message":"test","session_id":"x","cwd":"/tmp"}' | \
    bash ~/.claude/hooks/claude-notification.sh

# JSON 確認:
cat /mnt/c/Users/<ユーザー名>/.claude/hooks/.last-notify.json
# → env: "wsl", wsl_distro: "<ディストロ名>" を確認
```

## トラブルシューティング

### hook が発火しない
- `claude --debug` でログを確認
- hook を手動テスト: `echo '{"message":"test","session_id":"x","cwd":"/tmp"}' | bash ~/.claude/hooks/claude-notification.sh`

### 通知は出るがクリックで何も起きない
- `focus-listener-daemon.ps1` が稼働しているか確認
- `.last-notify.json` が生成されているか確認
- BurntToast v1.0.1+ か確認 (v1.0.0 は OnActivated のバグあり)
- デーモンログを確認: `cat ~/.claude/hooks/focus-listener-daemon.log`

### peers 環境: クリック後に別ピアのタブへ切り替わらない
- デーモンログで `[CLICK] select-window=` の値が `<session>:<数値>` 形式か確認
- 空や `@N` 形式なら window_index の取得に失敗している
- `.last-notify.json` に `window_index` フィールドがあるか確認
- hook を手動実行して出力を確認 (該当ピア shell 内で実行):
  ```bash
  tmux list-panes -s -t "$(tmux display-message -p '#{session_name}')" \
      -F '#{pane_id} #{window_index}'
  ```

### psmux でセッション名/ペインIDが取れない
- psmux セッション内で `echo $TMUX` が非空か確認
- `tmux display-message -p '#{session_name}:#{pane_id}'` が動くか確認

### WSL: 通知が出ない
- `.last-notify.json` が Windows 側 (`/mnt/c/Users/<user>/.claude/hooks/`) に書き出されているか確認
- `~/.cc-win-home` に正しい Windows ユーザー名がキャッシュされているか確認
- デーモンが Windows 側で稼働しているか確認

### WSL: クリック後にペインフォーカスしない
- デーモンログで `[CLICK] WSL select-pane` の `exit=` を確認
- WSL が起動中か確認: `wsl -l -v`
- `wsl -d <distro> -- tmux list-sessions` が動くか確認

### Windows Terminal がフォアグラウンドに来ない
- `SetForegroundWindow` はフォーカス制限がある
  (通知クリック経由なので通常は問題ないが、グループポリシー等で制限される場合あり)

## peers 環境対応

[claude-peers](https://github.com/nappa0326/claude-peers) のように各ピアが独立した
psmux window (`peer-0`, `peer-1`...) として並ぶ環境では、`select-pane` だけでは
window が切り替わらない。本ツールは以下の方式で対応:

- **hook 側**: `tmux list-panes -s -t <session> -F '#{pane_id} #{window_index}'` で
  自 pane_id に対応する window_index を逆引きし、JSON に保存
- **daemon 側**: `select-window -t <session>:<window_index>` → `select-pane -t <pane_id>`
  の順で両方実行

### psmux の非互換挙動 (回避済み)

実装にあたり以下の非互換を確認済み。同種の問題で悩んだ場合の参考に:

- `display-message -p '#{window_id}'` は client の active pane に依存するため、
  inactive な window で動く hook から自 window_id を取得できない
- `display-message -t <pane_id>` は `-t` を無視して current window を返す
- `select-window -t @N` (window_id 形式) は受け付けず、数値 index として誤解釈される
- `select-window -t <session>:<window_name>` は無視される
- 確実に動くのは `select-window -t <session>:<window_index>` (数値 index) のみ

## 既知の制限事項

1. **最後の通知のみ有効**: `.last-notify.json` は最新の通知で上書きされるため、
   複数セッションが同時に通知すると最後のペイン情報のみ残る。
   psmux/WSL 混在環境でも同様。

2. **常駐リスナーの寿命**: tmux サーバーが停止するとデーモンも終了する。
   セッション再起動時はデーモンも再起動が必要。

3. **BurntToast の AppId 制約**: v1.0.0 で AppId カスタマイズが廃止されたため、
   通知は PowerShell のアイコンで表示される。`-AppLogo` でアイコン画像を指定可能。

4. **WSL: ディストロ停止時の遅延**: WSL が停止状態だとクリック時に WSL 起動待ちが発生する
   (CC が動いている限り WSL は起動中なので通常は問題ない)。
