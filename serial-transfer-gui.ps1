#Requires -Version 5.1
# GEC6818 串口工具。必须 STA。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot "serial-transfer-core.ps1")
. (Join-Path $PSScriptRoot "serial-ios.ps1")

function Get-Ch340Ports {
    $list = New-Object System.Collections.Generic.List[string]
    try {
        Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq "OK" -and $_.FriendlyName -match "CH340 \(COM(\d+)\)" } |
            ForEach-Object {
                if ($_.FriendlyName -match "COM(\d+)") { [void]$list.Add("COM$($Matches[1])") }
            }
    } catch {}
    foreach ($n in [System.IO.Ports.SerialPort]::GetPortNames()) {
        if (-not $list.Contains($n)) { [void]$list.Add($n) }
    }
    return , @($list)
}

function Test-GecGuiRemotePath([string]$path) {
    return Test-GecRemotePath $path
}

$form = New-Object IosChromeForm
$form.Text = "串口工具"
$form.Size = New-Object System.Drawing.Size(980, 740)
$form.MinimumSize = New-Object System.Drawing.Size(860, 620)
$form.StartPosition = "CenterScreen"
$form.BackColor = $script:Ui.Bg
$form.ForeColor = $script:Ui.Text
$form.Font = $script:FontUi
$form.AcceptButton = $null
$form.ShowInTaskbar = $true
$form.ShowIcon = $false
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.ControlBox = $true
$script:IosMainForm = $form

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = "Fill"
$root.ColumnCount = 1
$root.RowCount = 2
$root.BackColor = $script:Ui.Bg
$root.GrowStyle = "FixedSize"
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($root)

# --- 工具条 ---
$nav = New-Object System.Windows.Forms.Panel
$nav.Dock = "Fill"
$nav.BackColor = $script:Ui.Nav
$root.Controls.Add($nav, 0, 0)

$fldPort = New-Field $nav 16 11 168 36
$cmbPort = New-UiCombo $fldPort
$cmbPort.Dock = "Fill"
$cmbPort.DropDownStyle = "DropDown"

$btnRef = Add-Btn $nav "刷新" 192 11 68 36 $script:Ui.Seg $script:Ui.Text

$fldBaud = New-Field $nav 268 11 128 36
$cmbBaud = New-UiCombo $fldBaud
$cmbBaud.Dock = "Fill"
$cmbBaud.DropDownStyle = "DropDownList"
@(9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600) | ForEach-Object { [void]$cmbBaud.Items.Add("$_") }
$cmbBaud.SelectedItem = "115200"

$seg = New-Object IosCard
$seg.CornerRadius = 12
$seg.BackColor = $script:Ui.Seg
$seg.LineColor = $script:Ui.Seg
$seg.Location = New-Object System.Drawing.Point(560, 11)
$seg.Size = New-Object System.Drawing.Size(400, 36)
$nav.Controls.Add($seg)

$btnSegXfer = Add-Btn $seg "文件传输" 3 3 194 30 $script:Ui.Seg $script:Ui.Muted
$btnSegTerm = Add-Btn $seg "串口终端" 203 3 194 30 ([System.Drawing.Color]::White) $script:Ui.Text
$btnSegTerm.RainbowBorder = $true

$pillConn = New-Object IosCard
$pillConn.CornerRadius = 12
$pillConn.BackColor = $script:Ui.Seg
$pillConn.LineColor = $script:Ui.Seg
$pillConn.Size = New-Object System.Drawing.Size(132, 36)
$pillConn.Location = New-Object System.Drawing.Point(820, 11)
$nav.Controls.Add($pillConn)
$lblConn = New-Object System.Windows.Forms.Label
$lblConn.Text = "●  未连接"
$lblConn.Dock = "Fill"
$lblConn.TextAlign = "MiddleCenter"
$lblConn.Font = $script:FontUiSm
$lblConn.ForeColor = $script:Ui.Muted
$lblConn.BackColor = [System.Drawing.Color]::Transparent
$pillConn.Controls.Add($lblConn)

$navHair = New-Object System.Windows.Forms.Panel
$navHair.Height = 1
$navHair.Dock = "Bottom"
$navHair.BackColor = $script:Ui.Border
$nav.Controls.Add($navHair)

