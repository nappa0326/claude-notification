#!/bin/bash
# start-wsl.sh
# WSL tmux セッション開始 + CC通知リスナーデーモン起動
#
# WSL bash 起点で tmux セッションを作成し、
# Windows 側の pwsh.exe で HWND 取得・デーモン起動を行う。
#
# 使い方: bash ~/start-wsl.sh
# 配置先: ~/start-wsl.sh (WSL ホーム)

set -euo pipefail

# --- セッション名 (peers 対応: 毎回ユニーク、start-psmux.ps1 と同等) ---
SESSION_NAME="work-$(date +%H%M%S)"

# --- WSL 環境チェック ---
if ! grep -qi microsoft /proc/version 2>/dev/null; then
    echo "Error: WSL 環境ではありません" >&2
    exit 1
fi

# --- Windows ユーザー名取得 (キャッシュ付き) ---
CACHE_FILE="$HOME/.cc-win-home"
if [ -f "$CACHE_FILE" ]; then
    WIN_USER=$(cat "$CACHE_FILE")
else
    WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
    if [ -z "$WIN_USER" ]; then
        echo "Error: Windows ユーザー名を取得できません" >&2
        exit 1
    fi
    echo -n "$WIN_USER" > "$CACHE_FILE"
fi

WIN_HOOKS_DIR="/mnt/c/Users/$WIN_USER/.claude/hooks"
mkdir -p "$WIN_HOOKS_DIR"

# --- WT HWND 取得 (pwsh.exe 経由) ---
# プロセスツリーを辿って Windows Terminal の HWND を取得
echo "Detecting WT HWND..."
WT_HWND=$(pwsh.exe -NoProfile -Command '
    $currentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
    for ($i = 0; $i -lt 15; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$currentPid" -EA SilentlyContinue
        if (-not $proc -or -not $proc.ParentProcessId) { break }
        $parentPid = $proc.ParentProcessId
        $parent = Get-Process -Id $parentPid -EA SilentlyContinue
        if (-not $parent) { break }
        if ($parent.ProcessName -eq "WindowsTerminal" -and $parent.MainWindowHandle -ne [IntPtr]::Zero) {
            Write-Output $parent.MainWindowHandle; exit
        }
        $currentPid = $parentPid
    }
    # フォールバック: プロセス名検索
    $wt = Get-Process -Name WindowsTerminal -EA SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
          Select-Object -First 1
    if ($wt) { Write-Output $wt.MainWindowHandle }
' 2>/dev/null | tr -d '\r\n')

HWND_FILE="$WIN_HOOKS_DIR/.wt-hwnd-$SESSION_NAME"
if [ -n "$WT_HWND" ] && [ "$WT_HWND" != "0" ]; then
    echo -n "$WT_HWND" > "$HWND_FILE"
    echo "WT HWND: $WT_HWND (saved)"
else
    echo "Warning: WT HWND を検出できません。クリック時はプロセス検索にフォールバックします。"
fi

# --- デーモン起動 (Windows 側 pwsh.exe) ---
DAEMON_SCRIPT="/mnt/c/Users/$WIN_USER/.claude/hooks/focus-listener-daemon.ps1"
WIN_DAEMON_SCRIPT="C:\\Users\\$WIN_USER\\.claude\\hooks\\focus-listener-daemon.ps1"

if [ -f "$DAEMON_SCRIPT" ]; then
    # 既存デーモンプロセスチェック
    DAEMON_RUNNING=$(pwsh.exe -NoProfile -Command '
        $d = Get-Process pwsh -EA SilentlyContinue |
             Where-Object { $_.CommandLine -like "*focus-listener-daemon*" }
        if ($d) { Write-Output "running" } else { Write-Output "stopped" }
    ' 2>/dev/null | tr -d '\r\n')

    if [ "$DAEMON_RUNNING" = "stopped" ]; then
        echo "Starting CC focus listener daemon..."
        pwsh.exe -NoProfile -Command "
            Start-Process pwsh -ArgumentList @(
                '-STA', '-NoProfile', '-WindowStyle', 'Hidden',
                '-File', '$WIN_DAEMON_SCRIPT'
            ) -WindowStyle Hidden
        " 2>/dev/null
    else
        echo "CC focus listener daemon already running."
    fi
else
    echo "Warning: デーモンスクリプトが見つかりません: $DAEMON_SCRIPT"
    echo "  Windows 側に focus-listener-daemon.ps1 を配置してください。"
fi

# --- tmux セッション作成・アタッチ ---
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Attaching to tmux session: $SESSION_NAME"
else
    echo "Creating tmux session: $SESSION_NAME"
    tmux new-session -d -s "$SESSION_NAME"
fi

tmux attach -t "$SESSION_NAME"
