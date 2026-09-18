# GEC6818 交互终端：PuTTY/MobaXterm 风格，在黑框里直接键入。
# 依赖：Open-GecSerialPort / Restore-GecShell / Read-GecSerialRaw / Send-GecSerialBytes
# 以及 GUI 里的 Get-PortBaud、Set-PortControlsEnabled、Update-ConnLabel、$btnStart/$btnRun/$script:Xfer

$script:TermPort = $null
$script:TermConnected = $false
$script:TermState = $null
$script:TermLines = New-Object System.Collections.Generic.List[string]
$script:TermCurLine = ""
$script:TermCurCol = 0
$script:TermEsc = 0
$script:TermCsi = ""
$script:TermOscLen = 0
$script:TermUtfNeed = 0
$script:TermUtfAcc = New-Object System.Collections.Generic.List[byte]
$script:TermDirty = $false
$script:TermCols = 80
$script:TermRows = 24
$script:TermSelecting = $false
$script:LastLaunch = $null

$uiBg = $script:Ui.Bg
$uiSurface = $script:Ui.Card
$uiOk = $script:Ui.Ok
$uiDanger = $script:Ui.Danger
$uiText = $script:Ui.Text
$uiMuted = $script:Ui.Muted
$uiAccent = $script:Ui.Accent
$uiSeg = $script:Ui.Seg

$termGrid = New-Object System.Windows.Forms.TableLayoutPanel
$termGrid.Dock = "Fill"
$termGrid.ColumnCount = 1
$termGrid.RowCount = 4
$termGrid.BackColor = $uiBg
$termGrid.GrowStyle = "FixedSize"
[void]$termGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48)))
[void]$termGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48)))
[void]$termGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$termGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 68)))
$tabTerm.Controls.Add($termGrid)

$termBar.Parent = $termGrid
$termBar.Dock = "Fill"
$termBar.BackColor = $uiBg
$termGrid.SetRow($termBar, 0)

$termLaunch = New-Object System.Windows.Forms.Panel
$termLaunch.Dock = "Fill"
$termLaunch.BackColor = $uiBg
$termGrid.Controls.Add($termLaunch)
$termGrid.SetRow($termLaunch, 1)
$lblLaunch = New-Object System.Windows.Forms.Label
$lblLaunch.Text = "快捷启动"
$lblLaunch.Location = New-Object System.Drawing.Point(4, 12)
$lblLaunch.Size = New-Object System.Drawing.Size(72, 22)
$lblLaunch.ForeColor = $uiMuted
$lblLaunch.BackColor = [System.Drawing.Color]::Transparent
$termLaunch.Controls.Add($lblLaunch)
$fldLaunch = New-Field $termLaunch 80 6 420 36
$txtLaunch = Add-Box $fldLaunch 0 0 100
$txtLaunch.Dock = "Fill"
if ($txtRemote -and $txtRemote.Text) { $txtLaunch.Text = $txtRemote.Text } else { $txtLaunch.Text = "/home/" }
$btnTermLaunch = Add-Btn $termLaunch "启动" 508 6 72 36 $script:Ui.Ink ([System.Drawing.Color]::White)
$btnTermStop = Add-Btn $termLaunch "停止" 588 6 72 36 $script:Ui.Danger ([System.Drawing.Color]::White)
$btnTermStop.Enabled = $false
$termLaunch.Add_Resize({
    $w = $termLaunch.ClientSize.Width
    $fldLaunch.Width = [Math]::Max(160, $w - 264)
    $btnTermLaunch.Left = $fldLaunch.Left + $fldLaunch.Width + 8
    $btnTermStop.Left = $btnTermLaunch.Left + $btnTermLaunch.Width + 8
})

$termShell = New-Card $termGrid
$termShell.Dock = "Fill"
$termShell.BackColor = $script:Ui.TermBg
$termShell.LineColor = $script:Ui.TermBg
$termShell.CornerRadius = 12
$termShell.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 8)
$termShell.Padding = New-Object System.Windows.Forms.Padding(12)
$termGrid.SetRow($termShell, 2)

$termQuick = New-Object System.Windows.Forms.FlowLayoutPanel
$termQuick.Dock = "Fill"
$termQuick.BackColor = $uiBg
$termQuick.WrapContents = $true
$termQuick.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$termGrid.Controls.Add($termQuick)
$termGrid.SetRow($termQuick, 3)

