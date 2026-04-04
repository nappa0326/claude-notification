#!/usr/bin/env pwsh
<#
.SYNOPSIS
    BurntToast 通知発行 + クリック → psmux/WSL ペインフォーカス 常駐デーモン
.DESCRIPTION
    psmux/WSL 両環境に対応し、以下を一貫して処理する:
      1. FileSystemWatcher で .last-notify.json の変更を検知
      2. BurntToast でトースト通知を発行
      3. OnActivated でクリックを検出し、psmux/WSL ペインにフォーカス

    環境判定: .last-notify.json の "env" フィールドで分岐
      - "psmux" (or 未設定): tmux -S <socket> select-pane
      - "wsl": wsl -d <distro> -- tmux -S <socket> select-pane

    COM アクティベーション制約により、通知発行とクリック検出は
    同一プロセスで行う必要がある。不可視 WinForms フォームで HWND を確保し、
    DoEvents() で COM メッセージをポンプする。

    起動方法: pwsh -STA -WindowStyle Hidden -NoProfile -File <this script>
.NOTES
    配置先: ~/.claude/hooks/focus-listener-daemon.ps1
    起動元: start-psmux.ps1 (psmux) / start-wsl.sh (WSL)
#>

# --- 多重起動防止 ---
$mutexName = "Global\CCFocusListenerDaemon"
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$acquired = $false
try {
    $acquired = $mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
}

if (-not $acquired) {
    # 既に別インスタンスが動作中
    exit 0
}

