# GEC6818 串口工具

粤嵌 GEC6818（CH340，115200 8N1）文件传输 + 交互终端。

## 使用

1. 关掉 MobaXterm 的串口标签（口同时只能被一个程序打开）
2. 双击 `打开串口传输.bat`
3. 选 CH340 串口和波特率（默认 115200）
4. **串口终端**：点绿色「连接」，在黑框里直接输入 Linux 命令
5. **文件传输**：选本地文件，传到 `/home/文件名`，可再启动板上程序

不要传到 U 盘。不要勾 DTR。约 284KB 需要 30–80 秒。

## 命令行

```powershell
.\board-cmd.ps1 "uname -n"
.\send-to-board.ps1 C:\path\vehicle_course -RemoteFile /home/demo
.\gec-serial.ps1 -Action cmd -Command "ls -l /home"
```

## 成功标准

传输成功需同时看到 `size_ok`、`CP_OK`、目标字节数与本地一致；ELF 应有 `7f 45 4c 46`。