$txtTerm = New-Object System.Windows.Forms.TextBox
$txtTerm.Multiline = $true
$txtTerm.ScrollBars = "Both"
$txtTerm.WordWrap = $true
$txtTerm.ReadOnly = $true
$txtTerm.Dock = "Fill"
$txtTerm.BackColor = $script:Ui.TermBg
$txtTerm.ForeColor = $script:Ui.TermFg
$txtTerm.Font = New-Object System.Drawing.Font("Consolas", 11)
$txtTerm.BorderStyle = "None"
$txtTerm.HideSelection = $false
$txtTerm.ShortcutsEnabled = $false
$txtTerm.MaxLength = 4000000
$txtTerm.AcceptsTab = $true
$txtTerm.AcceptsReturn = $true
$termShell.Controls.Add($txtTerm)
$txtTerm.Add_PreviewKeyDown({
    $n = [string]$_.KeyCode
    if ($n -eq "Tab" -or $n -eq "Up" -or $n -eq "Down" -or $n -eq "Left" -or $n -eq "Right" -or $n -eq "Home" -or $n -eq "End" -or $n -eq "Prior" -or $n -eq "Next") {
        $_.IsInputKey = $true
    }
})

$lblQuick = New-Object System.Windows.Forms.Label
$lblQuick.Text = "快捷命令"
$lblQuick.AutoSize = $true
$lblQuick.ForeColor = $uiMuted
$lblQuick.Margin = New-Object System.Windows.Forms.Padding(0, 8, 10, 0)
$termQuick.Controls.Add($lblQuick)

$quickCmds = @("uname -a", "ls -l /home", "df -h /home", "pidof vehicle_course", "cat /tmp/vc.log", "free")
foreach ($qc in $quickCmds) {
    $w = [Math]::Min(160, 52 + ($qc.Length * 7))
    $qb = Add-Btn $termQuick $qc 0 0 $w 28 $uiSeg $uiText
    $qb.Tag = $qc
    $qb.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
    $qb.Add_Click({
        if (-not $script:TermConnected) { return }
        Send-TerminalCommand ([string]$this.Tag)
        $txtTerm.Focus()
    })
}

function Get-TermSize {
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText("M", $txtTerm.Font)
    $cw = [Math]::Max(6, $sz.Width)
    $ch = [Math]::Max(10, $sz.Height)
    $cols = [int]($txtTerm.ClientSize.Width / $cw)
    $rows = [int]($txtTerm.ClientSize.Height / $ch)
    if ($cols -lt 40) { $cols = 40 }
    if ($cols -gt 132) { $cols = 132 }
    if ($rows -lt 12) { $rows = 12 }
    if ($rows -gt 60) { $rows = 60 }
    $script:TermCols = $cols
    $script:TermRows = $rows
}

function Reset-TerminalEmulator {
    $script:TermLines = New-Object System.Collections.Generic.List[string]
    $script:TermCurLine = ""
    $script:TermCurCol = 0
    $script:TermEsc = 0
    $script:TermCsi = ""
    $script:TermOscLen = 0
    $script:TermUtfNeed = 0
    $script:TermUtfAcc.Clear()
    $script:TermDirty = $true
    $txtTerm.Clear()
}

function Get-TermDisplayText {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ln in $script:TermLines) {
        [void]$sb.Append($ln)
        [void]$sb.Append("`r`n")
    }
    [void]$sb.Append($script:TermCurLine)
    return $sb.ToString()
}

function Snap-TermCaret {
    if ($script:TermSelecting) { return }
    $txtTerm.SelectionLength = 0
    $txtTerm.SelectionStart = $txtTerm.Text.Length
    $txtTerm.ScrollToCaret()
}

function Sync-TerminalDisplay {
    if (-not $script:TermDirty) { return }
    $script:TermDirty = $false
    if ($script:TermSelecting -and $txtTerm.SelectionLength -gt 0) { return }
    $shown = Get-TermDisplayText
    $old = $txtTerm.Text
    if ($shown -eq $old) {
        Snap-TermCaret
        return
    }
    if ($shown.StartsWith($old) -and $old.Length -gt 0) {
        $txtTerm.AppendText($shown.Substring($old.Length))
    } else {
        $txtTerm.Text = $shown
    }
    Snap-TermCaret
}

function Term-TrimHistory {
    if ($script:TermLines.Count -le 1800) { return }
    $script:TermLines.RemoveRange(0, 400)
}

