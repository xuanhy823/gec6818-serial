# GEC6818 串口协议（内部）

Agent 不要复述或重写这套协议。传文件只用仓库根的 `gec-serial.ps1 -Action xfer`。

## 为什么不能手写 dd

1. ELF 里常有 `0x03`（SIGINT）和 `0x04`（ICANON 下当 EOF）。不关 `ISIG`/`ICANON`，`dd` 会中途停。
2. `stty raw` 会关 `ICRNL`。之后只发 `\r` 时，ash 收不到换行，`dd`/`wc` 根本不跑，校验读到 `board=-1`。
3. `/home` 在慢闪存上。115200 直接 `dd` 到 `/home` 会丢字节。必须先写 `/tmp`（tmpfs），`wc`/`ls` 对齐后再 `cp`。
4. 传完必须先 `stty sane`（LF 和 CR 都发），再查大小。

当前引擎：`stty -echo -icanon -isig ...` → `dd of=/tmp/.gec_xfer bs=1 count=N`（命令用 LF）→ 256 字节节流 → 恢复 shell → 核对大小 → `cp` 到目标。

## 串口参数

- 115200 8N1，Handshake=None
- `DtrEnable=false`，`RtsEnable=false`（DTR 可能复位）
- 不要 `BreakState`（CH340 报设备失效并卡死 Write）
- 命令在 cooked 模式用 `\r`；raw / `-icrnl` 后用 `\n`
- 读串口用原始字节（Latin-1 1:1）。默认 ASCII 会把 ≥128 的字节变成 `?`

## 板上事实

- 内核 Linux 3.4.39-gec，提示符 `[root@GEC6818 /]#`
- Qt Embedded 5.7.0：`/usr/local/Qt-Embedded-5.7.0`
- 音乐：`madplay`。没有可用 OV5645，`/dev/video*` 是显示通道
- U 盘挂在 `/mnt/udisk`（电脑看不见盘符）。不要用 U 盘当默认传输
- `/tmp` 重启清空

## 人用 GUI

`打开串口传输.bat` 以 `-STA` 开 WinForms。引擎必须在 PowerShell Runspace 里跑，不要用 BackgroundWorker（会报「没有运行空间」）。

终端按钮在窗口顶栏（连接 / 断开 / 清屏 / Ctrl+C），不要到黑框里找。
