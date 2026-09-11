# Transfer engine. Must run inside a PowerShell Runspace (not BackgroundWorker).
# $State is a synchronized hashtable.
# WCH CH340 4.x 会让 .NET SerialPort.Open 报「设备没有发挥作用」，改走 CreateFile。
if (-not ([System.Management.Automation.PSTypeName]"GecNativePort").Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct GecDcb {
    public uint DCBlength;
    public uint BaudRate;
    public uint Flags;
    public ushort wReserved;
    public ushort XonLim;
    public ushort XoffLim;
    public byte ByteSize;
    public byte Parity;
    public byte StopBits;
    public byte XonChar;
    public byte XoffChar;
    public byte ErrorChar;
    public byte EofChar;
    public byte EvtChar;
    public ushort wReserved1;
}

[StructLayout(LayoutKind.Sequential)]
public struct GecTimeouts {
    public uint ReadIntervalTimeout;
    public uint ReadTotalTimeoutMultiplier;
    public uint ReadTotalTimeoutConstant;
    public uint WriteTotalTimeoutMultiplier;
    public uint WriteTotalTimeoutConstant;
}

[StructLayout(LayoutKind.Sequential)]
public struct GecComstat {
    public uint Flags;
    public uint cbInQue;
    public uint cbOutQue;
}

public class GecNativePort : IDisposable {
    public string PortName;
    public int BaudRate;
    IntPtr _h = new IntPtr(-1);
    static readonly IntPtr Invalid = new IntPtr(-1);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    static extern IntPtr CreateFile(string name, uint acc, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(IntPtr h, byte[] buf, int n, out int got, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(IntPtr h, byte[] buf, int n, out int wrote, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetCommState(IntPtr h, ref GecDcb dcb);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetCommState(IntPtr h, ref GecDcb dcb);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetCommTimeouts(IntPtr h, ref GecTimeouts t);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ClearCommError(IntPtr h, out uint err, out GecComstat st);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetupComm(IntPtr h, uint inq, uint outq);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool PurgeComm(IntPtr h, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FlushFileBuffers(IntPtr h);

    public GecNativePort(string name, int baud) {
        PortName = name;
        BaudRate = baud;
    }
    public bool IsOpen { get { return _h != Invalid && _h != IntPtr.Zero; } }

    public void Open() {
        if (IsOpen) return;
        _h = CreateFile(@"\\.\" + PortName, 0xC0000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (_h == Invalid) {
            throw new System.IO.IOException("CreateFile " + PortName + " win32=" + Marshal.GetLastWin32Error());
        }
        SetupComm(_h, 65536, 65536);
        GecTimeouts to = new GecTimeouts();
        to.ReadIntervalTimeout = 0xFFFFFFFF;
        to.WriteTotalTimeoutConstant = 8000;
        SetCommTimeouts(_h, ref to);
        GecDcb dcb = new GecDcb();
        dcb.DCBlength = (uint)Marshal.SizeOf(typeof(GecDcb));
        if (GetCommState(_h, ref dcb)) {
            dcb.BaudRate = (uint)BaudRate;
            dcb.ByteSize = 8;
            dcb.Parity = 0;
            dcb.StopBits = 0;
            uint flags = dcb.Flags;
            flags |= 1;
            flags &= unchecked((uint)~0x333E);
            dcb.Flags = flags;
            SetCommState(_h, ref dcb);
        }
        PurgeComm(_h, 0x000F);
    }

    public int BytesToRead {
        get {
            if (!IsOpen) return 0;
            uint err;
            GecComstat st;
            if (!ClearCommError(_h, out err, out st)) return 0;
            return (int)st.cbInQue;
        }
    }

    public string ReadExisting() {
        int n = BytesToRead;
        if (n <= 0) return "";
        byte[] buf = new byte[n];
        int got = Read(buf, 0, n);
        if (got <= 0) return "";
        return Encoding.GetEncoding(28591).GetString(buf, 0, got);
    }

    public int Read(byte[] buf, int off, int count) {
        if (!IsOpen || buf == null || count <= 0) return 0;
        byte[] tmp = (off == 0) ? buf : new byte[count];
        int got;
        if (!ReadFile(_h, tmp, (off == 0) ? Math.Min(count, buf.Length) : count, out got, IntPtr.Zero)) return 0;
        if (off != 0 && got > 0) Array.Copy(tmp, 0, buf, off, got);
        return got;
    }

    public void Write(string s) {
        if (string.IsNullOrEmpty(s)) return;
        byte[] b = Encoding.GetEncoding(28591).GetBytes(s);
        Write(b, 0, b.Length);
    }

    public void Write(byte[] bytes, int off, int count) {
        if (!IsOpen || bytes == null || count <= 0) return;
        byte[] tmp = bytes;
        if (off != 0 || count != bytes.Length) {
            tmp = new byte[count];
            Array.Copy(bytes, off, tmp, 0, count);
        }
        int wrote;
        WriteFile(_h, tmp, count, out wrote, IntPtr.Zero);
    }

    public void Close() { Dispose(); }
    public void Dispose() {
        if (!IsOpen) return;
        try { FlushFileBuffers(_h); } catch {}
        try { PurgeComm(_h, 0x000F); } catch {}
        CloseHandle(_h);
        _h = Invalid;
    }
}
"@
}

function New-GecSerialPort([string]$name, [int]$baud) {
    $n = ([string]$name).Trim()
    if ($n -match '^\\\\\.\\(COM\d+)$') { $n = $Matches[1] }
    return New-Object GecNativePort($n, $baud)
}

function Format-GecLogText([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return "" }
    $s = [string]$text
    $s = $s -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''
    $s = $s -replace '\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', ''
    $s = $s -replace '\x1b.', ''
    $s = $s -replace '[\x00-\x08\x0b\x0c\x0e-\x1f]', ''
    $s = ($s -replace '[\r\n]+', ' ')
    return (($s -replace '[ \t]+', ' ').Trim())
}

function Write-XferLog($State, [string]$line) {
    if ($null -eq $State -or $null -eq $State.logs) { return }
    $clean = Format-GecLogText $line
    if ([string]::IsNullOrWhiteSpace($clean)) { return }
    [void]$State.logs.Add(("{0}`t{1}" -f (Get-Date).ToString("HH:mm:ss"), $clean))
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

function Get-GecSessionPort($State) {
    if ($State.sharedPort -and $State.sharedPort.IsOpen) {
        Write-XferLog $State "port_reuse"
        return $State.sharedPort
    }
    $p = Open-GecSerialPort $State.port $State.baud
    Write-XferLog $State "port_open"
    return $p
}

function Release-GecSessionPort($p, $State) {
    if ($State.keepOpen) { return }
    Close-GecSerialPort $p
}

function Close-GecSerialPort($p) {
    if ($null -eq $p) { return }
    try {
        if ($p.IsOpen) { $p.Close() }
    } catch {
        try { $p.Dispose() } catch {}
    }
    Start-Sleep -Milliseconds 300
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
    $msg = ""
    if ($last) { $msg = [string]$last.Exception.Message }
    if ($msg -match "没有发挥作用|not functioning|被拒绝|denied|Access") {
        throw ("open_fail " + $name + " 口打不开。请关掉 MobaXterm 串口标签和本工具的重复窗口，拔掉 USB 转串口等 3 秒再插上。 " + $msg)
    }
    throw ("open_fail " + $name + " close_mobaxterm " + $msg)
}

function Recv-GecSerial($p, [int]$ms, [string]$Until = $null) {
    $end = [datetime]::UtcNow.AddMilliseconds($ms)
    $sb = New-Object System.Text.StringBuilder
    $lastData = [datetime]::UtcNow
    $got = $false
    while ([datetime]::UtcNow -lt $end) {
        $chunk = ""
        try {
            if ($p.BytesToRead -gt 0) { $chunk = $p.ReadExisting() }
        } catch {}
        if ($chunk) {
            [void]$sb.Append($chunk)
            $lastData = [datetime]::UtcNow
            $got = $true
            if ($Until -and $sb.ToString() -match $Until) {
                Start-Sleep -Milliseconds 25
                try { if ($p.BytesToRead -gt 0) { [void]$sb.Append($p.ReadExisting()) } } catch {}
                break
            }
        } elseif ($got -and (([datetime]::UtcNow - $lastData).TotalMilliseconds -ge 70)) {
            break
        }
        Start-Sleep -Milliseconds 10
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

function Send-GecCmd($p, [string]$c, [int]$ms = 1000, [string]$Until = $null) {
    while ($p.BytesToRead -gt 0) {
        try { $null = $p.ReadExisting() } catch { break }
    }
    Send-GecRawLine $p $c
    return Recv-GecSerial $p $ms $Until
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
        $h = Send-GecCmd $p "echo BOARD_ALIVE" 800 "BOARD_ALIVE"
        if ($h -match "BOARD_ALIVE") {
            Write-XferLog $State ("restore$i ok")
            return $true
        }
        Write-XferLog $State ("restore$i " + $h)
    }
    return $false
}

function Assert-BoardAlive($p, $State) {
    if (-not (Restore-GecShell $p $State)) {
        throw "board_no_echo: 串口能打开但板子没有回音。若刚传失败，请按板上复位，并关掉 MobaXterm 串口标签后再试。"
    }
}

function Read-GecRemoteSize($p, [string]$path, $State) {
    $out = Send-GecCmd $p ("echo WC_BEGIN; wc -c " + $path + "; echo WC_END") 1800
    $n = [int64](-1)
    if ($out -match "(?s)WC_BEGIN\s+(\d+)") { $n = [int64]$Matches[1] }
    if ($n -lt 0) {
        $ls = Send-GecCmd $p ("echo SZ_BEGIN; busybox ls -l " + $path + "; echo SZ_END") 2200
        $chunk = $ls
        if ($ls -match "(?s)SZ_BEGIN(.*)SZ_END") { $chunk = $Matches[1] }
        if ($chunk -match "root\s+(\d+)\s+") { $n = [int64]$Matches[1] }
        if ($n -lt 0) { Write-XferLog $State ("size_fail " + $path) }
    }
    return $n
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

function Resolve-GecLaunchPath([string]$raw) {
    $s = ([string]$raw).Trim().Replace('\', '/')
    if (-not $s) { return "" }
    if ($s -match '^[A-Za-z0-9._+-]+$') { $s = "/home/" + $s }
    if ($s -notmatch '^/') { $s = "/" + $s }
    return ($s -replace '/{2,}', '/')
}

function Get-GecLaunchKindLabel([string]$kind) {
    switch ($kind) {
        "qt"  { return "Qt(linuxfb)" }
        "nqt" { return "非Qt" }
        default { return "普通程序" }
    }
}

function Get-GecLaunchPlan($p, [string]$remote, $State) {
    $remote = Resolve-GecLaunchPath $remote
    if (-not (Test-GecRemotePath $remote)) {
        throw ("非法板上路径: " + $remote + "  只用 /home/名、/tmp/名 或 /usr/local/bin/名，也可只填文件名")
    }
    $base = Split-Path -Leaf $remote
    $out = Send-GecCmd $p ('chmod +x ' + $remote + ' 2>/dev/null; echo DET_BEGIN; test -f ' + $remote + '; echo EXIT:$?; wc -c ' + $remote + '; od -An -tx1 -N4 ' + $remote + '; echo DET_END') 900 "DET_END"
    if ($out -notmatch "EXIT:0") {
        throw ("板上没有这个文件: " + $remote + "  先传到 /home 再启动")
    }
    $n = [int64](-1)
    if ($out -match ("(?m)^\\s*(\\d+)\\s+" + [regex]::Escape($remote))) {
        $n = [int64]$Matches[1]
    } elseif ($out -match "(?s)EXIT:0\s+(\d+)") {
        $n = [int64]$Matches[1]
    }
    $isElf = [bool]($out -match "7f\s*45\s*4c\s*46")
    $kind = "bin"
    $reason = "plain"
    if ($base -match "nqt") {
        $kind = "nqt"
        $reason = "name_nqt"
    } elseif (Test-GecVehicleName $base) {
        $kind = "qt"
        $reason = "known_qt"
    } elseif ($isElf -and ($n -ge 80000)) {
        $kind = "qt"
        $reason = "elf_size"
    } elseif ($isElf) {
        $reason = "small_elf"
    }
    if (($kind -eq "qt") -and ($n -ge 0) -and ($n -lt 80000) -and (Test-GecVehicleName $base)) {
        Write-XferLog $State ("qt copy too small (" + $n + "B), fallback /usr/local/bin/vehicle_course")
        $remote = "/usr/local/bin/vehicle_course"
        $base = "vehicle_course"
        $reason = "fallback_stock_qt"
        $n = [int64](-1)
    }
    Write-XferLog $State ("detect " + $kind + " " + $reason + " " + $remote + " " + $n + "B elf=" + $isElf)
    return [pscustomobject]@{
        remote = $remote
        base   = $base
        size   = $n
        elf    = $isElf
        kind   = $kind
        reason = $reason
    }
}

function Start-GecBoardApp($p, $State) {
    $plan = Get-GecLaunchPlan $p $State.remote $State
    $remote = [string]$plan.remote
    $base = [string]$plan.base
    $isNqt = ($plan.kind -eq "nqt")
    $isQt = ($plan.kind -eq "qt")
    $State.remote = $remote

    $null = Send-GecCmd $p ("killall vehicle_course vehicle_nqt " + $base + " 2>/dev/null; rm -f /tmp/vc.log /tmp/nqt.log /tmp/run.log") 350
    $logFile = "/tmp/run.log"
    $waitMs = 700
    if ($isNqt) {
        Write-XferLog $State ("run_nqt " + $remote)
        $null = Send-GecCmd $p ($remote + " >/tmp/nqt.log 2>&1 & echo RUN_OK") 350 "RUN_OK"
        $logFile = "/tmp/nqt.log"
    } elseif ($isQt) {
        $useStarter = ($remote -eq "/usr/local/bin/vehicle_course") -or ($remote -eq "/usr/local/bin/start_vehicle")
        $started = $false
        if ($useStarter) {
            $sv = Send-GecCmd $p 'if [ -x /usr/local/bin/start_vehicle ]; then /usr/local/bin/start_vehicle >/tmp/start.out 2>&1 & echo SV:0; else echo SV:1; fi' 400 "SV:"
            if ($sv -match "SV:0") {
                Write-XferLog $State "run start_vehicle &"
                $base = "vehicle_course"
                $started = $true
            }
        }
        if (-not $started) {
            Write-XferLog $State ("run_qt " + $remote)
            $null = Send-GecCmd $p ('export LD_LIBRARY_PATH=/usr/local/Qt-Embedded-5.7.0/lib:/lib:/usr/lib QT_PLUGIN_PATH=/usr/local/Qt-Embedded-5.7.0/plugins QT_QPA_PLATFORM=linuxfb QT_QPA_FONTDIR=/usr/share/fonts; unset QT_QPA_GENERIC_PLUGINS QT_QPA_FB_HIDECURSOR; ' + $remote + ' >/tmp/vc.log 2>&1 & echo RUN_OK') 400 "RUN_OK"
        }
        $logFile = "/tmp/vc.log"
        $waitMs = 1100
    } else {
        Write-XferLog $State ("run_bg " + $remote)
        $null = Send-GecCmd $p ($remote + " >/tmp/run.log 2>&1 & echo RUN_OK") 350 "RUN_OK"
    }
    Start-Sleep -Milliseconds $waitMs
    $out = Send-GecCmd $p ("echo PID_BEGIN; pidof " + $base + "; echo PID_END; cat " + $logFile + "; echo START_DONE") 1600 "START_DONE"
    $pids = Get-GecPidsFromText $out
    $logReady = $isQt -and ($out -match "step6 loop")
    if (($pids.Count -eq 0) -and -not $logReady) {
        throw ("进程没起来(" + $base + ")。请看开发板屏幕。日志: " + (($out -replace "[\r\n]+", " ").Trim()))
    }
    $pidTxt = "none"
    if ($pids.Count -gt 0) { $pidTxt = ($pids -join ",") }
    $State.launchBase = $base
    $State.launchPids = @($pids)
    $State.message = "已启动 " + $base + "  pid=" + $pidTxt + "  (" + (Get-GecLaunchKindLabel $plan.kind) + ")"
    Write-XferLog $State ($State.message + " " + $remote)
}

function Invoke-GecSerialStart($State) {
    $p = $null
    $State.t0 = Get-Date
    $State.total = 1L
    $State.done = 0L
    $State.error = $null
    $State.finished = $false
    try {
        $p = Get-GecSessionPort $State
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
        Release-GecSessionPort $p $State
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

function Resolve-GecLocalFile([string]$raw) {
    $s = ([string]$raw).Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($s)) {
        throw "没有选择电脑上的文件"
    }
    if (-not (Test-Path -LiteralPath $s)) {
        throw ("找不到本地文件: " + $s)
    }
    $item = Get-Item -LiteralPath $s -ErrorAction Stop
    return [string]$item.FullName
}

function Invoke-GecSerialTransfer($State) {
    $p = $null
    $t0 = Get-Date
    $State.t0 = $t0
    $State.error = $null
    $State.finished = $false
    try {
        $local = Resolve-GecLocalFile $State.local
        $State.local = $local
        $bytes = [IO.File]::ReadAllBytes($local)
        $total = [int64]$bytes.Length
        $State.total = $total
        $State.done = 0L
        Write-XferLog $State ("file_bytes " + $total)
        if (-not (Test-GecRemotePath $State.remote)) {
            throw ("非法板上路径: " + $State.remote + "  只用 /home/名、/tmp/名 或 /usr/local/bin/名")
        }
        $p = Get-GecSessionPort $State
        Assert-BoardAlive $p $State
        $stage = "/tmp/.gec_xfer"
        $null = Send-GecCmd $p ("rm -f " + $stage) 400
        # 关 ICANON/ISIG：文件里的 0x03/0x04 否则会 SIGINT 或当 EOF，dd 必被截断
        $null = Send-GecCmd $p "stty -echo -icanon -isig -ixon -ixoff -icrnl -inlcr -onlcr" 700
        Write-XferLog $State "stty_raw"
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
        if ($cp -notmatch "CP_OK") {
            Write-XferLog $State $cp
            throw "临时文件已完整，但拷到 " + $State.remote + " 失败。看板上 /home 空间。"
        }
        Write-XferLog $State ("CP_OK " + $State.remote)
        $final = Read-GecRemoteSize $p $State.remote $State
        if ($final -ne $total) {
            throw ("copy_mismatch dest=" + $final + " local=" + $total)
        }
        $ver = Send-GecCmd $p ("od -An -tx1 -N8 " + $State.remote + "; echo VERIFY_DONE") 2000
        if ($ver -notmatch "VERIFY_DONE") { Write-XferLog $State $ver }
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
        Release-GecSessionPort $p $State
        $State.finished = $true
    }
}