function Term-WriteChar([char]$ch) {
    $line = $script:TermCurLine
    $col = $script:TermCurCol
    if ($col -lt $line.Length) {
        $script:TermCurLine = $line.Substring(0, $col) + $ch + $line.Substring($col + 1)
    } else {
        if ($col -gt $line.Length) {
            $script:TermCurLine = $line + (" " * ($col - $line.Length)) + $ch
        } else {
            $script:TermCurLine = $line + $ch
        }
    }
    $script:TermCurCol++
    if ($script:TermCols -gt 8 -and $script:TermCurCol -ge $script:TermCols) {
        Term-CommitLine
        return
    }
    $script:TermDirty = $true
}

function Term-Backspace {
    if ($script:TermCurCol -le 0) { return }
    $script:TermCurCol--
    $line = $script:TermCurLine
    if ($script:TermCurCol -lt $line.Length) {
        $script:TermCurLine = $line.Remove($script:TermCurCol, 1)
    }
    $script:TermDirty = $true
}

function Term-CommitLine {
    $script:TermLines.Add($script:TermCurLine)
    $script:TermCurLine = ""
    $script:TermCurCol = 0
    Term-TrimHistory
    $script:TermDirty = $true
}

function Term-EraseInLine([string]$p) {
    $line = $script:TermCurLine
    $col = $script:TermCurCol
    if ($p -eq "2") {
        $script:TermCurLine = ""
        $script:TermCurCol = 0
    } elseif ($p -eq "1") {
        if ($col -lt $line.Length) {
            $script:TermCurLine = (" " * $col) + $line.Substring($col)
        } else {
            $script:TermCurLine = ""
            $script:TermCurCol = 0
        }
    } else {
        if ($col -lt $line.Length) {
            $script:TermCurLine = $line.Substring(0, $col)
        }
    }
    $script:TermDirty = $true
}

function Apply-TermCsi([string]$seq) {
    if ([string]::IsNullOrEmpty($seq)) { return }
    $cmd = $seq.Substring($seq.Length - 1, 1)
    $params = ""
    if ($seq.Length -gt 1) { $params = $seq.Substring(0, $seq.Length - 1) }
    switch ($cmd) {
        "J" {
            if ($params -eq "2" -or $params -eq "3") { Reset-TerminalEmulator }
        }
        "K" { Term-EraseInLine $params }
        "A" {
            $n = 1
            [void][int]::TryParse($params, [ref]$n)
            if ($n -lt 1) { $n = 1 }
            $keep = $script:TermCurCol
            for ($i = 0; $i -lt $n -and $script:TermLines.Count -gt 0; $i++) {
                $script:TermCurLine = $script:TermLines[$script:TermLines.Count - 1]
                $script:TermLines.RemoveAt($script:TermLines.Count - 1)
            }
            $script:TermCurCol = [Math]::Min($keep, $script:TermCurLine.Length)
            $script:TermDirty = $true
        }
        "B" {
            $n = 1
            [void][int]::TryParse($params, [ref]$n)
            if ($n -lt 1) { $n = 1 }
            for ($i = 0; $i -lt $n; $i++) { Term-CommitLine }
        }
        "C" {
            $n = 1
            [void][int]::TryParse($params, [ref]$n)
            if ($n -lt 1) { $n = 1 }
            $script:TermCurCol += $n
            $script:TermDirty = $true
        }
        "D" {
            $n = 1
            [void][int]::TryParse($params, [ref]$n)
            if ($n -lt 1) { $n = 1 }
            $script:TermCurCol = [Math]::Max(0, $script:TermCurCol - $n)
            $script:TermDirty = $true
        }
        "G" {
            $n = 1
            [void][int]::TryParse($params, [ref]$n)
            if ($n -lt 1) { $n = 1 }
            $script:TermCurCol = $n - 1
            $script:TermDirty = $true
        }
        "H" { $script:TermCurCol = 0; $script:TermDirty = $true }
        "f" { $script:TermCurCol = 0; $script:TermDirty = $true }
        "m" { }
        default { }
    }
}

function Flush-TermUtfBroken {
    foreach ($x in @($script:TermUtfAcc)) {
        Term-WriteChar ([char]$x)
    }
    $script:TermUtfAcc.Clear()
    $script:TermUtfNeed = 0
}

