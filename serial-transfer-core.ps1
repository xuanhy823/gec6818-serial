# Transfer engine. Must run inside a PowerShell Runspace (not BackgroundWorker).
# $State is a synchronized hashtable.

function Write-XferLog($State, [string]$line) {
    if ($null -eq $State -or $null -eq $State.logs) { return }
    [void]$State.logs.Add(("{0}`t{1}" -f (Get-Date).ToString("HH:mm:ss"), $line))
}

function Get-GecCh340Port {
    $ch = Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "OK" -and $_.FriendlyName -match "CH340 \(COM(\d+)\)" } |
        ForEach-Object { if ($_.FriendlyName -match "COM(\d+)") { "COM$($Matches[1])" } }
    if ($ch) { return @($ch)[0] }
    $names = @([System.IO.Ports.SerialPort]::GetPortNames())
    if ($names.Count -eq 1) { return $names[0] }
    return $null
}

function Test-GecRemotePath([string]$path) {
    return [bool]($path -match '^/(home|tmp|usr/local/bin)/[A-Za-z0-9._+-]+$')
}

function New-GecSerialPort([string]$name, [int]$baud) {
    $p = New-Object System.IO.Ports.SerialPort($name, $baud, "None", 8, "One")
    $p.DtrEnable = $false
    $p.RtsEnable = $false
    $p.Handshake = [System.IO.Ports.Handshake]::None
    $p.ReadBufferSize = 65536
    $p.WriteBufferSize = 65536
    $p.ReadTimeout = 400
    $p.WriteTimeout = 8000
    $p.NewLine = "`r"
    # Latin-1 是字节 1:1，避免默认 ASCII 把 0x80–0xFF 变成 '?'
    $p.Encoding = [System.Text.Encoding]::GetEncoding(28591)
    return $p
}

function Read-GecSerialRaw($p) {
    $n = 0
    try { $n = $p.BytesToRead } catch { return , [byte[]]@() }
    if ($n -le 0) { return , [byte[]]@() }
    $buf = New-Object byte[] $n
    $got = 0
    try { $got = $p.Read($buf, 0, $n) } catch { return , [byte[]]@() }
    if ($got -le 0) { return , [byte[]]@() }
    if ($got -lt $n) { [Array]::Resize([ref]$buf, $got) }
    return , $buf
}

function Send-GecSerialBytes($p, [byte[]]$bytes) {
    if ($null -eq $p -or -not $p.IsOpen) { return }
    if ($null -eq $bytes -or $bytes.Length -le 0) { return }
    $p.Write($bytes, 0, $bytes.Length)
}

function Open-GecSerialPort([string]$name, [int]$baud, [int]$retries = 4) {
    $last = $null
    for ($i = 0; $i -lt $retries; $i++) {
        $p = New-GecSerialPort $name $baud
        try {
            $p.Open()
            return $p
        } catch {
            $last = $_
            try { if ($p.IsOpen) { $p.Close() } } catch {}
            try { $p.Dispose() } catch {}
            if ($i -lt ($retries - 1)) { Start-Sleep -Milliseconds 450 }
        }
    }
    throw ("open_fail " + $name + " close_mobaxterm " + $last.Exception.Message)
}

function Recv-GecSerial($p, [int]$ms) {
    $end = [datetime]::UtcNow.AddMilliseconds($ms)
    $sb = New-Object System.Text.StringBuilder
    while ([datetime]::UtcNow -lt $end) {
        Start-Sleep -Milliseconds 20
        try {
            if ($p.BytesToRead -gt 0) { [void]$sb.Append($p.ReadExisting()) }
        } catch {}
    }
    return $sb.ToString()
}

function Send-GecRawLine($p, [string]$c, [switch]$LfOnly) {
    if ($LfOnly) {
        $p.Write($c + "`n")
    } else {
        $p.Write($c + "`r")
    }
}

function Send-GecCmd($p, [string]$c, [int]$ms = 1000) {
    while ($p.BytesToRead -gt 0) {
        try { $null = $p.ReadExisting() } catch { break }
    }
    Send-GecRawLine $p $c
    return Recv-GecSerial $p $ms
}

