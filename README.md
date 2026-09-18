# GEC6818 串口工具

给粤嵌 **GEC6818**（S5P6818，Linux 3.4.39，LCD 800×480）用的 Windows 串口工具：把交叉编译好的程序传到板上，在图形界面里开一个接近 MobaXterm 的终端，也可以用命令行给脚本 / AI 调用。

串口走底板 **UART0（DB9）+ USB 转 CH340**，不是安卓刷机线。默认 **115200 8N1**，流控全关，**不要开 DTR / RTS**（DTR 可能复位板子；`BreakState` 会把 CH340 卡死）。

> 不要自己用记事本粘贴二进制，也不要手写 `dd` / XMODEM 灌 ELF。  
> 文件里常有 `0x03`（SIGINT）、`0x04`（当 EOF）。必须走本仓库脚本：先关 `ISIG`/`ICANON`，写入 `/tmp` 校验字节数，再 `cp` 到 `/home`。

---

## 目录里有什么

| 文件 | 作用 |
|------|------|
| `打开串口传输.bat` | 人用入口。以 `-STA` 打开图形界面（必须 STA，否则窗口起不来） |
| `serial-transfer-gui.ps1` | 图形界面：分段页「文件传输 / 串口终端」 |
| `serial-term.ps1` | 终端仿真：按字节收发、UTF-8/GBK、方向键、Ctrl+C / Ctrl+D、快捷启动 |
| `serial-ios.ps1` | 界面控件（圆角卡片、按钮、自定义下拉） |
| `serial-transfer-core.ps1` | Win32 打开 CH340、恢复 shell、传文件、检测并启动板上程序 |
| `gec-serial.ps1` | 命令行总入口：`cmd` / `xfer` / `start` |
| `board-cmd.ps1` | 包装：执行一条板上命令 |
| `send-to-board.ps1` | 包装：传文件 |
| `说明.txt` | 简短中文备忘 |

桌面也可以放一份副本，和本目录保持同一套文件即可。

### 给 Cursor / Agent 的 Skill

克隆本仓库后，把 `.cursor/skills/gec6818-serial/` 留在仓库里即可。Cursor 会读 `SKILL.md`：提到 GEC6818、下板、串口传输时，Agent 应调用仓库根的 `gec-serial.ps1`，不要自己写 `dd`。

若要在其他工程里用，把整个 `gec6818-serial` 目录拷到那个工程的 `.cursor/skills/` 下，并把脚本路径指回本仓库根。

---

## 使用前

1. **先关 MobaXterm 的串口标签**（不必退出 MobaXterm）。COM 口同时只能被一个程序打开。
2. 图形界面开着时，命令行 / 其他工具也打不开同一口；用完点「断开」或关掉窗口。
3. 插上 **状态 OK 的 USB-SERIAL CH340**。口号码会变（出现过 COM6、COM3），以界面下拉或设备管理器为准，不要写死。
4. 线接底板 UART0。先开串口窗口再上电 / 按复位，板子提示符一般是：

   ```text
   [root@GEC6818 /]#
   ```

5. Windows 需要 PowerShell 5.1+。双击 bat 即可，不必改执行策略（bat 里带了 `-ExecutionPolicy Bypass`）。

---

## 图形界面

双击 `打开串口传输.bat`。

顶栏：

- **串口 / 刷新 / 波特率**：同一条灰胶囊里；下拉是圆角菜单，不是系统白底列表
- **文件传输 | 串口终端**：切换页面
- **连接 / 断开**：两页共用一条已打开的串口；传输会复用，不必先断开终端
- 右上角状态：空闲 / 已连接 / 传输中

WCH CH340 4.x 和 `.NET SerialPort.Open()` 不兼容，打开口走 Win32 `CreateFile`。

### 串口终端

用来在板上敲 Linux 命令，验证文件在不在、进程起没起。

1. 选好串口和 115200，点顶栏 **连接**
2. 鼠标点进中间黑色区域，直接打字（板子回显，类似 MobaXterm）
3. **Enter** 执行；**方向键**走板上历史；**Tab** 补全
4. **Ctrl+C**：没选中文字时中断前台命令；若刚快捷启动过后台程序，会一并强制结束
5. **Ctrl+D**：结束 `cat > 文件` 这类输入
6. **右键**：有选中复制，否则粘贴
7. 「快捷启动」填 `/home/名` 或只填文件名，点 **启动** 后台跑到 LCD；点 **停止**、顶栏断开或关窗口会 `kill -9` 并清掉 LCD 残留画面
8. 底部快捷按钮会发 `uname -a`、`ls -l /home`、`df -h /home`、`pidof vehicle_course`、`cat /tmp/vc.log`、`free`

连接失败常见原因：口被占（`open_fail`），或板子没回音（按复位，确认 UART0）。

`cat 文件` 只是查看。要写入用 `cat > /tmp/a.txt`，打完点 Ctrl+D。

### 文件传输