function Feed-TermPrintableByte([byte]$b) {
    if ($script:TermUtfNeed -gt 0) {
        if (($b -band 0xC0) -eq 0x80) {
            $script:TermUtfAcc.Add($b)
            $script:TermUtfNeed--
            if ($script:TermUtfNeed -eq 0) {
                $raw = $script:TermUtfAcc.ToArray()
                $script:TermUtfAcc.Clear()
                try {
                    $utf8 = New-Object System.Text.UTF8Encoding $false, $true
                    foreach ($c in $utf8.GetChars($raw)) { Term-WriteChar $c }
                } catch {
                    try {
                        foreach ($c in [System.Text.Encoding]::GetEncoding(936).GetChars($raw)) { Term-WriteChar $c }
                    } catch {
                        foreach ($x in $raw) { Term-WriteChar ([char]$x) }
                    }
                }
            }
            return
        }
        Flush-TermUtfBroken
    }
    if ($b -lt 128) {
        if ($b -ge 32) { Term-WriteChar ([char]$b) }
        return
    }
    if (($b -band 0xE0) -eq 0xC0) { $script:TermUtfNeed = 1; $script:TermUtfAcc.Add($b); return }
    if (($b -band 0xF0) -eq 0xE0) { $script:TermUtfNeed = 2; $script:TermUtfAcc.Add($b); return }
    if (($b -band 0xF8) -eq 0xF0) { $script:TermUtfNeed = 3; $script:TermUtfAcc.Add($b); return }
    Term-WriteChar ([char]$b)
}

function Feed-TermByte([byte]$b) {
    switch ($script:TermEsc) {
        1 {
            if ($b -eq 91) { $script:TermEsc = 2; $script:TermCsi = ""; return }
            if ($b -eq 93 -or $b -eq 80 -or $b -eq 88 -or $b -eq 94 -or $b -eq 95) {
                $script:TermEsc = 3
                $script:TermOscLen = 0
                return
            }
            if ($b -eq 55 -or $b -eq 56 -or $b -eq 77 -or $b -eq 99) {
                $script:TermEsc = 0
                return
            }
            $script:TermEsc = 0
            if ($b -ge 32) { Feed-TermPrintableByte $b }
            return
        }
        2 {
            if ($b -ge 64 -and $b -le 126) {
                Apply-TermCsi ($script:TermCsi + [char]$b)
                $script:TermEsc = 0
                $script:TermCsi = ""
            } elseif ($b -eq 10 -or $b -eq 13) {
                $script:TermEsc = 0
                $script:TermCsi = ""
            } else {
                $script:TermCsi += [char]$b
                if ($script:TermCsi.Length -gt 24) { $script:TermEsc = 0; $script:TermCsi = "" }
            }
            return
        }
        3 {
            $script:TermOscLen++
            if ($b -eq 7 -or $b -eq 10 -or $b -eq 13 -or $script:TermOscLen -gt 80) {
                $script:TermEsc = 0
                $script:TermOscLen = 0
                if ($b -eq 10) { Term-CommitLine }
                elseif ($b -eq 13) { $script:TermCurCol = 0; $script:TermDirty = $true }
            } elseif ($b -eq 27) {
                $script:TermEsc = 1
            }
            return
        }
    }
    if ($b -eq 27) { $script:TermEsc = 1; return }
    switch ($b) {
        10 { Term-CommitLine }
        13 { $script:TermCurCol = 0; $script:TermDirty = $true }
        8  { Term-Backspace }
        127 { Term-Backspace }
        7  { }
        9  {
            $sp = 8 - ($script:TermCurCol % 8)
            if ($sp -le 0) { $sp = 8 }
            for ($i = 0; $i -lt $sp; $i++) { Term-WriteChar ([char]32) }
        }
        12 { Term-CommitLine }
        default { Feed-TermPrintableByte $b }
    }
}

function Feed-TermBytes([byte[]]$buf) {
    if ($null -eq $buf -or $buf.Length -eq 0) { return }
    foreach ($b in $buf) { Feed-TermByte ([byte]$b) }
    Sync-TerminalDisplay
}

function Send-TermBytes([byte[]]$bytes) {
    if ($null -eq $script:TermPort -or -not $script:TermPort.IsOpen) { return }
    $script:TermSelecting = $false
    Snap-TermCaret
    Send-GecSerialBytes $script:TermPort $bytes
}

function Send-TermText([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return }
    Send-TermBytes ([System.Text.Encoding]::UTF8.GetBytes($text))
}

