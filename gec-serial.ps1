# Agent/CLI entry. Do not invent raw dd. Actions: cmd | xfer | start
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("cmd", "xfer", "start")]
    [string]$Action,
    [string]$Command = "",
    [string]$LocalFile = "",
    [string]$RemoteFile = "/home/vehicle_course",
    [string]$PortName = "",
    [int]$Baud = 115200,
    [int]$WaitMs = 2000,
    [switch]$Install,
    [switch]$Run
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "serial-transfer-core.ps1")

if ([string]::IsNullOrWhiteSpace($PortName)) {
    $PortName = Get-GecCh340Port
}
if ([string]::IsNullOrWhiteSpace($PortName)) {
    Write-Host "找不到状态 OK 的 CH340。用 -PortName 指定。先关 MobaXterm 串口标签。"
    exit 2
}

function New-CliState {
    $logs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    return [hashtable]::Synchronized(@{
        local = $LocalFile
        remote = $RemoteFile
        port = $PortName
        baud = $Baud
        install = [bool]$Install
        run = [bool]$Run
        cancel = $false
        done = 0L
        total = 1L
        t0 = (Get-Date)
        logs = $logs
        error = $null
        finished = $false
        ok = $false
        message = ""
    })
}

function Write-CliLogs($st) {
    foreach ($line in @($st.logs)) {
        Write-Host $line
    }
}

function Invoke-CliCmd {
    param($Port, $BaudRate, $CmdText, $Ms)
    $code = 1
    $st = New-CliState
    $p = $null
    try {
        try {
            $p = Open-GecSerialPort $Port $BaudRate
        } catch {
            Write-Host $_.Exception.Message
            return 2
        }
        if (Restore-GecShell $p $st) {
            $out = Send-GecCmd $p $CmdText $Ms
            Write-Host $out
            if ($out -match ".") { $code = 0 }
        } else {
            Write-CliLogs $st
            Write-Host "board_no_echo。按板上复位后再试。"
        }
    } finally {
        try { if ($p.IsOpen) { $p.Close() } } catch {}
    }
    return $code
}

if ($Action -eq "cmd") {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-Host "cmd 需要 -Command"
        exit 2
    }
    $rc = Invoke-CliCmd $PortName $Baud $Command $WaitMs
    exit $rc
}

$st = New-CliState
if ($Action -eq "xfer") {
    if (-not (Test-Path -LiteralPath $LocalFile)) {
        Write-Host ("找不到本地文件: " + $LocalFile)
        exit 2
    }
    Invoke-GecSerialTransfer $st
} else {
    Invoke-GecSerialStart $st
}
Write-CliLogs $st
if ($st.ok) {
    if ($st.message) { Write-Host $st.message }
    exit 0
}
Write-Host $st.error
exit 1