# --- 页面容器 ---
$pageHost = New-Object System.Windows.Forms.Panel
$pageHost.Dock = "Fill"
$pageHost.BackColor = $script:Ui.Bg
$pageHost.Padding = New-Object System.Windows.Forms.Padding(16, 8, 16, 14)
$root.Controls.Add($pageHost, 0, 1)

$pageXfer = New-Object System.Windows.Forms.Panel
$pageXfer.Dock = "Fill"
$pageXfer.BackColor = $script:Ui.Bg
$pageXfer.Visible = $false
$pageHost.Controls.Add($pageXfer)

$pageTerm = New-Object System.Windows.Forms.Panel
$pageTerm.Dock = "Fill"
$pageTerm.BackColor = $script:Ui.Bg
$pageTerm.Visible = $true
$pageHost.Controls.Add($pageTerm)

$tabTerm = New-Object System.Windows.Forms.Panel
$tabTerm.Dock = "Fill"
$tabTerm.BackColor = $script:Ui.Bg
$pageTerm.Controls.Add($tabTerm)

$termBar = New-Object System.Windows.Forms.Panel
$termBar.Dock = "Fill"
$termBar.BackColor = $script:Ui.Bg
$btnTermConnect = Add-Btn $termBar "连接" 4 4 88 36 $script:Ui.Ink ([System.Drawing.Color]::White)
$btnTermDisconnect = Add-Btn $termBar "断开" 100 4 72 36 $script:Ui.Danger ([System.Drawing.Color]::White)
$btnTermDisconnect.Enabled = $false
$btnTermClear = Add-Btn $termBar "清屏" 180 4 68 36 $script:Ui.Seg $script:Ui.Text
$btnTermCtrlC = Add-Btn $termBar "Ctrl+C" 256 4 76 36 $script:Ui.Seg $script:Ui.Text
$btnTermCtrlC.Enabled = $false
$lblTermStatus = New-Object System.Windows.Forms.Label
$lblTermStatus.Text = "先关 MobaXterm 串口标签，再点连接"
$lblTermStatus.Location = New-Object System.Drawing.Point(348, 12)
$lblTermStatus.Size = New-Object System.Drawing.Size(420, 22)
$lblTermStatus.ForeColor = $script:Ui.Muted
$lblTermStatus.BackColor = [System.Drawing.Color]::Transparent
$termBar.Controls.Add($lblTermStatus)

$script:CurrentPage = "term"

function Show-GecPage([string]$which) {
    if ($which -eq "term" -and $script:Xfer -and -not $script:Xfer.finished) {
        [System.Windows.Forms.MessageBox]::Show("传输进行中，请等待完成后再打开终端。", "串口终端", "OK", "Information") | Out-Null
        $which = "xfer"
    }
    $script:CurrentPage = $which
    $pageXfer.Visible = ($which -eq "xfer")
    $pageTerm.Visible = ($which -eq "term")
    if ($which -eq "term") {
        $btnSegTerm.BackColor = [System.Drawing.Color]::White
        $btnSegTerm.ForeColor = $script:Ui.Text
        $btnSegTerm.RainbowBorder = $true
        $btnSegXfer.BackColor = $script:Ui.Seg
        $btnSegXfer.ForeColor = $script:Ui.Muted
        $btnSegXfer.RainbowBorder = $false
        $form.AcceptButton = $null
        if ($script:TermConnected) { $txtTerm.Focus() }
    } else {
        $btnSegXfer.BackColor = [System.Drawing.Color]::White
        $btnSegXfer.ForeColor = $script:Ui.Text
        $btnSegXfer.RainbowBorder = $true
        $btnSegTerm.BackColor = $script:Ui.Seg
        $btnSegTerm.ForeColor = $script:Ui.Muted
        $btnSegTerm.RainbowBorder = $false
    }
    $btnSegXfer.Invalidate()
    $btnSegTerm.Invalidate()
}

$btnSegXfer.Add_Click({ Show-GecPage "xfer" })
$btnSegTerm.Add_Click({ Show-GecPage "term" })

# --- 传输页 ---
$xferGrid = New-Object System.Windows.Forms.TableLayoutPanel
$xferGrid.Dock = "Fill"
$xferGrid.ColumnCount = 1
$xferGrid.RowCount = 5
$xferGrid.BackColor = $script:Ui.Bg
[void]$xferGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$xferGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$xferGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$xferGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$xferGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$pageXfer.Controls.Add($xferGrid)