function Send-TerminalCommand([string]$cmd) {
    if (-not $script:TermConnected -or -not $script:TermPort) { return }
    $cmd = $cmd.Trim()
    if (-not $cmd) { return }
    Send-TermText ($cmd + "`r")
}

function Read-TerminalBytes {
    if ($null -eq $script:TermPort -or -not $script:TermPort.IsOpen) { return }
    try {
        $rounds = 0
        while ($rounds -lt 32) {
            $buf = Read-GecSerialRaw $script:TermPort
            if (-not $buf -or $buf.Length -le 0) { break }
            Feed-TermBytes $buf
            $rounds++
        }
    } catch {
        $lblTermStatus.Text = ("读取失败: " + $_.Exception.Message)
        Disconnect-Terminal
    }
}

$termPollTimer = New-Object System.Windows.Forms.Timer
$termPollTimer.Interval = 16
$termPollTimer.Add_Tick({ Read-TerminalBytes })

function Connect-Terminal {
    if ($script:TermConnected) { return }
    if ($script:Xfer -and -not $script:Xfer.finished) {
        [System.Windows.Forms.MessageBox]::Show("传输进行中，请等待完成或取消后再连接。", "串口", "OK", "Warning") | Out-Null
        return
    }
    $pb = Get-PortBaud
    if (-not $pb.Port) {
        [System.Windows.Forms.MessageBox]::Show("请选择串口。先关掉 MobaXterm 的串口标签。", "串口", "OK", "Warning") | Out-Null
        return
    }
    $script:TermState = [hashtable]@{
        logs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    }
    try {
        $script:TermPort = Open-GecSerialPort $pb.Port $pb.Baud
    } catch {
        [System.Windows.Forms.MessageBox]::Show(("打不开 " + $pb.Port + "：`n" + $_.Exception.Message + "`n`n1. 关掉 MobaXterm 的串口标签（不用退出软件）`n2. 不要同时开两个本工具窗口`n3. 拔掉 USB 转串口，等 3 秒再插上，然后点刷新"), "串口", "OK", "Error") | Out-Null
        $script:TermPort = $null
        return
    }
    Reset-TerminalEmulator
    $lblTermStatus.Text = ("正在连接 " + $pb.Port + " @ " + $pb.Baud + " ...")
    Start-Sleep -Milliseconds 200
    $ok = Restore-GecShell $script:TermPort $script:TermState
    if (-not $ok) {
        [System.Windows.Forms.MessageBox]::Show("板子无回音。请按复位键，并确认 UART0 接线。", "串口", "OK", "Warning") | Out-Null
        try { Close-GecSerialPort $script:TermPort } catch { try { $script:TermPort.Close() } catch {} }
        $script:TermPort = $null
        $lblTermStatus.Text = "连接失败。"
        return
    }
    while ($script:TermPort.BytesToRead -gt 0) {
        try { $null = $script:TermPort.ReadExisting() } catch { break }
    }
    Get-TermSize
    $null = Send-GecCmd $script:TermPort ("export TERM=linux; stty cols " + $script:TermCols + " rows " + $script:TermRows + " icanon echo isig icrnl -ixon erase ^H") 700
    while ($script:TermPort.BytesToRead -gt 0) {
        try { $null = $script:TermPort.ReadExisting() } catch { break }
    }
    Reset-TerminalEmulator
    $script:TermConnected = $true
    Send-TermBytes ([byte[]]@(13))
    Start-Sleep -Milliseconds 150
    Read-TerminalBytes
    $btnTermConnect.Enabled = $false
    $btnTermDisconnect.Enabled = $true
    $btnTermCtrlC.Enabled = $true
    $btnTermCtrlD.Enabled = $true
    $btnTermStop.Enabled = $true
    if ($btnStop) { $btnStop.Enabled = $true }
    Set-PortControlsEnabled $false
    $lblTermStatus.Text = ($pb.Port + " 已连接 — 和 MobaXterm 一样在黑框里输入，Enter 执行")
    $lblTermStatus.ForeColor = $script:Ui.Text
    Update-ConnLabel
    if ($script:CurrentPage -eq "term") {
        $termPollTimer.Start()
        $txtTerm.Focus()
    }
}