function Restore-GecShell($p, $State) {
    for ($i = 0; $i -lt 5; $i++) {
        $p.Write([byte[]]@(3), 0, 1)
        Start-Sleep -Milliseconds 150
        # raw/-icrnl 时必须用 LF，cooked 时 CR 才稳，两种都发
        $p.Write("stty sane echo icanon isig icrnl -ixon`n")
        Start-Sleep -Milliseconds 200
        $p.Write("stty sane echo icanon isig icrnl -ixon`r")
        $null = Recv-GecSerial $p 350
        $h = Send-GecCmd $p "echo BOARD_ALIVE" 800
        Write-XferLog $State ("restore$i " + (($h -replace "[\r\n]+", " ").Trim()))
        if ($h -match "BOARD_ALIVE") { return $true }
    }
    return $false
}

function Assert-BoardAlive($p, $State) {
    if (-not (Restore-GecShell $p $State)) {
        throw "board_no_echo: 串口能打开但板子没有回音。若刚传失败，请按板上复位，并关掉 MobaXterm 串口标签后再试。"
    }
}

function Read-GecRemoteSize($p, [string]$path, $State) {
    $out = Send-GecCmd $p ("echo SZ_BEGIN; ls -l " + $path + "; echo SZ_END") 2200
    Write-XferLog $State (("size_ls " + $path + " " + ($out -replace "[\r\n]+", " ")).Trim())
    $chunk = $out
    if ($out -match "(?s)SZ_BEGIN(.*)SZ_END") { $chunk = $Matches[1] }
    if ($chunk -match "root\s+(\d+)\s+") {
        return [int64]$Matches[1]
    }
    $out2 = Send-GecCmd $p ("echo WC_BEGIN; wc -c " + $path + "; echo WC_END") 1800
    Write-XferLog $State (("size_wc " + ($out2 -replace "[\r\n]+", " ")).Trim())
    if ($out2 -match "(?s)WC_BEGIN.*?(\d{4,}).*?WC_END") {
        return [int64]$Matches[1]
    }
    return [int64](-1)
}

function Get-GecPidsFromText([string]$text) {
    $found = New-Object System.Collections.Generic.List[int]
    $chunk = $text
    if ($text -match "(?s)PID_BEGIN(.*)PID_END") { $chunk = $Matches[1] }
    foreach ($m in [regex]::Matches($chunk, '(?m)(?<![A-Za-z0-9_/])(\d{2,5})(?![A-Za-z0-9_])')) {
        $n = [int]$m.Groups[1].Value
        if (($n -ge 2) -and -not $found.Contains($n)) { $found.Add($n) }
    }
    return , @($found)
}

function Test-GecVehicleName([string]$base) {
    return ($base -match '^(vehicle_course|vehicle_nqt|start_vehicle|demo)$')
}