$cardFile = New-Card $xferGrid
$cardFile.Height = 88
$cardFile.Dock = "Top"
$cardFile.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$xferGrid.SetRow($cardFile, 0)
Add-L $cardFile "电脑上的文件" 16 10 240 | Out-Null
$fldLocal = New-Field $cardFile 16 34 680 36
$txtLocal = Add-Box $fldLocal 0 0 100
$txtLocal.Dock = "Fill"
$btnBrowse = Add-Btn $cardFile "浏览" 708 34 88 36 $script:Ui.Ink ([System.Drawing.Color]::White)

$shareNqt = "C:\Users\32533\gec6818_share\vehicle_nqt"
$shareQt = "C:\Users\32533\gec6818_share\vehicle_course"
if (Test-Path $shareNqt) { $txtLocal.Text = $shareNqt }
elseif (Test-Path $shareQt) { $txtLocal.Text = $shareQt }

$cardDest = New-Card $xferGrid
$cardDest.Height = 88
$cardDest.Dock = "Top"
$cardDest.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$xferGrid.SetRow($cardDest, 1)
Add-L $cardDest "板上目标（/home、/tmp 或 /usr/local/bin）" 16 10 420 | Out-Null
$fldRemote = New-Field $cardDest 16 34 780 36
$txtRemote = Add-Box $fldRemote 0 0 100
$txtRemote.Dock = "Fill"
if (Test-Path $shareNqt) { $txtRemote.Text = "/home/vehicle_nqt" } else { $txtRemote.Text = "/home/vehicle_course" }

$cardAct = New-Card $xferGrid
$cardAct.Height = 100
$cardAct.Dock = "Top"
$cardAct.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$xferGrid.SetRow($cardAct, 2)

$chkInstall = New-Object System.Windows.Forms.CheckBox
$chkInstall.Text = "再拷到 /usr/local/bin"
$chkInstall.Location = New-Object System.Drawing.Point(16, 12)
$chkInstall.Size = New-Object System.Drawing.Size(220, 24)
$chkInstall.ForeColor = $script:Ui.Text
$chkInstall.BackColor = [System.Drawing.Color]::Transparent
$chkInstall.Font = $script:FontUi
$cardAct.Controls.Add($chkInstall)

$chkRun = New-Object System.Windows.Forms.CheckBox
$chkRun.Text = "传完自动启动"
$chkRun.Location = New-Object System.Drawing.Point(250, 12)
$chkRun.Size = New-Object System.Drawing.Size(160, 24)
$chkRun.ForeColor = $script:Ui.Text
$chkRun.BackColor = [System.Drawing.Color]::Transparent
$chkRun.Font = $script:FontUi
$cardAct.Controls.Add($chkRun)

$btnStart = Add-Btn $cardAct "开始传输" 16 48 132 38 $script:Ui.Ink ([System.Drawing.Color]::White)
$btnRun = Add-Btn $cardAct "启动程序" 156 48 124 38 $script:Ui.Ink ([System.Drawing.Color]::White)
$btnCancel = Add-Btn $cardAct "取消" 288 48 80 38 $script:Ui.Seg $script:Ui.Text
$btnCancel.Enabled = $false

$cardProg = New-Card $xferGrid
$cardProg.Height = 68
$cardProg.Dock = "Top"
$cardProg.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$xferGrid.SetRow($cardProg, 3)
$lblProg = New-Object System.Windows.Forms.Label
$lblProg.Text = "等待开始"
$lblProg.Location = New-Object System.Drawing.Point(16, 10)
$lblProg.Size = New-Object System.Drawing.Size(760, 20)
$lblProg.ForeColor = $script:Ui.Text
$lblProg.BackColor = [System.Drawing.Color]::Transparent
$cardProg.Controls.Add($lblProg)
$barPct = New-Object IosProgress
$barPct.Progress = 0
$barPct.FillColor = $script:Ui.Ink
$barPct.Location = New-Object System.Drawing.Point(16, 38)
$barPct.Size = New-Object System.Drawing.Size(760, 8)
$cardProg.Controls.Add($barPct)

