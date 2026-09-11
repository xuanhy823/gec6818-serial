@echo off
cd /d "%~dp0"
start "GEC6818 serial" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0serial-transfer-gui.ps1"