function Start-GecBoardApp($p, $State) {
    $remote = $State.remote
    if (-not (Test-GecRemotePath $remote)) {
        throw ("非法板上路径: " + $remote + "  只用 /home/名、/tmp/名 或 /usr/local/bin/名")
    }
    $base = Split-Path -Leaf $remote
    $null = Send-GecCmd $p "stty sane echo" 400
    $chk = Send-GecCmd $p ('test -f ' + $remote + '; echo EXIT:$?') 800
    Write-XferLog $State (("exists " + $remote + " " + ($chk -replace "[\r\n]+", " ")).Trim())
    if ($chk -notmatch "EXIT:0") {
        $null = Send-GecCmd $p "stty echo" 200
        throw ("板上没有这个文件: " + $remote + "  先传输再启动")
    }
    $null = Send-GecCmd $p "chmod +x $remote" 400
    $n = Read-GecRemoteSize $p $remote $State
    $isNqt = ($base -match "nqt")
    $isQt = (-not $isNqt) -and ( ($n -ge 80000) -or (Test-GecVehicleName $base) )
    if ($isQt -and ($n -ge 0) -and ($n -lt 80000)) {
        Write-XferLog $State ("qt copy too small (" + $n + "B), fallback /usr/local/bin/vehicle_course")
        $remote = "/usr/local/bin/vehicle_course"
        $base = "vehicle_course"
        $isNqt = $false
        $isQt = $true
    }

    $null = Send-GecCmd $p ("killall vehicle_course vehicle_nqt " + $base + " 2>/dev/null") 500
    $null = Send-GecCmd $p "rm -f /tmp/vc.log /tmp/nqt.log /tmp/run.log" 400
    $logFile = "/tmp/run.log"
    if ($isNqt) {
        Write-XferLog $State ("run_nqt " + $remote)
        $null = Send-GecCmd $p "$remote >/tmp/nqt.log 2>&1 &" 400
        $logFile = "/tmp/nqt.log"
    } elseif ($isQt) {
        $useStarter = ($remote -eq "/usr/local/bin/vehicle_course") -or ($remote -eq "/usr/local/bin/start_vehicle")
        $sv = ""
        if ($useStarter) {
            $sv = Send-GecCmd $p 'test -x /usr/local/bin/start_vehicle; echo SV:$?' 500
        }
        if ($useStarter -and ($sv -match "SV:0")) {
            Write-XferLog $State "run start_vehicle &"
            $null = Send-GecCmd $p "/usr/local/bin/start_vehicle >/tmp/start.out 2>&1 &" 500
            $base = "vehicle_course"
        } else {
            Write-XferLog $State ("run_qt " + $remote)
            $null = Send-GecCmd $p "export LD_LIBRARY_PATH=/usr/local/Qt-Embedded-5.7.0/lib:/lib:/usr/lib" 350
            $null = Send-GecCmd $p "export QT_PLUGIN_PATH=/usr/local/Qt-Embedded-5.7.0/plugins" 350
            $null = Send-GecCmd $p "export QT_QPA_PLATFORM=linuxfb" 350
            $null = Send-GecCmd $p "export QT_QPA_FONTDIR=/usr/share/fonts" 350
            $null = Send-GecCmd $p "unset QT_QPA_GENERIC_PLUGINS" 350
            $null = Send-GecCmd $p "unset QT_QPA_FB_HIDECURSOR" 350
            $null = Send-GecCmd $p "$remote >/tmp/vc.log 2>&1 &" 400
        }
        $logFile = "/tmp/vc.log"
    } else {
        Write-XferLog $State ("run_bg " + $remote)
        $null = Send-GecCmd $p "$remote >/tmp/run.log 2>&1 &" 400
    }
    Start-Sleep -Milliseconds 2000
    $out = Send-GecCmd $p ("echo PID_BEGIN; pidof " + $base + "; echo PID_END; cat " + $logFile + "; echo START_DONE") 2800
    $null = Send-GecCmd $p "stty echo" 200
    Write-XferLog $State (($out -replace "`r", "").Trim())
    $pids = Get-GecPidsFromText $out
    $logReady = $isQt -and ($out -match "step6 loop")
    if (($pids.Count -eq 0) -and -not $logReady) {
        throw ("进程没起来(" + $base + ")。请看开发板屏幕。日志: " + (($out -replace "[\r\n]+", " ").Trim()))
    }
    $pidTxt = "none"
    if ($pids.Count -gt 0) { $pidTxt = ($pids -join ",") }
    $State.message = "已启动 " + $remote + " 进程名=" + $base + " pid=" + $pidTxt + "，请看开发板屏幕"
    Write-XferLog $State $State.message
}

function Invoke-GecSerialStart($State) {
    $p = $null
    $State.t0 = Get-Date
    $State.total = 1L
    $State.done = 0L
    $State.error = $null
    $State.finished = $false
    try {
        $p = Open-GecSerialPort $State.port $State.baud
        Write-XferLog $State ("start " + $State.remote)
        Assert-BoardAlive $p $State
        Start-GecBoardApp $p $State
        $State.done = 1L
        $State.ok = $true
        if (-not $State.message) { $State.message = "已启动，请看开发板屏幕" }
        Write-XferLog $State "started, check LCD"
    } catch {
        $State.ok = $false
        $State.error = $_.Exception.Message
        Write-XferLog $State ("fail " + $_.Exception.Message)
    } finally {
        try { if ($p -and $p.IsOpen) { $p.Close() } } catch {}
        $State.finished = $true
    }
}

function Send-GecBinaryPayload($p, $State, [byte[]]$bytes, [int]$baud) {
    $total = [int64]$bytes.Length
    $off = 0L
    $buf = New-Object byte[] 256
    $paceMs = [Math]::Max(3, [int](256.0 * 10.0 * 1000.0 / [Math]::Max(9600, $baud)))
    while ($off -lt $total) {
        if ($State.cancel) { throw "cancelled" }
        $n = [int][Math]::Min(256, $total - $off)
        [Array]::Copy($bytes, $off, $buf, 0, $n)
        $p.Write($buf, 0, $n)
        $off += $n
        $State.done = $off
        Start-Sleep -Milliseconds $paceMs
        while ($p.BytesToRead -gt 0) {
            try { $null = $p.ReadExisting() } catch { break }
        }
    }
}