$cardLog = New-Card $xferGrid
$cardLog.Dock = "Fill"
$cardLog.Margin = New-Object System.Windows.Forms.Padding(0)
$xferGrid.SetRow($cardLog, 4)
$lblLog = Add-L $cardLog "日志" 16 8 120
$lblLog.Dock = "Top"
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Dock = "Fill"
$txtLog.BackColor = $script:Ui.Input
$txtLog.ForeColor = $script:Ui.Text
$txtLog.Font = $script:FontMono
$txtLog.BorderStyle = "None"
$cardLog.Controls.Add($txtLog)
$txtLog.BringToFront()

. (Join-Path $PSScriptRoot "serial-term.ps1")

function Write-Log([string]$line) {
    $msg = "[{0}] {1}`r`n" -f (Get-Date -Format "HH:mm:ss"), $line
    $txtLog.AppendText($msg)
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
}

function Update-Progress([int64]$done, [int64]$total, $t0) {
    if ($total -le 0) { return }
    if ($done -gt $total) { $done = $total }
    $pct = [int](($done * 1000) / $total)
    $elapsed = [math]::Max(0.25, ((Get-Date) - $t0).TotalSeconds)
    $speed = $done / $elapsed
    $eta = if ($speed -gt 1) { ($total - $done) / $speed } else { 0 }
    $lblProg.Text = ("{0:N0} / {1:N0}    {2:0.0}%    {3:0.0} KB/s    剩余 {4:0} 秒" -f `
        $done, $total, (100.0 * $done / $total), ($speed / 1024.0), $eta)
    $barPct.Progress = [Math]::Min(1.0, [Math]::Max(0.0, $pct / 1000.0))
}

function Refresh-Ports {
    $keep = $cmbPort.Text
    $cmbPort.Items.Clear()
    foreach ($n in (Get-Ch340Ports)) { [void]$cmbPort.Items.Add($n) }
    if ($keep -and $cmbPort.Items.Contains($keep)) { $cmbPort.SelectedItem = $keep }
    elseif ($cmbPort.Items.Count -gt 0) { $cmbPort.SelectedIndex = 0 }
    else { Write-Log "未发现串口，插上 CH340 后点刷新。" }
}

function Get-PortBaud {
    $portName = [string]$cmbPort.SelectedItem
    if (-not $portName) { $portName = $cmbPort.Text.Trim() }
    $baud = 115200
    $baudText = [string]$cmbBaud.SelectedItem
    if (-not $baudText) { $baudText = $cmbBaud.Text }
    [void][int]::TryParse($baudText, [ref]$baud)
    if ($baud -le 0) { $baud = 115200 }
    return @{ Port = $portName; Baud = $baud }
}

function Set-PortControlsEnabled([bool]$enabled) {
    $cmbPort.Enabled = $enabled
    $cmbBaud.Enabled = $enabled
    $btnRef.Enabled = $enabled
}

function Update-ConnLabel {
    if ($script:TermConnected) {
        $lblConn.Text = "●  " + $script:TermPort.PortName
        $lblConn.ForeColor = [System.Drawing.Color]::White
        $pillConn.BackColor = $script:Ui.Ink
        $pillConn.LineColor = $script:Ui.Ink
    } elseif ($script:Xfer -and -not $script:Xfer.finished) {
        $lblConn.Text = "●  传输中"
        $lblConn.ForeColor = [System.Drawing.Color]::White
        $pillConn.BackColor = $script:Ui.Ink
        $pillConn.LineColor = $script:Ui.Ink
    } else {
        $lblConn.Text = "●  未连接"
        $lblConn.ForeColor = $script:Ui.Muted
        $pillConn.BackColor = $script:Ui.Seg
        $pillConn.LineColor = $script:Ui.Seg
    }
    $pillConn.Invalidate()
}

function Layout-Nav {
    $w = $nav.ClientSize.Width
    $pillConn.Left = [Math]::Max(420, $w - 148)
    $seg.Width = [Math]::Min(320, [Math]::Max(220, $w - 568))
    $seg.Left = [Math]::Max(408, $pillConn.Left - $seg.Width - 12)
    $half = [int](($seg.Width - 10) / 2)
    $btnSegXfer.Width = $half
    $btnSegTerm.Left = 4 + $half
    $btnSegTerm.Width = $half
    $lblTermStatus.Width = [Math]::Max(160, $termBar.ClientSize.Width - 360)
}

$nav.Add_Resize({ Layout-Nav })
$form.Add_Shown({
    Layout-Nav
    $fldLocal.Width = [Math]::Max(200, $cardFile.ClientSize.Width - 124)
    $btnBrowse.Left = $fldLocal.Left + $fldLocal.Width + 8
    $fldRemote.Width = [Math]::Max(200, $cardDest.ClientSize.Width - 32)
    $lblProg.Width = [Math]::Max(200, $cardProg.ClientSize.Width - 32)
    $barPct.Width = $lblProg.Width
    Show-GecPage "term"
})

$cardFile.Add_Resize({
    $fldLocal.Width = [Math]::Max(200, $cardFile.ClientSize.Width - 124)
    $btnBrowse.Left = $fldLocal.Left + $fldLocal.Width + 8
})
$cardDest.Add_Resize({
    $fldRemote.Width = [Math]::Max(200, $cardDest.ClientSize.Width - 32)
})
$cardProg.Add_Resize({
    $lblProg.Width = [Math]::Max(200, $cardProg.ClientSize.Width - 32)
    $barPct.Width = $lblProg.Width
})

$script:CorePath = Join-Path $PSScriptRoot "serial-transfer-core.ps1"
$script:Xfer = $null
$script:Ps = $null
$script:Rs = $null
$script:Async = $null
$script:LogSeen = 0

function New-XferState {
    $logs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    return [hashtable]::Synchronized(@{
        local = ""; remote = ""; port = ""; baud = 115200
        install = $false; run = $false; cancel = $false
        done = 0L; total = 1L; t0 = (Get-Date)
        logs = $logs; error = $null; finished = $false; ok = $false; message = ""
    })
}

function Stop-XferUi {
    $btnStart.Enabled = -not $script:TermConnected
    $btnRun.Enabled = -not $script:TermConnected
    $btnCancel.Enabled = $false
    if (-not $script:TermConnected) { Set-PortControlsEnabled $true }
    Update-ConnLabel
}

function Drain-XferUi {
    if ($null -eq $script:Xfer) { return }
    $st = $script:Xfer
    if ($st.t0 -and $st.total -gt 0) { Update-Progress ([int64]$st.done) ([int64]$st.total) $st.t0 }
    while ($script:LogSeen -lt $st.logs.Count) {
        $raw = [string]$st.logs[$script:LogSeen]
        $script:LogSeen++
        if ($raw -match "^\d{2}:\d{2}:\d{2}`t") {
            $txtLog.AppendText(("[{0}] {1}`r`n" -f $raw.Substring(0, 8), $raw.Substring(9)))
        } else {
            Write-Log $raw
        }
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
    if ($st.finished) {
        $timer.Stop()
        try {
            if ($script:Async -and $script:Ps) { $script:Ps.EndInvoke($script:Async) | Out-Null }
        } catch {
            Write-Log ("运行空间: " + $_.Exception.Message)
        }
        if ($script:Ps) { $script:Ps.Dispose(); $script:Ps = $null }
        if ($script:Rs) { $script:Rs.Dispose(); $script:Rs = $null }
        $script:Async = $null
        if ($st.ok) {
            if ($st.message) { Write-Log ([string]$st.message) } else { Write-Log "传输成功。" }
            $lblProg.Text = "成功"
        } elseif ($st.error) {
            Write-Log ("失败: " + $st.error)
            $lblProg.Text = "失败"
        }
        Stop-XferUi
        $script:Xfer = $null
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({ Drain-XferUi })

function Start-CoreJob([string]$entry, $local, $remote, $portName, $baud, $install, $run) {
    $script:Xfer = New-XferState
    $script:Xfer.local = $local
    $script:Xfer.remote = $remote
    $script:Xfer.port = $portName
    $script:Xfer.baud = $baud
    $script:Xfer.install = $install
    $script:Xfer.run = $run
    $script:LogSeen = 0
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable("State", $script:Xfer)
    $rs.SessionStateProxy.SetVariable("CorePath", $script:CorePath)
    $rs.SessionStateProxy.SetVariable("Entry", $entry)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        . $CorePath
        if ($Entry -eq "start") { Invoke-GecSerialStart $State }
        else { Invoke-GecSerialTransfer $State }
    })
    $script:Rs = $rs
    $script:Ps = $ps
    $script:Async = $ps.BeginInvoke()
    $timer.Start()
    Update-ConnLabel
}