try {
    # --- ログ ---
    $logFile = Join-Path $HOME ".claude" "hooks" "focus-listener-daemon.log"
    function Log($msg) {
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $msg" |
            Out-File $logFile -Append -Encoding utf8
    }

    # --- 初期化ログ ---
    $apt = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] === Daemon Start (PID=$PID, Apartment=$apt) ===" |
        Out-File $logFile -Encoding utf8

    # --- PATH にcargo bin等を追加 (psmux の tmux コマンド用) ---
    $cargoBin = Join-Path $HOME ".cargo" "bin"
    if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }
    $wingetLinks = Join-Path $env:LOCALAPPDATA "Microsoft" "WinGet" "Links"
    if (Test-Path $wingetLinks) { $env:PATH = "$wingetLinks;$env:PATH" }

    # --- Win32 API 定義 ---
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinFocus {
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public const int SW_SHOW = 5;
}
'@ -ErrorAction SilentlyContinue

    # --- アセンブリ・モジュール読み込み ---
    Add-Type -AssemblyName System.Windows.Forms
    Import-Module BurntToast -ErrorAction Stop
    Log "Loaded (BurntToast + System.Windows.Forms)"

    # --- 不可視フォーム作成 (COM コールバック用 HWND 確保) ---
    $form = [System.Windows.Forms.Form]::new()
    $form.ShowInTaskbar = $false
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    $form.Opacity = 0
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.Size = [System.Drawing.Size]::new(1, 1)
    $null = $form.Handle  # HWND 強制生成
    Log "Form created (HWND=$($form.Handle))"

    # --- アイコンパス ---
    $iconPath = Join-Path $HOME ".claude" "icons" "claude-ai-icon.png"
    $hasIcon = Test-Path $iconPath
    if ($hasIcon) { Log "Icon: $iconPath" }

    # --- OnActivated: クリック → ペインフォーカス + WT アクティブ化 ---
    # 注意: Register-ObjectEvent は1回のみ。再登録すると OnActivated が壊れる
    $CompatMgr = [Microsoft.Toolkit.Uwp.Notifications.ToastNotificationManagerCompat]

    $null = Register-ObjectEvent -InputObject $CompatMgr -EventName OnActivated `
        -SourceIdentifier "CCFocusDaemon_OnActivated" -Action {

        $logPath = Join-Path $HOME ".claude" "hooks" "focus-listener-daemon.log"
        $notifyFile = Join-Path $HOME ".claude" "hooks" ".last-notify.json"

        try {
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [CLICK] OnActivated fired" |
                Out-File $logPath -Append -Encoding utf8

            if (-not (Test-Path $notifyFile)) { return }
            $info = Get-Content $notifyFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if (-not $info) { return }

            # --- ペインフォーカス (env 判定で psmux/WSL を分岐) ---
            $paneId = $info.pane_id
            $socket = $info.tmux_socket
            $envType = if ($info.env) { $info.env } else { "psmux" }

            if ($paneId -and $socket) {
                if ($envType -eq "wsl" -and $info.wsl_distro) {
                    # WSL: wsl -d <distro> -- tmux -S <socket> select-pane -t <pane_id>
                    $r = & wsl -d $info.wsl_distro -- tmux -S $socket select-pane -t $paneId 2>&1
                    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [CLICK] WSL select-pane=$paneId distro=$($info.wsl_distro) socket=$socket exit=$LASTEXITCODE" |
                        Out-File $logPath -Append -Encoding utf8
                } else {
                    # psmux: 直接 tmux コマンド
                    $r = & tmux -S $socket select-pane -t $paneId 2>&1
                    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [CLICK] select-pane=$paneId socket=$socket exit=$LASTEXITCODE" |
                        Out-File $logPath -Append -Encoding utf8
                }
            } elseif ($paneId) {
                # ソケット未指定フォールバック
                & tmux select-pane -t $paneId 2>&1 | Out-Null
            }

            # --- Windows Terminal をフォアグラウンドに ---
            $hwnd = [IntPtr]::Zero
            if ($info.wt_hwnd) {
                $hwnd = [IntPtr]::new([long]$info.wt_hwnd)
            } else {
                # フォールバック: プロセス名で検索
                $proc = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue |
                        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
                        Select-Object -First 1
                if ($proc) { $hwnd = $proc.MainWindowHandle }
            }
            if ($hwnd -ne [IntPtr]::Zero) {
                [WinFocus]::ShowWindow($hwnd, [WinFocus]::SW_SHOW)
                [WinFocus]::SetForegroundWindow($hwnd)
                "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [CLICK] SetForegroundWindow hwnd=$hwnd" |
                    Out-File $logPath -Append -Encoding utf8
            }
        } catch {
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [CLICK] Error: $_" |
                Out-File $logPath -Append -Encoding utf8
        }
    }
    Log "OnActivated registered"

    # --- FileSystemWatcher: .last-notify.json 変更 → 通知発行 ---
    $hooksDir = Join-Path $HOME ".claude" "hooks"
    $watcher = [System.IO.FileSystemWatcher]::new($hooksDir, ".last-notify.json")
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite

    $null = Register-ObjectEvent $watcher Changed -SourceIdentifier "CCFocusDaemon_FSW" -Action {
        # FSW は LastWrite で2回発火するため、少し待ってから読む
        Start-Sleep -Milliseconds 200

        $logPath = Join-Path $HOME ".claude" "hooks" "focus-listener-daemon.log"
        $notifyFile = Join-Path $HOME ".claude" "hooks" ".last-notify.json"
        $iconFile = Join-Path $HOME ".claude" "icons" "claude-ai-icon.png"

        try {
            $info = Get-Content $notifyFile -Raw -ErrorAction Stop | ConvertFrom-Json

            # 重複排除: tag が前回と同じなら無視 (LastWrite 2回発火対策)
            if ($info.tag -eq $script:lastTag) { return }
            $script:lastTag = $info.tag

            # 通知テキスト組み立て
            $paneLabel = ""
            if ($info.pane_id) { $paneLabel = ":$($info.pane_id)" }
            $body = "$($info.subtitle)`n$($info.project) [$($info.session_name)$paneLabel]"

            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [FSW] Sending notification: tag=$($info.tag)" |
                Out-File $logPath -Append -Encoding utf8

            # BurntToast 通知発行
            $toastParams = @{
                Text             = "Claude Code", $body
                UniqueIdentifier = $info.tag
                Sound            = "Default"
            }
            if (Test-Path $iconFile) {
                $toastParams["AppLogo"] = $iconFile
            }
            New-BurntToastNotification @toastParams

        } catch {
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [FSW] Error: $_" |
                Out-File $logPath -Append -Encoding utf8
        }
    }
    $watcher.EnableRaisingEvents = $true
    Log "FileSystemWatcher registered"

    # --- メインループ: DoEvents(COM) + Start-Sleep(PS events) ---
    Log "Entering main loop..."
    $aliveCheckCounter = 0
    $lastSocket = $null
    $lastEnv = $null
    $lastDistro = $null

    while ($true) {
        # COM メッセージポンプ (OnActivated コールバック処理)
        [System.Windows.Forms.Application]::DoEvents()
        # PS イベントキュー処理 (Register-ObjectEvent)
        Start-Sleep -Milliseconds 100

        # tmux サーバー生存確認 (~30秒ごと)
        $aliveCheckCounter++
        if ($aliveCheckCounter -ge 300) {
            $aliveCheckCounter = 0

            # .last-notify.json からソケットパス・環境情報を取得 (あれば)
            $notifyFile = Join-Path $HOME ".claude" "hooks" ".last-notify.json"
            if (Test-Path $notifyFile) {
                try {
                    $info = Get-Content $notifyFile -Raw -ErrorAction SilentlyContinue |
                            ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($info.tmux_socket) { $lastSocket = $info.tmux_socket }
                    if ($info.env) { $lastEnv = $info.env }
                    if ($info.wsl_distro) { $lastDistro = $info.wsl_distro }
                } catch { }
            }

            # 環境に応じた tmux 生存確認
            $tmuxAlive = $false
            try {
                if ($lastEnv -eq "wsl" -and $lastDistro) {
                    # WSL: wsl -d <distro> -- tmux list-sessions
                    if ($lastSocket) {
                        $null = & wsl -d $lastDistro -- tmux -S $lastSocket list-sessions 2>$null
                    } else {
                        $null = & wsl -d $lastDistro -- tmux list-sessions 2>$null
                    }
                } else {
                    # psmux: 直接 tmux コマンド
                    if ($lastSocket) {
                        $null = & tmux -S $lastSocket list-sessions 2>$null
                    } else {
                        $null = & tmux list-sessions 2>$null
                    }
                }
                $tmuxAlive = ($LASTEXITCODE -eq 0)
            } catch { }

            if (-not $tmuxAlive) {
                Log "tmux server not responding. Exiting."
                break
            }
        }
    }

} finally {
    # --- クリーンアップ ---
    Log "Shutting down..."
    Unregister-Event -SourceIdentifier "CCFocusDaemon_OnActivated" -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier "CCFocusDaemon_FSW" -ErrorAction SilentlyContinue
    if ($watcher) { $watcher.Dispose() }
    if ($form) { $form.Dispose() }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Log "Stopped."
}
