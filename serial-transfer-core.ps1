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
    readonly object _gate = new object();

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

    public void SetBaudRate(int baud) {
        if (baud < 1200) return;
        lock (_gate) {
            BaudRate = baud;
            if (!IsOpen) return;
            GecDcb dcb = new GecDcb();
            dcb.DCBlength = (uint)Marshal.SizeOf(typeof(GecDcb));
            if (!GetCommState(_h, ref dcb)) return;
            dcb.BaudRate = (uint)baud;
            dcb.ByteSize = 8;
            dcb.Parity = 0;
            dcb.StopBits = 0;
            SetCommState(_h, ref dcb);
            PurgeComm(_h, 0x000F);
        }
    }

    public int BytesToRead {
        get {
            lock (_gate) {
                if (!IsOpen) return 0;
                uint err;
                GecComstat st;
                if (!ClearCommError(_h, out err, out st)) return 0;
                return (int)st.cbInQue;
            }
        }
    }

    public int BytesToWrite {
        get {
            lock (_gate) {
                if (!IsOpen) return 0;
                uint err;
                GecComstat st;
                if (!ClearCommError(_h, out err, out st)) return 0;
                return (int)st.cbOutQue;
            }
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
        lock (_gate) {
            if (!IsOpen || buf == null || count <= 0) return 0;
            byte[] tmp = (off == 0) ? buf : new byte[count];
            int got;
            if (!ReadFile(_h, tmp, (off == 0) ? Math.Min(count, buf.Length) : count, out got, IntPtr.Zero)) return 0;
            if (off != 0 && got > 0) Array.Copy(tmp, 0, buf, off, got);
            return got;
        }
    }

    public void Write(string s) {
        if (string.IsNullOrEmpty(s)) return;
        byte[] b = Encoding.GetEncoding(28591).GetBytes(s);
        Write(b, 0, b.Length);
    }

    public void Write(byte[] bytes, int off, int count) {
        if (bytes == null || count <= 0) return;
        lock (_gate) {
            if (!IsOpen) return;
            int done = 0;
            while (done < count) {
                int n = count - done;
                byte[] tmp;
                if (off == 0 && done == 0 && n == bytes.Length) {
                    tmp = bytes;
                } else {
                    tmp = new byte[n];
                    Array.Copy(bytes, off + done, tmp, 0, n);
                }
                int wrote;
                if (!WriteFile(_h, tmp, n, out wrote, IntPtr.Zero)) return;
                if (wrote <= 0) return;
                done += wrote;
            }
        }
    }

    public void Close() { Dispose(); }
    public void Dispose() {
        lock (_gate) {
            if (!IsOpen) return;
            try { FlushFileBuffers(_h); } catch {}
            try { PurgeComm(_h, 0x000F); } catch {}
            CloseHandle(_h);
            _h = Invalid;
        }
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
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    $p = $path.Trim().Replace('\', '/')
    if ($p -match '\.\.') { return $false }
    if ($p -match '//') { return $false }
    if ($p -match '/(udisk|etc|dev|proc|sys)(/|$)') { return $false }
    return [bool]($p -match '^/(home|tmp|usr/local/bin)(/[A-Za-z0-9._+-]+)+$')
}

function Join-GecRemoteName([string]$current, [string]$fileName) {
    $name = [string]$fileName
    if ($name -notmatch '^[A-Za-z0-9._+-]+$') {
        $name = [regex]::Replace($name, '[^A-Za-z0-9._+-]', '_')
    }
    if (-not $name) { return $current }
    $cur = ([string]$current).Trim().Replace('\', '/')
    if ($cur -match '^/(home|tmp|usr/local/bin)(/[A-Za-z0-9._+-]+)+$') {
        $i = $cur.LastIndexOf('/')
        if ($i -gt 0) { return $cur.Substring(0, $i) + '/' + $name }
    }
    return '/home/' + $name
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

function Test-GecUntilText([string]$text, [string]$until) {
    if ([string]::IsNullOrEmpty($until) -or [string]::IsNullOrEmpty($text)) { return $false }
    $esc = [regex]::Escape($until)
    return [bool]($text -match ('(?m)^' + $esc))
}

function Recv-GecSerial($p, [int]$ms, [string]$Until = $null) {
    $end = [datetime]::UtcNow.AddMilliseconds($ms)
    $sb = New-Object System.Text.StringBuilder
    $lastData = [datetime]::UtcNow
    $got = $false
    $needUntil = -not [string]::IsNullOrEmpty($Until)
    while ([datetime]::UtcNow -lt $end) {
        $chunk = ""
        try {
            if ($p.BytesToRead -gt 0) { $chunk = $p.ReadExisting() }
        } catch {}
        if ($chunk) {
            [void]$sb.Append($chunk)
            $lastData = [datetime]::UtcNow
            $got = $true
            if ($needUntil -and (Test-GecUntilText $sb.ToString() $Until)) {
                Start-Sleep -Milliseconds 50
                try { if ($p.BytesToRead -gt 0) { [void]$sb.Append($p.ReadExisting()) } } catch {}
                break
            }
        } elseif ($got -and (-not $needUntil) -and (([datetime]::UtcNow - $lastData).TotalMilliseconds -ge 80)) {
            break
        }
        Start-Sleep -Milliseconds 8
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

function Send-GecQuietCmd($p, [string]$c, [int]$ms = 1000, [string]$Until = $null) {
    $null = Send-GecCmd $p "stty -echo" 300
    $out = Send-GecCmd $p $c $ms $Until
    $null = Send-GecCmd $p "stty echo" 300
    return $out
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

function Get-GecSizeWaitMs($State) {
    $wait = 4500
    try {
        $sz = [int64]$State.total
        if ($sz -gt 0) { $wait = [Math]::Min(20000, 4000 + [int]($sz / 4000)) }
    } catch {}
    return $wait
}

function Parse-GecWcSize([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return [int64](-1) }
    $blocks = [regex]::Matches($text, '(?s)WC_BEGIN(.*?)WC_END')
    for ($i = $blocks.Count - 1; $i -ge 0; $i--) {
        $c = $blocks[$i].Groups[1].Value
        if ($c -match '(?m)^\s*(\d+)\s+\S+') { return [int64]$Matches[1] }
        if ($c -match '(?m)^\s*(\d+)\s*$') { return [int64]$Matches[1] }
        if ($c -match '(\d+)\s+/\S+') { return [int64]$Matches[1] }
    }
    if ($text -match '(?m)^(\d+)\s+/\S+') { return [int64]$Matches[1] }
    if ($text -match '(\d+)\s+/(?:tmp|home|usr)[^\r\n]*') { return [int64]$Matches[1] }
    return [int64](-1)
}

function Parse-GecLsSize([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return [int64](-1) }
    $blocks = [regex]::Matches($text, '(?s)SZ_BEGIN(.*?)SZ_END')
    $chunks = New-Object System.Collections.Generic.List[string]
    for ($i = $blocks.Count - 1; $i -ge 0; $i--) { [void]$chunks.Add($blocks[$i].Groups[1].Value) }
    [void]$chunks.Add($text)
    foreach ($chunk in $chunks) {
        if ($chunk -match '[-dclpsb][-rwxstST]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+') {
            return [int64]$Matches[1]
        }
        if ($chunk -match '\s(\d+)\s+[A-Z][a-z]{2}\s+\d+') { return [int64]$Matches[1] }
    }
    return [int64](-1)
}

function Read-GecRemoteSize($p, [string]$path, $State) {
    $wait = Get-GecSizeWaitMs $State
    $out = Send-GecQuietCmd $p ("busybox wc -c " + $path + "; echo GEC_SZ_DONE") $wait "GEC_SZ_DONE"
    $n = Parse-GecWcSize $out
    if ($n -ge 0) { return $n }
    $ls = Send-GecQuietCmd $p ("busybox ls -l " + $path + "; echo GEC_SZ_DONE") $wait "GEC_SZ_DONE"
    $n = Parse-GecLsSize $ls
    if ($n -ge 0) { return $n }
    Write-XferLog $State ("size_fail " + $path + " wc=[" + (Format-GecLogText $out) + "] ls=[" + (Format-GecLogText $ls) + "]")
    return [int64](-1)
}

function Read-GecDfAvailKb($p, [string]$dir, $State) {
    $out = Send-GecQuietCmd $p ("busybox df -k " + $dir + "; echo GEC_DF_DONE") 2500 "GEC_DF_DONE"
    $avail = [int64](-1)
    foreach ($line in ($out -split '[\r\n]+')) {
        $parts = @($line.Trim() -split '\s+')
        if ($parts.Count -ge 6 -and $parts[1] -match '^\d+$' -and $parts[3] -match '^\d+$') {
            $avail = [int64]$parts[3]
        }
    }
    Write-XferLog $State ("df " + $dir + " avail_kb=" + $avail)
    return $avail
}

function Get-GecPidsFromText([string]$text) {
    $found = New-Object System.Collections.Generic.List[int]
    if ($text -notmatch "(?s)PID_BEGIN(.*)PID_END") { return , @() }
    $chunk = $Matches[1]
    foreach ($m in [regex]::Matches($chunk, '(?m)(?<![A-Za-z0-9_/])(\d{2,5})(?![A-Za-z0-9_])')) {
        $n = [int]$m.Groups[1].Value
        if (($n -ge 2) -and ($n -le 32768) -and -not $found.Contains($n)) { $found.Add($n) }
    }
    return , @($found)
}

function Test-GecVehicleName([string]$base) {
    return ($base -match '^(vehicle_course|vehicle_nqt|start_vehicle|demo)$')
}

function Get-GecKillCmd {
    param(
        [string[]]$Names,
        $Pids,
        [switch]$BlankFb
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $safeNames = @($Names | Where-Object { $_ -match '^[A-Za-z0-9._+-]+$' } | Select-Object -Unique)
    $safePids = @($Pids | Where-Object { "$_" -match '^\d+$' } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($safePids.Count -gt 0) {
        [void]$parts.Add("kill -9 " + ($safePids -join " ") + " 2>/dev/null")
    }
    if ($safeNames.Count -gt 0) {
        $joined = $safeNames -join " "
        [void]$parts.Add("killall -9 " + $joined + " 2>/dev/null")
        [void]$parts.Add("killall " + $joined + " 2>/dev/null")
        foreach ($n in $safeNames) {
            [void]$parts.Add('kill -9 $(pidof ' + $n + ') 2>/dev/null')
        }
    }
    if ($BlankFb) {
        [void]$parts.Add("head -c 1600000 /dev/zero > /dev/fb0 2>/dev/null")
    }
    [void]$parts.Add("echo KILL_DONE")
    return ($parts -join "; ")
}

function Resolve-GecLaunchPath([string]$raw) {
    $s = ([string]$raw).Trim().Replace('\', '/')
    if (-not $s) { return "" }
    $s = ($s -replace '/{2,}', '/')
    if ($s -notmatch '^/') {
        $s = "/home/" + $s.TrimStart('/')
    }
    return $s
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
        throw ("非法板上路径: " + $remote + "  只用 /home、/tmp、/usr/local/bin 下的文件，可带子目录，例如 /home/class/demo")
    }
    $base = Split-Path -Leaf $remote
    $out = Send-GecCmd $p ('chmod +x ' + $remote + ' 2>/dev/null; echo DET_BEGIN; test -f ' + $remote + '; echo EXIT:$?; wc -c ' + $remote + '; od -An -tx1 -N4 ' + $remote + '; echo DET_END') 900 "DET_END"
    if ($out -notmatch "EXIT:0(?:\D|$)") {
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

    $preKill = Get-GecKillCmd -Names @("vehicle_course", "vehicle_nqt", "start_vehicle", $base) -BlankFb:$false
    $preKill = $preKill -replace "; echo KILL_DONE$", ""
    $null = Send-GecCmd $p ($preKill + "; rm -f /tmp/vc.log /tmp/nqt.log /tmp/run.log; echo KILL_DONE") 900 "KILL_DONE"
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

function Set-GecPortBaud($p, [int]$baud) {
    if ($null -eq $p -or $baud -lt 1200) { return }
    try {
        $p.SetBaudRate($baud)
    } catch {
        try { $p.BaudRate = $baud } catch {}
    }
}

function Test-GecBaudEcho($p, [string]$tag) {
    $h = ""
    try { $h = Send-GecCmd $p ("echo " + $tag) 450 $tag } catch {}
    return [bool]($h -match [regex]::Escape($tag))
}

function Restore-GecBaudPair($p, [int]$orig) {
    try { Set-GecPortBaud $p $orig } catch {}
    Start-Sleep -Milliseconds 50
    try { Send-GecRawLine $p ("stty " + $orig) -LfOnly } catch {}
    Start-Sleep -Milliseconds 70
    try { Set-GecPortBaud $p $orig } catch {}
    Start-Sleep -Milliseconds 70
}

function Get-GecFastBaudList([int]$orig, [int64]$total, [int]$maxBaud) {
    $list = New-Object System.Collections.Generic.List[int]
    if ($maxBaud -le 0) { $maxBaud = 10000000 }
    if ($total -gt 65536) {
        # 大文件无流控时 460800 易丢字节，固定走 230400（含从更高波特率降速）
        if (($maxBaud -ge 230400) -and ($orig -ne 230400)) {
            [void]$list.Add(230400)
        }
    } else {
        if (($orig -lt 460800) -and ($maxBaud -ge 460800)) { [void]$list.Add(460800) }
        if (($orig -lt 230400) -and ($maxBaud -ge 230400)) { [void]$list.Add(230400) }
    }
    return $list
}

function Enter-GecXferBaud($p, $State, [int]$MaxBaud = 0) {
    $orig = [int]$State.baud
    if ($orig -le 0) { $orig = 115200 }
    $total = 0L
    try { $total = [int64]$State.total } catch {}
    $cands = Get-GecFastBaudList $orig $total $MaxBaud
    if ($cands.Count -eq 0) {
        Write-XferLog $State ("baud_keep " + $orig)
        return $orig
    }
    foreach ($fast in $cands) {
        Write-XferLog $State ("baud_try " + $fast)
        Send-GecRawLine $p ("stty " + $fast) -LfOnly
        Start-Sleep -Milliseconds 70
        Set-GecPortBaud $p $fast
        Start-Sleep -Milliseconds 50
        $tag = "FAST_" + $fast
        if (Test-GecBaudEcho $p $tag) {
            Write-XferLog $State ("baud_fast " + $fast)
            return $fast
        }
        Write-XferLog $State ("baud_try_fail " + $fast)
        Restore-GecBaudPair $p $orig
        if (-not (Test-GecBaudEcho $p "SLOW_OK")) {
            Write-XferLog $State "baud_desync restore_shell"
            $null = Restore-GecShell $p $State
        }
    }
    Write-XferLog $State ("baud_keep " + $orig)
    return $orig
}

function Exit-GecXferBaud($p, $State, [int]$xferBaud) {
    $orig = [int]$State.baud
    if ($orig -le 0) { $orig = 115200 }
    if ($xferBaud -eq $orig) { return }
    try { Send-GecRawLine $p ("stty " + $orig) -LfOnly } catch {}
    Start-Sleep -Milliseconds 90
    Set-GecPortBaud $p $orig
    Start-Sleep -Milliseconds 90
}

function Get-GecIoWaitMs([int64]$bytes, [int]$baseMs, [int]$capMs = 180000) {
    if ($bytes -lt 0) { $bytes = 0 }
    if ($capMs -lt $baseMs) { $capMs = $baseMs }
    $extra = [int][Math]::Min(400000, ($bytes / 12))
    $ms = $baseMs + $extra
    if ($ms -lt $baseMs) { $ms = $baseMs }
    if ($ms -gt $capMs) { $ms = $capMs }
    return $ms
}

function Send-GecBinaryPayload($p, $State, [byte[]]$bytes, [int]$baud, [switch]$SlowDd, [int64]$Start = 0, [int64]$Count = -1) {
    $len = [int64]$bytes.Length
    if ($Start -lt 0) { $Start = 0 }
    if ($Start -gt $len) { $Start = $len }
    if ($Count -lt 0) { $Count = $len - $Start }
    $end = $Start + $Count
    if ($end -gt $len) { $end = $len }
    $chunk = 4096
    $slack = 1.02
    if ($SlowDd) {
        $chunk = 256
        $slack = 1.12
    } elseif ($baud -ge 460800) {
        $chunk = 2048
        $slack = 1.06
    }
    $rate = [Math]::Max(9600, $baud)
    if ($Start -eq 0) {
        Write-XferLog $State ("pace chunk=" + $chunk + " baud=" + $baud + " clock=1")
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $off = $Start
    $sent = 0L
    while ($off -lt $end) {
        if ($State.cancel) { throw "cancelled" }
        $n = [int][Math]::Min($chunk, $end - $off)
        $p.Write($bytes, [int]$off, $n)
        $off += $n
        $sent += $n
        $State.done = $off
        $ahead = ($sent * 10000.0 * $slack / $rate) - $sw.Elapsed.TotalMilliseconds
        if ($ahead -ge 6) { Start-Sleep -Milliseconds ([int]$ahead) }
    }
    $pad = 40
    if ($SlowDd) { $pad = 120 }
    elseif ($baud -ge 460800) { $pad = 70 }
    $left = ($sent * 10000.0 * $slack / $rate) + $pad - $sw.Elapsed.TotalMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds ([int]$left) }
}

function Receive-GecRawBlob($p, $State, [byte[]]$bytes, [int]$baud, [bool]$useHead, [int64]$off, [int]$n, [string]$path) {
    $null = Send-GecCmd $p "stty -echo -icanon -isig -ixon -ixoff -icrnl -inlcr -onlcr" 700
    if ($useHead) {
        Send-GecRawLine $p ("busybox head -c " + $n + " > " + $path) -LfOnly
    } else {
        Send-GecRawLine $p ("busybox dd of=" + $path + " bs=1 count=" + $n) -LfOnly
    }
    Start-Sleep -Milliseconds 80
    $null = Recv-GecSerial $p 40
    Write-XferLog $State ("recv_blob " + $path + " off=" + $off + " n=" + $n + " baud=" + $baud)
    Send-GecBinaryPayload $p $State $bytes $baud -SlowDd:(-not $useHead) -Start $off -Count $n
    $tailMs = 700
    if (-not $useHead) { $tailMs = Get-GecIoWaitMs $n 800 }
    $tail = Recv-GecSerial $p $tailMs
    if ($tail) { Write-XferLog $State (("recv_tail " + ($tail -replace "[\r\n]+", " ")).Trim()) }
    if (-not (Restore-GecShell $p $State)) {
        throw "传完后串口没恢复，无法核对大小。关 MobaXterm 串口标签，按板上复位后再传。"
    }
    return (Read-GecRemoteSize $p $path $State)
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
            throw ("非法板上路径: " + $State.remote + "  只用 /home、/tmp、/usr/local/bin 下的文件，可带子目录")
        }
        $p = Get-GecSessionPort $State
        Assert-BoardAlive $p $State
        $stage = "/tmp/.gec_xfer"
        $part = "/tmp/.gec_part"
        $destDir = ($State.remote -replace '/[^/]+$', '')
        if ([string]::IsNullOrWhiteSpace($destDir)) { $destDir = "/" }
        $tmpKb = Read-GecDfAvailKb $p "/tmp" $State
        $needKb = [int64][Math]::Ceiling(($total + 589824) / 1024.0)
        if (($tmpKb -ge 0) -and ($tmpKb -lt $needKb)) {
            throw ("板上 /tmp 空间不足：需要约 " + $needKb + "KB，只剩 " + $tmpKb + "KB。请先删 /tmp 里的文件再传。")
        }
        $homeKb = Read-GecDfAvailKb $p $destDir $State
        $needHomeKb = [int64][Math]::Ceiling(($total + 32768) / 1024.0)
        if (($homeKb -ge 0) -and ($homeKb -lt $needHomeKb)) {
            throw ("板上 " + $destDir + " 空间不足：需要约 " + $needHomeKb + "KB，只剩 " + $homeKb + "KB。")
        }
        $null = Send-GecCmd $p ("rm -f " + $stage + " " + $part) 500
        $useHead = $false
        $hp = Send-GecCmd $p "busybox head -c 1 /dev/null >/dev/null; echo HEAD_OK" 500 "HEAD_OK"
        if ($hp -match "HEAD_OK") { $useHead = $true }
        Write-XferLog $State ("recv_tool " + $(if ($useHead) { "head" } else { "dd" }))
        $origBaud = [int]$State.baud
        if ($origBaud -le 0) { $origBaud = 115200 }
        $maxBaud = 10000000
        $got = [int64](-1)
        $xferBaud = $origBaud
        $piece = 524288
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            if ($attempt -gt 0) {
                $State.done = 0L
                $null = Send-GecCmd $p ("rm -f " + $stage + " " + $part) 500
                $null = Restore-GecShell $p $State
            }
            $xferBaud = Enter-GecXferBaud $p $State $maxBaud
            $State.xferBaud = $xferBaud
            $off = 0L
            $okRun = $true
            while ($off -lt $total) {
                if ($State.cancel) { throw "cancelled" }
                $n = [int][Math]::Min([int64]$piece, $total - $off)
                $target = $stage
                if ($total -gt $piece) { $target = $part }
                Write-XferLog $State ("stty_raw baud=" + $xferBaud + " try=" + ($attempt + 1) + " off=" + $off + " n=" + $n)
                $gotPart = Receive-GecRawBlob $p $State $bytes $xferBaud $useHead $off $n $target
                if ($gotPart -ne [int64]$n) {
                    Write-XferLog $State ("chunk_bad off=" + $off + " want=" + $n + " got=" + $gotPart)
                    $okRun = $false
                    break
                }
                if ($target -eq $part) {
                    if ($off -eq 0) {
                        $cat = Send-GecQuietCmd $p ("mv -f " + $part + " " + $stage + " && echo CAT_OK") 2500 "CAT_OK"
                    } else {
                        $cat = Send-GecQuietCmd $p ("cat " + $part + " >> " + $stage + " && rm -f " + $part + " && echo CAT_OK") 4000 "CAT_OK"
                    }
                    if ($cat -notmatch "CAT_OK") {
                        Write-XferLog $State $cat
                        $okRun = $false
                        break
                    }
                }
                $off += $n
            }
            if ($okRun -and ($off -eq $total)) {
                $got = Read-GecRemoteSize $p $stage $State
                if ($got -eq $total) { break }
                Write-XferLog $State ("size_retry local=" + $total + " board=" + $got + " baud=" + $xferBaud)
            } else {
                $got = [int64](-1)
                Write-XferLog $State ("size_retry local=" + $total + " board=" + $got + " baud=" + $xferBaud)
            }
            if ($xferBaud -le $origBaud) { break }
            $maxBaud = $origBaud
            Write-XferLog $State ("retry_slow " + $origBaud)
        }
        Exit-GecXferBaud $p $State $xferBaud
        if ($got -lt 0) {
            throw "传完后读不到 /tmp 临时文件大小。看日志里 size_fail / df。可按板上复位后再传。"
        }
        if ($got -ne $total) {
            throw ("size_mismatch local=" + $total + " board=" + $got + " 串口拷贝不完整，已拒绝覆盖目标文件。")
        }
        Write-XferLog $State ("size_ok " + $stage + " " + $total)
        $cpMs = Get-GecIoWaitMs $total 8000
        $isElf = ($total -ge 4 -and $bytes[0] -eq 127 -and $bytes[1] -eq 69 -and $bytes[2] -eq 76 -and $bytes[3] -eq 70)
        $chmod = ""
        if ($isElf) { $chmod = " && chmod +x " + $State.remote }
        $cp = Send-GecQuietCmd $p ("mkdir -p " + $destDir + " && cp -f " + $stage + " " + $State.remote + $chmod + " && echo CP_OK") $cpMs "CP_OK"
        if ($cp -notmatch "CP_OK") {
            Write-XferLog $State $cp
            throw "临时文件已完整，但拷到 " + $State.remote + " 失败。看板上 /home 空间。"
        }
        Write-XferLog $State ("CP_OK " + $State.remote)
        $final = Read-GecRemoteSize $p $State.remote $State
        if ($final -ne $total) {
            throw ("copy_mismatch dest=" + $final + " local=" + $total)
        }
        $ver = Send-GecCmd $p ("od -An -tx1 -N8 " + $State.remote + "; echo VERIFY_DONE") 2500 "VERIFY_DONE"
        if ($ver -notmatch "VERIFY_DONE") { Write-XferLog $State $ver }
        if ($isElf) {
            if ($ver -match "7f\s*45\s*4c\s*46") {
                Write-XferLog $State "elf_ok 7f 45 4c 46"
            } else {
                Write-XferLog $State "elf_warn no_magic"
            }
        } else {
            Write-XferLog $State "skip_elf_magic"
        }
        $null = Send-GecCmd $p ("rm -f " + $stage) 800
        if ($State.install) {
            $base = Split-Path -Leaf $State.remote
            $insMs = Get-GecIoWaitMs $total 8000
            $ins = Send-GecCmd $p ("cp -f " + $State.remote + " /usr/local/bin/" + $base + " && chmod +x /usr/local/bin/" + $base + " && echo INSTALL_OK") $insMs "INSTALL_OK"
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
            if ($p -and $p.IsOpen) {
                if ($State.xferBaud) { Exit-GecXferBaud $p $State ([int]$State.xferBaud) }
                $null = Restore-GecShell $p $State
            }
        } catch {}
    } finally {
        Release-GecSessionPort $p $State
        $State.finished = $true
    }
}