$btnRef.Add_Click({ Refresh-Ports })
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "选择要传到板子的文件"
    $share = "C:\Users\32533\gec6818_share"
    if (Test-Path $share) { $dlg.InitialDirectory = $share }
    $dlg.Filter = "全部|*.*"
    if ($dlg.ShowDialog() -eq "OK") {
        $txtLocal.Text = $dlg.FileName
        $txtRemote.Text = "/home/" + [IO.Path]::GetFileName($dlg.FileName)
    }
})
$txtLocal.Add_TextChanged({
    $name = [IO.Path]::GetFileName($txtLocal.Text.Trim())
    if ($name) { $txtRemote.Text = "/home/" + $name }
})

$btnStart.Add_Click({
    if ($script:TermConnected) {
        [System.Windows.Forms.MessageBox]::Show("终端已连接，请先断开终端再传输。", "串口传输", "OK", "Warning") | Out-Null
        return
    }
    if ($script:Xfer -and -not $script:Xfer.finished) { return }
    $local = $txtLocal.Text.Trim()
    $remote = $txtRemote.Text.Trim()
    $pb = Get-PortBaud
    if (-not (Test-Path -LiteralPath $local)) {
        [System.Windows.Forms.MessageBox]::Show("找不到本地文件。", "串口传输", "OK", "Warning") | Out-Null
        return
    }
    if (-not $pb.Port) {
        [System.Windows.Forms.MessageBox]::Show("请选择串口。先关掉 MobaXterm 的串口标签。", "串口传输", "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-GecGuiRemotePath $remote)) {
        [System.Windows.Forms.MessageBox]::Show("板上路径只允许 /home/名、/tmp/名 或 /usr/local/bin/名（字母数字._+-）。", "串口传输", "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $script:CorePath)) {
        [System.Windows.Forms.MessageBox]::Show("缺少 serial-transfer-core.ps1", "串口传输", "OK", "Error") | Out-Null
        return
    }
    $btnStart.Enabled = $false
    $btnRun.Enabled = $false
    $btnCancel.Enabled = $true
    $btnTermConnect.Enabled = $false
    Set-PortControlsEnabled $false
    $barPct.Progress = 0
    $lblProg.Text = "连接中..."
    Write-Log ("开始 " + $pb.Port + " " + $pb.Baud + " -> " + $remote)
    Show-GecPage "xfer"
    Start-CoreJob "xfer" $local $remote $pb.Port $pb.Baud ([bool]$chkInstall.Checked) ([bool]$chkRun.Checked)
})

$btnRun.Add_Click({
    if ($script:TermConnected) {
        [System.Windows.Forms.MessageBox]::Show("终端已连接，请先断开终端再启动程序。", "启动", "OK", "Warning") | Out-Null
        return
    }
    if ($script:Xfer -and -not $script:Xfer.finished) { return }
    $remote = $txtRemote.Text.Trim()
    $pb = Get-PortBaud
    if (-not $pb.Port) {
        [System.Windows.Forms.MessageBox]::Show("请选择串口。先关掉 MobaXterm 的串口标签。", "启动", "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-GecGuiRemotePath $remote)) {
        [System.Windows.Forms.MessageBox]::Show("请填写合法板上路径，例如 /home/vehicle_course", "启动", "OK", "Warning") | Out-Null
        return
    }
    $btnStart.Enabled = $false
    $btnRun.Enabled = $false
    $btnCancel.Enabled = $true
    $btnTermConnect.Enabled = $false
    Set-PortControlsEnabled $false
    $lblProg.Text = "正在启动..."
    Write-Log ("启动 " + $pb.Port + " -> " + $remote)
    Show-GecPage "xfer"
    Start-CoreJob "start" $txtLocal.Text.Trim() $remote $pb.Port $pb.Baud $false $true
})

$btnCancel.Add_Click({
    if ($script:Xfer -and -not $script:Xfer.finished) {
        $script:Xfer.cancel = $true
        Write-Log "正在取消..."
    }
})

$form.Add_FormClosing({
    if ($script:Xfer) { $script:Xfer.cancel = $true }
    Disconnect-Terminal
    $timer.Stop()
})

Refresh-Ports
Write-Log "准备就绪。当前在「串口终端」页，点连接后即可输入命令。"
[System.Windows.Forms.Application]::Run($form)