function Disconnect-Terminal {
    $termPollTimer.Stop()
    if ($script:TermPort -and $script:TermPort.IsOpen) {
        try { $null = Stop-BoardApp -LeavePollStopped } catch {}
    }
    if ($script:TermPort) {
        if (Get-Command Close-GecSerialPort -ErrorAction SilentlyContinue) {
            Close-GecSerialPort $script:TermPort
        } else {
            try { if ($script:TermPort.IsOpen) { $script:TermPort.Close() } } catch {}
        }
        $script:TermPort = $null
    }
    $script:TermConnected = $false
    $script:TermState = $null
    $script:LastLaunch = $null
    $btnTermConnect.Enabled = $true
    $btnTermDisconnect.Enabled = $false
    $btnTermCtrlC.Enabled = $false
    $btnTermCtrlD.Enabled = $false
    $btnTermStop.Enabled = $false
    if ($btnStop) { $btnStop.Enabled = $true }
    if (-not ($script:Xfer -and -not $script:Xfer.finished)) {
        $btnStart.Enabled = $true
        $btnRun.Enabled = $true
        Set-PortControlsEnabled $true
    }
    $lblTermStatus.Text = "未连接。点顶栏「连接」。"
    $lblTermStatus.ForeColor = $script:Ui.Muted
    Update-ConnLabel
}

