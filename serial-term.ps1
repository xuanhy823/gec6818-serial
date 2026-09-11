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
$script:TermUtfNeed = 0
$script:TermUtfAcc = New-Object System.Collections.Generic.List[byte]
$script:TermDirty = $false

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
$termGrid.RowCount = 2
$termGrid.BackColor = $uiBg
[void]$termGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$termGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 68)))
$tabTerm.Controls.Add($termGrid)

$termShell = New-Card $termGrid
$termShell.Dock = "Fill"
$termShell.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$termShell.Padding = New-Object System.Windows.Forms.Padding(10)
$termGrid.SetRow($termShell, 0)

$termQuick = New-Object System.Windows.Forms.FlowLayoutPanel
$termQuick.Dock = "Fill"
$termQuick.BackColor = $uiBg
$termQuick.WrapContents = $true
$termQuick.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$termGrid.Controls.Add($termQuick)
$termGrid.SetRow($termQuick, 1)

$txtTerm = New-Object System.Windows.Forms.TextBox
$txtTerm.Multiline = $true
$txtTerm.ScrollBars = "Both"
$txtTerm.WordWrap = $false
$txtTerm.Dock = "Fill"
$txtTerm.BackColor = $script:Ui.TermBg
$txtTerm.ForeColor = $script:Ui.TermFg
$txtTerm.Font = New-Object System.Drawing.Font("Consolas", 11)
$txtTerm.BorderStyle = "None"
$txtTerm.HideSelection = $false
$txtTerm.ShortcutsEnabled = $false
$txtTerm.MaxLength = 2000000
$txtTerm.AcceptsTab = $true
$txtTerm.AcceptsReturn = $true
$termShell.Controls.Add($txtTerm)

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

function Reset-TerminalEmulator {
    $script:TermLines = New-Object System.Collections.Generic.List[string]
    $script:TermCurLine = ""
    $script:TermCurCol = 0
    $script:TermEsc = 0
    $script:TermCsi = ""
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

function Sync-TerminalDisplay {
    if (-not $script:TermDirty) { return }
    $script:TermDirty = $false
    if ($txtTerm.SelectionLength -gt 0) { return }
    $shown = Get-TermDisplayText
    $old = $txtTerm.Text
    if ($shown -eq $old) { return }
    if ($shown.StartsWith($old) -and $old.Length -gt 0) {
        $txtTerm.AppendText($shown.Substring($old.Length))
    } else {
        $txtTerm.Text = $shown
    }
    $txtTerm.SelectionStart = $txtTerm.Text.Length
    $txtTerm.ScrollToCaret()
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
            if ($b -eq 93) { $script:TermEsc = 3; return }
            if ($b -eq 80 -or $b -eq 88 -or $b -eq 94 -or $b -eq 95) { $script:TermEsc = 3; return }
            $script:TermEsc = 0
            return
        }
        2 {
            if ($b -ge 64 -and $b -le 126) {
                Apply-TermCsi ($script:TermCsi + [char]$b)
                $script:TermEsc = 0
                $script:TermCsi = ""
            } else {
                $script:TermCsi += [char]$b
                if ($script:TermCsi.Length -gt 32) { $script:TermEsc = 0; $script:TermCsi = "" }
            }
            return
        }
        3 {
            if ($b -eq 7) { $script:TermEsc = 0 }
            elseif ($b -eq 27) { $script:TermEsc = 1 }
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
        12 { Reset-TerminalEmulator }
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
        $buf = Read-GecSerialRaw $script:TermPort
        if ($buf -and $buf.Length -gt 0) { Feed-TermBytes $buf }
    } catch {
        $lblTermStatus.Text = ("读取失败: " + $_.Exception.Message)
        Disconnect-Terminal
    }
}

$termPollTimer = New-Object System.Windows.Forms.Timer
$termPollTimer.Interval = 30
$termPollTimer.Add_Tick({ Read-TerminalBytes })

