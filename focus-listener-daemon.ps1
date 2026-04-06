#!/usr/bin/env pwsh
<#
.SYNOPSIS
    BurntToast 通知発行 + クリック → psmux/WSL ペインフォーカス 常駐デーモン
.DESCRIPTION
    psmux/WSL 両環境に対応し、以下を一貫して処理する:
      1. FileSystemWatcher で notify-queue/ ディレクトリの新規ファイルを検知
      2. ToastContentBuilder で launch 引数にペイン情報を埋め込んだトースト通知を発行
      3. OnActivated で launch 引数をパースし、psmux/WSL ペインにフォーカス

    1通知=1ファイルのキューモデルにより、同時通知の race condition を解消。
    クリック時はファイル読み込み不要 (launch 引数から直接ペイン情報を取得)。

    環境判定: launch 引数の "env" キーで分岐
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

    # --- OnActivated: クリック → launch 引数パース → ペインフォーカス + WT アクティブ化 ---
    # 注意: Register-ObjectEvent は1回のみ。再登録すると OnActivated が壊れる
    # OnActivated は非標準1引数デリゲートのため $Event.SourceEventArgs は null になる。
    # $args[0] (= $Event.SourceArgs[0]) から ToastNotificationActivatedEventArgsCompat を取得する。
    $CompatMgr = [Microsoft.Toolkit.Uwp.Notifications.ToastNotificationManagerCompat]

    $null = Register-ObjectEvent -InputObject $CompatMgr -EventName OnActivated `
        -SourceIdentifier "CCFocusDaemon_OnActivated" -Action {

        $logPath = Join-Path $HOME ".claude" "hooks" "focus-listener-daemon.log"

        try {
            # --- launch 引数パース (ファイル読み込み不要、race condition なし) ---
            $eventArgs = $args[0]
            if (-not $eventArgs) { $eventArgs = $Event.SourceArgs[0] }
            $argString = $eventArgs.Argument

            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [CLICK] OnActivated fired, args='$argString'" |
                Out-File $logPath -Append -Encoding utf8

            if (-not $argString) { return }

            # ToastArguments.Parse で URL デコード付きパース (% → %25 自動変換に対応)
            $parsed = [Microsoft.Toolkit.Uwp.Notifications.ToastArguments]::Parse($argString)
            $paneId = $parsed["pane_id"]
            $socket = $parsed["tmux_socket"]
            $envType = if ($parsed.Contains("env")) { $parsed["env"] } else { "psmux" }
            $windowIndex = if ($parsed.Contains("window_index")) { $parsed["window_index"] } else { "" }
            $sessionName = if ($parsed.Contains("session_name")) { $parsed["session_name"] } else { "" }
            $wslDistro = if ($parsed.Contains("wsl_distro")) { $parsed["wsl_distro"] } else { "" }
            $wtHwnd = if ($parsed.Contains("wt_hwnd")) { $parsed["wt_hwnd"] } else { "" }

            # --- ペインフォーカス (env 判定で psmux/WSL を分岐) ---
            if ($paneId -and $socket) {
                # peers 環境では各ピアが独立した psmux window として並ぶため、
                # select-pane だけでは window が切り替わらない。
                # psmux は select-window -t @N (window_id形式) を受け付けない
                # (数値 index として誤解釈) ため、"session_name:window_index" 形式で指定する。
                $winTarget = if ($sessionName -and $windowIndex) { "${sessionName}:${windowIndex}" } else { "" }

                if ($envType -eq "wsl" -and $wslDistro) {
                    # WSL: session:index で select-window してから select-pane
                    if ($winTarget) {
                        & wsl -d $wslDistro -- tmux -S $socket select-window -t $winTarget 2>&1 | Out-Null
                    }
                    $r = & wsl -d $wslDistro -- tmux -S $socket select-pane -t $paneId 2>&1
                    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [CLICK] WSL select-window=$winTarget pane=$paneId distro=$wslDistro socket=$socket exit=$LASTEXITCODE" |
                        Out-File $logPath -Append -Encoding utf8
                } else {
                    # psmux: session:index で select-window してから select-pane
                    if ($winTarget) {
                        & tmux -S $socket select-window -t $winTarget 2>&1 | Out-Null
                    }
                    $r = & tmux -S $socket select-pane -t $paneId 2>&1
                    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [CLICK] select-window=$winTarget pane=$paneId socket=$socket exit=$LASTEXITCODE" |
                        Out-File $logPath -Append -Encoding utf8
                }
            } elseif ($paneId) {
                # ソケット未指定フォールバック
                & tmux select-pane -t $paneId 2>&1 | Out-Null
            }

            # --- Windows Terminal をフォアグラウンドに ---
            $hwnd = [IntPtr]::Zero
            if ($wtHwnd) {
                $hwnd = [IntPtr]::new([long]$wtHwnd)
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

    # --- キューディレクトリ準備 (起動時掃除 + 作成) ---
    $queueDir = Join-Path $HOME ".claude" "hooks" "notify-queue"
    if (Test-Path $queueDir) {
        Get-ChildItem $queueDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Log "Queue dir cleaned: $queueDir"
    } else {
        New-Item -ItemType Directory -Path $queueDir -Force | Out-Null
        Log "Queue dir created: $queueDir"
    }

    # --- FileSystemWatcher: notify-queue/ に新規ファイル → 通知発行 ---
    $watcher = [System.IO.FileSystemWatcher]::new($queueDir, "*.json")
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
    $watcher.IncludeSubdirectories = $false

    $null = Register-ObjectEvent $watcher Created -SourceIdentifier "CCFocusDaemon_FSW" -Action {
        $logPath = Join-Path $HOME ".claude" "hooks" "focus-listener-daemon.log"
        $iconFile = Join-Path $HOME ".claude" "icons" "claude-ai-icon.png"

        try {
            $filePath = $Event.SourceEventArgs.FullPath

            # ファイル書き込み完了待ち (hook 側の cat > が終わるまで)
            Start-Sleep -Milliseconds 50

            $info = Get-Content $filePath -Raw -ErrorAction Stop | ConvertFrom-Json

            # 通知テキスト組み立て
            $paneLabel = ""
            if ($info.pane_id) { $paneLabel = ":$($info.pane_id)" }
            $body = "$($info.subtitle)`n$($info.project) [$($info.session_name)$paneLabel]"

            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [FSW] Sending notification: tag=$($info.tag) file=$($Event.SourceEventArgs.Name)" |
                Out-File $logPath -Append -Encoding utf8

            # --- ToastContentBuilder で launch 引数にペイン情報を埋め込み ---
            # クリック時に OnActivated がこの引数をパースしてフォーカス先を特定する
            $builder = [Microsoft.Toolkit.Uwp.Notifications.ToastContentBuilder]::new()
            $null = $builder.AddArgument("pane_id", "$($info.pane_id)")
            $null = $builder.AddArgument("session_name", "$($info.session_name)")
            $null = $builder.AddArgument("window_index", "$($info.window_index)")
            $null = $builder.AddArgument("tmux_socket", "$($info.tmux_socket)")
            $null = $builder.AddArgument("wt_hwnd", "$($info.wt_hwnd)")
            $null = $builder.AddArgument("env", "$(if ($info.env) { $info.env } else { 'psmux' })")
            if ($info.wsl_distro) {
                $null = $builder.AddArgument("wsl_distro", "$($info.wsl_distro)")
            }
            $null = $builder.AddText("Claude Code")
            $null = $builder.AddText($body)

            # アイコン設定 (AppLogoOverride)
            if (Test-Path $iconFile) {
                $null = $builder.AddAppLogoOverride(
                    [Uri]::new($iconFile),
                    [Microsoft.Toolkit.Uwp.Notifications.ToastGenericAppLogoCrop]::Default)
            }

            # BurntToast の Submit-BTNotification で発行 (Tag による replace セマンティクス維持)
            # ToastContentBuilder が生成した launch 引数は ToastContent XML に埋め込まれている
            Submit-BTNotification -Content $builder.GetToastContent() -UniqueIdentifier "$($info.tag)"

            # aliveCheck 用: 最新の環境情報をグローバル変数に保存
            $global:CCLastSocket = $info.tmux_socket
            $global:CCLastEnv = if ($info.env) { $info.env } else { "psmux" }
            $global:CCLastDistro = $info.wsl_distro

            # キューファイル削除 (処理済み)
            Remove-Item $filePath -Force -ErrorAction SilentlyContinue

        } catch {
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [FSW] Error: $_" |
                Out-File $logPath -Append -Encoding utf8
        }
    }
    $watcher.EnableRaisingEvents = $true
    Log "FileSystemWatcher registered on $queueDir (*.json, Created)"

    # --- メインループ: DoEvents(COM) + Start-Sleep(PS events) ---
    Log "Entering main loop..."
    $aliveCheckCounter = 0

    # aliveCheck 用グローバル変数初期化 (FSW ハンドラから更新される)
    $global:CCLastSocket = $null
    $global:CCLastEnv = $null
    $global:CCLastDistro = $null

    while ($true) {
        # COM メッセージポンプ (OnActivated コールバック処理)
        [System.Windows.Forms.Application]::DoEvents()
        # PS イベントキュー処理 (Register-ObjectEvent)
        Start-Sleep -Milliseconds 100

        # tmux サーバー生存確認 (~30秒ごと)
        $aliveCheckCounter++
        if ($aliveCheckCounter -ge 300) {
            $aliveCheckCounter = 0

            # FSW ハンドラが $global: に保存した最新の環境情報を使う
            $lastSocket = $global:CCLastSocket
            $lastEnv = $global:CCLastEnv
            $lastDistro = $global:CCLastDistro

            # まだ通知が1件も来ていなければスキップ
            if (-not $lastSocket) { continue }

            # 環境に応じた tmux 生存確認
            $tmuxAlive = $false
            try {
                if ($lastEnv -eq "wsl" -and $lastDistro) {
                    # WSL: wsl -d <distro> -- tmux list-sessions
                    $null = & wsl -d $lastDistro -- tmux -S $lastSocket list-sessions 2>$null
                } else {
                    # psmux: 直接 tmux コマンド
                    $null = & tmux -S $lastSocket list-sessions 2>$null
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
