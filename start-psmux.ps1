#!/usr/bin/env pwsh
<#
.SYNOPSIS
    psmux セッション開始 + CC通知リスナーデーモン起動
.DESCRIPTION
    psmux セッションを作成し、CC通知のクリック検出用デーモンをバックグラウンドで起動する。
    起動時に Windows Terminal の HWND を取得し、セッション名に紐づけて保存する。
.NOTES
    配置先: ~/start-psmux.ps1
#>

param(
    [string]$SessionName = "work"
)

# --- WT HWND をプロセスツリーから取得 ---
# 現在のプロセスから親を辿り、WindowsTerminal を探す
function Get-WtHwnd {
    $currentPid = $PID
    for ($i = 0; $i -lt 10; $i++) {
        # CIM で親プロセスIDを取得
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$currentPid" -ErrorAction SilentlyContinue
        if (-not $proc -or -not $proc.ParentProcessId) { break }

        $parentPid = $proc.ParentProcessId
        $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
        if (-not $parent) { break }

        if ($parent.ProcessName -eq "WindowsTerminal" -and $parent.MainWindowHandle -ne [IntPtr]::Zero) {
            return $parent.MainWindowHandle
        }
        $currentPid = $parentPid
    }

    # フォールバック: プロセス名で検索 (単一 WT ウィンドウの場合)
    $wt = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
          Select-Object -First 1
    if ($wt) { return $wt.MainWindowHandle }

    return $null
}

# --- HWND 取得・保存 ---
$hooksDir = Join-Path $HOME ".claude" "hooks"
if (-not (Test-Path $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }

$wtHwnd = Get-WtHwnd
$hwndFile = Join-Path $hooksDir ".wt-hwnd-$SessionName"
if ($wtHwnd) {
    [string]$wtHwnd | Out-File $hwndFile -NoNewline -Encoding ascii
    Write-Host "WT HWND: $wtHwnd (saved to $hwndFile)" -ForegroundColor DarkGray
} else {
    Write-Host "Warning: Could not detect WT HWND. Click-to-focus may fall back to process search." -ForegroundColor Yellow
}

# --- psmux セッション作成 (既存セッションがあれば attach) ---
$null = & tmux has-session -t $SessionName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating psmux session: $SessionName" -ForegroundColor Cyan
    & tmux new-session -d -s $SessionName
}

# --- CC通知フォーカスリスナーデーモン起動 ---
$daemonScript = Join-Path $hooksDir "focus-listener-daemon.ps1"
if (Test-Path $daemonScript) {
    # 多重起動防止は daemon 側の Mutex で行うが、プロセス検索で事前チェック
    $daemonProcess = Get-Process pwsh -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*focus-listener-daemon*" }

    if (-not $daemonProcess) {
        Write-Host "Starting CC focus listener daemon..." -ForegroundColor Green
        Start-Process pwsh -ArgumentList @(
            "-STA", "-NoProfile", "-WindowStyle", "Hidden",
            "-File", $daemonScript
        ) -WindowStyle Hidden
    } else {
        Write-Host "CC focus listener daemon already running." -ForegroundColor DarkGreen
    }
}

# --- psmux セッションに attach ---
Write-Host "Attaching to psmux session: $SessionName" -ForegroundColor Cyan
& tmux attach -t $SessionName