function Show-TermNote([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $script:TermLines.Add($text)
    $script:TermDirty = $true
    Sync-TerminalDisplay
}

function Stop-LastLaunchApp {
    param([switch]$LeavePollStopped)
    return Stop-BoardApp -LeavePollStopped:$LeavePollStopped
}

function Stop-BoardApp {
    param(
        [switch]$LeavePollStopped,
        [switch]$UseLaunchBox
    )
    if (-not $script:TermPort -or -not $script:TermPort.IsOpen) { return $false }
    $names = New-Object System.Collections.Generic.List[string]
    $pids = @()
    if ($script:LastLaunch) {
        $b = [string]$script:LastLaunch.base
        if ($b -match '^[A-Za-z0-9._+-]+$') { [void]$names.Add($b) }
        $pids = @($script:LastLaunch.pids | Where-Object { "$_" -match '^\d+$' })
        if ((Get-Command Test-GecVehicleName -ErrorAction SilentlyContinue) -and (Test-GecVehicleName $b)) {
            foreach ($x in @("vehicle_course", "vehicle_nqt", "start_vehicle")) {
                if (-not $names.Contains($x)) { [void]$names.Add($x) }
            }
        }
    }
    if ($UseLaunchBox) {
        $hint = ""
        if ($txtLaunch -and $txtLaunch.Text) { $hint = $txtLaunch.Text.Trim() }
        if (-not $hint -and $txtRemote -and $txtRemote.Text) { $hint = $txtRemote.Text.Trim() }
        if ($hint) {
            $leaf = Split-Path -Leaf ($hint.Replace('\', '/'))
            if ($leaf -match '^[A-Za-z0-9._+-]+$' -and -not $names.Contains($leaf)) { [void]$names.Add($leaf) }
            if ((Get-Command Test-GecVehicleName -ErrorAction SilentlyContinue) -and (Test-GecVehicleName $leaf)) {
                foreach ($x in @("vehicle_course", "vehicle_nqt", "start_vehicle")) {
                    if (-not $names.Contains($x)) { [void]$names.Add($x) }
                }
            }
        }
    }
    if ($names.Count -eq 0 -and $pids.Count -eq 0) { return $false }
    $termPollTimer.Stop()
    try {
        try { Send-TermBytes ([byte[]]@(3)) } catch {}
        Start-Sleep -Milliseconds 80
        $kill = Get-GecKillCmd -Names @($names) -Pids $pids -BlankFb
        $out = Send-GecCmd $script:TermPort $kill 2200 "KILL_DONE"
        if ($out -notmatch "KILL_DONE") {
            $st = $script:TermState
            if (-not $st) {
                $st = @{ logs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) }
            }
            $null = Restore-GecShell $script:TermPort $st
            $out = Send-GecCmd $script:TermPort $kill 2200 "KILL_DONE"
        }
    } catch {
    } finally {
        if ($script:TermConnected -and -not $LeavePollStopped) { $termPollTimer.Start() }
    }
    $script:LastLaunch = $null
    return $true
}

function Invoke-StopBoardAppClick {
    if ($script:Xfer -and -not $script:Xfer.finished) {
        [System.Windows.Forms.MessageBox]::Show("传输进行中，请等待完成或取消后再停止。", "停止程序", "OK", "Warning") | Out-Null
        return
    }
    if (-not $script:TermConnected) {
        Connect-Terminal
        if (-not $script:TermConnected) { return }
    }
    $base = ""
    if ($script:LastLaunch) { $base = [string]$script:LastLaunch.base }
    if (Stop-BoardApp -UseLaunchBox) {
        $note = "已停止板上程序"
        if ($base) { $note = "已停止 " + $base }
        $lblTermStatus.Text = $note
        $lblTermStatus.ForeColor = $uiText
        Show-TermNote $note
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $note }
    } else {
        $lblTermStatus.Text = "没有要停的程序。先启动，或在路径里填板上文件名。"
        $lblTermStatus.ForeColor = $uiMuted
    }
}

function Restore-TermTty {
    if (-not $script:TermConnected -or -not $script:TermPort -or -not $script:TermPort.IsOpen) { return }
    Get-TermSize
    $null = Send-GecCmd $script:TermPort ("stty cols " + $script:TermCols + " rows " + $script:TermRows + " icanon echo isig icrnl -ixon erase ^H") 500
}

function Send-TermCtrlC {
    param([switch]$StopApp)
    if (-not $script:TermConnected -or -not $script:TermPort) { return }
    $base = ""
    if ($script:LastLaunch) { $base = [string]$script:LastLaunch.base }
    $hadApp = [bool]$script:LastLaunch
    Send-TermBytes ([byte[]]@(3))
    if ($hadApp) {
        Start-Sleep -Milliseconds 60
        if (Stop-BoardApp) {
            $note = "已停止 " + $base
            $lblTermStatus.Text = $note
            $lblTermStatus.ForeColor = $uiText
            Show-TermNote $note
        }
    }
}

function Send-TermCtrlD {
    if (-not $script:TermConnected -or -not $script:TermPort) { return }
    Send-TermBytes ([byte[]]@(4))
}

function Paste-ToTerminal {
    if (-not $script:TermConnected) { return }
    $clip = [System.Windows.Forms.Clipboard]::GetText()
    if ([string]::IsNullOrEmpty($clip)) { return }
    $clip = $clip -replace "`r`n", "`r" -replace "`n", "`r"
    Send-TermText $clip
}

$txtTerm.Add_KeyDown({
    if (-not $script:TermConnected) {
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) { $_.SuppressKeyPress = $true }
        return
    }
    $k = $_.KeyCode
    $ctrl = $_.Control
    if ($ctrl -and $k -eq [System.Windows.Forms.Keys]::C) {
        if ($txtTerm.SelectionLength -gt 0) {
            [System.Windows.Forms.Clipboard]::SetText($txtTerm.SelectedText)
        } else {
            Send-TermCtrlC
        }
        $_.SuppressKeyPress = $true
        $_.Handled = $true
        return
    }
    if ($ctrl -and $k -eq [System.Windows.Forms.Keys]::V) {
        Paste-ToTerminal
        $_.SuppressKeyPress = $true
        $_.Handled = $true
        return
    }
    $map = @{
        Return    = @(13)
        Enter     = @(13)
        Back      = @(8)
        Tab       = @(9)
        Up        = @(27, 91, 65)
        Down      = @(27, 91, 66)
        Right     = @(27, 91, 67)
        Left      = @(27, 91, 68)
        Home      = @(27, 91, 72)
        End       = @(27, 91, 70)
        Delete    = @(27, 91, 51, 126)
        Escape    = @(27)
        Prior     = @(27, 91, 53, 126)
        Next      = @(27, 91, 54, 126)
    }
    $name = [string]$k
    if ($ctrl) {
        $code = ([int]$k)
        if ($code -ge 65 -and $code -le 90) {
            Send-TermBytes ([byte[]]@($code - 64))
            $_.SuppressKeyPress = $true
            $_.Handled = $true
        }
        return
    }
    if ($map.ContainsKey($name)) {
        $seq = $map[$name]
        if ($null -ne $seq) { Send-TermBytes ([byte[]]$seq) }
        $_.SuppressKeyPress = $true
        $_.Handled = $true
    }
})

$txtTerm.Add_KeyPress({
    if (-not $script:TermConnected) {
        $_.Handled = $true
        return
    }
    $ch = $_.KeyChar
    if ($ch -eq [char]13 -or $ch -eq [char]10 -or $ch -eq [char]9 -or $ch -eq [char]8) {
        $_.Handled = $true
        return
    }
    if ([char]::IsControl($ch) -and $ch -ne [char]0) {
        $_.Handled = $true
        return
    }
    Send-TermText ([string]$ch)
    $_.Handled = $true
})

