#!/bin/bash
# claude-notification.sh
# Claude Code Notification hook → ペイン情報書き出し (通知発行はデーモンが担当)
#
# 配置先:
#   psmux: ~/.claude/hooks/claude-notification.sh
#   WSL:   ~/.claude/hooks/claude-notification.sh (WSL 側ホーム)
# 前提: focus-listener-daemon.ps1 が Windows 側で常駐中
#
# 設計:
#   - hook command は bash で高速実行 (~50ms)
#   - psmux/WSL 両環境対応: 環境自動検出で書き出し先・パスを分岐
#   - psmux: ローカル ~/.claude/hooks/.last-notify.json に書き出し
#   - WSL: /mnt/c/Users/<user>/.claude/hooks/.last-notify.json に書き出し
#   - 常駐デーモン (focus-listener-daemon.ps1) が FSW で検知し通知発行

set -euo pipefail

# --- 環境検出 ---
ENV_TYPE="psmux"
WSL_DISTRO=""
if grep -qi microsoft /proc/version 2>/dev/null; then
    ENV_TYPE="wsl"
    # WSL ディストリビューション名 (複数ディストロ対応)
    WSL_DISTRO="${WSL_DISTRO_NAME:-$(grep -oP '^NAME="\K[^"]+' /etc/os-release 2>/dev/null || hostname)}"
fi

# --- Windows ホームパス (WSL 時のみ、キャッシュ付き) ---
WIN_HOOKS_DIR=""
if [ "$ENV_TYPE" = "wsl" ]; then
    CACHE_FILE="$HOME/.cc-win-home"
    if [ -f "$CACHE_FILE" ]; then
        WIN_USER=$(cat "$CACHE_FILE")
    else
        # cmd.exe /c "echo %USERNAME%" (~39ms、初回のみ)
        WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
        if [ -n "$WIN_USER" ]; then
            echo -n "$WIN_USER" > "$CACHE_FILE"
        fi
    fi
    WIN_HOOKS_DIR="/mnt/c/Users/$WIN_USER/.claude/hooks"
fi

# --- stdin から hook payload を読む ---
INPUT=$(cat)

# --- JSON からフィールド抽出 (jq があれば使う、なければ grep) ---
if command -v jq &>/dev/null; then
    MESSAGE=$(echo "$INPUT" | jq -r '.message // empty')
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
    CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
else
    # jq なしフォールバック (簡易パース)
    MESSAGE=$(echo "$INPUT" | grep -oP '"message"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
    SESSION_ID=$(echo "$INPUT" | grep -oP '"session_id"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
    CWD=$(echo "$INPUT" | grep -oP '"cwd"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
fi

# --- プロジェクト名 ---
PROJECT_NAME=""
if [ -n "$CWD" ]; then
    PROJECT_NAME=$(basename "$CWD")
fi

# --- psmux (tmux互換) からセッション名・ペインIDを取得 ---
SESSION_NAME=""
PANE_ID=""

# $TMUX_PANE が設定されていればそれを使う (psmux がセットする場合)
if [ -n "${TMUX_PANE:-}" ]; then
    PANE_ID="$TMUX_PANE"
fi

# tmux display-message で確実に取得 (フォールバック)
if command -v tmux &>/dev/null && [ -n "${TMUX:-}" ]; then
    if [ -z "$SESSION_NAME" ]; then
        SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
    fi
    if [ -z "$PANE_ID" ]; then
        PANE_ID=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
    fi
fi

[ -z "$SESSION_NAME" ] && SESSION_NAME="default"

# --- tmux ソケットパス ---
TMUX_SOCKET=""
if [ -n "${TMUX:-}" ]; then
    # $TMUX 形式: /tmp/psmux-xxx/default,pid,index (psmux) or /tmp/tmux-1000/default,pid,index (WSL)
    UNIX_SOCKET=$(echo "$TMUX" | cut -d, -f1)
    if [ "$ENV_TYPE" = "wsl" ]; then
        # WSL: Linux パスをそのまま格納 (デーモンが wsl -d で使う)
        TMUX_SOCKET="$UNIX_SOCKET"
    else
        # psmux: Windows パス形式に変換、JSON エスケープ
        WIN_SOCKET=$(cygpath -w "$UNIX_SOCKET" 2>/dev/null || echo "$UNIX_SOCKET")
        TMUX_SOCKET=$(echo "$WIN_SOCKET" | sed 's/\\/\\\\/g')
    fi
fi

# --- WT ウィンドウハンドル (起動スクリプトが書き出したファイルから読む) ---
WT_HWND=""
if [ "$ENV_TYPE" = "wsl" ]; then
    # WSL: Windows 側のファイルを /mnt/c/ 経由で読む
    HWND_FILE="$WIN_HOOKS_DIR/.wt-hwnd-$SESSION_NAME"
else
    HWND_FILE="$HOME/.claude/hooks/.wt-hwnd-$SESSION_NAME"
fi
if [ -f "$HWND_FILE" ]; then
    WT_HWND=$(cat "$HWND_FILE" 2>/dev/null | tr -d '[:space:]')
fi

# --- 通知テキスト組み立て ---
# hook_event_name は常に "Notification" なので、message の内容で判断
SUBTITLE=""
if [ -n "$MESSAGE" ]; then
    case "$MESSAGE" in
        *"finished"*|*"complete"*|*"done"*)
            SUBTITLE="Task Complete" ;;
        *"permission"*|*"approve"*)
            SUBTITLE="Permission Required" ;;
        *"question"*|*"input"*|*"waiting"*)
            SUBTITLE="Question for You" ;;
        *)
            SUBTITLE="$MESSAGE" ;;
    esac
else
    SUBTITLE="Awaiting Input"
fi

# --- UniqueIdentifier (英数字とハイフンのみ) ---
TAG=$(echo "cc-${SESSION_NAME}-${PANE_ID}" | tr -cd 'a-zA-Z0-9-')

# --- ペイン情報をファイルに書き出し (常駐デーモンが FSW で検知) ---
if [ "$ENV_TYPE" = "wsl" ]; then
    # WSL: Windows 側のパスに書き出し (FSW が検知できるよう /mnt/c/ 経由)
    NOTIFY_DIR="$WIN_HOOKS_DIR"
else
    NOTIFY_DIR="$HOME/.claude/hooks"
fi
NOTIFY_FILE="$NOTIFY_DIR/.last-notify.json"
mkdir -p "$NOTIFY_DIR"

# WSL 時は env, wsl_distro フィールドを追加
WSL_FIELDS=""
if [ "$ENV_TYPE" = "wsl" ]; then
    WSL_FIELDS="$(cat <<WSLEOF
    "env": "wsl",
    "wsl_distro": "$WSL_DISTRO",
WSLEOF
)"
else
    WSL_FIELDS='    "env": "psmux",'
fi

cat > "$NOTIFY_FILE" <<EOF
{
    "session_name": "$SESSION_NAME",
    "pane_id": "$PANE_ID",
    "project": "$PROJECT_NAME",
    "subtitle": "$SUBTITLE",
    "tag": "$TAG",
    "tmux_socket": "$TMUX_SOCKET",
    "wt_hwnd": "$WT_HWND",
$WSL_FIELDS
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# 通知発行は常駐デーモン (focus-listener-daemon.ps1) が FSW 経由で行う
exit 0