function Invoke-GecSerialTransfer($State) {
    $p = $null
    $t0 = Get-Date
    $State.t0 = $t0
    $State.error = $null
    $State.finished = $false
    try {
        $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $State.local))
        $total = [int64]$bytes.Length
        $State.total = $total
        $State.done = 0L
        Write-XferLog $State ("file_bytes " + $total)
        if (-not (Test-GecRemotePath $State.remote)) {
            throw ("非法板上路径: " + $State.remote + "  只用 /home/名、/tmp/名 或 /usr/local/bin/名")
        }
        $p = Open-GecSerialPort $State.port $State.baud
        Write-XferLog $State "port_open"
        Assert-BoardAlive $p $State
        $stage = "/tmp/.gec_xfer"
        $null = Send-GecCmd $p ("rm -f " + $stage) 400
        # 关 ICANON/ISIG：文件里的 0x03/0x04 否则会 SIGINT 或当 EOF，dd 必被截断
        $st = Send-GecCmd $p "stty -echo -icanon -isig -ixon -ixoff -icrnl -inlcr -onlcr" 700
        Write-XferLog $State (("stty " + ($st -replace "[\r\n]+", " ")).Trim())
        Send-GecRawLine $p ("busybox dd of=" + $stage + " bs=1 count=" + $total) -LfOnly
        Start-Sleep -Milliseconds 500
        $null = Recv-GecSerial $p 80
        Write-XferLog $State ("dd_to " + $stage + " count=" + $total)
        Send-GecBinaryPayload $p $State $bytes ([int]$State.baud)
        $tail = Recv-GecSerial $p 3500
        if ($tail) { Write-XferLog $State (("dd_tail " + ($tail -replace "[\r\n]+", " ")).Trim()) }
        if (-not (Restore-GecShell $p $State)) {
            throw "传完后串口没恢复，无法核对大小。关 MobaXterm 串口标签，按板上复位后再传。"
        }
        $got = Read-GecRemoteSize $p $stage $State
        if ($got -lt 0) {
            throw "传完后读不到 /tmp 临时文件大小。板子可能还在 raw 模式。按复位后再传一次。"
        }
        if ($got -ne $total) {
            throw ("size_mismatch local=" + $total + " board=" + $got + " 串口拷贝不完整，已拒绝覆盖目标文件。")
        }
        Write-XferLog $State ("size_ok " + $stage + " " + $total)
        $destDir = ($State.remote -replace '/[^/]+$', '')
        if ([string]::IsNullOrWhiteSpace($destDir)) { $destDir = "/" }
        $cp = Send-GecCmd $p ("mkdir -p " + $destDir + " && cp -f " + $stage + " " + $State.remote + " && chmod +x " + $State.remote + " && echo CP_OK") 2500
        Write-XferLog $State (($cp -replace "[\r\n]+", " ").Trim())
        if ($cp -notmatch "CP_OK") {
            throw "临时文件已完整，但拷到 " + $State.remote + " 失败。看板上 /home 空间。"
        }
        $final = Read-GecRemoteSize $p $State.remote $State
        if ($final -ne $total) {
            throw ("copy_mismatch dest=" + $final + " local=" + $total)
        }
        $ver = Send-GecCmd $p ("od -An -tx1 -N8 " + $State.remote + "; echo VERIFY_DONE") 2000
        Write-XferLog $State ($ver -replace "`r", "")
        if ($ver -match "7f\s*45\s*4c\s*46") {
            Write-XferLog $State "elf_ok 7f 45 4c 46"
        } else {
            Write-XferLog $State "elf_warn no_magic"
        }
        $null = Send-GecCmd $p ("rm -f " + $stage) 400
        if ($State.install) {
            $base = Split-Path -Leaf $State.remote
            $ins = Send-GecCmd $p ("cp -f " + $State.remote + " /usr/local/bin/" + $base + " && chmod +x /usr/local/bin/" + $base + " && echo INSTALL_OK") 2000
            Write-XferLog $State $ins
        }
        if ($State.run) {
            Start-GecBoardApp $p $State
        }
        $sec = [int]((Get-Date) - $t0).TotalSeconds
        Write-XferLog $State ("done " + $sec + "s " + $State.remote + " " + $total + "B")
        if (-not $State.message) { $State.message = "传输成功 " + $State.remote + " " + $total + "B / " + $sec + "s" }
        $State.ok = $true
    } catch {
        $State.ok = $false
        $State.error = $_.Exception.Message
        Write-XferLog $State ("fail " + $_.Exception.Message)
        try {
            if ($p -and $p.IsOpen) { $null = Restore-GecShell $p $State }
        } catch {}
    } finally {
        try { if ($p -and $p.IsOpen) { $p.Close() } } catch {}
        $State.finished = $true
    }
}