$txtTerm.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:TermSelecting = $true
    }
})

$txtTerm.Add_MouseUp({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $script:TermSelecting = $false
        if ($txtTerm.SelectionLength -gt 0) {
            [System.Windows.Forms.Clipboard]::SetText($txtTerm.SelectedText)
        } else {
            Paste-ToTerminal
        }
        return
    }
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:TermSelecting = $false
        if ($txtTerm.SelectionLength -le 0) { Snap-TermCaret }
    }
})

function Start-TermQuickLaunch {
    if ($script:Xfer -and -not $script:Xfer.finished) {
        [System.Windows.Forms.MessageBox]::Show("传输进行中，请等待完成后再启动。", "快捷启动", "OK", "Warning") | Out-Null
        return
    }
    $path = Resolve-GecLaunchPath $txtLaunch.Text
    if (-not $path) {
        [System.Windows.Forms.MessageBox]::Show("请输入板上路径，例如 /home/lamp，或只填 lamp。", "快捷启动", "OK", "Warning") | Out-Null
        $txtLaunch.Focus()
        return
    }
    if (-not (Test-GecRemotePath $path)) {
        [System.Windows.Forms.MessageBox]::Show("路径只允许 /home、/tmp、/usr/local/bin 下的文件，可带子目录。", "快捷启动", "OK", "Warning") | Out-Null
        $txtLaunch.Focus()
        return
    }
    $txtLaunch.Text = $path
    if ($txtRemote) { $txtRemote.Text = $path }
    if (-not $script:TermConnected) {
        $lblTermStatus.Text = "正在连接串口..."
        Connect-Terminal
        if (-not $script:TermConnected) { return }
    }
    $termPollTimer.Stop()
    $btnTermLaunch.Enabled = $false
    $lblTermStatus.Text = ("正在检测 " + $path + " ...")
    $lblTermStatus.ForeColor = $uiText
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $script:TermState) {
        $script:TermState = @{
            logs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        }
    }
    $script:TermState.remote = $path
    $script:TermState.message = ""
    try {
        Start-GecBoardApp $script:TermPort $script:TermState
        $base = [string]$script:TermState.launchBase
        if (-not $base) { $base = Split-Path -Leaf $path }
        $script:LastLaunch = @{
            base   = $base
            remote = [string]$script:TermState.remote
            pids   = @($script:TermState.launchPids)
        }
        $msg = [string]$script:TermState.message
        if (-not $msg) { $msg = "已启动 " + $base }
        $lblTermStatus.Text = $msg + "  ·  点「停止」或 Ctrl+C 结束"
        $lblTermStatus.ForeColor = $uiText
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $msg }
        Show-TermNote $msg
    } catch {
        $err = [string]$_.Exception.Message
        $lblTermStatus.Text = $err
        $lblTermStatus.ForeColor = $uiDanger
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("启动失败: " + $err) }
        [System.Windows.Forms.MessageBox]::Show($err, "快捷启动", "OK", "Warning") | Out-Null
    } finally {
        $btnTermLaunch.Enabled = $true
        if ($script:TermConnected) { $termPollTimer.Start() }
        $txtTerm.Focus()
    }
}

$btnTermConnect.Add_Click({ Connect-Terminal })
$btnTermDisconnect.Add_Click({ Disconnect-Terminal })
$btnTermClear.Add_Click({ Reset-TerminalEmulator; if ($script:TermConnected) { $txtTerm.Focus() } })
$btnTermCtrlC.Add_Click({ Send-TermCtrlC -StopApp; $txtTerm.Focus() })
$btnTermCtrlD.Add_Click({ Send-TermCtrlD; $txtTerm.Focus() })
$btnTermLaunch.Add_Click({ Start-TermQuickLaunch })
$btnTermStop.Add_Click({ Invoke-StopBoardAppClick })
if ($btnStop) { $btnStop.Add_Click({ Invoke-StopBoardAppClick }) }
$txtLaunch.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter -or $_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
        $_.SuppressKeyPress = $true
        $_.Handled = $true
        Start-TermQuickLaunch
    }
})
if ($txtRemote) {
    $txtRemote.Add_TextChanged({
        if ($txtLaunch -and -not $txtLaunch.Focused) { $txtLaunch.Text = $txtRemote.Text }
    })
}