1. 切到 **文件传输**
2. 「电脑上的文件」选交叉编译产物（常见在 `C:\Users\32533\gec6818_share\` 或本课程仓库根目录）
3. 「板上目标」默认 `/home/文件名`。只允许：

   - `/home/名字`
   - `/tmp/名字`
   - `/usr/local/bin/名字`

   名字只能是字母数字和 `._+-`。**不要写 U 盘、`/udisk`、根分区 `/`。**

4. 可选：**传完自动启动**
5. 点 **开始传输**，看进度条。约 284KB 的程序，串口段大约十多秒（230400）；拷到 `/home` 闪存还要再等一会儿。日志需有 `size_ok`、`CP_OK`
6. 成功后再点 **启动程序**（或勾了自动启动则不用再点）。要退出点 **停止程序**，不要只关电脑窗口却指望板子自己停——以前 SIGTERM 经常杀不掉 Qt，现在会强制结束并清屏

`/home` 在慢闪存上，脚本会先写 `/tmp/.gec_xfer`（tmpfs），核对大小后再 `cp` 过去。`/tmp` 重启就没了，长期放的程序用 `/home`。

---

## 怎样才算成功

**传文件**必须同时满足：

- 日志有 `size_ok /tmp/.gec_xfer <本地字节数>`
- 有 `CP_OK`
- 目标 `ls -l` 的字节数和本地一致
- 若是 ELF，有 `elf_ok` / `7f 45 4c 46`

出现 `size_mismatch`、`board=-1`、`copy_mismatch`：**不要启动这个文件**，按板上复位后再传一次。

**启动**满足任一即可：

- `pidof <实际文件名>` 有数字。`/home/demo` 查的是 `demo`，不是 `vehicle_course`
- `/tmp/vc.log` 里出现 `step6 loop touch=`

已经在跑就不要再点启动（会先 `killall` 再拉起）。看开发板 LCD 确认界面。

---

## 板上启动环境

脚本启动 Qt 程序时会自己 export，一般不用手设：

```text
LD_LIBRARY_PATH=/usr/local/Qt-Embedded-5.7.0/lib:/lib:/usr/lib
QT_PLUGIN_PATH=/usr/local/Qt-Embedded-5.7.0/plugins
QT_QPA_PLATFORM=linuxfb
QT_QPA_FONTDIR=/usr/share/fonts
```

规则：

- 后台启动：`程序 >/tmp/vc.log 2>&1 &`，不要前台跑 `start_vehicle`（它会 `exec`，吃掉串口 shell）
- **不要**设 `QT_QPA_FB_HIDECURSOR`（会崩）
- **不要**设 `QT_QPA_GENERIC_PLUGINS`
- 文件 ≥80KB，或名叫 `vehicle_course` / `demo` / `start_vehicle`：按 Qt 带库启动
- 文件名含 `nqt`：不带 Qt 库
- 板上已有较稳的库存：`/usr/local/bin/vehicle_course`、`/usr/local/bin/start_vehicle`

不要对 i2c-0 做 `i2cdetect` / `i2cset` / 跑 `alc5623_init`，也不要写 ASoC `codec_reg`（内核会 Oops）。

---

## 命令行

在本目录打开 PowerShell。不指定 `-PortName` 时，自动选状态 OK 的 CH340。

```powershell
# 一条板上命令
.\board-cmd.ps1 "uname -n"
.\board-cmd.ps1 "ls -l /home"

# 等价写法
.\gec-serial.ps1 -Action cmd -Command "uname -a" -WaitMs 2000

# 传文件到 /home
.\send-to-board.ps1 C:\path\vehicle_course -RemoteFile /home/demo

# 传完安装到 /usr/local/bin 并启动
.\send-to-board.ps1 C:\path\vehicle_course -RemoteFile /home/demo -Install -Run

# 只启动板上已有程序
.\gec-serial.ps1 -Action start -RemoteFile /home/demo
```

`gec-serial.ps1` 参数：

| 参数 | 说明 |
|------|------|
| `-Action` | `cmd` / `xfer` / `start` |
| `-Command` | `cmd` 时的板上命令 |
| `-LocalFile` | `xfer` 时的电脑文件 |
| `-RemoteFile` | 板上路径，默认 `/home/vehicle_course` |
| `-PortName` | 如 `COM6`；可空 |
| `-Baud` | 默认 115200 |
| `-WaitMs` | `cmd` 等待回显，默认 2000 |
| `-Install` | 再拷到 `/usr/local/bin` |
| `-Run` | 传完启动 |

退出码：`0` 成功，`1` 板上失败，`2` 参数/找不到口/打不开口。

---

## 排障

| 现象 | 处理 |
|------|------|
| `open_fail` / 访问被拒绝 | 关 MobaXterm 串口标签、本工具重复窗口；CH340 4.x 必须用当前这版（Win32 打开） |
| `board_no_echo` | 按板上复位，确认 UART0，不要用刷机线 |
| `size_mismatch` | 文件不完整，禁止启动；复位后再传 |
| 启动报没 PID，但有 `step6` | 已经在跑，看 LCD |
| 段错误 / `/tmp/vc.log` 是空的 | 多半传截断了，先跑 `/usr/local/bin/vehicle_course` |
| 终端里中文或符号变 `?` | 用当前这版（按字节读，不再走默认 ASCII） |
| 连上后看不到「连接」按钮 | 按钮在**窗口最上方**，和串口、波特率同一栏，不在黑框里 |
| 传 284KB 要一两分钟 | 115200 正常 |

---

## 和 MobaXterm 的关系

本工具用来传文件和日常敲命令。需要完整终端体验时仍可用 MobaXterm：CH340、115200、8N1、流控全关。**同一时刻只能开一边的串口。**

不要默认结束 MobaXterm 进程。

---

## 许可

[MIT](LICENSE)。可以复制、修改、再发布。
