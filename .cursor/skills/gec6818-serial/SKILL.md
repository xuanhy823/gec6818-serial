---
name: gec6818-serial
description: >-
  Controls the GEC6818 (粤嵌) board over CH340 serial (115200). Transfers files to
  /home, runs board commands, and starts the vehicle Qt GUI. Use when the user
  mentions GEC6818、开发板、串口、CH340、COM6、COM3、MobaXterm、下板、串口传输、
  传到板上、启动中控、vehicle_course，or any board file/command over UART.
---

# GEC6818 串口控板

板子：粤嵌 GEC6818（S5P6818，Linux 3.4.39，LCD 800×480）。串口是 **状态 OK 的 USB-SERIAL CH340**，115200 8N1，流控全关。

**不要自己写 `dd` / raw 灌文件。** 必须走本仓库脚本，否则 ELF 会被 `0x03`/`0x04` 截断，或 raw 模式下命令发不出去。

## 入口

本 skill 在仓库 `.cursor/skills/gec6818-serial/`。脚本在**仓库根目录**（和 `gec-serial.ps1` 同级），不要到别的路径自己发明一套。

仓库根 = `gec-serial.ps1` 所在目录（`.cursor/skills/gec6818-serial` 再往上三级）。

```powershell
# 若当前就在仓库根：
$root = (Get-Location).Path
$s = Join-Path $root "gec-serial.ps1"
```

| 谁用 | 怎么用 |
|------|--------|
| 人 | 双击仓库根的 `打开串口传输.bat`（必须 `-STA`） |
| Agent | `gec-serial.ps1` 的 `cmd` / `xfer` / `start` |

```powershell
# 执行一条板上命令
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Action cmd -Command "uname -n"
# 传文件到 /home（先写 /tmp 再校验字节数）
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Action xfer -LocalFile "C:\path\vehicle_course" -RemoteFile "/home/demo"
# 启动板上程序（按实际文件名 pidof）
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Action start -RemoteFile "/home/demo"
```

兼容包装：`board-cmd.ps1` → `cmd`；`send-to-board.ps1` → `xfer`。

## 调用前检查

1. 请用户**关掉 MobaXterm 串口标签**（不必退出 MobaXterm）。串口同时只能被一个程序打开。
2. **不要** `Stop-Process MobaXterm`，除非用户明确同意。
3. 传输 GUI / 终端「连接」开着时 Agent 打不开口，先让用户断开或关窗口。
4. 口由脚本自动选「状态 OK 的 CH340」。号会变（做过 COM6 / COM3），不要写死。
5. `DtrEnable` / `RtsEnable` 必须 false。不要设 `BreakState`（CH340 会卡死）。
6. 打开失败（`UnauthorizedAccess` / `open_fail`）= 口被占，停下来让用户关标签，不要重试轰炸。

## 成功标准

**传文件成功** 必须同时满足：

- 日志有 `size_ok /tmp/.gec_xfer <本地字节数>`
- 有 `CP_OK`
- 目标 `ls -l` 字节数与本地一致
- ELF 则 `7f 45 4c 46`

`board=-1` 或 `size_mismatch` = 失败，**禁止启动**该文件。

**启动成功** 满足任一即可：

- `pidof <实际文件名>` 有数字（`/home/demo` 查的是 `demo`，不是 `vehicle_course`）
- `/tmp/vc.log` 出现 `step6 loop touch=`

进程在跑时不要再点启动（会先 `killall` 再拉起）。

## 板上路径

- 程序放 **`/home/<名>`**（重启还在）。路径只允许 `[A-Za-z0-9._+-]`。
- `/tmp` 是 tmpfs，只适合日志和传输中转。
- 加 `-Install` 才会再拷到 `/usr/local/bin/`。
- 不要写 `/udisk`、未挂载 U 盘、根分区 `/`。
- 已知完好 Qt：`/usr/local/bin/vehicle_course`、`/usr/local/bin/start_vehicle`。

## 启动环境（脚本会自动 export）

```text
LD_LIBRARY_PATH=/usr/local/Qt-Embedded-5.7.0/lib:/lib:/usr/lib
QT_PLUGIN_PATH=/usr/local/Qt-Embedded-5.7.0/plugins
QT_QPA_PLATFORM=linuxfb
QT_QPA_FONTDIR=/usr/share/fonts
不要设 QT_QPA_FB_HIDECURSOR（会崩）
不要设 QT_QPA_GENERIC_PLUGINS
必须后台：prog >/tmp/vc.log 2>&1 &
不要前台跑 start_vehicle（它 exec，会吃掉串口 shell）
```

文件 ≥80KB 或名为 `vehicle_course` / `vehicle_nqt` / `start_vehicle` / `demo` 时按 Qt 启动；文件名含 `nqt` 则不带 Qt 库。

## 禁止

- 自己实现串口 `dd` / XMODEM / 把二进制当文本粘贴
- 对 i2c-0 做 `i2cdetect` / `i2cset` / 跑 `alc5623_init`
- 写 ASoC `codec_reg`（kernel Oops）
- 设 `QT_QPA_FB_HIDECURSOR`
- 默认杀 MobaXterm

## 排障

| 现象 | 处理 |
|------|------|
| `open_fail` | 关 MobaXterm 串口标签和本工具窗口 |
| `board_no_echo` | 按板上复位，确认 UART0 |
| `size_mismatch` | 不要启动；复位后再传 |
| 启动报没 PID，但有 `step6` | 已在跑，看 LCD |
| 段错误 / 空 `vc.log` | 文件被截断，改跑 `/usr/local/bin/vehicle_course` |
| 115200 传约 284KB | 大约 30–80 秒，属正常 |

协议细节见同目录 [reference.md](reference.md)。人用说明见仓库根 [README.md](../../../README.md)。