function Connect-Terminal {
    if ($script:TermConnected) { return }
    if ($script:Xfer -and -not $script:Xfer.finished) {
        [System.Windows.Forms.MessageBox]::Show("传输进行中，请等待完成或取消后再连接终端。", "串口终端", "OK", "Warning") | Out-Null
        return
    }
    $pb = Get-PortBaud
    if (-not $pb.Port) {
        [System.Windows.Forms.MessageBox]::Show("请选择串口。先关掉 MobaXterm 的串口标签。", "串口终端", "OK", "Warning") | Out-Null
        return
    }
    $script:TermState = [hashtable]@{
        logs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    }
    try {
        $script:TermPort = Open-GecSerialPort $pb.Port $pb.Baud
    } catch {
        [System.Windows.Forms.MessageBox]::Show(("打不开 " + $pb.Port + "：`n" + $_.Exception.Message + "`n`n请先关闭 MobaXterm 串口标签。"), "串口终端", "OK", "Error") | Out-Null
        $script:TermPort = $null
        return
    }
    Reset-TerminalEmulator
    $lblTermStatus.Text = ("正在连接 " + $pb.Port + " @ " + $pb.Baud + " ...")
    $ok = Restore-GecShell $script:TermPort $script:TermState
    if (-not $ok) {
        [System.Windows.Forms.MessageBox]::Show("板子无回音。请按复位键，并确认 UART0 接线。", "串口终端", "OK", "Warning") | Out-Null
        try { $script:TermPort.Close() } catch {}
        $script:TermPort = $null
        $lblTermStatus.Text = "连接失败。"
        return
    }
    while ($script:TermPort.BytesToRead -gt 0) {
        try { $null = $script:TermPort.ReadExisting() } catch { break }
    }
    Reset-TerminalEmulator
    $script:TermConnected = $true
    Send-TermBytes ([byte[]]@(13))
    Start-Sleep -Milliseconds 120
    Read-TerminalBytes
    $btnTermConnect.Enabled = $false
    $btnTermDisconnect.Enabled = $true
    $btnTermCtrlC.Enabled = $true
    $btnStart.Enabled = $false
    $btnRun.Enabled = $false
    Set-PortControlsEnabled $false
    $lblTermStatus.Text = ($pb.Port + " 已连接 — 在黑框里直接输入，Enter 执行")
    $lblTermStatus.ForeColor = [System.Drawing.Color]::FromArgb(61, 220, 151)
    Update-ConnLabel
    $termPollTimer.Start()
    $txtTerm.Focus()
}

function Disconnect-Terminal {
    $termPollTimer.Stop()
    if ($script:TermPort) {
        try { if ($script:TermPort.IsOpen) { $script:TermPort.Close() } } catch {}
        $script:TermPort = $null
    }
    $script:TermConnected = $false
    $script:TermState = $null
    $btnTermConnect.Enabled = $true
    $btnTermDisconnect.Enabled = $false
    $btnTermCtrlC.Enabled = $false
    if (-not ($script:Xfer -and -not $script:Xfer.finished)) {
        $btnStart.Enabled = $true
        $btnRun.Enabled = $true
        Set-PortControlsEnabled $true
    }
    $lblTermStatus.Text = "未连接。点黑色窗口输入，和 MobaXterm 一样。"
    $lblTermStatus.ForeColor = [System.Drawing.Color]::FromArgb(122, 132, 153)
    Update-ConnLabel
}

function Send-TermCtrlC {
    if (-not $script:TermConnected -or -not $script:TermPort) { return }
    Send-TermBytes ([byte[]]@(3))
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
    if ($ctrl -and $k -eq [System.Windows.Forms.Keys]::A) {
        $txtTerm.SelectAll()
        $_.SuppressKeyPress = $true
        $_.Handled = $true
        return
    }
    $map = @{
        Return    = @(13)
        Enter     = @(13)
        Back      = @(127)
        Tab       = @(9)
        Up        = @(27, 91, 65)
        Down      = @(27, 91, 66)
        Right     = @(27, 91, 67)
        Left      = @(27, 91, 68)
        Home      = @(27, 91, 72)
        End       = @(27, 91, 70)
        Delete    = @(27, 91, 51, 126)
        Escape    = @(27)
        Prior     = $null
        Next      = $null
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

$txtTerm.Add_MouseUp({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        if ($txtTerm.SelectionLength -gt 0) {
            [System.Windows.Forms.Clipboard]::SetText($txtTerm.SelectedText)
        } else {
            Paste-ToTerminal
        }
    }
})

$btnTermConnect.Add_Click({ Connect-Terminal })
$btnTermDisconnect.Add_Click({ Disconnect-Terminal })
$btnTermClear.Add_Click({ Reset-TerminalEmulator; if ($script:TermConnected) { $txtTerm.Focus() } })
$btnTermCtrlC.Add_Click({ Send-TermCtrlC; $txtTerm.Focus() })
